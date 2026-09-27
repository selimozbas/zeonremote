// ZeonVNC - window hosting a single remote desktop session
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

#import "ZVBookmark.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVSession;
@class ZVRemoteView;

@interface ZVSessionWindowController : NSWindowController <NSWindowDelegate>

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark;
// For reverse connections accepted by the listener (takes ownership of fd)
- (instancetype)initWithBookmark:(ZVBookmark*)bookmark incomingSocket:(int)fd;

@property (nonatomic, readonly) ZVSession* session;
@property (nonatomic, readonly) ZVRemoteView* remoteView;
@property (nonatomic, readonly) ZVBookmark* bookmark;

- (void)start;

// Menu / toolbar actions
- (IBAction)sendCtrlAltDel:(nullable id)sender;
- (IBAction)sendCtrlEsc:(nullable id)sender;
- (IBAction)sendAltTab:(nullable id)sender;
- (IBAction)sendAltF4:(nullable id)sender;
- (IBAction)sendWindowsKey:(nullable id)sender;
- (IBAction)sendCtrlShiftEsc:(nullable id)sender;
- (IBAction)sendWinL:(nullable id)sender;
- (IBAction)sendWinR:(nullable id)sender;
- (IBAction)sendWinE:(nullable id)sender;
- (IBAction)sendWinD:(nullable id)sender;
- (IBAction)sendPrintScreen:(nullable id)sender;
- (IBAction)refreshScreen:(nullable id)sender;
- (IBAction)toggleViewOnly:(nullable id)sender;
- (IBAction)toggleStats:(nullable id)sender;
- (IBAction)showConnectionInfo:(nullable id)sender;
- (IBAction)takeScreenshot:(nullable id)sender;
- (IBAction)copyScreenshot:(nullable id)sender;
- (IBAction)typeClipboard:(nullable id)sender;
- (IBAction)setScaleFit:(nullable id)sender;
- (IBAction)setScale100:(nullable id)sender;
- (IBAction)setScaleNative:(nullable id)sender;
- (IBAction)setScaleFill:(nullable id)sender;
- (IBAction)zoomIn:(nullable id)sender;
- (IBAction)zoomOut:(nullable id)sender;
- (IBAction)sizeWindowToRemote:(nullable id)sender;
- (IBAction)toggleSmoothScaling:(nullable id)sender;
- (IBAction)setQualityPreset:(nullable id)sender;   // tag = ZVQualityPreset
- (IBAction)setCommandKeyMode:(nullable id)sender;  // tag = ZVCommandKeyMode
- (IBAction)setKeyboardMode:(nullable id)sender;    // tag = ZVKeyboardMode
- (IBAction)toggleRemoteResize:(nullable id)sender;
- (IBAction)disconnect:(nullable id)sender;
- (IBAction)reconnect:(nullable id)sender;
- (IBAction)saveAsBookmark:(nullable id)sender;
- (IBAction)showFileTransfer:(nullable id)sender;
- (IBAction)openSSHTerminal:(nullable id)sender;

// Called by the app when the local pasteboard changed
- (void)localClipboardChanged:(nullable NSString*)text;

@end

NS_ASSUME_NONNULL_END
