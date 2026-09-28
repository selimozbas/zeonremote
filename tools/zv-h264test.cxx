// Zeon Remote - decodes an Annex B H.264 file with the VideoToolbox decoder
// context and writes the last frame as a PPM image. Development check.
//
// Usage: zv-h264test in.h264 width height out.ppm

#include <stdio.h>
#include <stdlib.h>

#include <vector>

#include <core/Rect.h>
#include <rfb/PixelBuffer.h>
#include <rfb/H264DecoderContext.h>

int main(int argc, char** argv)
{
  if (argc != 5) {
    fprintf(stderr, "usage: %s in.h264 width height out.ppm\n", argv[0]);
    return 1;
  }
  int w = atoi(argv[2]), h = atoi(argv[3]);

  FILE* f = fopen(argv[1], "rb");
  if (!f)
    return 1;
  std::vector<uint8_t> data;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
    data.insert(data.end(), buf, buf + n);
  fclose(f);

  rfb::PixelFormat pf(32, 24, false, true, 255, 255, 255, 16, 8, 0);
  rfb::ManagedPixelBuffer pb(pf, w, h);
  core::Rect r(0, 0, w, h);
  rfb::H264DecoderContext* ctx = rfb::H264DecoderContext::createContext(r);
  ctx->decode(data.data(), data.size(), &pb);
  delete ctx;

  int stride;
  const uint8_t* px = pb.getBuffer(r, &stride);
  FILE* o = fopen(argv[4], "wb");
  fprintf(o, "P6\n%d %d\n255\n", w, h);
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      const uint8_t* p = px + (y * stride + x) * 4;
      uint8_t rgb[3] = { p[2], p[1], p[0] };
      fwrite(rgb, 1, 3, o);
    }
  fclose(o);
  printf("decoded %zu bytes\n", data.size());
  return 0;
}
