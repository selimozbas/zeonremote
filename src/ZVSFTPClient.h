// Zeon Remote - SFTP client (libssh2) used for file transfer to devices that
// offer SSH, such as a Raspberry Pi. All network work happens on a
// private serial queue; completion blocks are called on the main thread.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

#import "ZVFileClient.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVSFTPClient;


@protocol ZVSFTPClientDelegate <NSObject>
// Main thread; return YES to trust. "fingerprint" is "ssh:<sha256 hex>",
// display is OpenSSH style ("SHA256:base64").
- (BOOL)sftpClient:(ZVSFTPClient*)client trustHostKey:(NSString*)fingerprint
           display:(NSString*)display;
@optional
// Main thread; called after the host key was accepted and before logging
// in, so a password saved for this device can be offered
- (nullable NSString*)sftpClientSavedPassword:(ZVSFTPClient*)client;
@required
// Main thread; asked when agent, key files and the offered password fail
- (BOOL)sftpClient:(ZVSFTPClient*)client
    wantsPasswordForUser:(NSString* _Nullable * _Nonnull)user
                password:(NSString* _Nullable * _Nonnull)password
                remember:(BOOL*)remember
                  failed:(BOOL)previousFailed;
@end

@interface ZVSFTPClient : NSObject <ZVFileClient>

- (instancetype)initWithHost:(NSString*)host port:(int)port;

@property (nonatomic, weak) id<ZVSFTPClientDelegate> delegate;
@property (nonatomic, copy, nullable) NSString* username;
// Tried (once) before asking; e.g. the credentials used for VNC
@property (nonatomic, copy, nullable) NSString* offeredPassword;

@property (nonatomic, readonly) BOOL isConnected;
// Set before connecting; NO for shell-only connections
@property (nonatomic) BOOL wantsSFTP;
// Known once connected: "mac:.." (local network only) and "ssh:<sha256>"
@property (nonatomic, readonly, copy, nullable) NSString* deviceMAC;
@property (nonatomic, readonly, copy, nullable) NSString* hostKeyFingerprint;
@property (nonatomic, readonly, copy) NSString* host;
@property (nonatomic, readonly, copy, nullable) NSString* homeDirectory;
// Password that worked and should be saved (set when the user asked)
@property (nonatomic, readonly, copy, nullable) NSString* passwordToRemember;
// Password that logged in (memory only), e.g. to open SFTP alongside a shell
@property (nonatomic, readonly, copy, nullable) NSString* usedPassword;

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

// Interactive shell with a pseudo terminal. Uses the client's queue for
// as long as the shell runs, so use a separate client for SFTP.
// "output" and "closed" are called on the main thread.
- (void)openShellWithTerminal:(NSString*)term
                      columns:(int)columns rows:(int)rows
                       output:(void (^)(NSData* data))output
                       closed:(void (^)(NSError* _Nullable error))closed;
- (void)writeShell:(NSData*)data;
- (void)resizeShellColumns:(int)columns rows:(int)rows;
- (void)closeShell;

@end

NS_ASSUME_NONNULL_END
