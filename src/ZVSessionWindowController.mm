// Zeon Remote - window hosting a single remote desktop session
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define XK_LATIN1
#define XK_MISCELLANY
#include <rfb/keysymdef.h>

#import "ZVSessionWindowController.h"
#import "ZVSession.h"
#import "ZVRemoteView.h"
#import "ZVClipboard.h"
#import "ZVPreferences.h"
#import "ZVFileTransferWindowController.h"
#import "ZVAppDelegate.h"

static NSToolbarItemIdentifier const kTBCtrlAltDel = @"ctrlaltdel";
static NSToolbarItemIdentifier const kTBKeys = @"keys";
static NSToolbarItemIdentifier const kTBRefresh = @"refresh";
static NSToolbarItemIdentifier const kTBScale = @"scale";
static NSToolbarItemIdentifier const kTBQuality = @"quality";
static NSToolbarItemIdentifier const kTBViewOnly = @"viewonly";
static NSToolbarItemIdentifier const kTBClipboard = @"clipboard";
static NSToolbarItemIdentifier const kTBScreenshot = @"screenshot";
static NSToolbarItemIdentifier const kTBStats = @"stats";
static NSToolbarItemIdentifier const kTBFullScreen = @"fullscreen";
static NSToolbarItemIdentifier const kTBDisconnect = @"disconnect";
static NSToolbarItemIdentifier const kTBFiles = @"files";
static NSToolbarItemIdentifier const kTBTerminal = @"terminal";

static const int kMaxReconnectAttempts = 20;

#pragma mark - Overlay

// Centered panel used for "connecting" and "disconnected" states
@interface ZVOverlayView : NSVisualEffectView
@property (nonatomic, strong) NSProgressIndicator* spinner;
@property (nonatomic, strong) NSTextField* titleLabel;
@property (nonatomic, strong) NSTextField* detailLabel;
@property (nonatomic, strong) NSStackView* buttons;
@end

@implementation ZVOverlayView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    self.material = NSVisualEffectMaterialHUDWindow;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 14;
    self.layer.masksToBounds = YES;

    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeRegular;

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    _titleLabel.alignment = NSTextAlignmentCenter;

    _detailLabel = [NSTextField wrappingLabelWithString:@""];
    _detailLabel.font = [NSFont systemFontOfSize:12];
    _detailLabel.textColor = [NSColor secondaryLabelColor];
    _detailLabel.alignment = NSTextAlignmentCenter;
    _detailLabel.preferredMaxLayoutWidth = 360;

    _buttons = [[NSStackView alloc] init];
    _buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _buttons.spacing = 10;

    NSStackView* stack = [NSStackView stackViewWithViews:@[_spinner, _titleLabel, _detailLabel, _buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(22, 28, 22, 28);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
      [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [self.widthAnchor constraintGreaterThanOrEqualToConstant:300],
      [self.widthAnchor constraintLessThanOrEqualToConstant:440],
    ]];
  }
  return self;
}

- (void)showBusy:(BOOL)busy title:(NSString*)title detail:(NSString*)detail
         buttons:(NSArray<NSButton*>*)buttons
{
  _spinner.hidden = !busy;
  if (busy)
    [_spinner startAnimation:nil];
  else
    [_spinner stopAnimation:nil];
  _titleLabel.stringValue = title;
  _detailLabel.stringValue = detail ?: @"";
  _detailLabel.hidden = detail.length == 0;
  for (NSView* v in [_buttons.arrangedSubviews copy])
    [v removeFromSuperview];
  for (NSButton* b in buttons)
    [_buttons addArrangedSubview:b];
  _buttons.hidden = buttons.count == 0;
  self.hidden = NO;
}

@end

#pragma mark - Window controller

@interface ZVSessionWindowController () <ZVSessionDelegate, ZVRemoteViewDelegate,
                                         NSToolbarDelegate>
@end

@implementation ZVSessionWindowController {
  ZVSession* _session;
  ZVRemoteView* _remoteView;
  ZVBookmark* _bookmark;
  ZVOverlayView* _overlay;
  NSVisualEffectView* _statsPanel;
  NSTextField* _statsLabel;
  NSTimer* _statsTimer;

  BOOL _everConnected;
  BOOL _sizedToRemote;
  BOOL _userClosing;
  BOOL _inFullScreen;
  int _reconnectAttempt;
  NSTimer* _reconnectTimer;
  int _reconnectCountdown;
  NSTimer* _resizeTimer;

  ZVFileTransferWindowController* _files;
  NSVisualEffectView* _uploadHUD;
  NSTextField* _uploadLabel;
  NSProgressIndicator* _uploadProgress;

}

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark
{
  return [self initWithBookmark:bookmark incomingSocket:-1];
}

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark incomingSocket:(int)fd
{
  NSRect frame = NSMakeRect(0, 0, 1024, 700);
  NSWindow* window = [[NSWindow alloc]
                       initWithContentRect:frame
                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                           NSWindowStyleMaskFullSizeContentView
                                   backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:window];
  if (self) {
    _bookmark = [bookmark copy];

    window.title = [bookmark displayName];
    window.subtitle = @"Connecting…";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    window.tabbingMode = NSWindowTabbingModePreferred;
    window.tabbingIdentifier = @"ZeonVNCSession";
    window.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0];
    window.titlebarAppearsTransparent = NO;
    window.minSize = NSMakeSize(320, 240);
    [window center];

    _remoteView = [[ZVRemoteView alloc] initWithFrame:frame];
    _remoteView.viewDelegate = self;
    _remoteView.scaleMode = bookmark.scaleMode;
    _remoteView.commandKeyMode = bookmark.commandKeyMode;
    _remoteView.keyboardMode = bookmark.keyboardMode;
    _remoteView.showDotForInvisibleCursor = bookmark.showRemoteCursor;
    _remoteView.smoothScaling = ![[NSUserDefaults standardUserDefaults] boolForKey:@"ZVSharpScaling"];

    NSView* content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    window.contentView = content;

    _remoteView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_remoteView];
    NSLayoutGuide* safe = content.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
      [_remoteView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
      [_remoteView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
      [_remoteView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
      [_remoteView.topAnchor constraintEqualToAnchor:safe.topAnchor],
    ]];

    _overlay = [[ZVOverlayView alloc] initWithFrame:NSZeroRect];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_overlay];
    [NSLayoutConstraint activateConstraints:@[
      [_overlay.centerXAnchor constraintEqualToAnchor:_remoteView.centerXAnchor],
      [_overlay.centerYAnchor constraintEqualToAnchor:_remoteView.centerYAnchor],
    ]];

    [self buildStatsPanel];

    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:@"ZVSessionToolbar2"];
    tb.delegate = self;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    tb.allowsUserCustomization = YES;
    tb.autosavesConfiguration = YES;
    window.toolbar = tb;
    window.toolbarStyle = NSWindowToolbarStyleUnified;

    if (fd >= 0) {
      _session = [[ZVSession alloc] initWithBookmark:bookmark connectedSocket:fd];
      _bookmark.autoReconnect = NO;
    } else {
      _session = [ZVSession sessionWithBookmark:bookmark];
    }
    _session.delegate = self;
    _remoteView.session = _session;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clipboardNotification:)
                                                 name:ZVLocalClipboardChangedNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_statsTimer invalidate];
  [_reconnectTimer invalidate];
  [_resizeTimer invalidate];
}

- (ZVSession*)session { return _session; }
- (ZVRemoteView*)remoteView { return _remoteView; }
- (ZVBookmark*)bookmark { return _bookmark; }

- (void)start
{
  [self showWindow:nil];
  [self.window makeFirstResponder:_remoteView];
  [self showConnecting];
  [_session connect];
}

#pragma mark Overlay states

- (NSButton*)buttonWithTitle:(NSString*)title action:(SEL)action primary:(BOOL)primary
{
  NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
  b.bezelStyle = NSBezelStyleRounded;
  if (primary)
    b.keyEquivalent = @"\r";
  return b;
}

- (void)showConnecting
{
  NSString* title = _reconnectAttempt > 0
    ? [NSString stringWithFormat:@"Reconnecting (attempt %d)…", _reconnectAttempt]
    : @"Connecting…";
  [_overlay showBusy:YES title:title detail:_bookmark.host
             buttons:@[[self buttonWithTitle:@"Cancel" action:@selector(cancelConnect:) primary:NO]]];
}

- (void)cancelConnect:(id)sender
{
  [_reconnectTimer invalidate];
  _reconnectTimer = nil;
  _userClosing = YES;
  [_session disconnect];
  [self.window close];
}

- (void)showDisconnected:(NSString*)title detail:(NSString*)detail
{
  NSMutableArray* buttons = [NSMutableArray array];
  [buttons addObject:[self buttonWithTitle:@"Close" action:@selector(closeWindow:)
                                   primary:_session.isReverseConnection]];
  if (!_session.isReverseConnection)
    [buttons addObject:[self buttonWithTitle:@"Reconnect" action:@selector(reconnect:) primary:YES]];
  [_overlay showBusy:NO title:title detail:detail buttons:buttons];
}

- (void)closeWindow:(id)sender
{
  [self.window close];
}

#pragma mark Stats panel

- (void)buildStatsPanel
{
  _statsPanel = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
  _statsPanel.material = NSVisualEffectMaterialHUDWindow;
  _statsPanel.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  _statsPanel.state = NSVisualEffectStateActive;
  _statsPanel.wantsLayer = YES;
  _statsPanel.layer.cornerRadius = 8;
  _statsPanel.translatesAutoresizingMaskIntoConstraints = NO;
  _statsPanel.hidden = YES;

  _statsLabel = [NSTextField labelWithString:@""];
  _statsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
  _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [_statsPanel addSubview:_statsLabel];

  NSView* content = self.window.contentView;
  [content addSubview:_statsPanel];
  [NSLayoutConstraint activateConstraints:@[
    [_statsLabel.leadingAnchor constraintEqualToAnchor:_statsPanel.leadingAnchor constant:10],
    [_statsLabel.trailingAnchor constraintEqualToAnchor:_statsPanel.trailingAnchor constant:-10],
    [_statsLabel.topAnchor constraintEqualToAnchor:_statsPanel.topAnchor constant:6],
    [_statsLabel.bottomAnchor constraintEqualToAnchor:_statsPanel.bottomAnchor constant:-6],
    [_statsPanel.trailingAnchor constraintEqualToAnchor:_remoteView.trailingAnchor constant:-12],
    [_statsPanel.topAnchor constraintEqualToAnchor:_remoteView.topAnchor constant:12],
  ]];
}

- (IBAction)toggleStats:(id)sender
{
  _statsPanel.hidden = !_statsPanel.hidden;
  if (!_statsPanel.hidden) {
    [self updateStats:nil];
    _statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                 selector:@selector(updateStats:)
                                                 userInfo:nil repeats:YES];
  } else {
    [_statsTimer invalidate];
    _statsTimer = nil;
  }
}

- (void)updateStats:(NSTimer*)t
{
  ZVSessionStats s = [_session stats];
  NSSize fb = _session.framebufferSize;
  NSString* quality = s.jpegQuality >= 0 ? [NSString stringWithFormat:@"JPEG %d", s.jpegQuality]
                                         : @"lossless";
  NSString* encoding = [ZVSession nameForEncoding:s.lastEncoding];
  if ([encoding isEqualToString:@"H.264"])
    quality = @"hardware decoded";
  double speed = s.kbitsPerSecond;
  NSString* rate = speed >= 1000 ? [NSString stringWithFormat:@"%.1f Mbit/s", speed / 1000]
                                 : [NSString stringWithFormat:@"%.0f kbit/s", speed];
  _statsLabel.stringValue =
    [NSString stringWithFormat:@"%.0f × %.0f   %.0f%%\n%.1f upd/s   %.1f Mpx/s\n%@   %@ (%@)\nLink ≈ %.1f Mbit/s",
     fb.width, fb.height, [_remoteView effectiveScale] * 100,
     s.updatesPerSecond, s.megapixelsPerSecond,
     rate, encoding, quality, s.lineSpeedKbps / 1000.0];
}

#pragma mark ZVSessionDelegate

- (void)session:(ZVSession*)session stateChanged:(ZVSessionState)state
{
  switch (state) {
  case ZVSessionConnecting:
    self.window.subtitle = @"Connecting…";
    [self showConnecting];
    break;
  case ZVSessionAuthenticating:
    self.window.subtitle = @"Authenticating…";
    _overlay.titleLabel.stringValue = @"Authenticating…";
    break;
  case ZVSessionConnected:
    _everConnected = YES;
    _reconnectAttempt = 0;
    _overlay.hidden = YES;
    [_remoteView setNeedsDisplay:YES];
    [self.window makeFirstResponder:_remoteView];
    [[ZVBookmarkStore sharedStore] noteConnectedTo:_bookmark];
    // Let the server know what we have right now
    if (_bookmark.shareClipboard) {
      NSString* text = [[ZVClipboard shared] currentText];
      if (text)
        [_session localClipboardChanged:text];
    }
    if (_bookmark.fullScreen && !_inFullScreen)
      [self.window toggleFullScreen:nil];
    break;
  default:
    break;
  }
  [self updateSubtitle];
  [self.window.toolbar validateVisibleItems];
}

- (void)updateSubtitle
{
  if (_session.state != ZVSessionConnected)
    return;
  NSSize fb = _session.framebufferSize;
  NSString* lock = [_session isSecure] ? @"🔒 " : @"";
  NSString* vo = _session.viewOnly ? @" — view only" : @"";
  self.window.subtitle = [NSString stringWithFormat:@"%@%@ — %.0f×%.0f%@",
                          lock, _bookmark.host, fb.width, fb.height, vo];
}

- (void)session:(ZVSession*)session framebufferChanged:(IOSurfaceRef)surface
{
  [_remoteView setSurface:surface];
  if (!_sizedToRemote) {
    _sizedToRemote = YES;
    [self sizeWindowToRemote:nil];
  }
  [self updateSubtitle];
}

- (void)sessionFramebufferUpdated:(ZVSession*)session
{
  [_remoteView framebufferUpdated];
}

- (void)session:(ZVSession*)session desktopNameChanged:(NSString*)name
{
  if (_bookmark.name.length)
    self.window.title = [NSString stringWithFormat:@"%@ — %@", _bookmark.name, name];
  else
    self.window.title = name.length ? name : _bookmark.host;
}

- (void)session:(ZVSession*)session cursorChanged:(NSImage*)image hotspot:(NSPoint)hotspot
{
  [_remoteView setRemoteCursor:image hotspot:hotspot];
}

- (void)session:(ZVSession*)session remoteClipboard:(NSString*)text
{
  [[ZVClipboard shared] setRemoteText:text];
}

- (void)sessionBell:(ZVSession*)session
{
  NSBeep();
}

- (void)session:(ZVSession*)session closedWithReason:(ZVCloseReason)reason
        message:(NSString*)message
{
  [self.window.toolbar validateVisibleItems];
  if (_userClosing)
    return;

  switch (reason) {
  case ZVCloseByUser:
  case ZVCloseAuthCancelled:
    if (!_everConnected) {
      [self.window close];
      return;
    }
    [self showDisconnected:@"Disconnected" detail:nil];
    break;

  case ZVCloseAuthFailed: {
    NSString* detail = message;
    if (detail.length == 0 || [detail caseInsensitiveCompare:@"Authentication failed"] == NSOrderedSame)
      detail = @"The server did not accept the user name or password. "
               @"Press Reconnect to enter it again.";
    [self showDisconnected:@"Authentication failed" detail:detail];
    break;
  }

  case ZVCloseByServer:
  case ZVCloseError:
  case ZVCloseConnectFailed:
    // macOS blocks local network access until the user allows it, which
    // shows up as "No route to host" for LAN addresses
    if ([message containsString:@"(65)"]) {
      message = [message stringByAppendingString:
                 @"\n\nIf this computer is on your local network, allow Zeon Remote in "
                 @"System Settings → Privacy & Security → Local Network."];
    }
    if ((_everConnected || _reconnectAttempt > 0) && _bookmark.autoReconnect &&
        _reconnectAttempt < kMaxReconnectAttempts) {
      [self scheduleReconnect:message];
    } else {
      NSString* title = reason == ZVCloseConnectFailed ? @"Unable to connect"
                                                       : @"Connection lost";
      [self showDisconnected:title detail:message];
    }
    break;
  }
  self.window.subtitle = @"Disconnected";
}

- (void)scheduleReconnect:(NSString*)message
{
  _reconnectAttempt++;
  // 2, 3, 5, 8 ... seconds, capped at 30
  int delay = MIN(30, 2 + (_reconnectAttempt - 1) * (_reconnectAttempt) / 2);
  _reconnectCountdown = delay;
  [self updateReconnectOverlay:message];
  [_reconnectTimer invalidate];
  _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                   selector:@selector(reconnectTick:)
                                                   userInfo:message repeats:YES];
}

- (void)updateReconnectOverlay:(NSString*)message
{
  NSString* detail = [NSString stringWithFormat:@"Reconnecting in %d s…%@%@",
                      _reconnectCountdown, message.length ? @"\n" : @"", message ?: @""];
  [_overlay showBusy:YES title:@"Connection lost" detail:detail
             buttons:@[[self buttonWithTitle:@"Close" action:@selector(cancelConnect:) primary:NO],
                       [self buttonWithTitle:@"Reconnect Now" action:@selector(reconnect:) primary:YES]]];
}

- (void)reconnectTick:(NSTimer*)t
{
  _reconnectCountdown--;
  if (_reconnectCountdown <= 0) {
    [_reconnectTimer invalidate];
    _reconnectTimer = nil;
    [self showConnecting];
    [_session connect];
    return;
  }
  [self updateReconnectOverlay:t.userInfo];
}

- (IBAction)reconnect:(id)sender
{
  [_reconnectTimer invalidate];
  _reconnectTimer = nil;
  if (_session.state != ZVSessionDisconnected && _session.state != ZVSessionIdle)
    return;
  if (_session.isReverseConnection)
    return;
  [self showConnecting];
  [_session connect];
}

- (BOOL)session:(ZVSession*)session
    wantsCredentialsWithUsername:(BOOL)needUsername
                          secure:(BOOL)secure
                         warning:(NSString*)warning
                          device:(NSString*)device
                        username:(NSString**)username
                        password:(NSString**)password
                        remember:(BOOL*)rememberOut
{
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Log in to %@", _bookmark.displayName];
  NSMutableArray* info = [NSMutableArray array];
  if (warning) {
    alert.alertStyle = NSAlertStyleWarning;
    [info addObject:warning];
  }
  if (device)
    [info addObject:device];
  [info addObject:secure
    ? @"The connection is encrypted."
    : @"This connection is not encrypted. The password is protected, but the session data is not."];
  alert.informativeText = [info componentsJoinedByString:@"\n\n"];
  [alert addButtonWithTitle:@"Connect"];
  [alert addButtonWithTitle:@"Cancel"];

  NSTextField* userField = nil;
  NSSecureTextField* passField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  passField.placeholderString = @"Password";
  BOOL savingEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];
  NSButton* remember = [NSButton checkboxWithTitle:savingEnabled
                                                     ? @"Save password in Keychain"
                                                     : @"Save password (turned off in Settings)"
                                            target:nil action:nil];
  remember.state = savingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  remember.enabled = savingEnabled;

  NSMutableArray* views = [NSMutableArray array];
  if (needUsername) {
    userField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    userField.placeholderString = @"User name";
    userField.stringValue = *username ?: @"";
    [views addObject:userField];
  }
  [views addObject:passField];
  [views addObject:remember];

  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  for (NSView* v in @[passField]) {
    [v.widthAnchor constraintEqualToConstant:260].active = YES;
  }
  if (userField)
    [userField.widthAnchor constraintEqualToConstant:260].active = YES;
  stack.frame = NSMakeRect(0, 0, 260, needUsername ? 88 : 56);
  alert.accessoryView = stack;
  alert.window.initialFirstResponder = (userField && userField.stringValue.length == 0) ? userField : passField;

  NSModalResponse r = [alert runModal];
  if (r != NSAlertFirstButtonReturn)
    return NO;

  if (userField) {
    *username = userField.stringValue;
    if (!_bookmark.isTransient && ![_bookmark.username isEqualToString:userField.stringValue]) {
      _bookmark.username = userField.stringValue;
      [[ZVBookmarkStore sharedStore] updateBookmark:_bookmark];
    }
  }
  *password = passField.stringValue;
  *rememberOut = savingEnabled && remember.state == NSControlStateValueOn;
  return YES;
}

- (BOOL)session:(ZVSession*)session showMessage:(NSString*)text title:(NSString*)title
      questions:(BOOL)yesNo style:(NSAlertStyle)style
{
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = title;
  alert.informativeText = text;
  alert.alertStyle = style;
  if (yesNo) {
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
  } else {
    [alert addButtonWithTitle:@"OK"];
  }
  return [alert runModal] == NSAlertFirstButtonReturn;
}

#pragma mark ZVRemoteViewDelegate

- (void)remoteViewDidChangeZoom:(ZVRemoteView*)view
{
  _bookmark.scaleMode = view.scaleMode;
  [self.window.toolbar validateVisibleItems];
}

#pragma mark Window delegate

- (void)windowDidResignKey:(NSNotification*)notification
{
  // Avoid stuck modifiers when focus moves elsewhere
  [_remoteView releaseKeys];
}

- (void)windowDidResize:(NSNotification*)notification
{
  if (!_bookmark.remoteResize)
    return;
  [_resizeTimer invalidate];
  _resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self
                                                selector:@selector(sendRemoteResize:)
                                                userInfo:nil repeats:NO];
}

- (void)sendRemoteResize:(NSTimer*)t
{
  _resizeTimer = nil;
  if (![_session supportsRemoteResize])
    return;
  NSSize size = _remoteView.bounds.size;
  if (_remoteView.scaleMode == ZVScaleNativePixels) {
    CGFloat bs = self.window.backingScaleFactor;
    size = NSMakeSize(size.width * bs, size.height * bs);
  }
  [_session requestRemoteSize:NSMakeSize(floor(size.width), floor(size.height))];
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification
{
  _inFullScreen = YES;
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification
{
  [self windowDidResize:notification];
}

- (void)windowDidExitFullScreen:(NSNotification*)notification
{
  _inFullScreen = NO;
  [self windowDidResize:notification];
}

- (void)windowWillClose:(NSNotification*)notification
{
  _userClosing = YES;
  [_reconnectTimer invalidate];
  _reconnectTimer = nil;
  [_statsTimer invalidate];
  _statsTimer = nil;
  [_session disconnect];
  [_files close];
  _files = nil;
  [[NSNotificationCenter defaultCenter] postNotificationName:@"ZVSessionWindowClosed" object:self];
}

#pragma mark Clipboard

- (void)clipboardNotification:(NSNotification*)n
{
  [self localClipboardChanged:n.userInfo[@"text"]];
}

- (void)localClipboardChanged:(NSString*)text
{
  if (!_bookmark.shareClipboard || _session.state != ZVSessionConnected)
    return;
  [_session localClipboardChanged:text];
}

- (IBAction)typeClipboard:(id)sender
{
  NSString* text = [[ZVClipboard shared] currentText];
  if (text.length == 0) {
    NSBeep();
    return;
  }
  if (text.length > 4096) {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"Type a long text?";
    a.informativeText = [NSString stringWithFormat:@"The clipboard contains %lu characters.",
                         (unsigned long)text.length];
    [a addButtonWithTitle:@"Type"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn)
      return;
  }
  [_session typeText:text];
}

#pragma mark Special keys

- (IBAction)sendCtrlAltDel:(id)sender { [_session sendKeyCombo:@[@(XK_Control_L), @(XK_Alt_L), @(XK_Delete)]]; }
- (IBAction)sendCtrlEsc:(id)sender { [_session sendKeyCombo:@[@(XK_Control_L), @(XK_Escape)]]; }
- (IBAction)sendAltTab:(id)sender { [_session sendKeyCombo:@[@(XK_Alt_L), @(XK_Tab)]]; }
- (IBAction)sendAltF4:(id)sender { [_session sendKeyCombo:@[@(XK_Alt_L), @(XK_F4)]]; }
- (IBAction)sendWindowsKey:(id)sender { [_session sendKeyCombo:@[@(XK_Super_L)]]; }
- (IBAction)sendCtrlShiftEsc:(id)sender { [_session sendKeyCombo:@[@(XK_Control_L), @(XK_Shift_L), @(XK_Escape)]]; }
- (IBAction)sendWinL:(id)sender { [_session sendKeyCombo:@[@(XK_Super_L), @(XK_l)]]; }
- (IBAction)sendWinR:(id)sender { [_session sendKeyCombo:@[@(XK_Super_L), @(XK_r)]]; }
- (IBAction)sendWinE:(id)sender { [_session sendKeyCombo:@[@(XK_Super_L), @(XK_e)]]; }
- (IBAction)sendWinD:(id)sender { [_session sendKeyCombo:@[@(XK_Super_L), @(XK_d)]]; }
- (IBAction)sendPrintScreen:(id)sender { [_session sendKeyCombo:@[@(XK_Print)]]; }

#pragma mark View actions

- (IBAction)refreshScreen:(id)sender
{
  [_session refreshScreen];
}

- (IBAction)toggleViewOnly:(id)sender
{
  if (!_session.viewOnly)
    [_session releaseAllKeys];
  _session.viewOnly = !_session.viewOnly;
  _bookmark.viewOnly = _session.viewOnly;
  [_remoteView setRemoteCursor:nil hotspot:NSZeroPoint];
  [_session refreshScreen]; // re-sends the cursor
  [self updateSubtitle];
  [self.window.toolbar validateVisibleItems];
}

- (void)applyScaleMode:(ZVScaleMode)mode
{
  _remoteView.scaleMode = mode;
  _bookmark.scaleMode = mode;
  [self persistBookmarkSetting];
  [self.window.toolbar validateVisibleItems];
}

- (IBAction)setScaleFit:(id)sender { [self applyScaleMode:ZVScaleFit]; }
- (IBAction)setScaleFill:(id)sender { [self applyScaleMode:ZVScaleFill]; }
- (IBAction)setScaleNative:(id)sender { [self applyScaleMode:ZVScaleNativePixels]; }

- (IBAction)setScale100:(id)sender
{
  _remoteView.zoom = 1.0;
  [self applyScaleMode:ZVScale100];
}

- (IBAction)zoomIn:(id)sender
{
  CGFloat z = _remoteView.scaleMode == ZVScale100 ? _remoteView.zoom : [_remoteView effectiveScale];
  _remoteView.zoom = MIN(4.0, round((z + 0.25) * 4) / 4);
  [self applyScaleMode:ZVScale100];
}

- (IBAction)zoomOut:(id)sender
{
  CGFloat z = _remoteView.scaleMode == ZVScale100 ? _remoteView.zoom : [_remoteView effectiveScale];
  _remoteView.zoom = MAX(0.25, round((z - 0.25) * 4) / 4);
  [self applyScaleMode:ZVScale100];
}

- (IBAction)toggleSmoothScaling:(id)sender
{
  _remoteView.smoothScaling = !_remoteView.smoothScaling;
  [[NSUserDefaults standardUserDefaults] setBool:!_remoteView.smoothScaling forKey:@"ZVSharpScaling"];
}

- (IBAction)sizeWindowToRemote:(id)sender
{
  if (_inFullScreen)
    return;
  NSSize natural = _remoteView.scaleMode == ZVScaleNativePixels || _remoteView.scaleMode == ZVScale100
    ? [_remoteView naturalContentSize] : _session.framebufferSize;
  if (natural.width <= 0 || natural.height <= 0)
    return;

  NSWindow* w = self.window;
  NSRect visible = (w.screen ?: [NSScreen mainScreen]).visibleFrame;
  CGFloat titlebar = NSHeight(w.frame) - NSHeight(_remoteView.frame);
  CGFloat maxW = NSWidth(visible);
  CGFloat maxH = NSHeight(visible) - titlebar;

  NSSize size = natural;
  if (size.width > maxW || size.height > maxH) {
    if (_remoteView.scaleMode == ZVScaleFit || _remoteView.scaleMode == ZVScaleFill) {
      CGFloat s = MIN(maxW / size.width, maxH / size.height);
      size = NSMakeSize(floor(size.width * s), floor(size.height * s));
    } else {
      size = NSMakeSize(MIN(size.width, maxW), MIN(size.height, maxH));
    }
  }

  NSRect frame = w.frame;
  NSRect newFrame;
  newFrame.size = NSMakeSize(size.width, size.height + titlebar);
  newFrame.origin.x = NSMidX(frame) - newFrame.size.width / 2;
  newFrame.origin.y = NSMaxY(frame) - newFrame.size.height;
  // Keep on screen
  newFrame.origin.x = MAX(NSMinX(visible), MIN(newFrame.origin.x, NSMaxX(visible) - newFrame.size.width));
  newFrame.origin.y = MAX(NSMinY(visible), MIN(newFrame.origin.y, NSMaxY(visible) - newFrame.size.height));
  [w setFrame:newFrame display:YES animate:sender != nil];
}

- (IBAction)setQualityPreset:(id)sender
{
  _bookmark.quality = (ZVQualityPreset)[sender tag];
  [_session applySettings:_bookmark];
  [self persistBookmarkSetting];
  [self.window.toolbar validateVisibleItems];
}

- (IBAction)setCommandKeyMode:(id)sender
{
  [_session releaseAllKeys];
  _bookmark.commandKeyMode = (ZVCommandKeyMode)[sender tag];
  _remoteView.commandKeyMode = _bookmark.commandKeyMode;
  [self persistBookmarkSetting];
}

- (IBAction)setKeyboardMode:(id)sender
{
  [_session releaseAllKeys];
  _bookmark.keyboardMode = (ZVKeyboardMode)[sender tag];
  _remoteView.keyboardMode = _bookmark.keyboardMode;
  [self persistBookmarkSetting];
}

- (IBAction)toggleRemoteResize:(id)sender
{
  _bookmark.remoteResize = !_bookmark.remoteResize;
  [self persistBookmarkSetting];
  if (_bookmark.remoteResize)
    [self sendRemoteResize:nil];
}

- (void)persistBookmarkSetting
{
  if (_bookmark.isTransient)
    return;
  ZVBookmark* stored = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:_bookmark.uuid];
  if (!stored)
    return;
  stored.scaleMode = _bookmark.scaleMode;
  stored.quality = _bookmark.quality;
  stored.commandKeyMode = _bookmark.commandKeyMode;
  stored.keyboardMode = _bookmark.keyboardMode;
  stored.remoteResize = _bookmark.remoteResize;
  [[ZVBookmarkStore sharedStore] updateBookmark:stored];
}

- (IBAction)saveAsBookmark:(id)sender
{
  if (!_bookmark.isTransient)
    return;
  ZVBookmark* b = [_bookmark copy];
  b.name = _session.desktopName.length ? _session.desktopName : _bookmark.host;
  b.uuid = [NSUUID UUID].UUIDString;
  NSString* pw = [_bookmark storedPassword];
  [[ZVBookmarkStore sharedStore] addBookmark:b];
  ZVBookmark* saved = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:b.uuid];
  if (pw && saved)
    [saved setStoredPassword:pw];
  NSString* ident = [[ZVBookmarkStore sharedStore] identityForScope:[_bookmark credentialScope]];
  if (ident && saved)
    [[ZVBookmarkStore sharedStore] setIdentity:ident forScope:[saved credentialScope]];
}

#pragma mark SSH terminal

// Opens an SSH terminal to the same device, logging in with the SSH user
// of this connection or the VNC credentials (same account on e.g. a Pi)
- (IBAction)openSSHTerminal:(id)sender
{
  ZVBookmark* b = [ZVBookmark bookmarkWithHost:_session.hostName];
  b.protocolType = ZVProtocolSSH;
  b.sshPort = _bookmark.sshPort > 0 ? _bookmark.sshPort : 22;
  b.username = _bookmark.sshUsername.length ? _bookmark.sshUsername : (_session.vncUsername ?: @"");
  NSString* desktop = _session.desktopName.length ? _session.desktopName : _bookmark.displayName;
  b.name = [NSString stringWithFormat:@"%@ — SSH", desktop];
  [(ZVAppDelegate*)NSApp.delegate openTerminalForBookmark:b password:_session.vncPassword];
}

#pragma mark File transfer

- (ZVFileTransferWindowController*)fileTransfer
{
  if (!_files) {
    NSString* user = _bookmark.sshUsername.length ? _bookmark.sshUsername : nil;
    int port = _bookmark.sshPort > 0 ? (int)_bookmark.sshPort : 22;
    NSString* title = _session.desktopName.length ? _session.desktopName : _bookmark.displayName;
    _files = [[ZVFileTransferWindowController alloc] initWithContext:_session
                                                                host:_session.hostName
                                                                port:port
                                                            username:user
                                                               title:title];
  }
  return _files;
}

- (IBAction)showFileTransfer:(id)sender
{
  [[self fileTransfer] showWindow:nil];
}

- (void)buildUploadHUD
{
  _uploadHUD = [[NSVisualEffectView alloc] init];
  _uploadHUD.material = NSVisualEffectMaterialHUDWindow;
  _uploadHUD.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  _uploadHUD.state = NSVisualEffectStateActive;
  _uploadHUD.wantsLayer = YES;
  _uploadHUD.layer.cornerRadius = 10;
  _uploadHUD.translatesAutoresizingMaskIntoConstraints = NO;

  _uploadLabel = [NSTextField labelWithString:@""];
  _uploadLabel.font = [NSFont systemFontOfSize:12];
  _uploadLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _uploadProgress = [[NSProgressIndicator alloc] init];
  _uploadProgress.style = NSProgressIndicatorStyleBar;
  _uploadProgress.indeterminate = NO;
  _uploadProgress.minValue = 0;
  _uploadProgress.maxValue = 1;
  NSButton* stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopUpload:)];
  stop.controlSize = NSControlSizeSmall;

  NSStackView* row = [NSStackView stackViewWithViews:@[_uploadProgress, stop]];
  NSStackView* stack = [NSStackView stackViewWithViews:@[_uploadLabel, row]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 6;
  stack.edgeInsets = NSEdgeInsetsMake(10, 14, 10, 14);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [_uploadHUD addSubview:stack];

  [self.window.contentView addSubview:_uploadHUD];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:_uploadHUD.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:_uploadHUD.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:_uploadHUD.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:_uploadHUD.bottomAnchor],
    [_uploadHUD.widthAnchor constraintEqualToConstant:340],
    [_uploadProgress.widthAnchor constraintEqualToConstant:250],
    [_uploadLabel.widthAnchor constraintLessThanOrEqualToConstant:310],
    [_uploadHUD.centerXAnchor constraintEqualToAnchor:_remoteView.centerXAnchor],
    [_uploadHUD.bottomAnchor constraintEqualToAnchor:_remoteView.bottomAnchor constant:-20],
  ]];
}

- (void)stopUpload:(id)sender
{
  [_files.client cancelTransfer];
}

- (void)hideUploadHUDAfter:(NSTimeInterval)delay
{
  NSVisualEffectView* hud = _uploadHUD;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ hud.hidden = YES; });
}

- (void)remoteView:(ZVRemoteView*)view didReceiveFileURLs:(NSArray<NSURL*>*)urls
{
  if (_session.state != ZVSessionConnected)
    return;
  if (!_uploadHUD)
    [self buildUploadHUD];
  _uploadHUD.hidden = NO;
  _uploadProgress.doubleValue = 0;
  _uploadLabel.stringValue = [NSString stringWithFormat:@"Connecting to %@ (SSH)…", _session.hostName];

  NSByteCountFormatter* fmt = [[NSByteCountFormatter alloc] init];
  [[self fileTransfer] uploadToRemoteDesktop:urls progress:^(ZVTransferProgress p) {
    self->_uploadProgress.doubleValue = p.bytesTotal ? (double)p.bytesDone / p.bytesTotal : 0;
    self->_uploadLabel.stringValue = [NSString stringWithFormat:@"Uploading %@ — %@ of %@",
                                      p.currentName ?: @"",
                                      [fmt stringFromByteCount:p.bytesDone],
                                      [fmt stringFromByteCount:p.bytesTotal]];
  } completion:^(NSString* destination, NSError* error) {
    if (error) {
      BOOL cancelled = error.code == NSUserCancelledError;
      self->_uploadLabel.stringValue = cancelled ? @"Upload stopped"
                                                 : [NSString stringWithFormat:@"Upload failed: %@",
                                                    error.localizedDescription];
      [self hideUploadHUDAfter:cancelled ? 1.5 : 6];
      return;
    }
    self->_uploadProgress.doubleValue = 1;
    self->_uploadLabel.stringValue = [NSString stringWithFormat:@"Uploaded %lu item(s) to %@",
                                      (unsigned long)urls.count, destination];
    [self hideUploadHUDAfter:3];
  }];
}

#pragma mark Info / screenshot

- (IBAction)showConnectionInfo:(id)sender
{
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = @"Connection Information";
  a.informativeText = [_session connectionInfo];
  [a addButtonWithTitle:@"OK"];
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (NSData*)screenshotPNG
{
  NSImage* img = [_remoteView snapshotImage];
  if (!img)
    return nil;
  CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
  return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (IBAction)takeScreenshot:(id)sender
{
  NSData* png = [self screenshotPNG];
  if (!png) {
    NSBeep();
    return;
  }
  NSDateFormatter* df = [[NSDateFormatter alloc] init];
  df.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
  NSSavePanel* panel = [NSSavePanel savePanel];
  panel.allowedContentTypes = @[UTTypePNG];
  panel.nameFieldStringValue = [NSString stringWithFormat:@"%@ %@.png",
                                _bookmark.displayName, [df stringFromDate:[NSDate date]]];
  panel.directoryURL = [[NSFileManager defaultManager] URLsForDirectory:NSDesktopDirectory
                                                              inDomains:NSUserDomainMask].firstObject;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK)
      [png writeToURL:panel.URL atomically:YES];
  }];
}

- (IBAction)copyScreenshot:(id)sender
{
  NSData* png = [self screenshotPNG];
  if (!png) {
    NSBeep();
    return;
  }
  NSPasteboard* pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setData:png forType:NSPasteboardTypePNG];
}

// Toolbar items must not use NSWindow's toggleFullScreen: directly;
// NSWindow's validation of that action assumes a menu item.
- (IBAction)toggleFullScreenMode:(id)sender
{
  [self.window toggleFullScreen:nil];
}

- (IBAction)disconnect:(id)sender
{
  _userClosing = YES;
  [_session disconnect];
  [self.window close];
}

#pragma mark Validation

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
  SEL a = item.action;
  BOOL connected = _session.state == ZVSessionConnected;
  NSMenuItem* mi = [(NSObject*)item isKindOfClass:[NSMenuItem class]] ? (NSMenuItem*)item : nil;

  if (a == @selector(toggleViewOnly:)) {
    mi.state = _session.viewOnly ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
  }
  if (a == @selector(setScaleFit:)) { mi.state = _remoteView.scaleMode == ZVScaleFit; return YES; }
  if (a == @selector(setScaleFill:)) { mi.state = _remoteView.scaleMode == ZVScaleFill; return YES; }
  if (a == @selector(setScaleNative:)) { mi.state = _remoteView.scaleMode == ZVScaleNativePixels; return YES; }
  if (a == @selector(setScale100:)) {
    mi.state = _remoteView.scaleMode == ZVScale100 && fabs(_remoteView.zoom - 1.0) < 0.001;
    return YES;
  }
  if (a == @selector(toggleSmoothScaling:)) { mi.state = _remoteView.smoothScaling; return YES; }
  if (a == @selector(toggleStats:)) { mi.state = !_statsPanel.hidden; return YES; }
  if (a == @selector(setQualityPreset:)) { mi.state = _bookmark.quality == mi.tag; return YES; }
  if (a == @selector(setCommandKeyMode:)) { mi.state = _bookmark.commandKeyMode == mi.tag; return YES; }
  if (a == @selector(setKeyboardMode:)) { mi.state = _bookmark.keyboardMode == mi.tag; return YES; }
  if (a == @selector(toggleRemoteResize:)) {
    mi.state = _bookmark.remoteResize;
    return !connected || [_session supportsRemoteResize];
  }
  if (a == @selector(reconnect:))
    return _session.state == ZVSessionDisconnected && !_session.isReverseConnection;
  if (a == @selector(saveAsBookmark:))
    return _bookmark.isTransient;
  if (a == @selector(sizeWindowToRemote:))
    return connected && !_inFullScreen;
  if (a == @selector(showFileTransfer:))
    return connected || _files != nil;
  if (a == @selector(openSSHTerminal:))
    return connected || _session.state == ZVSessionDisconnected;
  if (a == @selector(disconnect:) || a == @selector(zoomIn:) || a == @selector(zoomOut:) ||
      a == @selector(showConnectionInfo:) || a == @selector(takeScreenshot:) ||
      a == @selector(copyScreenshot:))
    return connected;

  // Everything that sends input
  if (a == @selector(sendCtrlAltDel:) || a == @selector(sendCtrlEsc:) ||
      a == @selector(sendAltTab:) || a == @selector(sendAltF4:) ||
      a == @selector(sendWindowsKey:) || a == @selector(sendCtrlShiftEsc:) ||
      a == @selector(sendWinL:) || a == @selector(sendWinR:) || a == @selector(sendWinE:) ||
      a == @selector(sendWinD:) || a == @selector(sendPrintScreen:) ||
      a == @selector(typeClipboard:))
    return connected && !_session.viewOnly;
  if (a == @selector(refreshScreen:))
    return connected;

  return YES;
}

#pragma mark Toolbar

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
  return @[kTBCtrlAltDel, kTBKeys, kTBClipboard, kTBFiles, kTBTerminal, NSToolbarFlexibleSpaceItemIdentifier,
           kTBScale, kTBQuality, kTBViewOnly, kTBRefresh, kTBScreenshot, kTBStats,
           kTBFullScreen, kTBDisconnect];
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
  return @[kTBCtrlAltDel, kTBKeys, kTBRefresh, kTBScale, kTBQuality, kTBViewOnly,
           kTBClipboard, kTBFiles, kTBTerminal, kTBScreenshot, kTBStats, kTBFullScreen, kTBDisconnect,
           NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier];
}

- (NSMenuItem*)item:(NSString*)title action:(SEL)action tag:(NSInteger)tag
{
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  mi.target = self;
  mi.tag = tag;
  return mi;
}

- (NSToolbarItem*)buttonItem:(NSToolbarItemIdentifier)ident label:(NSString*)label
                      symbol:(NSString*)symbol action:(SEL)action
{
  NSToolbarItem* item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
  item.label = label;
  item.paletteLabel = label;
  item.toolTip = label;
  item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
  item.target = self;
  item.action = action;
  return item;
}

- (NSMenuToolbarItem*)menuItem:(NSToolbarItemIdentifier)ident label:(NSString*)label
                        symbol:(NSString*)symbol menu:(NSMenu*)menu
{
  NSMenuToolbarItem* item = [[NSMenuToolbarItem alloc] initWithItemIdentifier:ident];
  item.label = label;
  item.paletteLabel = label;
  item.toolTip = label;
  item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
  item.menu = menu;
  item.showsIndicator = YES;
  return item;
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident
 willBeInsertedIntoToolbar:(BOOL)flag
{
  if ([ident isEqualToString:kTBCtrlAltDel])
    return [self buttonItem:ident label:@"Ctrl-Alt-Del" symbol:@"lock.shield" action:@selector(sendCtrlAltDel:)];

  if ([ident isEqualToString:kTBKeys]) {
    NSMenu* m = [[NSMenu alloc] init];
    [m addItem:[self item:@"Ctrl-Alt-Del" action:@selector(sendCtrlAltDel:) tag:0]];
    [m addItem:[self item:@"Ctrl-Shift-Esc (Task Manager)" action:@selector(sendCtrlShiftEsc:) tag:0]];
    [m addItem:[self item:@"Ctrl-Esc" action:@selector(sendCtrlEsc:) tag:0]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Windows Key" action:@selector(sendWindowsKey:) tag:0]];
    [m addItem:[self item:@"Win-L (Lock)" action:@selector(sendWinL:) tag:0]];
    [m addItem:[self item:@"Win-R (Run)" action:@selector(sendWinR:) tag:0]];
    [m addItem:[self item:@"Win-E (Explorer)" action:@selector(sendWinE:) tag:0]];
    [m addItem:[self item:@"Win-D (Desktop)" action:@selector(sendWinD:) tag:0]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Alt-Tab" action:@selector(sendAltTab:) tag:0]];
    [m addItem:[self item:@"Alt-F4" action:@selector(sendAltF4:) tag:0]];
    [m addItem:[self item:@"Print Screen" action:@selector(sendPrintScreen:) tag:0]];
    return [self menuItem:ident label:@"Keys" symbol:@"keyboard" menu:m];
  }

  if ([ident isEqualToString:kTBClipboard]) {
    NSMenu* m = [[NSMenu alloc] init];
    [m addItem:[self item:@"Type Clipboard Text" action:@selector(typeClipboard:) tag:0]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Copy Screenshot" action:@selector(copyScreenshot:) tag:0]];
    return [self menuItem:ident label:@"Clipboard" symbol:@"doc.on.clipboard" menu:m];
  }

  if ([ident isEqualToString:kTBRefresh])
    return [self buttonItem:ident label:@"Refresh" symbol:@"arrow.clockwise" action:@selector(refreshScreen:)];

  if ([ident isEqualToString:kTBScale]) {
    NSMenu* m = [[NSMenu alloc] init];
    [m addItem:[self item:@"Fit to Window" action:@selector(setScaleFit:) tag:0]];
    [m addItem:[self item:@"Stretch to Window" action:@selector(setScaleFill:) tag:0]];
    [m addItem:[self item:@"Actual Size (100%)" action:@selector(setScale100:) tag:0]];
    [m addItem:[self item:@"Pixel Perfect (1:1 Retina)" action:@selector(setScaleNative:) tag:0]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Zoom In" action:@selector(zoomIn:) tag:0]];
    [m addItem:[self item:@"Zoom Out" action:@selector(zoomOut:) tag:0]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Resize Window to Remote Screen" action:@selector(sizeWindowToRemote:) tag:0]];
    [m addItem:[self item:@"Resize Remote Screen to Window" action:@selector(toggleRemoteResize:) tag:0]];
    [m addItem:[self item:@"Smooth Scaling" action:@selector(toggleSmoothScaling:) tag:0]];
    return [self menuItem:ident label:@"Scale" symbol:@"arrow.up.left.and.down.right.magnifyingglass" menu:m];
  }

  if ([ident isEqualToString:kTBQuality]) {
    NSMenu* m = [[NSMenu alloc] init];
    [m addItem:[self item:@"Automatic" action:@selector(setQualityPreset:) tag:ZVQualityAuto]];
    [m addItem:[self item:@"Lossless (LAN)" action:@selector(setQualityPreset:) tag:ZVQualityLossless]];
    [m addItem:[self item:@"High" action:@selector(setQualityPreset:) tag:ZVQualityHigh]];
    [m addItem:[self item:@"Balanced" action:@selector(setQualityPreset:) tag:ZVQualityBalanced]];
    [m addItem:[self item:@"Low Bandwidth" action:@selector(setQualityPreset:) tag:ZVQualityLow]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self item:@"Smooth Video (H.264)" action:@selector(setQualityPreset:) tag:ZVQualityVideo]];
    return [self menuItem:ident label:@"Quality" symbol:@"speedometer" menu:m];
  }

  if ([ident isEqualToString:kTBTerminal])
    return [self buttonItem:ident label:@"SSH Terminal" symbol:@"terminal" action:@selector(openSSHTerminal:)];
  if ([ident isEqualToString:kTBFiles])
    return [self buttonItem:ident label:@"Files" symbol:@"folder" action:@selector(showFileTransfer:)];
  if ([ident isEqualToString:kTBViewOnly])
    return [self buttonItem:ident label:@"View Only" symbol:@"eye" action:@selector(toggleViewOnly:)];
  if ([ident isEqualToString:kTBScreenshot])
    return [self buttonItem:ident label:@"Screenshot" symbol:@"camera" action:@selector(takeScreenshot:)];
  if ([ident isEqualToString:kTBStats])
    return [self buttonItem:ident label:@"Statistics" symbol:@"chart.bar.xaxis" action:@selector(toggleStats:)];
  if ([ident isEqualToString:kTBFullScreen]) {
    NSToolbarItem* it = [self buttonItem:ident label:@"Full Screen"
                                  symbol:@"arrow.up.left.and.arrow.down.right"
                                  action:@selector(toggleFullScreenMode:)];
    return it;
  }
  if ([ident isEqualToString:kTBDisconnect])
    return [self buttonItem:ident label:@"Disconnect" symbol:@"xmark.circle" action:@selector(disconnect:)];

  return nil;
}

@end
