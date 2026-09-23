import Foundation

// Feeds a distinct tone on each content channel through the real Processor and reports which output slot carries it.
let fs: Float = 48000
let freqs: [Float] = [200, 300, 450, 60, 700, 1000]   // L R C LFE Ls Rs
let names = ["L","R","C","LFE","Ls","Rs"]
let frames = 48000 * 2
let block = 128

func run(_ configure: (inout Settings) -> Void, label: String, expect: [Int: [Int: Float]]) -> Bool {
    var s = Settings()
    s.limEnabled = false; s.autoHeadroomEnabled = false; s.eqEnabled = false; s.bassEnabled = false; s.upmixMode = 0; s.compEnabled = false
    s.lfeGainDB = 0; s.width = 1; s.dialogEnhanceDB = 0
    configure(&s)
    let proc = Processor()
    proc.update(s.makeParams(fs: fs))
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames * 6); defer { buf.deallocate() }
    var acc = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)  // in-phase
    var accQ = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6) // quadrature (delay-independent magnitude)
    var slotRMS = [Double](repeating: 0, count: 6)
    var n = 0
    for start in stride(from: 0, to: frames, by: block) {
        let cnt = min(block, frames - start)
        for i in 0..<cnt { let t = Float(start + i) / fs; for c in 0..<6 { buf[i * 6 + c] = 0.2 * sinf(2 * Float.pi * freqs[c] * t) } }
        proc.process(buf, cnt, 6)
        if start < Int(fs * 0.5) { continue }   // skip ramps
        for i in 0..<cnt {
            let t = Float(start + i) / fs
            for slot in 0..<6 {
                let y = Double(buf[i * 6 + slot]); slotRMS[slot] += y * y
                for c in 0..<6 { acc[slot][c] += y * Double(sinf(2 * Float.pi * freqs[c] * t)); accQ[slot][c] += y * Double(cosf(2 * Float.pi * freqs[c] * t)) }
            }
            n += 1
        }
    }
    var ok = true
    var report = ""
    for slot in 0..<6 {
        let rms = (slotRMS[slot] / Double(n)).squareRoot()
        var parts: [String] = []
        for c in 0..<6 {
            let amp = 2 * (acc[slot][c] * acc[slot][c] + accQ[slot][c] * accQ[slot][c]).squareRoot() / Double(n)   // amplitude of tone c on this slot, any phase
            if amp > 0.01 { parts.append(String(format: "%@ %.1f dB", names[c], 20 * log10(amp / 0.2))) }
            let want = expect[slot]?[c] ?? -100
            let got: Float = amp > 0.001 ? Float(20 * log10(amp / 0.2)) : -100
            if abs(got - want) > 0.6 { ok = false; report += String(format: "  MISMATCH slot %@: content %@ expected %.1f dB got %.1f dB\n", names[slot], names[c], want, got) }
        }
        report += String(format: "  slot %-3@ rms %-7.4f  carries: %@\n", names[slot], rms, parts.isEmpty ? "silence" : parts.joined(separator: ", "))
    }
    print("[\(ok ? "PASS" : "FAIL")] \(label)\n" + report)
    return ok
}

var all = true
let L = 0, R = 1, C = 2, LFE = 3, Ls = 4, Rs = 5
all = run({ _ in }, label: "normal 5.1 (identity)", expect: [L:[L:0], R:[R:0], C:[C:0], LFE:[LFE:0], Ls:[Ls:0], Rs:[Rs:0]]) && all
all = run({ $0.orientation = 1 }, label: "turned left: physical Ls=L+C(-3), L=R+C(-3), Rs=Ls, R=Rs, C silent",
          expect: [Ls:[L:0, C:-3], L:[R:0, C:-3], Rs:[Ls:0], R:[Rs:0], C:[:], LFE:[LFE:0]]) && all
all = run({ $0.orientation = 2 }, label: "turned right: physical R=L+C(-3), Rs=R+C(-3), L=Ls, Ls=Rs, C silent",
          expect: [R:[L:0, C:-3], Rs:[R:0, C:-3], L:[Ls:0], Ls:[Rs:0], C:[:], LFE:[LFE:0]]) && all
all = run({ $0.orientation = 1; $0.phantomCenterDB = -6 }, label: "turned left, phantom center -6 dB",
          expect: [Ls:[L:0, C:-6], L:[R:0, C:-6], Rs:[Ls:0], R:[Rs:0], C:[:], LFE:[LFE:0]]) && all
all = run({ $0.orientation = 1; $0.route = [0, 1, 3, 2, 4, 5] }, label: "turned left + wiring fix C<->LFE swapped (slot C carries LFE content, slot LFE silent)",
          expect: [Ls:[L:0, C:-3], L:[R:0, C:-3], Rs:[Ls:0], R:[Rs:0], C:[LFE:0], LFE:[:]]) && all
all = run({ $0.orientation = 1; $0.bypass = true }, label: "turned left but bypass on (calibration): identity",
          expect: [L:[L:0], R:[R:0], C:[C:0], LFE:[LFE:0], Ls:[Ls:0], Rs:[Rs:0]]) && all
all = run({ $0.orientation = 2; $0.outGainDB[1] = -6; $0.delayMs[5] = 5 }, label: "turned right + trim -6 dB on physical R (applies after the remap)",
          expect: [R:[L:-6, C:-9], Rs:[R:0, C:-3], L:[Ls:0], Ls:[Rs:0], C:[:], LFE:[LFE:0]]) && all
print(all ? "ALL ORIENTATION TESTS PASSED" : "SOME TESTS FAILED")

// ---- volume stage
var vall = true
vall = run({ $0.systemVolume = 0.5 }, label: "volume 50 % (curve v²: −12 dB on every channel)",
           expect: [L:[L:-12], R:[R:-12], C:[C:-12], LFE:[LFE:-12], Ls:[Ls:-12], Rs:[Rs:-12]]) && vall
vall = run({ $0.systemVolume = 0.5; $0.systemMuted = true }, label: "muted: silence",
           expect: [:]) && vall
vall = run({ $0.systemVolume = 0.5; $0.bypass = true }, label: "volume 50 % but bypass (calibration): unity",
           expect: [L:[L:0], R:[R:0], C:[C:0], LFE:[LFE:0], Ls:[Ls:0], Rs:[Rs:0]]) && vall
print(vall ? "ALL VOLUME TESTS PASSED" : "VOLUME TESTS FAILED")
