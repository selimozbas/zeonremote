/* ZeonVNC: H.264 decoding with Apple VideoToolbox (hardware accelerated)
 *
 * The RFB "Open H.264" encoding delivers an Annex B byte stream (start
 * codes). VideoToolbox wants parameter sets in a format description and
 * the slices in AVCC form (length prefixed), so the stream is converted
 * here, one access unit at a time.
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include <string.h>

#include <core/LogWriter.h>

#include <rfb/PixelBuffer.h>
#include <rfb/H264VTDecoderContext.h>

using namespace rfb;

static core::LogWriter vlog("H264VideoToolbox");

H264VTDecoderContext::H264VTDecoderContext(const core::Rect& r)
  : H264DecoderContext(r), paramsChanged(false), format(nullptr),
    session(nullptr), lastFrame(nullptr)
{
}

H264VTDecoderContext::~H264VTDecoderContext()
{
  destroySession();
}

void H264VTDecoderContext::destroySession()
{
  if (session) {
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    session = nullptr;
  }
  if (format) {
    CFRelease(format);
    format = nullptr;
  }
  if (lastFrame) {
    CVPixelBufferRelease(lastFrame);
    lastFrame = nullptr;
  }
}

bool H264VTDecoderContext::createSession()
{
  destroySession();

  const uint8_t* sets[2] = { sps.data(), pps.data() };
  size_t sizes[2] = { sps.size(), pps.size() };
  OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
    kCFAllocatorDefault, 2, sets, sizes, 4, &format);
  if (err != noErr) {
    vlog.error("Invalid H.264 parameter sets (%d)", (int)err);
    format = nullptr;
    return false;
  }

  int32_t fmt = kCVPixelFormatType_32BGRA;
  CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fmt);
  const void* keys[] = { kCVPixelBufferPixelFormatTypeKey };
  const void* values[] = { fmtNum };
  CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
  CFRelease(fmtNum);

  VTDecompressionOutputCallbackRecord cb = { outputCallback, this };
  err = VTDecompressionSessionCreate(kCFAllocatorDefault, format, nullptr,
                                     attrs, &cb, &session);
  CFRelease(attrs);
  if (err != noErr) {
    vlog.error("Unable to create H.264 decoder (%d)", (int)err);
    session = nullptr;
    return false;
  }

  CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(format);
  vlog.info("Hardware H.264 decoder ready (%dx%d)", dim.width, dim.height);
  return true;
}

void H264VTDecoderContext::outputCallback(void* refcon, void*, OSStatus status,
                                          VTDecodeInfoFlags, CVImageBufferRef image,
                                          CMTime, CMTime)
{
  H264VTDecoderContext* self = (H264VTDecoderContext*)refcon;
  if (status != noErr || image == nullptr)
    return;
  if (self->lastFrame)
    CVPixelBufferRelease(self->lastFrame);
  self->lastFrame = CVPixelBufferRetain(image);
}

void H264VTDecoderContext::decodeAccessUnit(const std::vector<uint8_t>& avcc,
                                            ModifiablePixelBuffer* pb)
{
  if (avcc.empty())
    return;

  if (paramsChanged || session == nullptr) {
    if (sps.empty() || pps.empty())
      return;     // can't decode anything before the first key frame
    paramsChanged = false;
    if (!createSession())
      return;
  }

  CMBlockBufferRef block = nullptr;
  OSStatus err = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                                    avcc.size(), kCFAllocatorDefault,
                                                    nullptr, 0, avcc.size(), 0, &block);
  if (err != noErr)
    return;
  CMBlockBufferReplaceDataBytes(avcc.data(), block, 0, avcc.size());

  CMSampleBufferRef sample = nullptr;
  size_t sampleSize = avcc.size();
  err = CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1, 0,
                                  nullptr, 1, &sampleSize, &sample);
  CFRelease(block);
  if (err != noErr)
    return;

  VTDecodeInfoFlags info = 0;
  err = VTDecompressionSessionDecodeFrame(session, sample, 0, nullptr, &info);
  CFRelease(sample);
  if (err == kVTInvalidSessionErr) {
    // e.g. after the GPU was reset; rebuild on the next key frame
    vlog.info("H.264 decoder session invalidated, recreating");
    paramsChanged = true;
    return;
  }
  if (err != noErr) {
    vlog.debug("H.264 decode error %d", (int)err);
    return;
  }
  VTDecompressionSessionWaitForAsynchronousFrames(session);

  if (lastFrame == nullptr)
    return;

  CVPixelBufferLockBaseAddress(lastFrame, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(lastFrame);
  size_t stride = CVPixelBufferGetBytesPerRow(lastFrame) / 4;
  int w = (int)CVPixelBufferGetWidth(lastFrame);
  int h = (int)CVPixelBufferGetHeight(lastFrame);

  // The coded frame can be larger than the rectangle (macroblock padding)
  core::Rect r = rect;
  if (r.width() > w)
    r.br.x = r.tl.x + w;
  if (r.height() > h)
    r.br.y = r.tl.y + h;

  // BGRA in memory matches the viewer's native format; imageRect()
  // converts if the framebuffer uses something else
  static const PixelFormat bgra(32, 24, false, true, 255, 255, 255, 16, 8, 0);
  if (base)
    pb->imageRect(bgra, r, base, stride);
  CVPixelBufferUnlockBaseAddress(lastFrame, kCVPixelBufferLock_ReadOnly);
}

void H264VTDecoderContext::decode(const uint8_t* buf, uint32_t len,
                                  ModifiablePixelBuffer* pb)
{
  std::vector<uint8_t> avcc;

  // Split the Annex B stream into NAL units
  auto findStart = [&](size_t from, size_t* codeLen) -> size_t {
    for (size_t p = from; p + 3 <= len; p++) {
      if (buf[p] == 0 && buf[p + 1] == 0) {
        if (buf[p + 2] == 1) {
          *codeLen = 3;
          return p;
        }
        if (p + 4 <= len && buf[p + 2] == 0 && buf[p + 3] == 1) {
          *codeLen = 4;
          return p;
        }
      }
    }
    *codeLen = 0;
    return len;
  };

  size_t codeLen;
  size_t start = findStart(0, &codeLen);
  while (start < len) {
    size_t nalStart = start + codeLen;
    size_t nextLen;
    size_t next = findStart(nalStart, &nextLen);
    size_t nalEnd = next;
    // Trailing zero bytes belong to the next start code
    while (nalEnd > nalStart && buf[nalEnd - 1] == 0)
      nalEnd--;

    if (nalEnd > nalStart) {
      const uint8_t* nal = buf + nalStart;
      size_t nalLen = nalEnd - nalStart;
      int type = nal[0] & 0x1f;

      switch (type) {
      case 7: // SPS
        if (sps.size() != nalLen || memcmp(sps.data(), nal, nalLen) != 0) {
          sps.assign(nal, nal + nalLen);
          paramsChanged = true;
        }
        break;
      case 8: // PPS
        if (pps.size() != nalLen || memcmp(pps.data(), nal, nalLen) != 0) {
          pps.assign(nal, nal + nalLen);
          paramsChanged = true;
        }
        break;
      case 1: // non-IDR slice
      case 5: // IDR slice
        // first_mb_in_slice == 0 (first bit set) starts a new picture
        if (nalLen > 1 && (nal[1] & 0x80) && !avcc.empty()) {
          decodeAccessUnit(avcc, pb);
          avcc.clear();
        }
        avcc.push_back((nalLen >> 24) & 0xff);
        avcc.push_back((nalLen >> 16) & 0xff);
        avcc.push_back((nalLen >> 8) & 0xff);
        avcc.push_back(nalLen & 0xff);
        avcc.insert(avcc.end(), nal, nal + nalLen);
        break;
      default:
        // AUD, SEI etc. are not needed for decoding
        break;
      }
    }

    start = next;
    codeLen = nextLen;
  }

  decodeAccessUnit(avcc, pb);
}
