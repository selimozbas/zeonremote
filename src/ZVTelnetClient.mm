// ZeonVNC - Telnet client
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <mutex>
#include <string>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#import "ZVTelnetClient.h"
#import "ZVNetUtil.h"

enum {
  SE = 240, NOP = 241, SB = 250, WILL = 251, WONT = 252, DO = 253, DONT = 254, IAC = 255,
};
enum {
  OPT_BINARY = 0, OPT_ECHO = 1, OPT_SGA = 3, OPT_TTYPE = 24, OPT_NAWS = 31,
};
enum { TTYPE_IS = 0, TTYPE_SEND = 1 };

@implementation ZVTelnetClient {
  int _port;
  int _sock;
  int _wake[2];
  std::mutex _mutex;
  std::vector<uint8_t> _out;
  int _cols, _rows;
  BOOL _resize;
  BOOL _nawsEnabled;
  BOOL _binary;
  volatile BOOL _stop;
  NSString* _term;
  // Options we agreed to (RFC 1143: never answer a request for the state
  // we are already in, to avoid negotiation loops)
  BOOL _willOn[256];     // we WILL
  BOOL _doOn[256];       // they WILL (we sent DO)
}

- (instancetype)initWithHost:(NSString*)host port:(int)port
{
  self = [super init];
  if (self) {
    _host = [host copy];
    _port = port > 0 ? port : 23;
    _sock = -1;
    if (pipe(_wake) == 0) {
      fcntl(_wake[0], F_SETFL, O_NONBLOCK);
      fcntl(_wake[1], F_SETFL, O_NONBLOCK);
    }
  }
  return self;
}

- (void)dealloc
{
  close(_wake[0]);
  close(_wake[1]);
}

- (void)wake
{
  char c = 0;
  (void)!write(_wake[1], &c, 1);
}

- (void)write:(NSData*)data
{
  {
    std::lock_guard<std::mutex> lock(_mutex);
    const uint8_t* p = (const uint8_t*)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
      uint8_t c = p[i];
      if (c == IAC)
        _out.push_back(IAC);          // escape data 0xFF
      _out.push_back(c);
      // NVT: a bare CR must be followed by NUL (or LF) unless in binary mode
      if (c == '\r' && !_binary && !(i + 1 < data.length && p[i + 1] == '\n'))
        _out.push_back(0);
    }
  }
  [self wake];
}

- (void)resizeColumns:(int)columns rows:(int)rows
{
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _cols = columns;
    _rows = rows;
    _resize = YES;
  }
  [self wake];
}

- (void)disconnect
{
  _stop = YES;
  [self wake];
}

// Raw protocol bytes (not escaped)
- (void)queueCommand:(std::initializer_list<uint8_t>)bytes
{
  std::lock_guard<std::mutex> lock(_mutex);
  _out.insert(_out.end(), bytes.begin(), bytes.end());
}

- (void)queueNAWS
{
  std::lock_guard<std::mutex> lock(_mutex);
  uint8_t sz[4] = { (uint8_t)(_cols >> 8), (uint8_t)_cols, (uint8_t)(_rows >> 8), (uint8_t)_rows };
  _out.push_back(IAC); _out.push_back(SB); _out.push_back(OPT_NAWS);
  for (uint8_t b : sz) {
    if (b == IAC)
      _out.push_back(IAC);
    _out.push_back(b);
  }
  _out.push_back(IAC); _out.push_back(SE);
}

- (void)connectWithTerminal:(NSString*)term columns:(int)columns rows:(int)rows
                     output:(void (^)(NSData*))output closed:(void (^)(NSError*))closed
{
  _term = [term copy];
  _cols = columns;
  _rows = rows;
  _stop = NO;
  [NSThread detachNewThreadWithBlock:^{
    NSError* error = nil;
    [self runWithOutput:output error:&error];
    if (self->_sock >= 0) {
      close(self->_sock);
      self->_sock = -1;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ closed(error); });
  }];
}

- (void)handleOption:(uint8_t)cmd option:(uint8_t)opt
{
  switch (cmd) {
  case DO:
    if (_willOn[opt]) {
      if (opt == OPT_NAWS)
        [self queueNAWS];   // the server may want the size now
      break;
    }
    if (opt == OPT_TTYPE || opt == OPT_SGA || opt == OPT_BINARY) {
      _willOn[opt] = YES;
      [self queueCommand:{IAC, WILL, opt}];
      if (opt == OPT_BINARY)
        _binary = YES;
    } else if (opt == OPT_NAWS) {
      _willOn[opt] = YES;
      [self queueCommand:{IAC, WILL, OPT_NAWS}];
      _nawsEnabled = YES;
      [self queueNAWS];
    } else {
      [self queueCommand:{IAC, WONT, opt}];
    }
    break;
  case DONT:
    if (_willOn[opt]) {
      _willOn[opt] = NO;
      [self queueCommand:{IAC, WONT, opt}];
    }
    if (opt == OPT_NAWS)
      _nawsEnabled = NO;
    break;
  case WILL:
    if (_doOn[opt])
      break;
    // Let the server echo and suppress go-ahead (character mode)
    if (opt == OPT_ECHO || opt == OPT_SGA || opt == OPT_BINARY) {
      _doOn[opt] = YES;
      [self queueCommand:{IAC, DO, opt}];
    } else {
      [self queueCommand:{IAC, DONT, opt}];
    }
    break;
  case WONT:
    if (_doOn[opt]) {
      _doOn[opt] = NO;
      [self queueCommand:{IAC, DONT, opt}];
    }
    break;
  }
}

- (void)handleSubnegotiation:(const std::vector<uint8_t>&)sb
{
  if (sb.size() >= 2 && sb[0] == OPT_TTYPE && sb[1] == TTYPE_SEND) {
    std::string t = _term.uppercaseString.UTF8String;
    std::lock_guard<std::mutex> lock(_mutex);
    _out.push_back(IAC); _out.push_back(SB); _out.push_back(OPT_TTYPE); _out.push_back(TTYPE_IS);
    _out.insert(_out.end(), t.begin(), t.end());
    _out.push_back(IAC); _out.push_back(SE);
  }
}

- (void)runWithOutput:(void (^)(NSData*))output error:(NSError**)error
{
  _sock = ZVConnectTCP(_host, _port, &_stop, error);
  if (_sock < 0)
    return;
  fcntl(_sock, F_SETFL, O_NONBLOCK);

  // Offer what we support up front; many servers wait for the client
  _willOn[OPT_TTYPE] = _willOn[OPT_NAWS] = YES;
  _doOn[OPT_SGA] = _doOn[OPT_ECHO] = YES;
  _nawsEnabled = YES;
  [self queueCommand:{IAC, WILL, OPT_TTYPE}];
  [self queueCommand:{IAC, WILL, OPT_NAWS}];
  [self queueCommand:{IAC, DO, OPT_SGA}];
  [self queueCommand:{IAC, DO, OPT_ECHO}];

  enum { DATA, GOT_IAC, GOT_CMD, IN_SB, SB_IAC } state = DATA;
  uint8_t cmd = 0;
  std::vector<uint8_t> sb;
  std::vector<uint8_t> in(16384);

  while (!_stop) {
    // Pending output
    std::vector<uint8_t> out;
    BOOL resize = NO;
    {
      std::lock_guard<std::mutex> lock(_mutex);
      out.swap(_out);
      resize = _resize && _nawsEnabled;
      _resize = NO;
    }
    if (resize) {
      [self queueNAWS];
      std::lock_guard<std::mutex> lock(_mutex);
      out.insert(out.end(), _out.begin(), _out.end());
      _out.clear();
    }
    size_t off = 0;
    while (off < out.size()) {
      ssize_t n = send(_sock, out.data() + off, out.size() - off, 0);
      if (n > 0) {
        off += n;
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        struct pollfd p = { _sock, POLLOUT, 0 };
        poll(&p, 1, 1000);
        continue;
      }
      if (error)
        *error = [NSError errorWithDomain:@"ZeonVNC" code:errno
                                 userInfo:@{NSLocalizedDescriptionKey: @"Connection lost"}];
      return;
    }

    struct pollfd fds[2] = { { _sock, POLLIN, 0 }, { _wake[0], POLLIN, 0 } };
    poll(fds, 2, 1000);
    if (fds[1].revents) {
      char drain[64];
      while (read(_wake[0], drain, sizeof(drain)) > 0)
        ;
    }
    if (!(fds[0].revents & (POLLIN | POLLHUP | POLLERR)))
      continue;

    ssize_t n = recv(_sock, in.data(), in.size(), 0);
    if (n == 0)
      return;       // closed by the server
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      if (error)
        *error = [NSError errorWithDomain:@"ZeonVNC" code:errno
                                 userInfo:@{NSLocalizedDescriptionKey: @"Connection lost"}];
      return;
    }

    // Strip the telnet protocol from the data stream
    NSMutableData* text = [NSMutableData dataWithCapacity:n];
    for (ssize_t i = 0; i < n; i++) {
      uint8_t c = in[i];
      switch (state) {
      case DATA:
        if (c == IAC)
          state = GOT_IAC;
        else
          [text appendBytes:&c length:1];
        break;
      case GOT_IAC:
        if (c == IAC) {
          [text appendBytes:&c length:1];
          state = DATA;
        } else if (c == SB) {
          sb.clear();
          state = IN_SB;
        } else if (c == WILL || c == WONT || c == DO || c == DONT) {
          cmd = c;
          state = GOT_CMD;
        } else {
          state = DATA;     // NOP, GA, etc.
        }
        break;
      case GOT_CMD:
        [self handleOption:cmd option:c];
        state = DATA;
        break;
      case IN_SB:
        if (c == IAC)
          state = SB_IAC;
        else
          sb.push_back(c);
        break;
      case SB_IAC:
        if (c == SE) {
          [self handleSubnegotiation:sb];
          state = DATA;
        } else {
          sb.push_back(c);
          state = IN_SB;
        }
        break;
      }
    }
    if (text.length) {
      NSData* d = text;
      dispatch_async(dispatch_get_main_queue(), ^{ output(d); });
    }
  }
}

@end
