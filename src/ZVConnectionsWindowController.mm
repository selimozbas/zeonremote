// ZeonVNC - connection manager (address book + quick connect)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <initializer_list>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "ZVConnectionsWindowController.h"
#import "ZVBookmark.h"
#import "ZVPreferences.h"

static NSUserInterfaceItemIdentifier const kCellID = @"ZVBookmarkCell";

// Scroll view content that starts at the top
@interface ZVFlippedView : NSView
@end
@implementation ZVFlippedView
- (BOOL)isFlipped { return YES; }
@end

#pragma mark - List cell

@interface ZVBookmarkCell : NSTableCellView
@property (nonatomic, strong) NSTextField* titleField;
@property (nonatomic, strong) NSTextField* subtitleField;
@end

@implementation ZVBookmarkCell

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    NSImageView* icon = [NSImageView imageViewWithImage:
                           [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18
                                                                               weight:NSFontWeightRegular];
    icon.contentTintColor = [NSColor controlAccentColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    _titleField = [NSTextField labelWithString:@""];
    _titleField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitleField = [NSTextField labelWithString:@""];
    _subtitleField.font = [NSFont systemFontOfSize:11];
    _subtitleField.textColor = [NSColor secondaryLabelColor];
    _subtitleField.lineBreakMode = NSLineBreakByTruncatingTail;

    NSStackView* text = [NSStackView stackViewWithViews:@[_titleField, _subtitleField]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 1;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:icon];
    [self addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
      [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
      [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [icon.widthAnchor constraintEqualToConstant:26],
      [text.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
      [text.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6],
      [text.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    self.textField = _titleField;
    self.imageView = icon;
  }
  return self;
}

@end

#pragma mark - Sidebar items

typedef NS_ENUM(NSInteger, ZVSidebarKind) {
  ZVSidebarHeader,
  ZVSidebarBookmark,
  ZVSidebarRecent,
};

@interface ZVSidebarItem : NSObject
@property (nonatomic) ZVSidebarKind kind;
@property (nonatomic, copy) NSString* title;
@property (nonatomic, strong) ZVBookmark* bookmark;   // bookmark rows
@property (nonatomic, copy) NSString* host;           // recent rows
@property (nonatomic, strong) NSDate* date;           // recent rows
@property (nonatomic) ZVProtocol protocolType;        // recent rows
@end

@implementation ZVSidebarItem
@end

static NSUserInterfaceItemIdentifier const kHeaderID = @"ZVHeaderCell";

#pragma mark - Window controller

@interface ZVConnectionsWindowController () <NSTableViewDataSource, NSTableViewDelegate,
                                             NSTextFieldDelegate, NSSearchFieldDelegate,
                                             NSComboBoxDelegate, NSMenuItemValidation>
@end

@implementation ZVConnectionsWindowController {
  NSArray<ZVSidebarItem*>* _rows;
  NSString* _selectedRecentHost;
  ZVBookmark* _editing;
  BOOL _loadingForm;
  BOOL _reloading;

  NSComboBox* _quickField;
  NSSearchField* _search;
  NSTableView* _table;
  NSView* _detail;
  NSView* _emptyView;

  // Form
  NSTextField* _name;
  NSTextField* _host;
  NSTextField* _user;
  NSSecureTextField* _password;
  NSTextField* _group;
  NSPopUpButton* _quality;
  NSPopUpButton* _encoding;
  NSSlider* _jpeg;
  NSTextField* _jpegLabel;
  NSSlider* _compress;
  NSTextField* _compressLabel;
  NSPopUpButton* _colors;
  NSPopUpButton* _scale;
  NSPopUpButton* _cmdKey;
  NSPopUpButton* _kbdMode;
  NSButton* _viewOnly;
  NSButton* _shared;
  NSButton* _fullScreen;
  NSButton* _reconnect;
  NSButton* _clipboard;
  NSButton* _remoteResize;
  NSButton* _dotCursor;
  NSButton* _alwaysAsk;
  NSTextField* _sshUser;
  NSTextField* _sshPort;
  NSPopUpButton* _type;
  NSTextField* _port;
  NSGridView* _grid;
  NSGridView* _grid2;
  NSGridView* _customGrid;
}

- (instancetype)init
{
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                                      NSWindowStyleMaskFullSizeContentView
                                              backing:NSBackingStoreBuffered defer:NO];
  self = [super initWithWindow:w];
  if (self) {
    w.title = @"ZeonVNC";
    w.subtitle = @"Connections";
    w.minSize = NSMakeSize(760, 520);
    w.releasedWhenClosed = NO;
    w.titlebarAppearsTransparent = YES;
    w.frameAutosaveName = @"ZVConnectionsWindow";
    w.autorecalculatesKeyViewLoop = YES;
    [w center];
    [self buildUI];
    [self reload];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storeChanged:)
                                                 name:ZVBookmarksDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesChanged:)
                                                 name:ZVPreferencesChangedNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark UI construction

- (NSTextField*)label:(NSString*)s
{
  NSTextField* f = [NSTextField labelWithString:s];
  f.alignment = NSTextAlignmentRight;
  f.textColor = [NSColor secondaryLabelColor];
  return f;
}

- (NSTextField*)field:(NSString*)placeholder
{
  NSTextField* f = [[NSTextField alloc] init];
  f.placeholderString = placeholder;
  f.delegate = self;
  [f.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
  return f;
}

- (NSPopUpButton*)popup:(NSArray<NSString*>*)titles
{
  NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [p addItemsWithTitles:titles];
  for (NSInteger i = 0; i < p.numberOfItems; i++)
    [p itemAtIndex:i].tag = i;
  p.target = self;
  p.action = @selector(formChanged:);
  return p;
}

- (NSButton*)check:(NSString*)title
{
  NSButton* b = [NSButton checkboxWithTitle:title target:self action:@selector(formChanged:)];
  return b;
}

- (NSView*)sectionHeader:(NSString*)title
{
  NSTextField* f = [NSTextField labelWithString:title];
  f.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  return f;
}

- (void)buildUI
{
  NSView* content = self.window.contentView;

  // --- Sidebar ---
  NSVisualEffectView* sidebar = [[NSVisualEffectView alloc] init];
  sidebar.material = NSVisualEffectMaterialSidebar;
  sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  sidebar.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:sidebar];

  _search = [[NSSearchField alloc] init];
  _search.placeholderString = @"Search";
  _search.delegate = self;
  _search.translatesAutoresizingMaskIntoConstraints = NO;
  [sidebar addSubview:_search];

  _table = [[NSTableView alloc] init];
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
  [_table addTableColumn:col];
  _table.headerView = nil;
  _table.style = NSTableViewStyleSourceList;
  _table.rowHeight = 44;
  _table.floatsGroupRows = NO;
  _table.dataSource = self;
  _table.delegate = self;
  _table.target = self;
  _table.doubleAction = @selector(connectSelected:);
  _table.backgroundColor = [NSColor clearColor];
  _table.allowsEmptySelection = YES;

  NSMenu* ctx = [[NSMenu alloc] init];
  [ctx addItemWithTitle:@"Connect" action:@selector(connectSelected:) keyEquivalent:@""];
  [ctx addItemWithTitle:@"Save to Address Book" action:@selector(saveRecentToAddressBook:) keyEquivalent:@""];
  [ctx addItemWithTitle:@"Duplicate" action:@selector(duplicateBookmark:) keyEquivalent:@""];
  [ctx addItem:[NSMenuItem separatorItem]];
  [ctx addItemWithTitle:@"Delete" action:@selector(deleteBookmark:) keyEquivalent:@""];
  [ctx addItemWithTitle:@"Clear Recent Connections" action:@selector(clearRecent:) keyEquivalent:@""];
  for (NSMenuItem* mi in ctx.itemArray)
    mi.target = self;
  _table.menu = ctx;

  NSScrollView* scroll = [[NSScrollView alloc] init];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.drawsBackground = NO;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [sidebar addSubview:scroll];

  NSButton* add = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add"]
                                     target:self action:@selector(newBookmark:)];
  add.bordered = NO;
  add.toolTip = @"New connection";
  NSButton* del = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"Remove"]
                                     target:self action:@selector(deleteBookmark:)];
  del.bordered = NO;
  del.toolTip = @"Delete connection";
  NSStackView* sidebarButtons = [NSStackView stackViewWithViews:@[add, del]];
  sidebarButtons.spacing = 4;
  sidebarButtons.translatesAutoresizingMaskIntoConstraints = NO;
  [sidebar addSubview:sidebarButtons];

  // --- Main area ---
  NSView* main = [[NSView alloc] init];
  main.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:main];

  // Quick connect bar
  NSTextField* qcLabel = [NSTextField labelWithString:@"Quick Connect"];
  qcLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightBold];
  _quickField = [[NSComboBox alloc] init];
  _quickField.placeholderString = @"host or host::port · ssh user@host · telnet host";
  _quickField.completes = YES;
  _quickField.delegate = self;
  _quickField.target = self;
  _quickField.action = @selector(quickConnect:);
  _quickField.font = [NSFont systemFontOfSize:14];
  [_quickField.widthAnchor constraintGreaterThanOrEqualToConstant:400].active = YES;
  NSButton* qcButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(quickConnect:)];
  qcButton.bezelStyle = NSBezelStyleRounded;
  qcButton.controlSize = NSControlSizeLarge;
  NSStackView* qcRow = [NSStackView stackViewWithViews:@[_quickField, qcButton]];
  qcRow.spacing = 8;
  NSStackView* qc = [NSStackView stackViewWithViews:@[qcLabel, qcRow]];
  qc.orientation = NSUserInterfaceLayoutOrientationVertical;
  qc.alignment = NSLayoutAttributeLeading;
  qc.spacing = 8;
  qc.translatesAutoresizingMaskIntoConstraints = NO;
  [main addSubview:qc];

  NSBox* sep = [[NSBox alloc] init];
  sep.boxType = NSBoxSeparator;
  sep.translatesAutoresizingMaskIntoConstraints = NO;
  [main addSubview:sep];

  _detail = [self buildDetailForm];
  _detail.translatesAutoresizingMaskIntoConstraints = NO;
  NSScrollView* detailScroll = [[NSScrollView alloc] init];
  detailScroll.drawsBackground = NO;
  detailScroll.hasVerticalScroller = YES;
  detailScroll.autohidesScrollers = YES;
  detailScroll.translatesAutoresizingMaskIntoConstraints = NO;
  NSClipView* clip = [[NSClipView alloc] init];
  clip.drawsBackground = NO;
  detailScroll.contentView = clip;
  NSView* doc = [[ZVFlippedView alloc] init];
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:_detail];
  detailScroll.documentView = doc;
  [main addSubview:detailScroll];

  _emptyView = [NSTextField wrappingLabelWithString:
                  @"Select a saved connection, or press + to add one.\n\n"
                  @"Tip: type an address above and press Return to connect right away."];
  ((NSTextField*)_emptyView).alignment = NSTextAlignmentCenter;
  ((NSTextField*)_emptyView).textColor = [NSColor secondaryLabelColor];
  _emptyView.translatesAutoresizingMaskIntoConstraints = NO;
  [main addSubview:_emptyView];

  [NSLayoutConstraint activateConstraints:@[
    [sidebar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [sidebar.topAnchor constraintEqualToAnchor:content.topAnchor],
    [sidebar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [sidebar.widthAnchor constraintEqualToConstant:260],

    [_search.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:40],
    [_search.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:12],
    [_search.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-12],
    [scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:8],
    [scroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:sidebarButtons.topAnchor constant:-6],
    [sidebarButtons.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:10],
    [sidebarButtons.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-8],

    [main.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [main.topAnchor constraintEqualToAnchor:content.topAnchor],
    [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],

    [qc.topAnchor constraintEqualToAnchor:main.topAnchor constant:44],
    [qc.leadingAnchor constraintEqualToAnchor:main.leadingAnchor constant:28],
    [qc.trailingAnchor constraintLessThanOrEqualToAnchor:main.trailingAnchor constant:-28],
    [sep.topAnchor constraintEqualToAnchor:qc.bottomAnchor constant:18],
    [sep.leadingAnchor constraintEqualToAnchor:main.leadingAnchor constant:20],
    [sep.trailingAnchor constraintEqualToAnchor:main.trailingAnchor constant:-20],

    [detailScroll.topAnchor constraintEqualToAnchor:sep.bottomAnchor constant:4],
    [detailScroll.leadingAnchor constraintEqualToAnchor:main.leadingAnchor],
    [detailScroll.trailingAnchor constraintEqualToAnchor:main.trailingAnchor],
    [detailScroll.bottomAnchor constraintEqualToAnchor:main.bottomAnchor],
    [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [_detail.topAnchor constraintEqualToAnchor:doc.topAnchor constant:16],
    [_detail.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:28],
    [_detail.trailingAnchor constraintLessThanOrEqualToAnchor:doc.trailingAnchor constant:-28],
    [_detail.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-20],

    [_emptyView.centerXAnchor constraintEqualToAnchor:detailScroll.centerXAnchor],
    [_emptyView.centerYAnchor constraintEqualToAnchor:detailScroll.centerYAnchor],
    [_emptyView.widthAnchor constraintLessThanOrEqualToConstant:360],
  ]];

  [self.window setInitialFirstResponder:_quickField];
}

- (NSView*)buildDetailForm
{
  _name = [self field:@"My computer"];
  _host = [self field:@"192.168.1.10, server:1 or server::5900"];
  _user = [self field:@"Only needed for some servers"];
  _password = [[NSSecureTextField alloc] init];
  _password.placeholderString = @"Optional, saved in the Keychain";
  _password.delegate = self;
  _group = [self field:@"Optional"];
  _alwaysAsk = [self check:@"Always ask for the password"];
  _type = [self popup:@[@"VNC (remote desktop)", @"SSH (terminal)", @"Telnet (terminal)"]];
  _port = [[NSTextField alloc] init];
  _port.delegate = self;
  [_port.widthAnchor constraintEqualToConstant:70].active = YES;
  _sshUser = [self field:@"Same as the VNC user"];
  _sshPort = [[NSTextField alloc] init];
  _sshPort.placeholderString = @"22";
  _sshPort.delegate = self;
  [_sshPort.widthAnchor constraintEqualToConstant:70].active = YES;

  _quality = [self popup:@[@"Automatic (adapts to bandwidth)", @"Lossless (LAN)", @"High",
                           @"Balanced", @"Low bandwidth", @"Custom",
                           @"Smooth video (H.264)"]];
  _encoding = [self popup:@[@"Tight", @"ZRLE", @"Hextile", @"Raw", @"H.264"]];
  _jpeg = [NSSlider sliderWithValue:8 minValue:-1 maxValue:9 target:self action:@selector(formChanged:)];
  _jpeg.numberOfTickMarks = 11;
  _jpeg.allowsTickMarkValuesOnly = YES;
  _jpegLabel = [NSTextField labelWithString:@""];
  _compress = [NSSlider sliderWithValue:2 minValue:0 maxValue:9 target:self action:@selector(formChanged:)];
  _compress.numberOfTickMarks = 10;
  _compress.allowsTickMarkValuesOnly = YES;
  _compressLabel = [NSTextField labelWithString:@""];
  _colors = [self popup:@[@"Full color", @"256 colors", @"64 colors", @"8 colors"]];

  _scale = [self popup:@[@"Fit to window", @"Actual size (100%)", @"Pixel perfect (1:1 Retina)",
                         @"Stretch to window"]];
  _cmdKey = [self popup:@[@"Windows key", @"Ctrl (⌘C → Ctrl+C)", @"Alt"]];
  _kbdMode = [self popup:@[@"Server layout (raw key codes)", @"Mac layout (symbols)"]];

  _viewOnly = [self check:@"View only (no keyboard / mouse)"];
  _shared = [self check:@"Shared session (don't disconnect other viewers)"];
  _fullScreen = [self check:@"Start in full screen"];
  _reconnect = [self check:@"Reconnect automatically"];
  _clipboard = [self check:@"Share clipboard"];
  _remoteResize = [self check:@"Resize remote screen to window"];
  _dotCursor = [self check:@"Show dot when remote cursor is hidden"];

  NSButton* connect = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connectSelected:)];
  connect.bezelStyle = NSBezelStyleRounded;
  connect.keyEquivalent = @"";
  connect.controlSize = NSControlSizeLarge;
  connect.hasDestructiveAction = NO;
  if (@available(macOS 11.0, *))
    connect.bezelColor = [NSColor controlAccentColor];

  NSGridView* grid = [NSGridView gridViewWithViews:@[
    @[[self sectionHeader:@"Connection"], [NSGridCell emptyContentView]],
    @[[self label:@"Type"], _type],
    @[[self label:@"Name"], _name],
    @[[self label:@"Address"], _host],
    @[[self label:@"Port"], _port],
    @[[self label:@"User name"], _user],
    @[[self label:@"Password"], _password],
    @[[NSGridCell emptyContentView], _alwaysAsk],
    @[[self label:@"Group"], _group],
    @[[self sectionHeader:@"Display & Quality"], [NSGridCell emptyContentView]],
    @[[self label:@"Quality"], _quality],
  ]];
  grid.rowSpacing = 8;
  grid.columnSpacing = 10;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [grid columnAtIndex:0].width = 110;
  _grid = grid;
  for (NSInteger r : {0, 9}) {
    [grid rowAtIndex:r].topPadding = r ? 14 : 0;
    [[grid cellAtColumnIndex:0 rowIndex:r] setXPlacement:NSGridCellPlacementLeading];
    [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(r, 1)];
  }

  NSStackView* jpegRow = [NSStackView stackViewWithViews:@[_jpeg, _jpegLabel]];
  [_jpeg.widthAnchor constraintEqualToConstant:180].active = YES;
  NSStackView* compRow = [NSStackView stackViewWithViews:@[_compress, _compressLabel]];
  [_compress.widthAnchor constraintEqualToConstant:180].active = YES;

  _customGrid = [NSGridView gridViewWithViews:@[
    @[[self label:@"Encoding"], _encoding],
    @[[self label:@"JPEG quality"], jpegRow],
    @[[self label:@"Compression"], compRow],
    @[[self label:@"Colors"], _colors],
  ]];
  _customGrid.rowSpacing = 8;
  _customGrid.columnSpacing = 10;
  [_customGrid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [_customGrid columnAtIndex:0].width = 110;

  NSGridView* grid2 = [NSGridView gridViewWithViews:@[
    @[[self label:@"Scaling"], _scale],
    @[[self sectionHeader:@"Keyboard"], [NSGridCell emptyContentView]],
    @[[self label:@"⌘ Command key"], _cmdKey],
    @[[self label:@"Layout"], _kbdMode],
    @[[self sectionHeader:@"File Transfer (SSH)"], [NSGridCell emptyContentView]],
    @[[self label:@"SSH user"], _sshUser],
    @[[self label:@"SSH port"], _sshPort],
    @[[self sectionHeader:@"Options"], [NSGridCell emptyContentView]],
    @[[NSGridCell emptyContentView], _viewOnly],
    @[[NSGridCell emptyContentView], _shared],
    @[[NSGridCell emptyContentView], _clipboard],
    @[[NSGridCell emptyContentView], _reconnect],
    @[[NSGridCell emptyContentView], _fullScreen],
    @[[NSGridCell emptyContentView], _remoteResize],
    @[[NSGridCell emptyContentView], _dotCursor],
  ]];
  _grid2 = grid2;
  grid2.rowSpacing = 8;
  grid2.columnSpacing = 10;
  [grid2 columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [grid2 columnAtIndex:0].width = 110;
  for (NSInteger r : {1, 4, 7}) {
    [grid2 rowAtIndex:r].topPadding = 14;
    [[grid2 cellAtColumnIndex:0 rowIndex:r] setXPlacement:NSGridCellPlacementLeading];
    [grid2 mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(r, 1)];
  }

  NSStackView* buttons = [NSStackView stackViewWithViews:@[connect]];

  NSStackView* stack = [NSStackView stackViewWithViews:@[grid, _customGrid, grid2, buttons]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  [stack setCustomSpacing:20 afterView:grid2];
  return stack;
}

#pragma mark Data

- (BOOL)savingEnabled
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:ZVPrefRememberPasswords];
}

- (void)updatePasswordControls
{
  BOOL saving = [self savingEnabled];
  _password.enabled = saving;
  _alwaysAsk.enabled = saving;
  _password.placeholderString = saving ? @"Optional, saved in the Keychain"
                                       : @"Asked on every connection (see Settings)";
  if (!saving)
    _password.stringValue = @"";
}

- (void)preferencesChanged:(NSNotification*)n
{
  [self updatePasswordControls];
}

- (void)storeChanged:(NSNotification*)n
{
  [self reload];
}

- (ZVSidebarItem*)itemAtRow:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)_rows.count)
    return nil;
  return _rows[row];
}

- (ZVSidebarItem*)targetItem
{
  NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
  return [self itemAtRow:row];
}

- (void)reload
{
  NSString* q = _search.stringValue;
  ZVBookmarkStore* store = [ZVBookmarkStore sharedStore];
  NSMutableArray<ZVSidebarItem*>* rows = [NSMutableArray array];

  NSArray* books = store.bookmarks;
  if (q.length) {
    books = [books filteredArrayUsingPredicate:
             [NSPredicate predicateWithBlock:^BOOL(ZVBookmark* b, NSDictionary* bindings) {
      return [b.name localizedCaseInsensitiveContainsString:q] ||
             [b.host localizedCaseInsensitiveContainsString:q] ||
             [b.group localizedCaseInsensitiveContainsString:q];
    }]];
  }
  ZVSidebarItem* h1 = [[ZVSidebarItem alloc] init];
  h1.kind = ZVSidebarHeader;
  h1.title = @"Address Book";
  [rows addObject:h1];
  for (ZVBookmark* b in books) {
    ZVSidebarItem* it = [[ZVSidebarItem alloc] init];
    it.kind = ZVSidebarBookmark;
    it.bookmark = b;
    [rows addObject:it];
  }

  NSMutableArray* recents = [NSMutableArray array];
  for (NSDictionary* r in store.recentEntries) {
    NSString* host = r[@"host"];
    ZVBookmark* quick = [ZVBookmark bookmarkFromQuickConnect:host];
    ZVBookmark* match = [store bookmarkMatching:quick];
    if (q.length && ![host localizedCaseInsensitiveContainsString:q] &&
        ![match.name localizedCaseInsensitiveContainsString:q])
      continue;
    ZVSidebarItem* it = [[ZVSidebarItem alloc] init];
    it.kind = ZVSidebarRecent;
    it.host = host;
    it.date = r[@"date"];
    it.title = match.name.length ? match.name : host;
    it.protocolType = quick.protocolType;
    [recents addObject:it];
  }
  if (recents.count) {
    ZVSidebarItem* h2 = [[ZVSidebarItem alloc] init];
    h2.kind = ZVSidebarHeader;
    h2.title = @"Recent";
    [rows addObject:h2];
    [rows addObjectsFromArray:recents];
  }
  _rows = rows;

  NSString* selectedUUID = _editing.uuid;
  _reloading = YES;
  [_table reloadData];

  NSInteger idx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)_rows.count; i++) {
    ZVSidebarItem* it = _rows[i];
    if (selectedUUID && it.kind == ZVSidebarBookmark &&
        [it.bookmark.uuid isEqualToString:selectedUUID])
      idx = i;
    else if (!selectedUUID && _selectedRecentHost && it.kind == ZVSidebarRecent &&
             [it.host isEqualToString:_selectedRecentHost])
      idx = i;
  }
  if (idx != NSNotFound)
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
  else
    [_table deselectAll:nil];
  _reloading = NO;
  // The edited connection may have been filtered out or deleted
  if (idx == NSNotFound && selectedUUID && ![store bookmarkWithUUID:selectedUUID])
    _editing = nil;
  if (idx == NSNotFound)
    _selectedRecentHost = nil;

  [_quickField removeAllItems];
  [_quickField addItemsWithObjectValues:store.recentHosts];

  [self updateDetailVisibility];
}

- (void)updateDetailVisibility
{
  BOOL has = _editing != nil;
  _detail.hidden = !has;
  _emptyView.hidden = has;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
  return _rows.count;
}

- (NSString*)relativeDate:(NSDate*)date
{
  if (!date || [date isEqualToDate:[NSDate distantPast]])
    return nil;
  if (date.timeIntervalSinceNow > -60)
    return @"just now";
  NSRelativeDateTimeFormatter* f = [[NSRelativeDateTimeFormatter alloc] init];
  f.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
  return [f localizedStringForDate:date relativeToDate:[NSDate date]];
}

- (NSString*)symbolForProtocol:(ZVProtocol)p
{
  switch (p) {
  case ZVProtocolSSH:    return @"terminal";
  case ZVProtocolTelnet: return @"network";
  default:               return @"display";
  }
}

- (BOOL)tableView:(NSTableView*)tableView isGroupRow:(NSInteger)row
{
  return [self itemAtRow:row].kind == ZVSidebarHeader;
}

- (CGFloat)tableView:(NSTableView*)tableView heightOfRow:(NSInteger)row
{
  return [self itemAtRow:row].kind == ZVSidebarHeader ? 28 : 44;
}

- (BOOL)tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row
{
  return [self itemAtRow:row].kind != ZVSidebarHeader;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
{
  ZVSidebarItem* it = [self itemAtRow:row];

  if (it.kind == ZVSidebarHeader) {
    NSTableCellView* hv = [tableView makeViewWithIdentifier:kHeaderID owner:self];
    if (!hv) {
      hv = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 240, 28)];
      hv.identifier = kHeaderID;
      NSTextField* t = [NSTextField labelWithString:@""];
      t.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
      t.textColor = [NSColor secondaryLabelColor];
      t.translatesAutoresizingMaskIntoConstraints = NO;
      [hv addSubview:t];
      [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:4],
        [t.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-4],
      ]];
      hv.textField = t;
    }
    hv.textField.stringValue = it.title;
    return hv;
  }

  ZVBookmarkCell* cell = [tableView makeViewWithIdentifier:kCellID owner:self];
  if (!cell) {
    cell = [[ZVBookmarkCell alloc] initWithFrame:NSMakeRect(0, 0, 240, 44)];
    cell.identifier = kCellID;
  }

  if (it.kind == ZVSidebarBookmark) {
    ZVBookmark* b = it.bookmark;
    cell.titleField.stringValue = [b displayName];
    NSString* sub = b.host;
    if (b.group.length)
      sub = [NSString stringWithFormat:@"%@ · %@", b.group, b.host];
    if (b.protocolType != ZVProtocolVNC)
      sub = [NSString stringWithFormat:@"%@ · %@", b.protocolType == ZVProtocolSSH ? @"SSH" : @"Telnet", sub];
    cell.subtitleField.stringValue = sub;
    cell.imageView.image = [NSImage imageWithSystemSymbolName:[self symbolForProtocol:b.protocolType]
                                     accessibilityDescription:nil];
  } else {
    cell.titleField.stringValue = it.title;
    NSString* when = [self relativeDate:it.date];
    NSString* sub = it.host;
    if (![it.title isEqualToString:it.host])
      sub = it.host;
    else
      sub = nil;
    if (when)
      sub = sub ? [NSString stringWithFormat:@"%@ · %@", sub, when] : when;
    cell.subtitleField.stringValue = sub ?: @"";
    cell.imageView.image = [NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath"
                                     accessibilityDescription:nil];
  }
  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification
{
  if (_reloading)
    return;
  ZVSidebarItem* it = [self itemAtRow:_table.selectedRow];
  if (it.kind == ZVSidebarBookmark) {
    _selectedRecentHost = nil;
    if (![_editing.uuid isEqualToString:it.bookmark.uuid]) {
      [self commitForm];
      _editing = [it.bookmark copy];
      [self loadForm];
    }
  } else {
    [self commitForm];
    _editing = nil;
    _selectedRecentHost = it.kind == ZVSidebarRecent ? it.host : nil;
    if (_selectedRecentHost)
      _quickField.stringValue = _selectedRecentHost;
  }
  [self updateDetailVisibility];
}

- (void)controlTextDidChange:(NSNotification*)n
{
  if (n.object == _search) {
    [self reload];
    return;
  }
}

- (void)controlTextDidEndEditing:(NSNotification*)n
{
  if (n.object == _search || n.object == _quickField)
    return;
  [self formChanged:n.object];
}

#pragma mark Form

- (void)loadForm
{
  if (!_editing)
    return;
  _loadingForm = YES;
  [_type selectItemWithTag:_editing.protocolType];
  if (_editing.protocolType == ZVProtocolSSH)
    _port.stringValue = [NSString stringWithFormat:@"%ld", (long)(_editing.sshPort ?: 22)];
  else if (_editing.protocolType == ZVProtocolTelnet)
    _port.stringValue = [NSString stringWithFormat:@"%ld", (long)(_editing.telnetPort ?: 23)];
  _name.stringValue = _editing.name;
  _host.stringValue = _editing.host;
  _user.stringValue = _editing.username;
  _password.stringValue = [self savingEnabled] ? ([_editing storedPassword] ?: @"") : @"";
  [self updatePasswordControls];
  _group.stringValue = _editing.group;
  [_quality selectItemWithTag:_editing.quality];
  [_encoding selectItemWithTag:_editing.encoding];
  _jpeg.integerValue = _editing.jpegQuality;
  _compress.integerValue = MAX(0, _editing.compressLevel);
  [_colors selectItemWithTag:_editing.colorDepth];
  [_scale selectItemWithTag:_editing.scaleMode];
  [_cmdKey selectItemWithTag:_editing.commandKeyMode];
  [_kbdMode selectItemWithTag:_editing.keyboardMode];
  _viewOnly.state = _editing.viewOnly;
  _shared.state = _editing.shared;
  _fullScreen.state = _editing.fullScreen;
  _reconnect.state = _editing.autoReconnect;
  _clipboard.state = _editing.shareClipboard;
  _remoteResize.state = _editing.remoteResize;
  _dotCursor.state = _editing.showRemoteCursor;
  _alwaysAsk.state = _editing.alwaysAskPassword;
  _sshUser.stringValue = _editing.sshUsername;
  _sshPort.stringValue = _editing.sshPort == 22 ? @"" : [NSString stringWithFormat:@"%ld", (long)_editing.sshPort];
  [self updateCustomControls];
  _loadingForm = NO;
}

- (void)updateCustomControls
{
  ZVProtocol proto = (ZVProtocol)_type.selectedTag;
  BOOL vnc = proto == ZVProtocolVNC;
  // Rows: 4 port, 5 user, 6 password, 7 always ask, 9-10 display & quality
  [_grid rowAtIndex:4].hidden = vnc;
  [_grid rowAtIndex:5].hidden = proto == ZVProtocolTelnet;
  [_grid rowAtIndex:6].hidden = proto == ZVProtocolTelnet;
  [_grid rowAtIndex:7].hidden = proto == ZVProtocolTelnet;
  [_grid rowAtIndex:9].hidden = !vnc;
  [_grid rowAtIndex:10].hidden = !vnc;
  _grid2.hidden = !vnc;
  _host.placeholderString = vnc ? @"192.168.1.10, server:1 or server::5900" : @"192.168.1.10 or host name";
  _port.placeholderString = proto == ZVProtocolSSH ? @"22" : @"23";
  _customGrid.hidden = !vnc || _quality.selectedTag != ZVQualityCustom;
  NSInteger q = _jpeg.integerValue;
  _jpegLabel.stringValue = q < 0 ? @"Lossless" : [NSString stringWithFormat:@"%ld", (long)q];
  _compressLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)_compress.integerValue];
}

- (IBAction)formChanged:(id)sender
{
  if (_loadingForm || !_editing)
    return;
  [self updateCustomControls];
  [self commitForm];
}

- (void)commitForm
{
  if (!_editing || _loadingForm)
    return;

  ZVBookmark* b = _editing;
  NSString* oldName = b.name;
  NSString* oldHost = b.host;
  NSString* oldGroup = b.group;

  ZVProtocol oldType = b.protocolType;
  b.protocolType = (ZVProtocol)_type.selectedTag;
  if (b.protocolType == oldType) {
    NSInteger port = _port.integerValue;
    if (b.protocolType == ZVProtocolSSH)
      b.sshPort = (port > 0 && port < 65536) ? port : 22;
    else if (b.protocolType == ZVProtocolTelnet)
      b.telnetPort = (port > 0 && port < 65536) ? port : 23;
  }
  b.name = _name.stringValue;
  b.host = [_host.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  b.username = _user.stringValue;
  b.group = _group.stringValue;
  b.quality = (ZVQualityPreset)_quality.selectedTag;
  b.encoding = (ZVEncoding)_encoding.selectedTag;
  b.jpegQuality = _jpeg.integerValue;
  b.compressLevel = _compress.integerValue;
  b.colorDepth = (ZVColorDepth)_colors.selectedTag;
  b.scaleMode = (ZVScaleMode)_scale.selectedTag;
  b.commandKeyMode = (ZVCommandKeyMode)_cmdKey.selectedTag;
  b.keyboardMode = (ZVKeyboardMode)_kbdMode.selectedTag;
  b.viewOnly = _viewOnly.state == NSControlStateValueOn;
  b.shared = _shared.state == NSControlStateValueOn;
  b.fullScreen = _fullScreen.state == NSControlStateValueOn;
  b.autoReconnect = _reconnect.state == NSControlStateValueOn;
  b.shareClipboard = _clipboard.state == NSControlStateValueOn;
  b.remoteResize = _remoteResize.state == NSControlStateValueOn;
  b.showRemoteCursor = _dotCursor.state == NSControlStateValueOn;
  b.alwaysAskPassword = _alwaysAsk.state == NSControlStateValueOn;
  b.sshUsername = [_sshUser.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSInteger sshPort = _sshPort.integerValue;
  b.sshPort = (sshPort > 0 && sshPort < 65536) ? sshPort : 22;

  if ([self savingEnabled]) {
    NSString* pw = _password.stringValue;
    if (![pw isEqualToString:[b storedPassword] ?: @""])
      [b setStoredPassword:pw.length ? pw : nil];
  }

  BOOL listChanged = ![oldName isEqualToString:b.name] || ![oldHost isEqualToString:b.host] ||
                     ![oldGroup isEqualToString:b.group] || oldType != b.protocolType;
  if (listChanged) {
    [[ZVBookmarkStore sharedStore] updateBookmark:b];   // triggers reload
  } else {
    // Avoid a full reload (and losing focus) for option changes
    [[NSNotificationCenter defaultCenter] removeObserver:self name:ZVBookmarksDidChangeNotification object:nil];
    [[ZVBookmarkStore sharedStore] updateBookmark:b];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storeChanged:)
                                                 name:ZVBookmarksDidChangeNotification object:nil];
  }
}

#pragma mark Actions

- (void)focusQuickConnect
{
  [self.window makeFirstResponder:_quickField];
}

- (IBAction)quickConnect:(id)sender
{
  NSString* host = [_quickField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (host.length == 0) {
    NSBeep();
    return;
  }
  // Use saved settings when the address matches a bookmark
  ZVBookmark* quick = [ZVBookmark bookmarkFromQuickConnect:host];
  ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkMatching:quick];
  if (!b && quick.protocolType != ZVProtocolVNC)
    b = quick;
  if (!b) {
    b = quick;
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"ZVDefaultCommandKey"])
      b.commandKeyMode = (ZVCommandKeyMode)[d integerForKey:@"ZVDefaultCommandKey"];
    if ([d objectForKey:@"ZVDefaultQuality"])
      b.quality = (ZVQualityPreset)[d integerForKey:@"ZVDefaultQuality"];
    if ([d objectForKey:@"ZVDefaultScale"])
      b.scaleMode = (ZVScaleMode)[d integerForKey:@"ZVDefaultScale"];
  }
  [self.delegate openSessionForBookmark:b];
}

- (IBAction)connectSelected:(id)sender
{
  [self commitForm];
  NSInteger row = sender == _table ? _table.clickedRow : _table.selectedRow;
  if (row < 0)
    row = _table.selectedRow;
  ZVSidebarItem* it = [self itemAtRow:row];
  if (it.kind == ZVSidebarRecent) {
    _quickField.stringValue = it.host;
    [self quickConnect:nil];
    return;
  }
  if (it.kind != ZVSidebarBookmark) {
    NSBeep();
    return;
  }
  ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:it.bookmark.uuid];
  if (b.host.length == 0) {
    NSBeep();
    [self.window makeFirstResponder:_host];
    return;
  }
  [self.delegate openSessionForBookmark:b];
}

- (IBAction)newBookmark:(id)sender
{
  [self commitForm];
  ZVBookmark* b = [[ZVBookmark alloc] init];
  b.name = @"New Connection";
  NSString* q = [_quickField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (q.length)
    b.host = q;
  [[ZVBookmarkStore sharedStore] addBookmark:b];
  _search.stringValue = @"";
  _editing = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:b.uuid];
  [self reload];
  [self loadForm];
  [self.window makeFirstResponder:_name];
  [_name selectText:nil];
}

- (IBAction)duplicateBookmark:(id)sender
{
  ZVSidebarItem* it = [self targetItem];
  if (it.kind != ZVSidebarBookmark)
    return;
  [self commitForm];
  ZVBookmark* b = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:it.bookmark.uuid];
  NSString* pw = [b storedPassword];
  b.uuid = [NSUUID UUID].UUIDString;
  b.name = [b.name stringByAppendingString:@" copy"];
  b.lastConnected = nil;
  [[ZVBookmarkStore sharedStore] addBookmark:b];
  if (pw)
    [b setStoredPassword:pw];
  _editing = [b copy];
  [self reload];
  [self loadForm];
}

- (IBAction)deleteBookmark:(id)sender
{
  ZVSidebarItem* it = [self targetItem];
  if (it.kind == ZVSidebarRecent) {
    // Recent entries are just history; no confirmation needed
    [[ZVBookmarkStore sharedStore] removeRecentHost:it.host];
    return;
  }
  if (it.kind != ZVSidebarBookmark)
    return;
  ZVBookmark* b = it.bookmark;
  NSAlert* a = [[NSAlert alloc] init];
  a.messageText = [NSString stringWithFormat:@"Delete “%@”?", [b displayName]];
  a.informativeText = @"The saved password is removed from the Keychain as well.";
  [a addButtonWithTitle:@"Delete"];
  [a addButtonWithTitle:@"Cancel"];
  a.buttons.firstObject.hasDestructiveAction = YES;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn)
      return;
    if ([self->_editing.uuid isEqualToString:b.uuid])
      self->_editing = nil;
    [[ZVBookmarkStore sharedStore] removeBookmark:b];
  }];
}

- (IBAction)importBookmarks:(id)sender
{
  NSOpenPanel* p = [NSOpenPanel openPanel];
  p.allowedContentTypes = @[UTTypeJSON, [UTType typeWithFilenameExtension:@"vnc"] ?: UTTypeData];
  p.allowsMultipleSelection = YES;
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK)
      return;
    for (NSURL* url in p.URLs) {
      NSError* err = nil;
      if (![[ZVBookmarkStore sharedStore] importFromURL:url error:&err]) {
        [[NSAlert alertWithError:err] runModal];
        break;
      }
    }
  }];
}

- (IBAction)exportBookmarks:(id)sender
{
  NSSavePanel* p = [NSSavePanel savePanel];
  p.allowedContentTypes = @[UTTypeJSON];
  p.nameFieldStringValue = @"ZeonVNC Connections.json";
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK)
      return;
    NSError* err = nil;
    if (![[ZVBookmarkStore sharedStore] exportToURL:p.URL error:&err])
      [[NSAlert alertWithError:err] runModal];
  }];
}

- (IBAction)saveRecentToAddressBook:(id)sender
{
  ZVSidebarItem* it = [self targetItem];
  if (it.kind != ZVSidebarRecent)
    return;
  [self commitForm];
  ZVBookmark* quick = [ZVBookmark bookmarkFromQuickConnect:it.host];
  ZVBookmark* existing = [[ZVBookmarkStore sharedStore] bookmarkMatching:quick];
  if (existing) {
    _editing = existing;
  } else {
    ZVBookmark* b = [[ZVBookmark alloc] initWithDictionary:[quick dictionaryRepresentation]];
    b.uuid = [NSUUID UUID].UUIDString;
    b.name = quick.host;
    // Carry over a password remembered for the quick connection
    NSString* pw = [quick storedPassword];
    NSString* ident = [[ZVBookmarkStore sharedStore] identityForScope:[quick credentialScope]];
    [[ZVBookmarkStore sharedStore] addBookmark:b];
    if (pw)
      [b setStoredPassword:pw];
    if (ident)
      [[ZVBookmarkStore sharedStore] setIdentity:ident forScope:[b credentialScope]];
    _editing = [[ZVBookmarkStore sharedStore] bookmarkWithUUID:b.uuid];
  }
  _selectedRecentHost = nil;
  _search.stringValue = @"";
  [self reload];
  [self loadForm];
  [self.window makeFirstResponder:_name];
  [_name selectText:nil];
}

- (IBAction)clearRecent:(id)sender
{
  _selectedRecentHost = nil;
  [[ZVBookmarkStore sharedStore] clearRecent];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
  SEL a = item.action;
  ZVSidebarItem* it = [self targetItem];
  if (a == @selector(deleteBookmark:) && item.menu == _table.menu)
    item.title = it.kind == ZVSidebarRecent ? @"Remove from Recent" : @"Delete";
  if (a == @selector(connectSelected:) || a == @selector(deleteBookmark:))
    return it.kind == ZVSidebarBookmark || it.kind == ZVSidebarRecent;
  if (a == @selector(duplicateBookmark:)) {
    item.hidden = it.kind != ZVSidebarBookmark;
    return it.kind == ZVSidebarBookmark;
  }
  if (a == @selector(saveRecentToAddressBook:)) {
    item.hidden = it.kind != ZVSidebarRecent;
    return it.kind == ZVSidebarRecent;
  }
  if (a == @selector(clearRecent:)) {
    item.hidden = it.kind != ZVSidebarRecent;
    return [ZVBookmarkStore sharedStore].recentEntries.count > 0;
  }
  return YES;
}

- (void)keyDown:(NSEvent*)event
{
  // Delete removes the selected connection when the list has focus
  if (self.window.firstResponder == _table &&
      (event.keyCode == 51 || event.keyCode == 117)) {
    [self deleteBookmark:nil];
    return;
  }
  [super keyDown:event];
}

@end
