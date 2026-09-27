// ZeonVNC - Metal view showing the remote framebuffer and forwarding
// local input to the session.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

#import "ZVBookmark.h"

NS_ASSUME_NONNULL_BEGIN

@class ZVSession;
@class ZVRemoteView;

@protocol ZVRemoteViewDelegate <NSObject>
- (void)remoteViewDidChangeZoom:(ZVRemoteView*)view;
// Files dragged from Finder onto the remote screen
- (void)remoteView:(ZVRemoteView*)view didReceiveFileURLs:(NSArray<NSURL*>*)urls;
@end

@interface ZVRemoteView : MTKView

@property (nonatomic, weak, nullable) ZVSession* session;
@property (nonatomic, weak, nullable) id<ZVRemoteViewDelegate> viewDelegate;

@property (nonatomic) ZVScaleMode scaleMode;
@property (nonatomic) CGFloat zoom;   // for ZVScale100: 1.0 = 100%
@property (nonatomic) ZVCommandKeyMode commandKeyMode;
@property (nonatomic) ZVKeyboardMode keyboardMode;
@property (nonatomic) BOOL showDotForInvisibleCursor;
@property (nonatomic) BOOL smoothScaling;

- (void)setSurface:(nullable IOSurfaceRef)surface;
- (void)framebufferUpdated;
- (void)setRemoteCursor:(nullable NSImage*)image hotspot:(NSPoint)hotspot;

// Keyboard events routed here by ZVApplication while the view has focus
- (void)handleKeyEvent:(NSEvent*)event;
- (void)releaseKeys;

// Size (in points) that shows the framebuffer unscaled
- (NSSize)naturalContentSize;
// Current remote pixels per point
- (CGFloat)effectiveScale;

- (nullable NSImage*)snapshotImage;

@end

NS_ASSUME_NONNULL_END
