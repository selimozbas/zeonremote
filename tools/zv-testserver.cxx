// ZeonVNC - synthetic VNC test server
//
// Serves an animated desktop using the RFB core's server code so the viewer
// can be tested against all encodings and auth methods without a real
// VNC server. Input events are logged to stderr.
//
// Usage: zv-testserver [-port N] [-password PW] [-size WxH] [-reverse host:port]
//                      [-cert cert.pem -key key.pem]
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

#include <list>
#include <string>

#include <core/Configuration.h>
#include <core/LogWriter.h>
#include <core/Logger_stdio.h>
#include <core/Timer.h>

#include <network/TcpSocket.h>
#include <rdr/FdOutStream.h>

#include <rfb/PixelBuffer.h>
#include <rfb/SDesktop.h>
#include <rfb/ScreenSet.h>
#include <rfb/VNCServerST.h>
#include <rfb/obfuscate.h>

static bool quit = false;

class TestDesktop : public rfb::SDesktop, public core::Timer::Callback {
public:
  TestDesktop(int w, int h) : server(nullptr), timer(this), frame(0),
                              width(w), height(h), mx(0), my(0), buttons(0)
  {
    pb = new rfb::ManagedPixelBuffer(
      rfb::PixelFormat(32, 24, false, true, 255, 255, 255, 16, 8, 0), w, h);
    drawBackground();
  }

  void init(rfb::VNCServer* vs) override
  {
    server = vs;
    server->setPixelBuffer(pb, computeLayout());
    server->setName("ZeonVNC Test Desktop");
  }

  rfb::ScreenSet computeLayout()
  {
    rfb::ScreenSet layout;
    layout.add_screen(rfb::Screen(0, 0, 0, width, height, 0));
    return layout;
  }

  void start() override { timer.start(33); }
  void stop() override { timer.stop(); }

  void queryConnection(network::Socket* sock, const char*) override
  {
    server->approveConnection(sock, true, nullptr);
  }

  void terminate() override { quit = true; }

  unsigned int setScreenLayout(int fbw, int fbh, const rfb::ScreenSet&) override
  {
    fprintf(stderr, "RESIZE %dx%d\n", fbw, fbh);
    width = fbw;
    height = fbh;
    pb = new rfb::ManagedPixelBuffer(pb->getPF(), fbw, fbh);
    drawBackground();
    server->setPixelBuffer(pb, computeLayout());
    return rfb::resultSuccess;
  }

  void keyEvent(uint32_t keysym, uint32_t keycode, bool down) override
  {
    fprintf(stderr, "KEY %s keysym=0x%04x keycode=0x%02x\n",
            down ? "down" : "up  ", keysym, keycode);
  }

  void pointerEvent(const core::Point& pos, uint16_t mask) override
  {
    if (mask != buttons)
      fprintf(stderr, "POINTER %d,%d buttons=0x%x\n", pos.x, pos.y, mask);
    // Paint while the left button is held, like a drawing program
    if (mask & 1) {
      core::Rect r(pos.x - 3, pos.y - 3, pos.x + 4, pos.y + 4);
      r = r.intersect(pb->getRect());
      uint8_t pix[4] = {40, 40, 240, 0};
      pb->fillRect(r, pix);
      server->add_changed(r);
    }
    mx = pos.x;
    my = pos.y;
    buttons = mask;
  }

  void handleClipboardAnnounce(bool available) override
  {
    fprintf(stderr, "CLIPBOARD announce %d\n", available);
    if (available)
      server->requestClipboard();
  }

  void handleClipboardData(const char* data) override
  {
    fprintf(stderr, "CLIPBOARD data \"%s\"\n", data);
    lastClipboard = data;
    // Echo it back with a prefix so the client->server->client path is visible
    server->announceClipboard(true);
  }

  void handleClipboardRequest() override
  {
    std::string s = "From test server: " + lastClipboard;
    server->sendClipboardData(s.c_str());
  }

private:
  void drawBackground()
  {
    int stride;
    uint8_t* buf = pb->getBufferRW(pb->getRect(), &stride);
    for (int y = 0; y < height; y++) {
      uint32_t* row = (uint32_t*)(buf + y * stride * 4);
      for (int x = 0; x < width; x++) {
        uint8_t r = x * 255 / width;
        uint8_t g = y * 255 / height;
        uint8_t b = 128;
        // Fine checkerboard in one corner to judge scaling quality
        if (x < 200 && y < 200)
          r = g = b = ((x ^ y) & 1) ? 255 : 0;
        // Thin lines like text
        if (y > 220 && y < 400 && x < 600 && (y % 6 == 0) && ((x / 7) % 5 != 0))
          r = g = b = 20;
        row[x] = (r << 16) | (g << 8) | b;
      }
    }
    pb->commitBufferRW(pb->getRect());
  }

  void handleTimeout(core::Timer* t) override
  {
    // A bouncing box to exercise continuous updates
    frame++;
    static core::Rect last;
    int bw = 160, bh = 120;
    int x = (int)((sin(frame * 0.03) * 0.5 + 0.5) * (width - bw));
    int y = (int)((cos(frame * 0.021) * 0.5 + 0.5) * (height - bh - 420)) + 410;
    if (y + bh > height) y = height - bh;
    if (y < 0) y = 0;

    core::Rect r(x, y, x + bw, y + bh);
    if (!last.is_empty()) {
      // Restore background under the previous box
      uint8_t bg[4];
      core::Rect lr = last.intersect(pb->getRect());
      int stride;
      uint8_t* buf = pb->getBufferRW(lr, &stride);
      for (int yy = 0; yy < lr.height(); yy++) {
        uint32_t* row = (uint32_t*)(buf + yy * stride * 4);
        for (int xx = 0; xx < lr.width(); xx++) {
          int gx = lr.tl.x + xx, gy = lr.tl.y + yy;
          row[xx] = ((gx * 255 / width) << 16) | ((gy * 255 / height) << 8) | 128;
        }
      }
      pb->commitBufferRW(lr);
      (void)bg;
      server->add_changed(lr);
    }
    uint8_t col[4] = {(uint8_t)(frame * 3), 200, (uint8_t)(255 - frame * 2), 0};
    core::Rect cr = r.intersect(pb->getRect());
    pb->fillRect(cr, col);
    server->add_changed(cr);
    last = cr;
    t->repeat();
  }

  rfb::VNCServer* server;
  core::Timer timer;
  rfb::ManagedPixelBuffer* pb;
  unsigned frame;
  int width, height;
  int mx, my;
  uint16_t buttons;
  std::string lastClipboard;
};

int main(int argc, char** argv)
{
  int port = 5901;
  int w = 1600, h = 1000;
  const char* password = nullptr;
  const char* reverse = nullptr;
  const char* cert = nullptr;
  const char* key = nullptr;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-port") && i + 1 < argc) port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-password") && i + 1 < argc) password = argv[++i];
    else if (!strcmp(argv[i], "-size") && i + 1 < argc) sscanf(argv[++i], "%dx%d", &w, &h);
    else if (!strcmp(argv[i], "-reverse") && i + 1 < argc) reverse = argv[++i];
    else if (!strcmp(argv[i], "-cert") && i + 1 < argc) cert = argv[++i];
    else if (!strcmp(argv[i], "-key") && i + 1 < argc) key = argv[++i];
  }

  signal(SIGPIPE, SIG_IGN);
  core::initStdIOLoggers();
  core::LogWriter::setLogParams("*:stderr:30");

  if (password) {
    char path[] = "/tmp/zv-testserver-passwd-XXXXXX";
    int fd = mkstemp(path);
    std::vector<uint8_t> obf = rfb::obfuscate(password);
    (void)!write(fd, obf.data(), obf.size());
    close(fd);
    core::Configuration::setParam("PasswordFile", path);
    core::Configuration::setParam("SecurityTypes", "VncAuth");
  } else {
    core::Configuration::setParam("SecurityTypes", "None");
  }
  if (cert && key) {
    // TLS with a certificate (VeNCrypt X509), optionally with VncAuth
    core::Configuration::setParam("X509Cert", cert);
    core::Configuration::setParam("X509Key", key);
    core::Configuration::setParam("SecurityTypes", password ? "X509Vnc" : "X509None");
  }

  TestDesktop desktop(w, h);
  rfb::VNCServerST server("zv-testserver", &desktop);

  std::list<network::SocketListener*> listeners;
  if (reverse) {
    std::string host;
    int rport;
    network::getHostAndPort(reverse, &host, &rport, 5500);
    server.addSocket(new network::TcpSocket(host.c_str(), rport), true);
    fprintf(stderr, "Connected out to %s:%d\n", host.c_str(), rport);
  } else {
    network::createTcpListeners(&listeners, "127.0.0.1", port);
    fprintf(stderr, "Listening on 127.0.0.1:%d (%s)\n", port,
            password ? "VncAuth" : "no auth");
  }

  while (!quit) {
    fd_set rfds, wfds;
    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    for (auto* l : listeners)
      FD_SET(l->getFd(), &rfds);
    std::list<network::Socket*> sockets;
    server.getSockets(&sockets);
    for (auto* s : sockets) {
      FD_SET(s->getFd(), &rfds);
      if (s->outStream().hasBufferedData())
        FD_SET(s->getFd(), &wfds);
    }

    int timeout = core::Timer::checkTimeouts();
    struct timeval tv, *tvp = nullptr;
    if (timeout >= 0) {
      tv.tv_sec = timeout / 1000;
      tv.tv_usec = (timeout % 1000) * 1000;
      tvp = &tv;
    }
    int n = select(FD_SETSIZE, &rfds, &wfds, nullptr, tvp);
    if (n < 0)
      continue;

    for (auto* l : listeners) {
      if (FD_ISSET(l->getFd(), &rfds)) {
        network::Socket* sock = l->accept();
        if (sock)
          server.addSocket(sock);
      }
    }

    core::Timer::checkTimeouts();

    server.getSockets(&sockets);
    for (auto* s : sockets) {
      if (FD_ISSET(s->getFd(), &rfds))
        server.processSocketReadEvent(s);
      if (FD_ISSET(s->getFd(), &wfds))
        server.processSocketWriteEvent(s);
      if (s->isShutdown()) {
        server.removeSocket(s);
        delete s;
        if (reverse)
          quit = true;
      }
    }
  }
  return 0;
}
