// ZeonVNC - SSH / Telnet terminal window
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVTerminalWindowController.h"
#import "ZVFileTransferWindowController.h"
#import "ZVKeychain.h"
#import "ZVPreferences.h"
#import "ZVSFTPClient.h"
#import "ZVTelnetClient.h"
#import "ZVTerminalView.h"
#import "ZVTrust.h"

static NSString* const kFontSizeKey = @"ZVTerminalFontSize";
static NSString* const kTermType = @"xterm-256color";

static NSToolbarItemIdentifier const kTBFiles = @"files";
static NSToolbarItemIdentifier const kTBReconnect = @"reconnect";
static NSToolbarItemIdentifier const kTBClear = @"clear";
static NSToolbarItemIdentifier const kTBFont = @"font";
static NSToolbarItemIdentifier const kTBDisconnect = @"disconnect";

@interface ZVTerminalWindowController () <ZVSFTPClientDelegate, ZVFileTransferContext,
                                          NSToolbarDelegate>
@end

@implementation ZVTerminalWindowController {
  ZVBookmark* _bookmark;
  ZVTerminalView* _terminal;

  ZVSFTPClient* _ssh;
  ZVTelnetClient* _telnet;
  BOOL _connecting;
  BOOL _connected;
  BOOL _closedByUser;
  BOOL _sawOutput;

  ZVFileTransferWindowController* _files;
}

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark
{
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 540)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:w];
  if (self) {
    _bookmark = [bookmark copy];

    w.title = [bookmark displayName];
    w.subtitle = [self connectionDescription];
    w.delegate = self;
    w.releasedWhenClosed = NO;
    w.tabbingMode = NSWindowTabbingModePreferred;
    w.tabbingIdentifier = @"ZeonVNCTerminal";
    w.minSize = NSMakeSize(360, 200);
    [w center];

    _terminal = [[ZVTerminalView alloc] initWithFrame:w.contentView.bounds];
    _terminal.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat size = [[NSUserDefaults standardUserDefaults] doubleForKey:kFontSizeKey];
    _terminal.fontSize = size > 0 ? size : 13;
    w.contentView = _terminal;

    __weak ZVTerminalWindowController* weakSelf = self;
    _terminal.onSend = ^(NSData* data) { [weakSelf userTyped:data]; };
    _terminal.onResize = ^(NSInteger cols, NSInteger rows) { [weakSelf terminalResized:cols rows:rows]; };
    _terminal.onTitle = ^(NSString* title) { [weakSelf setRemoteTitle:title]; };

    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:@"ZVTerminalToolbar"];
    tb.delegate = self;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    w.toolbar = tb;
    w.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
  }
  return self;
}

- (ZVBookmark*)bookmark { return _bookmark; }
- (BOOL)isConnected { return _connected; }

- (BOOL)isSSH
{
  return _bookmark.protocolType == ZVProtocolSSH;
}

// Host name and port from the bookmark ("host", "host:port", "[v6]:port")
- (NSString*)hostName
{
  NSString* h = _bookmark.host;
  if ([h hasPrefix:@"["]) {
    NSRange end = [h rangeOfString:@"]"];
    if (end.location != NSNotFound)
      return [h substringWithRange:NSMakeRange(1, end.location - 1)];
  }
  NSRange colon = [h rangeOfString:@":" options:NSBackwardsSearch];
  if (colon.location != NSNotFound && [h rangeOfString:@":"].location == colon.location)
    return [h substringToIndex:colon.location];
  return h;
}

- (int)port
{
  NSString* h = _bookmark.host;
  NSRange colon = [h rangeOfString:@":" options:NSBackwardsSearch];
  BOOL bracketed = [h hasPrefix:@"["];
  BOOL single = colon.location != NSNotFound && [h rangeOfString:@":"].location == colon.location;
  if (colon.location != NSNotFound && (single || bracketed)) {
    int p = [h substringFromIndex:colon.location + 1].intValue;
    if (p > 0)
      return p;
  }
  if ([self isSSH])
    return _bookmark.sshPort > 0 ? (int)_bookmark.sshPort : 22;
  return _bookmark.telnetPort > 0 ? (int)_bookmark.telnetPort : 23;
}

- (NSString*)sshUser
{
  return _bookmark.username.length ? _bookmark.username : nil;
}

- (NSString*)connectionDescription
{
  if ([self isSSH]) {
    NSString* user = _ssh.username ?: [self sshUser];
    return [NSString stringWithFormat:@"ssh %@%@%@", user.length ? [user stringByAppendingString:@"@"] : @"",
            [self hostName], [self port] == 22 ? @"" : [NSString stringWithFormat:@" -p %d", [self port]]];
  }
  return [NSString stringWithFormat:@"telnet %@ %d", [self hostName], [self port]];
}

#pragma mark Connection

- (void)start
{
  [self showWindow:nil];
  [self connect];
}

- (void)status:(NSString*)text
{
  // Dim status lines, like "Connecting…", in the terminal itself
  [_terminal feedText:[NSString stringWithFormat:@"\x1b[2m%@\x1b[0m\r\n", text]];
}

- (void)connect
{
  if (_connecting || _connected)
    return;
  _connecting = YES;
  _closedByUser = NO;
  _sawOutput = NO;
  [self.window.toolbar validateVisibleItems];

  int cols = (int)MAX(_terminal.columns, 20), rows = (int)MAX(_terminal.rows, 5);
  __weak ZVTerminalWindowController* weakSelf = self;

  if ([self isSSH]) {
    [self status:[NSString stringWithFormat:@"Connecting to %@…", [self hostName]]];
    _ssh = [[ZVSFTPClient alloc] initWithHost:[self hostName] port:[self port]];
    _ssh.wantsSFTP = NO;
    _ssh.delegate = self;
    _ssh.username = [self sshUser];
    if (self.offeredPassword.length)
      _ssh.offeredPassword = self.offeredPassword;
    else if ([[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords] &&
             !_bookmark.alwaysAskPassword)
      _ssh.offeredPassword = [_bookmark storedPassword];
    [_ssh openShellWithTerminal:kTermType columns:cols rows:rows
                         output:^(NSData* data) { [weakSelf remoteOutput:data]; }
                         closed:^(NSError* error) { [weakSelf remoteClosed:error]; }];
  } else {
    [self status:[NSString stringWithFormat:@"Connecting to %@ port %d…", [self hostName], [self port]]];
    [_terminal feedText:@"\x1b[33mTelnet is not encrypted; everything, including passwords, "
                        @"is sent in plain text.\x1b[0m\r\n"];
    _telnet = [[ZVTelnetClient alloc] initWithHost:[self hostName] port:[self port]];
    [_telnet connectWithTerminal:kTermType columns:cols rows:rows
                          output:^(NSData* data) { [weakSelf remoteOutput:data]; }
                          closed:^(NSError* error) { [weakSelf remoteClosed:error]; }];
  }
}

- (void)remoteOutput:(NSData*)data
{
  if (!_sawOutput) {
    // First output means we're logged in
    _sawOutput = YES;
    _connecting = NO;
    _connected = YES;
    [self didConnect];
  }
  [_terminal feedData:data];
}

- (void)didConnect
{
  self.window.subtitle = [self connectionDescription];
  [[ZVBookmarkStore sharedStore] noteConnectedTo:_bookmark];

  if (_ssh) {
    NSString* identity = [ZVTrust identityForMAC:_ssh.deviceMAC key:_ssh.hostKeyFingerprint];
    [ZVTrust noteDeviceForScope:[_bookmark credentialScope] mac:_ssh.deviceMAC
                            key:_ssh.hostKeyFingerprint name:[self hostName]
                           host:_bookmark.host username:_ssh.username];
    NSString* pw = _ssh.passwordToRemember;
    if (pw && identity && [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords])
      [ZVKeychain setPassword:pw forAccount:[@"ssh:" stringByAppendingString:identity]];
  }
  [self.window.toolbar validateVisibleItems];
}

- (void)remoteClosed:(NSError*)error
{
  BOOL wasConnected = _connected;
  _connecting = NO;
  _connected = NO;
  [self.window.toolbar validateVisibleItems];
  if (_closedByUser)
    return;

  if (error && error.code != NSUserCancelledError)
    [_terminal feedText:[NSString stringWithFormat:@"\r\n\x1b[31m%@\x1b[0m\r\n",
                         [error.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"]]];
  [self status:[NSString stringWithFormat:@"\r\n[%@ — press Return to reconnect]",
                wasConnected ? @"Connection closed" : @"Not connected"]];
  self.window.subtitle = @"Disconnected";
}

- (void)userTyped:(NSData*)data
{
  if (_connected) {
    if (_ssh)
      [_ssh writeShell:data];
    else
      [_telnet write:data];
    return;
  }
  // Return reconnects a closed session
  if (!_connecting && data.length && memchr(data.bytes, '\r', data.length))
    [self reconnect:nil];
}

- (void)terminalResized:(NSInteger)cols rows:(NSInteger)rows
{
  if (_ssh)
    [_ssh resizeShellColumns:(int)cols rows:(int)rows];
  else
    [_telnet resizeColumns:(int)cols rows:(int)rows];
}

- (void)setRemoteTitle:(NSString*)title
{
  self.window.title = title.length ? title : [_bookmark displayName];
}

- (void)closeTransport
{
  _closedByUser = YES;
  [_ssh closeShell];
  [_telnet disconnect];
  _ssh = nil;
  _telnet = nil;
  _connected = NO;
  _connecting = NO;
}

- (IBAction)reconnect:(id)sender
{
  [self closeTransport];
  [_terminal feedText:@"\r\n"];
  [self connect];
}

- (IBAction)disconnect:(id)sender
{
  [self.window close];
}

- (IBAction)clearTerminal:(id)sender
{
  [_terminal resetTerminal];
}

- (void)setFontSize:(CGFloat)size
{
  _terminal.fontSize = MAX(8, MIN(size, 36));
  [[NSUserDefaults standardUserDefaults] setDouble:_terminal.fontSize forKey:kFontSizeKey];
}

- (IBAction)biggerFont:(id)sender { [self setFontSize:_terminal.fontSize + 1]; }
- (IBAction)smallerFont:(id)sender { [self setFontSize:_terminal.fontSize - 1]; }
- (IBAction)defaultFontSize:(id)sender { [self setFontSize:13]; }

#pragma mark Files (SFTP over the same login)

- (NSString*)transferUsername { return _ssh.username ?: [self sshUser]; }
- (NSString*)transferPassword { return _ssh.usedPassword; }
- (NSString*)transferScope { return [_bookmark credentialScope]; }

- (IBAction)showFileTransfer:(id)sender
{
  if (![self isSSH])
    return;
  if (!_files) {
    _files = [[ZVFileTransferWindowController alloc] initWithContext:self
                                                                host:[self hostName]
                                                                port:[self port]
                                                            username:[self transferUsername]
                                                               title:[_bookmark displayName]];
  }
  [_files showWindow:nil];
}

#pragma mark ZVSFTPClientDelegate (shell login)

- (BOOL)sftpClient:(ZVSFTPClient*)client trustHostKey:(NSString*)fingerprint display:(NSString*)display
{
  return [ZVTrust verifyKey:fingerprint mac:client.deviceMAC scope:[_bookmark credentialScope]
                       host:client.host];
}

- (NSString*)sftpClientSavedPassword:(ZVSFTPClient*)client
{
  if (![[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords] ||
      _bookmark.alwaysAskPassword)
    return nil;
  NSString* identity = [ZVTrust identityForMAC:client.deviceMAC key:client.hostKeyFingerprint];
  return identity ? [ZVKeychain passwordForAccount:[@"ssh:" stringByAppendingString:identity]] : nil;
}

- (BOOL)sftpClient:(ZVSFTPClient*)client wantsPasswordForUser:(NSString**)user
          password:(NSString**)password remember:(BOOL*)remember failed:(BOOL)failed
{
  BOOL saving = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Log in to %@", [_bookmark displayName]];
  alert.informativeText = failed ? @"The user name or password was not accepted."
                                 : [NSString stringWithFormat:@"SSH login to %@.", client.host];
  if (failed)
    alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"Log In"];
  [alert addButtonWithTitle:@"Cancel"];

  NSTextField* u = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  u.placeholderString = @"User name";
  u.stringValue = *user ?: @"";
  NSSecureTextField* p = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  p.placeholderString = @"Password";
  NSButton* r = [NSButton checkboxWithTitle:saving ? @"Save password in Keychain"
                                                   : @"Save password (turned off in Settings)"
                                     target:nil action:nil];
  r.state = saving ? NSControlStateValueOn : NSControlStateValueOff;
  r.enabled = saving;
  NSStackView* stack = [NSStackView stackViewWithViews:@[u, p, r]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  [u.widthAnchor constraintEqualToConstant:260].active = YES;
  [p.widthAnchor constraintEqualToConstant:260].active = YES;
  stack.frame = NSMakeRect(0, 0, 260, 88);
  alert.accessoryView = stack;
  alert.window.initialFirstResponder = u.stringValue.length ? p : u;

  if ([alert runModal] != NSAlertFirstButtonReturn)
    return NO;
  *user = u.stringValue;
  *password = p.stringValue;
  *remember = saving && r.state == NSControlStateValueOn;
  return YES;
}

#pragma mark Window

- (void)windowDidBecomeKey:(NSNotification*)notification
{
  [_terminal focus];
}

- (void)windowWillClose:(NSNotification*)notification
{
  [self closeTransport];
  [_files close];
  _files = nil;
  [[NSNotificationCenter defaultCenter] postNotificationName:@"ZVSessionWindowClosed" object:self];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
  SEL a = item.action;
  if (a == @selector(showFileTransfer:))
    return [self isSSH] && (_connected || _files != nil);
  if (a == @selector(reconnect:))
    return !_connecting;
  return YES;
}

#pragma mark Toolbar

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
  NSMutableArray* items = [NSMutableArray array];
  if ([self isSSH])
    [items addObject:kTBFiles];
  [items addObjectsFromArray:@[NSToolbarFlexibleSpaceItemIdentifier, kTBFont, kTBClear,
                               kTBReconnect, kTBDisconnect]];
  return items;
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
  return @[kTBFiles, kTBFont, kTBClear, kTBReconnect, kTBDisconnect,
           NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier];
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

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident
 willBeInsertedIntoToolbar:(BOOL)flag
{
  if ([ident isEqualToString:kTBFiles])
    return [self buttonItem:ident label:@"Files (SFTP)" symbol:@"folder" action:@selector(showFileTransfer:)];
  if ([ident isEqualToString:kTBReconnect])
    return [self buttonItem:ident label:@"Reconnect" symbol:@"arrow.clockwise" action:@selector(reconnect:)];
  if ([ident isEqualToString:kTBClear])
    return [self buttonItem:ident label:@"Clear" symbol:@"clear" action:@selector(clearTerminal:)];
  if ([ident isEqualToString:kTBDisconnect])
    return [self buttonItem:ident label:@"Disconnect" symbol:@"xmark.circle" action:@selector(disconnect:)];
  if ([ident isEqualToString:kTBFont]) {
    NSToolbarItemGroup* g = [NSToolbarItemGroup groupWithItemIdentifier:ident
                                                                 titles:@[@"A−", @"A+"]
                                                          selectionMode:NSToolbarItemGroupSelectionModeMomentary
                                                                 labels:@[@"Smaller", @"Bigger"]
                                                                 target:self
                                                                 action:@selector(fontGroup:)];
    g.label = @"Font Size";
    g.paletteLabel = @"Font Size";
    return g;
  }
  return nil;
}

- (void)fontGroup:(NSToolbarItemGroup*)group
{
  if (group.selectedIndex == 0)
    [self smallerFont:nil];
  else
    [self biggerFont:nil];
}

@end
