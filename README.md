# SixOut ❨⑥❩

A native macOS app (Apple silicon, macOS 14.2+) that turns a MacBook into a real 5.1
source for an analog speaker set through an HDMI → optical → Dolby Digital/DTS decoder
chain, and lets you test, rewire, calibrate and tune every channel.

It captures whatever your apps play to the SoundPusher virtual 5.1 device, runs a
processing chain (content detection, stereo upmix, dynamics, bass management,
per-speaker EQ, trims and delays, limiter, wiring fix), encodes the result to AC-3 or
DTS in real time and sends the bitstream out of the HDMI port. While its engine runs it
does the job of the SoundPusher app, which it quits automatically. Built for an analog
5.1 speaker set behind an optical decoder box, but nothing in it is specific to any
particular hardware beyond the defaults.

Highlights: channel test and rewiring, 10-band EQ per speaker with presets, bass
management, stereo-to-5.1 upmix with content detection, compressor and lookahead limiter
with automatic headroom, room calibration with a USB microphone (levels, delays,
polarity, EQ, crossover), listening-position profiles, "turned 90°" 4.1 modes, keyboard
volume keys for the volume-less virtual device, AC-3 or DTS encoding with a vendored,
patched ffmpeg (the DTS encoder's sub-channel bug is fixed here).

```
apps → SoundPusher Audio (virtual 5.1 device)
     → SixOut: tap → content detection → width & upmix → compressor
                  → bass management → EQ → trims → limiter → wiring fix → AC-3/DTS encoder
     → HDMI (USB-C adapter → HDMI EDID emulator → HDMI audio extractor)
     → optical (Toslink) → 5.1 decoder box → 6× RCA → analog 5.1 speaker set
```

## Why this exists

macOS has no built-in real-time Dolby Digital encoder, and an optical link can carry
only stereo PCM or a compressed AC3/DTS bitstream. Discrete 5.1 therefore only reaches
the decoder as AC3. SoundPusher provides the virtual device and the encoder; SixOut
reuses SoundPusher's MIT-licensed core and adds the processing and test tools in front
of the encoder, because a second tap writing back into the same device would double the
audio.

## Requirements

- macOS 14.2 or later on Apple silicon (tested on macOS 26.5, MacBook Air M4).
- The SoundPusher driver (`/Library/Audio/Plug-Ins/HAL/SoundPusherAudio.driver`) from
  the SoundPusher installer at https://codeberg.org/q-p/SoundPusher/releases.
  The SoundPusher **app** may stay installed but is not needed while SixOut runs.
- ffmpeg is vendored: `ffmpeg/install` holds minimal static libraries built from the ffmpeg 8.1
  source with `ffmpeg/build-ffmpeg.sh` (AC-3 and DTS encoders, S/PDIF framing only, no
  Homebrew dependency). The DTS encoder carries `Core/ffmpeg-dcaenc-lfe-history.patch`.
- Xcode Command Line Tools (`xcode-select --install`). No Xcode needed.
- An HDMI output whose EDID advertises AC3. With this chain that is the EDID emulator or
  the extractor's own "5.1" EDID mode. Audio MIDI Setup must list AC3 under
  "Encoded Digital Audio Formats" for the HDMI device.

## Build

```
git clone https://github.com/havurgiray/sixout.git && cd sixout
tools/make-signing-identity.sh   # once per Mac: local signing identity so permissions survive rebuilds
./build.sh                       # first run also builds the vendored ffmpeg libraries (a few minutes)
open build/SixOut.app
```

`./build.sh core` compiles only the native core, useful when porting.

`build.sh` compiles the C++/Objective-C++ core in `Core/`, the Swift sources in
`Sources/`, links the static ffmpeg libraries from `ffmpeg/install`, bundles
`Resources/voices/*.wav` and signs the bundle with the local identity "SixOut Dev"
(falling back to an ad-hoc signature if it is missing). Create that identity once with
`tools/make-signing-identity.sh`: with a stable identity the macOS privacy grants
(system audio, microphone, Accessibility) survive rebuilds, whereas an ad-hoc signature
changes with every build and silently invalidates them. To rebuild the ffmpeg libraries
(for example after editing the patch) run `ffmpeg/build-ffmpeg.sh`; it downloads the
8.1 source, applies the patch and builds in a few minutes with the command-line tools.

Regenerate the voice prompts (they are already included) with
`say -o Resources/voices/L.wav --data-format=LEI16@48000 "front left"` and so on for
R, C, LFE, Ls, Rs.

## First launch

1. Start the app from Finder or with `open build/SixOut.app`. Do not run the
   binary from a terminal: macOS then never shows the permission prompt and the tap
   delivers silence.
2. macOS asks whether SixOut may record system audio. Click **Allow**. If the
   engine was already running when you allowed it, click **Stop** and **Start** once.
3. The engine starts automatically (Setup tab → "Start the engine when SixOut
   opens"). The status line should read "Running → HDMI …" and "HDMI: bitstream, <codec>".
4. Turn the speaker volume down before the first test. If any box in the chain
   misreads the AC3 stream as PCM, it plays as loud static.

With the "SixOut Dev" signing identity in place, the permission survives rebuilds. Without
it (ad-hoc signature) macOS asks again after each rebuild.

## Using the app

### Test & Wiring

1. **Verify each speaker** plays a voice that says its own name, routed through the
   current wiring table. "Play all in order" cycles through all six. Each button has a
   pink-noise variant and a live meter.
2. **Identify what is wired where** plays each decoder output (the AC3 channel that
   reaches the decoder's FL, FR, C, SW, SL, SR jack). Pick the speaker you actually
   heard, then **Apply wiring fix**. The app computes the routing that puts every
   channel on the right speaker. It refuses a mapping that names one speaker twice.
3. **Wiring table** shows, per decoder output, which channel it carries, with quick
   swaps for the usual mistakes (center ⇄ sub, left ⇄ right, surround L ⇄ R).

The subwoofer test adds a 50 Hz tone under the voice so the sub is audible.

The Levels box shows peak dBFS. The input side is what apps send to the SoundPusher
device, which has no volume control, so streaming content sits near 0 dB most of the
time; that is normal. Red means within 0.5 dB of full scale, and a separate note appears
if the source itself is clipping. Set loudness at the speakers.

### EQ & Bass

- **EQ presets**: name the current EQ (optionally with the bass-management block) and
  save it; load or delete saved presets from the picker. Stored in `eq-presets.json` next
  to the settings. The live settings are still saved automatically on every change.
- Ten bands per speaker (31.5 Hz low shelf, 63 Hz to 8 kHz peaks, 16 kHz high shelf),
  ±12 dB. Copy one speaker's curve to all, or reset.
- **Bass management**: high-passes the five satellites at the crossover (Linkwitz-Riley
  4th order) and sends their bass to the sub. The crossover is capped at 120 Hz because
  the AC3 encoder low-passes the LFE channel there; bass redirected above 120 Hz would
  be lost. On speaker sets whose sub box already takes the bass of every input (most PC
  5.1 sets), the section is largely redundant: 80–100 Hz or off are both fine. **LFE gain**
  scales a source's discrete LFE track only; the film convention adds +10 dB there, and the
  calibration measures what your decoder and sub level need. Sub low-pass limits what the
  sub gets.
- **Speaker trims**: gain, mute, polarity invert and delay (distance compensation) per
  speaker.

- **Sub channel**: Auto (default), Send on the LFE channel, or Fold into the front channels.
  Auto now sends the LFE channel for both codecs, because the vendored DTS encoder carries a
  fix for a real ffmpeg bug: for 5.1 input its channel table has no entry for the LFE, so the
  history routine read one sample before the input buffer (an intermittent crash at page
  boundaries) and stored another channel's samples as LFE history, which made the decoded
  sub channel 5–7 dB low and distorted. With the fix (`Core/ffmpeg-dcaenc-lfe-history.patch`)
  the sub channel measures as cleanly as the other channels (52 dB signal-to-error, from 3 dB).
  The DTS decimation/interpolation pair leaves the sub 1.6 dB low, which the app compensates. Folding remains available; on speaker
  sets whose sub box takes the front input's bass to the same driver it costs nothing.

### Spatial & Dynamics

- **Listening orientation**: Normal 5.1, Turned 90° left, Turned 90° right. The turned modes are
  4.1: the content is remapped to the speakers around the turned listener (turned left: the old
  surround-left and front-left speakers become the front pair, the old surround-right and
  front-right the rear pair; turned right is the mirror), the center speaker is silent, and
  center content plays as a phantom center between the new front pair (level adjustable,
  −3 dB default). The remap sits after the upmix and before the per-speaker EQ, trims and
  delays, so corrections stay with their physical speaker. Also switchable from the menu bar.
- **Content detection** classifies the incoming audio as silence, stereo or 5.1 from the
  level in the center, LFE and surround channels.
- **Upmix** Off / Auto / Always. Auto engages only for stereo content after 300 ms.
  Center is derived from L+R, surrounds from a Pro Logic II style L−R matrix with a
  7 kHz low-pass and adjustable delay, LFE from low-passed L+R when bass management is
  off. Width scales the fronts' side signal; dialogue enhance boosts the center.
- **Compressor**: linked across channels, threshold/ratio/attack/release/makeup, with
  presets Off, Music glue, Gentle evening, TV & dialogue and Night mode (strong). The line
  under the presets names the one currently in use and what it does.
- **Limiter**: lookahead brickwall limiter, linked across the five satellites with a separate
  detector for the sub so bass peaks never duck the satellites. Keep it on; the AC3 encoder
  clips hard.
- **Auto headroom** (on by default) watches the limiter's gain reduction. More than 6 dB
  of limiting within a second backs the gain off by 1 dB at once; limiting above 1 dB for
  more than 30% of the time backs it off by 0.5 dB; after 20 s of idle limiter with audio
  playing it restores 0.25 dB every 5 s, up to 0 dB. The current value is shown and
  persisted; a floor slider limits how far it may go. A gain-reduction meter and a
  clipping counter sit next to it. If the result is too quiet, turn the speakers up
  rather than the master gain.
- **Presets**: Flat, Movie, Night mode, Music.

### Listening position profiles

A profile stores what a calibration produced for one seat: trims, delays, polarity, sub
level, bass management and the orientation used there, optionally the EQ. Save the current
state under a name (Calibrate tab or EQ & Bass tab), load or delete it later; stored in
`speaker-profiles.json` next to the settings. Trims and delays belong to the physical
speakers and are applied after the orientation remap, so they stay valid in the turned
modes as long as you sit where the microphone was. A different seat needs its own
calibration and its own profile.

### Calibrate (room measurement with a USB microphone)

Works with any class-compliant USB input, for example a handheld recorder in USB audio
interface mode, placed at ear height on the listening seat with the mics facing the
screen.

1. Pick the input device and, optionally, switch on "Monitor level" to see the ambient
   noise and find a quiet moment.
2. Set the test level (−12 dBFS default), sweeps per speaker (3) and sweep length (4 s),
   then click **Start calibration** while the engine is running. The app measures the
   background noise for 3 s, then plays exponential sine sweeps on every speaker through
   the real chain with all processing bypassed (the wiring fix stays active).
3. Each recording is deconvolved to an impulse response. Stationary noise such as
   traffic mostly falls out of the deconvolution; the sweeps are repeated and combined
   with a median so a typing burst spoils at most one pass; bands whose signal-to-noise
   margin is below 10 dB are shown grey and left uncorrected.
4. The results table lists, per speaker, whether a response was found, its level,
   arrival time, polarity, the suggested trim and delay, and the left/right balance at
   the recorder's two microphones (a hint for swapped pairs or a recorder facing the
   wrong way). The graph shows the third-octave response and the proposed EQ curve.
5. Tick what to apply (trims, delays, EQ, crossover and bass management, sub level,
   polarity) and click **Apply to settings**. **Revert** restores the settings saved
   automatically before the run.


**Polarity pair test.** The polarity column in the results table is only the sign of
the impulse peak, which is unreliable for the sub (its response is a slow low-passed
wobble) and can be fooled by desk or wall reflections on satellites. The pair test in
the same tab plays each speaker together with Front left, once as wired and once
inverted, with the measured delays and trims applied, and keeps the polarity that sums
louder in the overlap band (80–400 Hz for satellites, 40–160 Hz for the sub). Conclusive
verdicts (at least 1.5 dB difference) become the Polarity suggestion; tick Polarity and
Apply to use them.

The microphone is not calibrated for absolute level, so all levels are relative. The
sub level suggestion sets the LFE gain so the sub's 40–100 Hz band matches the
satellites' midband. Results are stored in `calibration.json` next to the settings.

### Volume keys

The SoundPusher virtual device has no volume control, so macOS shows the "no volume"
bezel for it. With "Volume keys control SixOut" (Setup tab, on by default) the app takes
the keyboard volume keys whenever the system output is "SoundPusher Audio", applies the
volume as the last stage of its own chain (a perceptual curve: 50 % ≈ −12 dB, 25 % ≈ −24 dB) and shows a
bezel like macOS. Other output devices are untouched. Steps are 1/16 per press, 1/64 with
Shift+Option, and the mute key toggles mute. macOS requires the Accessibility permission
for this (System Settings → Privacy & Security → Accessibility). The app asks for it on
launch while the option is on, and keeps retrying the key listener until it is granted. The status bar has a volume
slider and mute button as well.

### Setup

Output device picker (any device that offers AC3), encoder choice (AC-3 640 kbit/s or
DTS 1509 kbit/s through ffmpeg's experimental DTS encoder; changing it restarts the engine
automatically, and levels should be re-calibrated after switching). Measured on a 5.1 test
signal: DTS leaves about 9 dB less coding error than AC-3 on broadband channels and 22 dB
less on speech; the AC-3 coupling and cutoff options and the DTS ADPCM option change
nothing measurable at these rates. the intermittent crash of ffmpeg's DTS encoder was traced to the same LFE history bug (a read one sample before the input buffer) and is fixed by the vendored patch (24 of 24 runs on every input class), IOCycle safety factor (raise it if you
hear dropouts, then restart the engine), SoundPusher app status with quit/relaunch
buttons, autostart, launch at login, and the engine log.

## Settings and self-test

Settings live in `~/Library/Application Support/SixOut/settings.json`, saved half a
second after every change and again on engine stop and on quit. Files written by older
builds load fine (a folder from the earlier app name is migrated automatically): missing keys take their defaults instead of rejecting the file, and an
unreadable file is kept as `settings.unreadable.json`. Delete the file to reset everything.

```
open build/SixOut.app --args --selftest
```

starts the engine, plays the six voices through the whole chain, and after 12 seconds
writes `selftest.log` next to the settings file with the HDMI format and the peak level
seen per input and output channel, then quits. Play a 5.1 file to the SoundPusher device
during the run to verify the capture side.

## Tests

- `tests/run-dsp-tests.sh` compiles the real DSP with a test driver and checks the orientation
  remap (both turned modes, phantom center level, wiring-table interaction, bypass, trims and
  delays) and the volume stage (curve, mute, bypass) by feeding a distinct tone per content
  channel and measuring what each output slot carries.
- `open build/SixOut.app --args --selftest` exercises the whole chain through the real devices
  (see above).
- The encoder path can be checked offline with the harness described in the commit history of
  `Core/SPDIFAudioEncoder.cpp`; the vendored DTS fix was verified to 52 dB sub-channel
  signal-to-error and 24 of 24 crash-free runs.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "No HDMI output with an AC3 format" | The HDMI chain is not connected, or the EDID lacks AC3. Set the extractor to its 5.1 EDID mode or put the EDID emulator inline. Check Audio MIDI Setup. |
| Engine runs, meters stay at zero while apps play | System-audio-recording permission missing, or granted after the engine started. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then Stop/Start. Also make sure the system output is "SoundPusher Audio". |
| Loud static | A device downstream is in PCM mode. Set the extractor to 5.1/bitstream and the decoder to 5.1. |
| "Could not obtain exclusive access to device" | Another process holds the HDMI device, usually the SoundPusher app. Quit it (Setup tab). |
| Only stereo on the speakers | Upmix off and the source is stereo, or the source app is downmixing. Check the content detector. |
| "SoundPusher Audio" missing | The driver is not installed, or neither SixOut nor SoundPusher is running to unhide it. |
| Sound stops when SixOut quits | Expected. Relaunch it or the SoundPusher app. |
| Third display refused | The M4 Air allows two external displays and the extractor counts as one. |

### Why the sound output says "SoundPusher Audio"

That is expected. Apps play into the SoundPusher virtual device; SixOut taps it, processes
the audio, encodes AC3 and drives the HDMI port itself. The system output must stay on
"SoundPusher Audio" for the chain to work.

### If a calibration reports speakers as "no usable recording"

The microphone stream ended before those sweeps were played. The run now watches the
recorder between sweeps and aborts with a message if the stream stalls, restarts the
capture engine after a Core Audio configuration change, and reports how long the
recording actually was. Typical causes: the recorder switching mode or sample rate,
USB re-enumeration, or the recorder powering down. Keep it on USB power and in
interface mode, and start the run only once "Monitor level" shows a live signal.

### UI performance

Live values (meters, gain reduction, detection state) are published 20 times per second
on a separate `LiveMeters` object observed only by the small meter views, so the settings
views are not rebuilt on every tick. If the window ever stutters again, sample the process
(`sample SixOut 3`) and look for SwiftUI layout work on the main thread.

## Ideas for later

- **LPCM 5.1 direct output mode** (for an AV receiver or an HDMI-to-5.1-analog decoder box with
  LPCM 5.1/7.1 decoding). Today the output stage always encodes to AC-3/DTS because optical can
  carry nothing else. With an LPCM-capable HDMI sink, add a third output choice next to AC-3 and
  DTS: open the HDMI device in its 6-channel (or 8-channel) 48 kHz PCM format instead of the
  IEC 61937 bitstream format and write the processed frames directly (the DigitalOutputContext's
  ring buffer and IOProc stay, the encoder step goes). Map channels by the device's own labels:
  the HDMI layout is L R LFE C Ls Rs, i.e. sub before center. Everything upstream (tap, wiring
  fix, calibration, EQ, orientation modes, volume keys, profiles) is unchanged; latency drops by
  roughly 100 ms. Roughly 150 lines native plus the picker. With a receiver, its own bass
  management and LFE handling apply, so re-run the calibration after switching.

- **MacBook speakers as center in the turned (4.1) modes.** Feed the center content to the
  built-in speakers as a second CoreAudio output while everything else goes through the
  AC-3/DTS chain. Needs: a delay on the laptop feed equal to the main chain's latency (about
  100–130 ms; measurable with the calibration mic by sweeping one front speaker and the laptop
  and comparing arrival times), drift compensation because the HDMI device and the built-in
  speakers run on different clocks (fill-level controlled fractional resampler, a few hundred
  ppm), a high-pass around 150 Hz with the bass staying in the main chain, its own trim, the
  laptop's hardware volume pinned with SixOut's volume applied digitally, and automatic fallback
  to the phantom center when the device disappears (lid closed, sleep). UI: a "Center output"
  choice (real center / phantom / MacBook speakers), a center-delay slider with a Measure
  button, a level trim. Limits: mono center placed wherever the laptop stands; system alert
  sounds routed to the built-in speakers would mix in.

## Project layout

```
Core/                     native core (C++/Objective-C++), derived from SoundPusher (MIT)
  AudioTap.{h,mm}         Core Audio process tap + private aggregate device
  ForwardingInputTap.*    tap IOProc; calls the Swift DSP callback, then feeds the encoder
  DigitalOutputContext.*  hogs the HDMI device, sets the AC3 format, output IOProc
  SPDIFAudioEncoder.*     AC3 encode (libavcodec) + IEC 61937 framing (libavformat spdif), ported to FFmpeg 8
  CoreAudioHelper.*       device/stream/format helpers, default-device and hog RAII
  EngineBridge.{h,mm}     C API used by Swift: start/stop chain, box acquire
  TPCircularBuffer/       lock-free ring buffer
Sources/
  DSP.swift               real-time chain (biquads, upmix, compressor, limiter, routing, test injection, detection)
  Settings.swift          Codable settings, presets, JSON persistence, parameter conversion
  Engine.swift            engine controller, meters, device queries, SoundPusher app handling
  TestSignals.swift       voice and pink-noise buffers
  Views.swift             SwiftUI tabs
  EQPresets.swift         named EQ presets (save / load / delete)
  SpeakerProfiles.swift   listening position profiles (trims, delays, polarity, sub, orientation)
  SweepMath.swift         sine sweeps, inverse filter, FFT deconvolution, third-octave analysis
  MicCapture.swift        AVAudioEngine input capture from a chosen device with a sample timeline
  Calibration.swift       measurement run, analysis, suggestions, apply/revert
  CalibrationView.swift   Calibrate tab
  App.swift               app entry, menu bar extra, --selftest
  MediaKeys.swift         volume-key event tap and the volume bezel
Resources/voices/         L R C LFE Ls Rs announcement files
Info.plist, build.sh
tests/                           DSP unit tests (run-dsp-tests.sh)
tools/make-signing-identity.sh   creates the local signing identity used by build.sh
ffmpeg/build-ffmpeg.sh           rebuilds the vendored patched ffmpeg libraries
```

Channel order everywhere is L, R, C, LFE, Ls, Rs (CoreAudio AudioUnit 5.1 layout).

Threads: capture and DSP run on the Core Audio real-time thread of the tap aggregate
device; AC3 encoding and HDMI output run on the real-time thread of the HDMI device,
decoupled by a lock-free ring buffer; the microphone runs on AVAudioEngine's thread; the
UI on the main thread. Parameters are handed to the DSP as a fixed-size struct under a
try-lock and all audio buffers are preallocated, so nothing on the audio threads
allocates or blocks. The per-block DSP costs about one percent of a core, so it is
deliberately not split across cores (that would only add latency). Calibration analysis
runs off the main thread and fans the deconvolutions out over all cores with
`DispatchQueue.concurrentPerform`, with the inverse filter's spectrum computed once.

## Credits and licenses

- SixOut is released under the MIT license (`LICENSE`).
- SoundPusher by Daniel Vollmer, MIT license (`Core/LICENSE-SoundPusher.txt`):
  https://codeberg.org/q-p/SoundPusher
- FFmpeg (libavcodec, libavformat, libswresample, libavutil), LGPL, built from the 8.1
  source as static libraries with one local patch (`Core/ffmpeg-dcaenc-lfe-history.patch`,
  also worth submitting upstream: master still has the bug).
- TPCircularBuffer by Michael Tyson.
