// Zeon Remote - saved connection ("bookmark") model and store
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZVProtocol) {
  ZVProtocolVNC = 0,
  ZVProtocolSSH,
  ZVProtocolTelnet,
  ZVProtocolRDP,
  ZVProtocolSFTP,         // file transfer only (port: sshPort)
  ZVProtocolFTP,          // FTP / FTPS file transfer
};

typedef NS_ENUM(NSInteger, ZVQualityPreset) {
  ZVQualityAuto = 0,      // Adapt to measured bandwidth
  ZVQualityLossless,      // LAN, no JPEG
  ZVQualityHigh,          // JPEG q8
  ZVQualityBalanced,      // JPEG q6, more compression
  ZVQualityLow,           // Slow links
  ZVQualityCustom,
  ZVQualityVideo,         // H.264, smooth motion (e.g. Raspberry Pi hardware encoder)
};

typedef NS_ENUM(NSInteger, ZVEncoding) {
  ZVEncodingTight = 0,
  ZVEncodingZRLE,
  ZVEncodingHextile,
  ZVEncodingRaw,
  ZVEncodingH264,
};

typedef NS_ENUM(NSInteger, ZVColorDepth) {
  ZVColorFull = 0,
  ZVColor256,
  ZVColor64,
  ZVColor8,
};

typedef NS_ENUM(NSInteger, ZVScaleMode) {
  ZVScaleFit = 0,         // Fit window, keep aspect ratio
  ZVScale100,             // One remote pixel per point
  ZVScaleNativePixels,    // One remote pixel per screen pixel (Retina)
  ZVScaleFill,            // Stretch to window
};

typedef NS_ENUM(NSInteger, ZVCommandKeyMode) {
  ZVCommandAsWindows = 0, // Cmd -> Super/Windows key
  ZVCommandAsControl,     // Cmd -> Ctrl (Cmd+C copies on Windows)
  ZVCommandAsAlt,
};

typedef NS_ENUM(NSInteger, ZVKeyboardMode) {
  ZVKeyboardRawKeycodes = 0, // Use the server's keyboard layout
  ZVKeyboardSymbols,         // Use the local (Mac) keyboard layout
};

@interface ZVBookmark : NSObject <NSCopying>

@property (nonatomic, copy) NSString* uuid;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* host;       // host, host:display, host::port
@property (nonatomic, copy) NSString* username;
@property (nonatomic, copy) NSString* notes;
@property (nonatomic, copy) NSString* group;
@property (nonatomic) ZVProtocol protocolType;
@property (nonatomic) NSInteger telnetPort;      // default 23
@property (nonatomic) NSInteger rdpPort;         // default 3389
@property (nonatomic) NSInteger ftpPort;         // default 21 (990 for implicit FTPS)
@property (nonatomic) NSInteger ftpSecurity;     // ZVFTPSecurity: 0 none, 1 FTPS, 2 implicit FTPS

@property (nonatomic) ZVQualityPreset quality;
@property (nonatomic) ZVEncoding encoding;        // Custom only
@property (nonatomic) NSInteger jpegQuality;      // Custom only, -1 = lossless
@property (nonatomic) NSInteger compressLevel;    // Custom only, -1 = default
@property (nonatomic) ZVColorDepth colorDepth;    // Custom only

@property (nonatomic) ZVScaleMode scaleMode;
@property (nonatomic) ZVCommandKeyMode commandKeyMode;
@property (nonatomic) ZVKeyboardMode keyboardMode;

@property (nonatomic) BOOL shared;
@property (nonatomic) BOOL viewOnly;
@property (nonatomic) BOOL remoteResize;
@property (nonatomic) BOOL fullScreen;
@property (nonatomic) BOOL autoReconnect;
@property (nonatomic) BOOL shareClipboard;
@property (nonatomic) BOOL showRemoteCursor;      // draw a dot for invisible cursors
@property (nonatomic) BOOL alwaysAskPassword;     // never use saved passwords
@property (nonatomic, copy) NSString* sshUsername; // file transfer; empty = VNC user
@property (nonatomic) NSInteger sshPort;          // file transfer, default 22

@property (nonatomic, strong, nullable) NSDate* lastConnected;
@property (nonatomic, readonly) BOOL isTransient; // quick connect, not saved

+ (instancetype)bookmarkWithHost:(NSString*)host;
// Parses quick connect input: "host", "vnc://…", "ssh://user@host:port",
// "ssh user@host", "telnet://host:port", "telnet host port",
// "rdp://user@host:port", "rdp user@host", "sftp://user@host", "sftp user@host",
// "ftp://user@host:port", "ftps://user@host" (FTPS; port 990 = implicit),
// "ftp user@host"
+ (instancetype)bookmarkFromQuickConnect:(NSString*)text;
- (instancetype)initWithDictionary:(NSDictionary*)dict;
- (NSDictionary*)dictionaryRepresentation;

- (NSString*)displayName;
// Text that recreates this connection in Quick Connect (and Recent)
- (NSString*)quickConnectString;

// Credentials are saved per "scope" (a saved connection, or an address
// for quick connections) and, once the device behind it is known, per
// device identity (MAC address or server key). See ZVSession.
- (NSString*)credentialScope;

// Keychain backed password for the scope (used until the device is known)
- (nullable NSString*)storedPassword;
- (void)setStoredPassword:(nullable NSString*)password;

@end

extern NSNotificationName const ZVBookmarksDidChangeNotification;

@interface ZVBookmarkStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly) NSArray<ZVBookmark*>* bookmarks;
@property (nonatomic, readonly) NSArray<NSString*>* recentHosts;
// Most recent first; each entry has @"host" (NSString) and @"date" (NSDate)
@property (nonatomic, readonly) NSArray<NSDictionary*>* recentEntries;
- (void)removeRecentHost:(NSString*)host;
- (void)clearRecent;

- (void)addBookmark:(ZVBookmark*)bookmark;
- (void)updateBookmark:(ZVBookmark*)bookmark;
- (void)removeBookmark:(ZVBookmark*)bookmark;
- (nullable ZVBookmark*)bookmarkWithUUID:(NSString*)uuid;
- (nullable ZVBookmark*)bookmarkMatchingHost:(NSString*)host;
// Saved connection with the same address and type as a quick connection
- (nullable ZVBookmark*)bookmarkMatching:(ZVBookmark*)quick;
- (void)noteConnectedTo:(ZVBookmark*)bookmark;

// Devices seen behind addresses. Identities look like "mac:aa:bb:..",
// "x509:<sha256>" or "rsa:<sha256>".
- (nullable NSString*)identityForScope:(NSString*)scope;
- (void)setIdentity:(NSString*)identity forScope:(NSString*)scope;
- (nullable NSDictionary*)deviceInfo:(NSString*)identity;  // name, host, username, lastSeen
- (void)noteDevice:(NSString*)identity name:(nullable NSString*)name
              host:(NSString*)host username:(nullable NSString*)username;
// A device is identified by its MAC address when on the local network,
// otherwise by its server key; keys seen together with a MAC are aliased
// to it.
- (nullable NSString*)canonicalIdentityForMAC:(nullable NSString*)mac
                                          key:(nullable NSString*)key;
- (void)setAlias:(NSString*)mac forKey:(NSString*)key;
- (NSArray<NSString*>*)keysForMAC:(NSString*)mac;
- (BOOL)isTrustedServerKey:(NSString*)fingerprint;
- (void)trustServerKey:(NSString*)fingerprint;

// Keychain helpers for per-device passwords
+ (nullable NSString*)passwordForDevice:(NSString*)identity;
+ (void)setPassword:(nullable NSString*)password forDevice:(NSString*)identity;

- (BOOL)importFromURL:(NSURL*)url error:(NSError**)error;
- (BOOL)exportToURL:(NSURL*)url error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
