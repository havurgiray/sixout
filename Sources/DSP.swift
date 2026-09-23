import Foundation
import os.lock

let kChannels = 6
let kBands = 10
let kBandFreqs: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let kBandNames = ["31 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
let kMaxChannelDelay = 2400
let kLimiterLookahead = 64
let kMaxDelayFrames = 4800

@inline(__always) func dbToLin(_ db: Float) -> Float { powf(10, db / 20) }
@inline(__always) func linToDb(_ v: Float) -> Float { v > 1e-9 ? 20 * log10f(v) : -180 }

/// RBJ biquad, transposed direct form II.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    mutating func reset() { z1 = 0; z2 = 0 }
    mutating func set(_ b0: Float, _ b1: Float, _ b2: Float, _ a0: Float, _ a1: Float, _ a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }
    static func identity() -> Biquad { Biquad() }
    static func peak(fs: Float, f0: Float, q: Float, gainDB: Float) -> Biquad {
        var f = Biquad(); let A = powf(10, gainDB / 40); let w = 2 * Float.pi * f0 / fs; let c = cosf(w); let al = sinf(w) / (2 * q)
        f.set(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A); return f
    }
    static func lowShelf(fs: Float, f0: Float, q: Float, gainDB: Float) -> Biquad {
        var f = Biquad(); let A = powf(10, gainDB / 40); let w = 2 * Float.pi * f0 / fs; let c = cosf(w); let al = sinf(w) / (2 * q); let sa = 2 * sqrtf(A) * al
        f.set(A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sa), (A + 1) + (A - 1) * c + sa, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa); return f
    }
    static func highShelf(fs: Float, f0: Float, q: Float, gainDB: Float) -> Biquad {
        var f = Biquad(); let A = powf(10, gainDB / 40); let w = 2 * Float.pi * f0 / fs; let c = cosf(w); let al = sinf(w) / (2 * q); let sa = 2 * sqrtf(A) * al
        f.set(A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sa), (A + 1) - (A - 1) * c + sa, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa); return f
    }
    static func lowpass(fs: Float, f0: Float, q: Float) -> Biquad {
        var f = Biquad(); let w = 2 * Float.pi * f0 / fs; let c = cosf(w); let al = sinf(w) / (2 * q)
        f.set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al); return f
    }
    static func highpass(fs: Float, f0: Float, q: Float) -> Biquad {
        var f = Biquad(); let w = 2 * Float.pi * f0 / fs; let c = cosf(w); let al = sinf(w) / (2 * q)
        f.set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al); return f
    }
}

/// Fixed-size, trivially copyable parameter block handed to the audio thread.
struct DSPParams {
    var version: UInt32 = 0
    var bypass = false
    var masterGain: Float = 1
    var route = SIMD8<Int32>(0, 1, 2, 3, 4, 5, 0, 0)
    var outGain = SIMD8<Float>(repeating: 1)
    var outMute = SIMD8<UInt8>(repeating: 0)
    var outInvert = SIMD8<UInt8>(repeating: 0)
    var eqEnabled = false
    var eqChannelEnabled = SIMD8<UInt8>(repeating: 1)
    var eqGains = SIMD64<Float>(repeating: 0)   // index ch*10 + band
    var chDelay = SIMD8<Int32>(repeating: 0)     // per-speaker delay in frames
    var bassEnabled = false
    var crossoverHz: Float = 100
    var lfeGain: Float = 1
    var lfeLowpassHz: Float = 120
    var redirectBass = true
    var upmixMode: Int32 = 1
    var centerGain: Float = 0.707
    var surroundGain: Float = 0.5
    var surroundDelayFrames: Int32 = 576
    var width: Float = 1
    var dialogGain: Float = 1
    var compEnabled = false
    var compThreshold: Float = 0.125
    var compRatio: Float = 3
    var compAttackCoef: Float = 0.002
    var compReleaseCoef: Float = 0.0001
    var compMakeup: Float = 1
    var limEnabled = true
    var limCeiling: Float = 0.944
    var limReleaseCoef: Float = 0.00026
    var autoGain: Float = 1            // headroom gain applied just before the limiter (≤ 1)
    var foldLFE = false                // send the sub signal on the front channels instead of the LFE channel
    var volume: Float = 1              // SixOut's own volume (the virtual device has none), applied last
    var orientation: Int32 = 0         // 0 normal, 1 turned 90° left, 2 turned 90° right (4.1: center silent)
    var phantomCenterGain: Float = 0.707
}

/// A test signal request: a mono buffer injected on one output slot.
struct TestCommand {
    var serial: UInt32 = 0
    var active = false
    var slot: Int32 = 0
    var slot2: Int32 = -1       // optional second channel that receives the same signal
    var pre = false             // true: inject into the content channels before processing; false: after the wiring fix
    var samples: UnsafePointer<Float>? = nil
    var count: Int32 = 0
    var gain: Float = 0.25
    var subTone = false
}

/// Real-time processing state. Everything used on the audio thread is preallocated.
/// Marked Sendable because all cross-thread access goes through the lock or through plain atomically-written scalars.
final class Processor: @unchecked Sendable {
    // parameter hand-off
    private var lock = os_unfair_lock()
    private var pending = DSPParams()
    private var pendingTest = TestCommand()
    private var P = DSPParams()
    private var lastVersion: UInt32 = 0
    private var test = TestCommand()
    private var testPos: Int = 0
    private var testSerialDone: UInt32 = 0
    private var testPhase: Float = 0
    /// mach_absolute_time() of the first frame of the current test signal, for calibration timing
    private(set) var testStartHostTime: UInt64 = 0
    private(set) var fs: Float = 48000

    // filters
    private let eq = UnsafeMutablePointer<Biquad>.allocate(capacity: kChannels * kBands)
    private let bmHP = UnsafeMutablePointer<Biquad>.allocate(capacity: kChannels * 2)
    private let bmLFELP = UnsafeMutablePointer<Biquad>.allocate(capacity: 2)
    private let bmBassLP = UnsafeMutablePointer<Biquad>.allocate(capacity: 2)
    private let surLP = UnsafeMutablePointer<Biquad>.allocate(capacity: 2)
    private let upLFELP = UnsafeMutablePointer<Biquad>.allocate(capacity: 2)
    private let delayL = UnsafeMutablePointer<Float>.allocate(capacity: kMaxDelayFrames)
    private let delayR = UnsafeMutablePointer<Float>.allocate(capacity: kMaxDelayFrames)
    private var delayPos = 0
    private let limDelay = UnsafeMutablePointer<Float>.allocate(capacity: kChannels * kLimiterLookahead)
    private let chDelayBuf = UnsafeMutablePointer<Float>.allocate(capacity: kChannels * kMaxChannelDelay)
    private var chDelayPos = 0
    private var limPos = 0
    private var limEnv: Float = 1
    private var limEnvLFE: Float = 1
    private var compEnv: Float = 0
    private var upmixAmt: Float = 0
    private var upmixTarget: Float = 0
    private var outGainSm = SIMD8<Float>(repeating: 1)
    private var masterSm: Float = 1
    private var dialogSm: Float = 1
    private var autoGainSm: Float = 1
    private var volumeSm: Float = 1

    // limiter / clipping statistics, read and reset by the UI thread
    var limGRMaxDB: Float = 0          // peak gain reduction since last read
    var limActiveFrames: Int = 0       // frames with more than 1 dB of gain reduction since last read
    var limTotalFrames: Int = 0        // frames processed since last read
    var clipCount: Int = 0             // samples that hit the hard clamp since last read
    var limGRNowDB: Float = 0          // gain reduction at the end of the last block
    var inClipCount: Int = 0           // input samples at or above full scale (the source app is clipping)

    // detection
    private var detLevel = SIMD8<Float>(repeating: 0)
    private var stereoFrames: Int = 0
    /// 0 silence, 1 stereo, 2 multichannel — read by the UI
    var contentClass: Int32 = 0
    var upmixActive: Float = 0

    // meters, read by the UI
    let inPeak = UnsafeMutablePointer<Float>.allocate(capacity: kChannels)
    let outPeak = UnsafeMutablePointer<Float>.allocate(capacity: kChannels)
    var testFinishedSerial: UInt32 { testSerialDone }

    init() {
        for i in 0..<(kChannels * kBands) { eq[i] = Biquad() }
        for i in 0..<(kChannels * 2) { bmHP[i] = Biquad() }
        for i in 0..<2 { bmLFELP[i] = Biquad(); bmBassLP[i] = Biquad(); surLP[i] = Biquad(); upLFELP[i] = Biquad() }
        delayL.initialize(repeating: 0, count: kMaxDelayFrames)
        delayR.initialize(repeating: 0, count: kMaxDelayFrames)
        limDelay.initialize(repeating: 0, count: kChannels * kLimiterLookahead)
        chDelayBuf.initialize(repeating: 0, count: kChannels * kMaxChannelDelay)
        inPeak.initialize(repeating: 0, count: kChannels)
        outPeak.initialize(repeating: 0, count: kChannels)
        rebuildFilters()
    }

    func update(_ params: DSPParams) {
        os_unfair_lock_lock(&lock)
        pending = params
        pending.version = lastVersionPushed &+ 1
        lastVersionPushed = pending.version
        os_unfair_lock_unlock(&lock)
    }
    private var lastVersionPushed: UInt32 = 0

    func setTest(_ cmd: TestCommand) {
        os_unfair_lock_lock(&lock)
        pendingTest = cmd
        os_unfair_lock_unlock(&lock)
    }

    private func rebuildFilters() {
        let fs = self.fs
        for c in 0..<kChannels {
            for b in 0..<kBands {
                let g = P.eqGains[c * kBands + b]
                var f: Biquad
                switch b {
                case 0: f = Biquad.lowShelf(fs: fs, f0: kBandFreqs[0], q: 0.707, gainDB: g)
                case kBands - 1: f = Biquad.highShelf(fs: fs, f0: kBandFreqs[kBands - 1], q: 0.707, gainDB: g)
                default: f = Biquad.peak(fs: fs, f0: kBandFreqs[b], q: 1.4, gainDB: g)
                }
                f.z1 = eq[c * kBands + b].z1; f.z2 = eq[c * kBands + b].z2
                eq[c * kBands + b] = f
            }
            for k in 0..<2 {
                var f = Biquad.highpass(fs: fs, f0: P.crossoverHz, q: 0.707)
                f.z1 = bmHP[c * 2 + k].z1; f.z2 = bmHP[c * 2 + k].z2
                bmHP[c * 2 + k] = f
            }
        }
        for k in 0..<2 {
            var a = Biquad.lowpass(fs: fs, f0: P.lfeLowpassHz, q: 0.707); a.z1 = bmLFELP[k].z1; a.z2 = bmLFELP[k].z2; bmLFELP[k] = a
            var b = Biquad.lowpass(fs: fs, f0: P.crossoverHz, q: 0.707); b.z1 = bmBassLP[k].z1; b.z2 = bmBassLP[k].z2; bmBassLP[k] = b
            var c = Biquad.lowpass(fs: fs, f0: 7000, q: 0.707); c.z1 = surLP[k].z1; c.z2 = surLP[k].z2; surLP[k] = c
            var d = Biquad.lowpass(fs: fs, f0: 120, q: 0.707); d.z1 = upLFELP[k].z1; d.z2 = upLFELP[k].z2; upLFELP[k] = d
        }
    }

    /// Audio-thread entry point. Interleaved L R C LFE Ls Rs.
    func process(_ buf: UnsafeMutablePointer<Float>, _ frames: Int, _ channels: Int) {
        guard channels == kChannels, frames > 0 else { return }
        if os_unfair_lock_trylock(&lock) {
            if pending.version != lastVersion { P = pending; lastVersion = P.version; rebuildFilters() }
            if pendingTest.serial != test.serial { test = pendingTest; testPos = 0; testPhase = 0; if test.active { testStartHostTime = mach_absolute_time() } }
            os_unfair_lock_unlock(&lock)
        }
        let delayFrames = max(1, min(kMaxDelayFrames - 1, Int(P.surroundDelayFrames)))
        var detAcc = SIMD8<Float>(repeating: 0)
        let ramp: Float = 0.0015
        let bypass = P.bypass
        var blockMinEnv: Float = 1
        var activeFrames = 0
        var clips = 0
        var inClips = 0

        for i in 0..<frames {
            let f = buf + i * kChannels
            var x = SIMD8<Float>(repeating: 0)
            for c in 0..<kChannels { x[c] = f[c] }
            // ---- test signal for this frame (injected before or after processing)
            var testV: Float = 0
            let testNow = test.active
            if testNow {
                if let smp = test.samples, testPos < Int(test.count) { testV = smp[testPos] * test.gain }
                if test.subTone { testV += 0.3 * test.gain * sinf(testPhase); testPhase += 2 * Float.pi * 50 / fs; if testPhase > 2 * Float.pi { testPhase -= 2 * Float.pi } }
                testPos += 1
                if testPos >= Int(test.count) { test.active = false; testSerialDone = test.serial }
                if test.pre {
                    let s = Int(test.slot); if s >= 0 && s < kChannels { x[s] += testV }
                    let s2 = Int(test.slot2); if s2 >= 0 && s2 < kChannels { x[s2] += testV }
                }
            }
            for c in 0..<kChannels { let a = abs(x[c]); if a > inPeak[c] { inPeak[c] = a }; if a >= 0.999 { inClips += 1 } }
            detAcc += x * x

            if !bypass {
                // ---- stereo width (fronts)
                if P.width != 1 {
                    let m = (x[0] + x[1]) * 0.5, s = (x[0] - x[1]) * 0.5 * P.width
                    x[0] = m + s; x[1] = m - s
                }
                // ---- spatializer / upmix (delay lines always run so mode switches are click-free)
                if upmixAmt < upmixTarget { upmixAmt = min(upmixTarget, upmixAmt + ramp) } else if upmixAmt > upmixTarget { upmixAmt = max(upmixTarget, upmixAmt - ramp) }
                let sl = 0.866 * x[0] - 0.5 * x[1], sr = 0.866 * x[1] - 0.5 * x[0]
                var rp = delayPos - delayFrames; if rp < 0 { rp += kMaxDelayFrames }
                let dl = delayL[rp], dr = delayR[rp]
                delayL[delayPos] = sl; delayR[delayPos] = sr
                delayPos += 1; if delayPos >= kMaxDelayFrames { delayPos = 0 }
                let lsF = surLP[0].process(dl), rsF = surLP[1].process(dr)
                if upmixAmt > 0 {
                    let a = upmixAmt
                    x[2] += a * P.centerGain * (x[0] + x[1]) * 0.7071
                    x[4] += a * P.surroundGain * lsF
                    x[5] += a * P.surroundGain * rsF
                    if !P.bassEnabled { x[3] += a * 0.5 * upLFELP[1].process(upLFELP[0].process((x[0] + x[1]) * 0.5)) }
                }
                dialogSm += (P.dialogGain - dialogSm) * ramp
                x[2] *= dialogSm
                // ---- dynamics (linked compressor)
                if P.compEnabled {
                    var pk: Float = 0
                    for c in 0..<kChannels { pk = max(pk, abs(x[c])) }
                    compEnv += (pk > compEnv ? P.compAttackCoef : P.compReleaseCoef) * (pk - compEnv)
                    var g: Float = 1
                    if compEnv > P.compThreshold {
                        let overDB = 20 * log10f(compEnv / P.compThreshold)
                        g = powf(10, -(overDB * (1 - 1 / P.compRatio)) / 20)
                    }
                    let gg = g * P.compMakeup
                    for c in 0..<kChannels { x[c] *= gg }
                }
                // ---- listening orientation: remap content to the speakers around the turned listener (4.1)
                if P.orientation != 0 {
                    let cL = x[0], cR = x[1], cLs = x[4], cRs = x[5]
                    let ph = x[2] * P.phantomCenterGain
                    if P.orientation == 1 {          // turned left: new front pair = physical Ls (left) and L (right)
                        x[4] = cL + ph; x[0] = cR + ph; x[5] = cLs; x[1] = cRs
                    } else {                         // turned right: new front pair = physical R (left) and Rs (right)
                        x[1] = cL + ph; x[5] = cR + ph; x[0] = cLs; x[4] = cRs
                    }
                    x[2] = 0                         // the center speaker is at the listener's side now
                }
                // ---- bass management + LFE gain
                if P.bassEnabled {
                    var bass: Float = 0
                    for c in 0..<kChannels where c != 3 {
                        bass += x[c]
                        x[c] = bmHP[c * 2 + 1].process(bmHP[c * 2].process(x[c]))
                    }
                    let lp = bmBassLP[1].process(bmBassLP[0].process(bass))
                    var lfe = x[3] * P.lfeGain + (P.redirectBass ? lp : 0)
                    lfe = bmLFELP[1].process(bmLFELP[0].process(lfe))
                    x[3] = lfe
                } else {
                    x[3] *= P.lfeGain
                }
                // ---- per-speaker EQ
                if P.eqEnabled {
                    for c in 0..<kChannels where P.eqChannelEnabled[c] != 0 {
                        var v = x[c]
                        for b in 0..<kBands { v = eq[c * kBands + b].process(v) }
                        x[c] = v
                    }
                }
                // ---- per-speaker trims
                for c in 0..<kChannels {
                    outGainSm[c] += (P.outGain[c] - outGainSm[c]) * ramp
                    var g = outGainSm[c]
                    if P.outMute[c] != 0 { g = 0 }
                    if P.outInvert[c] != 0 { g = -g }
                    x[c] *= g
                }
                // ---- per-speaker delay (distance compensation)
                for c in 0..<kChannels {
                    let d = Int(P.chDelay[c])
                    if d > 0 {
                        var rp = chDelayPos - min(d, kMaxChannelDelay - 1); if rp < 0 { rp += kMaxChannelDelay }
                        let v = chDelayBuf[c * kMaxChannelDelay + rp]
                        chDelayBuf[c * kMaxChannelDelay + chDelayPos] = x[c]
                        x[c] = v
                    } else {
                        chDelayBuf[c * kMaxChannelDelay + chDelayPos] = x[c]
                    }
                }
                chDelayPos += 1; if chDelayPos >= kMaxChannelDelay { chDelayPos = 0 }
                // ---- sub fold: the encoder's LFE channel stays silent, the fronts carry the sub signal
                if P.foldLFE { let v = x[3] * 0.7071; x[0] += v; x[1] += v; x[3] = 0 }
                // ---- auto headroom (slow, so it never pumps)
                autoGainSm += (P.autoGain - autoGainSm) * 0.0003
                for c in 0..<kChannels { x[c] *= autoGainSm }
                // ---- limiter (linked, lookahead)
                if P.limEnabled {
                    // satellites share one detector (keeps the image stable); the sub has its own so bass never ducks them
                    var pk: Float = 0
                    for c in 0..<kChannels where c != 3 { pk = max(pk, abs(x[c])) }
                    let need: Float = pk > P.limCeiling ? P.limCeiling / pk : 1
                    if need < limEnv { limEnv = need } else { limEnv += P.limReleaseCoef * (1 - limEnv) }
                    let pkL = abs(x[3])
                    let needL: Float = pkL > P.limCeiling ? P.limCeiling / pkL : 1
                    if needL < limEnvLFE { limEnvLFE = needL } else { limEnvLFE += P.limReleaseCoef * (1 - limEnvLFE) }
                    let envMin = min(limEnv, limEnvLFE)
                    if envMin < blockMinEnv { blockMinEnv = envMin }
                    if limEnv < 0.891 { activeFrames += 1 }
                    for c in 0..<kChannels {
                        let idx = c * kLimiterLookahead + limPos
                        let d = limDelay[idx]
                        limDelay[idx] = x[c]
                        x[c] = d * (c == 3 ? limEnvLFE : limEnv)
                    }
                    limPos += 1; if limPos >= kLimiterLookahead { limPos = 0 }
                }
                masterSm += (P.masterGain - masterSm) * ramp
                volumeSm += (P.volume - volumeSm) * 0.002
                for c in 0..<kChannels {
                    let v = x[c] * masterSm * volumeSm
                    if v > 1 || v < -1 { clips += 1 }
                    x[c] = min(1, max(-1, v))
                }
            }
            if bypass && P.foldLFE { let v = x[3] * 0.7071; x[0] += v; x[1] += v; x[3] = 0 }
            // ---- routing (wiring fix): output slot s carries source channel route[s]
            var y = SIMD8<Float>(repeating: 0)
            for s in 0..<kChannels { let src = Int(P.route[s]); y[s] = (src >= 0 && src < kChannels) ? x[src] : 0 }
            // ---- test signal injection after the wiring fix (identifies physical outputs)
            if testNow && !test.pre {
                let s = Int(test.slot); if s >= 0 && s < kChannels { y[s] += testV }
                let s2 = Int(test.slot2); if s2 >= 0 && s2 < kChannels { y[s2] += testV }
            }
            for s in 0..<kChannels { f[s] = y[s]; let a = abs(y[s]); if a > outPeak[s] { outPeak[s] = a } }
        }

        // ---- limiter statistics
        let grMax = -20 * log10f(max(1e-6, blockMinEnv))
        if grMax > limGRMaxDB { limGRMaxDB = grMax }
        limGRNowDB = -20 * log10f(max(1e-6, min(limEnv, limEnvLFE)))
        limActiveFrames += activeFrames
        limTotalFrames += frames
        clipCount += clips
        inClipCount += inClips

        // ---- content detection (block level)
        let inv = 1 / Float(frames)
        let decay: Float = powf(0.001, Float(frames) / (fs * 1.5))  // ~1.5 s to fall 60 dB
        for c in 0..<kChannels {
            let rms = sqrtf(detAcc[c] * inv)
            detLevel[c] = max(rms, detLevel[c] * decay)
        }
        let front = max(detLevel[0], detLevel[1])
        let others = max(max(detLevel[2], detLevel[3]), max(detLevel[4], detLevel[5]))
        let frontDB = linToDb(front), othersDB = linToDb(others)
        var cls: Int32
        if frontDB < -60 && othersDB < -60 { cls = 0 }
        else if othersDB < -60 || othersDB < frontDB - 35 { cls = 1 }
        else { cls = 2 }
        if cls == 1 { stereoFrames += frames } else { stereoFrames = 0 }
        contentClass = cls
        switch P.upmixMode {
        case 2: upmixTarget = 1
        case 1: upmixTarget = (cls == 1 && stereoFrames > Int(fs * 0.3)) ? 1 : ((cls == 2) ? 0 : upmixTarget)
        default: upmixTarget = 0
        }
        upmixActive = upmixAmt
    }
}
