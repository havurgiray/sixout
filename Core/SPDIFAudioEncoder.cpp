// SPDIFAudioEncoder.cpp — see header. Derived from SoundPusher (MIT), ported to the FFmpeg 7/8 API.
#include <string>
#include <cassert>
#include <cstring>
#include <cmath>
#include <algorithm>
#include "SPDIFAudioEncoder.hpp"

static std::string GetAVErrorString(const int error)
{
  char buf[AV_ERROR_MAX_STRING_SIZE];
  av_strerror(error, buf, sizeof buf);
  return std::string(buf);
}

LibAVException::LibAVException(const int error) : std::runtime_error(GetAVErrorString(error)) { }

/// Picks a libav channel layout the codec supports for the CoreAudio layout tag and builds the input-index ->
/// libav-index mapping (side surrounds fall back to back surrounds when the codec's layout uses those).
static void MakeAVLayout(AudioChannelLayoutTag tag, const AVCodecContext *ctx, const AVCodec *codec, AVChannelLayout &outLayout, std::vector<int> &outMap)
{
  const uint32_t n = AudioChannelLayoutTag_GetNumberOfChannels(tag);
  outMap.assign(n, 0);
  std::vector<AVChannel> order;
  switch (tag)
  {
    case kAudioChannelLayoutTag_Stereo:
      outLayout = AV_CHANNEL_LAYOUT_STEREO; order = {AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT}; break;
    case kAudioChannelLayoutTag_AudioUnit_5_1: // L R C LFE Ls Rs
      outLayout = AV_CHANNEL_LAYOUT_5POINT1; order = {AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT}; break;
    default:
      throw std::runtime_error("Unsupported channel layout tag");
  }
  // prefer a layout the codec lists with the same channel count
  const AVChannelLayout *layouts = nullptr; int numLayouts = 0;
  if (avcodec_get_supported_config(ctx, codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, reinterpret_cast<const void **>(&layouts), &numLayouts) >= 0 && layouts)
  {
    bool found = false;
    for (int i = 0; i < numLayouts && !found; ++i)
      if (layouts[i].nb_channels == static_cast<int>(n) && av_channel_layout_compare(&layouts[i], &outLayout) == 0) found = true;
    if (!found)
      for (int i = 0; i < numLayouts; ++i)
        if (layouts[i].nb_channels == static_cast<int>(n)) { av_channel_layout_copy(&outLayout, &layouts[i]); break; }
  }
  for (uint32_t i = 0; i < n; ++i)
  {
    int idx = av_channel_layout_index_from_channel(&outLayout, order[i]);
    if (idx < 0 && order[i] == AV_CHAN_SIDE_LEFT) idx = av_channel_layout_index_from_channel(&outLayout, AV_CHAN_BACK_LEFT);
    if (idx < 0 && order[i] == AV_CHAN_SIDE_RIGHT) idx = av_channel_layout_index_from_channel(&outLayout, AV_CHAN_BACK_RIGHT);
    if (idx < 0) throw std::runtime_error("Channel not in the codec's layout");
    outMap[i] = idx;
  }
}

SPDIFAudioEncoder::SPDIFAudioEncoder(const AudioStreamBasicDescription &inFormat,
  const AudioChannelLayoutTag channelLayoutTag, const AudioStreamBasicDescription &outFormat, os_log_t logger,
  bool /*useDLPiiUpmix*/, const AVCodecID codecID, int requestedBitRate)
: _inFormat(inFormat), _outFormat(outFormat), _writePacketLogger(logger)
{
  int status = 0;
  assert(inFormat.mChannelsPerFrame == AudioChannelLayoutTag_GetNumberOfChannels(channelLayoutTag));

  const AVCodec *codec = avcodec_find_encoder(codecID);
  if (!codec) throw std::runtime_error(codecID == AV_CODEC_ID_DTS ? "DTS encoder not available in libavcodec" : "AC3 encoder not available in libavcodec");
  _codecName = codec->name;

  // candidate bit rates: the requested one first, then the standard S/PDIF-compatible maxima
  std::vector<int> rates;
  if (requestedBitRate > 0) rates.push_back(requestedBitRate);
  if (codecID == AV_CODEC_ID_DTS) { for (int r : {1509000, 1509750, 1411200, 1344000, 1280000, 1024000}) rates.push_back(r); }
  else { for (int r : {640000, 448000}) rates.push_back(r); }

  AVChannelLayout layout = {};
  std::string lastError;
  for (const int rate : rates)
  {
    if (_codecContext) avcodec_free_context(&_codecContext);
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) throw std::runtime_error("Could not allocate AVCodecContext");
    if (codecID == AV_CODEC_ID_DTS) _codecContext->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;

    av_channel_layout_uninit(&layout);
    MakeAVLayout(channelLayoutTag, _codecContext, codec, layout, _input2LibAVChannel);

    const enum AVSampleFormat *fmts = nullptr; int numFmts = 0;
    enum AVSampleFormat sampleFmt = codecID == AV_CODEC_ID_DTS ? AV_SAMPLE_FMT_S32 : AV_SAMPLE_FMT_FLTP;
    if (avcodec_get_supported_config(_codecContext, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, reinterpret_cast<const void **>(&fmts), &numFmts) >= 0 && fmts && numFmts > 0)
    {
      sampleFmt = fmts[0];
      for (int i = 0; i < numFmts; ++i) if (fmts[i] == AV_SAMPLE_FMT_FLTP) { sampleFmt = AV_SAMPLE_FMT_FLTP; break; }
    }

    _codecContext->bit_rate = rate;
    _codecContext->sample_fmt = sampleFmt;
    _codecContext->sample_rate = static_cast<int>(_inFormat.mSampleRate);
    status = av_channel_layout_copy(&_codecContext->ch_layout, &layout);
    if (status < 0) throw LibAVException(status);
    _codecContext->time_base = av_make_q(1, _codecContext->sample_rate);
    _codecContext->codec_type = AVMEDIA_TYPE_AUDIO;

    status = avcodec_open2(_codecContext, codec, nullptr);
    if (status >= 0) { _bitRate = rate; break; }
    char buf[AV_ERROR_MAX_STRING_SIZE]; av_strerror(status, buf, sizeof buf);
    lastError = std::string(codec->name) + " at " + std::to_string(rate) + " bit/s: " + buf;
    os_log_info(logger, "%{public}s", lastError.c_str());
  }
  if (_bitRate == 0) throw std::runtime_error("Could not open encoder: " + lastError);
  _numFramesPerPacket = _codecContext->frame_size;
  os_log_info(logger, "Encoder %{public}s at %d bit/s, %u frames per packet", _codecName, _bitRate, _numFramesPerPacket);

  status = avformat_alloc_output_context2(&_muxer, nullptr, "spdif", nullptr);
  if (status < 0 || !_muxer) throw std::runtime_error("Could not allocate spdif muxer");
  AVStream *stream = avformat_new_stream(_muxer, nullptr);
  if (!stream) throw std::runtime_error("Could not allocate AVStream");
  stream->id = 0;
  stream->time_base = _codecContext->time_base;
  status = avcodec_parameters_from_context(stream->codecpar, _codecContext);
  if (status < 0) throw LibAVException(status);

  const int avioSize = MaxBytesPerPacket * 2;
  uint8_t *avioBuffer = static_cast<uint8_t *>(av_malloc(avioSize));
  _avio = avio_alloc_context(avioBuffer, avioSize, 1, this, nullptr, &WritePacketFunc, nullptr);
  if (!_avio) throw std::runtime_error("Could not allocate AVIOContext");
  _muxer->pb = _avio;
  _muxer->flags |= AVFMT_FLAG_CUSTOM_IO;

  _frame = av_frame_alloc();
  if (!_frame) throw std::runtime_error("Could not allocate AVFrame");
  _frame->format = _codecContext->sample_fmt;
  status = av_channel_layout_copy(&_frame->ch_layout, &layout);
  if (status < 0) throw LibAVException(status);
  _frame->sample_rate = _codecContext->sample_rate;
  _frame->nb_samples = _numFramesPerPacket;
  status = av_frame_get_buffer(_frame, 0);
  if (status < 0) throw LibAVException(status);

  _packet = av_packet_alloc();
  if (!_packet) throw std::runtime_error("Could not allocate AVPacket");

  status = swr_alloc_set_opts2(&_swr, &layout, _codecContext->sample_fmt, _frame->sample_rate, &layout, AV_SAMPLE_FMT_FLT, _frame->sample_rate, 0, nullptr);
  if (status < 0) throw LibAVException(status);
  status = swr_set_channel_mapping(_swr, _input2LibAVChannel.data());
  if (status < 0) throw LibAVException(status);
  status = swr_init(_swr);
  if (status < 0) throw LibAVException(status);

  status = avformat_write_header(_muxer, nullptr);
  if (status < 0) throw LibAVException(status);
  av_channel_layout_uninit(&layout);
}

SPDIFAudioEncoder::~SPDIFAudioEncoder()
{
  if (_muxer) { av_write_trailer(_muxer); }
  if (_swr) swr_free(&_swr);
  if (_packet) av_packet_free(&_packet);
  if (_frame) av_frame_free(&_frame);
  if (_avio) { av_freep(&_avio->buffer); avio_context_free(&_avio); }
  if (_muxer) { _muxer->pb = nullptr; avformat_free_context(_muxer); }
  if (_codecContext) avcodec_free_context(&_codecContext);
}

int SPDIFAudioEncoder::WritePacketFunc(void *opaque, const uint8_t *buf, int buf_size)
{
  auto me = static_cast<SPDIFAudioEncoder *>(opaque);
  if (!me->_writePacketBuf) return buf_size; // header/trailer writes outside EncodePacket are dropped
  if (static_cast<uint32_t>(buf_size) > me->_writePacketBufSize)
    os_log_info(me->_writePacketLogger, "Writing %i bytes for packet but only %u available", buf_size, me->_writePacketBufSize);
  const auto num = std::min(static_cast<uint32_t>(buf_size), me->_writePacketBufSize);
  std::memcpy(me->_writePacketBuf, buf, num);
  me->_writePacketBuf += num;
  me->_writePacketBufSize -= num;
  return buf_size;
}

uint32_t SPDIFAudioEncoder::EncodePacket(const uint32_t numFrames, const SampleT *inputFrames, uint32_t sizeOutBuffer, uint8_t *outBuffer, const bool /*upmix*/)
{
  if (numFrames != _numFramesPerPacket) throw std::invalid_argument("Incorrect number of frames for encoding");
  int status = av_frame_make_writable(_frame);
  if (status < 0) throw LibAVException(status);
  const uint8_t *in[1] = { reinterpret_cast<const uint8_t *>(inputFrames) };
  status = swr_convert(_swr, _frame->data, _frame->nb_samples, in, numFrames);
  if (status < 0) throw LibAVException(status);

  status = avcodec_send_frame(_codecContext, _frame);
  if (status < 0) throw LibAVException(status);

  _writePacketBuf = outBuffer;
  _writePacketBufSize = sizeOutBuffer;
  while ((status = avcodec_receive_packet(_codecContext, _packet)) == 0)
  {
    _packet->stream_index = 0;
    if (_packet->pts == AV_NOPTS_VALUE) { _packet->pts = _packet->dts = _ptsOut; }
    _ptsOut += _numFramesPerPacket;
    const int w = av_write_frame(_muxer, _packet);
    av_packet_unref(_packet);
    if (w < 0) { _writePacketBuf = nullptr; _writePacketBufSize = 0; throw LibAVException(w); }
  }
  avio_flush(_muxer->pb);
  const auto numBytesWritten = static_cast<uint32_t>(_writePacketBuf - outBuffer);
  _writePacketBuf = nullptr;
  _writePacketBufSize = 0;
  if (status != AVERROR(EAGAIN) && status != AVERROR_EOF) throw LibAVException(status);
  return numBytesWritten;
}
