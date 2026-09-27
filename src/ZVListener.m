// ZeonVNC - reverse connection listener
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#import "ZVListener.h"

@implementation ZVListener {
  NSMutableArray<dispatch_source_t>* _sources;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    _sources = [NSMutableArray array];
  return self;
}

- (void)dealloc
{
  [self stop];
}

- (BOOL)isListening
{
  return _sources.count > 0;
}

- (int)openSocketFamily:(int)family port:(int)port
{
  int fd = socket(family, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;

  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  int rc;
  if (family == AF_INET6) {
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
    struct sockaddr_in6 sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin6_family = AF_INET6;
    sa.sin6_port = htons(port);
    sa.sin6_addr = in6addr_any;
    rc = bind(fd, (struct sockaddr*)&sa, sizeof(sa));
  } else {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    rc = bind(fd, (struct sockaddr*)&sa, sizeof(sa));
  }

  if (rc < 0 || listen(fd, 5) < 0) {
    int e = errno;
    close(fd);
    errno = e;
    return -1;
  }

  fcntl(fd, F_SETFL, O_NONBLOCK);
  return fd;
}

- (BOOL)startOnPort:(int)port error:(NSError**)error
{
  [self stop];

  int fds[2] = {
    [self openSocketFamily:AF_INET port:port],
    [self openSocketFamily:AF_INET6 port:port],
  };
  int err = errno;

  if (fds[0] < 0 && fds[1] < 0) {
    if (error)
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err
                               userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"Unable to listen on port %d: %s",
                                             port, strerror(err)]}];
    return NO;
  }

  for (int i = 0; i < 2; i++) {
    int lfd = fds[i];
    if (lfd < 0)
      continue;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, lfd, 0,
                                                   dispatch_get_main_queue());
    __weak ZVListener* weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
      struct sockaddr_storage ss;
      socklen_t len = sizeof(ss);
      int cfd = accept(lfd, (struct sockaddr*)&ss, &len);
      if (cfd < 0)
        return;

      int one = 1;
      setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
      // The RFB streams expect a non-blocking socket
      fcntl(cfd, F_SETFL, O_NONBLOCK);

      char host[INET6_ADDRSTRLEN] = "unknown";
      if (ss.ss_family == AF_INET)
        inet_ntop(AF_INET, &((struct sockaddr_in*)&ss)->sin_addr, host, sizeof(host));
      else if (ss.ss_family == AF_INET6)
        inet_ntop(AF_INET6, &((struct sockaddr_in6*)&ss)->sin6_addr, host, sizeof(host));

      ZVListener* strongSelf = weakSelf;
      if (strongSelf && strongSelf.onConnection)
        strongSelf.onConnection(cfd, [NSString stringWithUTF8String:host]);
      else
        close(cfd);
    });
    dispatch_source_set_cancel_handler(src, ^{ close(lfd); });
    dispatch_resume(src);
    [_sources addObject:src];
  }

  _port = port;
  return YES;
}

- (void)stop
{
  for (dispatch_source_t s in _sources)
    dispatch_source_cancel(s);
  [_sources removeAllObjects];
}

@end
