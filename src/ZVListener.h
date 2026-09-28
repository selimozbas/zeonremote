// Zeon Remote - listens for reverse ("listening viewer") connections, as
// used by UltraVNC / TightVNC servers' "Add new client" feature.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVListener : NSObject

// Called on the main thread with an accepted socket and the peer address
@property (nonatomic, copy, nullable) void (^onConnection)(int fd, NSString* peer);

@property (nonatomic, readonly) BOOL isListening;
@property (nonatomic, readonly) int port;

- (BOOL)startOnPort:(int)port error:(NSError**)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
