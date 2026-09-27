// ZeonVNC - two pane file transfer window (this Mac <-> remote over SFTP)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import "ZVFileTransferWindowController.h"
#import "ZVFilePane.h"
#import "ZVKeychain.h"
#import "ZVPreferences.h"
#import "ZVTrust.h"

@interface ZVFileTransferWindowController () <ZVSFTPClientDelegate, ZVFilePaneDelegate,
                                              NSWindowDelegate, NSSplitViewDelegate>
@end

@implementation ZVFileTransferWindowController {
  __weak id<ZVFileTransferContext> _context;
  ZVSFTPClient* _client;
  NSString* _title;

  ZVLocalFilePane* _local;
  ZVRemoteFilePane* _remote;
  ZVFilePane* _lastActive;

  NSTextField* _status;
  NSProgressIndicator* _progress;
  NSButton* _stopButton;
  NSButton* _uploadButton;
  NSButton* _downloadButton;
  BOOL _transferring;
  BOOL _started;

  // "Apply to all" answer for the running transfer
  NSNumber* _conflictAnswer;

  NSByteCountFormatter* _sizeFormatter;
  NSDateFormatter* _dateFormatter;
}

- (instancetype)initWithContext:(id<ZVFileTransferContext>)context host:(NSString*)host port:(int)port
                       username:(NSString*)username title:(NSString*)title
{
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 580)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:w];
  if (self) {
    _context = context;
    _title = [title copy];

    _client = [[ZVSFTPClient alloc] initWithHost:host port:port];
    _client.delegate = self;
    _client.username = username.length ? username : context.transferUsername;
    _client.offeredPassword = context.transferPassword;
    __weak ZVFileTransferWindowController* weakSelf = self;
    _client.conflictHandler = ^ZVConflictAction(ZVTransferConflict* c) {
      return [weakSelf resolveConflict:c];
    };

    _sizeFormatter = [[NSByteCountFormatter alloc] init];
    _sizeFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _dateFormatter.timeStyle = NSDateFormatterShortStyle;
    _dateFormatter.doesRelativeDateFormatting = YES;

    w.title = [NSString stringWithFormat:@"Files — %@", title];
    w.subtitle = [NSString stringWithFormat:@"This Mac ⇄ %@", host];
    w.minSize = NSMakeSize(760, 380);
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.frameAutosaveName = @"ZVFileTransferWindow2";
    [self buildUI];
  }
  return self;
}

- (ZVSFTPClient*)client { return _client; }

- (void)close
{
  [_client disconnect];
  [self.window close];
}

#pragma mark Keychain

// SSH passwords are saved per device (MAC address or host key)
- (NSString*)keychainAccount
{
  NSString* ident = [ZVTrust identityForMAC:_client.deviceMAC key:_client.hostKeyFingerprint];
  return ident ? [@"ssh:" stringByAppendingString:ident]
               : [@"ssh-host:" stringByAppendingString:_client.host];
}

- (NSString*)sftpClientSavedPassword:(ZVSFTPClient*)client
{
  if (![[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords])
    return nil;
  return [ZVKeychain passwordForAccount:[self keychainAccount]];
}

- (void)rememberPasswordIfNeeded
{
  NSString* pw = _client.passwordToRemember;
  if (pw && [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords])
    [ZVKeychain setPassword:pw forAccount:[self keychainAccount]];
}

#pragma mark UI

- (void)buildUI
{
  NSView* content = self.window.contentView;

  _local = [[ZVLocalFilePane alloc] init];
  _local.delegate = self;
  _remote = [[ZVRemoteFilePane alloc] initWithClient:_client];
  _remote.delegate = self;
  _remote.paneTitle = _title;

  NSSplitView* split = [[NSSplitView alloc] init];
  split.vertical = YES;
  split.dividerStyle = NSSplitViewDividerStyleThin;
  split.delegate = self;
  split.autosaveName = @"ZVFileTransferSplit";
  split.translatesAutoresizingMaskIntoConstraints = NO;
  [split addArrangedSubview:_local.view];
  [split addArrangedSubview:_remote.view];
  [content addSubview:split];

  _uploadButton = [NSButton buttonWithTitle:@"Upload" target:self action:@selector(uploadSelected:)];
  _uploadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:nil];
  _uploadButton.imagePosition = NSImageTrailing;
  _uploadButton.toolTip = @"Copy the selected items on this Mac to the remote folder";
  _downloadButton = [NSButton buttonWithTitle:@"Download" target:self action:@selector(downloadSelected:)];
  _downloadButton.image = [NSImage imageWithSystemSymbolName:@"arrow.left" accessibilityDescription:nil];
  _downloadButton.imagePosition = NSImageLeading;
  _downloadButton.toolTip = @"Copy the selected remote items to the folder on this Mac";

  _status = [NSTextField labelWithString:@""];
  _status.textColor = [NSColor secondaryLabelColor];
  _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  _progress = [[NSProgressIndicator alloc] init];
  _progress.style = NSProgressIndicatorStyleBar;
  _progress.indeterminate = NO;
  _progress.minValue = 0;
  _progress.maxValue = 1;
  _progress.hidden = YES;
  [_progress.widthAnchor constraintEqualToConstant:200].active = YES;
  _stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopTransfer:)];
  _stopButton.hidden = YES;

  NSStackView* bar = [NSStackView stackViewWithViews:@[_uploadButton, _downloadButton, _status,
                                                       _progress, _stopButton]];
  bar.spacing = 10;
  bar.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:bar];

  NSBox* line = [[NSBox alloc] init];
  line.boxType = NSBoxSeparator;
  line.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:line];

  [NSLayoutConstraint activateConstraints:@[
    [split.topAnchor constraintEqualToAnchor:content.topAnchor],
    [split.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [split.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [split.bottomAnchor constraintEqualToAnchor:line.topAnchor],
    [line.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [line.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [line.bottomAnchor constraintEqualToAnchor:bar.topAnchor],
    [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
  ]];
  [self updateButtons];
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i
{
  return 320;
}

- (CGFloat)splitView:(NSSplitView*)splitView constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i
{
  return splitView.bounds.size.width - 320;
}

- (void)showWindow:(id)sender
{
  [super showWindow:sender];
  if (!_started) {
    _started = YES;
    [_local navigateTo:[_local homePath]];
    [self connectRemote];
  }
}

- (void)connectRemote
{
  [_remote setStatus:[NSString stringWithFormat:@"Connecting to %@…", _client.host]];
  _status.stringValue = @"";
  [_client connect:^(NSError* error) {
    if (error) {
      [self->_remote setStatus:error.code == NSUserCancelledError ? @"Not connected" : error.localizedDescription];
      [self filePane:self->_remote showError:error];
      return;
    }
    [self rememberPasswordIfNeeded];
    [self->_remote navigateTo:self->_client.homeDirectory];
  }];
}

- (void)updateButtons
{
  _uploadButton.enabled = !_transferring && _remote.path != nil && _local.selectedEntries.count > 0;
  _downloadButton.enabled = !_transferring && _remote.path != nil && _remote.selectedEntries.count > 0;
}

#pragma mark Pane delegate

- (void)filePaneDidChange:(ZVFilePane*)pane
{
  [self updateButtons];
}

- (void)filePane:(ZVFilePane*)pane showError:(NSError*)error
{
  if (error.code == NSUserCancelledError)
    return;
  NSAlert* a = [NSAlert alertWithError:error];
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)filePaneRequestsTransfer:(ZVFilePane*)pane
{
  if (pane == _local)
    [self uploadSelected:nil];
  else
    [self downloadSelected:nil];
}

- (void)filePane:(ZVFilePane*)pane acceptDrop:(id<NSDraggingInfo>)info intoDirectory:(NSString*)dir
{
  NSPasteboard* pb = info.draggingPasteboard;
  if (pane == _remote) {
    NSArray* urls = [pb readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    [self upload:urls toDirectory:dir];
  } else {
    // Remote rows only carry their path; find the entries
    NSMutableArray* entries = [NSMutableArray array];
    for (NSPasteboardItem* item in pb.pasteboardItems) {
      ZVRemoteFile* f = [_remote entryForPath:[item stringForType:ZVRemotePathPasteboardType]];
      if (f)
        [entries addObject:f];
    }
    [self download:entries toDirectory:dir];
  }
}

#pragma mark Transfers

- (IBAction)uploadSelected:(id)sender
{
  NSMutableArray* urls = [NSMutableArray array];
  for (ZVRemoteFile* e in _local.selectedEntries)
    [urls addObject:[NSURL fileURLWithPath:e.path]];
  [self upload:urls toDirectory:_remote.path];
}

- (IBAction)downloadSelected:(id)sender
{
  [self download:_remote.selectedEntries toDirectory:_local.path];
}

- (void)beginTransfer:(NSString*)text
{
  _transferring = YES;
  _conflictAnswer = nil;
  _progress.doubleValue = 0;
  _progress.hidden = NO;
  _stopButton.hidden = NO;
  _status.stringValue = text;
  [self updateButtons];
}

- (void)endTransfer:(NSString*)text
{
  _transferring = NO;
  _progress.hidden = YES;
  _stopButton.hidden = YES;
  _status.stringValue = text ?: @"";
  [self updateButtons];
}

- (void)showProgress:(ZVTransferProgress)p verb:(NSString*)verb
{
  _progress.doubleValue = p.bytesTotal ? (double)p.bytesDone / p.bytesTotal : 0;
  _status.stringValue = [NSString stringWithFormat:@"%@ %@ (%lu of %lu) — %@ of %@",
                         verb, p.currentName ?: @"",
                         (unsigned long)MIN(p.filesDone + 1, MAX(p.filesTotal, (NSUInteger)1)),
                         (unsigned long)p.filesTotal,
                         [_sizeFormatter stringFromByteCount:p.bytesDone],
                         [_sizeFormatter stringFromByteCount:p.bytesTotal]];
}

- (IBAction)stopTransfer:(id)sender
{
  [_client cancelTransfer];
}

- (void)upload:(NSArray<NSURL*>*)urls toDirectory:(NSString*)dir
{
  if (urls.count == 0 || !dir || _transferring)
    return;
  [self beginTransfer:@"Uploading…"];
  [_client uploadURLs:urls toDirectory:dir progress:^(ZVTransferProgress p) {
    [self showProgress:p verb:@"Uploading"];
  } completion:^(NSError* error) {
    if (error && error.code != NSUserCancelledError)
      [self filePane:self->_remote showError:error];
    [self endTransfer:error ? (error.code == NSUserCancelledError ? @"Stopped" : @"Upload failed")
                            : [NSString stringWithFormat:@"Uploaded %lu item(s)", (unsigned long)urls.count]];
    [self->_remote reload];
  }];
}

- (void)download:(NSArray<ZVRemoteFile*>*)entries toDirectory:(NSString*)dir
{
  if (entries.count == 0 || !dir || _transferring)
    return;
  [self beginTransfer:@"Downloading…"];
  [_client downloadFiles:entries toDirectory:[NSURL fileURLWithPath:dir isDirectory:YES]
                progress:^(ZVTransferProgress p) {
    [self showProgress:p verb:@"Downloading"];
  } completion:^(NSArray<NSURL*>* urls, NSError* error) {
    if (error && error.code != NSUserCancelledError)
      [self filePane:self->_local showError:error];
    [self endTransfer:error ? (error.code == NSUserCancelledError ? @"Stopped" : @"Download failed")
                            : [NSString stringWithFormat:@"Downloaded %lu item(s)", (unsigned long)urls.count]];
    [self->_local reload];
  }];
}

- (void)uploadToRemoteDesktop:(NSArray<NSURL*>*)urls
                     progress:(void (^)(ZVTransferProgress))progress
                   completion:(void (^)(NSString*, NSError*))completion
{
  _conflictAnswer = nil;
  [_client connect:^(NSError* error) {
    if (error) {
      completion(nil, error);
      return;
    }
    [self rememberPasswordIfNeeded];
    NSString* desktop = [self->_client.homeDirectory stringByAppendingPathComponent:@"Desktop"];
    [self->_client directoryExists:desktop completion:^(BOOL exists) {
      NSString* dir = exists ? desktop : self->_client.homeDirectory;
      [self->_client uploadURLs:urls toDirectory:dir progress:progress completion:^(NSError* err) {
        if (!err && [self->_remote.path isEqualToString:dir])
          [self->_remote reload];
        completion(err ? nil : dir, err);
      }];
    }];
  }];
}

#pragma mark Conflicts

- (NSString*)describeSize:(unsigned long long)size date:(NSDate*)date
{
  NSString* s = [_sizeFormatter stringFromByteCount:size];
  return date ? [NSString stringWithFormat:@"%@, modified %@", s, [_dateFormatter stringFromDate:date]] : s;
}

// Called on the main thread while the transfer waits
- (ZVConflictAction)resolveConflict:(ZVTransferConflict*)c
{
  if (_conflictAnswer)
    return (ZVConflictAction)_conflictAnswer.integerValue;

  NSString* where = c.upload ? _client.host : @"this Mac";
  NSAlert* a = [[NSAlert alloc] init];
  a.alertStyle = NSAlertStyleWarning;
  a.messageText = [NSString stringWithFormat:@"“%@” already exists", c.name];
  NSMutableString* info = [NSMutableString stringWithFormat:@"An item with this name already exists in “%@” on %@.\n\n",
                           c.destination.lastPathComponent ?: c.destination, where];
  if (c.existingIsDirectory)
    [info appendString:@"The existing item is a folder, so it can't be replaced; "
                       @"Keep Both saves the file under a new name.\n\n"];
  [info appendFormat:@"Existing: %@\n", [self describeSize:c.existingSize date:c.existingDate]];
  [info appendFormat:@"%@: %@", c.upload ? @"Uploading" : @"Downloading",
   [self describeSize:c.incomingSize date:c.incomingDate]];
  a.informativeText = info;

  NSButton* replace = [a addButtonWithTitle:@"Replace"];
  [a addButtonWithTitle:@"Keep Both"];
  [a addButtonWithTitle:@"Skip"];
  [a addButtonWithTitle:@"Stop"];
  replace.hasDestructiveAction = YES;
  replace.enabled = !c.existingIsDirectory;
  a.showsSuppressionButton = YES;
  a.suppressionButton.title = @"Apply to all remaining conflicts";

  NSModalResponse r = [a runModal];
  ZVConflictAction action;
  switch (r) {
  case NSAlertFirstButtonReturn:  action = ZVConflictReplace; break;
  case NSAlertSecondButtonReturn: action = ZVConflictKeepBoth; break;
  case NSAlertThirdButtonReturn:  action = ZVConflictSkip; break;
  default:                        action = ZVConflictStop; break;
  }
  if (a.suppressionButton.state == NSControlStateValueOn && action != ZVConflictStop)
    _conflictAnswer = @(action);
  return action;
}

#pragma mark ZVSFTPClientDelegate

- (BOOL)sftpClient:(ZVSFTPClient*)client trustHostKey:(NSString*)fingerprint display:(NSString*)display
{
  id<ZVFileTransferContext> c = _context;
  NSString* scope = c ? c.transferScope : [@"ssh-host:" stringByAppendingString:client.host];
  return [ZVTrust verifyKey:fingerprint mac:client.deviceMAC scope:scope host:client.host];
}

- (BOOL)sftpClient:(ZVSFTPClient*)client wantsPasswordForUser:(NSString**)user
          password:(NSString**)password remember:(BOOL*)remember failed:(BOOL)failed
{
  BOOL saving = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"SSH login to %@", client.host];
  alert.informativeText = failed
    ? @"The user name or password was not accepted."
    : @"File transfer uses SSH (SFTP). Enter the login of the device.";
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

- (void)windowWillClose:(NSNotification*)notification
{
  [_client cancelTransfer];
}

@end
