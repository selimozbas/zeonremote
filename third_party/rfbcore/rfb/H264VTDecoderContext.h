/* ZeonVNC: H.264 decoding with Apple VideoToolbox (hardware accelerated)
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef __RFB_H264VTDECODERCONTEXT_H__
#define __RFB_H264VTDECODERCONTEXT_H__

#include <vector>

#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>

#include <rfb/H264DecoderContext.h>

namespace rfb {

  class H264VTDecoderContext : public H264DecoderContext {
    public:
      H264VTDecoderContext(const core::Rect &r);
      ~H264VTDecoderContext() override;

      void decode(const uint8_t* h264_buffer, uint32_t len,
                  ModifiablePixelBuffer* pb) override;

    private:
      bool createSession();
      void destroySession();
      void decodeAccessUnit(const std::vector<uint8_t>& avcc,
                            ModifiablePixelBuffer* pb);

      static void outputCallback(void* refcon, void* frameRefcon,
                                 OSStatus status, VTDecodeInfoFlags flags,
                                 CVImageBufferRef image, CMTime pts,
                                 CMTime duration);

      std::vector<uint8_t> sps, pps;
      bool paramsChanged;
      CMVideoFormatDescriptionRef format;
      VTDecompressionSessionRef session;
      CVPixelBufferRef lastFrame;
  };

}

#endif
