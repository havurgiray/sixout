// ForwardingInputTap.hpp — reads the tapped input device and forwards frames to the DigitalOutputContext,
// calling a user DSP callback on each block first. Derived from SoundPusher (MIT).
#ifndef ForwardingInputTap_hpp
#define ForwardingInputTap_hpp

#include <vector>
#include <os/log.h>
#include <CoreAudio/CoreAudio.h>
#include "CoreAudioHelper.hpp"
#include "EngineBridge.h"

struct DigitalOutputContext;

struct ForwardingInputTap
{
  ForwardingInputTap(AudioObjectID device, AudioObjectID stream, DigitalOutputContext &outContext, SLProcessFn process, void *ctx);
  ~ForwardingInputTap();
  void Start();
  void Stop();

  const AudioObjectID _device;
  const AudioObjectID _stream;
  const AudioStreamBasicDescription _format;

protected:
  static OSStatus DeviceIOProcFunc(AudioObjectID inDevice, const AudioTimeStamp* inNow,
    const AudioBufferList* inInputData, const AudioTimeStamp* inInputTime, AudioBufferList* outOutputData,
    const AudioTimeStamp* inOutputTime, void* inClientData);

  DigitalOutputContext &_outContext;
  SLProcessFn _process;
  void *_ctx;
  std::vector<float> _scratch;
  os_log_t _log;
  AudioDeviceIOProcID _deviceIOProcID;
  bool _isRunning;
};

#endif
