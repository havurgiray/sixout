import Foundation

enum Role: Int, CaseIterable, Codable, Identifiable {
    case L = 0, R, C, LFE, Ls, Rs
    var id: Int { rawValue }
    var name: String { ["Front left", "Front right", "Center", "Subwoofer", "Surround left", "Surround right"][rawValue] }
    var short: String { ["L", "R", "C", "LFE", "Ls", "Rs"][rawValue] }
    var voiceFile: String { ["L", "R", "C", "LFE", "Ls", "Rs"][rawValue] }
}

struct ChannelEQ: Codable, Equatable {
    var enabled = true
    var gains: [Float] = Array(repeating: 0, count: 10)
}

struct Settings: Codable, Equatable {
    var bypass = false
    var masterGainDB: Float = 0
    var route: [Int] = [0, 1, 2, 3, 4, 5]
    var outGainDB: [Float] = [0, 0, 0, 0, 0, 0]
    var outMute: [Bool] = [false, false, false, false, false, false]
    var outInvert: [Bool] = [false, false, false, false, false, false]
    var delayMs: [Float] = [0, 0, 0, 0, 0, 0]
    var eqEnabled = false
    var eq: [ChannelEQ] = Array(repeating: ChannelEQ(), count: 6)
    var bassEnabled = false
    var crossoverHz: Float = 100
    var lfeGainDB: Float = 10
    var lfeLowpassHz: Float = 120
    var redirectBass = true
    var upmixMode = 1
    var centerLevelDB: Float = -3
    var surroundLevelDB: Float = -6
    var surroundDelayMs: Float = 12
    var width: Float = 1
    var dialogEnhanceDB: Float = 0
    var compEnabled = false
    var compThresholdDB: Float = -18
    var compRatio: Float = 3
    var compAttackMs: Float = 10
    var compReleaseMs: Float = 200
    var compMakeupDB: Float = 0
    var limEnabled = true
    var limCeilingDB: Float = -0.5
    var limReleaseMs: Float = 80
    var autoStart = true
    var ioCycleSafetyFactor: Double = 8
    var outputDeviceUID: String = ""
    var encoder = 0                       // 0 = AC-3 640 kbit/s, 1 = DTS 1509 kbit/s (experimental)
    var subChannelMode = 0                // 0 = auto (send on the LFE channel; the vendored DTS encoder is fixed), 1 = send on the LFE channel, 2 = fold into fronts
    var foldsSub: Bool { subChannelMode == 2 }
    var orientation = 0                   // 0 normal, 1 turned 90° left, 2 turned 90° right (4.1 modes)
    var phantomCenterDB: Float = -3
    var mediaKeysEnabled = true           // volume keys control SixOut while the output is the SoundPusher device
    var systemVolume: Float = 1           // 0…1, like the macOS slider
    var systemMuted = false
    var autoHeadroomEnabled = true
    var autoHeadroomDB: Float = 0          // gain the auto headroom controller currently applies (≤ 0)
    var autoHeadroomFloorDB: Float = -12

    func makeParams(fs: Float) -> DSPParams {
        var p = DSPParams()
        p.bypass = bypass
        p.masterGain = dbToLin(masterGainDB)
        for i in 0..<6 {
            p.route[i] = Int32(route.indices.contains(i) ? route[i] : i)
            p.outGain[i] = dbToLin(outGainDB[i])
            p.outMute[i] = outMute[i] ? 1 : 0
            p.outInvert[i] = outInvert[i] ? 1 : 0
            p.eqChannelEnabled[i] = eq[i].enabled ? 1 : 0
            for b in 0..<kBands { p.eqGains[i * kBands + b] = b < eq[i].gains.count ? eq[i].gains[b] : 0 }
            p.chDelay[i] = Int32(max(0, min(Float(kMaxChannelDelay - 1), (delayMs.indices.contains(i) ? delayMs[i] : 0) / 1000 * fs)))
        }
        p.eqEnabled = eqEnabled
        p.bassEnabled = bassEnabled
        p.crossoverHz = crossoverHz
        p.lfeGain = dbToLin(lfeGainDB + (encoder == 1 && !foldsSub ? 1.6 : 0))   // DTS LFE decimation/interpolation pair measures −1.6 dB; compensate
        p.lfeLowpassHz = lfeLowpassHz
        p.redirectBass = redirectBass
        p.upmixMode = Int32(upmixMode)
        p.centerGain = dbToLin(centerLevelDB)
        p.surroundGain = dbToLin(surroundLevelDB)
        p.surroundDelayFrames = Int32(max(1, surroundDelayMs / 1000 * fs))
        p.width = width
        p.dialogGain = dbToLin(dialogEnhanceDB)
        p.compEnabled = compEnabled
        p.compThreshold = dbToLin(compThresholdDB)
        p.compRatio = max(1, compRatio)
        p.compAttackCoef = 1 - expf(-1 / (max(0.1, compAttackMs) / 1000 * fs))
        p.compReleaseCoef = 1 - expf(-1 / (max(1, compReleaseMs) / 1000 * fs))
        p.compMakeup = dbToLin(compMakeupDB)
        p.limEnabled = limEnabled
        p.limCeiling = dbToLin(limCeilingDB)
        p.limReleaseCoef = 1 - expf(-1 / (max(1, limReleaseMs) / 1000 * fs))
        p.autoGain = dbToLin(autoHeadroomEnabled ? max(autoHeadroomFloorDB, min(0, autoHeadroomDB)) : 0)
        p.foldLFE = foldsSub
        p.orientation = Int32(orientation)
        p.phantomCenterGain = dbToLin(phantomCenterDB)
        let v = max(0, min(1, systemVolume))
        p.volume = systemMuted ? 0 : v * v      // perceptual curve: 50 % ≈ −12 dB, 25 % ≈ −24 dB
        return p
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SixOut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    /// Loads the settings file. Keys missing from an older file take their default value instead of
    /// rejecting the whole file, so adding fields never wipes a user's settings.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        var s: Settings
        if let direct = try? JSONDecoder().decode(Settings.self, from: data) {
            s = direct
        } else if let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let defData = try? JSONEncoder().encode(Settings()),
                  let defaults = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any],
                  let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, new in new }),
                  let repaired = try? JSONDecoder().decode(Settings.self, from: merged) {
            s = repaired
        } else {
            // keep the unreadable file for inspection instead of overwriting it
            try? FileManager.default.copyItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("unreadable.json"))
            return Settings()
        }
        for i in 0..<6 where s.eq[i].gains.count != kBands {
            var g = Array(repeating: Float(0), count: kBands)
            for (k, v) in s.eq[i].gains.prefix(kBands).enumerated() { g[k] = v }
            s.eq[i].gains = g
        }
        if s.eq.count != 6 { s.eq = Array(repeating: ChannelEQ(), count: 6) }
        if s.delayMs.count != 6 { s.delayMs = [0, 0, 0, 0, 0, 0] }
        if s.route.count != 6 { s.route = [0, 1, 2, 3, 4, 5] }
        if s.outGainDB.count != 6 { s.outGainDB = [0, 0, 0, 0, 0, 0] }
        if s.outMute.count != 6 { s.outMute = Array(repeating: false, count: 6) }
        if s.outInvert.count != 6 { s.outInvert = Array(repeating: false, count: 6) }
        s.encoder = max(0, min(1, s.encoder))
        s.subChannelMode = max(0, min(2, s.subChannelMode))
        s.systemVolume = max(0, min(1, s.systemVolume))
        s.orientation = max(0, min(2, s.orientation))
        s.crossoverHz = max(40, min(120, s.crossoverHz))      // AC3 carries LFE only up to 120 Hz
        s.lfeLowpassHz = max(60, min(120, s.lfeLowpassHz))
        return s
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Settings.fileURL, options: .atomic) }
    }

    /// Compressor presets: (name, enabled, threshold dB, ratio, attack ms, release ms, makeup dB, description)
    static let compressorPresets: [(String, Bool, Float, Float, Float, Float, Float, String)] = [
        ("Off", false, -18, 3, 10, 200, 0, "No dynamics processing. Best for music and for hearing everything the mix has."),
        ("Music glue", true, -10, 1.5, 40, 500, 1, "Barely audible. Slow, shallow; only rounds off the loudest peaks."),
        ("Gentle evening", true, -12, 2, 30, 400, 2, "Mild leveling for late listening without losing the punch of transients."),
        ("TV & dialogue", true, -18, 3, 15, 300, 4, "Keeps speech at a steady level and tames loud ads and action scenes."),
        ("Night mode (strong)", true, -24, 4, 5, 250, 6, "Squashes almost everything: quiet parts up, loud parts down. Audible pumping; use only when you must keep the volume very low."),
    ]

    mutating func applyCompressorPreset(_ i: Int) {
        let p = Settings.compressorPresets[i]
        compEnabled = p.1; compThresholdDB = p.2; compRatio = p.3; compAttackMs = p.4; compReleaseMs = p.5; compMakeupDB = p.6
    }

    static let presets: [(String, (inout Settings) -> Void)] = [
        ("Flat (pass everything through)", { s in
            s.eqEnabled = false; s.bassEnabled = false; s.upmixMode = 0; s.compEnabled = false; s.limEnabled = true
            s.width = 1; s.dialogEnhanceDB = 0; s.lfeGainDB = 0; s.masterGainDB = 0
        }),
        ("Movie (recommended)", { s in
            s.upmixMode = 1; s.centerLevelDB = -3; s.surroundLevelDB = -6; s.surroundDelayMs = 12
            s.bassEnabled = true; s.crossoverHz = 120; s.lfeGainDB = 10; s.lfeLowpassHz = 120; s.redirectBass = true
            s.eqEnabled = true
            for i in 0..<6 { s.eq[i].enabled = true; s.eq[i].gains = i == 3 ? Array(repeating: 0, count: 10) : [0, 0, 0, -1, 0, 0, 1, 1, 2, 1] }
            s.dialogEnhanceDB = 2; s.compEnabled = false; s.limEnabled = true; s.limCeilingDB = -0.5; s.masterGainDB = 0
        }),
        ("Night mode (quiet, even loudness)", { s in
            s.compEnabled = true; s.compThresholdDB = -24; s.compRatio = 4; s.compAttackMs = 5; s.compReleaseMs = 250; s.compMakeupDB = 6
            s.limEnabled = true; s.limCeilingDB = -1; s.dialogEnhanceDB = 4; s.lfeGainDB = 4; s.bassEnabled = true; s.upmixMode = 1
        }),
        ("Music (wide stereo, no upmix)", { s in
            s.upmixMode = 0; s.width = 1.3; s.compEnabled = false; s.eqEnabled = false; s.bassEnabled = true; s.lfeGainDB = 6; s.dialogEnhanceDB = 0
        }),
    ]
}
