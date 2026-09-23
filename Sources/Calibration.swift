import Foundation
import AVFoundation
import Accelerate
import Combine

struct SpeakerResult: Identifiable, Codable {
    var role: Role
    var id: Int { role.rawValue }
    var ok: Bool
    var levelDB: Float
    var delayMs: Float
    var polarityPositive: Bool
    var peakToFloorDB: Float    // for a speaker that was not found this is the best value seen
    var bands: [Float]          // third-octave levels relative to the speaker's own reference level
    var snr: [Float]            // per third-octave band, dB above the noise floor in the IR domain
    var micBalanceDB: Float     // positive = louder in the recorder's left microphone
    var suggestedTrimDB: Float = 0
    var suggestedDelayMs: Float = 0
    var suggestedEQ: [Float] = Array(repeating: 0, count: kBands)
    var suggestInvert = false
}

struct PolarityVerdict: Identifiable, Codable {
    var role: Role
    var asWiredDB: Float
    var invertedDB: Float
    var invert: Bool
    var conclusive: Bool
    var id: Int { role.rawValue }
    var text: String { conclusive ? (invert ? "inverted sums louder → invert" : "as wired is correct") : "inconclusive (under 1.5 dB difference)" }
}

struct CalibrationResult: Codable {
    var polarity: [PolarityVerdict]? = nil
    var date: Date
    var deviceName: String
    var micSampleRate: Double
    var noiseBands: [Float]
    var noiseRMSDB: Float
    var speakers: [SpeakerResult]
    var suggestedCrossoverHz: Float
    var suggestedLFEGainDB: Float
    var warnings: [String]

    static let fileURL = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("calibration.json")
    static let preURL = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("settings-before-calibration.json")
    static func load() -> CalibrationResult? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CalibrationResult.self, from: d)
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: CalibrationResult.fileURL, options: .atomic) } }
}

@MainActor
final class Calibrator: ObservableObject {
    enum Phase: Equatable { case idle, noise, sweeping(Role, Int, Int), polarity, analysing, done, failed(String) }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var statusText = "Idle"
    @Published var result: CalibrationResult? = CalibrationResult.load()
    @Published var inputDevices: [InputDevice] = []
    @Published var selectedDevice: AudioDeviceID? = nil
    @Published var monitoring = false
    @Published var monitorLevelDB: Float = -100
    @Published var testLevelDB: Float = -12
    @Published var repetitions = 3
    @Published var sweepSeconds: Double = 4
    @Published var applyTrims = true
    @Published var applyDelays = true
    @Published var applyEQ = true
    @Published var applyCrossover = true
    @Published var applySubLevel = true
    @Published var applyPolarity = false
    @Published var canRevert = FileManager.default.fileExists(atPath: CalibrationResult.preURL.path)
    @Published var polarity: [PolarityVerdict] = CalibrationResult.load()?.polarity ?? []

    private let engine: EngineController
    private let mic = MicCapture()
    private var cancelled = false
    private var sweepBuffer: UnsafeMutablePointer<Float>? = nil
    private var sweepBufferCount = 0

    var isBusy: Bool { switch phase { case .idle, .done, .failed: return false; default: return true } }

    init(engine: EngineController) {
        self.engine = engine
        refreshDevices()
    }

    func refreshDevices() {
        inputDevices = MicCapture.inputDevices()
        if selectedDevice == nil || !inputDevices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = inputDevices.first { !$0.name.localizedCaseInsensitiveContains("MacBook") && !$0.name.localizedCaseInsensitiveContains("Built-in") }?.id ?? inputDevices.first?.id   // prefer an external microphone over the built-in one
        }
    }

    // MARK: live level monitor

    func setMonitoring(_ on: Bool) {
        if on {
            guard let dev = selectedDevice else { return }
            MicCapture.requestPermission { [weak self] ok in
                guard let self = self else { return }
                guard ok else { self.statusText = "Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone."; return }
                self.mic.levelHandler = { [weak self] rms in DispatchQueue.main.async { self?.monitorLevelDB = linToDb(rms) } }
                do { try self.mic.start(device: dev, record: false); self.monitoring = true }
                catch { self.statusText = error.localizedDescription }
            }
        } else {
            mic.stop(); monitoring = false; monitorLevelDB = -100
        }
    }

    // MARK: measurement

    func start() {
        guard !isBusy else { return }
        guard engine.isRunning else { phase = .failed("Start the engine first."); return }
        guard let dev = selectedDevice, let devInfo = inputDevices.first(where: { $0.id == dev }) else { phase = .failed("No input device selected."); return }
        cancelled = false
        MicCapture.requestPermission { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.phase = .failed("Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone."); return }
            Task { @MainActor in await self.run(device: dev, deviceName: devInfo.name) }
        }
    }

    func cancel() { cancelled = true }

    private func run(device: AudioDeviceID, deviceName: String) async {
        let saved = engine.settings
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: CalibrationResult.preURL, options: .atomic); canRevert = true }
        var flat = saved; flat.bypass = true           // bypass keeps the wiring fix but removes all processing
        engine.calibrationInProgress = true
        engine.settings = flat
        engine.stopTests()
        mic.levelHandler = { [weak self] rms in DispatchQueue.main.async { self?.monitorLevelDB = linToDb(rms) } }
        do { try mic.start(device: device, record: true) }
        catch { engine.settings = saved; engine.calibrationInProgress = false; phase = .failed("Could not start the microphone: \(error.localizedDescription)"); return }
        monitoring = true

        let fsOut = 48000.0
        let sweep = Sweep(fs: fsOut, f1: 20, f2: 20000, duration: sweepSeconds)
        let sig = sweep.signal()
        let tail = Int(0.5 * fsOut)
        sweepBuffer?.deallocate()
        sweepBuffer = UnsafeMutablePointer<Float>.allocate(capacity: sig.count + tail)
        sweepBuffer!.initialize(repeating: 0, count: sig.count + tail)
        sig.withUnsafeBufferPointer { sweepBuffer!.update(from: $0.baseAddress!, count: sig.count) }
        sweepBufferCount = sig.count + tail

        let roles = Role.allCases
        let totalSteps = Double(roles.count * repetitions + 1)
        var step = 0.0

        phase = .noise; statusText = "Measuring background noise (stay quiet)…"; progress = 0
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let noiseEnd = mic.recordedFrames
        step += 1; progress = step / totalSteps

        var starts: [(Role, Int)] = []
        var lastHT: UInt64 = engine.processor.testStartHostTime
        var runWarnings: [String] = []
        var framesBefore = mic.recordedFrames
        var stalled = false
        outer: for role in roles {
            for rep in 0..<repetitions {
                if cancelled || stalled { break outer }
                phase = .sweeping(role, rep + 1, repetitions)
                statusText = "Sweeping \(role.name) (\(rep + 1)/\(repetitions))…  mic: \(Int(Double(mic.recordedFrames) / mic.sampleRate)) s recorded"
                let slot = engine.settings.route.firstIndex(of: role.rawValue) ?? role.rawValue
                engine.injectBuffer(role: role, samples: UnsafePointer(sweepBuffer!), count: sweepBufferCount, gain: dbToLin(testLevelDB), pre: true)
                var ht = lastHT
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 10_000_000); ht = engine.processor.testStartHostTime; if ht != lastHT { break } }
                if ht == lastHT { runWarnings.append("\(role.name): the engine did not start the sweep in time (rep \(rep + 1)).") }
                lastHT = ht
                let idx = mic.sampleIndex(forHostTime: ht)
                starts.append((role, idx))
                // wait for the sweep while checking that the mic keeps recording and the sweep reaches the output
                var outPeak: Float = 0
                let ticks = Int((sweepSeconds + 1.0) * 10)
                for _ in 0..<ticks {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    outPeak = max(outPeak, engine.currentOutMeters[min(5, max(0, slot))])
                }
                if outPeak < 0.01 { runWarnings.append("\(role.name): the sweep never showed up on output \(Role(rawValue: slot)?.short ?? "?") (rep \(rep + 1)).") }
                let framesNow = mic.recordedFrames
                let expected = Int((sweepSeconds + 1.0) * mic.sampleRate)
                if framesNow - framesBefore < expected / 2 {
                    stalled = true
                    runWarnings.append("The microphone stream stopped after \(Int(Double(framesNow) / mic.sampleRate)) s (interruptions: \(mic.interruptions)). The recorder was disconnected, changed mode or sample rate, or went to sleep. Measurement aborted.")
                }
                framesBefore = framesNow
                step += 1; progress = step / totalSteps
            }
        }
        engine.stopTests()
        let fsIn = mic.sampleRate
        let ch0 = mic.channel(0), ch1 = mic.channel(1)
        let micInterruptions = mic.interruptions
        mic.stop(); monitoring = false
        engine.settings = saved
        engine.calibrationInProgress = false
        if cancelled { phase = .idle; statusText = "Cancelled"; return }
        if stalled { phase = .failed(runWarnings.last ?? "Microphone stream stopped."); statusText = "Failed"; return }
        if micInterruptions > 0 { runWarnings.append("Core Audio reconfigured the microphone \(micInterruptions)× during the run; results may be unreliable.") }

        phase = .analysing; statusText = "Analysing…"
        let reps = repetitions, sweepLen = sweepSeconds
        let analysed: CalibrationResult = await Task.detached(priority: .userInitiated) {
            Calibrator.analyse(ch0: ch0, ch1: ch1, fsIn: fsIn, noiseEnd: noiseEnd, starts: starts, reps: reps, sweepSeconds: sweepLen, deviceName: deviceName)
        }.value
        var merged = analysed
        merged.warnings = runWarnings + merged.warnings
        result = merged
        merged.save()
        phase = .done
        statusText = "Done. Review the results and click Apply."
        progress = 1
    }

    // MARK: analysis (pure, runs off the main thread)

    nonisolated static func analyse(ch0: [Float], ch1: [Float], fsIn: Double, noiseEnd: Int, starts: [(Role, Int)], reps: Int, sweepSeconds: Double, deviceName: String) -> CalibrationResult {
        var warnings: [String] = []
        let n = min(ch0.count, ch1.count)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * (ch0[i] + ch1[i]) }
        var peakRec: Float = 0
        vDSP_maxmgv(mono, 1, &peakRec, vDSP_Length(n))
        if peakRec > 0.97 { warnings.append("The microphone overloaded. Lower the test level or the recorder's input gain and measure again.") }

        let inv = Sweep(fs: fsIn, f1: 20, f2: 20000, duration: sweepSeconds).inverseFilter()
        let pre = Int(0.1 * fsIn)
        let segLen = Int((sweepSeconds + 1.3) * fsIn)
        let deconv = Deconvolver(inverse: inv, maxSegmentLength: segLen)

        // noise floor: raw band levels and the noise floor in the IR domain
        let nLo = min(n, Int(0.3 * fsIn)), nHi = max(nLo + 1, min(n, noiseEnd - Int(0.2 * fsIn)))
        let noiseSeg = Array(mono[nLo..<nHi])
        let noiseBands = SweepAnalysis.welchBandLevels(noiseSeg, fs: fsIn)
        var noiseRMS: Float = 0
        vDSP_rmsqv(noiseSeg, 1, &noiseRMS, vDSP_Length(noiseSeg.count))
        let noiseIR = deconv.deconvolve(Array(noiseSeg.prefix(segLen)) + [Float](repeating: 0, count: max(0, segLen - noiseSeg.count)))
        let noiseA = SweepAnalysis.analyse(ir: noiseIR, fs: fsIn, searchFrom: inv.count - 1, searchTo: inv.count - 1 + Int(1.0 * fsIn))

        struct Rep { var a: IRAnalysis; var delayMs: Float; var balanceDB: Float }
        // every (speaker, repetition) is deconvolved on its own core; the mono response is derived from the two mic channels
        var repOut = [(Role, Rep)?](repeating: nil, count: starts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: starts.count) { k in
            let (role, start) = starts[k]
            let s0 = max(0, start - pre), s1 = min(n, s0 + segLen)
            guard s1 - s0 > inv.count / 2 else { return }
            let irL = deconv.deconvolve(Array(ch0[s0..<s1]))
            let irR = deconv.deconvolve(Array(ch1[s0..<s1]))
            var ir = [Float](repeating: 0, count: min(irL.count, irR.count))
            vDSP_vadd(irL, 1, irR, 1, &ir, 1, vDSP_Length(ir.count))
            var half: Float = 0.5
            vDSP_vsmul(ir, 1, &half, &ir, 1, vDSP_Length(ir.count))
            let from = inv.count - 1 + pre, to = from + Int(1.2 * fsIn)
            let a = SweepAnalysis.analyse(ir: ir, fs: fsIn, searchFrom: from, searchTo: to)
            let delayMs = Float(a.peakIndex - from) / Float(fsIn) * 1000
            let w = Int(0.003 * fsIn)
            var pl: Float = 0, pr: Float = 0
            for i in max(0, a.peakIndex - w)...min(ir.count - 1, a.peakIndex + w) { pl = max(pl, abs(irL[i])); pr = max(pr, abs(irR[i])) }
            let bal = 20 * log10f(max(1e-9, pl) / max(1e-9, pr))
            lock.lock(); repOut[k] = (role, Rep(a: a, delayMs: delayMs, balanceDB: bal)); lock.unlock()
        }
        var perRole: [Role: [Rep]] = [:]
        for item in repOut { if let (role, rep) = item { perRole[role, default: []].append(rep) } }

        func refLevel(_ bands: [Float], role: Role) -> Float {
            let idx = role == .LFE ? Array(3...7) : Array(11...22)   // 40–100 Hz for the sub, 250 Hz–4 kHz otherwise
            return idx.map { bands[$0] }.reduce(0, +) / Float(idx.count)
        }

        var speakers: [SpeakerResult] = []
        let recordedSeconds = Double(n) / fsIn
        for role in Role.allCases {
            let all = perRole[role] ?? []
            let repsFor = all.filter { $0.a.peakToFloorDB > 15 }
            guard !repsFor.isEmpty else {
                let best = all.map { $0.a.peakToFloorDB }.max() ?? 0
                speakers.append(SpeakerResult(role: role, ok: false, levelDB: 0, delayMs: 0, polarityPositive: true, peakToFloorDB: best, bands: Array(repeating: 0, count: kThirdOctaveCenters.count), snr: Array(repeating: 0, count: kThirdOctaveCenters.count), micBalanceDB: 0))
                if all.isEmpty {
                    let expectedStart = starts.first { $0.0 == role }.map { Double($0.1) / fsIn } ?? 0
                    warnings.append("\(role.name): no usable recording (sweep expected at \(Int(expectedStart)) s, recording is \(Int(recordedSeconds)) s long). The microphone stream ended early.")
                } else {
                    warnings.append("\(role.name): no clear response (best peak-to-floor \(String(format: "%.0f", best)) dB, need 15). Check the speaker, the wiring fix, the volume and the microphone placement.")
                }
                continue
            }
            let nb = kThirdOctaveCenters.count
            var medBands = [Float](repeating: 0, count: nb)
            for b in 0..<nb { medBands[b] = SweepAnalysis.median(repsFor.map { $0.a.bandLevels[b] }) }
            let level = refLevel(medBands, role: role)
            let delay = SweepAnalysis.median(repsFor.map { $0.delayMs })
            let pos = repsFor.filter { $0.a.peakValue > 0 }.count * 2 > repsFor.count
            let ptf = SweepAnalysis.median(repsFor.map { $0.a.peakToFloorDB })
            let bal = SweepAnalysis.median(repsFor.map { $0.balanceDB })
            let snr = (0..<nb).map { medBands[$0] - noiseA.bandLevels[$0] }
            speakers.append(SpeakerResult(role: role, ok: true, levelDB: level, delayMs: delay, polarityPositive: pos, peakToFloorDB: ptf, bands: medBands.map { $0 - level }, snr: snr, micBalanceDB: bal))
        }

        // ---- suggestions
        let sats = speakers.filter { $0.ok && $0.role != .LFE }
        let ref = sats.isEmpty ? 0 : sats.map { $0.levelDB }.reduce(0, +) / Float(sats.count)
        let maxDelay = speakers.filter { $0.ok }.map { $0.delayMs }.max() ?? 0
        let fronts = speakers.filter { $0.ok && ($0.role == .L || $0.role == .R || $0.role == .C) }
        let majorityPositive = fronts.filter { $0.polarityPositive }.count * 2 >= fronts.count

        // crossover from the satellites' low-frequency roll-off: the lowest frequency from which the response stays
        // within 6 dB of the midband over three consecutive bands (single dips from room cancellations are skipped).
        // Capped at 120 Hz because the AC3 encoder low-passes the LFE channel there; redirected bass above that is lost.
        var xo: Float = 0
        for s in sats {
            var rolloff: Double = 250
            let idxs = kThirdOctaveCenters.indices.filter { kThirdOctaveCenters[$0] >= 40 && kThirdOctaveCenters[$0] <= 250 }
            for i in idxs {
                let holds = (0..<3).allSatisfy { k in let j = i + k; return j < s.bands.count && (s.snr[j] < 6 || s.bands[j] >= -6) }
                if holds { rolloff = kThirdOctaveCenters[i]; break }
            }
            xo = max(xo, Float(rolloff) * 1.25)
        }
        if xo == 0 { xo = 100 }
        let snaps: [Float] = [60, 80, 100, 120]
        xo = snaps.min(by: { abs($0 - xo) < abs($1 - xo) }) ?? 100

        var lfeGain: Float = 10
        if let sub = speakers.first(where: { $0.role == .LFE && $0.ok }) {
            lfeGain = max(0, min(15, ref - sub.levelDB))
        }

        for i in speakers.indices where speakers[i].ok {
            let s = speakers[i]
            speakers[i].suggestedDelayMs = max(0, min(40, maxDelay - s.delayMs))
            speakers[i].suggestInvert = (s.polarityPositive != majorityPositive)
            if s.role == .LFE {
                speakers[i].suggestedTrimDB = 0
                var eq = [Float](repeating: 0, count: kBands)
                for b in 0..<3 {
                    let fb = Double(kBandFreqs[b])
                    let idx = kThirdOctaveCenters.indices.filter { kThirdOctaveCenters[$0] >= fb / sqrt(2) && kThirdOctaveCenters[$0] < fb * sqrt(2) && s.snr[$0] >= 10 }
                    if !idx.isEmpty { let dev = idx.map { s.bands[$0] }.reduce(0, +) / Float(idx.count); eq[b] = max(-8, min(4, -dev)) }
                }
                speakers[i].suggestedEQ = eq
            } else {
                speakers[i].suggestedTrimDB = max(-10, min(10, ref - s.levelDB))
                // target: flat to 1 kHz, then a gentle −1 dB/octave tilt (the usual in-room preference; a flat mic
                // response at the seat sounds bright and harsh). Boosts above 2 kHz are limited because small
                // drivers get harsh and distort when pushed there.
                var eq = [Float](repeating: 0, count: kBands)
                for b in 0..<kBands {
                    let fb = Double(kBandFreqs[b])
                    if Float(fb) < xo * 0.7 { continue }
                    let target: Float = fb > 1000 ? Float(-log2(fb / 1000)) : 0
                    let idx = kThirdOctaveCenters.indices.filter { kThirdOctaveCenters[$0] >= fb / sqrt(2) && kThirdOctaveCenters[$0] < fb * sqrt(2) && s.snr[$0] >= 10 }
                    if !idx.isEmpty {
                        let dev = idx.map { s.bands[$0] }.reduce(0, +) / Float(idx.count) - target
                        let maxBoost: Float = fb >= 8000 ? 1 : (fb >= 2000 ? 2.5 : 6)
                        eq[b] = max(-8, min(maxBoost, -dev))
                    }
                }
                speakers[i].suggestedEQ = eq
            }
        }

        // ---- warnings
        let lowSNR = speakers.filter { $0.ok }.flatMap { s in (0..<kThirdOctaveCenters.count).filter { kThirdOctaveCenters[$0] >= 100 && kThirdOctaveCenters[$0] <= 8000 && s.snr[$0] < 10 } }
        if !lowSNR.isEmpty { warnings.append("Background noise was high in some bands; those bands were left uncorrected. Try again in a quieter moment or raise the test level.") }
        func bal(_ r: Role) -> Float? { speakers.first { $0.role == r && $0.ok }?.micBalanceDB }
        if let l = bal(.L), let r = bal(.R), l < -2 && r > 2 { warnings.append("Front left was louder in the recorder's right microphone and vice versa: either L/R are swapped, or the recorder faced away from the screen.") }
        if let l = bal(.Ls), let r = bal(.Rs), l < -2 && r > 2 { warnings.append("Surround left/right look swapped from the recorder's point of view (or the recorder faced away from the screen).") }
        for s in speakers where s.ok && s.suggestInvert { warnings.append("\(s.role.name) appears to have inverted polarity compared with the front speakers.") }

        return CalibrationResult(date: Date(), deviceName: deviceName, micSampleRate: fsIn, noiseBands: noiseBands, noiseRMSDB: linToDb(noiseRMS), speakers: speakers, suggestedCrossoverHz: xo, suggestedLFEGainDB: lfeGain, warnings: warnings)
    }


    // MARK: polarity pair test

    func startPolarityCheck() {
        guard !isBusy else { return }
        guard engine.isRunning else { phase = .failed("Start the engine first."); return }
        guard result != nil else { phase = .failed("Run the calibration first; the pair test uses its delays and trims."); return }
        guard let dev = selectedDevice else { phase = .failed("No input device selected."); return }
        cancelled = false
        MicCapture.requestPermission { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.phase = .failed("Microphone access denied."); return }
            Task { @MainActor in await self.runPolarityCheck(device: dev) }
        }
    }

    private func runPolarityCheck(device: AudioDeviceID) async {
        guard let res = result else { return }
        let saved = engine.settings
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: CalibrationResult.preURL, options: .atomic); canRevert = true }
        var t = saved                       // keep encoder, devices, startup and headroom preferences
        t.outInvert = Array(repeating: false, count: 6); t.outMute = Array(repeating: false, count: 6)
        t.delayMs = [0, 0, 0, 0, 0, 0]; t.outGainDB = [0, 0, 0, 0, 0, 0]
        for sp in res.speakers where sp.ok { t.delayMs[sp.role.rawValue] = sp.suggestedDelayMs; t.outGainDB[sp.role.rawValue] = sp.suggestedTrimDB }
        t.lfeGainDB = res.suggestedLFEGainDB
        t.eqEnabled = false; t.bassEnabled = false; t.upmixMode = 0; t.compEnabled = false; t.limEnabled = true; t.limCeilingDB = -0.5
        t.masterGainDB = 0; t.bypass = false; t.width = 1; t.dialogEnhanceDB = 0
        t.autoHeadroomEnabled = false; t.autoHeadroomDB = 0
        engine.calibrationInProgress = true
        engine.settings = t
        engine.stopTests()
        mic.levelHandler = { [weak self] rms in DispatchQueue.main.async { self?.monitorLevelDB = linToDb(rms) } }
        do { try mic.start(device: device, record: true) }
        catch { engine.settings = saved; engine.calibrationInProgress = false; phase = .failed("Could not start the microphone: \(error.localizedDescription)"); return }
        monitoring = true
        phase = .polarity; statusText = "Polarity pair test…"; progress = 0

        let fsOut = 48000.0
        let satSweep = Sweep(fs: fsOut, f1: 80, f2: 400, duration: 2)
        let subSweep = Sweep(fs: fsOut, f1: 40, f2: 160, duration: 3)
        func makeBuffer(_ sw: Sweep) -> (UnsafeMutablePointer<Float>, Int) {
            let sig = sw.signal(); let tail = Int(0.5 * fsOut)
            let p = UnsafeMutablePointer<Float>.allocate(capacity: sig.count + tail)
            p.initialize(repeating: 0, count: sig.count + tail)
            sig.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: sig.count) }
            return (p, sig.count + tail)
        }
        let (satBuf, satN) = makeBuffer(satSweep)
        let (subBuf, subN) = makeBuffer(subSweep)
        let candidates: [Role] = [.R, .C, .LFE, .Ls, .Rs].filter { r in res.speakers.first { $0.role == r }?.ok == true && !(r == .LFE && saved.foldsSub) }
        let conditions = [false, true, false, true]
        let total = Double(max(1, candidates.count * conditions.count))
        var runs: [(Role, Bool, Int)] = []
        var lastHT = engine.processor.testStartHostTime
        var step = 0.0
        try? await Task.sleep(nanoseconds: 500_000_000)
        outer: for role in candidates {
            for inv in conditions {
                if cancelled { break outer }
                statusText = "Polarity: \(role.name) + front left, \(inv ? "inverted" : "as wired")…"
                engine.settings.outInvert[role.rawValue] = inv
                try? await Task.sleep(nanoseconds: 250_000_000)
                let isSub = role == .LFE
                engine.injectBuffer(role: role, samples: UnsafePointer(isSub ? subBuf : satBuf), count: isSub ? subN : satN, gain: dbToLin(testLevelDB), pre: true, role2: .L)
                var ht = lastHT
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 10_000_000); ht = engine.processor.testStartHostTime; if ht != lastHT { break } }
                lastHT = ht
                runs.append((role, inv, mic.sampleIndex(forHostTime: ht)))
                try? await Task.sleep(nanoseconds: UInt64(((isSub ? subSweep.duration : satSweep.duration) + 0.8) * 1_000_000_000))
                step += 1; progress = step / total
            }
        }
        engine.stopTests()
        let fsIn = mic.sampleRate
        let ch0 = mic.channel(0), ch1 = mic.channel(1)
        mic.stop(); monitoring = false
        engine.settings = saved
        engine.calibrationInProgress = false
        satBuf.deallocate(); subBuf.deallocate()
        if cancelled { phase = .idle; statusText = "Cancelled"; return }

        phase = .analysing; statusText = "Analysing polarity…"
        let verdicts: [PolarityVerdict] = await Task.detached(priority: .userInitiated) {
            Calibrator.analysePolarity(ch0: ch0, ch1: ch1, fsIn: fsIn, runs: runs, satSweep: satSweep, subSweep: subSweep)
        }.value
        polarity = verdicts
        var r = res
        for v in verdicts { if let i = r.speakers.firstIndex(where: { $0.role == v.role }) { r.speakers[i].suggestInvert = v.conclusive && v.invert } }
        r.warnings.removeAll { $0.contains("inverted polarity") || $0.contains("inverting sums louder") }
        for v in verdicts where v.conclusive && v.invert { r.warnings.append("\(v.role.name): inverting sums louder with front left. Tick Polarity and apply.") }
        r.polarity = verdicts
        result = r; r.save()
        phase = .done; statusText = verdicts.isEmpty ? "Polarity check produced no usable data." : "Polarity check done."; progress = 1
    }

    nonisolated static func analysePolarity(ch0: [Float], ch1: [Float], fsIn: Double, runs: [(Role, Bool, Int)], satSweep: Sweep, subSweep: Sweep) -> [PolarityVerdict] {
        let n = min(ch0.count, ch1.count)
        var mono = [Float](repeating: 0, count: n)
        vDSP_vadd(ch0, 1, ch1, 1, &mono, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(n))
        let satInv = Sweep(fs: fsIn, f1: satSweep.f1, f2: satSweep.f2, duration: satSweep.duration).inverseFilter()
        let subInv = Sweep(fs: fsIn, f1: subSweep.f1, f2: subSweep.f2, duration: subSweep.duration).inverseFilter()
        let pre = Int(0.1 * fsIn)
        let satSeg = Int((satSweep.duration + 1.0) * fsIn), subSeg = Int((subSweep.duration + 1.0) * fsIn)
        let satD = Deconvolver(inverse: satInv, maxSegmentLength: satSeg), subD = Deconvolver(inverse: subInv, maxSegmentLength: subSeg)
        var levels = [Float](repeating: -200, count: runs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: runs.count) { k in
            let (role, _, start) = runs[k]
            let isSub = role == .LFE
            let d = isSub ? subD : satD, sw = isSub ? subSweep : satSweep, segLen = isSub ? subSeg : satSeg
            let s0 = max(0, start - pre), s1 = min(n, s0 + segLen)
            guard s1 - s0 > d.invCount / 2 else { return }
            let ir = d.deconvolve(Array(mono[s0..<s1]))
            let from = d.invCount - 1 + pre, to = from + Int(1.0 * fsIn)
            let a = SweepAnalysis.analyse(ir: ir, fs: fsIn, searchFrom: from, searchTo: to, windowMs: 150)
            let idx = kThirdOctaveCenters.indices.filter { kThirdOctaveCenters[$0] >= sw.f1 * 1.3 && kThirdOctaveCenters[$0] <= sw.f2 / 1.3 }
            let lv = idx.isEmpty ? Float(-200) : idx.map { a.bandLevels[$0] }.reduce(0, +) / Float(idx.count)
            lock.lock(); levels[k] = lv; lock.unlock()
        }
        var out: [PolarityVerdict] = []
        for role in [Role.R, .C, .LFE, .Ls, .Rs] {
            let offs = runs.indices.filter { runs[$0].0 == role && !runs[$0].1 }.map { levels[$0] }.filter { $0 > -150 }
            let ons = runs.indices.filter { runs[$0].0 == role && runs[$0].1 }.map { levels[$0] }.filter { $0 > -150 }
            guard !offs.isEmpty, !ons.isEmpty else { continue }
            let a = offs.reduce(0, +) / Float(offs.count), b = ons.reduce(0, +) / Float(ons.count)
            let diff = b - a
            out.append(PolarityVerdict(role: role, asWiredDB: a, invertedDB: b, invert: diff > 1.5, conclusive: abs(diff) >= 1.5))
        }
        return out
    }

    // MARK: apply / revert

    func apply() {
        guard let r = result else { return }
        var s = engine.settings
        s.bypass = false
        for sp in r.speakers where sp.ok {
            let i = sp.role.rawValue
            if applyTrims { s.outGainDB[i] = sp.suggestedTrimDB }
            if applyDelays { s.delayMs[i] = sp.suggestedDelayMs }
            if applyEQ { s.eq[i].enabled = true; s.eq[i].gains = sp.suggestedEQ }
            if applyPolarity { s.outInvert[i] = sp.suggestInvert }
        }
        if applyEQ { s.eqEnabled = true }
        if applyCrossover { s.bassEnabled = true; s.crossoverHz = min(120, r.suggestedCrossoverHz); s.lfeLowpassHz = 120 }
        if applySubLevel { s.lfeGainDB = r.suggestedLFEGainDB }
        engine.settings = s
        engine.appendLog("Calibration applied")
        statusText = "Calibration applied."
    }

    func revert() {
        guard let d = try? Data(contentsOf: CalibrationResult.preURL), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return }
        engine.settings = s
        engine.appendLog("Settings restored to the state before calibration")
        statusText = "Restored the settings from before calibration."
    }
}
