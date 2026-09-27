// ZeonVNC - one side of the file transfer window: a folder browser for
// either this Mac or the remote device (SFTP)
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

#import "ZVSFTPClient.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVFilePane;

// Pasteboard type for remote files dragged out of the remote pane
extern NSPasteboardType const ZVRemotePathPasteboardType;

@protocol ZVFilePaneDelegate <NSObject>
// Items dropped from the other pane (or Finder) into "directory"
- (void)filePane:(ZVFilePane*)pane acceptDrop:(id<NSDraggingInfo>)info
     intoDirectory:(NSString*)directory;
// Double-click on a file / "Transfer" command: copy to the other side
- (void)filePaneRequestsTransfer:(ZVFilePane*)pane;
- (void)filePane:(ZVFilePane*)pane showError:(NSError*)error;
- (void)filePaneDidChange:(ZVFilePane*)pane;
@end

@interface ZVFilePane : NSViewController <NSTableViewDataSource, NSTableViewDelegate,
                                          NSMenuItemValidation>

@property (nonatomic, weak, nullable) id<ZVFilePaneDelegate> delegate;
@property (nonatomic, copy) NSString* paneTitle;
@property (nonatomic, copy) NSString* symbolName;
@property (nonatomic, readonly, copy, nullable) NSString* path;
@property (nonatomic, readonly) NSTableView* tableView;
@property (nonatomic) BOOL showHidden;

- (void)navigateTo:(NSString*)path;
- (void)reload;
- (NSArray<ZVRemoteFile*>*)selectedEntries;
- (nullable ZVRemoteFile*)entryForPath:(NSString*)path;
- (void)setStatus:(NSString*)text;

// Subclass responsibilities
- (nullable NSString*)homePath;
- (void)listPath:(NSString*)path
      completion:(void (^)(NSArray<ZVRemoteFile*>* _Nullable entries, NSError* _Nullable error))completion;
- (void)createFolder:(NSString*)path completion:(void (^)(NSError* _Nullable error))completion;
- (void)renameEntry:(ZVRemoteFile*)entry to:(NSString*)name
         completion:(void (^)(NSError* _Nullable error))completion;
- (void)deleteEntries:(NSArray<ZVRemoteFile*>*)entries
           completion:(void (^)(NSError* _Nullable error))completion;
- (NSString*)deleteVerb;         // "Delete" or "Move to Trash"
- (BOOL)acceptsDropFrom:(id<NSDraggingInfo>)info;
- (nullable id<NSPasteboardWriting>)pasteboardWriterForEntry:(ZVRemoteFile*)entry;
- (void)addContextMenuItems:(NSMenu*)menu;

@end

// This Mac
@interface ZVLocalFilePane : ZVFilePane
@end

// The remote device over SFTP
@interface ZVRemoteFilePane : ZVFilePane
- (instancetype)initWithClient:(ZVSFTPClient*)client;
@property (nonatomic, readonly) ZVSFTPClient* client;
@end

NS_ASSUME_NONNULL_END
