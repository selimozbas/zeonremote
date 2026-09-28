// Zeon Remote - application delegate
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Routes keyboard events straight to the remote view so that ⌘
// shortcuts, key releases while ⌘ is held, etc. reach the server.
@interface ZVApplication : NSApplication
@end

@class ZVBookmark;

@interface ZVAppDelegate : NSObject <NSApplicationDelegate>
- (void)openSessionForBookmark:(ZVBookmark*)bookmark;
// SSH / Telnet terminal; "password" is tried before asking (memory only)
- (void)openTerminalForBookmark:(ZVBookmark*)bookmark password:(nullable NSString*)password;
@end

NS_ASSUME_NONNULL_END
