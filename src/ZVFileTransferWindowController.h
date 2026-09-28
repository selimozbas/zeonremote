// Zeon Remote - file transfer window (SFTP) for a session
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>

#import "ZVFTPClient.h"
#import "ZVSFTPClient.h"

NS_ASSUME_NONNULL_BEGIN

// What the file transfer window needs from the connection it belongs to
// (a VNC session or an SSH terminal)
@protocol ZVFileTransferContext <NSObject>
// Tried first when logging in to SSH (e.g. the VNC credentials)
@property (nonatomic, readonly, copy, nullable) NSString* transferUsername;
@property (nonatomic, readonly, copy, nullable) NSString* transferPassword;
// Credential scope of the connection (see ZVBookmark)
@property (nonatomic, readonly, copy) NSString* transferScope;
@end

@interface ZVFileTransferWindowController : NSWindowController

- (instancetype)initWithContext:(id<ZVFileTransferContext>)context
                           host:(NSString*)host
                           port:(int)port
                       username:(nullable NSString*)username
                          title:(NSString*)title;

// FTP / FTPS window on its own (a saved or quick FTP connection)
- (instancetype)initWithContext:(id<ZVFileTransferContext>)context
                        ftpHost:(NSString*)host
                           port:(int)port
                       security:(ZVFTPSecurity)security
                       username:(nullable NSString*)username
                          title:(NSString*)title;

// Keeps the context alive (for windows that don't belong to a session)
@property (nonatomic, strong, nullable) id<ZVFileTransferContext> ownedContext;

@property (nonatomic, readonly) id<ZVFileClient> client;

// Uploads to the remote desktop folder (or home), used when files are
// dropped on the remote screen. Progress is reported to the caller.
- (void)uploadToRemoteDesktop:(NSArray<NSURL*>*)urls
                     progress:(void (^)(ZVTransferProgress progress))progress
                   completion:(void (^)(NSString* _Nullable destination,
                                        NSError* _Nullable error))completion;

- (void)close;

@end

NS_ASSUME_NONNULL_END
