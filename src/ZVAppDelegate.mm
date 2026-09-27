// ZeonVNC - application delegate, menus and keyboard routing
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <core/LogWriter.h>
#include <core/Logger_stdio.h>

#import "ZVAppDelegate.h"
#import "ZVBookmark.h"
#import "ZVClipboard.h"
#import "ZVConnectionsWindowController.h"
#import "ZVListener.h"
#import "ZVPreferences.h"
#import "ZVRemoteView.h"
#import "ZVSession.h"
#import "ZVSessionWindowController.h"
#import "ZVTerminalWindowController.h"

#ifdef ZV_SPARKLE
#import <Sparkle/Sparkle.h>
#endif

static const NSEventModifierFlags kLocalShortcutMask =
  NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;

@implementation ZVApplication

- (void)sendEvent:(NSEvent*)event
{
  NSEventType t = event.type;
  if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp || t == NSEventTypeFlagsChanged) {
    NSWindow* w = self.keyWindow;
    if ([w.firstResponder isKindOfClass:[ZVRemoteView class]] && w.attachedSheet == nil) {
      ZVRemoteView* view = (ZVRemoteView*)w.firstResponder;
      BOOL local = NO;
      if (t != NSEventTypeFlagsChanged) {
        NSEventModifierFlags m = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if ((m & kLocalShortcutMask) == kLocalShortcutMask)
          local = YES;
        else if ((m & NSEventModifierFlagCommand) &&
                 ![[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefPassCommandShortcuts])
          local = [self.mainMenu performKeyEquivalent:event];
        else if ((m & NSEventModifierFlagCommand) && event.keyCode == 12 /* Q */ &&
                 view.session.state != ZVSessionConnected)
          local = YES;   // allow ⌘Q while not connected
      }
      if (!local) {
        [view handleKeyEvent:event];
        return;
      }
      if (t == NSEventTypeKeyDown && [self.mainMenu performKeyEquivalent:event])
        return;
    }
  }
  [super sendEvent:event];
}

@end

#pragma mark - Delegate

@interface ZVAppDelegate () <ZVConnectionsDelegate>
@end

@implementation ZVAppDelegate {
  ZVConnectionsWindowController* _connections;
  ZVPreferencesWindowController* _prefs;
  NSMutableArray<ZVSessionWindowController*>* _sessions;
  NSMutableArray<ZVTerminalWindowController*>* _terminals;
  ZVListener* _listener;
  NSMutableArray<NSURL*>* _pendingOpen;
#ifdef ZV_SPARKLE
  SPUStandardUpdaterController* _updater;
#endif
  BOOL _launched;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _sessions = [NSMutableArray array];
    _terminals = [NSMutableArray array];
    _pendingOpen = [NSMutableArray array];
  }
  return self;
}

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
  [ZVPreferences registerDefaults];
#ifdef ZV_SPARKLE
  // Automatic updates, only in builds that carry the update signing key
  if ([[NSBundle mainBundle].infoDictionary[@"SUPublicEDKey"] length])
    _updater = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
                                                             updaterDelegate:nil
                                                          userDriverDelegate:nil];
#endif
  [self buildMenus];

  // Use the bundle icon explicitly (Dock, alerts) even if the icon cache
  // still has an older build registered. Not with the macOS 26 icon from
  // the asset catalog, which the system draws itself.
  if (![NSBundle mainBundle].infoDictionary[@"CFBundleIconName"]) {
    NSImage* icon = [NSImage imageNamed:@"ZeonVNC"];
    if (icon)
      NSApp.applicationIconImage = icon;
  }

  // Handle vnc:// URLs
  [[NSAppleEventManager sharedAppleEventManager]
    setEventHandler:self andSelector:@selector(handleURLEvent:withReplyEvent:)
      forEventClass:kInternetEventClass andEventID:kAEGetURL];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
  core::initStdIOLoggers();
  core::LogWriter::setLogParams("*:stderr:30");
  [ZVPreferences applyCoreSettings];

  [[ZVClipboard shared] start];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionClosed:)
                                               name:@"ZVSessionWindowClosed" object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesChanged:)
                                               name:ZVPreferencesChangedNotification object:nil];
  [self updateListener];

  // Addresses on the command line: ZeonVNC vnc://host:port or host::port
  NSArray* args = [NSProcessInfo processInfo].arguments;
  for (NSUInteger i = 1; i < args.count; i++) {
    NSString* a = args[i];
    if ([a hasPrefix:@"-"]) {
      i++;   // skip "-Key value" style defaults arguments
      continue;
    }
    NSURL* url = [a containsString:@"://"] ? [NSURL URLWithString:a] : nil;
    if (url)
      [_pendingOpen addObject:url];
    else
      [_pendingOpen addObject:[NSURL URLWithString:
        [@"zeonvnc-host:" stringByAppendingString:
          [a stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]]]];
  }

  _launched = YES;
  if (_pendingOpen.count) {
    for (NSURL* url in _pendingOpen)
      [self openURL:url];
    [_pendingOpen removeAllObjects];
  } else {
    [self showConnections:nil];
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag
{
  if (!flag)
    [self showConnections:nil];
  return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app
{
  return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
  NSUInteger active = 0;
  for (ZVSessionWindowController* s in _sessions)
    if (s.session.state == ZVSessionConnected)
      active++;
  for (ZVTerminalWindowController* t in _terminals)
    if (t.isConnected)
      active++;
  if (active == 0 || ![[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefConfirmQuit])
    return NSTerminateNow;

  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = active == 1 ? @"Quit ZeonVNC and close the open session?"
                              : [NSString stringWithFormat:@"Quit ZeonVNC and close %lu open sessions?",
                                 (unsigned long)active];
  [a addButtonWithTitle:@"Quit"];
  [a addButtonWithTitle:@"Cancel"];
  a.showsSuppressionButton = YES;
  NSModalResponse r = [a runModal];
  if (a.suppressionButton.state == NSControlStateValueOn)
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:ZVPrefConfirmQuit];
  return r == NSAlertFirstButtonReturn ? NSTerminateNow : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
  for (ZVSessionWindowController* s in [_sessions copy])
    [s.session disconnect];
}

#pragma mark Opening sessions

- (void)openSessionForBookmark:(ZVBookmark*)bookmark
{
  if (bookmark.protocolType != ZVProtocolVNC) {
    [self openTerminalForBookmark:bookmark password:nil];
    return;
  }

  // Bring an existing window for the same connection to the front
  for (ZVSessionWindowController* s in _sessions) {
    if ([s.bookmark.uuid isEqualToString:bookmark.uuid] &&
        s.session.state != ZVSessionDisconnected) {
      [s showWindow:nil];
      return;
    }
  }

  ZVSessionWindowController* wc = [[ZVSessionWindowController alloc] initWithBookmark:bookmark];
  [_sessions addObject:wc];
  [wc start];
}

- (void)openTerminalForBookmark:(ZVBookmark*)bookmark password:(NSString*)password
{
  // A new terminal each time (several shells to one device are common)
  ZVTerminalWindowController* tc = [[ZVTerminalWindowController alloc] initWithBookmark:bookmark];
  tc.offeredPassword = password;
  [_terminals addObject:tc];
  [tc start];
}

- (void)sessionClosed:(NSNotification*)n
{
  id wc = n.object;
  // Keep the controller alive until the current event is done
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_sessions removeObject:wc];
    [self->_terminals removeObject:wc];
  });
}

- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls
{
  for (NSURL* url in urls) {
    if (_launched)
      [self openURL:url];
    else
      [_pendingOpen addObject:url];
  }
}

- (void)handleURLEvent:(NSAppleEventDescriptor*)event withReplyEvent:(NSAppleEventDescriptor*)reply
{
  NSString* s = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
  NSURL* url = s ? [NSURL URLWithString:s] : nil;
  if (!url)
    return;
  if (_launched)
    [self openURL:url];
  else
    [_pendingOpen addObject:url];
}

- (void)openURL:(NSURL*)url
{
  if ([url.scheme isEqualToString:@"zeonvnc-host"]) {
    // Plain address given on the command line
    NSString* h = [url.resourceSpecifier stringByRemovingPercentEncoding];
    ZVBookmark* quick = [ZVBookmark bookmarkFromQuickConnect:h];
    ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkMatching:quick] ?: quick;
    [self openSessionForBookmark:b];
    return;
  }

  if (url.isFileURL) {
    // .vnc connection file: import it and connect
    NSString* text = [NSString stringWithContentsOfURL:url usedEncoding:NULL error:nil];
    if (!text)
      text = [NSString stringWithContentsOfURL:url encoding:NSISOLatin1StringEncoding error:nil];
    NSString* host = nil;
    NSString* port = nil;
    for (NSString* line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
      NSString* l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([l.lowercaseString hasPrefix:@"host="])
        host = [l substringFromIndex:5];
      else if ([l.lowercaseString hasPrefix:@"port="])
        port = [l substringFromIndex:5];
    }
    if (host.length == 0) {
      NSBeep();
      return;
    }
    NSString* h = port.length ? [NSString stringWithFormat:@"%@::%@", host, port] : host;
    ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkMatchingHost:h] ?: [ZVBookmark bookmarkWithHost:h];
    [self openSessionForBookmark:b];
    return;
  }

  NSString* scheme = url.scheme.lowercaseString;
  if (([scheme isEqualToString:@"ssh"] || [scheme isEqualToString:@"telnet"]) && url.host.length) {
    ZVBookmark* quick = [ZVBookmark bookmarkFromQuickConnect:url.absoluteString];
    [self openSessionForBookmark:[[ZVBookmarkStore sharedStore] bookmarkMatching:quick] ?: quick];
    return;
  }

  if ([scheme isEqualToString:@"vnc"] && url.host.length) {
    // vnc://[user@]host[:port]  (the port is a TCP port, not a display)
    NSString* host = url.host;
    if ([host containsString:@":"])
      host = [NSString stringWithFormat:@"[%@]", host];
    NSString* h = url.port ? [NSString stringWithFormat:@"%@::%@", host, url.port] : host;
    ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkMatchingHost:h];
    if (!b) {
      b = [ZVBookmark bookmarkWithHost:h];
      if (url.user.length)
        b.username = url.user;
    }
    [self openSessionForBookmark:b];
  }
}

#pragma mark Listener

- (void)preferencesChanged:(NSNotification*)n
{
  [self updateListener];
  BOOL sharp = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefSharpScaling];
  for (ZVSessionWindowController* s in _sessions)
    s.remoteView.smoothScaling = !sharp;
}

- (void)updateListener
{
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  BOOL enabled = [d boolForKey:ZVPrefListenEnabled];
  int port = (int)[d integerForKey:ZVPrefListenPort];

  if (!enabled) {
    [_listener stop];
    _listener = nil;
    return;
  }
  if (_listener.isListening && _listener.port == port)
    return;

  if (!_listener) {
    _listener = [[ZVListener alloc] init];
    __weak ZVAppDelegate* weakSelf = self;
    _listener.onConnection = ^(int fd, NSString* peer) {
      [weakSelf acceptReverseConnection:fd peer:peer];
    };
  }
  NSError* err = nil;
  if (![_listener startOnPort:port error:&err]) {
    NSAlert* a = [NSAlert alertWithError:err];
    [a runModal];
  }
}

- (void)acceptReverseConnection:(int)fd peer:(NSString*)peer
{
  ZVBookmark* b = [ZVBookmark bookmarkWithHost:peer];
  b.name = [NSString stringWithFormat:@"Incoming from %@", peer];
  NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
  b.commandKeyMode = (ZVCommandKeyMode)[d integerForKey:ZVPrefDefaultCommandKey];
  b.quality = (ZVQualityPreset)[d integerForKey:ZVPrefDefaultQuality];
  b.scaleMode = (ZVScaleMode)[d integerForKey:ZVPrefDefaultScale];

  ZVSessionWindowController* wc = [[ZVSessionWindowController alloc] initWithBookmark:b
                                                                       incomingSocket:fd];
  [_sessions addObject:wc];
  [wc start];
  [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark Actions

- (IBAction)showConnections:(id)sender
{
  if (!_connections) {
    _connections = [[ZVConnectionsWindowController alloc] init];
    _connections.delegate = self;
  }
  [_connections showWindow:nil];
}

- (IBAction)quickConnect:(id)sender
{
  [self showConnections:nil];
  [_connections focusQuickConnect];
}

- (IBAction)newBookmark:(id)sender
{
  [self showConnections:nil];
  [_connections newBookmark:nil];
}

- (IBAction)importBookmarks:(id)sender
{
  [self showConnections:nil];
  [_connections importBookmarks:nil];
}

- (IBAction)exportBookmarks:(id)sender
{
  [self showConnections:nil];
  [_connections exportBookmarks:nil];
}

- (IBAction)showPreferences:(id)sender
{
  if (!_prefs)
    _prefs = [[ZVPreferencesWindowController alloc] init];
  [_prefs showWindow:nil];
}

- (IBAction)showAbout:(id)sender
{
  NSMutableAttributedString* credits = [[NSMutableAttributedString alloc]
    initWithString:@"Remote desktops (VNC), terminals (SSH, Telnet) and file transfer (SFTP) for macOS.\n\n"
                   @"Free software under the GNU General Public License v2 or later.\n"
                   @"github.com/selimozbas/zeonvnc"
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11],
                     NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}];
  NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  [credits addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, credits.length)];
  [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionCredits: credits}];
}

#pragma mark Menus

- (NSMenuItem*)item:(NSString*)title action:(SEL)action key:(NSString*)key
{
  return [self item:title action:action key:key mods:NSEventModifierFlagCommand];
}

- (NSMenuItem*)item:(NSString*)title action:(SEL)action key:(NSString*)key
               mods:(NSEventModifierFlags)mods
{
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
  mi.keyEquivalentModifierMask = mods;
  return mi;
}

- (NSMenuItem*)local:(NSString*)title action:(SEL)action key:(NSString*)key
{
  return [self item:title action:action key:key mods:kLocalShortcutMask];
}

- (NSMenuItem*)tagged:(NSString*)title action:(SEL)action tag:(NSInteger)tag
{
  NSMenuItem* mi = [self item:title action:action key:@"" mods:0];
  mi.tag = tag;
  return mi;
}

- (void)addSubmenu:(NSMenu*)submenu title:(NSString*)title to:(NSMenu*)menu
{
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
  mi.submenu = submenu;
  [menu addItem:mi];
}

- (void)buildMenus
{
  NSMenu* main = [[NSMenu alloc] init];

  // App
  NSMenu* app = [[NSMenu alloc] initWithTitle:@"ZeonVNC"];
  NSMenuItem* about = [self item:@"About ZeonVNC" action:@selector(showAbout:) key:@""];
  about.target = self;
  [app addItem:about];
#ifdef ZV_SPARKLE
  if (_updater) {
    NSMenuItem* update = [self item:@"Check for Updates…" action:@selector(checkForUpdates:) key:@""];
    update.target = _updater;
    [app addItem:update];
  }
#endif
  [app addItem:[NSMenuItem separatorItem]];
  NSMenuItem* prefs = [self item:@"Settings…" action:@selector(showPreferences:) key:@","];
  prefs.target = self;
  [app addItem:prefs];
  [app addItem:[NSMenuItem separatorItem]];
  NSMenuItem* services = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
  services.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
  NSApp.servicesMenu = services.submenu;
  [app addItem:services];
  [app addItem:[NSMenuItem separatorItem]];
  [app addItem:[self item:@"Hide ZeonVNC" action:@selector(hide:) key:@"h"]];
  [app addItem:[self item:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h"
                     mods:NSEventModifierFlagCommand | NSEventModifierFlagOption]];
  [app addItem:[self item:@"Show All" action:@selector(unhideAllApplications:) key:@""]];
  [app addItem:[NSMenuItem separatorItem]];
  [app addItem:[self item:@"Quit ZeonVNC" action:@selector(terminate:) key:@"q"]];
  [self addSubmenu:app title:@"" to:main];

  // File
  NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem* conn = [self item:@"Connections" action:@selector(showConnections:) key:@"0"];
  conn.target = self;
  [file addItem:conn];
  NSMenuItem* qc = [self item:@"Quick Connect…" action:@selector(quickConnect:) key:@"k"];
  qc.target = self;
  [file addItem:qc];
  NSMenuItem* nb = [self item:@"New Connection" action:@selector(newBookmark:) key:@"n"];
  nb.target = self;
  [file addItem:nb];
  [file addItem:[NSMenuItem separatorItem]];
  NSMenuItem* imp = [self item:@"Import Connections…" action:@selector(importBookmarks:) key:@""];
  imp.target = self;
  [file addItem:imp];
  NSMenuItem* exp = [self item:@"Export Connections…" action:@selector(exportBookmarks:) key:@""];
  exp.target = self;
  [file addItem:exp];
  [file addItem:[NSMenuItem separatorItem]];
  [file addItem:[self item:@"Save as Connection" action:@selector(saveAsBookmark:) key:@""]];
  [file addItem:[self item:@"Save Screenshot…" action:@selector(takeScreenshot:) key:@"s" mods:kLocalShortcutMask]];
  [file addItem:[NSMenuItem separatorItem]];
  [file addItem:[self item:@"Close Window" action:@selector(performClose:) key:@"w"]];
  [self addSubmenu:file title:@"File" to:main];

  // Edit (for text fields in the connection manager)
  NSMenu* edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItem:[self item:@"Undo" action:@selector(undo:) key:@"z"]];
  [edit addItem:[self item:@"Redo" action:@selector(redo:) key:@"z"
                      mods:NSEventModifierFlagCommand | NSEventModifierFlagShift]];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItem:[self item:@"Cut" action:@selector(cut:) key:@"x"]];
  [edit addItem:[self item:@"Copy" action:@selector(copy:) key:@"c"]];
  [edit addItem:[self item:@"Paste" action:@selector(paste:) key:@"v"]];
  [edit addItem:[self item:@"Select All" action:@selector(selectAll:) key:@"a"]];
  NSMenuItem* find = [self item:@"Find…" action:@selector(performFindPanelAction:) key:@"f"];
  find.tag = NSFindPanelActionShowFindPanel;
  [edit addItem:find];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItem:[self item:@"Type Clipboard Text" action:@selector(typeClipboard:) key:@"t" mods:kLocalShortcutMask]];
  [edit addItem:[self item:@"Copy Screenshot" action:@selector(copyScreenshot:) key:@"c" mods:kLocalShortcutMask]];
  [self addSubmenu:edit title:@"Edit" to:main];

  // View
  NSMenu* view = [[NSMenu alloc] initWithTitle:@"View"];
  [view addItem:[self local:@"Fit to Window" action:@selector(setScaleFit:) key:@"0"]];
  [view addItem:[self local:@"Actual Size (100%)" action:@selector(setScale100:) key:@"1"]];
  [view addItem:[self local:@"Pixel Perfect (1:1 Retina)" action:@selector(setScaleNative:) key:@"2"]];
  [view addItem:[self local:@"Stretch to Window" action:@selector(setScaleFill:) key:@"3"]];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItem:[self local:@"Zoom In" action:@selector(zoomIn:) key:@"="]];
  [view addItem:[self local:@"Zoom Out" action:@selector(zoomOut:) key:@"-"]];
  [view addItem:[self item:@"Smooth Scaling" action:@selector(toggleSmoothScaling:) key:@"" mods:0]];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItem:[self local:@"Resize Window to Remote Screen" action:@selector(sizeWindowToRemote:) key:@"9"]];
  [view addItem:[self item:@"Resize Remote Screen to Window" action:@selector(toggleRemoteResize:) key:@"" mods:0]];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItem:[self local:@"Show Statistics" action:@selector(toggleStats:) key:@"i"]];
  [view addItem:[self item:@"Show Toolbar" action:@selector(toggleToolbarShown:) key:@"" mods:0]];
  [view addItem:[self item:@"Customize Toolbar…" action:@selector(runToolbarCustomizationPalette:) key:@"" mods:0]];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItem:[self local:@"Enter Full Screen" action:@selector(toggleFullScreen:) key:@"f"]];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItem:[self item:@"Bigger Terminal Font" action:@selector(biggerFont:) key:@"+"]];
  [view addItem:[self item:@"Smaller Terminal Font" action:@selector(smallerFont:) key:@"-"]];
  [view addItem:[self item:@"Default Terminal Font Size" action:@selector(defaultFontSize:) key:@"" mods:0]];
  [view addItem:[self item:@"Clear Terminal" action:@selector(clearTerminal:) key:@"k" mods:NSEventModifierFlagCommand | NSEventModifierFlagOption]];
  [self addSubmenu:view title:@"View" to:main];

  // Session
  NSMenu* sess = [[NSMenu alloc] initWithTitle:@"Session"];
  NSMenuItem* cad = [self local:@"Send Ctrl-Alt-Del" action:@selector(sendCtrlAltDel:) key:@"\x08"];
  [sess addItem:cad];
  NSMenu* keys = [[NSMenu alloc] initWithTitle:@"Send Keys"];
  [keys addItem:[self tagged:@"Ctrl-Shift-Esc (Task Manager)" action:@selector(sendCtrlShiftEsc:) tag:0]];
  [keys addItem:[self tagged:@"Ctrl-Esc" action:@selector(sendCtrlEsc:) tag:0]];
  [keys addItem:[self tagged:@"Windows Key" action:@selector(sendWindowsKey:) tag:0]];
  [keys addItem:[self tagged:@"Win-L (Lock)" action:@selector(sendWinL:) tag:0]];
  [keys addItem:[self tagged:@"Win-R (Run)" action:@selector(sendWinR:) tag:0]];
  [keys addItem:[self tagged:@"Win-E (Explorer)" action:@selector(sendWinE:) tag:0]];
  [keys addItem:[self tagged:@"Win-D (Desktop)" action:@selector(sendWinD:) tag:0]];
  [keys addItem:[self tagged:@"Alt-Tab" action:@selector(sendAltTab:) tag:0]];
  [keys addItem:[self tagged:@"Alt-F4" action:@selector(sendAltF4:) tag:0]];
  [keys addItem:[self tagged:@"Print Screen" action:@selector(sendPrintScreen:) tag:0]];
  NSMenuItem* keysItem = [[NSMenuItem alloc] initWithTitle:@"Send Keys" action:nil keyEquivalent:@""];
  keysItem.submenu = keys;
  [sess addItem:keysItem];
  [sess addItem:[NSMenuItem separatorItem]];
  [sess addItem:[self local:@"File Transfer…" action:@selector(showFileTransfer:) key:@"o"]];
  [sess addItem:[self local:@"SSH Terminal to This Device" action:@selector(openSSHTerminal:) key:@"e"]];
  [sess addItem:[NSMenuItem separatorItem]];
  [sess addItem:[self local:@"Refresh Screen" action:@selector(refreshScreen:) key:@"r"]];
  [sess addItem:[self local:@"View Only" action:@selector(toggleViewOnly:) key:@"v"]];
  [sess addItem:[NSMenuItem separatorItem]];

  NSMenu* quality = [[NSMenu alloc] initWithTitle:@"Quality"];
  [quality addItem:[self tagged:@"Automatic" action:@selector(setQualityPreset:) tag:ZVQualityAuto]];
  [quality addItem:[self tagged:@"Lossless (LAN)" action:@selector(setQualityPreset:) tag:ZVQualityLossless]];
  [quality addItem:[self tagged:@"High" action:@selector(setQualityPreset:) tag:ZVQualityHigh]];
  [quality addItem:[self tagged:@"Balanced" action:@selector(setQualityPreset:) tag:ZVQualityBalanced]];
  [quality addItem:[self tagged:@"Low Bandwidth" action:@selector(setQualityPreset:) tag:ZVQualityLow]];
  [quality addItem:[NSMenuItem separatorItem]];
  [quality addItem:[self tagged:@"Smooth Video (H.264)" action:@selector(setQualityPreset:) tag:ZVQualityVideo]];
  NSMenuItem* qItem = [[NSMenuItem alloc] initWithTitle:@"Quality" action:nil keyEquivalent:@""];
  qItem.submenu = quality;
  [sess addItem:qItem];

  NSMenu* cmd = [[NSMenu alloc] initWithTitle:@"⌘ Key Sends"];
  [cmd addItem:[self tagged:@"Windows Key" action:@selector(setCommandKeyMode:) tag:ZVCommandAsWindows]];
  [cmd addItem:[self tagged:@"Ctrl" action:@selector(setCommandKeyMode:) tag:ZVCommandAsControl]];
  [cmd addItem:[self tagged:@"Alt" action:@selector(setCommandKeyMode:) tag:ZVCommandAsAlt]];
  NSMenuItem* cmdItem = [[NSMenuItem alloc] initWithTitle:@"⌘ Key Sends" action:nil keyEquivalent:@""];
  cmdItem.submenu = cmd;
  [sess addItem:cmdItem];

  NSMenu* layout = [[NSMenu alloc] initWithTitle:@"Keyboard Layout"];
  [layout addItem:[self tagged:@"Server Layout (Raw Key Codes)" action:@selector(setKeyboardMode:) tag:ZVKeyboardRawKeycodes]];
  [layout addItem:[self tagged:@"Mac Layout (Symbols)" action:@selector(setKeyboardMode:) tag:ZVKeyboardSymbols]];
  NSMenuItem* layoutItem = [[NSMenuItem alloc] initWithTitle:@"Keyboard Layout" action:nil keyEquivalent:@""];
  layoutItem.submenu = layout;
  [sess addItem:layoutItem];

  [sess addItem:[NSMenuItem separatorItem]];
  [sess addItem:[self item:@"Connection Info" action:@selector(showConnectionInfo:) key:@"" mods:0]];
  [sess addItem:[NSMenuItem separatorItem]];
  [sess addItem:[self item:@"Reconnect" action:@selector(reconnect:) key:@"" mods:0]];
  [sess addItem:[self local:@"Disconnect" action:@selector(disconnect:) key:@"w"]];
  [self addSubmenu:sess title:@"Session" to:main];

  // Window
  NSMenu* win = [[NSMenu alloc] initWithTitle:@"Window"];
  [win addItem:[self item:@"Minimize" action:@selector(performMiniaturize:) key:@"m"]];
  [win addItem:[self item:@"Zoom" action:@selector(performZoom:) key:@"" mods:0]];
  [win addItem:[NSMenuItem separatorItem]];
  [win addItem:[self item:@"Show Previous Tab" action:@selector(selectPreviousTab:) key:@"" mods:0]];
  [win addItem:[self item:@"Show Next Tab" action:@selector(selectNextTab:) key:@"" mods:0]];
  [win addItem:[self item:@"Merge All Windows" action:@selector(mergeAllWindows:) key:@"" mods:0]];
  [win addItem:[NSMenuItem separatorItem]];
  [win addItem:[self item:@"Bring All to Front" action:@selector(arrangeInFront:) key:@"" mods:0]];
  [self addSubmenu:win title:@"Window" to:main];
  NSApp.windowsMenu = win;

  NSApp.mainMenu = main;
}

@end
