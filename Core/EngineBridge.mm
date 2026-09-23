// EngineBridge.mm — assembles the forwarding chain (tap aggregate -> DSP -> AC3 -> HDMI) behind a C API.
#import <Foundation/Foundation.h>
#include <memory>
#include <optional>
#include <cstring>
#include <string>
#include "EngineBridge.h"
#include "CoreAudioHelper.hpp"
#include "DigitalOutputContext.hpp"
#include "ForwardingInputTap.hpp"
#import "AudioTap.h"

namespace {

static const AudioObjectPropertyAddress DeviceAliveAddress = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

struct Chain;
static OSStatus DeviceAliveListenerFunc(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *);

struct Chain
{
  Chain(NSString *inUID, NSInteger inStreamIndex, AudioObjectID inDevice, AudioObjectID outDevice, AudioObjectID outStream,
        const AudioStreamBasicDescription &outFormat, bool drift, int codec, int bitRate, SLProcessFn process, void *ctx)
  : _defaultDevice(inDevice)
  , _tapped(AudioTap(inUID, inStreamIndex), drift)
  , _output(outDevice, outStream, outFormat, kAudioChannelLayoutTag_AudioUnit_5_1, false, codec, bitRate)
  , _input(_tapped._aggregateDevice, 0, _output, process, ctx)
  {
    AudioObjectAddPropertyListener(_output._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    AudioObjectAddPropertyListener(_input._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
  }
  ~Chain()
  {
    AudioObjectRemovePropertyListener(_input._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    AudioObjectRemovePropertyListener(_output._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
  }
  CAHelper::DefaultDeviceChanger _defaultDevice;
  AggregateTappedDevice _tapped;
  DigitalOutputContext _output;
  ForwardingInputTap _input;
};

std::unique_ptr<Chain> g_chain;
std::optional<CAHelper::DeviceBoxAcquirer> g_box;
SLEventFn g_event = nullptr;
void *g_eventCtx = nullptr;

static OSStatus DeviceAliveListenerFunc(AudioObjectID inObjectID, UInt32, const AudioObjectPropertyAddress *, void *inClientData)
{
  UInt32 alive = 1, size = sizeof alive;
  AudioObjectGetPropertyData(inObjectID, &DeviceAliveAddress, 0, NULL, &size, &alive);
  if (alive) return noErr;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_chain && g_chain.get() == inClientData)
    {
      g_chain.reset();
      if (g_event) g_event(g_eventCtx, 1, "An audio device disappeared; the engine stopped.");
    }
  });
  return noErr;
}

static void SetError(char *errBuf, int errBufLen, const std::string &msg)
{
  if (!errBuf || errBufLen <= 0) return;
  std::strncpy(errBuf, msg.c_str(), errBufLen - 1);
  errBuf[errBufLen - 1] = '\0';
}

static AudioObjectID FindDeviceByUID(const std::string &uid)
{
  for (const auto device : CAHelper::GetDevices())
  {
    CFStringRef s = nullptr;
    try { s = CAHelper::GetStringProperty(device, CAHelper::DeviceUIDAddress); } catch (...) { continue; }
    NSString *ns = CFBridgingRelease(s);
    if (std::string(ns.UTF8String) == uid) return device;
  }
  return kAudioObjectUnknown;
}

} // namespace

bool sl_acquire_box(const char *boxUID, char *errBuf, int errBufLen)
{
  try
  {
    g_box.reset();
    CFStringRef s = CFStringCreateWithCString(nullptr, boxUID, kCFStringEncodingUTF8);
    g_box.emplace(s);
    CFRelease(s);
    return true;
  }
  catch (const std::exception &e) { SetError(errBuf, errBufLen, e.what()); return false; }
}

void sl_release_box(void) { g_box.reset(); }

int sl_engine_start(const char *inDeviceUID, const char *outDeviceUID, double ioCycleSafetyFactor, bool driftCompensation,
                    int codec, int bitRate, SLProcessFn process, SLEventFn event, void *ctx, char *errBuf, int errBufLen)
{
  try
  {
    g_chain.reset();
    g_event = event; g_eventCtx = ctx;

    const AudioObjectID inDevice = FindDeviceByUID(inDeviceUID);
    if (inDevice == kAudioObjectUnknown) { SetError(errBuf, errBufLen, std::string("Source device not found: ") + inDeviceUID); return -1; }
    const AudioObjectID outDevice = FindDeviceByUID(outDeviceUID);
    if (outDevice == kAudioObjectUnknown) { SetError(errBuf, errBufLen, std::string("Digital output device not found: ") + outDeviceUID); return -2; }

    // source: first output stream offering 6-channel native float LPCM at 48 kHz
    NSInteger inStreamIndex = -1;
    {
      const auto streams = CAHelper::GetStreams(inDevice, false);
      for (std::size_t i = 0; i < streams.size() && inStreamIndex < 0; ++i)
        for (const auto &f : CAHelper::GetStreamPhysicalFormats(streams[i], 48000.0))
          if (f.mFormatID == kAudioFormatLinearPCM && f.mChannelsPerFrame == 6 && f.mFramesPerPacket == 1 && f.mFormatFlags == kAudioFormatFlagsNativeFloatPacked)
          { inStreamIndex = static_cast<NSInteger>(i); break; }
    }
    if (inStreamIndex < 0) { SetError(errBuf, errBufLen, "Source device has no 6-channel float stream at 48 kHz"); return -3; }

    // output: first stream with an AC3 (IEC 60958) format at 48 kHz
    AudioObjectID outStream = kAudioObjectUnknown;
    AudioStreamBasicDescription outFormat = {};
    {
      const auto streams = CAHelper::GetStreams(outDevice, false);
      for (const auto s : streams)
      {
        for (const auto &f : CAHelper::GetStreamPhysicalFormats(s, 48000.0))
          if (f.mFormatID == kAudioFormat60958AC3 || f.mFormatID == kAudioFormatAC3 || f.mFormatID == 'IAC3' || f.mFormatID == 'iac3')
          { outStream = s; outFormat = f; break; }
        if (outStream != kAudioObjectUnknown) break;
      }
    }
    if (outStream == kAudioObjectUnknown) { SetError(errBuf, errBufLen, "Output device offers no AC3 format at 48 kHz (check the HDMI EDID)"); return -4; }

    DigitalOutputContext::SetIOCycleSafetyFactor(ioCycleSafetyFactor);
    NSString *inUID = [NSString stringWithUTF8String:inDeviceUID];
    g_chain = std::make_unique<Chain>(inUID, inStreamIndex, inDevice, outDevice, outStream, outFormat, driftCompensation, codec, bitRate, process, ctx);
    g_chain->_output.SetUpmix(false);
    g_chain->_input.Start();
    g_chain->_output.Start();
    return 0;
  }
  catch (const std::exception &e)
  {
    g_chain.reset();
    SetError(errBuf, errBufLen, e.what());
    return -10;
  }
}

void sl_engine_stop(void) { g_chain.reset(); }
const char *sl_engine_codec_name(void) { return g_chain ? g_chain->_output.GetCodecName() : "-"; }
int sl_engine_bit_rate(void) { return g_chain ? g_chain->_output.GetBitRate() : 0; }
bool sl_engine_is_running(void) { return g_chain != nullptr; }
uint32_t sl_engine_frames_per_packet(void) { return g_chain ? g_chain->_output.GetNumFramesPerPacket() : 0; }
double sl_engine_sample_rate(void) { return g_chain ? g_chain->_output.GetInputFormat().mSampleRate : 0.0; }
