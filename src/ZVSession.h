// Zeon Remote - one VNC session. Owns the protocol connection (which runs on
// its own thread) and exposes a main-thread Objective-C interface.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>

#import "ZVBookmark.h"
#import "ZVFileTransferWindowController.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVSession;

typedef NS_ENUM(NSInteger, ZVSessionState) {
  ZVSessionIdle = 0,
  ZVSessionConnecting,
  ZVSessionAuthenticating,
  ZVSessionConnected,
  ZVSessionDisconnected,
};

typedef NS_ENUM(NSInteger, ZVCloseReason) {
  ZVCloseByUser = 0,
  ZVCloseByServer,
  ZVCloseConnectFailed,
  ZVCloseAuthFailed,
  ZVCloseAuthCancelled,
  ZVCloseError,
};

typedef struct {
  double kbitsPerSecond;       // received, last second
  double updatesPerSecond;
  double megapixelsPerSecond;
  unsigned long long totalBytes;
  unsigned long long lineSpeedKbps; // bandwidth estimate
  int jpegQuality;             // currently requested, -1 = lossless
  int lastEncoding;            // RFB encoding number of the last update, -1 = none
} ZVSessionStats;

@protocol ZVSessionDelegate <NSObject>
- (void)session:(ZVSession*)session stateChanged:(ZVSessionState)state;
- (void)session:(ZVSession*)session framebufferChanged:(IOSurfaceRef)surface;
- (void)sessionFramebufferUpdated:(ZVSession*)session;
- (void)session:(ZVSession*)session desktopNameChanged:(NSString*)name;
- (void)session:(ZVSession*)session cursorChanged:(nullable NSImage*)image
        hotspot:(NSPoint)hotspot;
- (void)session:(ZVSession*)session remoteClipboard:(NSString*)text;
- (void)session:(ZVSession*)session closedWithReason:(ZVCloseReason)reason
        message:(nullable NSString*)message;
- (void)sessionBell:(ZVSession*)session;

// Blocking prompts. Called on the main thread while the protocol
// thread waits for the answer.
- (BOOL)session:(ZVSession*)session
    wantsCredentialsWithUsername:(BOOL)needUsername
                          secure:(BOOL)secure
                         warning:(nullable NSString*)warning
                          device:(nullable NSString*)device
                        username:(NSString* _Nullable * _Nonnull)username
                        password:(NSString* _Nullable * _Nonnull)password
                        remember:(BOOL*)remember;
- (BOOL)session:(ZVSession*)session
    showMessage:(NSString*)text title:(NSString*)title
      questions:(BOOL)yesNo style:(NSAlertStyle)style;
@end

@interface ZVSession : NSObject <ZVFileTransferContext>

- (instancetype)initWithBookmark:(ZVBookmark*)bookmark;
// A VNC or RDP session, depending on the bookmark's protocol
+ (ZVSession*)sessionWithBookmark:(ZVBookmark*)bookmark;
// Session for an incoming (reverse) connection; takes ownership of fd
- (instancetype)initWithBookmark:(ZVBookmark*)bookmark connectedSocket:(int)fd;

// Reverse connections can't be re-established from this side
@property (nonatomic, readonly) BOOL isReverseConnection;

@property (nonatomic, weak) id<ZVSessionDelegate> delegate;
@property (nonatomic, readonly) ZVBookmark* bookmark;
@property (nonatomic, readonly) ZVSessionState state;
@property (nonatomic, readonly, copy) NSString* desktopName;
@property (nonatomic, readonly) NSSize framebufferSize;
@property (nonatomic, readonly, nullable) IOSurfaceRef surface;
@property (nonatomic) BOOL viewOnly;
// Identity of the connected device ("mac:..", "x509:..", "rsa:..")
@property (nonatomic, readonly, nullable) NSString* deviceIdentity;
// Credentials that logged in to VNC in this session (memory only)
@property (nonatomic, readonly, copy, nullable) NSString* vncUsername;
@property (nonatomic, readonly, copy, nullable) NSString* vncPassword;
// The host part of the address (without display / port), for SSH
@property (nonatomic, readonly) NSString* hostName;

// Trust decision for another key of the same device (e.g. its SSH host
// key): same per-device logic and dialog as for VNC keys
- (BOOL)verifyServerKey:(NSString*)fingerprint display:(NSString*)display;

- (void)connect;
- (void)disconnect;

// Apply changed quality / encoding settings from the bookmark
- (void)applySettings:(ZVBookmark*)bookmark;

// Input (ignored in view-only mode)
- (void)sendPointer:(NSPoint)pos buttons:(uint16_t)mask;
- (void)sendKeyPress:(int)systemKeyCode keyCode:(uint32_t)keyCode keySym:(uint32_t)keySym;
- (void)sendKeyRelease:(int)systemKeyCode;
- (void)releaseAllKeys;
// Presses the keysyms in order and releases them in reverse order
- (void)sendKeyCombo:(NSArray<NSNumber*>*)keySyms;
// Types text as individual key strokes
- (void)typeText:(NSString*)text;

- (void)refreshScreen;
- (void)requestRemoteSize:(NSSize)size;
- (BOOL)supportsRemoteResize;

// Clipboard
- (void)localClipboardChanged:(nullable NSString*)text;

- (ZVSessionStats)stats;
- (NSString*)connectionInfo;
+ (NSString*)nameForEncoding:(int)encoding;
- (BOOL)isSecure;

@end

NS_ASSUME_NONNULL_END
