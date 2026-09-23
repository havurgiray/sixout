#include <algorithm>
#include <cassert>
#include <cstring>
#include "ForwardingInputTap.hpp"
#include "DigitalOutputContext.hpp"

ForwardingInputTap::ForwardingInputTap(AudioObjectID device, AudioObjectID stream, DigitalOutputContext &outContext, SLProcessFn process, void *ctx)
: _device(device), _stream(stream), _format(outContext.GetInputFormat()), _outContext(outContext), _process(process), _ctx(ctx)
, _scratch(16384 * 6, 0.0f)
, _log(os_log_create("local.sixout", "InIOProc")), _deviceIOProcID(nullptr), _isRunning(false)
{
  OSStatus status = AudioDeviceCreateIOProcID(_device, DeviceIOProcFunc, this, &_deviceIOProcID);
  if (status != noErr)
    throw CAHelper::CoreAudioException("ForwardingInputTap::AudioDeviceCreateIOProcID()", status);
  CAHelper::SetStreamsEnabled(_device, _deviceIOProcID, /* input */false, false);

  static const AudioObjectPropertyAddress BufferFrameSizeAddress = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
  const UInt32 desiredBufferFrameSize = std::max(UInt32{128}, _outContext.GetNumFramesPerPacket() / 12);
  UInt32 dataSize = sizeof desiredBufferFrameSize;
  status = AudioObjectSetPropertyData(_device, &BufferFrameSizeAddress, 0, NULL, dataSize, &desiredBufferFrameSize);
  if (status != noErr)
    os_log(_log, "Could not set buffer frame-size to %u", desiredBufferFrameSize);
  outContext.SetNumSafeFrames(desiredBufferFrameSize);
}

ForwardingInputTap::~ForwardingInputTap()
{
  if (_isRunning) Stop();
  AudioDeviceDestroyIOProcID(_device, _deviceIOProcID);
  os_release(_log);
}

void ForwardingInputTap::Start()
{
  if (_isRunning) return;
  OSStatus status = AudioDeviceStart(_device, _deviceIOProcID);
  if (status != noErr)
    throw CAHelper::CoreAudioException("ForwardingInputTap::Start(): AudioDeviceStart()", status);
  _isRunning = true;
}

void ForwardingInputTap::Stop()
{
  if (!_isRunning) return;
  _isRunning = false;
  OSStatus status = AudioDeviceStop(_device, _deviceIOProcID);
  if (status != noErr)
    throw CAHelper::CoreAudioException("ForwardingInputTap::Stop(): AudioDeviceStop()", status);
}

OSStatus ForwardingInputTap::DeviceIOProcFunc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* inInputData,
  const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* inClientData)
{
  ForwardingInputTap *me = static_cast<ForwardingInputTap *>(inClientData);
  if (inInputData->mNumberBuffers < 1) return noErr;
  const auto &buffer = inInputData->mBuffers[0];
  const uint32_t channels = me->_format.mChannelsPerFrame;
  if (buffer.mNumberChannels != channels || !buffer.mData) return noErr;
  const float *input = static_cast<const float *>(buffer.mData);
  uint32_t available = buffer.mDataByteSize / (channels * sizeof *input);
  const uint32_t maxFrames = static_cast<uint32_t>(me->_scratch.size() / channels);
  while (available > 0)
  {
    const uint32_t n = std::min(available, maxFrames);
    float *scratch = me->_scratch.data();
    std::memcpy(scratch, input, n * channels * sizeof *input);
    if (me->_process) me->_process(me->_ctx, scratch, n, channels);
    me->_outContext.AppendInputFrames(n, channels, scratch);
    input += n * channels;
    available -= n;
  }
  return noErr;
}
