// Zeon Remote - RDP client core on top of FreeRDP
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include "ZVRdpClient.h"

#include <string.h>

#include <algorithm>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/channels.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>

#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/user.h>

// The framebuffer is B G R X in memory
static const UINT32 kFramebufferFormat = PIXEL_FORMAT_XRGB32;
// Cursor images are R G B A in memory
static const UINT32 kCursorFormat = PIXEL_FORMAT_ABGR32;

// Negotiated security protocols (MS-RDPBCGR 2.2.1.1.1, not in FreeRDP's
// public headers)
enum : UINT32 {
  kProtocolSSL = 0x1,
  kProtocolHybrid = 0x2,
  kProtocolRDSTLS = 0x4,
  kProtocolHybridEx = 0x8,
};

struct ZVRdpContext {
  rdpClientContext common;
  ZVRdpClient* owner;
  DispClientContext* disp;
  CliprdrClientContext* cliprdr;
  bool clipboardReady;
  // FreeRDP allocates the context with calloc, so no C++ members here
  std::string* localText;      // our clipboard, sent when the server asks
  bool localTextAvailable;
};

struct ZVPointer {
  rdpPointer pointer;
  std::vector<uint8_t>* rgba;
};

// Static callbacks that FreeRDP calls; they forward to the client object
struct ZVRdpCallbacks {
  static ZVRdpClient* owner(rdpContext* ctx) { return ((ZVRdpContext*)ctx)->owner; }

  static BOOL clientNew(freerdp* instance, rdpContext* context);
  static void clientFree(freerdp* instance, rdpContext* context);
  static BOOL preConnect(freerdp* instance);
  static BOOL postConnect(freerdp* instance);
  static void postDisconnect(freerdp* instance);
  static BOOL authenticate(freerdp* instance, char** user, char** password, char** domain,
                           rdp_auth_reason reason);
  static int verifyX509(freerdp* instance, const BYTE* data, size_t length, const char* hostname,
                        UINT16 port, DWORD flags);
  static int logonErrorInfo(freerdp* instance, UINT32 data, UINT32 type);

  static BOOL beginPaint(rdpContext* context);
  static BOOL endPaint(rdpContext* context);
  static BOOL desktopResize(rdpContext* context);
  static BOOL playSound(rdpContext* context, const PLAY_SOUND_UPDATE* sound);

  static BOOL pointerNew(rdpContext* context, rdpPointer* pointer);
  static void pointerFree(rdpContext* context, rdpPointer* pointer);
  static BOOL pointerSet(rdpContext* context, rdpPointer* pointer);
  static BOOL pointerSetNull(rdpContext* context);
  static BOOL pointerSetDefault(rdpContext* context);
  static BOOL pointerSetPosition(rdpContext* context, UINT32 x, UINT32 y);

  static void channelConnected(void* context, const ChannelConnectedEventArgs* e);
  static void channelDisconnected(void* context, const ChannelDisconnectedEventArgs* e);
  static UINT dispCaps(DispClientContext* disp, UINT32 maxMonitors, UINT32 maxA, UINT32 maxB);

  static UINT clipMonitorReady(CliprdrClientContext* clip, const CLIPRDR_MONITOR_READY* r);
  static UINT clipServerCapabilities(CliprdrClientContext* clip, const CLIPRDR_CAPABILITIES* c);
  static UINT clipServerFormatList(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list);
  static UINT clipServerFormatListResponse(CliprdrClientContext* clip,
                                           const CLIPRDR_FORMAT_LIST_RESPONSE* r);
  static UINT clipServerFormatDataRequest(CliprdrClientContext* clip,
                                          const CLIPRDR_FORMAT_DATA_REQUEST* r);
  static UINT clipServerFormatDataResponse(CliprdrClientContext* clip,
                                           const CLIPRDR_FORMAT_DATA_RESPONSE* r);
  static UINT sendClientFormatList(ZVRdpContext* ctx);
};

static char* dupString(const std::string& s)
{
  return s.empty() ? nullptr : _strdup(s.c_str());
}

// "a:b:c" -> "abc", lower case
static std::string plainHex(const char* s)
{
  std::string r;
  for (; s && *s; s++)
    if (*s != ':')
      r += (char)tolower(*s);
  return r;
}

// --- Client object

ZVRdpClient::ZVRdpClient(Delegate* delegate, const Options& options)
  : delegate_(delegate), options_(options), context_(nullptr), stopRequested_(false),
    secure_(false), canResize_(false), wakeEvent_(nullptr), buttons_(0), authRetry_(false)
{
  wakeEvent_ = CreateEventA(nullptr, TRUE, FALSE, nullptr);
}

ZVRdpClient::~ZVRdpClient()
{
  stop();
  join();
  if (wakeEvent_)
    (void)CloseHandle(wakeEvent_);
}

void ZVRdpClient::start()
{
  thread_ = std::thread([this]() { run(); });
}

void ZVRdpClient::stop()
{
  stopRequested_ = true;
  {
    std::lock_guard<std::mutex> lock(taskMutex_);
    if (context_)
      freerdp_abort_connect_context(&context_->common.context);
  }
  if (wakeEvent_)
    (void)SetEvent(wakeEvent_);
}

void ZVRdpClient::join()
{
  if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id())
    thread_.join();
}

void ZVRdpClient::post(std::function<void()> task)
{
  {
    std::lock_guard<std::mutex> lock(taskMutex_);
    tasks_.push_back(std::move(task));
  }
  (void)SetEvent(wakeEvent_);
}

void ZVRdpClient::runTasks()
{
  std::vector<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(taskMutex_);
    tasks.swap(tasks_);
    (void)ResetEvent(wakeEvent_);
  }
  for (auto& t : tasks)
    t();
}

std::string ZVRdpClient::connectionInfo()
{
  std::lock_guard<std::mutex> lock(infoMutex_);
  return info_;
}

void ZVRdpClient::run()
{
  delegate_->willConnect();

  RDP_CLIENT_ENTRY_POINTS entry;
  memset(&entry, 0, sizeof(entry));
  entry.Version = RDP_CLIENT_INTERFACE_VERSION;
  entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
  entry.ContextSize = sizeof(ZVRdpContext);
  entry.ClientNew = ZVRdpCallbacks::clientNew;
  entry.ClientFree = ZVRdpCallbacks::clientFree;

  rdpContext* context = freerdp_client_context_new(&entry);
  if (!context) {
    delegate_->closed(CloseError, "Unable to set up the RDP connection.");
    return;
  }
  ZVRdpContext* ctx = (ZVRdpContext*)context;
  ctx->owner = this;
  {
    std::lock_guard<std::mutex> lock(taskMutex_);
    context_ = ctx;
  }

  rdpSettings* s = context->settings;
  std::string user = options_.username, domain;
  size_t slash = user.find('\\');
  if (slash != std::string::npos) {
    domain = user.substr(0, slash);
    user = user.substr(slash + 1);
  }
  int w = std::max(200, std::min(8192, options_.width)) & ~1;
  int h = std::max(200, std::min(8192, options_.height));
  bool ok =
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, options_.host.c_str()) &&
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)options_.port) &&
    freerdp_settings_set_string(s, FreeRDP_Username, user.empty() ? nullptr : user.c_str()) &&
    freerdp_settings_set_string(s, FreeRDP_Domain, domain.empty() ? nullptr : domain.c_str()) &&
    freerdp_settings_set_string(s, FreeRDP_Password,
                                options_.password.empty() ? nullptr : options_.password.c_str()) &&
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)w) &&
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)h) &&
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32) &&
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, FALSE) &&
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE) &&
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, options_.clipboard ? TRUE : FALSE) &&
    freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE) &&
    freerdp_settings_set_uint32(s, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT) &&
    freerdp_settings_set_bool(s, FreeRDP_AllowFontSmoothing, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_AllowDesktopComposition, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_HasHorizontalWheel, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_HasExtendedMouseEvent, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_UnicodeInput, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_ExternalCertificateManagement, TRUE) &&
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE) &&
    freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, FALSE) &&
    freerdp_settings_set_string(s, FreeRDP_ClientHostname, "ZeonRemote");
  if (ok && options_.scalePercent > 100) {
    ok = freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, (UINT32)options_.scalePercent) &&
         freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor,
                                     options_.scalePercent >= 180 ? 180 : 140);
  }

  CloseReason reason = CloseByUser;
  std::string message;
  bool established = false;

  if (!ok) {
    reason = CloseError;
    message = "Invalid connection settings.";
  } else if (freerdp_client_start(context) != 0) {
    reason = CloseError;
    message = "Unable to start the RDP client.";
  } else {
    freerdp* instance = context->instance;
    if (stopRequested_ || !freerdp_connect(instance)) {
      UINT32 err = freerdp_get_last_error(context);
      if (stopRequested_ || err == FREERDP_ERROR_CONNECT_CANCELLED) {
        reason = stopRequested_ ? CloseByUser : CloseAuthCancelled;
      } else if (err == FREERDP_ERROR_AUTHENTICATION_FAILED ||
                 err == FREERDP_ERROR_CONNECT_LOGON_FAILURE ||
                 err == FREERDP_ERROR_CONNECT_WRONG_PASSWORD ||
                 err == FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS ||
                 err == FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION ||
                 err == FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED ||
                 err == FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT ||
                 err == FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED ||
                 err == FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED ||
                 err == FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE ||
                 err == FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED ||
                 err == FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED) {
        reason = CloseAuthFailed;
        message = freerdp_get_last_error_string(err);
      } else if (err == FREERDP_ERROR_TLS_CONNECT_FAILED &&
                 freerdp_get_last_error(context) == FREERDP_ERROR_TLS_CONNECT_FAILED) {
        reason = CloseConnectFailed;
        message = freerdp_get_last_error_string(err);
      } else {
        reason = CloseConnectFailed;
        message = freerdp_get_last_error_string(err);
      }
      if (message.empty() && reason != CloseByUser && reason != CloseAuthCancelled)
        message = "Unable to connect to " + options_.host + ".";
    } else {
      established = true;
      HANDLE handles[MAXIMUM_WAIT_OBJECTS];
      while (!stopRequested_ && !freerdp_shall_disconnect_context(context)) {
        runTasks();
        DWORD n = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles) - 1);
        if (n == 0) {
          reason = CloseError;
          message = "Internal error (no event handles).";
          break;
        }
        handles[n++] = wakeEvent_;
        DWORD status = WaitForMultipleObjects(n, handles, FALSE, 1000);
        if (status == WAIT_FAILED) {
          reason = CloseError;
          message = "Internal error (wait failed).";
          break;
        }
        if (!freerdp_check_event_handles(context))
          break;
      }
      if (!stopRequested_ && message.empty()) {
        UINT32 info = freerdp_error_info(instance);
        UINT32 err = freerdp_get_last_error(context);
        reason = CloseByServer;
        if (info != 0 && info != ERRINFO_LOGOFF_BY_USER)
          message = freerdp_get_error_info_string(info);
        else if (err != FREERDP_ERROR_SUCCESS)
          message = freerdp_get_last_error_string(err);
        else
          message = "The remote session was closed.";
      }
    }
    freerdp_disconnect(instance);
    (void)freerdp_client_stop(context);
  }
  (void)established;

  {
    std::lock_guard<std::mutex> lock(taskMutex_);
    context_ = nullptr;
  }
  freerdp_client_context_free(context);
  delegate_->closed(reason, message);
}

// --- Input

void ZVRdpClient::sendPointer(int x, int y, uint16_t buttons)
{
  post([this, x, y, buttons]() {
    ZVRdpContext* ctx = context_;
    if (!ctx || !ctx->common.context.input)
      return;
    rdpInput* input = ctx->common.context.input;
    UINT16 px = (UINT16)std::max(0, std::min(x, 0xffff));
    UINT16 py = (UINT16)std::max(0, std::min(y, 0xffff));
    uint16_t changed = buttons ^ buttons_;
    uint16_t pressed = buttons & changed;

    (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, px, py);

    struct { uint16_t bit; UINT16 flag; } map[] = {
      { ButtonLeft, PTR_FLAGS_BUTTON1 },
      { ButtonRight, PTR_FLAGS_BUTTON2 },
      { ButtonMiddle, PTR_FLAGS_BUTTON3 },
    };
    for (auto& m : map) {
      if (changed & m.bit)
        (void)freerdp_input_send_mouse_event(input, (UINT16)(m.flag | ((buttons & m.bit) ? PTR_FLAGS_DOWN : 0)),
                                             px, py);
    }
    if (changed & ButtonBack)
      (void)freerdp_input_send_extended_mouse_event(
        input, (UINT16)(PTR_XFLAGS_BUTTON1 | ((buttons & ButtonBack) ? PTR_XFLAGS_DOWN : 0)), px, py);
    if (changed & ButtonForward)
      (void)freerdp_input_send_extended_mouse_event(
        input, (UINT16)(PTR_XFLAGS_BUTTON2 | ((buttons & ButtonForward) ? PTR_XFLAGS_DOWN : 0)), px, py);

    // Wheel "buttons" are pressed and released for each step
    const int step = 120;
    if (pressed & WheelUp)
      (void)freerdp_input_send_mouse_event(input, (UINT16)(PTR_FLAGS_WHEEL | (step & 0x1ff)), px, py);
    if (pressed & WheelDown)
      (void)freerdp_input_send_mouse_event(input, (UINT16)(PTR_FLAGS_WHEEL | (-step & 0x1ff)), px, py);
    if (pressed & WheelRight)
      (void)freerdp_input_send_mouse_event(input, (UINT16)(PTR_FLAGS_HWHEEL | (step & 0x1ff)), px, py);
    if (pressed & WheelLeft)
      (void)freerdp_input_send_mouse_event(input, (UINT16)(PTR_FLAGS_HWHEEL | (-step & 0x1ff)), px, py);

    buttons_ = buttons;
  });
}

void ZVRdpClient::sendScancode(uint32_t qnum, bool down)
{
  post([this, qnum, down]() {
    ZVRdpContext* ctx = context_;
    if (!ctx || !ctx->common.context.input || qnum == 0)
      return;
    UINT32 sc = MAKE_RDP_SCANCODE(qnum & 0x7f, (qnum & 0x80) != 0);
    auto it = std::find(pressed_.begin(), pressed_.end(), qnum);
    bool repeat = down && it != pressed_.end();
    if (down && it == pressed_.end())
      pressed_.push_back(qnum);
    if (!down && it != pressed_.end())
      pressed_.erase(it);
    (void)freerdp_input_send_keyboard_event_ex(ctx->common.context.input, down ? TRUE : FALSE,
                                               repeat ? TRUE : FALSE, sc);
  });
}

void ZVRdpClient::sendUnicode(uint32_t ch, bool down)
{
  post([this, ch, down]() {
    ZVRdpContext* ctx = context_;
    if (!ctx || !ctx->common.context.input || ch == 0)
      return;
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    rdpInput* input = ctx->common.context.input;
    if (ch > 0xffff) {
      uint32_t v = ch - 0x10000;
      (void)freerdp_input_send_unicode_keyboard_event(input, flags, (UINT16)(0xd800 + (v >> 10)));
      (void)freerdp_input_send_unicode_keyboard_event(input, flags, (UINT16)(0xdc00 + (v & 0x3ff)));
    } else {
      (void)freerdp_input_send_unicode_keyboard_event(input, flags, (UINT16)ch);
    }
  });
}

void ZVRdpClient::releaseAllKeys()
{
  post([this]() {
    ZVRdpContext* ctx = context_;
    if (!ctx || !ctx->common.context.input)
      return;
    for (uint32_t qnum : pressed_)
      (void)freerdp_input_send_keyboard_event_ex(ctx->common.context.input, FALSE, FALSE,
                                                 MAKE_RDP_SCANCODE(qnum & 0x7f, (qnum & 0x80) != 0));
    pressed_.clear();
  });
}

void ZVRdpClient::requestSize(int width, int height)
{
  post([this, width, height]() {
    ZVRdpContext* ctx = context_;
    if (!ctx || !ctx->disp || !canResize_)
      return;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)(std::max(DISPLAY_CONTROL_MIN_MONITOR_WIDTH,
                                     std::min(DISPLAY_CONTROL_MAX_MONITOR_WIDTH, width)) & ~1);
    layout.Height = (UINT32)std::max(DISPLAY_CONTROL_MIN_MONITOR_HEIGHT,
                                     std::min(DISPLAY_CONTROL_MAX_MONITOR_HEIGHT, height));
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = (UINT32)std::max(100, options_.scalePercent);
    layout.DeviceScaleFactor = options_.scalePercent >= 180 ? 180
                             : options_.scalePercent > 100 ? 140 : 100;
    (void)ctx->disp->SendMonitorLayout(ctx->disp, 1, &layout);
  });
}

void ZVRdpClient::localClipboard(const std::string& utf8)
{
  post([this, utf8]() {
    ZVRdpContext* ctx = context_;
    if (!ctx)
      return;
    *ctx->localText = utf8;
    ctx->localTextAvailable = true;
    if (ctx->clipboardReady)
      (void)ZVRdpCallbacks::sendClientFormatList(ctx);
  });
}

// --- Connection callbacks

BOOL ZVRdpCallbacks::clientNew(freerdp* instance, rdpContext* context)
{
  ((ZVRdpContext*)context)->localText = new std::string();
  instance->PreConnect = preConnect;
  instance->PostConnect = postConnect;
  instance->PostDisconnect = postDisconnect;
  instance->AuthenticateEx = authenticate;
  instance->VerifyX509Certificate = verifyX509;
  instance->LogonErrorInfo = logonErrorInfo;
  instance->GetAccessToken = client_failsafe_get_access_token;
  return TRUE;
}

void ZVRdpCallbacks::clientFree(freerdp* instance, rdpContext* context)
{
  (void)instance;
  ZVRdpContext* ctx = (ZVRdpContext*)context;
  delete ctx->localText;
  ctx->localText = nullptr;
}

BOOL ZVRdpCallbacks::preConnect(freerdp* instance)
{
  rdpContext* context = instance->context;
  rdpSettings* s = context->settings;
  if (!freerdp_settings_set_uint32(s, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
      !freerdp_settings_set_uint32(s, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
    return FALSE;
  if (PubSub_SubscribeChannelConnected(context->pubSub, channelConnected) < 0 ||
      PubSub_SubscribeChannelDisconnected(context->pubSub, channelDisconnected) < 0)
    return FALSE;
  return TRUE;
}

BOOL ZVRdpCallbacks::postConnect(freerdp* instance)
{
  rdpContext* context = instance->context;
  ZVRdpClient* self = owner(context);
  rdpSettings* s = context->settings;

  int w = (int)freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
  int h = (int)freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
  int stride = 0;
  uint8_t* buffer = self->delegate_->newFramebuffer(w, h, &stride);
  if (!buffer)
    return FALSE;
  if (!gdi_init_ex(instance, kFramebufferFormat, (UINT32)stride, buffer, nullptr))
    return FALSE;
  self->delegate_->framebufferReplaced();

  rdpPointer pointer;
  memset(&pointer, 0, sizeof(pointer));
  pointer.size = sizeof(ZVPointer);
  pointer.New = pointerNew;
  pointer.Free = pointerFree;
  pointer.Set = pointerSet;
  pointer.SetNull = pointerSetNull;
  pointer.SetDefault = pointerSetDefault;
  pointer.SetPosition = pointerSetPosition;
  graphics_register_pointer(context->graphics, &pointer);

  rdpUpdate* update = context->update;
  update->BeginPaint = beginPaint;
  update->EndPaint = endPaint;
  update->DesktopResize = desktopResize;
  update->PlaySound = playSound;

  UINT32 proto = freerdp_settings_get_uint32(s, FreeRDP_SelectedProtocol);
  self->secure_ = proto != 0;   // TLS, NLA or RDSTLS; 0 is legacy RDP encryption
  {
    std::lock_guard<std::mutex> lock(self->infoMutex_);
    const char* security = (proto & kProtocolHybridEx) ? "NLA (CredSSP, extended)"
                         : (proto & kProtocolHybrid)    ? "NLA (CredSSP)"
                         : (proto & kProtocolRDSTLS)    ? "RDSTLS"
                         : (proto & kProtocolSSL)       ? "TLS"
                                                        : "Standard RDP encryption";
    char line[256];
    self->info_.clear();
    snprintf(line, sizeof(line), "Server: %s:%u\n", freerdp_settings_get_string(s, FreeRDP_ServerHostname),
             freerdp_settings_get_uint32(s, FreeRDP_ServerPort));
    self->info_ += line;
    snprintf(line, sizeof(line), "Protocol: RDP (FreeRDP %s)\n", freerdp_get_version_string());
    self->info_ += line;
    snprintf(line, sizeof(line), "Security: %s\n", security);
    self->info_ += line;
  }

  std::string name = freerdp_settings_get_string(s, FreeRDP_ServerHostname) ?: "";
  self->delegate_->connected(name);
  return TRUE;
}

void ZVRdpCallbacks::postDisconnect(freerdp* instance)
{
  rdpContext* context = instance->context;
  if (!context)
    return;
  PubSub_UnsubscribeChannelConnected(context->pubSub, channelConnected);
  PubSub_UnsubscribeChannelDisconnected(context->pubSub, channelDisconnected);
  gdi_free(instance);
}

BOOL ZVRdpCallbacks::authenticate(freerdp* instance, char** user, char** password, char** domain,
                                  rdp_auth_reason reason)
{
  ZVRdpClient* self = owner(instance->context);
  switch (reason) {
  case AUTH_NLA:
  case AUTH_TLS:
  case AUTH_RDP:
  case AUTH_RDSTLS:
    break;
  default:
    return FALSE;   // gateways, smart cards: not supported
  }

  std::string u = *user ? *user : "";
  if (*domain && **domain)
    u = std::string(*domain) + "\\" + u;
  std::string p = *password ? *password : "";
  if (!self->delegate_->credentials(self->authRetry_, &u, &p))
    return FALSE;
  self->authRetry_ = true;

  std::string d;
  size_t slash = u.find('\\');
  if (slash != std::string::npos) {
    d = u.substr(0, slash);
    u = u.substr(slash + 1);
  }
  free(*user);
  free(*password);
  free(*domain);
  *user = dupString(u);
  *password = dupString(p);
  *domain = dupString(d);
  return TRUE;
}

// Every certificate comes here (ExternalCertificateManagement): trust is
// decided by Zeon Remote per device, like VNC TLS certificates, and nothing is
// stored in FreeRDP's known_hosts
int ZVRdpCallbacks::verifyX509(freerdp* instance, const BYTE* data, size_t length,
                               const char* hostname, UINT16 port, DWORD flags)
{
  (void)hostname; (void)port; (void)flags;
  ZVRdpClient* self = owner(instance->context);
  std::string pem((const char*)data, length);
  rdpCertificate* cert = freerdp_certificate_new_from_pem(pem.c_str());
  if (!cert)
    return 0;
  std::string identity, subject, issuer;
  char* hex = freerdp_certificate_get_fingerprint_by_hash_ex(cert, "sha256", FALSE);
  if (hex)
    identity = "x509:" + plainHex(hex);
  free(hex);
  char* sub = freerdp_certificate_get_subject(cert);
  char* iss = freerdp_certificate_get_issuer(cert);
  subject = sub ? sub : "";
  issuer = iss ? iss : "";
  free(sub);
  free(iss);
  freerdp_certificate_free(cert);
  if (identity.empty())
    return 0;
  return self->delegate_->verifyCertificate(identity, subject, issuer, false) ? 1 : 0;
}

int ZVRdpCallbacks::logonErrorInfo(freerdp* instance, UINT32 data, UINT32 type)
{
  (void)instance; (void)data; (void)type;
  return 1;
}

// --- Drawing

BOOL ZVRdpCallbacks::beginPaint(rdpContext* context)
{
  rdpGdi* gdi = context->gdi;
  HGDI_WND hwnd = gdi->primary->hdc->hwnd;
  hwnd->invalid->null = TRUE;
  hwnd->ninvalid = 0;
  owner(context)->delegate_->beginUpdate();
  return TRUE;
}

BOOL ZVRdpCallbacks::endPaint(rdpContext* context)
{
  rdpGdi* gdi = context->gdi;
  HGDI_WND hwnd = gdi->primary->hdc->hwnd;
  ZVRdpClient* self = owner(context);
  if (hwnd->invalid->null) {
    self->delegate_->endUpdate(0, 0, 0, 0);
  } else {
    self->delegate_->endUpdate(hwnd->invalid->x, hwnd->invalid->y,
                               hwnd->invalid->w, hwnd->invalid->h);
  }
  return TRUE;
}

BOOL ZVRdpCallbacks::desktopResize(rdpContext* context)
{
  ZVRdpClient* self = owner(context);
  rdpSettings* s = context->settings;
  int w = (int)freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth);
  int h = (int)freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
  int stride = 0;
  uint8_t* buffer = self->delegate_->newFramebuffer(w, h, &stride);
  if (!buffer)
    return FALSE;
  if (!gdi_resize_ex(context->gdi, (UINT32)w, (UINT32)h, (UINT32)stride, kFramebufferFormat,
                     buffer, nullptr))
    return FALSE;
  self->delegate_->framebufferReplaced();
  return TRUE;
}

BOOL ZVRdpCallbacks::playSound(rdpContext* context, const PLAY_SOUND_UPDATE* sound)
{
  (void)sound;
  owner(context)->delegate_->bell();
  return TRUE;
}

// --- Pointer

BOOL ZVRdpCallbacks::pointerNew(rdpContext* context, rdpPointer* pointer)
{
  ZVPointer* p = (ZVPointer*)pointer;
  p->rgba = new std::vector<uint8_t>((size_t)pointer->width * pointer->height * 4);
  if (pointer->width == 0 || pointer->height == 0)
    return TRUE;
  return freerdp_image_copy_from_pointer_data(p->rgba->data(), kCursorFormat, 0, 0, 0,
                                              pointer->width, pointer->height,
                                              pointer->xorMaskData, pointer->lengthXorMask,
                                              pointer->andMaskData, pointer->lengthAndMask,
                                              pointer->xorBpp, &context->gdi->palette);
}

void ZVRdpCallbacks::pointerFree(rdpContext* context, rdpPointer* pointer)
{
  (void)context;
  ZVPointer* p = (ZVPointer*)pointer;
  delete p->rgba;
  p->rgba = nullptr;
}

BOOL ZVRdpCallbacks::pointerSet(rdpContext* context, rdpPointer* pointer)
{
  ZVPointer* p = (ZVPointer*)pointer;
  if (!p->rgba)
    return TRUE;
  owner(context)->delegate_->cursorChanged(p->rgba->data(), (int)pointer->width,
                                           (int)pointer->height, (int)pointer->xPos,
                                           (int)pointer->yPos);
  return TRUE;
}

BOOL ZVRdpCallbacks::pointerSetNull(rdpContext* context)
{
  owner(context)->delegate_->cursorChanged(nullptr, 0, 0, 0, 0);
  return TRUE;
}

BOOL ZVRdpCallbacks::pointerSetDefault(rdpContext* context)
{
  // Width -1: the system arrow
  owner(context)->delegate_->cursorChanged(nullptr, -1, -1, 0, 0);
  return TRUE;
}

BOOL ZVRdpCallbacks::pointerSetPosition(rdpContext* context, UINT32 x, UINT32 y)
{
  (void)context; (void)x; (void)y;
  return TRUE;
}

// --- Channels

void ZVRdpCallbacks::channelConnected(void* context, const ChannelConnectedEventArgs* e)
{
  ZVRdpContext* ctx = (ZVRdpContext*)context;
  if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    ctx->disp = (DispClientContext*)e->pInterface;
    ctx->disp->custom = ctx;
    ctx->disp->DisplayControlCaps = dispCaps;
  } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    CliprdrClientContext* clip = (CliprdrClientContext*)e->pInterface;
    ctx->cliprdr = clip;
    clip->custom = ctx;
    clip->MonitorReady = clipMonitorReady;
    clip->ServerCapabilities = clipServerCapabilities;
    clip->ServerFormatList = clipServerFormatList;
    clip->ServerFormatListResponse = clipServerFormatListResponse;
    clip->ServerFormatDataRequest = clipServerFormatDataRequest;
    clip->ServerFormatDataResponse = clipServerFormatDataResponse;
  } else {
    freerdp_client_OnChannelConnectedEventHandler(context, e);
  }
}

void ZVRdpCallbacks::channelDisconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
  ZVRdpContext* ctx = (ZVRdpContext*)context;
  if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    ctx->disp = nullptr;
    ctx->owner->canResize_ = false;
  } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    ctx->cliprdr = nullptr;
    ctx->clipboardReady = false;
  } else {
    freerdp_client_OnChannelDisconnectedEventHandler(context, e);
  }
}

UINT ZVRdpCallbacks::dispCaps(DispClientContext* disp, UINT32 maxMonitors, UINT32 maxA, UINT32 maxB)
{
  (void)maxMonitors; (void)maxA; (void)maxB;
  ZVRdpContext* ctx = (ZVRdpContext*)disp->custom;
  ctx->owner->canResize_ = true;
  return CHANNEL_RC_OK;
}

// --- Clipboard (plain text)

UINT ZVRdpCallbacks::sendClientFormatList(ZVRdpContext* ctx)
{
  if (!ctx->cliprdr)
    return CHANNEL_RC_OK;
  CLIPRDR_FORMAT format;
  memset(&format, 0, sizeof(format));
  format.formatId = CF_UNICODETEXT;
  CLIPRDR_FORMAT_LIST list;
  memset(&list, 0, sizeof(list));
  list.common.msgType = CB_FORMAT_LIST;
  list.numFormats = ctx->localTextAvailable ? 1 : 0;
  list.formats = &format;
  return ctx->cliprdr->ClientFormatList(ctx->cliprdr, &list);
}

UINT ZVRdpCallbacks::clipMonitorReady(CliprdrClientContext* clip, const CLIPRDR_MONITOR_READY* r)
{
  (void)r;
  ZVRdpContext* ctx = (ZVRdpContext*)clip->custom;
  CLIPRDR_GENERAL_CAPABILITY_SET general;
  memset(&general, 0, sizeof(general));
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
  general.version = CB_CAPS_VERSION_2;
  general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps;
  memset(&caps, 0, sizeof(caps));
  caps.cCapabilitiesSets = 1;
  caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
  UINT rc = clip->ClientCapabilities(clip, &caps);
  if (rc != CHANNEL_RC_OK)
    return rc;
  ctx->clipboardReady = true;
  return sendClientFormatList(ctx);
}

UINT ZVRdpCallbacks::clipServerCapabilities(CliprdrClientContext* clip, const CLIPRDR_CAPABILITIES* c)
{
  (void)clip; (void)c;
  return CHANNEL_RC_OK;
}

UINT ZVRdpCallbacks::clipServerFormatList(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list)
{
  CLIPRDR_FORMAT_LIST_RESPONSE response;
  memset(&response, 0, sizeof(response));
  response.common.msgType = CB_FORMAT_LIST_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = clip->ClientFormatListResponse(clip, &response);
  if (rc != CHANNEL_RC_OK)
    return rc;

  for (UINT32 i = 0; i < list->numFormats; i++) {
    if (list->formats[i].formatId == CF_UNICODETEXT) {
      CLIPRDR_FORMAT_DATA_REQUEST request;
      memset(&request, 0, sizeof(request));
      request.common.msgType = CB_FORMAT_DATA_REQUEST;
      request.requestedFormatId = CF_UNICODETEXT;
      return clip->ClientFormatDataRequest(clip, &request);
    }
  }
  return CHANNEL_RC_OK;
}

UINT ZVRdpCallbacks::clipServerFormatListResponse(CliprdrClientContext* clip,
                                                  const CLIPRDR_FORMAT_LIST_RESPONSE* r)
{
  (void)clip; (void)r;
  return CHANNEL_RC_OK;
}

UINT ZVRdpCallbacks::clipServerFormatDataRequest(CliprdrClientContext* clip,
                                                 const CLIPRDR_FORMAT_DATA_REQUEST* r)
{
  ZVRdpContext* ctx = (ZVRdpContext*)clip->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response;
  memset(&response, 0, sizeof(response));
  response.common.msgType = CB_FORMAT_DATA_RESPONSE;

  WCHAR* wide = nullptr;
  if (r->requestedFormatId == CF_UNICODETEXT && ctx->localTextAvailable) {
    // Windows wants CR LF line endings and a terminating null
    std::string text;
    for (char c : *ctx->localText) {
      if (c == '\n')
        text += '\r';
      if (c != '\r')
        text += c;
    }
    size_t len = 0;
    wide = ConvertUtf8ToWCharAlloc(text.c_str(), &len);
    if (wide) {
      response.common.msgFlags = CB_RESPONSE_OK;
      response.common.dataLen = (UINT32)((len + 1) * sizeof(WCHAR));
      response.requestedFormatData = (const BYTE*)wide;
    }
  }
  if (!wide)
    response.common.msgFlags = CB_RESPONSE_FAIL;
  UINT rc = clip->ClientFormatDataResponse(clip, &response);
  free(wide);
  return rc;
}

UINT ZVRdpCallbacks::clipServerFormatDataResponse(CliprdrClientContext* clip,
                                                  const CLIPRDR_FORMAT_DATA_RESPONSE* r)
{
  ZVRdpContext* ctx = (ZVRdpContext*)clip->custom;
  if (r->common.msgFlags != CB_RESPONSE_OK || !r->requestedFormatData)
    return CHANNEL_RC_OK;
  size_t chars = r->common.dataLen / sizeof(WCHAR);
  size_t len = 0;
  char* utf8 = ConvertWCharNToUtf8Alloc((const WCHAR*)r->requestedFormatData, chars, &len);
  if (!utf8)
    return CHANNEL_RC_OK;
  std::string text;
  for (size_t i = 0; i < len && utf8[i]; i++)
    if (utf8[i] != '\r')
      text += utf8[i];
  free(utf8);
  ctx->owner->delegate_->remoteClipboard(text);
  return CHANNEL_RC_OK;
}
