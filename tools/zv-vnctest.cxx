// ZeonVNC - headless VNC client check against zv-testserver: connects,
// authenticates, receives a few framebuffer updates with the requested
// encoding and checks that the screen was drawn. Used by tools/run-tests.sh.
//
// Usage: zv-vnctest [-port N] [-password PW] [-encoding raw|hextile|tight|zrle]
//                   [-security TYPE] [-updates N] [-expect-auth-failure]
//
// Exit status 0 on success, 1 on failure.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <string>

#include <core/Configuration.h>
#include <core/LogWriter.h>
#include <core/Logger_stdio.h>

#include <network/TcpSocket.h>
#include <rdr/FdInStream.h>
#include <rdr/FdOutStream.h>

#include <rfb/CConnection.h>
#include <rfb/CSecurity.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <rfb/Security.h>
#include <rfb/encodings.h>

class TestConnection : public rfb::CConnection {
public:
  TestConnection(const char* password, int encoding)
    : password(password ? password : ""), updates(0), initialised(false)
  {
    setPreferredEncoding(encoding);
  }

  void getUserPasswd(bool, std::string* user, std::string* passwd) override
  {
    if (user)
      *user = "test";
    if (passwd)
      *passwd = password;
  }

  bool showMsgBox(rfb::MsgBoxFlags, const char*, const char*) override
  {
    return true;
  }

  void bell() override {}

  bool verifyServerIdentity(const char*, const uint8_t*, size_t) override
  {
    return true;
  }

  void initDone() override
  {
    initialised = true;
    setFramebuffer(new rfb::ManagedPixelBuffer(server.pf(), server.width(),
                                               server.height()));
  }

  void framebufferUpdateEnd() override
  {
    CConnection::framebufferUpdateEnd();
    updates++;
  }

  // Fraction of pixels that are not black
  double coverage()
  {
    rfb::ModifiablePixelBuffer* pb = getFramebuffer();
    const rfb::PixelFormat& pf = pb->getPF();
    int stride;
    const uint8_t* data = pb->getBuffer(pb->getRect(), &stride);
    size_t lit = 0;
    int bpp = pf.bpp / 8;
    for (int y = 0; y < pb->height(); y++) {
      for (int x = 0; x < pb->width(); x++) {
        const uint8_t* p = data + (y * stride + x) * bpp;
        bool any = false;
        for (int i = 0; i < bpp; i++)
          any |= p[i] != 0;
        lit += any;
      }
    }
    return (double)lit / ((double)pb->width() * pb->height());
  }

  const char* securityName()
  {
    return csecurity ? rfb::secTypeName(csecurity->getType()) : "?";
  }

  std::string password;
  int updates;
  bool initialised;
};

static int encodingByName(const char* name)
{
  if (!strcmp(name, "raw")) return rfb::encodingRaw;
  if (!strcmp(name, "hextile")) return rfb::encodingHextile;
  if (!strcmp(name, "tight")) return rfb::encodingTight;
  if (!strcmp(name, "zrle")) return rfb::encodingZRLE;
  fprintf(stderr, "unknown encoding %s\n", name);
  exit(2);
}

int main(int argc, char** argv)
{
  int port = 5901;
  const char* password = nullptr;
  const char* encName = "tight";
  const char* security = nullptr;
  int wantUpdates = 3;
  bool expectAuthFailure = false;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-port") && i + 1 < argc) port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-password") && i + 1 < argc) password = argv[++i];
    else if (!strcmp(argv[i], "-encoding") && i + 1 < argc) encName = argv[++i];
    else if (!strcmp(argv[i], "-security") && i + 1 < argc) security = argv[++i];
    else if (!strcmp(argv[i], "-updates") && i + 1 < argc) wantUpdates = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-expect-auth-failure")) expectAuthFailure = true;
    else {
      fprintf(stderr, "unknown argument %s\n", argv[i]);
      return 2;
    }
  }

  signal(SIGPIPE, SIG_IGN);
  core::initStdIOLoggers();
  core::LogWriter::setLogParams("*:stderr:0");
  if (security)
    core::Configuration::setParam("SecurityTypes", security);

  const char* label = encName;
  try {
    network::TcpSocket sock("127.0.0.1", port);
    TestConnection cc(password, encodingByName(encName));
    cc.setServerName("127.0.0.1");
    cc.setStreams(&sock.inStream(), &sock.outStream());
    cc.initialiseProtocol();

    time_t deadline = time(nullptr) + 20;
    while (cc.updates < wantUpdates) {
      if (time(nullptr) > deadline) {
        printf("FAIL %s: timed out after %d updates\n", label, cc.updates);
        return 1;
      }
      sock.outStream().flush();
      struct pollfd pfd = { sock.getFd(), POLLIN, 0 };
      if (sock.outStream().hasBufferedData())
        pfd.events |= POLLOUT;
      if (poll(&pfd, 1, 1000) <= 0)
        continue;
      while (cc.processMsg())
        ;
    }

    if (expectAuthFailure) {
      printf("FAIL %s: connected although authentication should fail\n", label);
      return 1;
    }

    rfb::ModifiablePixelBuffer* pb = cc.getFramebuffer();
    double lit = cc.coverage();
    printf("%s: %dx%d, %d updates, %.0f%% drawn, security %s\n", label,
           pb->width(), pb->height(), cc.updates, lit * 100,
           cc.securityName());
    // zv-testserver draws a gradient with a blue component everywhere
    if (lit < 0.9) {
      printf("FAIL %s: the framebuffer is mostly empty\n", label);
      return 1;
    }
    cc.close();
  } catch (rfb::auth_error& e) {
    if (expectAuthFailure) {
      printf("%s: authentication rejected as expected (%s)\n", label, e.what());
      return 0;
    }
    printf("FAIL %s: authentication failed: %s\n", label, e.what());
    return 1;
  } catch (std::exception& e) {
    printf("FAIL %s: %s\n", label, e.what());
    return 1;
  }
  printf("OK %s\n", label);
  return 0;
}
