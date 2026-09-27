// ZeonVNC - application preferences
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <string>

#include <core/Configuration.h>

#import "ZVPreferences.h"
#import "ZVBookmark.h"
#import "ZVKeychain.h"

NSString* const ZVPrefPassCommandShortcuts = @"ZVPassCommandShortcuts";
NSString* const ZVPrefDefaultCommandKey = @"ZVDefaultCommandKey";
NSString* const ZVPrefDefaultQuality = @"ZVDefaultQuality";
NSString* const ZVPrefDefaultScale = @"ZVDefaultScale";
NSString* const ZVPrefSharpScaling = @"ZVSharpScaling";
NSString* const ZVPrefSecurityMode = @"ZVSecurityMode";
NSString* const ZVPrefListenEnabled = @"ZVListenEnabled";
NSString* const ZVPrefListenPort = @"ZVListenPort";
NSString* const ZVPrefConfirmQuit = @"ZVConfirmQuit";
NSString* const ZVPrefRememberPasswords = @"ZVRememberPasswords";

NSNotificationName const ZVPreferencesChangedNotification = @"ZVPreferencesChangedNotification";

@implementation ZVPreferences

+ (void)registerDefaults
{
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    ZVPrefPassCommandShortcuts: @YES,
    ZVPrefDefaultCommandKey: @(ZVCommandAsControl),
    ZVPrefDefaultQuality: @(ZVQualityAuto),
    ZVPrefDefaultScale: @(ZVScaleFit),
    ZVPrefSharpScaling: @NO,
    ZVPrefSecurityMode: @0,
    ZVPrefListenEnabled: @NO,
    ZVPrefListenPort: @5500,
    ZVPrefConfirmQuit: @YES,
    ZVPrefRememberPasswords: @YES,
  }];
}

+ (void)applyCoreSettings
{
  BOOL encryptedOnly = [[NSUserDefaults standardUserDefaults] integerForKey:ZVPrefSecurityMode] == 1;
  std::string types;
#ifdef HAVE_GNUTLS
  types += "X509Vnc,X509Plain,X509None,TLSVnc,TLSPlain,TLSNone,";
#endif
#ifdef HAVE_NETTLE
  types += "RA2,RA2_256,";
  if (!encryptedOnly)
    types += "RA2ne,RA2ne_256,DH,MSLogonII,";
#endif
  if (!encryptedOnly)
    types += "VncAuth,Plain,None,";
  if (!types.empty())
    types.pop_back();
  core::Configuration::setParam("SecurityTypes", types.c_str());
}

@end

#pragma mark - Window

@implementation ZVPreferencesWindowController {
  NSButton* _passCmd;
  NSButton* _confirmQuit;
  NSButton* _rememberPasswords;
  NSButton* _sharp;
  NSPopUpButton* _cmdKey;
  NSPopUpButton* _quality;
  NSPopUpButton* _scale;
  NSPopUpButton* _security;
  NSButton* _listen;
  NSTextField* _port;
}

- (instancetype)init
{
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 420)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:w];
  if (self) {
    w.title = @"ZeonVNC Settings";
    [self build];
    [self load];
    [w center];
  }
  return self;
}

- (NSTextField*)label:(NSString*)s
{
  NSTextField* f = [NSTextField labelWithString:s];
  f.alignment = NSTextAlignmentRight;
  return f;
}

- (NSPopUpButton*)popup:(NSArray*)titles
{
  NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [p addItemsWithTitles:titles];
  for (NSInteger i = 0; i < p.numberOfItems; i++)
    [p itemAtIndex:i].tag = i;
  p.target = self;
  p.action = @selector(changed:);
  return p;
}

- (void)build
{
  _passCmd = [NSButton checkboxWithTitle:@"Send ⌘ shortcuts to the remote computer"
                                  target:self action:@selector(changed:)];
  NSTextField* passHint = [NSTextField wrappingLabelWithString:
                             @"Local shortcuts use ⌃⌥⌘ (e.g. ⌃⌥⌘F full screen, ⌃⌥⌘W disconnect)."];
  passHint.font = [NSFont systemFontOfSize:11];
  passHint.textColor = [NSColor secondaryLabelColor];
  _confirmQuit = [NSButton checkboxWithTitle:@"Ask before quitting with active sessions"
                                      target:self action:@selector(changed:)];
  _rememberPasswords = [NSButton checkboxWithTitle:@"Save passwords in the Keychain"
                                            target:self action:@selector(changed:)];
  NSTextField* pwHint = [NSTextField wrappingLabelWithString:
                           @"When off, the user name and password are asked for on every "
                           @"connection and nothing is saved."];
  pwHint.font = [NSFont systemFontOfSize:11];
  pwHint.textColor = [NSColor secondaryLabelColor];
  [pwHint.widthAnchor constraintLessThanOrEqualToConstant:320].active = YES;
  NSButton* removeAll = [NSButton buttonWithTitle:@"Remove All Saved Passwords…"
                                           target:self action:@selector(removeAllPasswords:)];
  removeAll.controlSize = NSControlSizeSmall;
  _sharp = [NSButton checkboxWithTitle:@"Sharp (pixelated) scaling instead of smooth"
                                target:self action:@selector(changed:)];

  _cmdKey = [self popup:@[@"Windows key", @"Ctrl", @"Alt"]];
  _quality = [self popup:@[@"Automatic", @"Lossless (LAN)", @"High", @"Balanced", @"Low bandwidth"]];
  [_quality addItemWithTitle:@"Smooth video (H.264)"];
  _quality.lastItem.tag = ZVQualityVideo;
  _scale = [self popup:@[@"Fit to window", @"Actual size (100%)", @"Pixel perfect (1:1 Retina)",
                         @"Stretch to window"]];
  _security = [self popup:@[@"Any method the server offers", @"Encrypted connections only"]];

  _listen = [NSButton checkboxWithTitle:@"Listen for incoming (reverse) connections"
                                 target:self action:@selector(changed:)];
  _port = [[NSTextField alloc] init];
  _port.target = self;
  _port.action = @selector(changed:);
  [_port.widthAnchor constraintEqualToConstant:70].active = YES;
  NSStackView* portRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Port"], _port]];

  NSTextField* quickHdr = [NSTextField labelWithString:@"Quick Connect defaults"];
  quickHdr.font = [NSFont boldSystemFontOfSize:13];

  NSGridView* grid = [NSGridView gridViewWithViews:@[
    @[[self label:@"Keyboard:"], _passCmd],
    @[[NSGridCell emptyContentView], passHint],
    @[[self label:@"Display:"], _sharp],
    @[[self label:@"Security:"], _security],
    @[[self label:@"Passwords:"], _rememberPasswords],
    @[[NSGridCell emptyContentView], pwHint],
    @[[NSGridCell emptyContentView], removeAll],
    @[[self label:@"Listening:"], _listen],
    @[[NSGridCell emptyContentView], portRow],
    @[[self label:@"General:"], _confirmQuit],
    @[quickHdr, [NSGridCell emptyContentView]],
    @[[self label:@"⌘ key:"], _cmdKey],
    @[[self label:@"Quality:"], _quality],
    @[[self label:@"Scaling:"], _scale],
  ]];
  grid.rowSpacing = 10;
  grid.columnSpacing = 10;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [grid rowAtIndex:10].topPadding = 12;
  [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(10, 1)];
  [[grid cellAtColumnIndex:0 rowIndex:10] setXPlacement:NSGridCellPlacementLeading];
  [passHint.widthAnchor constraintLessThanOrEqualToConstant:320].active = YES;

  grid.translatesAutoresizingMaskIntoConstraints = NO;
  NSView* content = self.window.contentView;
  [content addSubview:grid];
  [NSLayoutConstraint activateConstraints:@[
    [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
    [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
    [grid.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-24],
    [grid.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
  ]];
}

- (void)load
{
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  _passCmd.state = [d boolForKey:ZVPrefPassCommandShortcuts];
  _confirmQuit.state = [d boolForKey:ZVPrefConfirmQuit];
  _rememberPasswords.state = [d boolForKey:ZVPrefRememberPasswords];
  _sharp.state = [d boolForKey:ZVPrefSharpScaling];
  [_cmdKey selectItemWithTag:[d integerForKey:ZVPrefDefaultCommandKey]];
  [_quality selectItemWithTag:[d integerForKey:ZVPrefDefaultQuality]];
  [_scale selectItemWithTag:[d integerForKey:ZVPrefDefaultScale]];
  [_security selectItemWithTag:[d integerForKey:ZVPrefSecurityMode]];
  _listen.state = [d boolForKey:ZVPrefListenEnabled];
  _port.integerValue = [d integerForKey:ZVPrefListenPort];
}

- (void)removeAllPasswords:(id)sender
{
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = @"Remove all saved passwords?";
  a.informativeText = @"Every password ZeonVNC saved in the Keychain is deleted. "
                      @"Saved connections are kept.";
  [a addButtonWithTitle:@"Remove"];
  [a addButtonWithTitle:@"Cancel"];
  a.buttons.firstObject.hasDestructiveAction = YES;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn)
      [ZVKeychain removeAllPasswords];
  }];
}

- (void)changed:(id)sender
{
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  [d setBool:_passCmd.state == NSControlStateValueOn forKey:ZVPrefPassCommandShortcuts];
  [d setBool:_confirmQuit.state == NSControlStateValueOn forKey:ZVPrefConfirmQuit];
  [d setBool:_rememberPasswords.state == NSControlStateValueOn forKey:ZVPrefRememberPasswords];
  [d setBool:_sharp.state == NSControlStateValueOn forKey:ZVPrefSharpScaling];
  [d setInteger:_cmdKey.selectedTag forKey:ZVPrefDefaultCommandKey];
  [d setInteger:_quality.selectedTag forKey:ZVPrefDefaultQuality];
  [d setInteger:_scale.selectedTag forKey:ZVPrefDefaultScale];
  [d setInteger:_security.selectedTag forKey:ZVPrefSecurityMode];
  [d setBool:_listen.state == NSControlStateValueOn forKey:ZVPrefListenEnabled];
  NSInteger port = _port.integerValue;
  if (port < 1 || port > 65535)
    port = 5500;
  [d setInteger:port forKey:ZVPrefListenPort];

  [ZVPreferences applyCoreSettings];
  [[NSNotificationCenter defaultCenter] postNotificationName:ZVPreferencesChangedNotification object:nil];
}

@end
