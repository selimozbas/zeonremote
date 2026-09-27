// ZeonVNC - Telnet client (RFC 854) with terminal type (RFC 1091),
// window size (NAWS, RFC 1073), echo and suppress-go-ahead negotiation
//
// Telnet is not encrypted; it is meant for devices that don't offer SSH
// (switches, routers, embedded boards).
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVTelnetClient : NSObject

- (instancetype)initWithHost:(NSString*)host port:(int)port;

@property (nonatomic, readonly, copy) NSString* host;

// "output" and "closed" are called on the main thread
- (void)connectWithTerminal:(NSString*)term
                    columns:(int)columns rows:(int)rows
                     output:(void (^)(NSData* data))output
                     closed:(void (^)(NSError* _Nullable error))closed;
- (void)write:(NSData*)data;
- (void)resizeColumns:(int)columns rows:(int)rows;
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
