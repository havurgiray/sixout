import Foundation
import AppKit
import CoreAudio
import ServiceManagement
import Combine

struct OutputDevice: Identifiable, Hashable { let uid: String; let name: String; var id: String { uid } }

/// Live values that change many times per second. Kept on a separate object so only the small meter views re-render.
struct MeterState: Equatable {
    var inPeak = [Float](repeating: 0, count: 6)
    var outPeak = [Float](repeating: 0, count: 6)
    var contentClass = 0
    var upmixAmount: Float = 0
    var limGRNow: Float = 0
    var limGRPeak: Float = 0
    var limActivePercent: Float = 0
    var clipEvents = 0
    var inClipEvents = 0
}

@MainActor
final class LiveMeters: ObservableObject {
    @Published var state = MeterState()
}

/// The live volume, on its own object so key presses re-render only the volume control, not the whole window.
@MainActor
final class VolumeModel: ObservableObject {
    @Published var value: Float = 1
    @Published var muted = false
    var gain: Float { muted ? 0 : max(0, min(1, value)) * max(0, min(1, value)) }
}

private let processCallback: SLProcessFn = { ctx, buf, frames, channels in
    guard let ctx = ctx, let buf = buf else { return }
    let engine = Unmanaged<EngineController>.fromOpaque(ctx).takeUnretainedValue()
    engine.processor.process(buf, Int(frames), Int(channels))
}

private let eventCallback: SLEventFn = { ctx, code, message in
    guard let ctx = ctx else { return }
    let engine = Unmanaged<EngineController>.fromOpaque(ctx).takeUnretainedValue()
    let msg = message.map { String(cString: $0) } ?? "Engine event \(code)"
    DispatchQueue.main.async { engine.handleEvent(code: Int(code), message: msg) }
}

@MainActor
final class EngineController: ObservableObject {
    static let shared = EngineController()
    static let sourceUID = "de.maven.audio.SoundPusherAudioDevice_v001"
    static let boxUID = "de.maven.audio.SoundPusherAudioBox_v001"
    static let soundPusherBundleID = "de.maven.SoundPusher"

    nonisolated let processor = Processor()
    let signals = TestSignals()
    let meters = LiveMeters()
    let volume = VolumeModel()

    @Published var settings: Settings {
        didSet {
            pushParams(); saveSoon()
            if oldValue.encoder != settings.encoder && isRunning && !calibrationInProgress {
                appendLog("Encoder changed; restarting the engine")
                stop(); start()
            }
            if oldValue.mediaKeysEnabled != settings.mediaKeysEnabled { updateMediaKeys() }
        }
    }
    /// Set by the calibrator while a measurement runs so settings churn does not restart the engine.
    var calibrationInProgress = false
    @Published private(set) var codecDescription = ""
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Stopped"
    @Published var lastError: String? = nil
    private var inMeters = [Float](repeating: 0, count: 6)
    private var outMeters = [Float](repeating: 0, count: 6)
    private var limGRPeakHold: Float = 0
    @Published private(set) var hdmiFormat = "unknown"
    @Published private(set) var soundPusherRunning = false
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published private(set) var sourceDevicePresent = false
    @Published private(set) var playingRole: Role? = nil
    @Published private(set) var playingSlot: Int? = nil
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled { didSet { setLaunchAtLogin(launchAtLogin) } }
    @Published private(set) var log: [String] = []
    /// Convenience accessors for code that needs the latest live values.
    var currentInMeters: [Float] { inMeters }
    var currentOutMeters: [Float] { outMeters }
    private var grHistory: [Float] = []
    private var fracHistory: [Float] = []
    private var quietSeconds: Double = 0
    private var lastAutoChange = Date.distantPast
    private var clipHistory: [Int] = []
    private var inClipHistory: [Int] = []

    private var meterTimer: Timer?
    private var slowTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var testSerial: UInt32 = 0
    private var sequence: [Role] = []
    private var sequenceIsSlots = false
    private var sequenceWork: DispatchWorkItem?
    private var boxAcquired = false

    @Published private(set) var mediaKeysActive = false
    @Published private(set) var accessibilityGranted = MediaKeys.hasAccessibilityPermission
    private var defaultOutputIsOurs = false

    private init() {
        settings = Settings.load()
        volume.value = settings.systemVolume; volume.muted = settings.systemMuted
        pushParams()
        refreshDevices()
        setupMediaKeys()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickFast() } }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickSlow() } }
        tickSlow()
    }

    // MARK: engine control

    func start() {
        lastError = nil
        if isRunning { return }
        quitSoundPusherIfRunning()
        var err = [CChar](repeating: 0, count: 512)
        if !boxAcquired {
            boxAcquired = sl_acquire_box(EngineController.boxUID, &err, Int32(err.count))
            if !boxAcquired { appendLog("Could not acquire SoundPusher device box: \(String(cString: err))") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        refreshDevices()
        let outUID = resolvedOutputUID()
        guard !outUID.isEmpty else {
            lastError = "No HDMI output with a digital bitstream format was found. Check the HDMI chain is connected and Audio MIDI Setup lists AC3 or DTS under Encoded Digital Audio Formats."
            status = "No bitstream output device"; return
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = sl_engine_start(EngineController.sourceUID, outUID, settings.ioCycleSafetyFactor, false, Int32(settings.encoder), 0, processCallback, eventCallback, ctx, &err, Int32(err.count))
        if rc == 0 {
            isRunning = true
            let name = outputDevices.first { $0.uid == outUID }?.name ?? outUID
            let codec = String(cString: sl_engine_codec_name()).uppercased().replacingOccurrences(of: "DCA", with: "DTS")
            codecDescription = "\(codec) \(sl_engine_bit_rate() / 1000) kbit/s"
            status = "Running → \(name) (\(codecDescription), \(sl_engine_frames_per_packet()) frames/packet)"
            appendLog("Engine started to \(name) with \(codec) at \(sl_engine_bit_rate() / 1000) kbit/s")
        } else {
            let msg = String(cString: err)
            lastError = "Engine start failed (\(rc)): \(msg)"
            status = "Failed"
            appendLog(lastError!)
        }
    }

    func stop() {
        stopTests()
        if isRunning { sl_engine_stop(); appendLog("Engine stopped") }
        isRunning = false
        status = "Stopped"
        codecDescription = ""
        saveNow()
    }

    func shutdown() {
        stop()
        if boxAcquired { sl_release_box(); boxAcquired = false }
        saveNow()
    }

    /// Writes the settings immediately (used on stop/quit so a change made just before is not lost).
    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        settingsForSaving().save()
    }

    func handleEvent(code: Int, message: String) {
        isRunning = sl_engine_is_running()
        if !isRunning { status = "Stopped: \(message)" }
        appendLog(message)
    }

    func quitSoundPusherIfRunning() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: EngineController.soundPusherBundleID)
        guard !apps.isEmpty else { return }
        appendLog("Quitting the SoundPusher app (SixOut takes over its job while running)")
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && !NSRunningApplication.runningApplications(withBundleIdentifier: EngineController.soundPusherBundleID).isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        soundPusherRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: EngineController.soundPusherBundleID).isEmpty
    }

    func relaunchSoundPusher() {
        stop()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EngineController.soundPusherBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: parameters

    private func pushParams() {
        var p = settings.makeParams(fs: processor.fs)
        p.volume = volume.gain
        processor.update(p)
    }

    /// Settings with the live volume merged in (the volume lives on its own object to keep key presses cheap).
    private func settingsForSaving() -> Settings { var s = settings; s.systemVolume = volume.value; s.systemMuted = volume.muted; return s }

    /// Called by the volume control and the volume keys.
    func volumeChanged() { pushParams(); saveSoon() }

    private func saveSoon() {
        saveWork?.cancel()
        let s = settingsForSaving()
        let w = DispatchWorkItem { s.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func applyPreset(_ index: Int) {
        var s = settings
        Settings.presets[index].1(&s)
        settings = s
    }

    /// From "output slot s was heard from speaker role r" build the routing that fixes it.
    func applyWiringFix(heard: [Int]) -> String? {
        guard heard.count == 6 else { return "Incomplete" }
        if Set(heard).count != 6 { return "Each speaker can be chosen only once. Two outputs were assigned the same speaker." }
        var route = [Int](repeating: 0, count: 6)
        for slot in 0..<6 { route[slot] = heard[slot] }
        settings.route = route
        return nil
    }

    // MARK: tests

    func playRole(_ role: Role, kind: TestKind = .voice) {
        // injected before processing: delays, trims, EQ, the sub fold and the wiring fix all apply, like real content
        playingRole = role; playingSlot = nil
        inject(slot: role.rawValue, role: role, kind: kind, pre: true)
    }

    func playSlot(_ slot: Int, kind: TestKind = .voice) {
        playingSlot = slot; playingRole = nil
        inject(slot: slot, role: Role(rawValue: slot)!, kind: kind)
    }

    enum TestKind { case voice, noise }

    private func inject(slot: Int, role: Role, kind: TestKind, pre: Bool = false) {
        let sound: TestSignals.Sound?
        switch kind {
        case .voice: sound = signals.voices[role]
        case .noise: sound = signals.pinkNoise
        }
        guard let s = sound else { return }
        testSerial &+= 1
        var cmd = TestCommand()
        cmd.serial = testSerial; cmd.active = true; cmd.slot = Int32(slot); cmd.pre = pre
        cmd.samples = UnsafePointer(s.ptr); cmd.count = Int32(s.count); cmd.gain = 0.35
        cmd.subTone = (role == .LFE) || (slot == 3 && kind == .voice && playingSlot != nil)
        processor.setTest(cmd)
    }

    /// Injects an arbitrary mono buffer on the output slot that carries `role` (used by calibration). Returns the slot.
    /// `pre` injects into the content channels before all processing (delays, trims, inversion apply);
    /// otherwise the signal is added after the wiring fix on the slot that carries the role.
    @discardableResult
    func injectBuffer(role: Role, samples: UnsafePointer<Float>, count: Int, gain: Float, pre: Bool = false, role2: Role? = nil) -> Int {
        let slot = pre ? role.rawValue : (settings.route.firstIndex(of: role.rawValue) ?? role.rawValue)
        var slot2 = -1
        if let r2 = role2 { slot2 = pre ? r2.rawValue : (settings.route.firstIndex(of: r2.rawValue) ?? r2.rawValue) }
        testSerial &+= 1
        var cmd = TestCommand()
        cmd.serial = testSerial; cmd.active = true; cmd.slot = Int32(slot); cmd.slot2 = Int32(slot2); cmd.pre = pre
        cmd.samples = samples; cmd.count = Int32(count); cmd.gain = gain; cmd.subTone = false
        processor.setTest(cmd)
        return slot
    }

    func playAllRoles() {
        sequence = Role.allCases; sequenceIsSlots = false
        stepSequence()
    }

    func playAllSlots() {
        sequence = Role.allCases; sequenceIsSlots = true
        stepSequence()
    }

    private func stepSequence() {
        sequenceWork?.cancel()
        guard !sequence.isEmpty else { playingRole = nil; playingSlot = nil; return }
        let r = sequence.removeFirst()
        if sequenceIsSlots { playSlot(r.rawValue) } else { playRole(r) }
        let dur = Double(signals.voices[r]?.count ?? 48000) / 48000 + 0.3
        let w = DispatchWorkItem { [weak self] in self?.stepSequence() }
        sequenceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: w)
    }

    func stopTests() {
        sequence.removeAll(); sequenceWork?.cancel()
        testSerial &+= 1
        var cmd = TestCommand(); cmd.serial = testSerial; cmd.active = false
        processor.setTest(cmd)
        playingRole = nil; playingSlot = nil
    }

    // MARK: periodic

    private func tickFast() {
        var i = inMeters, o = outMeters
        for c in 0..<6 {
            let ip = processor.inPeak[c]; processor.inPeak[c] = 0
            let op = processor.outPeak[c]; processor.outPeak[c] = 0
            i[c] = max(ip, i[c] * 0.8); o[c] = max(op, o[c] * 0.8)
        }
        inMeters = i; outMeters = o
        var st = MeterState()
        // quantise to 0.5 dB steps so the views (and their text) only re-render on visible changes
        func q(_ v: Float) -> Float { v < 1e-4 ? 0 : dbToLin((linToDb(v) * 2).rounded() / 2) }
        st.inPeak = i.map(q); st.outPeak = o.map(q)
        st.contentClass = Int(processor.contentClass)
        st.upmixAmount = (processor.upmixActive * 20).rounded() / 20
        autoHeadroomTick(&st)
        st.limGRNow = (st.limGRNow * 2).rounded() / 2; st.limGRPeak = (st.limGRPeak * 2).rounded() / 2; st.limActivePercent = st.limActivePercent.rounded()
        // publish only on a visible change, and only while the window can actually be seen (menu-bar-only use costs nothing)
        let windowVisible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.title == "SixOut" }
        if windowVisible && st != meters.state { meters.state = st }
        if processor.testFinishedSerial == testSerial && sequence.isEmpty && (playingRole != nil || playingSlot != nil) && sequenceWork == nil {
            playingRole = nil; playingSlot = nil
        }
    }

    /// Keeps the limiter out of the way: backs the gain off when it works hard, restores it slowly when idle.
    private func autoHeadroomTick(_ st: inout MeterState) {
        let gr = processor.limGRMaxDB; processor.limGRMaxDB = 0
        let active = processor.limActiveFrames, total = processor.limTotalFrames
        processor.limActiveFrames = 0; processor.limTotalFrames = 0
        let clips = processor.clipCount; processor.clipCount = 0
        let inClips = processor.inClipCount; processor.inClipCount = 0
        inClipHistory.append(inClips); if inClipHistory.count > 60 { inClipHistory.removeFirst() }
        st.inClipEvents = inClipHistory.reduce(0, +)
        let frac = total > 0 ? Float(active) / Float(total) : 0
        limGRPeakHold = max(gr, limGRPeakHold * 0.95)
        grHistory.append(gr); if grHistory.count > 20 { grHistory.removeFirst() }
        fracHistory.append(frac); if fracHistory.count > 20 { fracHistory.removeFirst() }
        clipHistory.append(clips); if clipHistory.count > 60 { clipHistory.removeFirst() }
        st.limGRNow = processor.limGRNowDB
        st.limGRPeak = limGRPeakHold
        st.limActivePercent = 100 * (fracHistory.reduce(0, +) / Float(max(1, fracHistory.count)))
        st.clipEvents = clipHistory.reduce(0, +)
        guard isRunning, settings.autoHeadroomEnabled, settings.limEnabled, !settings.bypass else { return }
        let gr1s = grHistory.max() ?? 0
        let frac1s = fracHistory.reduce(0, +) / Float(max(1, fracHistory.count))
        let signal = (inMeters.max() ?? 0) > dbToLin(-45)
        let now = Date()
        var g = settings.autoHeadroomDB
        var changed = false
        if gr1s > 6 && now.timeIntervalSince(lastAutoChange) > 0.3 {
            g -= 1; changed = true                                    // gross overload: back off quickly
        } else if frac1s > 0.3 && now.timeIntervalSince(lastAutoChange) > 1.0 {
            g -= 0.5; changed = true                                  // limiting most of the time: creep down
        } else if signal && gr1s < 0.5 {
            quietSeconds += 1.0 / 20
            if quietSeconds > 20 && g < 0 { g += 0.25; quietSeconds = 15; changed = true }   // idle limiter: restore slowly
        } else if gr1s >= 0.5 {
            quietSeconds = 0
        }
        g = max(settings.autoHeadroomFloorDB, min(0, g))
        if changed && g != settings.autoHeadroomDB {
            settings.autoHeadroomDB = g
            lastAutoChange = now
            grHistory.removeAll(); fracHistory.removeAll()
        }
    }

    // MARK: volume keys

    private func setupMediaKeys() {
        let keys = MediaKeys.shared
        keys.shouldHandle = { [weak self] in
            guard let self = self else { return false }
            return self.settings.mediaKeysEnabled && self.defaultOutputIsOurs
        }
        keys.onVolume = { [weak self] dir in self?.stepVolume(dir) }
        keys.onMute = { [weak self] in self?.toggleMute() }
        updateMediaKeys()
    }

    private var promptedAccessibility = false
    func updateMediaKeys() {
        let granted = MediaKeys.hasAccessibilityPermission
        if granted != accessibilityGranted { accessibilityGranted = granted }
        if settings.mediaKeysEnabled && accessibilityGranted {
            let wasInstalled = MediaKeys.shared.isInstalled
            let active = MediaKeys.shared.install()
            if active != mediaKeysActive { mediaKeysActive = active }
            if active && !wasInstalled { appendLog("Volume keys: event tap installed") }
            if !active { appendLog("Volume keys: Accessibility is granted but the event tap could not be created; toggle SixOut off and on in System Settings → Privacy & Security → Accessibility") }
        } else {
            MediaKeys.shared.uninstall(); if mediaKeysActive { mediaKeysActive = false }
            if settings.mediaKeysEnabled && !promptedAccessibility && !CommandLine.arguments.contains("--selftest") {
                promptedAccessibility = true
                MediaKeys.requestAccessibilityPermission()   // system dialog pointing to Privacy & Security → Accessibility
            }
        }
    }

    func requestAccessibility() {
        MediaKeys.requestAccessibilityPermission()
        appendLog("Requested the Accessibility permission for the volume keys; enable SixOut in System Settings → Privacy & Security → Accessibility")
    }

    func stepVolume(_ direction: Int) {
        let step: Float = MediaKeys.shared.fineStep ? 1.0 / 64 : 1.0 / 16
        var v = volume.value + Float(direction) * step
        v = (v * 64).rounded() / 64
        v = max(0, min(1, v))
        volume.value = v
        if v > 0 && volume.muted { volume.muted = false }
        volumeChanged()
        VolumeBezel.shared.show(volume: v, muted: volume.muted)
    }

    func toggleMute() {
        volume.muted.toggle()
        volumeChanged()
        VolumeBezel.shared.show(volume: volume.value, muted: volume.muted)
    }

    private func tickSlow() {
        defaultOutputIsOurs = CoreAudioInfo.defaultOutputUID() == EngineController.sourceUID
        // keep trying while the option is on and the tap is not up: the grant can arrive at any time
        if settings.mediaKeysEnabled && !MediaKeys.shared.isInstalled { updateMediaKeys() }
        else if accessibilityGranted != MediaKeys.hasAccessibilityPermission { updateMediaKeys() }
        // assign published values only when they change: every assignment re-renders the whole window
        let spRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: EngineController.soundPusherBundleID).isEmpty
        if spRunning != soundPusherRunning { soundPusherRunning = spRunning }
        let raw = CoreAudioInfo.currentFormatDescription(uid: resolvedOutputUID())
        let fmt = (raw.hasPrefix("bitstream") && isRunning && !codecDescription.isEmpty) ? "bitstream, \(codecDescription)" : raw
        if fmt != hdmiFormat { hdmiFormat = fmt }
        let present = CoreAudioInfo.deviceID(uid: EngineController.sourceUID) != nil
        if present != sourceDevicePresent { sourceDevicePresent = present }
        if isRunning != sl_engine_is_running() { isRunning = sl_engine_is_running(); if !isRunning { status = "Stopped" } }
        if outputDevices.isEmpty { let d = CoreAudioInfo.devicesWithAC3(); if !d.isEmpty { outputDevices = d } }
    }

    func refreshDevices() {
        outputDevices = CoreAudioInfo.devicesWithAC3()
    }

    func resolvedOutputUID() -> String {
        if !settings.outputDeviceUID.isEmpty, outputDevices.contains(where: { $0.uid == settings.outputDeviceUID }) { return settings.outputDeviceUID }
        return outputDevices.first?.uid ?? ""
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { appendLog("Launch at login: \(error.localizedDescription)") }
    }

    func appendLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// Small CoreAudio queries used for status display.
enum CoreAudioInfo {
    static func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var a = addr(sel); var sz = UInt32(MemoryLayout<CFString?>.size); var v: Unmanaged<CFString>? = nil
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, $0) }
        guard st == noErr, let cf = v else { return "" }
        return cf.takeRetainedValue() as String
    }
    static func allDevices() -> [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / 4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids
    }
    static func deviceID(uid: String) -> AudioDeviceID? { allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid } }
    static func defaultOutputUID() -> String {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev: AudioDeviceID = 0; var sz = UInt32(4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return "" }
        return string(dev, kAudioDevicePropertyDeviceUID)
    }
    static func outputStreams(_ dev: AudioDeviceID) -> [AudioStreamID] {
        var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
        var s = [AudioStreamID](repeating: 0, count: Int(sz) / 4)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &s) == noErr else { return [] }
        return s
    }
    static func fourcc(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "?"
    }
    static func devicesWithAC3() -> [OutputDevice] {
        var out: [OutputDevice] = []
        for d in allDevices() {
            let uid = string(d, kAudioDevicePropertyDeviceUID)
            if uid.hasPrefix("local.sixout") || uid.hasPrefix("local.SixOut") || uid.hasPrefix("de.maven.SoundPusher.Aggregate") { continue }
            var has = false
            for s in outputStreams(d) {
                var a = addr(kAudioStreamPropertyAvailablePhysicalFormats); var sz: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(s, &a, 0, nil, &sz) == noErr, sz > 0 else { continue }
                let n = Int(sz) / MemoryLayout<AudioStreamRangedDescription>.stride
                var fmts = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: n)
                guard AudioObjectGetPropertyData(s, &a, 0, nil, &sz, &fmts) == noErr else { continue }
                if fmts.contains(where: { $0.mFormat.mFormatID == kAudioFormat60958AC3 || $0.mFormat.mFormatID == kAudioFormatAC3 }) { has = true; break }
            }
            if has { out.append(OutputDevice(uid: uid, name: string(d, kAudioObjectPropertyName))) }
        }
        return out
    }
    static func currentFormatDescription(uid: String) -> String {
        guard !uid.isEmpty, let d = deviceID(uid: uid), let s = outputStreams(d).first else { return "no device" }
        var a = addr(kAudioStreamPropertyPhysicalFormat); var f = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(s, &a, 0, nil, &sz, &f) == noErr else { return "?" }
        let id = f.mFormatID == kAudioFormat60958AC3 ? "bitstream (IEC 61937)" : (f.mFormatID == kAudioFormatLinearPCM ? "PCM \(f.mChannelsPerFrame) ch" : fourcc(f.mFormatID))
        return "\(id) @ \(Int(f.mSampleRate)) Hz"
    }
}
