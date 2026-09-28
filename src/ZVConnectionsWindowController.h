// Zeon Remote - connection manager (address book + quick connect)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ZVBookmark;

@protocol ZVConnectionsDelegate <NSObject>
- (void)openSessionForBookmark:(ZVBookmark*)bookmark;
@end

@interface ZVConnectionsWindowController : NSWindowController

@property (nonatomic, weak) id<ZVConnectionsDelegate> delegate;

- (IBAction)newBookmark:(nullable id)sender;
- (IBAction)deleteBookmark:(nullable id)sender;
- (IBAction)duplicateBookmark:(nullable id)sender;
- (IBAction)connectSelected:(nullable id)sender;
- (IBAction)importBookmarks:(nullable id)sender;
- (IBAction)exportBookmarks:(nullable id)sender;
- (void)focusQuickConnect;

@end

NS_ASSUME_NONNULL_END
