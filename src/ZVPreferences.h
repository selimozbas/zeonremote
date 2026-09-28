// Zeon Remote - application preferences
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const ZVPrefPassCommandShortcuts; // BOOL
extern NSString* const ZVPrefDefaultCommandKey;     // ZVCommandKeyMode
extern NSString* const ZVPrefDefaultQuality;        // ZVQualityPreset
extern NSString* const ZVPrefDefaultScale;          // ZVScaleMode
extern NSString* const ZVPrefSharpScaling;          // BOOL
extern NSString* const ZVPrefSecurityMode;          // 0 any, 1 encrypted only
extern NSString* const ZVPrefListenEnabled;         // BOOL
extern NSString* const ZVPrefListenPort;            // int
extern NSString* const ZVPrefConfirmQuit;           // BOOL
extern NSString* const ZVPrefRememberPasswords;     // BOOL, default for the login dialog

extern NSNotificationName const ZVPreferencesChangedNotification;

@interface ZVPreferences : NSObject
+ (void)registerDefaults;
// Pushes settings into the protocol core (security types, ...)
+ (void)applyCoreSettings;
@end

@interface ZVPreferencesWindowController : NSWindowController
@end

NS_ASSUME_NONNULL_END
