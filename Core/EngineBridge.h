// EngineBridge.h — plain C interface between the Swift app and the native tap/encoder core.
#ifndef EngineBridge_h
#define EngineBridge_h
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

/// Called on the real-time audio thread with interleaved float frames (L R C LFE Ls Rs); process in place.
typedef void (*SLProcessFn)(void *ctx, float *interleaved, uint32_t frames, uint32_t channels);
/// Called on the main thread for engine events. code 1 = a device disappeared and the engine stopped.
typedef void (*SLEventFn)(void *ctx, int code, const char *message);

/// Makes the SoundPusher virtual device visible (needed while the SoundPusher app is not running).
bool sl_acquire_box(const char *boxUID, char *errBuf, int errBufLen);
void sl_release_box(void);

/// Starts tap -> process -> AC3 -> digital output. Returns 0 on success, otherwise fills errBuf.
/// codec: 0 = AC-3 (640 kbit/s), 1 = DTS (1509 kbit/s, experimental encoder). bitRate 0 = codec default.
int sl_engine_start(const char *inDeviceUID, const char *outDeviceUID, double ioCycleSafetyFactor,
                    bool driftCompensation, int codec, int bitRate, SLProcessFn process, SLEventFn event, void *ctx,
                    char *errBuf, int errBufLen);
/// Name and bit rate of the running encoder, e.g. "ac3" and 640000.
const char *sl_engine_codec_name(void);
int sl_engine_bit_rate(void);
void sl_engine_stop(void);
bool sl_engine_is_running(void);
uint32_t sl_engine_frames_per_packet(void);
double sl_engine_sample_rate(void);

#ifdef __cplusplus
}
#endif
#endif
