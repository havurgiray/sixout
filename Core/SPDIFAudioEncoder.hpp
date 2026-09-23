// SPDIFAudioEncoder.hpp — AC3 encoder + IEC 61937 (S/PDIF) framing via libavcodec/libavformat.
// Derived from SoundPusher (MIT, Daniel Vollmer), ported to the FFmpeg 7/8 API.
#ifndef SPDIFAudioEncoder_hpp
#define SPDIFAudioEncoder_hpp

#include <stdexcept>
#include <cstdint>
#include <vector>
#include <os/log.h>
#include <CoreAudio/CoreAudio.h>
extern "C" {
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libswresample/swresample.h"
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
}

struct LibAVException : std::runtime_error { LibAVException(const int error); };

/// Takes interleaved float input frames (L R C LFE Ls Rs) and produces S/PDIF-framed AC3 packets.
struct SPDIFAudioEncoder
{
  typedef float SampleT;

  SPDIFAudioEncoder(const AudioStreamBasicDescription &inFormat, const AudioChannelLayoutTag channelLayoutTag,
    const AudioStreamBasicDescription &outFormat, os_log_t logger, bool useDLPiiUpmix,
    const AVCodecID codecID = AV_CODEC_ID_AC3, int requestedBitRate = 0);

  const char *GetCodecName() const { return _codecName; }
  int GetBitRate() const { return _bitRate; }
  ~SPDIFAudioEncoder();

  const AudioStreamBasicDescription &GetInFormat() const { return _inFormat; }
  const AudioStreamBasicDescription &GetOutFormat() const { return _outFormat; }
  uint32_t GetNumFramesPerPacket() const { return _numFramesPerPacket; }

  static constexpr uint32_t MaxBytesPerPacket = 6144;

  /// Encodes exactly GetNumFramesPerPacket() interleaved frames into outBuffer; returns bytes written.
  uint32_t EncodePacket(const uint32_t numFrames, const SampleT *inputFrames, uint32_t sizeOutBuffer, uint8_t *outBuffer, const bool upmix);

protected:
  static int WritePacketFunc(void *opaque, const uint8_t *buf, int buf_size);

  AudioStreamBasicDescription _inFormat;
  AudioStreamBasicDescription _outFormat;
  AVCodecContext *_codecContext = nullptr;
  AVFormatContext *_muxer = nullptr;
  AVIOContext *_avio = nullptr;
  AVFrame *_frame = nullptr;
  AVPacket *_packet = nullptr;
  SwrContext *_swr = nullptr;
  std::vector<int> _input2LibAVChannel;
  uint32_t _numFramesPerPacket = 0;
  int64_t _pts = 0;
  const char *_codecName = "?";
  int _bitRate = 0;
  int64_t _ptsOut = 0;
  uint8_t *_writePacketBuf = nullptr;
  uint32_t _writePacketBufSize = 0;
  os_log_t _writePacketLogger;
};

#endif
