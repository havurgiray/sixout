import Foundation
import Combine

/// A named EQ snapshot: the six per-speaker curves, the EQ switch, and optionally the bass-management block.
struct EQPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date = Date()
    var eqEnabled: Bool
    var eq: [ChannelEQ]
    var bassEnabled: Bool? = nil
    var crossoverHz: Float? = nil
    var lfeGainDB: Float? = nil
    var lfeLowpassHz: Float? = nil
    var redirectBass: Bool? = nil
    var includesBass: Bool { bassEnabled != nil }

    static func capture(from s: Settings, name: String, includeBass: Bool) -> EQPreset {
        var p = EQPreset(name: name, eqEnabled: s.eqEnabled, eq: s.eq)
        if includeBass { p.bassEnabled = s.bassEnabled; p.crossoverHz = s.crossoverHz; p.lfeGainDB = s.lfeGainDB; p.lfeLowpassHz = s.lfeLowpassHz; p.redirectBass = s.redirectBass }
        return p
    }

    func apply(to s: inout Settings) {
        s.eqEnabled = eqEnabled
        s.eq = eq.count == 6 ? eq : s.eq
        for i in 0..<6 where s.eq[i].gains.count != kBands { s.eq[i].gains = Array(repeating: 0, count: kBands) }
        if let b = bassEnabled { s.bassEnabled = b }
        if let v = crossoverHz { s.crossoverHz = max(40, min(120, v)) }
        if let v = lfeGainDB { s.lfeGainDB = v }
        if let v = lfeLowpassHz { s.lfeLowpassHz = max(60, min(120, v)) }
        if let v = redirectBass { s.redirectBass = v }
    }
}

@MainActor
final class EQPresetStore: ObservableObject {
    static let shared = EQPresetStore()
    @Published private(set) var presets: [EQPreset] = []
    static let fileURL = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("eq-presets.json")

    private init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: EQPresetStore.fileURL), let p = try? JSONDecoder().decode([EQPreset].self, from: d) else { presets = []; return }
        presets = p.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(presets) { try? d.write(to: EQPresetStore.fileURL, options: .atomic) }
    }

    /// Saves under `name`, replacing an existing preset with the same name.
    func save(_ preset: EQPreset) {
        presets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(id: UUID) { presets.removeAll { $0.id == id }; persist() }
}
