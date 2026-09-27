// ZeonVNC - IOSurface backed framebuffer
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#include <stdexcept>
#include <string.h>

#import <CoreVideo/CoreVideo.h>

#include "ZVFramebuffer.h"

rfb::PixelFormat ZVFramebuffer::nativePF()
{
  // 32 bpp, depth 24, little endian, true colour, B G R X in memory
  return rfb::PixelFormat(32, 24, false, true, 255, 255, 255, 16, 8, 0);
}

ZVFramebuffer::ZVFramebuffer(int width, int height)
  : rfb::FullFramePixelBuffer(nativePF(), 0, 0, nullptr, 0),
    surface_(nullptr), lockDepth(0)
{
  if (width < 1) width = 1;
  if (height < 1) height = 1;

  NSDictionary* props = @{
    (id)kIOSurfaceWidth: @(width),
    (id)kIOSurfaceHeight: @(height),
    (id)kIOSurfaceBytesPerElement: @4,
    (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
  };

  surface_ = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  if (surface_ == nullptr)
    throw std::runtime_error("Unable to allocate IOSurface framebuffer");

  IOSurfaceLock(surface_, 0, nullptr);
  uint8_t* base = (uint8_t*)IOSurfaceGetBaseAddress(surface_);
  size_t bpr = IOSurfaceGetBytesPerRow(surface_);
  // Opaque black to start with
  for (int y = 0; y < height; y++) {
    uint32_t* row = (uint32_t*)(base + y * bpr);
    for (int x = 0; x < width; x++)
      row[x] = 0xff000000;
  }
  IOSurfaceUnlock(surface_, 0, nullptr);

  setBuffer(width, height, base, bpr / 4);
}

ZVFramebuffer::~ZVFramebuffer()
{
  if (surface_) {
    while (lockDepth > 0)
      endWrite();
    CFRelease(surface_);
  }
}

void ZVFramebuffer::beginWrite()
{
  if (lockDepth++ == 0)
    IOSurfaceLock(surface_, 0, nullptr);
}

void ZVFramebuffer::endWrite()
{
  if (lockDepth == 0)
    return;
  if (--lockDepth == 0)
    IOSurfaceUnlock(surface_, 0, nullptr);
}
