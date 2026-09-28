// Zeon Remote - what the file transfer window needs from a remote file
// system: SFTP (ZVSFTPClient) or FTP / FTPS (ZVFTPClient). Network work
// happens on the client's own queue; completion blocks run on the main
// thread.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZVRemoteFile : NSObject
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* path;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isSymlink;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSDate* modified;
@property (nonatomic) unsigned long permissions;
@end

typedef NS_ENUM(NSInteger, ZVConflictAction) {
  ZVConflictReplace = 0,
  ZVConflictKeepBoth,     // transfer under a new name ("name 2.ext")
  ZVConflictSkip,
  ZVConflictStop,         // cancel the whole transfer
};

// A file that already exists at the destination
@interface ZVTransferConflict : NSObject
@property (nonatomic) BOOL upload;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* destination;   // folder, for display
@property (nonatomic) unsigned long long existingSize;
@property (nonatomic, strong, nullable) NSDate* existingDate;
@property (nonatomic) BOOL existingIsDirectory;
@property (nonatomic) unsigned long long incomingSize;
@property (nonatomic, strong, nullable) NSDate* incomingDate;
@end

typedef struct {
  unsigned long long bytesDone;
  unsigned long long bytesTotal;
  NSUInteger filesDone;
  NSUInteger filesTotal;
  __unsafe_unretained NSString* _Nullable currentName;
} ZVTransferProgress;

@protocol ZVFileClient <NSObject>

@property (nonatomic, readonly, copy) NSString* host;
@property (nonatomic, readonly, copy, nullable) NSString* homeDirectory;
// Known once connected: "mac:.." (local network only) and the server's key
// ("ssh:<sha256>" or "x509:<sha256>" for FTPS; nil for plain FTP)
@property (nonatomic, readonly, copy, nullable) NSString* deviceMAC;
@property (nonatomic, readonly, copy, nullable) NSString* hostKeyFingerprint;
// Password that worked and should be saved (set when the user asked)
@property (nonatomic, readonly, copy, nullable) NSString* passwordToRemember;

// Asked (on the main thread) for every file that already exists at the
// destination. Without a handler existing files are replaced.
@property (nonatomic, copy, nullable) ZVConflictAction (^conflictHandler)(ZVTransferConflict* conflict);

- (void)connect:(void (^)(NSError* _Nullable error))completion;
- (void)disconnect;

- (void)listDirectory:(NSString*)path
           completion:(void (^)(NSArray<ZVRemoteFile*>* _Nullable files,
                                NSError* _Nullable error))completion;

// Uploads files and folders (recursively) into a remote directory.
// Existing folders are merged; existing files go through the conflict
// handler.
- (void)uploadURLs:(NSArray<NSURL*>*)urls
       toDirectory:(NSString*)directory
          progress:(nullable void (^)(ZVTransferProgress progress))progress
        completion:(void (^)(NSError* _Nullable error))completion;

// Downloads files and folders into a local directory. Existing folders
// are merged; existing files go through the conflict handler. The
// completion gets the top level local URLs.
- (void)downloadFiles:(NSArray<ZVRemoteFile*>*)files
          toDirectory:(NSURL*)directory
             progress:(nullable void (^)(ZVTransferProgress progress))progress
           completion:(void (^)(NSArray<NSURL*>* _Nullable urls,
                                NSError* _Nullable error))completion;

- (void)createDirectory:(NSString*)path completion:(void (^)(NSError* _Nullable error))completion;
- (void)removeFiles:(NSArray<ZVRemoteFile*>*)files completion:(void (^)(NSError* _Nullable error))completion;
- (void)renameFile:(ZVRemoteFile*)file to:(NSString*)newName
        completion:(void (^)(NSError* _Nullable error))completion;
- (void)directoryExists:(NSString*)path completion:(void (^)(BOOL exists))completion;

// Stops the running transfer after the current chunk
- (void)cancelTransfer;

@end

NS_ASSUME_NONNULL_END
