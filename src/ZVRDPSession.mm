// Zeon Remote - one RDP session (see ZVRDPSession.h)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <unistd.h>

#include <atomic>
#include <map>
#include <memory>

#define XK_LATIN1
#define XK_MISCELLANY
#include <rfb/keysymdef.h>

#include "keysym2ucs.h"

#import "ZVRDPSession.h"
#import "ZVSession+Private.h"
#import "ZVNetUtil.h"
#include "ZVFramebuffer.h"
#include "rdp/ZVRdpClient.h"

static NSString* nsstr(const std::string& s)
{
  return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

// Keys without a character, for keysyms that come without a key code
// (Mac keyboard layout mode, typed text, special key combinations).
// Values are PC AT set 1 scancodes as QEMU numbers them (0x80 = extended).
static uint32_t qnumForKeySym(uint32_t ks)
{
  switch (ks) {
  case XK_Control_L: return 0x1d;
  case XK_Control_R: return 0x9d;
  case XK_Alt_L:     return 0x38;
  case XK_Alt_R:     return 0xb8;
  case XK_Meta_L:    return 0x38;
  case XK_Meta_R:    return 0xb8;
  case XK_Shift_L:   return 0x2a;
  case XK_Shift_R:   return 0x36;
  case XK_Super_L:   return 0xdb;
  case XK_Super_R:   return 0xdc;
  case XK_Menu:      return 0xdd;
  case XK_Caps_Lock: return 0x3a;
  case XK_Escape:    return 0x01;
  case XK_Tab:       return 0x0f;
  case XK_Return:    return 0x1c;
  case XK_KP_Enter:  return 0x9c;
  case XK_BackSpace: return 0x0e;
  case XK_Delete:    return 0xd3;
  case XK_Insert:    return 0xd2;
  case XK_Home:      return 0xc7;
  case XK_End:       return 0xcf;
  case XK_Page_Up:   return 0xc9;
  case XK_Page_Down: return 0xd1;
  case XK_Left:      return 0xcb;
  case XK_Right:     return 0xcd;
  case XK_Up:        return 0xc8;
  case XK_Down:      return 0xd0;
  case XK_Print:     return 0xb7;
  case XK_Scroll_Lock: return 0x46;
  case XK_Num_Lock:  return 0x45;
  case XK_F1:  return 0x3b;
  case XK_F2:  return 0x3c;
  case XK_F3:  return 0x3d;
  case XK_F4:  return 0x3e;
  case XK_F5:  return 0x3f;
  case XK_F6:  return 0x40;
  case XK_F7:  return 0x41;
  case XK_F8:  return 0x42;
  case XK_F9:  return 0x43;
  case XK_F10: return 0x44;
  case XK_F11: return 0x57;
  case XK_F12: return 0x58;
  // Letters used by the special key combinations (Win-L, Win-R, ...)
  case XK_l: return 0x26;
  case XK_r: return 0x13;
  case XK_e: return 0x12;
  case XK_d: return 0x20;
  }
  return 0;
}

@interface ZVRDPSession ()
- (void)_rdpClosed:(ZVCloseReason)reason message:(NSString*)message;
@end

// Protocol thread side: owns the framebuffer and talks to the session on
// the main thread
class ZVRDPBridge : public ZVRdpClient::Delegate {
public:
  explicit ZVRDPBridge(ZVRDPSession* session, NSString* host, int port, NSString* user)
    : session_(session), host_(host), port_(port), user_(user),
      current_(nullptr), previous_(nullptr), redrawPending(false) {}

  ~ZVRDPBridge() override
  {
    delete previous_;
    delete current_;
  }

  std::atomic<bool> redrawPending;

  // The device behind the address: a short TCP connection lets the MAC
  // address be found in the ARP table, and makes macOS ask for the Local
  // Network permission before FreeRDP connects
  void willConnect() override
  {
    int fd = ZVConnectTCP(host_, port_, nullptr, nil);
    if (fd >= 0) {
      mac_ = ZVMACAddressOfPeer(fd);
      close(fd);
    }
  }

  bool credentials(bool retry, std::string* user, std::string* password) override
  {
    if (retry)
      return false;
    __block BOOL ok = NO;
    __block std::string u = user->empty() ? (user_.UTF8String ?: "") : *user;
    __block std::string p = *password;
    __weak ZVRDPSession* weak = session_;
    NSString* mac = mac_;
    NSString* key = key_;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZVRDPSession* s = weak;
      if (!s)
        return;
      [s _setState:ZVSessionAuthenticating];
      ok = [s _credentialsUser:YES secure:YES mac:mac key:key username:&u password:&p];
    });
    if (!ok)
      return false;
    *user = u;
    *password = p;
    return true;
  }

  bool verifyCertificate(const std::string& identity, const std::string& subject,
                         const std::string& issuer, bool mismatch) override
  {
    (void)subject; (void)issuer; (void)mismatch;
    key_ = nsstr(identity);
    __block BOOL ok = NO;
    __weak ZVRDPSession* weak = session_;
    NSString* fp = key_;
    NSString* mac = mac_;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ZVRDPSession* s = weak;
      if (s)
        ok = [s _verifyServerKey:fp mac:mac];
    });
    return ok;
  }

  uint8_t* newFramebuffer(int width, int height, int* stride) override
  {
    delete previous_;
    previous_ = current_;
    current_ = new ZVFramebuffer(width, height);
    current_->beginWrite();
    IOSurfaceRef surface = current_->surface();
    *stride = (int)IOSurfaceGetBytesPerRow(surface);
    return (uint8_t*)IOSurfaceGetBaseAddress(surface);
  }

  void framebufferReplaced() override
  {
    current_->endWrite();
    IOSurfaceRef surface = (IOSurfaceRef)CFRetain(current_->surface());
    int w = current_->width(), h = current_->height();
    onMain(^(ZVRDPSession* s) {
      [s _framebufferChanged:surface width:w height:h];
      CFRelease(surface);
    });
    delete previous_;
    previous_ = nullptr;
  }

  void beginUpdate() override
  {
    if (current_)
      current_->beginWrite();
  }

  void endUpdate(int x, int y, int w, int h) override
  {
    (void)x; (void)y;
    if (current_)
      current_->endWrite();
    if (w > 0 && h > 0 && !redrawPending.exchange(true))
      onMain(^(ZVRDPSession* s) { [s _framebufferUpdated]; });
  }

  void cursorChanged(const uint8_t* rgba, int width, int height, int hotX, int hotY) override
  {
    if (width < 0) {
      // The system arrow
      onMain(^(ZVRDPSession* s) {
        NSCursor* arrow = [NSCursor arrowCursor];
        NSImage* img = arrow.image;
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:
                                 [img CGImageForProposedRect:NULL context:nil hints:nil]];
        NSSize size = img.size;
        NSInteger pw = rep.pixelsWide, ph = rep.pixelsHigh;
        NSMutableData* data = [NSMutableData dataWithLength:(NSUInteger)(pw * ph * 4)];
        uint8_t* out = (uint8_t*)data.mutableBytes;
        for (NSInteger y = 0; y < ph; y++) {
          for (NSInteger x = 0; x < pw; x++) {
            NSColor* c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
            uint8_t* px = out + (y * pw + x) * 4;
            px[0] = (uint8_t)(c.redComponent * 255);
            px[1] = (uint8_t)(c.greenComponent * 255);
            px[2] = (uint8_t)(c.blueComponent * 255);
            px[3] = (uint8_t)(c.alphaComponent * 255);
          }
        }
        CGFloat sx = size.width > 0 ? pw / size.width : 1;
        [s _cursorChanged:data width:(int)pw height:(int)ph
                  hotspot:NSMakePoint(arrow.hotSpot.x * sx, arrow.hotSpot.y * sx)];
      });
      return;
    }
    NSData* data = width > 0 ? [NSData dataWithBytes:rgba length:(size_t)width * height * 4]
                             : [NSData data];
    onMain(^(ZVRDPSession* s) {
      [s _cursorChanged:data width:width height:height hotspot:NSMakePoint(hotX, hotY)];
    });
  }

  void connected(const std::string& name) override
  {
    NSString* n = nsstr(name);
    NSString* mac = mac_;
    NSString* key = key_;
    onMain(^(ZVRDPSession* s) { [s _didInitWithName:n mac:mac key:key]; });
  }

  void remoteClipboard(const std::string& utf8) override
  {
    NSString* text = nsstr(utf8);
    onMain(^(ZVRDPSession* s) { [s _remoteClipboard:text]; });
  }

  void bell() override
  {
    onMain(^(ZVRDPSession* s) { [s _bell]; });
  }

  void closed(ZVRdpClient::CloseReason reason, const std::string& message) override
  {
    ZVCloseReason r;
    switch (reason) {
    case ZVRdpClient::CloseByUser:        r = ZVCloseByUser; break;
    case ZVRdpClient::CloseByServer:      r = ZVCloseByServer; break;
    case ZVRdpClient::CloseConnectFailed: r = ZVCloseConnectFailed; break;
    case ZVRdpClient::CloseAuthFailed:    r = ZVCloseAuthFailed; break;
    case ZVRdpClient::CloseAuthCancelled: r = ZVCloseAuthCancelled; break;
    default:                              r = ZVCloseError; break;
    }
    NSString* msg = message.empty() ? nil : nsstr(message);
    onMain(^(ZVRDPSession* s) { [s _rdpClosed:r message:msg]; });
  }

private:
  void onMain(void (^block)(ZVRDPSession* s))
  {
    __weak ZVRDPSession* weak = session_;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZVRDPSession* s = weak;
      if (s)
        block(s);
    });
  }

  __weak ZVRDPSession* session_;
  NSString* host_;
  int port_;
  NSString* user_;
  NSString* mac_;
  NSString* key_;
  ZVFramebuffer* current_;
  ZVFramebuffer* previous_;
};

// The client thread is joined when this is destroyed, so it is released
// away from the main thread (the thread may wait for the main thread)
struct ZVRDPConnection {
  std::unique_ptr<ZVRDPBridge> bridge;
  std::unique_ptr<ZVRdpClient> client;   // destroyed first
};

static void releaseConnection(std::shared_ptr<ZVRDPConnection>& conn)
{
  if (!conn)
    return;
  conn->client->stop();
  __block std::shared_ptr<ZVRDPConnection> doomed = conn;
  conn.reset();
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    doomed.reset();
  });
}

@implementation ZVRDPSession {
  std::shared_ptr<ZVRDPConnection> _rdp;
  // Pressed keys: local key code -> scancode (qnum) or Unicode character
  std::map<int, std::pair<bool, uint32_t>> _keys;
}

- (void)dealloc
{
  releaseConnection(_rdp);
}

- (NSString*)hostName
{
  return self.bookmark.host;
}

- (void)connect
{
  if (_rdp)
    return;

  ZVBookmark* b = self.bookmark;
  ZVRdpClient::Options o;
  o.host = b.host.UTF8String ?: "";
  if ([b.host hasPrefix:@"["] && [b.host hasSuffix:@"]"])
    o.host = [b.host substringWithRange:NSMakeRange(1, b.host.length - 2)].UTF8String;
  o.port = b.rdpPort > 0 ? (int)b.rdpPort : 3389;
  o.username = b.username.UTF8String ?: "";
  o.clipboard = b.shareClipboard;

  // Desktop size: what fits on this screen. In pixel perfect mode the
  // desktop has the screen's pixels and Windows scales its UI to match.
  NSScreen* screen = [NSScreen mainScreen];
  NSSize avail = screen.visibleFrame.size;
  avail.height -= 60;   // title bar and toolbar
  CGFloat scale = screen.backingScaleFactor;
  if (b.scaleMode == ZVScaleNativePixels && scale > 1) {
    o.width = (int)(avail.width * scale);
    o.height = (int)(avail.height * scale);
    o.scalePercent = (int)(scale * 100);
  } else {
    o.width = (int)avail.width;
    o.height = (int)avail.height;
  }

  auto conn = std::make_shared<ZVRDPConnection>();
  conn->bridge.reset(new ZVRDPBridge(self, b.host, o.port, b.username));
  conn->client.reset(new ZVRdpClient(conn->bridge.get(), o));
  _rdp = conn;
  _keys.clear();
  [self _setState:ZVSessionConnecting];
  conn->client->start();
}

- (void)disconnect
{
  if (_rdp)
    _rdp->client->stop();
}

- (void)_rdpClosed:(ZVCloseReason)reason message:(NSString*)message
{
  releaseConnection(_rdp);
  [self _closed:reason message:message];
}

- (void)_framebufferUpdated
{
  if (_rdp)
    _rdp->bridge->redrawPending = false;
  [super _framebufferUpdated];
}

#pragma mark Input

- (BOOL)canSendInput
{
  return _rdp && self.state == ZVSessionConnected && !self.viewOnly;
}

- (void)sendPointer:(NSPoint)pos buttons:(uint16_t)mask
{
  if (![self canSendInput])
    return;
  NSSize fb = self.framebufferSize;
  int x = (int)MAX(0, MIN(pos.x, fb.width - 1));
  int y = (int)MAX(0, MIN(pos.y, fb.height - 1));
  _rdp->client->sendPointer(x, y, mask);
}

- (void)sendKeyPress:(int)systemKeyCode keyCode:(uint32_t)keyCode keySym:(uint32_t)keySym
{
  if (![self canSendInput])
    return;
  uint32_t qnum = keyCode ? keyCode : qnumForKeySym(keySym);
  if (qnum) {
    _keys[systemKeyCode] = {true, qnum};
    _rdp->client->sendScancode(qnum, true);
    return;
  }
  uint32_t ucs = keysym2ucs(keySym);
  if (ucs == (uint32_t)-1 || ucs == 0)
    return;
  _keys[systemKeyCode] = {false, ucs};
  _rdp->client->sendUnicode(ucs, true);
}

- (void)sendKeyRelease:(int)systemKeyCode
{
  auto it = _keys.find(systemKeyCode);
  if (it == _keys.end())
    return;
  if (_rdp) {
    if (it->second.first)
      _rdp->client->sendScancode(it->second.second, false);
    else
      _rdp->client->sendUnicode(it->second.second, false);
  }
  _keys.erase(it);
}

- (void)releaseAllKeys
{
  for (auto& k : _keys) {
    if (_rdp && !k.second.first)
      _rdp->client->sendUnicode(k.second.second, false);
  }
  _keys.clear();
  if (_rdp)
    _rdp->client->releaseAllKeys();
}

- (void)refreshScreen
{
}

- (BOOL)supportsRemoteResize
{
  return _rdp && self.state == ZVSessionConnected && _rdp->client->canResize();
}

- (void)requestRemoteSize:(NSSize)size
{
  if ([self canSendInput])
    _rdp->client->requestSize((int)size.width, (int)size.height);
}

- (void)localClipboardChanged:(NSString*)text
{
  if (![self canSendInput] || !text || !self.bookmark.shareClipboard)
    return;
  NSString* t = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  _rdp->client->localClipboard(t.UTF8String ?: "");
}

#pragma mark Info

- (ZVSessionStats)stats
{
  ZVSessionStats s;
  memset(&s, 0, sizeof(s));
  s.jpegQuality = -1;
  s.lastEncoding = -1;
  return s;
}

- (NSString*)connectionInfo
{
  if (!_rdp)
    return @"Not connected";
  return nsstr(_rdp->client->connectionInfo());
}

- (BOOL)isSecure
{
  return _rdp && _rdp->client->isSecure();
}

@end
