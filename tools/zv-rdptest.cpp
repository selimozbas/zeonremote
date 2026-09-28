// Zeon Remote - headless RDP client check: connects with the RDP core the app
// uses, accepts the certificate, receives a few screen updates and checks
// that the screen was drawn. Used by tools/run-tests.sh against FreeRDP's
// sample server.
//
// Usage: zv-rdptest [-port N] [-user U] [-password P] [-updates N] [-size WxH]
//
// Exit status 0 on success, 1 on failure.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <vector>

#include "ZVRdpClient.h"

class TestDelegate : public ZVRdpClient::Delegate {
public:
  std::mutex m;
  std::condition_variable cv;
  std::vector<uint8_t> fb;
  int width = 0, height = 0, stride = 0;
  int updates = 0;
  int cursors = 0;
  bool done = false;
  bool wasConnected = false;
  bool certificateSeen = false;
  ZVRdpClient::CloseReason reason = ZVRdpClient::CloseByUser;
  std::string message;
  std::string user, password;

  bool credentials(bool retry, std::string* u, std::string* p) override
  {
    printf("credentials requested%s\n", retry ? " (retry)" : "");
    if (retry)
      return false;
    *u = user;
    *p = password;
    return true;
  }

  bool verifyCertificate(const std::string& identity, const std::string& subject,
                         const std::string& issuer, bool mismatch) override
  {
    printf("certificate %s subject \"%s\"%s\n", identity.c_str(), subject.c_str(),
           mismatch ? " (host name mismatch)" : "");
    certificateSeen = identity.rfind("x509:", 0) == 0 && identity.size() == 5 + 64;
    (void)issuer;
    return true;
  }

  uint8_t* newFramebuffer(int w, int h, int* s) override
  {
    std::lock_guard<std::mutex> lock(m);
    width = w;
    height = h;
    stride = w * 4;
    fb.assign((size_t)stride * h, 0);
    *s = stride;
    printf("framebuffer %dx%d\n", w, h);
    return fb.data();
  }

  void endUpdate(int x, int y, int w, int h) override
  {
    if (getenv("ZV_DEBUG"))
      printf("update %d,%d %dx%d\n", x, y, w, h);
    std::lock_guard<std::mutex> lock(m);
    if (w > 0 && h > 0)
      updates++;
    cv.notify_all();
  }

  void cursorChanged(const uint8_t* rgba, int w, int h, int hx, int hy) override
  {
    (void)rgba; (void)hx; (void)hy;
    std::lock_guard<std::mutex> lock(m);
    cursors++;
    printf("cursor %dx%d\n", w, h);
  }

  void connected(const std::string& name) override
  {
    std::lock_guard<std::mutex> lock(m);
    wasConnected = true;
    printf("connected to %s\n", name.c_str());
  }

  void closed(ZVRdpClient::CloseReason r, const std::string& msg) override
  {
    std::lock_guard<std::mutex> lock(m);
    reason = r;
    message = msg;
    done = true;
    cv.notify_all();
  }

  double coverage()
  {
    size_t lit = 0;
    for (int y = 0; y < height; y++) {
      const uint8_t* row = fb.data() + (size_t)y * stride;
      for (int x = 0; x < width; x++)
        lit += (row[x * 4] | row[x * 4 + 1] | row[x * 4 + 2]) != 0;
    }
    return width && height ? (double)lit / ((double)width * height) : 0;
  }
};

int main(int argc, char** argv)
{
  setvbuf(stdout, nullptr, _IOLBF, 0);
  ZVRdpClient::Options options;
  options.host = "127.0.0.1";
  options.width = 1024;
  options.height = 768;
  int wantUpdates = 1;
  TestDelegate d;
  d.user = "test";
  d.password = "test";

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-port") && i + 1 < argc) options.port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-user") && i + 1 < argc) d.user = argv[++i];
    else if (!strcmp(argv[i], "-password") && i + 1 < argc) d.password = argv[++i];
    else if (!strcmp(argv[i], "-updates") && i + 1 < argc) wantUpdates = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-size") && i + 1 < argc)
      sscanf(argv[++i], "%dx%d", &options.width, &options.height);
    else {
      fprintf(stderr, "unknown argument %s\n", argv[i]);
      return 2;
    }
  }

  ZVRdpClient client(&d, options);
  client.start();

  bool ok;
  {
    std::unique_lock<std::mutex> lock(d.m);
    ok = d.cv.wait_for(lock, std::chrono::seconds(30),
                       [&]() { return d.done || d.updates >= wantUpdates; });
  }
  if (!ok || d.done) {
    std::lock_guard<std::mutex> lock(d.m);
    printf("FAIL: %s after %d updates (%s)\n", d.done ? "closed" : "timed out", d.updates,
           d.message.c_str());
    client.stop();
    client.join();
    return 1;
  }

  // Input must not upset the connection: move, click, scroll, type
  client.sendPointer(100, 100, 0);
  client.sendPointer(120, 110, ZVRdpClient::ButtonLeft);
  client.sendPointer(120, 110, 0);
  client.sendPointer(120, 110, ZVRdpClient::WheelDown);
  client.sendPointer(120, 110, 0);
  client.sendScancode(0x1e, true);    // A
  client.sendScancode(0x1e, false);
  client.sendScancode(0x9d, true);    // right Ctrl (extended)
  client.sendScancode(0x9d, false);
  client.sendUnicode(0x00e7, true);   // ç
  client.sendUnicode(0x00e7, false);
  client.releaseAllKeys();

  // The sample server moves an icon with the mouse, so input shows up as
  // further updates
  int before;
  bool inputSeen;
  {
    std::unique_lock<std::mutex> lock(d.m);
    before = d.updates;
    inputSeen = d.cv.wait_for(lock, std::chrono::seconds(5),
                              [&]() { return d.done || d.updates > before; }) && !d.done;
  }

  double lit;
  bool stillConnected;
  int updates, width, height;
  {
    std::lock_guard<std::mutex> lock(d.m);
    lit = d.coverage();
    stillConnected = !d.done;
    updates = d.updates;
    width = d.width;
    height = d.height;
  }
  printf("%dx%d, %d updates, %.0f%% drawn, secure %s\n%s", width, height, updates, lit * 100,
         client.isSecure() ? "yes" : "no", client.connectionInfo().c_str());

  client.stop();
  client.join();

  if (!stillConnected) {
    printf("FAIL: the connection closed after input (%s)\n", d.message.c_str());
    return 1;
  }
  if (!inputSeen) {
    printf("FAIL: no screen update after mouse input\n");
    return 1;
  }
  if (!d.certificateSeen) {
    printf("FAIL: no certificate identity\n");
    return 1;
  }
  if (lit < 0.5) {
    printf("FAIL: the framebuffer is mostly empty\n");
    return 1;
  }
  if (d.reason != ZVRdpClient::CloseByUser) {
    printf("FAIL: closing reported reason %d (%s)\n", d.reason, d.message.c_str());
    return 1;
  }
  printf("OK\n");
  return 0;
}
