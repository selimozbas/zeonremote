// ZeonVNC - one VNC session
//
// The RFB protocol is handled by the core's rfb::CConnection running on a
// dedicated thread per session. The main thread never touches the
// CConnection directly; it posts tasks which the protocol thread runs
// between messages.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/if_ether.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <string.h>
#include <poll.h>
#include <sys/time.h>
#include <unistd.h>

#include <core/LogWriter.h>
#include <core/string.h>
#include <core/time.h>

#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>

#include <network/TcpSocket.h>

#include <rfb/CConnection.h>
#include <rfb/CMsgWriter.h>
#include <rfb/CSecurity.h>
#include <rfb/Exception.h>
#include <rfb/ScreenSet.h>
#include <rfb/Security.h>
#include <rfb/encodings.h>

#define XK_LATIN1
#define XK_MISCELLANY
#include <rfb/keysymdef.h>

#include "keysym2ucs.h"

#import <CommonCrypto/CommonDigest.h>

#import "ZVSession.h"
#import "ZVPreferences.h"
#import "ZVNetUtil.h"
#import "ZVTrust.h"
#include "ZVFramebuffer.h"

static core::LogWriter vlog("ZVSession");

static const rfb::PixelFormat verylowColourPF(8, 3, false, true, 1, 1, 1, 2, 1, 0);
static const rfb::PixelFormat lowColourPF(8, 6, false, true, 3, 3, 3, 4, 2, 0);
static const rfb::PixelFormat mediumColourPF(8, 8, false, true, 7, 7, 3, 5, 2, 0);

// Time new bandwidth estimates are weighted against (in ms)
static const unsigned bpsEstimateWindow = 1000;

// Settings copied from the bookmark, owned by the protocol thread
struct ZVOptions {
  std::string host;
  bool shared = true;
  ZVQualityPreset quality = ZVQualityAuto;
  ZVEncoding encoding = ZVEncodingTight;
  int jpegQuality = 8;
  int compressLevel = 2;
  ZVColorDepth colorDepth = ZVColorFull;
  std::string username;
  int fd = -1;   // already connected socket (reverse connection)
};

static ZVOptions optionsFromBookmark(ZVBookmark* b)
{
  ZVOptions o;
  o.host = b.host.UTF8String;
  o.shared = b.shared;
  o.quality = b.quality;
  o.encoding = b.encoding;
  o.jpegQuality = (int)b.jpegQuality;
  o.compressLevel = (int)b.compressLevel;
  o.colorDepth = b.colorDepth;
  o.username = b.username.UTF8String;
  return o;
}

#import "ZVSession+Private.h"
#ifdef ZV_RDP
#import "ZVRDPSession.h"
#endif

static NSString* nsstr(const char* s)
{
  if (s == nullptr)
    return @"";
  NSString* r = [NSString stringWithUTF8String:s];
  if (r == nil)
    r = [NSString stringWithCString:s encoding:NSISOLatin1StringEncoding];
  return r ?: @"";
}

static std::string sha256Hex(const uint8_t* data, size_t len)
{
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data, (CC_LONG)len, digest);
  std::string hex;
  for (unsigned char c : digest)
    hex += core::format("%02x", c);
  return hex;
}

#pragma mark - Protocol connection (C++)

class ZVConnection : public rfb::CConnection,
                     public std::enable_shared_from_this<ZVConnection>
{
public:
  ZVConnection(ZVSession* session, const ZVOptions& opts)
    : bytesReceived(0), updateCount(0), pixelCount(0),
      lastServerEncoding(-1), bpsEstimate(20000000), currentQuality(-1),
      session_(session), options(opts), sock(nullptr), fb(nullptr),
      stopRequested(false), established(false), inUpdate(false),
      redrawPending(false), fullColourPF(ZVFramebuffer::nativePF()),
      pendingPointer(false), pointerMask(0)
  {
    if (pipe(wakePipe) != 0)
      throw std::runtime_error("pipe() failed");
    fcntl(wakePipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wakePipe[1], F_SETFL, O_NONBLOCK);

    setShared(options.shared);

    supportsLocalCursor = true;
    supportsCursorPosition = false;
    supportsDesktopResize = true;
    supportsLEDState = false;
  }

  ~ZVConnection() override
  {
    if (options.fd >= 0)
      ::close(options.fd);
    ::close(wakePipe[0]);
    ::close(wakePipe[1]);
  }

  void start()
  {
    std::shared_ptr<ZVConnection> self = shared_from_this();
    std::thread([self]() { self->run(); }).detach();
  }

  void stop()
  {
    stopRequested = true;
    wake();
  }

  // Runs a task on the protocol thread
  void post(std::function<void()> task)
  {
    {
      std::lock_guard<std::mutex> lock(taskMutex);
      tasks.push_back(std::move(task));
    }
    wake();
  }

  // Pointer motion is coalesced; button changes are never dropped
  void postPointer(const core::Point& pos, uint16_t mask)
  {
    {
      std::lock_guard<std::mutex> lock(taskMutex);
      if (pendingPointer && mask != pointerMask) {
        core::Point p = pointerPos;
        uint16_t m = pointerMask;
        tasks.push_back([this, p, m]() { writePointer(p, m); });
      }
      pendingPointer = true;
      pointerPos = pos;
      pointerMask = mask;
    }
    wake();
  }

  // Stats (read from the main thread)
  std::atomic<unsigned long long> bytesReceived;
  std::atomic<unsigned> updateCount;
  std::atomic<unsigned long long> pixelCount;
  std::atomic<int> lastServerEncoding;
  std::atomic<unsigned long long> bpsEstimate;
  std::atomic<int> currentQuality;

  // Only valid once connected; read on the main thread for display
  std::mutex infoMutex;
  std::string infoText;
  bool secure = false;
  bool canResize = false;

  // Protocol thread only
  std::string localClipboard;

  void applyOptions(const ZVOptions& o)
  {
    int fd = options.fd;
    options = o;
    options.fd = fd;
    updateEncoding();
    updateCompressLevel();
    updateQualityLevel();
    updatePixelFormat();
  }

  void doRemoteResize(int width, int height)
  {
    if (state() != RFBSTATE_NORMAL || !server.supportsSetDesktopSize)
      return;
    if (width < 1 || height < 1)
      return;
    if (width == server.width() && height == server.height())
      return;

    rfb::ScreenSet layout = server.screenLayout();
    if (layout.num_screens() == 0)
      layout.add_screen(rfb::Screen());
    else {
      // Only a single screen is supported for now
      while (layout.num_screens() > 1) {
        rfb::ScreenSet::iterator it = layout.begin();
        ++it;
        layout.remove_screen(it->id);
      }
    }
    layout.begin()->dimensions.tl.x = 0;
    layout.begin()->dimensions.tl.y = 0;
    layout.begin()->dimensions.br.x = width;
    layout.begin()->dimensions.br.y = height;

    vlog.info("Requesting remote resize to %dx%d", width, height);
    writer()->writeSetDesktopSize(width, height, layout);
  }

  void writePointer(const core::Point& pos, uint16_t mask)
  {
    if (state() != RFBSTATE_NORMAL)
      return;
    if (!server.supportsExtendedMouseButtons)
      mask &= 0x7f;
    writer()->writePointerEvent(pos, mask);
  }

private:
  __weak ZVSession* session_;
  ZVOptions options;
  network::Socket* sock;
  ZVFramebuffer* fb;

  std::atomic<bool> stopRequested;
  bool established;
  bool inUpdate;
  std::atomic<bool> redrawPending;
  rfb::PixelFormat fullColourPF;

  int wakePipe[2];
  std::mutex taskMutex;
  std::deque<std::function<void()>> tasks;
  bool pendingPointer;
  core::Point pointerPos;
  uint16_t pointerMask;

  struct timeval updateStartTime;
  size_t updateStartPos;

  // Identity of the device behind the address (see serverIdentity())
  std::string macIdentity;
  std::string keyIdentity;

  // The ARP entry normally exists as soon as the TCP connection is up,
  // but it can briefly be missing (e.g. while being refreshed)
  void lookupMAC()
  {
    if (!macIdentity.empty() || sock == nullptr)
      return;
    NSString* mac = ZVMACAddressOfPeer(sock->getFd());
    if (mac)
      macIdentity = [mac substringFromIndex:4].UTF8String;
    if (!macIdentity.empty())
      vlog.info("Device MAC address: %s", macIdentity.c_str());
  }

  NSString* macIdentityString()
  {
    return macIdentity.empty() ? nil : nsstr(("mac:" + macIdentity).c_str());
  }

  NSString* keyIdentityString()
  {
    return keyIdentity.empty() ? nil : nsstr(keyIdentity.c_str());
  }

  void wake()
  {
    char c = 0;
    (void)!write(wakePipe[1], &c, 1);
  }

  void drainWake()
  {
    char buf[64];
    while (read(wakePipe[0], buf, sizeof(buf)) > 0)
      ;
  }

  void runTasks()
  {
    std::deque<std::function<void()>> todo;
    bool havePointer;
    core::Point pos;
    uint16_t mask;
    {
      std::lock_guard<std::mutex> lock(taskMutex);
      todo.swap(tasks);
      havePointer = pendingPointer;
      pos = pointerPos;
      mask = pointerMask;
      pendingPointer = false;
    }
    for (auto& t : todo)
      t();
    if (havePointer)
      writePointer(pos, mask);
  }

  // Runs a block on the main thread with the session, if it still exists.
  // Never capture "this" in these blocks; the connection may be gone by
  // the time they run.
  void onMain(void (^block)(ZVSession* s))
  {
    __weak ZVSession* weakSession = session_;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZVSession* s = weakSession;
      if (s)
        block(s);
    });
  }

  void run()
  {
    ZVCloseReason reason = ZVCloseByServer;
    std::string message;

    @autoreleasepool {
      try {
        std::string host;
        int port;

        onMain(^(ZVSession* s){ [s _setState:ZVSessionConnecting]; });

        if (options.fd >= 0) {
          // Reverse connection accepted by the listener
          sock = new network::TcpSocket(options.fd);
          options.fd = -1;
          host = sock->getPeerAddress();
          vlog.info("Accepted reverse connection from %s", host.c_str());
        } else {
          network::getHostAndPort(options.host.c_str(), &host, &port);
          // macOS may reject the first connection to the local network
          // with EHOSTUNREACH while it checks the Local Network privacy
          // permission, so retry that error for a few seconds.
          for (int attempt = 0; sock == nullptr; attempt++) {
            try {
              sock = new network::TcpSocket(host.c_str(), port);
            } catch (std::exception& e) {
              bool unreachable = strstr(e.what(), "(65)") != nullptr;
              if (unreachable && attempt < 8 && !stopRequested) {
                vlog.info("Host unreachable, retrying (%d)", attempt + 1);
                usleep(500000);
                continue;
              }
              throw std::runtime_error(core::format("Unable to connect to %s:%d\n\n%s",
                                                    host.c_str(), port, e.what()));
            }
          }
          vlog.info("Connected to host %s port %d", host.c_str(), port);
        }

        if (stopRequested)
          throw rfb::auth_cancelled();

        lookupMAC();

        onMain(^(ZVSession* s){ [s _setState:ZVSessionAuthenticating]; });

        setServerName(host.c_str());
        setStreams(&sock->inStream(), &sock->outStream());
        initialiseProtocol();

        eventLoop();
        reason = ZVCloseByUser;
      } catch (rdr::end_of_stream& e) {
        vlog.info("%s", e.what());
        if (!established) {
          reason = ZVCloseError;
          message = "The connection was dropped by the server before the session could be established.";
        } else {
          reason = ZVCloseByServer;
          message = "The connection was closed by the server.";
        }
      } catch (rfb::auth_cancelled& e) {
        reason = stopRequested ? ZVCloseByUser : ZVCloseAuthCancelled;
      } catch (rfb::auth_error& e) {
        vlog.error("Authentication failed: %s", e.what());
        reason = ZVCloseAuthFailed;
        message = e.what();
      } catch (std::exception& e) {
        vlog.error("%s", e.what());
        if (stopRequested) {
          reason = ZVCloseByUser;
        } else {
          reason = (sock == nullptr) ? ZVCloseConnectFailed : ZVCloseError;
          message = e.what();
        }
      }

      // Tear down the protocol first: security layers such as TLS still
      // talk to the socket when they are closed, so it must outlive them
      try {
        close();
      } catch (std::exception& e) {
        vlog.debug("Error while closing: %s", e.what());
      }
      fb = nullptr;   // deleted by close()

      shutdownSocket();

      NSString* msg = message.empty() ? nil : nsstr(message.c_str());
      ZVCloseReason r = reason;
      onMain(^(ZVSession* s){ [s _closed:r message:msg]; });
    }
  }

  void eventLoop()
  {
    while (!stopRequested) {
      runTasks();
      sock->outStream().flush();

      struct pollfd fds[2];
      fds[0].fd = sock->getFd();
      fds[0].events = POLLIN;
      if (sock->outStream().hasBufferedData())
        fds[0].events |= POLLOUT;
      fds[0].revents = 0;
      fds[1].fd = wakePipe[0];
      fds[1].events = POLLIN;
      fds[1].revents = 0;

      int n = poll(fds, 2, 1000);
      if (n < 0) {
        if (errno == EINTR)
          continue;
        throw std::runtime_error("poll() failed");
      }

      if (fds[1].revents)
        drainWake();

      if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
        getOutStream()->cork(true);
        while (processMsg()) {
          if (stopRequested)
            break;
          // Keep input responsive during long bursts of updates
          runTasks();
        }
        getOutStream()->cork(false);
      }

      bytesReceived = sock->inStream().pos();
    }

    close();
  }

  void shutdownSocket()
  {
    if (sock == nullptr)
      return;

    try {
      sock->outStream().flush();
    } catch (std::exception&) {
    }
    sock->shutdown();

    // Graceful close: give the peer a moment to finish (max 250 ms)
    struct timeval start;
    gettimeofday(&start, nullptr);
    while (core::msSince(&start) < 250) {
      bool done = false;
      while (true) {
        try {
          sock->inStream().skip(sock->inStream().avail());
          if (!sock->inStream().hasData(1))
            break;
        } catch (std::exception&) {
          done = true;
          break;
        }
      }
      if (done)
        break;
      usleep(10000);
    }

    delete sock;
    sock = nullptr;
  }

  // -- CConnection callbacks --

  bool showMsgBox(rfb::MsgBoxFlags flags, const char* title,
                  const char* text) override
  {
    __block BOOL result = NO;
    NSString* t = nsstr(title);
    NSString* m = nsstr(text);
    BOOL yesNo = (flags & (rfb::M_OKCANCEL | rfb::M_YESNO)) != 0;
    NSAlertStyle style = NSAlertStyleInformational;
    if ((flags & 0xf0) == rfb::M_ICONERROR)
      style = NSAlertStyleCritical;
    else if ((flags & 0xf0) == rfb::M_ICONWARNING)
      style = NSAlertStyleWarning;

    ZVSession* s = session_;
    dispatch_sync(dispatch_get_main_queue(), ^{
      result = [s _message:m title:t yesNo:yesNo style:style];
    });
    return result;
  }

  void serverIdentity(const char* type, const uint8_t* data,
                      size_t len) override
  {
    keyIdentity = std::string(type) + ":" + sha256Hex(data, len);
    vlog.info("Server key: %s", keyIdentity.c_str());
  }

  // Called when the key isn't trusted by a CA or the known hosts file.
  // Keys are trusted per device: the user confirms a key once, and is
  // told whether it belongs to a new device, a changed device (e.g.
  // re-installed) or a different device now using this address.
  bool verifyServerIdentity(const char* type, const uint8_t* data,
                            size_t len) override
  {
    std::string id = std::string(type) + ":" + sha256Hex(data, len);
    lookupMAC();
    __block BOOL ok = NO;
    ZVSession* s = session_;
    NSString* fp = nsstr(id.c_str());
    NSString* mac = macIdentityString();
    dispatch_sync(dispatch_get_main_queue(), ^{
      ok = [s _verifyServerKey:fp mac:mac];
    });
    if (!ok)
      throw rfb::auth_cancelled();
    return true;
  }

  void getUserPasswd(bool isSecure, std::string* user,
                     std::string* password) override
  {
    __block BOOL ok = NO;
    __block std::string u = options.username;
    __block std::string p;
    ZVSession* s = session_;
    bool needUser = user != nullptr;
    lookupMAC();
    NSString* mac = macIdentityString();
    NSString* key = keyIdentityString();
    dispatch_sync(dispatch_get_main_queue(), ^{
      ok = [s _credentialsUser:needUser secure:isSecure mac:mac key:key
                      username:&u password:&p];
    });
    if (!ok)
      throw rfb::auth_cancelled();

    options.username = u;
    if (user)
      *user = u;
    if (password)
      *password = p;
  }

  void initDone() override
  {
    established = true;

    // Old servers might send cursors in the middle of pixel format
    // changes, so start them in full colour
    fb = new ZVFramebuffer(server.width(), server.height());
    setFramebuffer(fb);
    notifyFramebuffer();

    updateEncoding();
    updateCompressLevel();
    updateQualityLevel();
    updatePixelFormat();
    updateInfo();

    NSString* name = nsstr(server.name());
    lookupMAC();
    NSString* mac = macIdentityString();
    NSString* key = keyIdentityString();
    onMain(^(ZVSession* s){ [s _didInitWithName:name mac:mac key:key]; });
  }

  void resizeFramebuffer() override
  {
    ZVFramebuffer* nfb = new ZVFramebuffer(server.width(), server.height());
    if (inUpdate)
      nfb->beginWrite();
    fb = nfb;
    setFramebuffer(nfb);  // deletes the old one
    notifyFramebuffer();
    updateInfo();
  }

  void notifyFramebuffer()
  {
    IOSurfaceRef surf = fb->surface();
    CFRetain(surf);
    int w = fb->width(), h = fb->height();
    onMain(^(ZVSession* s){
      [s _framebufferChanged:surf width:w height:h];
      CFRelease(surf);
    });
  }

  void setName(const char* name) override
  {
    CConnection::setName(name);
    NSString* n = nsstr(name);
    onMain(^(ZVSession* s){ [s _nameChanged:n]; });
  }

  void setExtendedDesktopSize(unsigned reason, unsigned result, int w, int h,
                              const rfb::ScreenSet& layout) override
  {
    CConnection::setExtendedDesktopSize(reason, result, w, h, layout);
    std::lock_guard<std::mutex> lock(infoMutex);
    canResize = server.supportsSetDesktopSize;
  }

  void bell() override
  {
    onMain(^(ZVSession* s){ [s _bell]; });
  }

  void framebufferUpdateStart() override
  {
    CConnection::framebufferUpdateStart();
    inUpdate = true;
    if (fb)
      fb->beginWrite();

    gettimeofday(&updateStartTime, nullptr);
    updateStartPos = sock->inStream().pos();
  }

  void framebufferUpdateEnd() override
  {
    CConnection::framebufferUpdateEnd();
    inUpdate = false;
    if (fb)
      fb->endWrite();

    updateCount++;

    // Bandwidth estimate: exponentially weighted by update duration
    struct timeval now;
    gettimeofday(&now, nullptr);
    unsigned long long elapsed = (now.tv_sec - updateStartTime.tv_sec) * 1000000ULL;
    elapsed += now.tv_usec - updateStartTime.tv_usec;
    if (elapsed == 0)
      elapsed = 1;
    unsigned long long bps = (unsigned long long)(sock->inStream().pos() - updateStartPos)
                             * 8 * 1000000 / elapsed;
    unsigned long long weight = elapsed * 1000 / bpsEstimateWindow;
    if (weight > 200000)
      weight = 200000;
    bpsEstimate = ((bpsEstimate * (1000000 - weight)) + (bps * weight)) / 1000000;

    if (!redrawPending.exchange(true)) {
      onMain(^(ZVSession* s){ [s _framebufferUpdated]; });
    }

    if (options.quality == ZVQualityAuto) {
      updateQualityLevel();
      updatePixelFormat();
    }
  }

public:
  void redrawDone() { redrawPending = false; }

private:
  bool dataRect(const core::Rect& r, int encoding) override
  {
    if (encoding != rfb::encodingCopyRect)
      lastServerEncoding = encoding;
    bool ret = CConnection::dataRect(r, encoding);
    if (ret)
      pixelCount += r.area();
    return ret;
  }

  void setCursor(int width, int height, const core::Point& hotspot,
                 const uint8_t* data) override
  {
    CConnection::setCursor(width, height, hotspot, data);

    NSData* rgba = [NSData dataWithBytes:data length:(size_t)width * height * 4];
    NSPoint hs = NSMakePoint(hotspot.x, hotspot.y);
    onMain(^(ZVSession* s){ [s _cursorChanged:rgba width:width height:height hotspot:hs]; });
  }

  void setCursorPos(const core::Point&) override {}

  void handleClipboardRequest() override
  {
    sendClipboardData(localClipboard.c_str());
  }

  void handleClipboardAnnounce(bool available) override
  {
    if (available)
      requestClipboard();
  }

  void handleClipboardData(const char* data) override
  {
    NSString* text = nsstr(data);
    onMain(^(ZVSession* s){ [s _remoteClipboard:text]; });
  }

  // -- Encoding selection --

  int presetQuality()
  {
    switch (options.quality) {
    case ZVQualityAuto:
      // Above 16 Mbps (LAN) use perceptually lossless JPEG
      return bpsEstimate > 16000000 ? 8 : 6;
    case ZVQualityLossless: return -1;
    case ZVQualityHigh:     return 8;
    case ZVQualityBalanced: return 6;
    case ZVQualityLow:      return 3;
    case ZVQualityCustom:   return options.jpegQuality;
    case ZVQualityVideo:    return 8;   // used if H.264 isn't available
    }
    return 8;
  }

  void updateEncoding()
  {
    int enc = rfb::encodingTight;
#ifdef HAVE_H264
    if (options.quality == ZVQualityVideo)
      enc = rfb::encodingH264;
#endif
    if (options.quality == ZVQualityCustom) {
      switch (options.encoding) {
      case ZVEncodingTight:   enc = rfb::encodingTight; break;
      case ZVEncodingZRLE:    enc = rfb::encodingZRLE; break;
      case ZVEncodingHextile: enc = rfb::encodingHextile; break;
      case ZVEncodingRaw:     enc = rfb::encodingRaw; break;
      case ZVEncodingH264:
#ifdef HAVE_H264
        enc = rfb::encodingH264;
#endif
        break;
      }
    }
    setPreferredEncoding(enc);
  }

  void updateCompressLevel()
  {
    int level = -1;
    switch (options.quality) {
    case ZVQualityAuto:     level = -1; break;
    case ZVQualityLossless: level = 1; break;
    case ZVQualityHigh:     level = 2; break;
    case ZVQualityBalanced: level = 6; break;
    case ZVQualityLow:      level = 9; break;
    case ZVQualityCustom:   level = options.compressLevel; break;
    case ZVQualityVideo:    level = -1; break;
    }
    setCompressLevel(level);
  }

  void updateQualityLevel()
  {
    int q = presetQuality();
    if (q != getQualityLevel() && options.quality == ZVQualityAuto)
      vlog.info("Throughput %d kbit/s - changing to quality %d",
                (int)(bpsEstimate / 1000), q);
    setQualityLevel(q);
    currentQuality = q;
  }

  void updatePixelFormat()
  {
    // Old (pre 3.8) servers can't handle format changes safely
    if (server.beforeVersion(3, 8))
      return;

    ZVColorDepth depth = ZVColorFull;
    if (options.quality == ZVQualityCustom)
      depth = options.colorDepth;
    else if (options.quality == ZVQualityAuto && bpsEstimate < 256000)
      depth = ZVColor256;

    rfb::PixelFormat pf;
    switch (depth) {
    case ZVColorFull: pf = fullColourPF; break;
    case ZVColor256:  pf = mediumColourPF; break;
    case ZVColor64:   pf = lowColourPF; break;
    case ZVColor8:    pf = verylowColourPF; break;
    }

    if (pf != server.pf()) {
      char str[256];
      pf.print(str, sizeof(str));
      vlog.info("Using pixel format %s", str);
      setPF(pf);
    }
  }

  void updateInfo()
  {
    std::string text;
    char pfStr[100];

    text += core::format("Desktop name: %.80s\n", server.name());
    text += core::format("Host: %.80s\n", options.host.c_str());
    text += core::format("Size: %d x %d\n", server.width(), server.height());
    server.pf().print(pfStr, sizeof(pfStr));
    text += core::format("Pixel format: %s\n", pfStr);
    text += core::format("Protocol version: %d.%d\n",
                         server.majorVersion, server.minorVersion);
    if (csecurity)
      text += core::format("Security method: %s\n",
                           rfb::secTypeName(csecurity->getType()));
    if (!macIdentity.empty())
      text += core::format("Device MAC address: %s\n", macIdentity.c_str());
    if (!keyIdentity.empty())
      text += core::format("Server key: %.24s…\n", keyIdentity.c_str());

    std::lock_guard<std::mutex> lock(infoMutex);
    infoText = text;
    secure = isSecure();
    canResize = server.supportsSetDesktopSize;
  }
};

#pragma mark - Session (Objective-C)

// Fake system key codes for synthesized key strokes
static const int kSyntheticKeyBase = 0x10000;

static uint32_t qnumForKeySym(uint32_t ks)
{
  switch (ks) {
  case XK_Control_L: return 0x1d;
  case XK_Control_R: return 0x9d;
  case XK_Alt_L:     return 0x38;
  case XK_Alt_R:     return 0xb8;
  case XK_Shift_L:   return 0x2a;
  case XK_Shift_R:   return 0x36;
  case XK_Super_L:   return 0xdb;
  case XK_Super_R:   return 0xdc;
  case XK_Delete:    return 0xd3;
  case XK_Escape:    return 0x01;
  case XK_Tab:       return 0x0f;
  case XK_Return:    return 0x1c;
  case XK_F4:        return 0x3e;
  case XK_Print:     return 0xb7;
  case XK_Menu:      return 0xdd;
  case XK_l:         return 0x26;
  case XK_r:         return 0x13;
  case XK_e:         return 0x12;
  case XK_d:         return 0x20;
  }
  return 0;
}

@implementation ZVSession {
  std::shared_ptr<ZVConnection> _conn;
  int _incomingFd;
  BOOL _isReverse;

  // Credentials
  NSString* _deviceIdentity;
  NSString* _pendingPassword;    // entered by the user, save once connected
  NSString* _pendingUsername;
  BOOL _forcePrompt;             // saved password was rejected
  NSString* _attemptUsername;    // credentials sent in this attempt
  NSString* _attemptPassword;
  NSString* _deviceMAC;
  IOSurfaceRef _surface;
  ZVSessionState _state;
  NSString* _desktopName;
  NSSize _fbSize;
  int _nextSynthetic;

  // Stats
  unsigned long long _lastBytes;
  unsigned _lastUpdates;
  unsigned long long _lastPixels;
  CFAbsoluteTime _lastStatsTime;
  ZVSessionStats _stats;
}

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark
{
  self = [super init];
  if (self) {
    _bookmark = [bookmark copy];
    _viewOnly = bookmark.viewOnly;
    _desktopName = @"";
    _state = ZVSessionIdle;
    _incomingFd = -1;
  }
  return self;
}

+ (ZVSession*)sessionWithBookmark:(ZVBookmark*)bookmark
{
#ifdef ZV_RDP
  if (bookmark.protocolType == ZVProtocolRDP)
    return [[ZVRDPSession alloc] initWithBookmark:bookmark];
#endif
  return [[ZVSession alloc] initWithBookmark:bookmark];
}

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark connectedSocket:(int)fd
{
  self = [self initWithBookmark:bookmark];
  if (self)
    _incomingFd = fd;
  return self;
}

- (BOOL)isReverseConnection
{
  return _isReverse;
}

- (void)dealloc
{
  if (_conn)
    _conn->stop();
  if (_incomingFd >= 0)
    close(_incomingFd);
  if (_surface)
    CFRelease(_surface);
}

- (ZVSessionState)state { return _state; }

// ZVFileTransferContext
- (NSString*)transferUsername { return _vncUsername; }
- (NSString*)transferPassword { return _vncPassword; }
- (NSString*)transferScope { return [_bookmark credentialScope]; }

- (NSString*)hostName
{
  std::string host;
  int port;
  try {
    network::getHostAndPort(_bookmark.host.UTF8String, &host, &port);
  } catch (std::exception&) {
    return _bookmark.host;
  }
  return nsstr(host.c_str());
}
- (NSString*)desktopName { return _desktopName; }
- (NSSize)framebufferSize { return _fbSize; }
- (IOSurfaceRef)surface { return _surface; }

- (void)connect
{
  if (_conn)
    return;

  ZVOptions opts = optionsFromBookmark(_bookmark);
  if (_incomingFd >= 0) {
    opts.fd = _incomingFd;
    _incomingFd = -1;
    _isReverse = YES;
  }
  _conn = std::make_shared<ZVConnection>(self, opts);

  _pendingPassword = nil;
  _pendingUsername = nil;

  _lastBytes = 0;
  _lastUpdates = 0;
  _lastPixels = 0;
  _lastStatsTime = CFAbsoluteTimeGetCurrent();
  memset(&_stats, 0, sizeof(_stats));

  _conn->start();
}

- (void)disconnect
{
  if (!_conn)
    return;
  _conn->stop();
}

- (void)applySettings:(ZVBookmark*)bookmark
{
  _bookmark = [bookmark copy];
  if (!_conn)
    return;
  ZVOptions opts = optionsFromBookmark(bookmark);
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c, opts]() {
    if (c->state() == rfb::CConnection::RFBSTATE_NORMAL)
      c->applyOptions(opts);
  });
}

#pragma mark Input

- (BOOL)canSendInput
{
  return _conn && _state == ZVSessionConnected && !_viewOnly;
}

- (void)sendPointer:(NSPoint)pos buttons:(uint16_t)mask
{
  if (![self canSendInput])
    return;
  int x = (int)pos.x, y = (int)pos.y;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= _fbSize.width) x = (int)_fbSize.width - 1;
  if (y >= _fbSize.height) y = (int)_fbSize.height - 1;
  _conn->postPointer(core::Point(x, y), mask);
}

- (void)sendKeyPress:(int)systemKeyCode keyCode:(uint32_t)keyCode keySym:(uint32_t)keySym
{
  if (![self canSendInput])
    return;
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c, systemKeyCode, keyCode, keySym]() {
    if (c->state() == rfb::CConnection::RFBSTATE_NORMAL)
      c->sendKeyPress(systemKeyCode, keyCode, keySym);
  });
}

- (void)sendKeyRelease:(int)systemKeyCode
{
  if (!_conn || _state != ZVSessionConnected)
    return;
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c, systemKeyCode]() {
    if (c->state() == rfb::CConnection::RFBSTATE_NORMAL)
      c->sendKeyRelease(systemKeyCode);
  });
}

- (void)releaseAllKeys
{
  if (!_conn || _state != ZVSessionConnected)
    return;
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c]() {
    if (c->state() == rfb::CConnection::RFBSTATE_NORMAL)
      c->releaseAllKeys();
  });
}

- (int)nextSyntheticCode
{
  _nextSynthetic = (_nextSynthetic + 1) % 0x8000;
  return kSyntheticKeyBase + _nextSynthetic;
}

- (void)sendKeyCombo:(NSArray<NSNumber*>*)keySyms
{
  if (![self canSendInput])
    return;
  std::vector<int> codes;
  for (NSNumber* n in keySyms) {
    uint32_t ks = n.unsignedIntValue;
    int code = [self nextSyntheticCode];
    codes.push_back(code);
    [self sendKeyPress:code keyCode:qnumForKeySym(ks) keySym:ks];
  }
  for (auto it = codes.rbegin(); it != codes.rend(); ++it)
    [self sendKeyRelease:*it];
}

- (void)typeText:(NSString*)text
{
  if (![self canSendInput])
    return;
  text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString* sub, NSRange r1, NSRange r2, BOOL* stop) {
    uint32_t ks;
    UTF32Char ch = 0;
    [sub getBytes:&ch maxLength:4 usedLength:NULL
         encoding:NSUTF32LittleEndianStringEncoding options:0
            range:NSMakeRange(0, sub.length) remainingRange:NULL];
    if (ch == '\n')
      ks = XK_Return;
    else if (ch == '\t')
      ks = XK_Tab;
    else
      ks = ucs2keysym(ch);
    if (ks == 0)
      return;
    int code = [self nextSyntheticCode];
    [self sendKeyPress:code keyCode:0 keySym:ks];
    [self sendKeyRelease:code];
  }];
}

- (void)refreshScreen
{
  if (!_conn || _state != ZVSessionConnected)
    return;
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c]() {
    if (c->state() == rfb::CConnection::RFBSTATE_NORMAL)
      c->refreshFramebuffer();
  });
}

- (BOOL)supportsRemoteResize
{
  if (!_conn || _state != ZVSessionConnected)
    return NO;
  std::lock_guard<std::mutex> lock(_conn->infoMutex);
  return _conn->canResize;
}

- (void)requestRemoteSize:(NSSize)size
{
  if (![self canSendInput])
    return;
  std::shared_ptr<ZVConnection> c = _conn;
  int w = (int)size.width, h = (int)size.height;
  c->post([c, w, h]() { c->doRemoteResize(w, h); });
}

- (void)localClipboardChanged:(NSString*)text
{
  if (![self canSendInput])
    return;
  std::string data;
  if (text) {
    // RFB wants plain LF line endings
    NSString* t = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    data = t.UTF8String ?: "";
  }
  bool available = text != nil;
  std::shared_ptr<ZVConnection> c = _conn;
  c->post([c, data, available]() {
    if (c->state() != rfb::CConnection::RFBSTATE_NORMAL)
      return;
    c->localClipboard = data;
    c->announceClipboard(available);
  });
}

#pragma mark Info

- (ZVSessionStats)stats
{
  if (!_conn)
    return _stats;

  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  double dt = now - _lastStatsTime;
  if (dt >= 0.5) {
    unsigned long long bytes = _conn->bytesReceived;
    unsigned updates = _conn->updateCount;
    unsigned long long pixels = _conn->pixelCount;
    _stats.kbitsPerSecond = (bytes - _lastBytes) * 8.0 / 1000.0 / dt;
    _stats.updatesPerSecond = (updates - _lastUpdates) / dt;
    _stats.megapixelsPerSecond = (pixels - _lastPixels) / 1e6 / dt;
    _lastBytes = bytes;
    _lastUpdates = updates;
    _lastPixels = pixels;
    _lastStatsTime = now;
  }
  _stats.totalBytes = _conn->bytesReceived;
  _stats.lineSpeedKbps = _conn->bpsEstimate / 1000;
  _stats.jpegQuality = _conn->currentQuality;
  _stats.lastEncoding = _conn->lastServerEncoding;
  return _stats;
}

+ (NSString*)nameForEncoding:(int)encoding
{
  if (encoding < 0)
    return @"-";
  return nsstr(rfb::encodingName(encoding));
}

- (NSString*)connectionInfo
{
  if (!_conn)
    return @"Not connected";
  std::string text;
  {
    std::lock_guard<std::mutex> lock(_conn->infoMutex);
    text = _conn->infoText;
  }
  ZVSessionStats s = [self stats];
  int enc = _conn->lastServerEncoding;
  text += core::format("Last used encoding: %s\n",
                       enc >= 0 ? rfb::encodingName(enc) : "-");
  if (s.jpegQuality >= 0)
    text += core::format("JPEG quality: %d\n", s.jpegQuality);
  else
    text += "JPEG quality: lossless\n";
  text += core::format("Line speed estimate: %llu kbit/s\n", s.lineSpeedKbps);
  text += core::format("Data received: %.1f MB\n", s.totalBytes / 1e6);
  return nsstr(text.c_str());
}

- (BOOL)isSecure
{
  if (!_conn)
    return NO;
  std::lock_guard<std::mutex> lock(_conn->infoMutex);
  return _conn->secure;
}

#pragma mark Callbacks from the protocol thread (main thread)

- (void)_setState:(ZVSessionState)state
{
  if (_state == state)
    return;
  _state = state;
  [_delegate session:self stateChanged:state];
}

- (BOOL)verifyServerKey:(NSString*)fingerprint display:(NSString*)display
{
  return [self _verifyServerKey:fingerprint mac:_deviceMAC];
}

- (BOOL)_verifyServerKey:(NSString*)fingerprint mac:(NSString*)mac
{
  return [ZVTrust verifyKey:fingerprint mac:mac scope:[_bookmark credentialScope]
                       host:_bookmark.host];
}

- (void)_didInitWithName:(NSString*)name mac:(NSString*)mac key:(NSString*)key
{
  ZVBookmarkStore* store = [ZVBookmarkStore sharedStore];
  NSString* scope = [_bookmark credentialScope];
  NSString* identity = [store canonicalIdentityForMAC:mac key:key];

  // Remember that this key belongs to this MAC, so the device is
  // recognised whichever of the two we can see next time
  if (mac && key)
    [store setAlias:mac forKey:key];

  _deviceIdentity = identity;
  _deviceMAC = mac;
  // Kept in memory for this session only, e.g. to log in to SSH on the
  // same device for file transfer
  _vncUsername = _attemptUsername;
  _vncPassword = _attemptPassword;
  _forcePrompt = NO;


  if (_pendingPassword) {
    // The password worked; remember it for this device
    if (identity)
      [ZVBookmarkStore setPassword:_pendingPassword forDevice:identity];
    else
      [_bookmark setStoredPassword:_pendingPassword];
  }
  _pendingPassword = nil;

  if (identity) {
    [store setIdentity:identity forScope:scope];
    [store noteDevice:identity name:name host:_bookmark.host username:_pendingUsername];
  }
  _pendingUsername = nil;

  _desktopName = name;
  [self _setState:ZVSessionConnected];
  [_delegate session:self desktopNameChanged:name];
}

- (void)_framebufferChanged:(IOSurfaceRef)surface width:(int)w height:(int)h
{
  if (_surface)
    CFRelease(_surface);
  _surface = (IOSurfaceRef)CFRetain(surface);
  _fbSize = NSMakeSize(w, h);
  [_delegate session:self framebufferChanged:surface];
}

- (void)_framebufferUpdated
{
  if (_conn)
    _conn->redrawDone();
  [_delegate sessionFramebufferUpdated:self];
}

- (void)_nameChanged:(NSString*)name
{
  _desktopName = name;
  [_delegate session:self desktopNameChanged:name];
}

- (void)_cursorChanged:(NSData*)rgba width:(int)w height:(int)h hotspot:(NSPoint)hs
{
  if (w <= 0 || h <= 0) {
    [_delegate session:self cursorChanged:nil hotspot:NSZeroPoint];
    return;
  }

  NSBitmapImageRep* rep =
    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                            pixelsWide:w pixelsHigh:h
                                         bitsPerSample:8 samplesPerPixel:4
                                              hasAlpha:YES isPlanar:NO
                                        colorSpaceName:NSDeviceRGBColorSpace
                                          bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                                           bytesPerRow:w * 4 bitsPerPixel:32];
  memcpy(rep.bitmapData, rgba.bytes, (size_t)w * h * 4);

  bool blank = true;
  const uint8_t* p = (const uint8_t*)rgba.bytes;
  for (int i = 0; i < w * h; i++) {
    if (p[i * 4 + 3] != 0) {
      blank = false;
      break;
    }
  }

  NSImage* img = nil;
  if (!blank) {
    img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img addRepresentation:rep];
  }
  [_delegate session:self cursorChanged:img hotspot:hs];
}

- (void)_remoteClipboard:(NSString*)text
{
  if (!_bookmark.shareClipboard)
    return;
  [_delegate session:self remoteClipboard:text];
}

- (void)_bell
{
  [_delegate sessionBell:self];
}

- (void)_closed:(ZVCloseReason)reason message:(NSString*)message
{
  // Never resend a password that was just rejected; ask instead. The
  // saved password is kept, since it may belong to another device that
  // used this address.
  if (reason == ZVCloseAuthFailed)
    _forcePrompt = YES;
  _pendingPassword = nil;
  _conn.reset();
  _state = ZVSessionDisconnected;
  [_delegate session:self closedWithReason:reason message:message];
}

- (BOOL)_credentialsUser:(BOOL)needUser secure:(BOOL)secure
                     mac:(NSString*)mac key:(NSString*)key
                username:(std::string*)user password:(std::string*)pass
{
  ZVBookmarkStore* store = [ZVBookmarkStore sharedStore];
  NSString* scope = [_bookmark credentialScope];
  NSString* identity = [store canonicalIdentityForMAC:mac key:key];
  NSString* bound = [store identityForScope:scope];
  NSDictionary* device = identity ? [store deviceInfo:identity] : nil;
  // Different device only if none of what we see matches what was bound
  BOOL otherDevice = identity && bound &&
                     ![bound isEqualToString:identity] &&
                     ![bound isEqualToString:mac ?: @""] &&
                     ![bound isEqualToString:key ?: @""] &&
                     ![[store canonicalIdentityForMAC:nil key:bound] isEqualToString:identity];

  // With saving turned off in Settings nothing saved is used: the user
  // name and password are asked for on every connection
  BOOL savingEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];

  NSString* savedUser = savingEnabled ? (device[@"username"] ?: nsstr(user->c_str()))
                                      : _bookmark.username;

  if (savingEnabled && !_forcePrompt && !_bookmark.alwaysAskPassword) {
    NSString* pw = nil;
    if (identity)
      pw = [ZVBookmarkStore passwordForDevice:identity];
    // The connection's own password only goes to the device it was used
    // with (or to any device, until we have seen one)
    if (!pw && !otherDevice)
      pw = [_bookmark storedPassword];
    if (pw && (!needUser || savedUser.length)) {
      *user = savedUser.UTF8String ?: "";
      *pass = pw.UTF8String ?: "";
      _attemptUsername = needUser ? savedUser : nil;
      _attemptPassword = pw;
      return YES;
    }
  }

  NSString* warning = nil;
  if (_forcePrompt) {
    warning = @"The saved password was not accepted.";
  } else if (otherDevice) {
    NSDictionary* prev = [store deviceInfo:bound];
    NSString* prevName = prev[@"name"];
    warning = prevName.length
      ? [NSString stringWithFormat:@"A different device is using this address now (previously “%@”). "
                                   @"The saved password was not sent.", prevName]
      : @"A different device is using this address now. The saved password was not sent.";
  }

  NSString* deviceLine = nil;
  if ([identity hasPrefix:@"mac:"])
    deviceLine = [NSString stringWithFormat:@"Device: %@", [identity substringFromIndex:4]];
  if (device[@"name"])
    deviceLine = deviceLine ? [NSString stringWithFormat:@"%@ (%@)", deviceLine, device[@"name"]]
                            : [NSString stringWithFormat:@"Device: %@", device[@"name"]];

  NSString* u = savedUser;
  NSString* p = nil;
  BOOL remember = NO;
  BOOL ok = [_delegate session:self wantsCredentialsWithUsername:needUser
                        secure:secure warning:warning device:deviceLine
                      username:&u password:&p remember:&remember];
  if (!ok)
    return NO;

  _pendingPassword = (savingEnabled && remember) ? p : nil;
  _pendingUsername = (savingEnabled && needUser) ? u : nil;
  _attemptUsername = needUser ? u : nil;
  _attemptPassword = p;
  *user = u.UTF8String ?: "";
  *pass = p.UTF8String ?: "";
  return YES;
}

- (BOOL)_message:(NSString*)text title:(NSString*)title yesNo:(BOOL)yesNo
           style:(NSAlertStyle)style
{
  return [_delegate session:self showMessage:text title:title
                  questions:yesNo style:style];
}

@end
