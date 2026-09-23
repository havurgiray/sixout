import Foundation
import Combine

/// A listening-position profile: everything a calibration produces for one seat, plus the orientation used there.
struct SpeakerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date = Date()
    var orientation: Int
    var phantomCenterDB: Float
    var outGainDB: [Float]
    var delayMs: [Float]
    var outInvert: [Bool]
    var lfeGainDB: Float
    var bassEnabled: Bool
    var crossoverHz: Float
    var lfeLowpassHz: Float
    var subChannelMode: Int
    var eqEnabled: Bool? = nil
    var eq: [ChannelEQ]? = nil
    var calibrationDate: Date? = nil
    var calibrationDevice: String? = nil
    var includesEQ: Bool { eq != nil }

    static func capture(from s: Settings, name: String, includeEQ: Bool, calibration: CalibrationResult?) -> SpeakerProfile {
        var p = SpeakerProfile(name: name, orientation: s.orientation, phantomCenterDB: s.phantomCenterDB, outGainDB: s.outGainDB, delayMs: s.delayMs, outInvert: s.outInvert,
                               lfeGainDB: s.lfeGainDB, bassEnabled: s.bassEnabled, crossoverHz: s.crossoverHz, lfeLowpassHz: s.lfeLowpassHz, subChannelMode: s.subChannelMode)
        if includeEQ { p.eqEnabled = s.eqEnabled; p.eq = s.eq }
        p.calibrationDate = calibration?.date; p.calibrationDevice = calibration?.deviceName
        return p
    }

    func apply(to s: inout Settings) {
        s.orientation = max(0, min(2, orientation)); s.phantomCenterDB = phantomCenterDB
        if outGainDB.count == 6 { s.outGainDB = outGainDB }
        if delayMs.count == 6 { s.delayMs = delayMs }
        if outInvert.count == 6 { s.outInvert = outInvert }
        s.lfeGainDB = lfeGainDB; s.bassEnabled = bassEnabled
        s.crossoverHz = max(40, min(120, crossoverHz)); s.lfeLowpassHz = max(60, min(120, lfeLowpassHz))
        s.subChannelMode = max(0, min(2, subChannelMode))
        if let e = eq, e.count == 6 { s.eq = e; for i in 0..<6 where s.eq[i].gains.count != kBands { s.eq[i].gains = Array(repeating: 0, count: kBands) } }
        if let en = eqEnabled { s.eqEnabled = en }
    }

    var summary: String {
        let o = ["normal 5.1", "turned left 4.1", "turned right 4.1"][max(0, min(2, orientation))]
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return "\(name)  (\(o)\(includesEQ ? ", with EQ" : ""), \(f.string(from: date)))"
    }
}

@MainActor
final class SpeakerProfileStore: ObservableObject {
    static let shared = SpeakerProfileStore()
    @Published private(set) var profiles: [SpeakerProfile] = []
    static let fileURL = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("speaker-profiles.json")

    private init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: SpeakerProfileStore.fileURL), let p = try? JSONDecoder().decode([SpeakerProfile].self, from: d) else { profiles = []; return }
        profiles = p.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(profiles) { try? d.write(to: SpeakerProfileStore.fileURL, options: .atomic) }
    }

    func save(_ profile: SpeakerProfile) {
        profiles.removeAll { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }
        profiles.append(profile)
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(id: UUID) { profiles.removeAll { $0.id == id }; persist() }
}
