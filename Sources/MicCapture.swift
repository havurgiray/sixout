import Foundation
import AVFoundation
import CoreAudio
import Accelerate

struct InputDevice: Identifiable, Hashable { let id: AudioDeviceID; let uid: String; let name: String; let channels: Int }

/// Records from a chosen input device with AVAudioEngine and keeps a sample-accurate timeline.
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var sampleRate: Double = 48000
    private(set) var channels: Int = 1
    private var hostTime0: UInt64 = 0
    private var samplesSoFar: Int = 0
    private var recording = false
    private var lock = NSLock()
    private var buffers: [[Float]] = []          // per channel
    private(set) var isRunning = false
    var levelHandler: ((Float) -> Void)?
    /// Set when Core Audio reconfigured the input (device change, sample-rate change, USB re-enumeration).
    private(set) var interruptions = 0
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.interruptions += 1
            // the engine stops itself on a configuration change; try to keep going
            self.engine.prepare()
            try? self.engine.start()
        }
    }
    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    static func inputDevices() -> [InputDevice] {
        var out: [InputDevice] = []
        for d in CoreAudioInfo.allDevices() {
            var a = CoreAudioInfo.addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput); var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &sz) == noErr, sz > 0 else { continue }
            var ca = CoreAudioInfo.addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput); var csz: UInt32 = 0
            var chans = 0
            if AudioObjectGetPropertyDataSize(d, &ca, 0, nil, &csz) == noErr, csz > 0 {
                let p = UnsafeMutableRawPointer.allocate(byteCount: Int(csz), alignment: 8); defer { p.deallocate() }
                if AudioObjectGetPropertyData(d, &ca, 0, nil, &csz, p) == noErr {
                    let abl = UnsafeMutableAudioBufferListPointer(p.assumingMemoryBound(to: AudioBufferList.self))
                    for b in abl { chans += Int(b.mNumberChannels) }
                }
            }
            var ta = CoreAudioInfo.addr(kAudioDevicePropertyTransportType); var tt: UInt32 = 0; var tsz = UInt32(4)
            AudioObjectGetPropertyData(d, &ta, 0, nil, &tsz, &tt)
            if tt == kAudioDeviceTransportTypeVirtual || tt == kAudioDeviceTransportTypeAggregate { continue }
            let uid = CoreAudioInfo.string(d, kAudioDevicePropertyDeviceUID)
            if uid.hasPrefix("local.sixout") || uid.hasPrefix("local.SixOut") || chans == 0 { continue }
            out.append(InputDevice(id: d, uid: uid, name: CoreAudioInfo.string(d, kAudioObjectPropertyName), channels: chans))
        }
        return out
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }

    func start(device: AudioDeviceID, record: Bool) throws {
        stop()
        let input = engine.inputNode
        var dev = device
        if let au = input.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { throw NSError(domain: "MicCapture", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Could not select the input device (\(st))"]) }
        }
        let fmt = input.inputFormat(forBus: 0)
        sampleRate = fmt.sampleRate
        channels = max(1, Int(fmt.channelCount))
        recording = record
        interruptions = 0
        hostTime0 = 0; samplesSoFar = 0
        buffers = Array(repeating: [], count: min(2, channels))
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, when in
            guard let self = self else { return }
            let n = Int(buf.frameLength)
            guard n > 0, let data = buf.floatChannelData else { return }
            self.lock.lock()
            if self.hostTime0 == 0 { self.hostTime0 = when.hostTime }
            if self.recording {
                for c in 0..<self.buffers.count { self.buffers[c].append(contentsOf: UnsafeBufferPointer(start: data[min(c, Int(buf.format.channelCount) - 1)], count: n)) }
            }
            self.samplesSoFar += n
            self.lock.unlock()
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(n))
            self.levelHandler?(rms)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop(); isRunning = false }
    }

    /// Sample index in the recording that corresponds to a mach host time.
    func sampleIndex(forHostTime ht: UInt64) -> Int {
        lock.lock(); let h0 = hostTime0; lock.unlock()
        guard h0 != 0 else { return 0 }
        let secs = AVAudioTime.seconds(forHostTime: ht) - AVAudioTime.seconds(forHostTime: h0)
        return Int(secs * sampleRate)
    }

    var recordedFrames: Int { lock.lock(); defer { lock.unlock() }; return buffers.first?.count ?? 0 }

    func channel(_ c: Int) -> [Float] { lock.lock(); defer { lock.unlock() }; return buffers.indices.contains(c) ? buffers[c] : (buffers.first ?? []) }

    var hostTimeAtStart: UInt64 { lock.lock(); defer { lock.unlock() }; return hostTime0 }
}
