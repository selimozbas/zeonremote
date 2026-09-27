// ZeonVNC - watches the local pasteboard and applies remote clipboard
// contents without echoing them back.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// userInfo[@"text"] holds the new text (absent if not text)
extern NSNotificationName const ZVLocalClipboardChangedNotification;

@interface ZVClipboard : NSObject

+ (instancetype)shared;

- (void)start;
- (nullable NSString*)currentText;
- (void)setRemoteText:(NSString*)text;

@end

NS_ASSUME_NONNULL_END
