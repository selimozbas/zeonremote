// ZeonVNC - one side of the file transfer window
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "ZVFilePane.h"

NSPasteboardType const ZVRemotePathPasteboardType = @"com.zeonvnc.remote-path";

static NSUserInterfaceItemIdentifier const kColName = @"name";
static NSUserInterfaceItemIdentifier const kColSize = @"size";
static NSUserInterfaceItemIdentifier const kColDate = @"date";

@implementation ZVFilePane {
  NSTableView* _table;
  NSPathControl* _pathControl;
  NSTextField* _paneTitleLabel;
  NSImageView* _paneTitleIcon;
  NSTextField* _footer;
  NSButton* _backButton;
  NSButton* _hiddenButton;

  NSMutableArray<NSString*>* _history;
  NSArray<ZVRemoteFile*>* _all;
  NSArray<ZVRemoteFile*>* _entries;

  NSByteCountFormatter* _sizeFormatter;
  NSDateFormatter* _dateFormatter;
}

- (instancetype)init
{
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _history = [NSMutableArray array];
    _paneTitle = @"";
    _symbolName = @"folder";
    _sizeFormatter = [[NSByteCountFormatter alloc] init];
    _sizeFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _dateFormatter.timeStyle = NSDateFormatterShortStyle;
    _dateFormatter.doesRelativeDateFormatting = YES;
  }
  return self;
}

- (NSTableView*)tableView { return _table; }

#pragma mark UI

- (NSButton*)iconButton:(NSString*)symbol tip:(NSString*)tip action:(SEL)action
{
  NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
                                   target:self action:action];
  b.bezelStyle = NSBezelStyleTexturedRounded;
  b.toolTip = tip;
  return b;
}

- (void)loadView
{
  NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 400)];

  _paneTitleIcon = [NSImageView imageViewWithImage:
                 [NSImage imageWithSystemSymbolName:_symbolName accessibilityDescription:nil]];
  _paneTitleIcon.contentTintColor = [NSColor controlAccentColor];
  _paneTitleLabel = [NSTextField labelWithString:_paneTitle];
  _paneTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  _paneTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  [_paneTitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];

  _backButton = [self iconButton:@"chevron.left" tip:@"Back" action:@selector(goBack:)];
  NSButton* up = [self iconButton:@"arrow.up" tip:@"Enclosing Folder" action:@selector(goUp:)];
  NSButton* home = [self iconButton:@"house" tip:@"Home Folder" action:@selector(goHome:)];
  NSButton* goTo = [self iconButton:@"arrow.right.circle" tip:@"Go to Folder…" action:@selector(goToFolder:)];
  NSButton* refresh = [self iconButton:@"arrow.clockwise" tip:@"Refresh" action:@selector(refresh:)];
  NSButton* newFolder = [self iconButton:@"folder.badge.plus" tip:@"New Folder" action:@selector(newFolder:)];
  _hiddenButton = [self iconButton:@"eye.slash" tip:@"Show Hidden Files" action:@selector(toggleHidden:)];
  _hiddenButton.buttonType = NSButtonTypePushOnPushOff;

  NSView* spacer = [[NSView alloc] init];
  [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView* header = [NSStackView stackViewWithViews:@[_paneTitleIcon, _paneTitleLabel, spacer, _backButton, up,
                                                          home, goTo, refresh, _hiddenButton, newFolder]];
  header.spacing = 4;
  header.translatesAutoresizingMaskIntoConstraints = NO;

  _pathControl = [[NSPathControl alloc] init];
  _pathControl.pathStyle = NSPathStyleStandard;
  _pathControl.target = self;
  _pathControl.action = @selector(pathClicked:);
  _pathControl.translatesAutoresizingMaskIntoConstraints = NO;

  _table = [[NSTableView alloc] init];
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.allowsMultipleSelection = YES;
  _table.dataSource = self;
  _table.delegate = self;
  _table.target = self;
  _table.doubleAction = @selector(openSelected:);
  _table.rowHeight = 22;
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
  [_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
  [_table registerForDraggedTypes:@[NSPasteboardTypeFileURL, ZVRemotePathPasteboardType]];

  NSTableColumn* c1 = [[NSTableColumn alloc] initWithIdentifier:kColName];
  c1.title = @"Name";
  c1.width = 220;
  NSTableColumn* c2 = [[NSTableColumn alloc] initWithIdentifier:kColSize];
  c2.title = @"Size";
  c2.width = 70;
  NSTableColumn* c3 = [[NSTableColumn alloc] initWithIdentifier:kColDate];
  c3.title = @"Modified";
  c3.width = 140;
  // Click a header to sort, click again to reverse; folders stay on top
  c1.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
  c2.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"size" ascending:NO];
  c3.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"modified" ascending:NO];
  [_table addTableColumn:c1];
  [_table addTableColumn:c2];
  [_table addTableColumn:c3];
  _table.sortDescriptors = @[c1.sortDescriptorPrototype];

  NSMenu* menu = [[NSMenu alloc] init];
  [menu addItemWithTitle:@"Open" action:@selector(openSelected:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Transfer to Other Side" action:@selector(transferSelected:) keyEquivalent:@""];
  [self addContextMenuItems:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Rename…" action:@selector(renameSelected:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Copy Path" action:@selector(copyPath:) keyEquivalent:@""];
  [menu addItemWithTitle:@"New Folder…" action:@selector(newFolder:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:[[self deleteVerb] stringByAppendingString:@"…"]
                  action:@selector(deleteSelected:) keyEquivalent:@""];
  for (NSMenuItem* mi in menu.itemArray)
    if (!mi.target)
      mi.target = self;
  _table.menu = menu;

  NSScrollView* scroll = [[NSScrollView alloc] init];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;

  _footer = [NSTextField labelWithString:@""];
  _footer.font = [NSFont systemFontOfSize:11];
  _footer.textColor = [NSColor secondaryLabelColor];
  _footer.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _footer.translatesAutoresizingMaskIntoConstraints = NO;

  [v addSubview:header];
  [v addSubview:_pathControl];
  [v addSubview:scroll];
  [v addSubview:_footer];
  [NSLayoutConstraint activateConstraints:@[
    [header.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
    [header.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:10],
    [header.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-8],
    [_paneTitleIcon.widthAnchor constraintEqualToConstant:18],
    [_pathControl.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
    [_pathControl.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
    [_pathControl.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-8],
    [scroll.topAnchor constraintEqualToAnchor:_pathControl.bottomAnchor constant:6],
    [scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:_footer.topAnchor constant:-4],
    [_footer.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:10],
    [_footer.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-10],
    [_footer.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-6],
  ]];
  self.view = v;
  [self updateButtons];
}

- (void)setPaneTitle:(NSString*)title
{
  _paneTitle = [title copy];
  _paneTitleLabel.stringValue = _paneTitle;
}

- (void)setSymbolName:(NSString*)symbolName
{
  _symbolName = [symbolName copy];
  _paneTitleIcon.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
}

- (void)setStatus:(NSString*)text
{
  _footer.stringValue = text ?: @"";
}

- (void)updateButtons
{
  _backButton.enabled = _history.count > 0;
  _hiddenButton.state = _showHidden ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark Subclass hooks (defaults)

- (NSString*)homePath { return nil; }
- (void)listPath:(NSString*)path completion:(void (^)(NSArray<ZVRemoteFile*>*, NSError*))completion {}
- (void)createFolder:(NSString*)path completion:(void (^)(NSError*))completion {}
- (void)renameEntry:(ZVRemoteFile*)entry to:(NSString*)name completion:(void (^)(NSError*))completion {}
- (void)deleteEntries:(NSArray<ZVRemoteFile*>*)entries completion:(void (^)(NSError*))completion {}
- (NSString*)deleteVerb { return @"Delete"; }
- (BOOL)acceptsDropFrom:(id<NSDraggingInfo>)info { return NO; }
- (id<NSPasteboardWriting>)pasteboardWriterForEntry:(ZVRemoteFile*)entry { return nil; }
- (void)addContextMenuItems:(NSMenu*)menu {}

#pragma mark Navigation

- (void)navigateTo:(NSString*)path
{
  [self loadPath:path addToHistory:YES];
}

- (void)loadPath:(NSString*)path addToHistory:(BOOL)addToHistory
{
  [self setStatus:@"Loading…"];
  [self listPath:path completion:^(NSArray<ZVRemoteFile*>* entries, NSError* error) {
    if (error) {
      [self setStatus:error.localizedDescription];
      [self.delegate filePane:self showError:error];
      return;
    }
    if (addToHistory && self->_path && ![self->_path isEqualToString:path])
      [self->_history addObject:self->_path];
    self->_path = [path copy];
    self->_all = entries;
    [self applyFilter];
    [self->_table deselectAll:nil];
    [self updatePathControl];
    [self updateButtons];
    [self.delegate filePaneDidChange:self];
  }];
}

- (void)reload
{
  if (_path)
    [self loadPath:_path addToHistory:NO];
  else if ([self homePath])
    [self loadPath:[self homePath] addToHistory:NO];
}

- (NSArray<ZVRemoteFile*>*)sortedEntries:(NSArray<ZVRemoteFile*>*)entries
{
  NSSortDescriptor* sd = _table.sortDescriptors.firstObject;
  NSString* key = sd.key ?: @"name";
  BOOL ascending = sd ? sd.ascending : YES;
  return [entries sortedArrayUsingComparator:^NSComparisonResult(ZVRemoteFile* a, ZVRemoteFile* b) {
    if (a.isDirectory != b.isDirectory)
      return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
    NSComparisonResult r = NSOrderedSame;
    if ([key isEqualToString:@"size"]) {
      if (a.size != b.size)
        r = a.size < b.size ? NSOrderedAscending : NSOrderedDescending;
    } else if ([key isEqualToString:@"modified"]) {
      NSDate* da = a.modified ?: [NSDate distantPast];
      NSDate* db = b.modified ?: [NSDate distantPast];
      r = [da compare:db];
    }
    if (r == NSOrderedSame)
      r = [a.name localizedStandardCompare:b.name];
    return ascending ? r : (NSComparisonResult)-r;
  }];
}

- (void)applyFilter
{
  // Keep the selection when the order changes
  NSArray<ZVRemoteFile*>* selected = [_entries objectsAtIndexes:_table.selectedRowIndexes];
  NSArray<ZVRemoteFile*>* visible = _showHidden ? _all
      : [_all filteredArrayUsingPredicate:
           [NSPredicate predicateWithFormat:@"NOT (name BEGINSWITH '.')"]];
  _entries = [self sortedEntries:visible];
  [_table reloadData];
  NSMutableIndexSet* rows = [NSMutableIndexSet indexSet];
  for (ZVRemoteFile* f in selected) {
    NSUInteger i = [_entries indexOfObjectIdenticalTo:f];
    if (i != NSNotFound)
      [rows addIndex:i];
  }
  [_table selectRowIndexes:rows byExtendingSelection:NO];
  NSUInteger dirs = [[_entries filteredArrayUsingPredicate:
                        [NSPredicate predicateWithFormat:@"isDirectory == YES"]] count];
  [self setStatus:[NSString stringWithFormat:@"%lu folders, %lu files",
                   (unsigned long)dirs, (unsigned long)(_entries.count - dirs)]];
}

- (void)updatePathControl
{
  _pathControl.URL = [NSURL fileURLWithPath:_path isDirectory:YES];
  for (NSPathControlItem* item in _pathControl.pathItems)
    item.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
}

- (void)pathClicked:(id)sender
{
  NSPathControlItem* item = _pathControl.clickedPathItem;
  if (item.URL)
    [self navigateTo:item.URL.path];
}

- (IBAction)goBack:(id)sender
{
  if (_history.count == 0)
    return;
  NSString* p = _history.lastObject;
  [_history removeLastObject];
  [self loadPath:p addToHistory:NO];
}

- (IBAction)goUp:(id)sender
{
  if (_path && ![_path isEqualToString:@"/"])
    [self navigateTo:[_path stringByDeletingLastPathComponent]];
}

- (IBAction)goHome:(id)sender
{
  if ([self homePath])
    [self navigateTo:[self homePath]];
}

- (IBAction)refresh:(id)sender
{
  [self reload];
}

- (IBAction)toggleHidden:(id)sender
{
  _showHidden = !_showHidden;
  [_table deselectAll:nil];
  [self applyFilter];
  [self updateButtons];
}

- (IBAction)goToFolder:(id)sender
{
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = @"Go to Folder";
  a.informativeText = @"Enter a path (~ is the home folder).";
  NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  f.stringValue = _path ?: @"";
  a.accessoryView = f;
  [a addButtonWithTitle:@"Go"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = f;
  [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
    NSString* p = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (r != NSAlertFirstButtonReturn || p.length == 0)
      return;
    NSString* home = [self homePath] ?: @"/";
    if ([p isEqualToString:@"~"])
      p = home;
    else if ([p hasPrefix:@"~/"])
      p = [home stringByAppendingPathComponent:[p substringFromIndex:2]];
    else if (![p hasPrefix:@"/"])
      p = [(self->_path ?: home) stringByAppendingPathComponent:p];
    [self navigateTo:p];
  }];
}

- (NSArray<ZVRemoteFile*>*)selectedEntries
{
  NSIndexSet* rows = _table.selectedRowIndexes;
  NSInteger clicked = _table.clickedRow;
  if (clicked >= 0 && ![rows containsIndex:clicked])
    rows = [NSIndexSet indexSetWithIndex:clicked];
  return [_entries objectsAtIndexes:rows];
}

- (ZVRemoteFile*)entryForPath:(NSString*)path
{
  for (ZVRemoteFile* f in _all)
    if ([f.path isEqualToString:path])
      return f;
  return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
  [self.delegate filePaneDidChange:self];
}

- (IBAction)openSelected:(id)sender
{
  NSArray<ZVRemoteFile*>* sel = [self selectedEntries];
  if (sel.count == 1 && sel.firstObject.isDirectory) {
    [self navigateTo:sel.firstObject.path];
    return;
  }
  if (sel.count > 0)
    [self.delegate filePaneRequestsTransfer:self];
}

- (IBAction)transferSelected:(id)sender
{
  if ([self selectedEntries].count)
    [self.delegate filePaneRequestsTransfer:self];
}

#pragma mark File operations

- (IBAction)newFolder:(id)sender
{
  if (!_path)
    return;
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = @"New Folder";
  NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  f.stringValue = @"untitled folder";
  a.accessoryView = f;
  [a addButtonWithTitle:@"Create"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = f;
  [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
    NSString* name = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (r != NSAlertFirstButtonReturn || name.length == 0)
      return;
    [self createFolder:[self->_path stringByAppendingPathComponent:name] completion:^(NSError* error) {
      if (error)
        [self.delegate filePane:self showError:error];
      [self reload];
    }];
  }];
}

- (IBAction)renameSelected:(id)sender
{
  NSArray* sel = [self selectedEntries];
  if (sel.count != 1)
    return;
  ZVRemoteFile* entry = sel.firstObject;
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = [NSString stringWithFormat:@"Rename “%@”", entry.name];
  NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  f.stringValue = entry.name;
  a.accessoryView = f;
  [a addButtonWithTitle:@"Rename"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = f;
  [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
    NSString* name = f.stringValue;
    if (r != NSAlertFirstButtonReturn || name.length == 0 || [name isEqualToString:entry.name])
      return;
    [self renameEntry:entry to:name completion:^(NSError* error) {
      if (error)
        [self.delegate filePane:self showError:error];
      [self reload];
    }];
  }];
}

- (IBAction)deleteSelected:(id)sender
{
  NSArray<ZVRemoteFile*>* sel = [self selectedEntries];
  if (sel.count == 0)
    return;
  NSAlert* a = [[NSAlert alloc] init];
  NSString* verb = [self deleteVerb];
  a.messageText = sel.count == 1
    ? [NSString stringWithFormat:@"%@ “%@”?", verb, sel.firstObject.name]
    : [NSString stringWithFormat:@"%@ %lu items?", verb, (unsigned long)sel.count];
  a.informativeText = [verb isEqualToString:@"Delete"]
    ? @"The items are deleted on the remote device immediately, folders with their contents. This can't be undone."
    : @"The items are moved to the Trash.";
  [a addButtonWithTitle:verb];
  [a addButtonWithTitle:@"Cancel"];
  a.buttons.firstObject.hasDestructiveAction = YES;
  [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn)
      return;
    [self setStatus:@"Deleting…"];
    [self deleteEntries:sel completion:^(NSError* error) {
      if (error)
        [self.delegate filePane:self showError:error];
      [self reload];
    }];
  }];
}

- (IBAction)copyPath:(id)sender
{
  NSArray* sel = [self selectedEntries];
  NSString* text = sel.count ? [[sel valueForKey:@"path"] componentsJoinedByString:@"\n"] : _path;
  if (!text)
    return;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
  SEL a = item.action;
  NSUInteger n = [self selectedEntries].count;
  if (a == @selector(renameSelected:))
    return n == 1;
  if (a == @selector(openSelected:) || a == @selector(transferSelected:) ||
      a == @selector(deleteSelected:))
    return n > 0;
  return _path != nil;
}

- (void)keyDown:(NSEvent*)event
{
  if (event.keyCode == 51 || event.keyCode == 117) {   // delete
    [self deleteSelected:nil];
    return;
  }
  if (event.keyCode == 36) {                           // return
    [self openSelected:nil];
    return;
  }
  [super keyDown:event];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
  return _entries.count;
}

- (void)tableView:(NSTableView*)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor*>*)oldDescriptors
{
  [self applyFilter];
  NSInteger row = _table.selectedRow;
  if (row >= 0)
    [_table scrollRowToVisible:row];
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
  ZVRemoteFile* f = _entries[row];
  NSTableCellView* cell = [tableView makeViewWithIdentifier:col.identifier owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] init];
    cell.identifier = col.identifier;
    NSTextField* t = [NSTextField labelWithString:@""];
    t.lineBreakMode = NSLineBreakByTruncatingMiddle;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:t];
    cell.textField = t;
    if ([col.identifier isEqualToString:kColName]) {
      NSImageView* iv = [[NSImageView alloc] init];
      iv.translatesAutoresizingMaskIntoConstraints = NO;
      [cell addSubview:iv];
      cell.imageView = iv;
      [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
        [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:16],
        [iv.heightAnchor constraintEqualToConstant:16],
        [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
      ]];
    } else {
      [t.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2].active = YES;
      t.textColor = [NSColor secondaryLabelColor];
    }
    [NSLayoutConstraint activateConstraints:@[
      [t.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
      [t.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
  }

  if ([col.identifier isEqualToString:kColName]) {
    cell.textField.stringValue = f.name;
    UTType* type = f.isDirectory ? UTTypeFolder
                                 : ([UTType typeWithFilenameExtension:f.name.pathExtension] ?: UTTypeData);
    cell.imageView.image = [[NSWorkspace sharedWorkspace] iconForContentType:type];
  } else if ([col.identifier isEqualToString:kColSize]) {
    cell.textField.stringValue = f.isDirectory ? @"—" : [_sizeFormatter stringFromByteCount:f.size];
  } else {
    cell.textField.stringValue = f.modified ? [_dateFormatter stringFromDate:f.modified] : @"";
  }
  return cell;
}

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row
{
  return [self pasteboardWriterForEntry:_entries[row]];
}

- (NSDragOperation)tableView:(NSTableView*)tableView validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{
  if (!_path || ![self acceptsDropFrom:info])
    return NSDragOperationNone;
  if (op == NSTableViewDropOn && !(row < (NSInteger)_entries.count && _entries[row].isDirectory))
    [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
  return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView*)tableView acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
  NSString* dir = _path;
  if (op == NSTableViewDropOn && row >= 0 && row < (NSInteger)_entries.count && _entries[row].isDirectory)
    dir = _entries[row].path;
  [self.delegate filePane:self acceptDrop:info intoDirectory:dir];
  return YES;
}

@end

#pragma mark - This Mac

@implementation ZVLocalFilePane

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.paneTitle = @"This Mac";
    self.symbolName = @"laptopcomputer";
  }
  return self;
}

- (NSString*)homePath
{
  return NSHomeDirectory();
}

- (void)listPath:(NSString*)path completion:(void (^)(NSArray<ZVRemoteFile*>*, NSError*))completion
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* error = nil;
    NSArray<NSURL*>* urls = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
                              includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey,
                                                           NSURLContentModificationDateKey,
                                                           NSURLIsSymbolicLinkKey, NSURLIsPackageKey]
                                                 options:0 error:&error];
    NSMutableArray* entries = [NSMutableArray array];
    for (NSURL* u in urls) {
      NSDictionary* v = [u resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey,
                                                   NSURLContentModificationDateKey,
                                                   NSURLIsSymbolicLinkKey] error:nil];
      ZVRemoteFile* e = [[ZVRemoteFile alloc] init];
      e.name = u.lastPathComponent;
      e.path = u.path;
      e.isDirectory = [v[NSURLIsDirectoryKey] boolValue];
      e.isSymlink = [v[NSURLIsSymbolicLinkKey] boolValue];
      if (e.isSymlink) {
        BOOL dir = NO;
        [fm fileExistsAtPath:u.path isDirectory:&dir];
        e.isDirectory = dir;
      }
      e.size = [v[NSURLFileSizeKey] unsignedLongLongValue];
      e.modified = v[NSURLContentModificationDateKey];
      [entries addObject:e];
    }
    [entries sortUsingComparator:^NSComparisonResult(ZVRemoteFile* a, ZVRemoteFile* b) {
      if (a.isDirectory != b.isDirectory)
        return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
      return [a.name localizedStandardCompare:b.name];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(error ? nil : entries, error);
    });
  });
}

- (void)createFolder:(NSString*)path completion:(void (^)(NSError*))completion
{
  NSError* error = nil;
  [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO
                                             attributes:nil error:&error];
  completion(error);
}

- (void)renameEntry:(ZVRemoteFile*)entry to:(NSString*)name completion:(void (^)(NSError*))completion
{
  NSError* error = nil;
  NSString* target = [[entry.path stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
  [[NSFileManager defaultManager] moveItemAtPath:entry.path toPath:target error:&error];
  completion(error);
}

- (NSString*)deleteVerb
{
  return @"Move to Trash";
}

- (void)deleteEntries:(NSArray<ZVRemoteFile*>*)entries completion:(void (^)(NSError*))completion
{
  NSMutableArray* urls = [NSMutableArray array];
  for (ZVRemoteFile* e in entries)
    [urls addObject:[NSURL fileURLWithPath:e.path]];
  [[NSWorkspace sharedWorkspace] recycleURLs:urls completionHandler:^(NSDictionary* newURLs, NSError* error) {
    completion(error);
  }];
}

- (BOOL)acceptsDropFrom:(id<NSDraggingInfo>)info
{
  // Only remote files are dropped here (downloads)
  return [info.draggingPasteboard.types containsObject:ZVRemotePathPasteboardType];
}

- (id<NSPasteboardWriting>)pasteboardWriterForEntry:(ZVRemoteFile*)entry
{
  return [NSURL fileURLWithPath:entry.path];
}

- (void)addContextMenuItems:(NSMenu*)menu
{
  NSMenuItem* reveal = [menu addItemWithTitle:@"Show in Finder" action:@selector(revealInFinder:)
                                keyEquivalent:@""];
  reveal.target = self;
}

- (IBAction)revealInFinder:(id)sender
{
  NSMutableArray* urls = [NSMutableArray array];
  for (ZVRemoteFile* e in [self selectedEntries])
    [urls addObject:[NSURL fileURLWithPath:e.path]];
  if (urls.count == 0 && self.path)
    [urls addObject:[NSURL fileURLWithPath:self.path]];
  [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
  if (item.action == @selector(revealInFinder:))
    return YES;
  return [super validateMenuItem:item];
}

@end

#pragma mark - Remote device

@implementation ZVRemoteFilePane

- (instancetype)initWithClient:(ZVSFTPClient*)client
{
  self = [super init];
  if (self) {
    _client = client;
    self.paneTitle = client.host;
    self.symbolName = @"server.rack";
  }
  return self;
}

- (NSString*)homePath
{
  return _client.homeDirectory;
}

- (void)listPath:(NSString*)path completion:(void (^)(NSArray<ZVRemoteFile*>*, NSError*))completion
{
  [_client listDirectory:path completion:completion];
}

- (void)createFolder:(NSString*)path completion:(void (^)(NSError*))completion
{
  [_client createDirectory:path completion:completion];
}

- (void)renameEntry:(ZVRemoteFile*)entry to:(NSString*)name completion:(void (^)(NSError*))completion
{
  [_client renameFile:entry to:name completion:completion];
}

- (void)deleteEntries:(NSArray<ZVRemoteFile*>*)entries completion:(void (^)(NSError*))completion
{
  [_client removeFiles:entries completion:completion];
}

- (BOOL)acceptsDropFrom:(id<NSDraggingInfo>)info
{
  // Local files (from the other pane or Finder) are uploaded
  if ([info.draggingPasteboard.types containsObject:ZVRemotePathPasteboardType])
    return NO;
  return [info.draggingPasteboard canReadObjectForClasses:@[[NSURL class]]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
}

- (id<NSPasteboardWriting>)pasteboardWriterForEntry:(ZVRemoteFile*)entry
{
  NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
  [item setString:entry.path forType:ZVRemotePathPasteboardType];
  return item;
}

@end
