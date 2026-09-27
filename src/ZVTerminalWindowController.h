// ZeonVNC - SSH / Telnet terminal window
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

#import "ZVBookmark.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZVTerminalWindowController : NSWindowController <NSWindowDelegate>

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark;

@property (nonatomic, readonly) ZVBookmark* bookmark;
@property (nonatomic, readonly) BOOL isConnected;
// Tried first when logging in (memory only), e.g. the VNC password
@property (nonatomic, copy, nullable) NSString* offeredPassword;

- (void)start;

- (IBAction)reconnect:(nullable id)sender;
- (IBAction)disconnect:(nullable id)sender;
- (IBAction)showFileTransfer:(nullable id)sender;
- (IBAction)clearTerminal:(nullable id)sender;
- (IBAction)biggerFont:(nullable id)sender;
- (IBAction)smallerFont:(nullable id)sender;
- (IBAction)defaultFontSize:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
