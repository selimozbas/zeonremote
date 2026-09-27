// ZeonVNC - Framebuffer backed by an IOSurface so it can be shown by
// Metal without any copies.
//
// This is free software; you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your
// option) any later version.

#ifndef __ZV_FRAMEBUFFER_H__
#define __ZV_FRAMEBUFFER_H__

#include <IOSurface/IOSurface.h>

#include <rfb/PixelBuffer.h>

class ZVFramebuffer : public rfb::FullFramePixelBuffer {
public:
  ZVFramebuffer(int width, int height);
  ~ZVFramebuffer();

  // Native format of the surface (BGRX, little endian)
  static rfb::PixelFormat nativePF();

  IOSurfaceRef surface() const { return surface_; }

  // Brackets CPU writes (i.e. a framebuffer update)
  void beginWrite();
  void endWrite();

private:
  IOSurfaceRef surface_;
  int lockDepth;
};

#endif
