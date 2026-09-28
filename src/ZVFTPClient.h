// Zeon Remote - FTP and FTPS client for the file transfer window (NAS boxes,
// web hosting, cameras and other devices without SSH). Built on
// ZVFtpConnection; network work happens on a private serial queue.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

#import "ZVFileClient.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVFTPClient;

typedef NS_ENUM(NSInteger, ZVFTPSecurity) {
  ZVFTPPlain = 0,         // not encrypted
  ZVFTPExplicitTLS,       // FTPS: AUTH TLS on the normal port (usually 21)
  ZVFTPImplicitTLS,       // FTPS with TLS from the start (usually 990)
};

@protocol ZVFTPClientDelegate <NSObject>
// Main thread; the server's TLS certificate ("x509:<sha256>"), before the
// password is sent. Return YES to trust it.
- (BOOL)ftpClient:(ZVFTPClient*)client trustCertificate:(NSString*)identity
          subject:(NSString*)subject;
@optional
// Main thread; a password saved for this server, tried before asking
- (nullable NSString*)ftpClientSavedPassword:(ZVFTPClient*)client;
@required
// Main thread; asked when there is no password or it was rejected
- (BOOL)ftpClient:(ZVFTPClient*)client
    wantsPasswordForUser:(NSString* _Nullable * _Nonnull)user
                password:(NSString* _Nullable * _Nonnull)password
                remember:(BOOL*)remember
                  failed:(BOOL)previousFailed;
@end

@interface ZVFTPClient : NSObject <ZVFileClient>

- (instancetype)initWithHost:(NSString*)host port:(int)port security:(ZVFTPSecurity)security;

@property (nonatomic, weak) id<ZVFTPClientDelegate> delegate;
// Empty: asked when connecting ("anonymous" logs in without a password)
@property (nonatomic, copy, nullable) NSString* username;
// Tried (once) before the saved password and before asking
@property (nonatomic, copy, nullable) NSString* offeredPassword;

@property (nonatomic, readonly) ZVFTPSecurity security;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) int port;

@end

NS_ASSUME_NONNULL_END
