// Zeon Remote - Metal view showing the remote framebuffer
//
// The framebuffer is an IOSurface written directly by the decoders; the
// view wraps it in a Metal texture (no copies) and draws it scaled. For
// strong downscaling a mipmapped copy is generated on the GPU so text
// stays readable.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>

#include "Keyboard.h"
#include "KeyboardMacOS.h"

#import "ZVRemoteView.h"
#import "ZVSession.h"

#define XK_MISCELLANY
#include <rfb/keysymdef.h>

static NSString* const kShaderSource = @
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct VOut { float4 pos [[position]]; float2 uv; };\n"
  "vertex VOut vmain(uint vid [[vertex_id]], constant float4& r [[buffer(0)]]) {\n"
  "  float2 c = float2(vid & 1, vid >> 1);\n"
  "  VOut o;\n"
  "  o.pos = float4(mix(r.x, r.z, c.x), mix(r.w, r.y, c.y), 0.0, 1.0);\n"
  "  o.uv = c;\n"
  "  return o;\n"
  "}\n"
  "fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
  "                      sampler smp [[sampler(0)]]) {\n"
  "  return float4(tex.sample(smp, in.uv).rgb, 1.0);\n"
  "}\n";

// Mouse button masks (RFB)
enum {
  kButtonLeft = 1, kButtonMiddle = 2, kButtonRight = 4,
  kWheelUp = 8, kWheelDown = 16, kWheelLeft = 32, kWheelRight = 64,
  kButtonBack = 128, kButtonForward = 256,
};

@class ZVRemoteView;

class ZVKeyHandler final : public KeyboardHandler {
public:
  ZVKeyHandler(ZVRemoteView* v) : view(v) {}
  void handleKeyPress(int systemKeyCode, uint32_t keyCode, uint32_t keySym) override;
  void handleKeyRelease(int systemKeyCode) override;
private:
  __weak ZVRemoteView* view;
};

@interface ZVRemoteView ()
- (void)sendKeyPress:(int)code keyCode:(uint32_t)keyCode keySym:(uint32_t)keySym;
- (void)sendKeyRelease:(int)code;
@end

void ZVKeyHandler::handleKeyPress(int systemKeyCode, uint32_t keyCode, uint32_t keySym)
{
  [view sendKeyPress:systemKeyCode keyCode:keyCode keySym:keySym];
}

void ZVKeyHandler::handleKeyRelease(int systemKeyCode)
{
  [view sendKeyRelease:systemKeyCode];
}

@implementation ZVRemoteView {
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _pipeline;
  id<MTLSamplerState> _linearSampler;
  id<MTLSamplerState> _nearestSampler;
  id<MTLSamplerState> _mipSampler;

  IOSurfaceRef _surface;
  id<MTLTexture> _surfaceTexture;
  id<MTLTexture> _mipTexture;
  NSSize _fbSize;

  ZVKeyHandler* _keyHandler;
  KeyboardMacOS* _keyboard;

  uint16_t _buttonMask;
  CGFloat _scrollAccumX, _scrollAccumY;
  NSPoint _pan;            // offset of the content in points (fixed scale modes)
  NSTimer* _edgeTimer;
  NSPoint _lastMouse;      // view coordinates

  NSCursor* _cursor;
  NSImage* _cursorImage;
  NSPoint _cursorHotspot;
  NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame
{
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  self = [super initWithFrame:frame device:device];
  if (self) {
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0.12, 0.12, 0.13, 1.0);
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

    CAMetalLayer* ml = (CAMetalLayer*)self.layer;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ml.colorspace = srgb;
    CGColorSpaceRelease(srgb);

    _zoom = 1.0;
    _smoothScaling = YES;
    _showDotForInvisibleCursor = YES;

    [self setupMetal];

    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    _keyHandler = new ZVKeyHandler(self);
    _keyboard = new KeyboardMacOS(_keyHandler);

    [self updateCursor];
  }
  return self;
}

- (void)dealloc
{
  [_edgeTimer invalidate];
  delete _keyboard;
  delete _keyHandler;
  if (_surface)
    CFRelease(_surface);
}

- (void)setupMetal
{
  id<MTLDevice> device = self.device;
  _queue = [device newCommandQueue];

  NSError* err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource options:nil error:&err];
  if (!lib) {
    NSLog(@"Zeon Remote: shader compilation failed: %@", err);
    return;
  }

  MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
  pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
  pd.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!_pipeline)
    NSLog(@"Zeon Remote: pipeline creation failed: %@", err);

  MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  _linearSampler = [device newSamplerStateWithDescriptor:sd];

  sd.mipFilter = MTLSamplerMipFilterLinear;
  _mipSampler = [device newSamplerStateWithDescriptor:sd];

  sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
  sd.minFilter = MTLSamplerMinMagFilterNearest;
  sd.magFilter = MTLSamplerMinMagFilterNearest;
  _nearestSampler = [device newSamplerStateWithDescriptor:sd];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (BOOL)isOpaque { return YES; }

#pragma mark Framebuffer

- (void)setSurface:(IOSurfaceRef)surface
{
  if (_surface)
    CFRelease(_surface);
  _surface = surface ? (IOSurfaceRef)CFRetain(surface) : NULL;
  _surfaceTexture = nil;
  _mipTexture = nil;

  if (_surface) {
    _fbSize = NSMakeSize(IOSurfaceGetWidth(_surface), IOSurfaceGetHeight(_surface));
    MTLTextureDescriptor* td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:(NSUInteger)_fbSize.width
                                                        height:(NSUInteger)_fbSize.height
                                                     mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = self.device.hasUnifiedMemory ? MTLStorageModeShared
                                                  : MTLStorageModeManaged;
    _surfaceTexture = [self.device newTextureWithDescriptor:td iosurface:_surface plane:0];
  } else {
    _fbSize = NSZeroSize;
  }

  [self clampPan];
  [self updateCursor];
  [self setNeedsDisplay:YES];
}

- (void)framebufferUpdated
{
  [self setNeedsDisplay:YES];
}

- (void)setScaleMode:(ZVScaleMode)scaleMode
{
  _scaleMode = scaleMode;
  [self clampPan];
  [self updateCursor];
  [self setNeedsDisplay:YES];
}

- (void)setZoom:(CGFloat)zoom
{
  _zoom = MAX(0.1, MIN(zoom, 8.0));
  [self clampPan];
  [self updateCursor];
  [self setNeedsDisplay:YES];
}

- (void)setSmoothScaling:(BOOL)smooth
{
  _smoothScaling = smooth;
  [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
  [super setFrameSize:size];
  [self clampPan];
  [self updateCursor];
}

- (void)viewDidChangeBackingProperties
{
  [super viewDidChangeBackingProperties];
  [self updateCursor];
  [self setNeedsDisplay:YES];
}

- (NSSize)naturalContentSize
{
  CGFloat s = [self fixedScale];
  return NSMakeSize(_fbSize.width * s, _fbSize.height * s);
}

// Points per remote pixel for the fixed scale modes
- (CGFloat)fixedScale
{
  if (_scaleMode == ZVScaleNativePixels) {
    CGFloat bs = self.window ? self.window.backingScaleFactor : 2.0;
    return 1.0 / bs;
  }
  return _zoom;
}

- (CGFloat)effectiveScale
{
  NSRect r = [self contentRect];
  if (_fbSize.width <= 0)
    return 1.0;
  return r.size.width / _fbSize.width;
}

// Where the framebuffer is drawn, in view coordinates (y up)
- (NSRect)contentRect
{
  NSSize vs = self.bounds.size;
  if (_fbSize.width <= 0 || _fbSize.height <= 0)
    return NSZeroRect;

  switch (_scaleMode) {
  case ZVScaleFit: {
    CGFloat s = MIN(vs.width / _fbSize.width, vs.height / _fbSize.height);
    NSSize cs = NSMakeSize(floor(_fbSize.width * s), floor(_fbSize.height * s));
    return NSMakeRect(floor((vs.width - cs.width) / 2),
                      floor((vs.height - cs.height) / 2),
                      cs.width, cs.height);
  }
  case ZVScaleFill:
    return self.bounds;
  case ZVScale100:
  case ZVScaleNativePixels: {
    NSSize cs = [self naturalContentSize];
    CGFloat x, y;
    if (cs.width <= vs.width)
      x = floor((vs.width - cs.width) / 2);
    else
      x = -_pan.x;
    if (cs.height <= vs.height)
      y = floor((vs.height - cs.height) / 2);
    else
      y = vs.height - cs.height + _pan.y;   // pan.y measured from the top
    return NSMakeRect(x, y, cs.width, cs.height);
  }
  }
  return self.bounds;
}

- (void)clampPan
{
  if (_scaleMode != ZVScale100 && _scaleMode != ZVScaleNativePixels) {
    _pan = NSZeroPoint;
    return;
  }
  NSSize cs = [self naturalContentSize];
  NSSize vs = self.bounds.size;
  _pan.x = MAX(0, MIN(_pan.x, cs.width - vs.width));
  _pan.y = MAX(0, MIN(_pan.y, cs.height - vs.height));
}

- (BOOL)canPan
{
  if (_scaleMode != ZVScale100 && _scaleMode != ZVScaleNativePixels)
    return NO;
  NSSize cs = [self naturalContentSize];
  return cs.width > self.bounds.size.width || cs.height > self.bounds.size.height;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect
{
  MTLRenderPassDescriptor* rpd = self.currentRenderPassDescriptor;
  id<CAMetalDrawable> drawable = self.currentDrawable;
  if (!rpd || !drawable || !_pipeline)
    return;

  id<MTLCommandBuffer> cb = [_queue commandBuffer];

  NSRect cr = [self contentRect];
  NSSize vs = self.bounds.size;
  id<MTLTexture> tex = _surfaceTexture;
  id<MTLSamplerState> sampler = _linearSampler;

  if (tex && cr.size.width > 0 && vs.width > 0 && vs.height > 0) {
    CGFloat bs = self.window ? self.window.backingScaleFactor : 1.0;
    CGFloat pixelsPerRemote = cr.size.width * bs / _fbSize.width;

    if (!_smoothScaling || fabs(pixelsPerRemote - round(pixelsPerRemote)) < 0.001) {
      // Integer scale factors look best without filtering
      sampler = (!_smoothScaling || pixelsPerRemote >= 1.0) ? _nearestSampler : _linearSampler;
    } else if (pixelsPerRemote < 0.75) {
      // Strong downscaling: sample from a mipmapped copy
      if (_mipTexture == nil || _mipTexture.width != tex.width ||
          _mipTexture.height != tex.height) {
        MTLTextureDescriptor* td =
          [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                             width:tex.width
                                                            height:tex.height
                                                         mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        _mipTexture = [self.device newTextureWithDescriptor:td];
      }
      id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
      [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(tex.width, tex.height, 1)
                  toTexture:_mipTexture destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit generateMipmapsForTexture:_mipTexture];
      [blit endEncoding];
      tex = _mipTexture;
      sampler = _mipSampler;
    }
  }

  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
  if (tex && cr.size.width > 0 && vs.width > 0 && vs.height > 0) {
    // Content rect in normalized device coordinates
    float r[4] = {
      (float)(cr.origin.x / vs.width * 2.0 - 1.0),
      (float)(cr.origin.y / vs.height * 2.0 - 1.0),
      (float)(NSMaxX(cr) / vs.width * 2.0 - 1.0),
      (float)(NSMaxY(cr) / vs.height * 2.0 - 1.0),
    };
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:r length:sizeof(r) atIndex:0];
    [enc setFragmentTexture:tex atIndex:0];
    [enc setFragmentSamplerState:sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  [enc endEncoding];

  [cb presentDrawable:drawable];
  [cb commit];
}

#pragma mark Snapshot

- (NSImage*)snapshotImage
{
  if (!_surface)
    return nil;
  IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
  size_t w = IOSurfaceGetWidth(_surface);
  size_t h = IOSurfaceGetHeight(_surface);
  size_t bpr = IOSurfaceGetBytesPerRow(_surface);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(_surface), w, h, 8,
                                           bpr, cs,
                                           kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
  IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
  if (ctx)
    CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  if (!img)
    return nil;
  NSImage* image = [[NSImage alloc] initWithCGImage:img size:NSMakeSize(w, h)];
  CGImageRelease(img);
  return image;
}

#pragma mark Cursor

- (void)setRemoteCursor:(NSImage*)image hotspot:(NSPoint)hotspot
{
  _cursorImage = image;
  _cursorHotspot = hotspot;
  [self updateCursor];
}

- (NSCursor*)dotCursor
{
  static NSCursor* dot;
  if (!dot) {
    NSImage* img = [NSImage imageWithSize:NSMakeSize(7, 7) flipped:NO
                           drawingHandler:^BOOL(NSRect r) {
      [[NSColor whiteColor] setFill];
      [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 0.5, 0.5)] fill];
      [[NSColor blackColor] setFill];
      [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 2, 2)] fill];
      return YES;
    }];
    dot = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(3.5, 3.5)];
  }
  return dot;
}

- (NSCursor*)invisibleCursor
{
  static NSCursor* inv;
  if (!inv) {
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    inv = [[NSCursor alloc] initWithImage:img hotSpot:NSZeroPoint];
  }
  return inv;
}

- (void)updateCursor
{
  if (self.session == nil || self.session.viewOnly) {
    _cursor = [NSCursor arrowCursor];
  } else if (_cursorImage == nil) {
    _cursor = _showDotForInvisibleCursor ? [self dotCursor] : [self invisibleCursor];
  } else {
    // Show the remote cursor at the same scale as the remote screen
    CGFloat s = [self effectiveScale];
    if (s <= 0)
      s = 1.0;
    NSSize sz = _cursorImage.size;
    NSImage* img = [_cursorImage copy];
    img.size = NSMakeSize(MAX(1, sz.width * s), MAX(1, sz.height * s));
    _cursor = [[NSCursor alloc] initWithImage:img
                                      hotSpot:NSMakePoint(_cursorHotspot.x * s,
                                                          _cursorHotspot.y * s)];
  }

  [self.window invalidateCursorRectsForView:self];
  if (self.window.isKeyWindow) {
    NSPoint p = [self convertPoint:[self.window mouseLocationOutsideOfEventStream] fromView:nil];
    if (NSPointInRect(p, self.bounds))
      [_cursor set];
  }
}

- (void)resetCursorRects
{
  if (_cursor)
    [self addCursorRect:self.visibleRect cursor:_cursor];
}

- (void)updateTrackingAreas
{
  [super updateTrackingAreas];
  if (_tracking)
    [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc]
                initWithRect:NSZeroRect
                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                             NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow |
                             NSTrackingInVisibleRect
                       owner:self userInfo:nil];
  [self addTrackingArea:_tracking];
}

- (void)cursorUpdate:(NSEvent*)event
{
  if (_cursor)
    [_cursor set];
}

#pragma mark Mouse

- (NSPoint)remotePointForEvent:(NSEvent*)event
{
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  _lastMouse = p;
  NSRect cr = [self contentRect];
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return NSZeroPoint;
  CGFloat x = (p.x - cr.origin.x) / cr.size.width * _fbSize.width;
  CGFloat y = (NSMaxY(cr) - p.y) / cr.size.height * _fbSize.height;
  return NSMakePoint(floor(x), floor(y));
}

- (void)sendPointerForEvent:(NSEvent*)event
{
  [self.session sendPointer:[self remotePointForEvent:event] buttons:_buttonMask];
}

- (uint16_t)maskForOtherButton:(NSInteger)number
{
  switch (number) {
  case 2: return kButtonMiddle;
  case 3: return kButtonBack;
  case 4: return kButtonForward;
  }
  return 0;
}

- (void)mouseDown:(NSEvent*)e
{
  [self.window makeFirstResponder:self];
  _buttonMask |= kButtonLeft;
  [self sendPointerForEvent:e];
}
- (void)mouseUp:(NSEvent*)e { _buttonMask &= ~kButtonLeft; [self sendPointerForEvent:e]; }
- (void)rightMouseDown:(NSEvent*)e { _buttonMask |= kButtonRight; [self sendPointerForEvent:e]; }
- (void)rightMouseUp:(NSEvent*)e { _buttonMask &= ~kButtonRight; [self sendPointerForEvent:e]; }
- (void)otherMouseDown:(NSEvent*)e { _buttonMask |= [self maskForOtherButton:e.buttonNumber]; [self sendPointerForEvent:e]; }
- (void)otherMouseUp:(NSEvent*)e { _buttonMask &= ~[self maskForOtherButton:e.buttonNumber]; [self sendPointerForEvent:e]; }
- (void)mouseDragged:(NSEvent*)e { [self sendPointerForEvent:e]; [self checkEdgePan]; }
- (void)rightMouseDragged:(NSEvent*)e { [self sendPointerForEvent:e]; [self checkEdgePan]; }
- (void)otherMouseDragged:(NSEvent*)e { [self sendPointerForEvent:e]; [self checkEdgePan]; }
- (void)mouseMoved:(NSEvent*)e { [self sendPointerForEvent:e]; [self checkEdgePan]; }

- (void)mouseExited:(NSEvent*)e
{
  [_edgeTimer invalidate];
  _edgeTimer = nil;
}

- (void)sendWheel:(uint16_t)bit count:(int)count at:(NSPoint)pos
{
  for (int i = 0; i < count; i++) {
    [self.session sendPointer:pos buttons:_buttonMask | bit];
    [self.session sendPointer:pos buttons:_buttonMask];
  }
}

- (void)scrollWheel:(NSEvent*)e
{
  NSPoint pos = [self remotePointForEvent:e];

  // Option + scroll pans the local view when the remote screen is larger
  if ((e.modifierFlags & NSEventModifierFlagOption) && [self canPan]) {
    _pan.x -= e.scrollingDeltaX;
    _pan.y -= e.scrollingDeltaY;
    [self clampPan];
    [self setNeedsDisplay:YES];
    return;
  }

  CGFloat dx = e.scrollingDeltaX, dy = e.scrollingDeltaY;
  int stepsX = 0, stepsY = 0;
  if (e.hasPreciseScrollingDeltas) {
    // Trackpads and Magic Mouse: one wheel click per ~12 points
    const CGFloat step = 12.0;
    if (e.phase == NSEventPhaseBegan) {
      _scrollAccumX = 0;
      _scrollAccumY = 0;
    }
    _scrollAccumX += dx;
    _scrollAccumY += dy;
    stepsX = (int)(_scrollAccumX / step);
    stepsY = (int)(_scrollAccumY / step);
    _scrollAccumX -= stepsX * step;
    _scrollAccumY -= stepsY * step;
  } else {
    stepsX = dx > 0 ? MAX(1, (int)round(dx)) : dx < 0 ? MIN(-1, (int)round(dx)) : 0;
    stepsY = dy > 0 ? MAX(1, (int)round(dy)) : dy < 0 ? MIN(-1, (int)round(dy)) : 0;
  }

  if (stepsY > 0) [self sendWheel:kWheelUp count:stepsY at:pos];
  if (stepsY < 0) [self sendWheel:kWheelDown count:-stepsY at:pos];
  if (stepsX > 0) [self sendWheel:kWheelLeft count:stepsX at:pos];
  if (stepsX < 0) [self sendWheel:kWheelRight count:-stepsX at:pos];
}

- (void)magnifyWithEvent:(NSEvent*)event
{
  // Pinch to zoom switches to fixed zoom
  if (_scaleMode == ZVScaleFit || _scaleMode == ZVScaleFill) {
    _zoom = [self effectiveScale];
    _scaleMode = ZVScale100;
  }
  if (_scaleMode == ZVScaleNativePixels) {
    _zoom = [self fixedScale];
    _scaleMode = ZVScale100;
  }
  self.zoom = _zoom * (1.0 + event.magnification);
  [self.viewDelegate remoteViewDidChangeZoom:self];
}

#pragma mark Edge panning

- (void)checkEdgePan
{
  if (![self canPan]) {
    [_edgeTimer invalidate];
    _edgeTimer = nil;
    return;
  }
  NSPoint d = [self edgeDirection];
  if (d.x == 0 && d.y == 0) {
    [_edgeTimer invalidate];
    _edgeTimer = nil;
  } else if (_edgeTimer == nil) {
    _edgeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 target:self
                                                selector:@selector(edgePanTick:)
                                                userInfo:nil repeats:YES];
  }
}

- (NSPoint)edgeDirection
{
  const CGFloat edge = 24.0;
  NSSize vs = self.bounds.size;
  NSPoint d = NSZeroPoint;
  if (_lastMouse.x < edge) d.x = -(edge - _lastMouse.x);
  else if (_lastMouse.x > vs.width - edge) d.x = edge - (vs.width - _lastMouse.x);
  if (_lastMouse.y < edge) d.y = edge - _lastMouse.y;            // bottom: move down
  else if (_lastMouse.y > vs.height - edge) d.y = -(edge - (vs.height - _lastMouse.y));
  return d;
}

- (void)edgePanTick:(NSTimer*)t
{
  NSPoint d = [self edgeDirection];
  if ((d.x == 0 && d.y == 0) || ![self canPan]) {
    [_edgeTimer invalidate];
    _edgeTimer = nil;
    return;
  }
  NSPoint old = _pan;
  _pan.x += d.x * 0.8;
  _pan.y += d.y * 0.8;
  [self clampPan];
  if (!NSEqualPoints(old, _pan)) {
    [self setNeedsDisplay:YES];
    // Keep the remote pointer under the local one
    NSRect cr = [self contentRect];
    NSPoint rp = NSMakePoint(floor((_lastMouse.x - cr.origin.x) / cr.size.width * _fbSize.width),
                             floor((NSMaxY(cr) - _lastMouse.y) / cr.size.height * _fbSize.height));
    [self.session sendPointer:rp buttons:_buttonMask];
  }
}

#pragma mark Dropped files

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
  if (![sender.draggingPasteboard canReadObjectForClasses:@[[NSURL class]]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}])
    return NSDragOperationNone;
  return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
  NSArray* urls = [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                                           options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  if (urls.count == 0)
    return NO;
  [self.viewDelegate remoteView:self didReceiveFileURLs:urls];
  return YES;
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent*)event { [self handleKeyEvent:event]; }
- (void)keyUp:(NSEvent*)event { [self handleKeyEvent:event]; }
- (void)flagsChanged:(NSEvent*)event { [self handleKeyEvent:event]; }

- (void)handleKeyEvent:(NSEvent*)event
{
  if (_keyboard->isKeyboardReset((__bridge const void*)event)) {
    [self releaseKeys];
    return;
  }
  _keyboard->handleEvent((__bridge const void*)event);
}

- (void)releaseKeys
{
  [self.session releaseAllKeys];
}

- (void)sendKeyPress:(int)code keyCode:(uint32_t)keyCode keySym:(uint32_t)keySym
{
  // Apply the modifier mapping chosen for this connection
  if (code == kVK_Command || code == kVK_RightCommand) {
    bool right = code == kVK_RightCommand;
    switch (_commandKeyMode) {
    case ZVCommandAsWindows:
      keySym = right ? XK_Super_R : XK_Super_L;
      keyCode = right ? 0xdc : 0xdb;
      break;
    case ZVCommandAsControl:
      keySym = right ? XK_Control_R : XK_Control_L;
      keyCode = right ? 0x9d : 0x1d;
      break;
    case ZVCommandAsAlt:
      keySym = right ? XK_Alt_R : XK_Alt_L;
      keyCode = right ? 0xb8 : 0x38;
      break;
    }
  }

  if (_keyboardMode == ZVKeyboardSymbols)
    keyCode = 0;

  [self.session sendKeyPress:code keyCode:keyCode keySym:keySym];
}

- (void)sendKeyRelease:(int)code
{
  [self.session sendKeyRelease:code];
}

@end
