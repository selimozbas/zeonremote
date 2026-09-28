// Zeon Remote - methods of ZVSession for its subclasses (ZVRDPSession) and the
// protocol threads. Objective-C++ only.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVSession.h"

#include <string>

NS_ASSUME_NONNULL_BEGIN

@interface ZVSession ()
- (BOOL)canSendInput;
- (void)_setState:(ZVSessionState)state;
- (void)_didInitWithName:(NSString*)name mac:(nullable NSString*)mac key:(nullable NSString*)key;
- (BOOL)_verifyServerKey:(NSString*)fingerprint mac:(nullable NSString*)mac;
- (void)_framebufferChanged:(IOSurfaceRef)surface width:(int)w height:(int)h;
- (void)_framebufferUpdated;
- (void)_nameChanged:(NSString*)name;
- (void)_cursorChanged:(NSData*)rgba width:(int)w height:(int)h hotspot:(NSPoint)hs;
- (void)_remoteClipboard:(NSString*)text;
- (void)_bell;
- (void)_closed:(ZVCloseReason)reason message:(nullable NSString*)message;
- (BOOL)_credentialsUser:(BOOL)needUser secure:(BOOL)secure
                     mac:(nullable NSString*)mac key:(nullable NSString*)key
                username:(std::string*)user password:(std::string*)pass;
- (BOOL)_message:(NSString*)text title:(NSString*)title yesNo:(BOOL)yesNo
           style:(NSAlertStyle)style;
@end

NS_ASSUME_NONNULL_END
