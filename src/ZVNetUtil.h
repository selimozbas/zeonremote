// ZeonVNC - small networking helpers shared by VNC, SSH and Telnet
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// "mac:aa:bb:cc:dd:ee:ff" of a connected peer on the local network (from
// the ARP table), or nil for peers behind a router / not on IPv4. Retries
// briefly since the ARP entry can be refreshing.
NSString* _Nullable ZVMACAddressOfPeer(int fd);

// Connects a blocking TCP socket with a timeout. Retries EHOSTUNREACH for
// a few seconds (macOS rejects the first local network connection while
// it checks the Local Network permission). *cancel is polled if given.
int ZVConnectTCP(NSString* host, int port, volatile BOOL* _Nullable cancel,
                 NSError* _Nullable * _Nullable error);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
