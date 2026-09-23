import Foundation
import Accelerate

/// Third-octave band centers used for analysis (Hz).
let kThirdOctaveCenters: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000]

/// Exponential sine sweep (Farina) with matching inverse filter.
struct Sweep {
    let fs: Double
    let f1: Double
    let f2: Double
    let duration: Double
    var count: Int { Int(duration * fs) }
    var L: Double { duration / log(f2 / f1) }

    func signal(fadeMs: Double = 15) -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        let w1 = 2 * Double.pi * f1
        let fade = Int(fadeMs / 1000 * fs)
        for i in 0..<n {
            let t = Double(i) / fs
            var v = sin(w1 * L * (exp(t / L) - 1))
            if i < fade { v *= Double(i) / Double(fade) }
            if i >= n - fade { v *= Double(n - 1 - i) / Double(fade) }
            out[i] = Float(v)
        }
        return out
    }

    /// Time-reversed sweep with a −6 dB/octave envelope; normalised so sweep ⊛ inverse peaks at 1.
    func inverseFilter() -> [Float] {
        let x = signal(fadeMs: 0)
        let n = x.count
        var inv = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let orig = n - 1 - i
            let tInv = Double(i) / fs   // envelope decays along the reversed filter: −6 dB/octave compensation
            inv[i] = x[orig] * Float(exp(-tInv / L))
        }
        // normalise using the analytic peak of the convolution
        let conv = fftConvolve(x, inv)
        var peak: Float = 0
        vDSP_maxmgv(conv, 1, &peak, vDSP_Length(conv.count))
        if peak > 0 { var s = 1 / peak; vDSP_vsmul(inv, 1, &s, &inv, 1, vDSP_Length(n)) }
        return inv
    }
}

/// Complex FFT helpers on split buffers (complex-to-complex, vDSP_fft_zop).
final class FFTPlan: @unchecked Sendable {
    let log2n: vDSP_Length
    let n: Int
    private let setup: FFTSetup
    init(minLength: Int) {
        log2n = vDSP_Length(max(4, Int(ceil(log2(Double(minLength))))))
        n = 1 << Int(log2n)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    final class Buf {
        let re: UnsafeMutablePointer<Float>; let im: UnsafeMutablePointer<Float>; let n: Int
        init(_ n: Int) { self.n = n; re = .allocate(capacity: n); im = .allocate(capacity: n); re.initialize(repeating: 0, count: n); im.initialize(repeating: 0, count: n) }
        deinit { re.deallocate(); im.deallocate() }
        var split: DSPSplitComplex { DSPSplitComplex(realp: re, imagp: im) }
        func load(_ x: [Float]) { re.initialize(repeating: 0, count: n); im.initialize(repeating: 0, count: n); x.withUnsafeBufferPointer { p in re.update(from: p.baseAddress!, count: min(n, x.count)) } }
    }
    func forward(_ input: Buf, _ output: Buf) {
        var i = input.split, o = output.split
        vDSP_fft_zop(setup, &i, 1, &o, 1, log2n, FFTDirection(FFT_FORWARD))
    }
    func inverse(_ input: Buf, _ output: Buf) {
        var i = input.split, o = output.split
        vDSP_fft_zop(setup, &i, 1, &o, 1, log2n, FFTDirection(FFT_INVERSE))
        var s = 1 / Float(n)
        vDSP_vsmul(output.re, 1, &s, output.re, 1, vDSP_Length(n)); vDSP_vsmul(output.im, 1, &s, output.im, 1, vDSP_Length(n))
    }
    /// c = a * b (c must not alias a or b)
    static func multiply(_ a: Buf, _ b: Buf, into c: Buf) {
        var A = a.split, B = b.split, C = c.split
        vDSP_zvmul(&A, 1, &B, 1, &C, 1, vDSP_Length(a.n), 1)
    }
}

/// Linear convolution via FFT, full length a.count + b.count - 1.
func fftConvolve(_ a: [Float], _ b: [Float]) -> [Float] {
    let outLen = a.count + b.count - 1
    let plan = FFTPlan(minLength: outLen)
    let A = FFTPlan.Buf(plan.n), B = FFTPlan.Buf(plan.n), FA = FFTPlan.Buf(plan.n), FB = FFTPlan.Buf(plan.n), P = FFTPlan.Buf(plan.n), R = FFTPlan.Buf(plan.n)
    A.load(a); B.load(b)
    plan.forward(A, FA); plan.forward(B, FB)
    FFTPlan.multiply(FA, FB, into: P)
    plan.inverse(P, R)
    return Array(UnsafeBufferPointer(start: R.re, count: outLen))
}


/// Deconvolution with a cached inverse-filter spectrum. Thread-safe: each call allocates its own work buffers,
/// the FFT setup is shared read-only.
final class Deconvolver: @unchecked Sendable {
    let plan: FFTPlan
    private let invSpectrum: FFTPlan.Buf
    let invCount: Int
    init(inverse: [Float], maxSegmentLength: Int) {
        plan = FFTPlan(minLength: maxSegmentLength + inverse.count - 1)
        invCount = inverse.count
        let t = FFTPlan.Buf(plan.n)
        t.load(inverse)
        invSpectrum = FFTPlan.Buf(plan.n)
        plan.forward(t, invSpectrum)
    }
    func deconvolve(_ segment: [Float]) -> [Float] {
        let X = FFTPlan.Buf(plan.n), FX = FFTPlan.Buf(plan.n), P = FFTPlan.Buf(plan.n), R = FFTPlan.Buf(plan.n)
        X.load(segment)
        plan.forward(X, FX)
        FFTPlan.multiply(FX, invSpectrum, into: P)
        plan.inverse(P, R)
        return Array(UnsafeBufferPointer(start: R.re, count: min(plan.n, segment.count + invCount - 1)))
    }
}

/// Result of analysing one impulse response.
struct IRAnalysis {
    var peakIndex: Int          // sample index of the strongest peak in the IR (relative to segment start)
    var peakValue: Float        // signed peak
    var peakToFloorDB: Float    // how far the peak stands above the IR's noise floor
    var bandLevels: [Float]     // dB per third-octave band (relative scale)
}

enum SweepAnalysis {
    /// Deconvolves a recorded segment with the inverse filter and returns the impulse response.
    static func impulseResponse(recording: [Float], inverse: [Float]) -> [Float] {
        fftConvolve(recording, inverse)
    }

    /// Finds the direct-sound peak and computes windowed third-octave levels.
    static func analyse(ir: [Float], fs: Double, searchFrom: Int, searchTo: Int, windowMs: Double = 120, preMs: Double = 2) -> IRAnalysis {
        let lo = max(0, min(ir.count - 1, searchFrom)), hi = max(lo + 1, min(ir.count, searchTo))
        var peakIdx = lo, peakAbs: Float = 0
        for i in lo..<hi { let a = abs(ir[i]); if a > peakAbs { peakAbs = a; peakIdx = i } }
        // noise floor: median of |ir| over the search range
        var mags = [Float](repeating: 0, count: hi - lo)
        for i in lo..<hi { mags[i - lo] = abs(ir[i]) }
        mags.sort()
        let floor = max(1e-9, mags[mags.count / 2])
        let ptf = 20 * log10f(max(1e-9, peakAbs) / floor)
        // window the IR around the peak
        let pre = Int(preMs / 1000 * fs), win = Int(windowMs / 1000 * fs)
        let start = max(0, peakIdx - pre)
        let nfft = 1 << Int(ceil(log2(Double(max(win, 8192)) * 2)))
        var seg = [Float](repeating: 0, count: nfft)
        let taperStart = Int(Double(win) * 0.7)
        for i in 0..<win {
            let idx = start + i
            guard idx < ir.count else { break }
            var w: Float = 1
            if i > taperStart { let p = Float(i - taperStart) / Float(max(1, win - taperStart)); w = 0.5 * (1 + cosf(Float.pi * p)) }
            seg[i] = ir[idx] * w
        }
        let levels = bandLevels(ofSpectrumOf: seg, fs: fs)
        return IRAnalysis(peakIndex: peakIdx, peakValue: ir[peakIdx], peakToFloorDB: ptf, bandLevels: levels)
    }

    /// Third-octave mean power levels (dB) of the spectrum of `x` (x.count must be a power of two).
    static func bandLevels(ofSpectrumOf x: [Float], fs: Double) -> [Float] {
        let plan = FFTPlan(minLength: x.count)
        let X = FFTPlan.Buf(plan.n), FX = FFTPlan.Buf(plan.n)
        X.load(x); plan.forward(X, FX)
        let half = plan.n / 2
        var power = [Float](repeating: 0, count: half)
        for i in 0..<half { power[i] = FX.re[i] * FX.re[i] + FX.im[i] * FX.im[i] }
        let binHz = fs / Double(plan.n)
        return kThirdOctaveCenters.map { fc in
            let lo = Int((fc * pow(2, -1.0 / 6)) / binHz), hi = Int((fc * pow(2, 1.0 / 6)) / binHz)
            let a = max(1, lo), b = max(a, min(half - 1, hi))
            var sum: Float = 0
            for i in a...b { sum += power[i] }
            let mean = sum / Float(b - a + 1)
            return 10 * log10f(max(1e-20, mean))
        }
    }

    /// Welch-averaged third-octave levels of a raw signal (for ambient noise and overload checks).
    static func welchBandLevels(_ x: [Float], fs: Double, window: Int = 8192) -> [Float] {
        guard x.count >= window else { return bandLevels(ofSpectrumOf: Array(x) + [Float](repeating: 0, count: window - x.count), fs: fs) }
        var acc = [Float](repeating: 0, count: kThirdOctaveCenters.count)
        var frames = 0
        var pos = 0
        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        while pos + window <= x.count && frames < 64 {
            var seg = Array(x[pos..<pos + window])
            vDSP_vmul(seg, 1, hann, 1, &seg, 1, vDSP_Length(window))
            let lv = bandLevels(ofSpectrumOf: seg, fs: fs)
            for i in 0..<lv.count { acc[i] += powf(10, lv[i] / 10) }
            frames += 1; pos += window / 2
        }
        return acc.map { 10 * log10f(max(1e-20, $0 / Float(max(1, frames)))) }
    }

    static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : 0.5 * (s[m - 1] + s[m])
    }
}
