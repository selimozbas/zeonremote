// Zeon Remote - two pane file transfer window (this Mac <-> remote over SFTP)
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

#pragma mark - Transfer queue

typedef NS_ENUM(NSInteger, ZVJobState) {
  ZVJobWaiting,
  ZVJobRunning,
  ZVJobDone,
  ZVJobFailed,
  ZVJobStopped,
};

// One upload or download in the transfer queue
@interface ZVTransferJob : NSObject
@property (nonatomic) BOOL upload;
@property (nonatomic, copy) NSArray<NSURL*>* urls;              // upload sources
@property (nonatomic, copy) NSArray<ZVRemoteFile*>* entries;    // download sources
@property (nonatomic, copy) NSString* destination;
@property (nonatomic) ZVJobState state;
@property (nonatomic) ZVTransferProgress progress;
@property (nonatomic, copy, nullable) NSString* currentName;
@property (nonatomic, copy, nullable) NSString* error;
@property (nonatomic) double bytesPerSecond;
@property (nonatomic, strong, nullable) NSDate* started;
@property (nonatomic) NSTimeInterval elapsed;
// Speed sampling
@property (nonatomic) CFAbsoluteTime sampleTime;
@property (nonatomic) unsigned long long sampleBytes;
- (NSUInteger)itemCount;
- (NSString*)title;
- (void)updateProgress:(ZVTransferProgress)p;
@end

@implementation ZVTransferJob

- (NSUInteger)itemCount
{
  return self.upload ? self.urls.count : self.entries.count;
}

- (NSString*)title
{
  NSString* first = self.upload ? self.urls.firstObject.lastPathComponent : self.entries.firstObject.name;
  NSUInteger n = [self itemCount];
  NSString* items = n == 1 ? first : [NSString stringWithFormat:@"%@ and %lu more", first, (unsigned long)(n - 1)];
  return [NSString stringWithFormat:@"%@ → %@", items,
          self.destination.lastPathComponent.length ? self.destination.lastPathComponent : self.destination];
}

// Called with every progress report; keeps a smoothed transfer speed
- (void)updateProgress:(ZVTransferProgress)p
{
  self.progress = p;
  self.currentName = p.currentName;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (self.sampleTime == 0) {
    self.sampleTime = now;
    self.sampleBytes = p.bytesDone;
    return;
  }
  CFTimeInterval dt = now - self.sampleTime;
  if (dt < 0.5)
    return;
  double instant = (double)(p.bytesDone - MIN(p.bytesDone, self.sampleBytes)) / dt;
  self.bytesPerSecond = self.bytesPerSecond > 0 ? 0.7 * self.bytesPerSecond + 0.3 * instant : instant;
  self.sampleTime = now;
  self.sampleBytes = p.bytesDone;
}

@end

static NSString* ZVFormatDuration(NSTimeInterval t)
{
  NSDateComponentsFormatter* f = [[NSDateComponentsFormatter alloc] init];
  f.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
  f.allowedUnits = t >= 3600 ? (NSCalendarUnitHour | NSCalendarUnitMinute)
                             : (NSCalendarUnitMinute | NSCalendarUnitSecond);
  f.maximumUnitCount = 2;
  return [f stringFromTimeInterval:MAX(1, round(t))];
}

// Row of the transfer list: direction icon, title, progress bar, details and
// a button that stops (running) or removes (any other state) the job
@interface ZVTransferRowView : NSTableCellView
@property (nonatomic, readonly) NSImageView* icon;
@property (nonatomic, readonly) NSTextField* title;
@property (nonatomic, readonly) NSTextField* detail;
@property (nonatomic, readonly) NSProgressIndicator* bar;
@property (nonatomic, readonly) NSButton* button;
@end

@implementation ZVTransferRowView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    _icon = [[NSImageView alloc] init];
    _icon.contentTintColor = [NSColor controlAccentColor];
    _title = [NSTextField labelWithString:@""];
    _title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _detail = [NSTextField labelWithString:@""];
    _detail.font = [NSFont systemFontOfSize:11];
    _detail.textColor = [NSColor secondaryLabelColor];
    _detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _bar = [[NSProgressIndicator alloc] init];
    _bar.style = NSProgressIndicatorStyleBar;
    _bar.indeterminate = NO;
    _bar.minValue = 0;
    _bar.maxValue = 1;
    _bar.controlSize = NSControlSizeSmall;
    _button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                                                  accessibilityDescription:@"Remove"]
                                 target:nil action:nil];
    _button.bordered = NO;
    _button.contentTintColor = [NSColor secondaryLabelColor];
    for (NSView* v in @[_icon, _title, _detail, _bar, _button]) {
      v.translatesAutoresizingMaskIntoConstraints = NO;
      [self addSubview:v];
    }
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
      [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
      [_icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_icon.widthAnchor constraintEqualToConstant:18],
      [_title.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:8],
      [_title.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
      [_title.trailingAnchor constraintEqualToAnchor:_bar.leadingAnchor constant:-12],
      [_detail.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
      [_detail.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:1],
      [_detail.trailingAnchor constraintEqualToAnchor:_button.leadingAnchor constant:-8],
      [_bar.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
      [_bar.widthAnchor constraintEqualToConstant:160],
      [_bar.trailingAnchor constraintEqualToAnchor:_button.leadingAnchor constant:-8],
      [_button.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
    ]];
  }
  return self;
}

@end

#pragma mark - Window

@interface ZVFileTransferWindowController () <ZVSFTPClientDelegate, ZVFTPClientDelegate, ZVFilePaneDelegate,
                                              NSWindowDelegate, NSSplitViewDelegate,
                                              NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation ZVFileTransferWindowController {
  __weak id<ZVFileTransferContext> _context;
  id<ZVFileClient> _client;
  BOOL _ftp;
  NSString* _title;

  ZVLocalFilePane* _local;
  ZVRemoteFilePane* _remote;
  ZVFilePane* _lastActive;

  NSTextField* _status;
  NSProgressIndicator* _progress;
  NSButton* _stopButton;
  NSButton* _uploadButton;
  NSButton* _downloadButton;
  NSButton* _queueButton;
  BOOL _started;

  // Transfers run one after another; finished ones stay listed until cleared
  NSMutableArray<ZVTransferJob*>* _jobs;
  ZVTransferJob* _running;
  NSTableView* _queueTable;
  NSScrollView* _queueScroll;
  NSLayoutConstraint* _queueHeight;
  NSButton* _clearButton;
  NSTimer* _queueTimer;

  // "Apply to all" answer for the running transfer
  NSNumber* _conflictAnswer;

  NSByteCountFormatter* _sizeFormatter;
  NSDateFormatter* _dateFormatter;
}

- (instancetype)initWithContext:(id<ZVFileTransferContext>)context host:(NSString*)host port:(int)port
                       username:(NSString*)username title:(NSString*)title
{
  ZVSFTPClient* sftp = [[ZVSFTPClient alloc] initWithHost:host port:port];
  sftp.username = username.length ? username : context.transferUsername;
  sftp.offeredPassword = context.transferPassword;
  self = [self initWithContext:context client:sftp title:title];
  if (self)
    sftp.delegate = self;
  return self;
}

- (instancetype)initWithContext:(id<ZVFileTransferContext>)context ftpHost:(NSString*)host port:(int)port
                       security:(ZVFTPSecurity)security username:(NSString*)username title:(NSString*)title
{
  ZVFTPClient* ftp = [[ZVFTPClient alloc] initWithHost:host port:port security:security];
  ftp.username = username.length ? username : context.transferUsername;
  ftp.offeredPassword = context.transferPassword;
  self = [self initWithContext:context client:ftp title:title];
  if (self) {
    _ftp = YES;
    ftp.delegate = self;
  }
  return self;
}

- (instancetype)initWithContext:(id<ZVFileTransferContext>)context client:(id<ZVFileClient>)client
                          title:(NSString*)title
{
  NSString* host = client.host;
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 580)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:w];
  if (self) {
    _context = context;
    _title = [title copy];

    _client = client;
    __weak ZVFileTransferWindowController* weakSelf = self;
    _client.conflictHandler = ^ZVConflictAction(ZVTransferConflict* c) {
      return [weakSelf resolveConflict:c];
    };

    _jobs = [NSMutableArray array];
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

- (id<ZVFileClient>)client { return _client; }

- (void)close
{
  [_client disconnect];
  [self.window close];
}

#pragma mark Keychain

// SSH and FTP passwords are saved per device (MAC address or server key)
- (NSString*)keychainAccount
{
  NSString* kind = _ftp ? @"ftp" : @"ssh";
  NSString* ident = [ZVTrust identityForMAC:_client.deviceMAC key:_client.hostKeyFingerprint];
  return ident ? [NSString stringWithFormat:@"%@:%@", kind, ident]
               : [NSString stringWithFormat:@"%@-host:%@", kind, _client.host];
}

- (NSString*)ftpClientSavedPassword:(ZVFTPClient*)client
{
  return [self sftpClientSavedPassword:nil];
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
  _queueButton = [NSButton buttonWithTitle:@"Transfers" target:self action:@selector(toggleQueue:)];
  _queueButton.image = [NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:nil];
  _queueButton.imagePosition = NSImageLeading;
  _queueButton.buttonType = NSButtonTypePushOnPushOff;
  _queueButton.toolTip = @"Show the transfer list";
  _clearButton = [NSButton buttonWithTitle:@"Clear Finished" target:self action:@selector(clearFinished:)];
  _clearButton.hidden = YES;

  _queueTable = [[NSTableView alloc] init];
  _queueTable.headerView = nil;
  _queueTable.rowHeight = 40;
  _queueTable.usesAlternatingRowBackgroundColors = YES;
  _queueTable.dataSource = self;
  _queueTable.delegate = self;
  NSTableColumn* jobColumn = [[NSTableColumn alloc] initWithIdentifier:@"job"];
  jobColumn.resizingMask = NSTableColumnAutoresizingMask;
  [_queueTable addTableColumn:jobColumn];
  _queueTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _queueScroll = [[NSScrollView alloc] init];
  _queueScroll.documentView = _queueTable;
  _queueScroll.hasVerticalScroller = YES;
  _queueScroll.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:_queueScroll];
  _queueHeight = [_queueScroll.heightAnchor constraintEqualToConstant:0];

  NSStackView* bar = [NSStackView stackViewWithViews:@[_uploadButton, _downloadButton, _status,
                                                       _progress, _stopButton, _clearButton,
                                                       _queueButton]];
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
    [split.bottomAnchor constraintEqualToAnchor:_queueScroll.topAnchor],
    [_queueScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [_queueScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [_queueScroll.bottomAnchor constraintEqualToAnchor:line.topAnchor],
    _queueHeight,
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
  _uploadButton.enabled = _remote.path != nil && _local.selectedEntries.count > 0;
  _downloadButton.enabled = _remote.path != nil && _remote.selectedEntries.count > 0;
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

- (IBAction)stopTransfer:(id)sender
{
  [_client cancelTransfer];
}

- (void)upload:(NSArray<NSURL*>*)urls toDirectory:(NSString*)dir
{
  if (urls.count == 0 || !dir)
    return;
  ZVTransferJob* job = [[ZVTransferJob alloc] init];
  job.upload = YES;
  job.urls = urls;
  job.destination = dir;
  [self enqueue:job];
}

- (void)download:(NSArray<ZVRemoteFile*>*)entries toDirectory:(NSString*)dir
{
  if (entries.count == 0 || !dir)
    return;
  ZVTransferJob* job = [[ZVTransferJob alloc] init];
  job.upload = NO;
  job.entries = entries;
  job.destination = dir;
  [self enqueue:job];
}

#pragma mark Queue

- (void)enqueue:(ZVTransferJob*)job
{
  [_jobs addObject:job];
  // A second transfer while one is running: show the list so it is clear
  // that it waits its turn
  if (_running && _queueButton.state == NSControlStateValueOff) {
    _queueButton.state = NSControlStateValueOn;
    [self toggleQueue:nil];
  }
  [self queueChanged];
  [self startNextJob];
}

- (void)startNextJob
{
  if (_running)
    return;
  ZVTransferJob* job = nil;
  for (ZVTransferJob* j in _jobs) {
    if (j.state == ZVJobWaiting) {
      job = j;
      break;
    }
  }
  if (!job) {
    [_queueTimer invalidate];
    _queueTimer = nil;
    return;
  }

  _running = job;
  _conflictAnswer = nil;
  job.state = ZVJobRunning;
  job.started = [NSDate date];
  _progress.doubleValue = 0;
  _progress.hidden = NO;
  _stopButton.hidden = NO;
  _status.stringValue = job.upload ? @"Uploading…" : @"Downloading…";
  if (!_queueTimer)
    _queueTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(queueTick:)
                                                 userInfo:nil repeats:YES];
  [self queueChanged];

  __weak ZVFileTransferWindowController* weakSelf = self;
  void (^progress)(ZVTransferProgress) = ^(ZVTransferProgress p) {
    [weakSelf job:job progressed:p];
  };
  if (job.upload) {
    [_client uploadURLs:job.urls toDirectory:job.destination progress:progress completion:^(NSError* error) {
      [weakSelf job:job finishedWithError:error];
    }];
  } else {
    [_client downloadFiles:job.entries toDirectory:[NSURL fileURLWithPath:job.destination isDirectory:YES]
                  progress:progress completion:^(NSArray<NSURL*>* urls, NSError* error) {
      [weakSelf job:job finishedWithError:error];
    }];
  }
}

- (void)job:(ZVTransferJob*)job progressed:(ZVTransferProgress)p
{
  [job updateProgress:p];
  _progress.doubleValue = p.bytesTotal ? (double)p.bytesDone / p.bytesTotal : 0;
  _status.stringValue = [NSString stringWithFormat:@"%@ %@ (%lu of %lu)",
                         job.upload ? @"Uploading" : @"Downloading", p.currentName ?: @"",
                         (unsigned long)MIN(p.filesDone + 1, MAX(p.filesTotal, (NSUInteger)1)),
                         (unsigned long)p.filesTotal];
  [self reloadJob:job];
}

- (void)job:(ZVTransferJob*)job finishedWithError:(NSError*)error
{
  job.elapsed = -[job.started timeIntervalSinceNow];
  if (!error) {
    job.state = ZVJobDone;
  } else if (error.code == NSUserCancelledError) {
    job.state = ZVJobStopped;
  } else {
    job.state = ZVJobFailed;
    job.error = error.localizedDescription;
    [self filePane:job.upload ? _remote : _local showError:error];
  }
  _running = nil;
  _progress.hidden = YES;
  _stopButton.hidden = YES;
  NSString* verb = job.upload ? @"Upload" : @"Download";
  switch (job.state) {
  case ZVJobDone:
    _status.stringValue = [NSString stringWithFormat:@"%@ed %lu item(s)", verb, (unsigned long)[job itemCount]];
    break;
  case ZVJobStopped:
    _status.stringValue = @"Stopped";
    break;
  default:
    _status.stringValue = [verb stringByAppendingString:@" failed"];
    break;
  }
  ZVFilePane* target = job.upload ? _remote : _local;
  if ([target.path isEqualToString:job.destination])
    [target reload];
  [self queueChanged];
  [self startNextJob];
}

- (void)queueTick:(NSTimer*)timer
{
  if (_running)
    [self reloadJob:_running];
}

- (void)queueChanged
{
  [_queueTable reloadData];
  NSUInteger waiting = 0, finished = 0;
  for (ZVTransferJob* j in _jobs) {
    if (j.state == ZVJobWaiting)
      waiting++;
    else if (j.state != ZVJobRunning)
      finished++;
  }
  NSUInteger active = waiting + (_running ? 1 : 0);
  _queueButton.title = active ? [NSString stringWithFormat:@"Transfers (%lu)", (unsigned long)active]
                              : @"Transfers";
  _clearButton.hidden = finished == 0 || _queueButton.state == NSControlStateValueOff;
}

- (void)reloadJob:(ZVTransferJob*)job
{
  NSUInteger row = [_jobs indexOfObjectIdenticalTo:job];
  if (row != NSNotFound)
    [_queueTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                           columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (IBAction)toggleQueue:(id)sender
{
  BOOL show = _queueButton.state == NSControlStateValueOn;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
    ctx.duration = 0.2;
    ctx.allowsImplicitAnimation = YES;
    self->_queueHeight.animator.constant = show ? 150 : 0;
    [self.window.contentView layoutSubtreeIfNeeded];
  }];
  [self queueChanged];
}

- (IBAction)clearFinished:(id)sender
{
  [_jobs filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ZVTransferJob* j, NSDictionary* b) {
    return j.state == ZVJobWaiting || j.state == ZVJobRunning;
  }]];
  [self queueChanged];
}

// Stops the running job, or removes any other one from the list
- (IBAction)jobButtonClicked:(NSButton*)sender
{
  NSInteger row = [_queueTable rowForView:sender];
  if (row < 0 || row >= (NSInteger)_jobs.count)
    return;
  ZVTransferJob* job = _jobs[row];
  if (job.state == ZVJobRunning) {
    [_client cancelTransfer];
    return;
  }
  [_jobs removeObjectAtIndex:row];
  [self queueChanged];
}

- (NSString*)detailForJob:(ZVTransferJob*)job
{
  ZVTransferProgress p = job.progress;
  NSString* where = job.upload ? [NSString stringWithFormat:@"to %@", job.destination]
                               : [NSString stringWithFormat:@"to this Mac, %@", job.destination];
  switch (job.state) {
  case ZVJobWaiting:
    return [NSString stringWithFormat:@"Waiting — %@", where];
  case ZVJobRunning: {
    if (p.bytesTotal == 0)
      return @"Preparing…";
    NSMutableString* d = [NSMutableString stringWithFormat:@"%@ of %@",
                          [_sizeFormatter stringFromByteCount:p.bytesDone],
                          [_sizeFormatter stringFromByteCount:p.bytesTotal]];
    if (job.bytesPerSecond > 0) {
      [d appendFormat:@" — %@/s", [_sizeFormatter stringFromByteCount:(long long)job.bytesPerSecond]];
      double left = (double)(p.bytesTotal - MIN(p.bytesDone, p.bytesTotal)) / job.bytesPerSecond;
      [d appendFormat:@" — %@ left", ZVFormatDuration(left)];
    }
    if (job.currentName.length)
      [d appendFormat:@" — %@", job.currentName];
    return d;
  }
  case ZVJobDone: {
    NSString* size = [_sizeFormatter stringFromByteCount:p.bytesTotal];
    if (job.elapsed >= 1 && p.bytesTotal)
      return [NSString stringWithFormat:@"Done — %@ in %@ (%@/s)", size, ZVFormatDuration(job.elapsed),
              [_sizeFormatter stringFromByteCount:(long long)(p.bytesTotal / job.elapsed)]];
    return [NSString stringWithFormat:@"Done — %@", size];
  }
  case ZVJobStopped:
    return @"Stopped";
  case ZVJobFailed:
    return [@"Failed: " stringByAppendingString:job.error ?: @"unknown error"];
  }
  return @"";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
  return _jobs.count;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
  ZVTransferRowView* v = [tableView makeViewWithIdentifier:@"job" owner:self];
  if (!v) {
    v = [[ZVTransferRowView alloc] initWithFrame:NSZeroRect];
    v.identifier = @"job";
    v.button.target = self;
    v.button.action = @selector(jobButtonClicked:);
  }
  ZVTransferJob* job = _jobs[row];
  NSString* symbol;
  switch (job.state) {
  case ZVJobDone:    symbol = @"checkmark.circle.fill"; break;
  case ZVJobFailed:  symbol = @"exclamationmark.triangle.fill"; break;
  case ZVJobStopped: symbol = @"stop.circle"; break;
  default:           symbol = job.upload ? @"arrow.up.circle" : @"arrow.down.circle"; break;
  }
  v.icon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
  v.icon.contentTintColor = job.state == ZVJobFailed ? [NSColor systemOrangeColor]
                          : job.state == ZVJobDone   ? [NSColor systemGreenColor]
                                                     : [NSColor controlAccentColor];
  v.title.stringValue = [NSString stringWithFormat:@"%@ %@", job.upload ? @"Upload" : @"Download", [job title]];
  v.detail.stringValue = [self detailForJob:job];
  ZVTransferProgress p = job.progress;
  v.bar.hidden = job.state != ZVJobRunning && job.state != ZVJobWaiting;
  v.bar.doubleValue = p.bytesTotal ? (double)p.bytesDone / p.bytesTotal : 0;
  BOOL running = job.state == ZVJobRunning;
  v.button.image = [NSImage imageWithSystemSymbolName:running ? @"stop.circle.fill" : @"xmark.circle.fill"
                             accessibilityDescription:running ? @"Stop" : @"Remove"];
  v.button.toolTip = running ? @"Stop" : @"Remove from the list";
  return v;
}

- (BOOL)tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row
{
  return NO;
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

#pragma mark ZVFTPClientDelegate

- (BOOL)ftpClient:(ZVFTPClient*)client trustCertificate:(NSString*)identity subject:(NSString*)subject
{
  id<ZVFileTransferContext> c = _context;
  NSString* scope = c ? c.transferScope : [@"ftp-host:" stringByAppendingString:client.host];
  return [ZVTrust verifyKey:identity mac:client.deviceMAC scope:scope host:client.host];
}

- (BOOL)ftpClient:(ZVFTPClient*)client wantsPasswordForUser:(NSString**)user
         password:(NSString**)password remember:(BOOL*)remember failed:(BOOL)failed
{
  NSString* what = client.security == ZVFTPPlain
    ? @"Enter the FTP login. The connection is not encrypted: the password is sent as plain text."
    : @"Enter the FTP login (FTPS, encrypted).";
  return [self askLoginTitle:[NSString stringWithFormat:@"FTP login to %@", client.host]
                        info:what user:user password:password remember:remember failed:failed];
}

- (BOOL)sftpClient:(ZVSFTPClient*)client wantsPasswordForUser:(NSString**)user
          password:(NSString**)password remember:(BOOL*)remember failed:(BOOL)failed
{
  return [self askLoginTitle:[NSString stringWithFormat:@"SSH login to %@", client.host]
                        info:@"File transfer uses SSH (SFTP). Enter the login of the device."
                        user:user password:password remember:remember failed:failed];
}

- (BOOL)askLoginTitle:(NSString*)title info:(NSString*)info user:(NSString**)user
             password:(NSString**)password remember:(BOOL*)remember failed:(BOOL)failed
{
  BOOL saving = [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = title;
  alert.informativeText = failed ? @"The user name or password was not accepted." : info;
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
  for (ZVTransferJob* j in _jobs)
    if (j.state == ZVJobWaiting)
      j.state = ZVJobStopped;
  [_queueTimer invalidate];
  _queueTimer = nil;
  [_client cancelTransfer];
}

@end
