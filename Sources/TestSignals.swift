import Foundation
import AVFoundation

/// Mono test buffers kept alive for the audio thread.
final class TestSignals {
    struct Sound { let ptr: UnsafeMutablePointer<Float>; let count: Int }
    private(set) var voices: [Role: Sound] = [:]
    private(set) var pinkNoise: Sound
    let sampleRate: Double = 48000

    init() {
        // pink noise, 1.5 s (Paul Kellet's filter)
        let n = Int(48000 * 1.5)
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        for i in 0..<n {
            let w = Float.random(in: -1...1)
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856; b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
            b6 = w * 0.115926
            // fade in/out
            let fade = min(1, Float(min(i, n - 1 - i)) / 2400)
            p[i] = pink * fade
        }
        pinkNoise = Sound(ptr: p, count: n)
        for role in Role.allCases {
            if let url = Bundle.main.url(forResource: role.voiceFile, withExtension: "wav", subdirectory: "voices") ?? Bundle.main.url(forResource: role.voiceFile, withExtension: "wav"),
               let s = TestSignals.load(url: url) { voices[role] = s }
        }
    }

    private static func load(url: URL) -> Sound? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: fmt) else { return nil }
        let inCap = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap), (try? file.read(into: inBuf)) != nil else { return nil }
        let outCap = AVAudioFrameCount(Double(inCap) * 48000 / file.processingFormat.sampleRate + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap) else { return nil }
        var consumed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else { return nil }
        // pad with 0.4 s of silence so the tail is audible before the next item
        let pad = 19200
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n + pad)
        p.initialize(from: ch, count: n)
        (p + n).initialize(repeating: 0, count: pad)
        return Sound(ptr: p, count: n + pad)
    }
}
