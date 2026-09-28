// Zeon Remote - small networking helpers
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <string>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netdb.h>
#include <netinet/if_ether.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import "ZVNetUtil.h"

static NSString* lookupMAC(in_addr_t addr)
{
  int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO };
  size_t needed = 0;
  if (sysctl(mib, 6, nullptr, &needed, nullptr, 0) < 0 || needed == 0)
    return nil;
  std::vector<char> buf(needed);
  if (sysctl(mib, 6, buf.data(), &needed, nullptr, 0) < 0)
    return nil;

#define ZV_ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))
  for (char* next = buf.data(); next < buf.data() + needed;) {
    struct rt_msghdr* rtm = (struct rt_msghdr*)next;
    if (rtm->rtm_msglen == 0)
      break;
    struct sockaddr_inarp* sin = (struct sockaddr_inarp*)(rtm + 1);
    struct sockaddr_dl* sdl = (struct sockaddr_dl*)((char*)sin + ZV_ROUNDUP(sin->sin_len));
    if (sin->sin_addr.s_addr == addr && sdl->sdl_family == AF_LINK && sdl->sdl_alen == 6) {
      const unsigned char* m = (const unsigned char*)LLADDR(sdl);
      return [NSString stringWithFormat:@"mac:%02x:%02x:%02x:%02x:%02x:%02x",
              m[0], m[1], m[2], m[3], m[4], m[5]];
    }
    next += rtm->rtm_msglen;
  }
#undef ZV_ROUNDUP
  return nil;
}

NSString* ZVMACAddressOfPeer(int fd)
{
  struct sockaddr_storage ss;
  socklen_t len = sizeof(ss);
  if (fd < 0 || getpeername(fd, (struct sockaddr*)&ss, &len) != 0 || ss.ss_family != AF_INET)
    return nil;
  in_addr_t addr = ((struct sockaddr_in*)&ss)->sin_addr.s_addr;
  for (int i = 0; i < 5; i++) {
    if (i > 0)
      usleep(30000);
    NSString* mac = lookupMAC(addr);
    if (mac)
      return mac;
  }
  return nil;
}

int ZVConnectTCP(NSString* host, int port, volatile BOOL* cancel, NSError** error)
{
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo* res = nullptr;
  std::string portStr = std::to_string(port);
  int gai = getaddrinfo(host.UTF8String, portStr.c_str(), &hints, &res);
  if (gai != 0) {
    if (error)
      *error = [NSError errorWithDomain:@"ZeonRemote" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown host %@: %s", host, gai_strerror(gai)]}];
    return -1;
  }

  int lastErr = 0;
  int fd = -1;
  for (int attempt = 0; attempt < 8 && fd < 0 && !(cancel && *cancel); attempt++) {
    for (struct addrinfo* ai = res; ai && fd < 0; ai = ai->ai_next) {
      int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
      if (s < 0)
        continue;
      int one = 1;
      setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
      setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

      fcntl(s, F_SETFL, O_NONBLOCK);
      int rc = connect(s, ai->ai_addr, ai->ai_addrlen);
      if (rc < 0 && errno == EINPROGRESS) {
        struct pollfd p = { s, POLLOUT, 0 };
        rc = poll(&p, 1, 10000);
        if (rc == 1) {
          socklen_t len = sizeof(lastErr);
          getsockopt(s, SOL_SOCKET, SO_ERROR, &lastErr, &len);
          rc = lastErr == 0 ? 0 : -1;
        } else {
          lastErr = rc == 0 ? ETIMEDOUT : errno;
          rc = -1;
        }
      } else if (rc < 0) {
        lastErr = errno;
      }
      if (rc == 0) {
        fcntl(s, F_SETFL, 0);
        fd = s;
      } else {
        close(s);
      }
    }
    if (fd < 0 && lastErr == EHOSTUNREACH)
      usleep(500000);
    else
      break;
  }
  freeaddrinfo(res);

  if (fd < 0 && error) {
    NSString* msg = [NSString stringWithFormat:@"Unable to connect to %@ port %d: %s", host, port,
                     strerror(lastErr ? lastErr : ECONNREFUSED)];
    if (lastErr == EHOSTUNREACH)
      msg = [msg stringByAppendingString:
               @"\n\nIf this device is on your local network, allow Zeon Remote in "
               @"System Settings → Privacy & Security → Local Network."];
    *error = [NSError errorWithDomain:@"ZeonRemote" code:lastErr userInfo:@{NSLocalizedDescriptionKey: msg}];
  }
  return fd;
}
