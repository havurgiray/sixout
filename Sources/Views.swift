import SwiftUI

let kJackNames = ["FL", "FR", "C", "SW", "SL", "SR"]

extension EngineController {
    func bind<T>(_ kp: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: EngineController
    var body: some View {
        VStack(spacing: 0) {
            StatusBarView()
            Divider()
            TabView {
                TestRouteView().tabItem { Label("Test & Wiring", systemImage: "waveform") }
                EQView().tabItem { Label("EQ & Bass", systemImage: "slider.horizontal.3") }
                SpatialView().tabItem { Label("Spatial & Dynamics", systemImage: "sparkles") }
                CalibrationView().tabItem { Label("Calibrate", systemImage: "mic") }
                SetupView().tabItem { Label("Setup", systemImage: "gearshape") }
            }
            .padding(10)
        }
    }
}

/// Level bar drawn in a single Canvas (no layout pass per update; the readout is drawn, not laid out).
struct MeterBar: View {
    var value: Float
    var showValue = false
    var body: some View {
        let db = linToDb(value)
        Canvas { ctx, size in
            let barH: CGFloat = 8
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: barH), cornerRadius: 3), with: .color(.secondary.opacity(0.15)))
            let color: Color = db > -0.5 ? .red : (db > -6 ? .orange : (db > -18 ? .green : .green.opacity(0.7)))
            if frac > 0 { ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * frac, height: barH), cornerRadius: 3), with: .color(color)) }
            if showValue {
                let t = Text(db > -90 ? String(format: "%.1f", db) : "–").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ctx.draw(t, at: CGPoint(x: size.width / 2, y: barH + 7))
            }
        }
        .frame(height: showValue ? 20 : 8)
    }
}

/// Meter for one channel; observes only the live-meter object so the rest of the window stays idle.
struct RoleMeter: View {
    @EnvironmentObject var meters: LiveMeters
    let slot: Int
    var input = false
    var showValue = false
    var body: some View { MeterBar(value: input ? meters.state.inPeak[slot] : meters.state.outPeak[slot], showValue: showValue) }
}

struct InputClipNote: View {
    @EnvironmentObject var meters: LiveMeters
    var body: some View {
        if meters.state.inClipEvents > 0 {
            Text("Source clipping: \(meters.state.inClipEvents) input samples at full scale in the last 3 s. The app that is playing is overdriving its output (a browser or player volume boost, or an EQ in the app); lower it there.").font(.caption).foregroundStyle(.red)
        }
    }
}

struct DetectionBadge: View {
    @EnvironmentObject var meters: LiveMeters
    var body: some View {
        HStack(spacing: 14) {
            Label(["Silence", "Stereo content", "5.1 content"][min(2, max(0, meters.state.contentClass))], systemImage: meters.state.contentClass == 2 ? "speaker.wave.3" : "speaker.wave.1")
            Text(meters.state.upmixAmount > 0.01 ? "Upmix on (\(Int(meters.state.upmixAmount * 100))%)" : "Upmix off").foregroundStyle(meters.state.upmixAmount > 0.01 ? .blue : .secondary)
        }
    }
}

struct LimiterMeterView: View {
    @EnvironmentObject var meters: LiveMeters
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gain reduction").frame(width: 150, alignment: .leading)
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: 8), cornerRadius: 3), with: .color(.secondary.opacity(0.15)))
                    let now = CGFloat(min(1, meters.state.limGRNow / 12)), peak = CGFloat(min(1, meters.state.limGRPeak / 12))
                    let color: Color = meters.state.limGRNow > 6 ? .red : (meters.state.limGRNow > 2 ? .orange : .green)
                    if now > 0 { ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * now, height: 8), cornerRadius: 3), with: .color(color)) }
                    ctx.fill(Path(CGRect(x: size.width * peak, y: 0, width: 2, height: 8)), with: .color(.primary.opacity(0.6)))
                }.frame(height: 8)
                Text(String(format: "%.1f dB now, %.1f peak, %.0f%% active", meters.state.limGRNow, meters.state.limGRPeak, meters.state.limActivePercent)).font(.system(.caption, design: .monospaced)).frame(width: 230, alignment: .leading)
            }
            if meters.state.clipEvents > 0 { Text("Clipping in the last 3 s: \(meters.state.clipEvents) samples hit full scale. Enable the limiter or lower the master gain.").font(.caption).foregroundStyle(.red) }
        }
    }
}

struct LevelsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) { Text("In ").frame(width: 30); ForEach(0..<6, id: \.self) { c in VStack { RoleMeter(slot: c, input: true, showValue: true); Text(Role(rawValue: c)!.short).font(.caption2) } } }
            HStack(alignment: .top) { Text("Out").frame(width: 30); ForEach(0..<6, id: \.self) { c in VStack { RoleMeter(slot: c, showValue: true); Text(Role(rawValue: c)!.short).font(.caption2) } } }
            InputClipNote()
            Text("Peak levels in dBFS. \"In\" is what apps send to the SoundPusher device before any processing; that device has no volume control, so apps deliver full scale and streaming content sits near 0 dB most of the time. That is normal. Red means within 0.5 dB of full scale. \"Out\" is after the limiter; set listening loudness at the speakers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Observes only the volume object, so volume changes do not rebuild the rest of the window.
struct VolumeControls: View {
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var volume: VolumeModel
    var body: some View {
        HStack(spacing: 8) {
            Button { engine.toggleMute() } label: { Image(systemName: volume.muted || volume.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.borderless)
            Slider(value: Binding(get: { volume.value }, set: { volume.value = $0; engine.volumeChanged() }), in: 0...1).frame(width: 220)
            Text("\(Int((volume.value * 100).rounded())) %").font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .trailing)
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject var engine: EngineController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Circle().fill(engine.isRunning ? Color.green : Color.gray).frame(width: 10, height: 10)
                Text(engine.status).font(.callout).lineLimit(1)
                Spacer()
                Button(engine.isRunning ? "Stop" : "Start") { engine.isRunning ? engine.stop() : engine.start() }.keyboardShortcut("r")
                Toggle("Bypass", isOn: engine.bind(\.bypass)).toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                VolumeControls()
                Text(engine.mediaKeysActive ? "volume keys active" : (engine.settings.mediaKeysEnabled ? "volume keys need the Accessibility permission (Setup)" : "volume keys off")).font(.caption).foregroundStyle(engine.mediaKeysActive ? .green : .secondary)
            }
            HStack(spacing: 14) {
                DetectionBadge()
                if engine.settings.orientation != 0 { Text(engine.settings.orientation == 1 ? "4.1, turned left" : "4.1, turned right").foregroundStyle(.blue) }
                Text("HDMI: \(engine.hdmiFormat)").foregroundStyle(engine.hdmiFormat.hasPrefix("bitstream") ? .green : .secondary)
                if engine.soundPusherRunning { Text("SoundPusher app is running").foregroundStyle(.orange) }
                Spacer()
            }
            .font(.caption)
            if let e = engine.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct TestRouteView: View {
    @EnvironmentObject var engine: EngineController
    @State private var heard: [Int] = [0, 1, 2, 3, 4, 5]
    @State private var fixError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("1. Verify each speaker (plays through the wiring fix below)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Each button says its own name. It should come out of that speaker. If it comes from another one, use section 2.").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(Role.allCases) { role in
                                VStack(spacing: 4) {
                                    Button(role.name) { engine.playRole(role) }
                                        .buttonStyle(.borderedProminent).tint(engine.playingRole == role ? .blue : .gray)
                                    Button("noise") { engine.playRole(role, kind: .noise) }.font(.caption).buttonStyle(.link)
                                    RoleMeter(slot: engine.settings.route.firstIndex(of: role.rawValue) ?? role.rawValue)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        HStack {
                            Button("Play all in order") { engine.playAllRoles() }
                            Button("Stop") { engine.stopTests() }
                        }
                    }
                    .padding(6)
                }

                GroupBox("2. Identify what is wired where") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play each decoder output, then pick the speaker you actually heard it from. Apply the fix and go back to section 1.").font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<6, id: \.self) { slot in
                            HStack {
                                Text("Output \(Role(rawValue: slot)!.short)").frame(width: 80, alignment: .leading).bold()
                                Text("decoder jack \(kJackNames[slot])").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Button("Play") { engine.playSlot(slot) }.tint(engine.playingSlot == slot ? .blue : nil)
                                Text("heard from").font(.caption)
                                Picker("", selection: $heard[slot]) { ForEach(Role.allCases) { r in Text(r.name).tag(r.rawValue) } }.frame(width: 170)
                                RoleMeter(slot: slot).frame(width: 120)
                            }
                        }
                        HStack {
                            Button("Play all outputs in order") { engine.playAllSlots() }
                            Button("Apply wiring fix") { fixError = engine.applyWiringFix(heard: heard) }.buttonStyle(.borderedProminent)
                            Button("Straight wiring") { engine.settings.route = [0, 1, 2, 3, 4, 5]; heard = [0, 1, 2, 3, 4, 5]; fixError = nil }
                        }
                        if let e = fixError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(6)
                }

                GroupBox("3. Wiring table (what each decoder output carries)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<6, id: \.self) { slot in
                            HStack {
                                Text("Output \(Role(rawValue: slot)!.short) (jack \(kJackNames[slot]))").frame(width: 190, alignment: .leading)
                                Text("carries").font(.caption)
                                Picker("", selection: Binding(get: { engine.settings.route[slot] }, set: { engine.settings.route[slot] = $0 })) {
                                    ForEach(Role.allCases) { r in Text(r.name).tag(r.rawValue) }
                                }.frame(width: 170)
                            }
                        }
                        HStack {
                            Text("Quick swaps:").font(.caption)
                            Button("Center ⇄ Sub") { swapRoutes(2, 3) }
                            Button("Left ⇄ Right") { swapRoutes(0, 1) }
                            Button("Surr. L ⇄ R") { swapRoutes(4, 5) }
                            Button("Fronts ⇄ Surrounds") { swapRoutes(0, 4); swapRoutes(1, 5) }
                        }
                        let r = engine.settings.route
                        if Set(r).count != 6 { Text("Warning: some speaker is used twice and another is silent.").font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(6)
                }

                GroupBox("Levels") { LevelsView().padding(6) }
            }
            .padding(4)
        }
    }

    private func swapRoutes(_ a: Int, _ b: Int) {
        var r = engine.settings.route
        // swap which slots carry role a and role b
        if let ia = r.firstIndex(of: a), let ib = r.firstIndex(of: b) { r.swapAt(ia, ib); engine.settings.route = r }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var unit: String = "dB"
    var format: String = "%.1f"
    /// When given, a small reset control appears whenever the value differs from it.
    var defaultValue: Float? = nil
    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value) + " " + unit).frame(width: 78, alignment: .trailing).font(.system(.caption, design: .monospaced))
            if let d = defaultValue {
                Button { value = d } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help(String(format: "Reset to " + format, d) + " " + unit)
                    .opacity(abs(value - d) > 0.001 ? 1 : 0.25).disabled(abs(value - d) <= 0.001)
            }
        }
    }
}

/// Defaults used by the per-slider reset controls.
private let kDefaults = Settings()

struct EQPresetBar: View {
    @EnvironmentObject var engine: EngineController
    @ObservedObject var store = EQPresetStore.shared
    @State private var name = ""
    @State private var includeBass = true
    @State private var selected: UUID? = nil
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Preset name", text: $name).frame(width: 220)
                Toggle("include bass management", isOn: $includeBass)
                Button("Save EQ") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { message = "Give the preset a name first."; return }
                    let p = EQPreset.capture(from: engine.settings, name: n, includeBass: includeBass)
                    store.save(p); selected = store.presets.first { $0.name == n }?.id
                    message = "Saved \"\(n)\"."
                }.buttonStyle(.borderedProminent)
            }
            HStack {
                Picker("Saved", selection: Binding(get: { selected ?? UUID() }, set: { selected = $0 })) {
                    Text("choose…").tag(UUID())
                    ForEach(store.presets) { p in Text(p.name + (p.includesBass ? "  (EQ + bass)" : "  (EQ)")).tag(p.id) }
                }.frame(width: 320)
                Button("Load") {
                    guard let p = store.presets.first(where: { $0.id == selected }) else { message = "Pick a preset to load."; return }
                    var s = engine.settings; p.apply(to: &s); engine.settings = s
                    name = p.name; message = "Loaded \"\(p.name)\"."
                }.disabled(selected == nil)
                Button("Delete") {
                    guard let p = store.presets.first(where: { $0.id == selected }) else { return }
                    store.delete(id: p.id); selected = nil; message = "Deleted \"\(p.name)\"."
                }.disabled(selected == nil)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Presets are stored in eq-presets.json next to the settings. The current EQ is always saved automatically; presets are named snapshots you can return to.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Save / load listening-position profiles (trims, delays, polarity, sub, bass management, orientation, optional EQ).
struct SpeakerProfileBar: View {
    @EnvironmentObject var engine: EngineController
    @ObservedObject var store = SpeakerProfileStore.shared
    @State private var name = ""
    @State private var includeEQ = false
    @State private var selected: UUID? = nil
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A profile holds what a calibration produced for one seat: trims, delays, polarity, sub level, bass management and the orientation used there, optionally the EQ. Trims and delays belong to the physical speakers and stay valid in the turned modes as long as you sit where the microphone was; a different seat needs its own calibration and profile.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Profile name (e.g. desk, sofa turned left)", text: $name).frame(width: 260)
                Toggle("include EQ", isOn: $includeEQ)
                Button("Save current") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { message = "Give the profile a name first."; return }
                    let p = SpeakerProfile.capture(from: engine.settings, name: n, includeEQ: includeEQ, calibration: CalibrationResult.load())
                    store.save(p); selected = store.profiles.first { $0.name == n }?.id
                    message = "Saved \"\(n)\"."
                }.buttonStyle(.borderedProminent)
            }
            HStack {
                Picker("Saved", selection: Binding(get: { selected ?? UUID() }, set: { selected = $0 })) {
                    Text("choose…").tag(UUID())
                    ForEach(store.profiles) { p in Text(p.summary).tag(p.id) }
                }.frame(width: 420)
                Button("Load") {
                    guard let p = store.profiles.first(where: { $0.id == selected }) else { message = "Pick a profile to load."; return }
                    var s = engine.settings; p.apply(to: &s); engine.settings = s
                    name = p.name; message = "Loaded \"\(p.name)\"."
                }.disabled(selected == nil)
                Button("Delete") {
                    guard let p = store.profiles.first(where: { $0.id == selected }) else { return }
                    store.delete(id: p.id); selected = nil; message = "Deleted \"\(p.name)\"."
                }.disabled(selected == nil)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct EQView: View {
    @EnvironmentObject var engine: EngineController
    @State private var role: Role = .L
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("EQ presets") { EQPresetBar().padding(6) }
                GroupBox("Per-speaker EQ") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("EQ enabled", isOn: engine.bind(\.eqEnabled)).toggleStyle(.switch)
                            Spacer()
                            Picker("Speaker", selection: $role) { ForEach(Role.allCases) { r in Text(r.short).tag(r) } }.pickerStyle(.segmented).frame(width: 320)
                        }
                        Toggle("Apply EQ to \(role.name)", isOn: Binding(get: { engine.settings.eq[role.rawValue].enabled }, set: { engine.settings.eq[role.rawValue].enabled = $0 }))
                        ForEach(0..<kBands, id: \.self) { b in
                            LabeledSlider(title: kBandNames[b] + (b == 0 ? " (low shelf)" : (b == kBands - 1 ? " (high shelf)" : "")),
                                          value: Binding(get: { engine.settings.eq[role.rawValue].gains[b] }, set: { engine.settings.eq[role.rawValue].gains[b] = $0 }),
                                          range: -12...12)
                        }
                        HStack {
                            Button("Reset this speaker") { engine.settings.eq[role.rawValue].gains = Array(repeating: 0, count: kBands) }
                            Button("Copy to all speakers") { let g = engine.settings.eq[role.rawValue].gains; for i in 0..<6 { engine.settings.eq[i].gains = g } }
                            Button("Reset all") { for i in 0..<6 { engine.settings.eq[i].gains = Array(repeating: 0, count: kBands) } }
                            Button("Velvety preset (all satellites)") {
                                let g: [Float] = [0, 0, 1, 1, 0, 0, -0.5, -1.5, -3, -4]
                                for i in 0..<6 where i != 3 { engine.settings.eq[i].enabled = true; engine.settings.eq[i].gains = g }
                                engine.settings.eqEnabled = true
                            }
                        }
                    }
                    .padding(6)
                }
                GroupBox("Bass management") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable (high-pass satellites, send their bass to the sub)", isOn: engine.bind(\.bassEnabled)).toggleStyle(.switch)
                        LabeledSlider(title: "Crossover", value: engine.bind(\.crossoverHz), range: 40...120, unit: "Hz", format: "%.0f", defaultValue: kDefaults.crossoverHz)
                        Text("Capped at 120 Hz: both encoders band-limit the sub (LFE) channel at about 120 Hz, so bass redirected above that would be lost. On speaker sets whose sub box takes the bass of every input internally (most PC 5.1 sets) this section is largely redundant; 80–100 Hz or off are both fine.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Redirect satellite bass to the subwoofer", isOn: engine.bind(\.redirectBass))
                        LabeledSlider(title: "LFE gain (decoder lacks +10 dB)", value: engine.bind(\.lfeGainDB), range: 0...15, defaultValue: kDefaults.lfeGainDB)
                        LabeledSlider(title: "Sub low-pass", value: engine.bind(\.lfeLowpassHz), range: 60...120, unit: "Hz", format: "%.0f", defaultValue: kDefaults.lfeLowpassHz)
                        Divider()
                        HStack {
                            Text("Sub channel")
                            Picker("", selection: engine.bind(\.subChannelMode)) {
                                Text("Auto (send on the LFE channel)").tag(0)
                                Text("Send on the LFE channel").tag(1)
                                Text("Fold into the front channels").tag(2)
                            }.frame(width: 300)
                            Text(engine.settings.foldsSub ? "currently: folded into L/R, LFE channel silent" : "currently: on the LFE channel").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Both codecs now carry the LFE channel cleanly: the DTS encoder built into SixOut includes a fix for an ffmpeg bug that garbled it (and could crash). Folding into the fronts remains available; on speaker sets whose sub box takes the front input's bass to the same driver it costs nothing either way.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                GroupBox("Speaker trims") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Role.allCases) { r in
                            HStack {
                                Text(r.name).frame(width: 110, alignment: .leading)
                                Slider(value: Binding(get: { engine.settings.outGainDB[r.rawValue] }, set: { engine.settings.outGainDB[r.rawValue] = $0 }), in: -12...12)
                                Text(String(format: "%+.1f dB", engine.settings.outGainDB[r.rawValue])).frame(width: 70).font(.system(.caption, design: .monospaced))
                                Toggle("Mute", isOn: Binding(get: { engine.settings.outMute[r.rawValue] }, set: { engine.settings.outMute[r.rawValue] = $0 }))
                                Toggle("Invert", isOn: Binding(get: { engine.settings.outInvert[r.rawValue] }, set: { engine.settings.outInvert[r.rawValue] = $0 }))
                            }
                        }
                        Button("Reset trims") { engine.settings.outGainDB = [0, 0, 0, 0, 0, 0]; engine.settings.outMute = Array(repeating: false, count: 6); engine.settings.outInvert = Array(repeating: false, count: 6) }
                        Divider()
                        Text("Speaker delay (distance compensation; the farthest speaker gets 0 ms)").font(.caption).foregroundStyle(.secondary)
                        ForEach(Role.allCases) { r in
                            HStack {
                                Text(r.name).frame(width: 110, alignment: .leading)
                                Slider(value: Binding(get: { engine.settings.delayMs[r.rawValue] }, set: { engine.settings.delayMs[r.rawValue] = $0 }), in: 0...40)
                                Text(String(format: "%.1f ms", engine.settings.delayMs[r.rawValue])).frame(width: 70).font(.system(.caption, design: .monospaced))
                            }
                        }
                        Button("Reset delays") { engine.settings.delayMs = [0, 0, 0, 0, 0, 0] }
                        Divider()
                        Text("Listening position profiles").font(.headline)
                        SpeakerProfileBar()
                    }
                    .padding(6)
                }
            }
            .padding(4)
        }
    }
}

struct SpatialView: View {
    @EnvironmentObject var engine: EngineController
    private var orientationDescription: String {
        switch engine.settings.orientation {
        case 1: return "You face your left wall. Front-left is the old surround-left speaker, front-right the old front-left; rear-left is the old surround-right, rear-right the old front-right. The center speaker is at your side and stays silent; center content plays as a phantom center between the new front pair."
        case 2: return "You face your right wall. Front-left is the old front-right speaker, front-right the old surround-right; rear-left is the old front-left, rear-right the old surround-left. The center speaker is at your side and stays silent; center content plays as a phantom center between the new front pair."
        default: return "Speakers are used as placed: 5.1 with a real center."
        }
    }
    /// Names the preset whose values match the current compressor settings, if any.
    private var compressorDescription: String {
        let s = engine.settings
        for p in Settings.compressorPresets where p.1 == s.compEnabled && (!s.compEnabled || (abs(p.2 - s.compThresholdDB) < 0.05 && abs(p.3 - s.compRatio) < 0.05 && abs(p.4 - s.compAttackMs) < 0.05 && abs(p.5 - s.compReleaseMs) < 0.5 && abs(p.6 - s.compMakeupDB) < 0.05)) {
            return "Current: \(p.0) — \(p.7)"
        }
        return "Current: custom settings. Threshold is where reduction starts, ratio how hard, attack how fast it clamps, release how fast it lets go, makeup lifts the result back up."
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Presets") {
                    HStack { ForEach(Array(Settings.presets.enumerated()), id: \.offset) { i, p in Button(p.0) { engine.applyPreset(i) } } }.padding(6)
                }
                GroupBox("Listening orientation (4.1 modes)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: engine.bind(\.orientation)) {
                            Text("Normal 5.1").tag(0)
                            Text("Turned 90° left").tag(1)
                            Text("Turned 90° right").tag(2)
                        }.pickerStyle(.segmented).frame(width: 420)
                        Text(orientationDescription).font(.caption).foregroundStyle(.secondary)
                        LabeledSlider(title: "Phantom center level", value: engine.bind(\.phantomCenterDB), range: -12...0, defaultValue: -3)
                            .disabled(engine.settings.orientation == 0)
                        Text("Applied after the upmix and before the per-speaker EQ, trims and delays, so every correction still lands on the speaker it was measured on: trims and delays stay valid in the turned modes as long as you sit where the calibration microphone was. A different seat needs its own calibration, saved as a listening position profile. The sub is unchanged. Calibration and the wiring tests always run in the normal orientation.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                GroupBox("Content detection → stereo spatializer (upmix)") {
                    VStack(alignment: .leading, spacing: 8) {
                        DetectionBadge()
                        Picker("Upmix stereo to 5.1", selection: engine.bind(\.upmixMode)) {
                            Text("Off").tag(0); Text("Auto (only when content is stereo)").tag(1); Text("Always").tag(2)
                        }.pickerStyle(.segmented)
                        LabeledSlider(title: "Center level", value: engine.bind(\.centerLevelDB), range: -12...6, defaultValue: kDefaults.centerLevelDB)
                        LabeledSlider(title: "Surround level", value: engine.bind(\.surroundLevelDB), range: -18...6, defaultValue: kDefaults.surroundLevelDB)
                        LabeledSlider(title: "Surround delay", value: engine.bind(\.surroundDelayMs), range: 0...50, unit: "ms", format: "%.0f", defaultValue: kDefaults.surroundDelayMs)
                        LabeledSlider(title: "Stereo width", value: engine.bind(\.width), range: 0...2, unit: "x", format: "%.2f", defaultValue: kDefaults.width)
                        LabeledSlider(title: "Dialogue enhance (center)", value: engine.bind(\.dialogEnhanceDB), range: 0...10, defaultValue: 0)
                        Button("Reset spatializer to defaults") {
                            engine.settings.upmixMode = kDefaults.upmixMode
                            engine.settings.centerLevelDB = kDefaults.centerLevelDB; engine.settings.surroundLevelDB = kDefaults.surroundLevelDB
                            engine.settings.surroundDelayMs = kDefaults.surroundDelayMs; engine.settings.width = kDefaults.width; engine.settings.dialogEnhanceDB = 0
                        }
                    }
                    .padding(6)
                }
                GroupBox("Dynamics (volume leveler / night mode)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Presets:").font(.caption)
                            ForEach(Array(Settings.compressorPresets.enumerated()), id: \.offset) { i, p in
                                Button(p.0) { engine.settings.applyCompressorPreset(i) }.help(p.7)
                            }
                        }
                        Text(compressorDescription).font(.caption).foregroundStyle(.secondary)
                        Toggle("Compressor enabled", isOn: engine.bind(\.compEnabled)).toggleStyle(.switch)
                        LabeledSlider(title: "Threshold", value: engine.bind(\.compThresholdDB), range: -50...0, defaultValue: kDefaults.compThresholdDB)
                        LabeledSlider(title: "Ratio", value: engine.bind(\.compRatio), range: 1...20, unit: ":1", format: "%.1f", defaultValue: kDefaults.compRatio)
                        LabeledSlider(title: "Attack", value: engine.bind(\.compAttackMs), range: 0.5...100, unit: "ms", format: "%.1f", defaultValue: kDefaults.compAttackMs)
                        LabeledSlider(title: "Release", value: engine.bind(\.compReleaseMs), range: 20...1000, unit: "ms", format: "%.0f", defaultValue: kDefaults.compReleaseMs)
                        LabeledSlider(title: "Makeup gain", value: engine.bind(\.compMakeupDB), range: 0...24, defaultValue: kDefaults.compMakeupDB)
                    }
                    .padding(6)
                }
                GroupBox("Limiter & master") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Limiter enabled (protects against clipping in the encoder)", isOn: engine.bind(\.limEnabled)).toggleStyle(.switch)
                        LabeledSlider(title: "Ceiling", value: engine.bind(\.limCeilingDB), range: -12...0, defaultValue: kDefaults.limCeilingDB)
                        LabeledSlider(title: "Release", value: engine.bind(\.limReleaseMs), range: 10...500, unit: "ms", format: "%.0f", defaultValue: kDefaults.limReleaseMs)
                        LimiterMeterView()
                        Divider()
                        Toggle("Auto headroom: back the gain off when the limiter works hard, restore it slowly when it idles", isOn: engine.bind(\.autoHeadroomEnabled)).toggleStyle(.switch)
                        HStack {
                            Text(String(format: "Auto gain now: %+.2f dB", engine.settings.autoHeadroomDB)).font(.system(.callout, design: .monospaced))
                            Button("Reset to 0 dB") { engine.settings.autoHeadroomDB = 0 }
                        }
                        LabeledSlider(title: "Auto headroom floor", value: engine.bind(\.autoHeadroomFloorDB), range: -24...0, format: "%.0f", defaultValue: kDefaults.autoHeadroomFloorDB)
                        Text("Rules: more than 6 dB of limiting in the last second → −1 dB at once; limiting over 1 dB for more than 30% of the last second → −0.5 dB; limiter idle for 20 s while audio plays → +0.25 dB every 5 s, up to 0 dB. If the result is too quiet, turn the speakers up instead of the master gain.").font(.caption).foregroundStyle(.secondary)
                        LabeledSlider(title: "Master gain", value: engine.bind(\.masterGainDB), range: -24...6, defaultValue: 0)
                    }
                    .padding(6)
                }
            }
            .padding(4)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var engine: EngineController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Signal path") {
                    Text("apps → SoundPusher virtual device → tap → content detection → width & upmix → dynamics → bass management → EQ → trims → limiter → wiring fix → AC-3/DTS encoder → HDMI → optical → decoder → speakers")
                        .font(.caption).padding(6)
                }
                GroupBox("Devices") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Source (what apps play to):")
                            Text("SoundPusher Audio").bold()
                            Text(engine.sourceDevicePresent ? "present" : "missing — is the SoundPusher driver installed?").foregroundStyle(engine.sourceDevicePresent ? .green : .red)
                        }
                        HStack {
                            Text("Digital output (bitstream):")
                            Picker("", selection: Binding(get: { engine.resolvedOutputUID() }, set: { engine.settings.outputDeviceUID = $0 })) {
                                ForEach(engine.outputDevices) { d in Text(d.name).tag(d.uid) }
                            }.frame(width: 260)
                            Button("Refresh") { engine.refreshDevices() }
                        }
                        Text("Current HDMI stream: \(engine.hdmiFormat)").font(.caption)
                        HStack {
                            Text("Encoder")
                            Picker("", selection: engine.bind(\.encoder)) {
                                Text("AC-3, 640 kbit/s (standard)").tag(0)
                                Text("DTS, 1509 kbit/s (experimental encoder)").tag(1)
                            }.frame(width: 320)
                            Button("Restart engine") { engine.stop(); engine.start() }.disabled(!engine.isRunning)
                        }
                        Text("Changing the encoder restarts the engine automatically (about a second of silence). DTS carries 2.4× the data of AC-3 over the same optical link; ffmpeg's DTS encoder is a basic one, so judge by ear. Turn the speakers down before the first try and switch back if you hear silence or noise. Decoders may reproduce the two codecs at slightly different levels, especially the sub channel, so re-run the calibration after settling on one.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("IOCycle safety factor")
                            Stepper(value: engine.bind(\.ioCycleSafetyFactor), in: 1...32, step: 1) { Text(String(format: "%.0f", engine.settings.ioCycleSafetyFactor)) }
                            Text("(raise if you hear dropouts; needs restart of the engine)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
                GroupBox("SoundPusher app") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SixOut does the SoundPusher app's job (capture → AC-3/DTS → HDMI) while its engine runs, so the SoundPusher app is quit automatically on start. The SoundPusher driver stays installed and is still required. Because of this, System Settings shows \"SoundPusher Audio\" as the sound output: that is the virtual device your apps play into and SixOut listens to. It is correct and should stay selected.").font(.caption)
                        HStack {
                            Text(engine.soundPusherRunning ? "SoundPusher app: running" : "SoundPusher app: not running").foregroundStyle(engine.soundPusherRunning ? .orange : .secondary)
                            Button("Quit SoundPusher") { engine.quitSoundPusherIfRunning() }
                            Button("Stop engine and relaunch SoundPusher") { engine.relaunchSoundPusher() }
                        }
                    }
                    .padding(6)
                }
                GroupBox("Volume keys") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The SoundPusher virtual device has no volume control, so macOS cannot use the keyboard volume keys with it. With this option SixOut takes the volume keys whenever the system output is \"SoundPusher Audio\", applies the volume at the end of its own chain, and shows a bezel like macOS. With any other output device the keys pass through untouched. macOS requires the Accessibility permission for this.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Volume keys control SixOut", isOn: engine.bind(\.mediaKeysEnabled))
                        HStack {
                            Text(engine.accessibilityGranted ? "Accessibility permission: granted" : "Accessibility permission: not granted").foregroundStyle(engine.accessibilityGranted ? .green : .orange)
                            if !engine.accessibilityGranted {
                                Button("Request permission") { engine.requestAccessibility() }
                                Button("Open Accessibility settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                            }
                            Button("Re-check") { engine.updateMediaKeys() }
                        }
                        Text("Steps: 1/16 per press like macOS; hold Shift+Option for 1/64 steps. Mute toggles with the mute key. After a rebuild the permission must be granted again because the app's signature changes.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Start the engine when SixOut opens", isOn: engine.bind(\.autoStart))
                        Toggle("Launch SixOut at login", isOn: $engine.launchAtLogin)
                        Text("Settings file: \(Settings.fileURL.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(6)
                }
                GroupBox("Log") {
                    ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(engine.log.enumerated()), id: \.offset) { _, l in Text(l).font(.system(.caption, design: .monospaced)) } } }
                        .frame(minHeight: 120, maxHeight: 220).padding(6)
                }
            }
            .padding(4)
        }
    }
}
