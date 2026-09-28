// ZeonVNC - RDP client core on top of FreeRDP. Plain C++ without any
// Cocoa code, so it also builds for the headless test client on Linux.
//
// The connection runs on its own thread. The delegate is called on that
// thread; input methods can be called from any thread (they are queued and
// run on the protocol thread).
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#ifndef __ZV_RDP_CLIENT_H__
#define __ZV_RDP_CLIENT_H__

#include <stdint.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct ZVRdpContext;

class ZVRdpClient {
public:
  enum CloseReason {
    CloseByUser,
    CloseByServer,
    CloseConnectFailed,
    CloseAuthFailed,
    CloseAuthCancelled,
    CloseError,
  };

  // Mouse buttons in the same bit layout as RFB pointer events
  enum {
    ButtonLeft = 1 << 0,
    ButtonMiddle = 1 << 1,
    ButtonRight = 1 << 2,
    WheelUp = 1 << 3,
    WheelDown = 1 << 4,
    WheelLeft = 1 << 5,
    WheelRight = 1 << 6,
    ButtonBack = 1 << 7,
    ButtonForward = 1 << 8,
  };

  struct Options {
    std::string host;
    int port = 3389;
    std::string username;   // "user", "DOMAIN\\user" or "user@domain"
    std::string password;
    int width = 1280;
    int height = 800;
    int scalePercent = 100;   // 100, 140 or 180: DPI hint for the server
    bool clipboard = true;
  };

  class Delegate {
  public:
    virtual ~Delegate() {}

    // First thing on the protocol thread, before FreeRDP connects
    virtual void willConnect() {}

    // Credentials for NLA / TLS logon. user/password come in with the
    // current values. Return false to cancel the connection.
    virtual bool credentials(bool retry, std::string* user, std::string* password) = 0;

    // Server certificate (every one, also those signed by a CA). identity
    // is "x509:<sha256 of the certificate>". Return true to accept.
    virtual bool verifyCertificate(const std::string& identity, const std::string& subject,
                                   const std::string& issuer, bool hostMismatch) = 0;

    // A framebuffer of the given size, 32 bits per pixel, B G R X in
    // memory. Returns the buffer and its stride in bytes. The previous
    // buffer must stay valid until framebufferReplaced() is called.
    virtual uint8_t* newFramebuffer(int width, int height, int* stride) = 0;
    virtual void framebufferReplaced() {}

    // Bracket drawing into the framebuffer. endUpdate reports the changed
    // area (empty when nothing changed).
    virtual void beginUpdate() {}
    virtual void endUpdate(int x, int y, int w, int h) = 0;

    // Cursor image, RGBA, not premultiplied. width 0 hides the cursor.
    virtual void cursorChanged(const uint8_t* rgba, int width, int height,
                               int hotX, int hotY) { (void)rgba; (void)width; (void)height;
                                                      (void)hotX; (void)hotY; }

    virtual void connected(const std::string& desktopName) { (void)desktopName; }
    virtual void remoteClipboard(const std::string& utf8) { (void)utf8; }
    virtual void bell() {}
    virtual void closed(CloseReason reason, const std::string& message) = 0;
  };

  ZVRdpClient(Delegate* delegate, const Options& options);
  ~ZVRdpClient();

  void start();
  void stop();
  // Waits until the protocol thread has ended
  void join();

  // Input, from any thread
  void sendPointer(int x, int y, uint16_t buttons);
  // scancode: PC AT set 1 scancode as used by QEMU ("qnum"): extended keys
  // have bit 7 set (0x9d = right Ctrl)
  void sendScancode(uint32_t qnum, bool down);
  void sendUnicode(uint32_t ch, bool down);
  void releaseAllKeys();
  void requestSize(int width, int height);
  void localClipboard(const std::string& utf8);

  bool isSecure() const { return secure_; }
  bool canResize() const { return canResize_; }
  std::string connectionInfo();

private:
  friend struct ZVRdpCallbacks;

  void run();
  void post(std::function<void()> task);
  void runTasks();

  Delegate* delegate_;
  Options options_;
  ZVRdpContext* context_;
  std::thread thread_;
  std::atomic<bool> stopRequested_;
  std::atomic<bool> secure_;
  std::atomic<bool> canResize_;
  void* wakeEvent_;

  std::mutex taskMutex_;
  std::vector<std::function<void()>> tasks_;

  // Protocol thread only
  uint16_t buttons_;
  std::vector<uint32_t> pressed_;
  bool authRetry_;
  std::mutex infoMutex_;
  std::string info_;
};

#endif
