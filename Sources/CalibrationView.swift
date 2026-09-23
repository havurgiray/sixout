import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject var engine: EngineController
    @StateObject private var cal: Calibrator
    @State private var graphRole: Role = .L

    init() { _cal = StateObject(wrappedValue: Calibrator(engine: EngineController.shared)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Listening position profiles") { SpeakerProfileBar().padding(6) }
                GroupBox("Measurement microphone") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect the USB microphone (a handheld recorder in audio interface mode works well). Put it at ear height on the listening seat, mics pointing at the screen. Traffic noise is handled by the sweep deconvolution and the noise measurement; keep typing and moving to a minimum during the run (about \(Int(3 + Double(cal.repetitions) * 6 * (cal.sweepSeconds + 1))) s).")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Input", selection: Binding(get: { cal.selectedDevice ?? 0 }, set: { cal.selectedDevice = $0 })) {
                                ForEach(cal.inputDevices) { d in Text("\(d.name) (\(d.channels) ch)").tag(d.id) }
                            }.frame(width: 330)
                            Button("Refresh") { cal.refreshDevices() }
                            Toggle("Monitor level", isOn: Binding(get: { cal.monitoring }, set: { cal.setMonitoring($0) })).disabled(cal.isBusy)
                            MeterBar(value: dbToLin(cal.monitorLevelDB)).frame(width: 140)
                            Text(String(format: "%.0f dBFS", cal.monitorLevelDB)).font(.system(.caption, design: .monospaced)).frame(width: 70)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Measure") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            LabeledSlider(title: "Test level", value: $cal.testLevelDB, range: -30...(-6), unit: "dBFS", format: "%.0f")
                        }
                        HStack {
                            Stepper("Sweeps per speaker: \(cal.repetitions)", value: $cal.repetitions, in: 1...5)
                            Stepper(String(format: "Sweep length: %.0f s", cal.sweepSeconds), value: $cal.sweepSeconds, in: 2...8, step: 1)
                            Spacer()
                            if cal.isBusy { Button("Cancel") { cal.cancel() } } else { Button("Start calibration") { cal.start() }.buttonStyle(.borderedProminent).disabled(!engine.isRunning) }
                        }
                        ProgressView(value: cal.progress)
                        Text(cal.statusText).font(.caption)
                        if case .failed(let m) = cal.phase { Text(m).font(.caption).foregroundStyle(.red) }
                        if !engine.isRunning { Text("The engine must be running (it plays the sweeps through the real chain).").font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(6)
                }

                if let r = cal.result {
                    GroupBox("Results  (\(r.deviceName), \(r.date.formatted(date: .abbreviated, time: .shortened)))") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: "Background noise during the run: %.0f dBFS at the microphone.", r.noiseRMSDB)).font(.caption)
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                GridRow {
                                    Text("Speaker").bold(); Text("Status").bold(); Text("Level").bold(); Text("Arrival").bold(); Text("Polarity").bold(); Text("→ Trim").bold(); Text("→ Delay").bold(); Text("Mic L/R").bold()
                                }
                                ForEach(r.speakers) { s in
                                    GridRow {
                                        Text(s.role.name)
                                        Text(s.ok ? "ok" : "not found").foregroundStyle(s.ok ? .green : .red)
                                        Text(s.ok ? String(format: "%+.1f dB", s.levelDB - (r.speakers.first { $0.role == .L }?.levelDB ?? 0)) : "–")
                                        Text(s.ok ? String(format: "%.1f ms", s.delayMs) : "–")
                                        Text(s.ok ? (s.polarityPositive ? "+" : "−") : "–")
                                        Text(s.ok ? String(format: "%+.1f dB", s.suggestedTrimDB) : "–")
                                        Text(s.ok ? String(format: "%.1f ms", s.suggestedDelayMs) : "–")
                                        Text(s.ok ? String(format: "%+.1f dB", s.micBalanceDB) : "–")
                                    }
                                    .font(.system(.body, design: .monospaced))
                                }
                            }
                            Text(String(format: "Suggested crossover: %.0f Hz   Suggested LFE gain: %+.1f dB", r.suggestedCrossoverHz, r.suggestedLFEGainDB)).font(.callout)
                            ForEach(r.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }

                            HStack {
                                Text("Response of").font(.caption)
                                Picker("", selection: $graphRole) { ForEach(Role.allCases) { role in Text(role.short).tag(role) } }.pickerStyle(.segmented).frame(width: 300)
                                Text("(relative to its own reference level; grey = too noisy to trust)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let s = r.speakers.first(where: { $0.role == graphRole }) {
                                ResponseGraph(bands: s.bands, snr: s.snr, eq: s.suggestedEQ).frame(height: 160)
                            }

                            Divider()
                            HStack {
                                Toggle("Trims", isOn: $cal.applyTrims); Toggle("Delays", isOn: $cal.applyDelays); Toggle("EQ", isOn: $cal.applyEQ)
                                Toggle("Crossover & bass mgmt", isOn: $cal.applyCrossover); Toggle("Sub level", isOn: $cal.applySubLevel); Toggle("Polarity", isOn: $cal.applyPolarity)
                            }.font(.caption)
                            HStack {
                                Button("Apply to settings") { cal.apply() }.buttonStyle(.borderedProminent)
                                Button("Revert to settings before calibration") { cal.revert() }.disabled(!cal.canRevert)
                            }
                            Text("After applying, save the result as a listening position profile (top of this tab) so you can switch seats later without measuring again.").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox("Polarity pair test") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Plays each speaker together with Front left, once as wired and once inverted, with the measured delays and trims applied, and keeps the polarity that sums louder in the overlap band (80–400 Hz for satellites, 40–160 Hz for the sub). This is far more reliable than the peak sign in the table above. About 70 s.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Check polarity") { cal.startPolarityCheck() }.disabled(cal.isBusy || !engine.isRunning)
                                if cal.phase == .polarity { Button("Cancel") { cal.cancel() } }
                            }
                            if !cal.polarity.isEmpty {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                    GridRow { Text("Speaker").bold(); Text("As wired").bold(); Text("Inverted").bold(); Text("Verdict").bold() }
                                    ForEach(cal.polarity) { v in
                                        GridRow {
                                            Text(v.role.name)
                                            Text(String(format: "%.1f dB", v.asWiredDB))
                                            Text(String(format: "%.1f dB", v.invertedDB))
                                            Text(v.text).foregroundStyle(v.conclusive ? (v.invert ? .orange : .green) : .secondary)
                                        }
                                        .font(.system(.body, design: .monospaced))
                                    }
                                }
                                Text("Conclusive inversions are written into the Polarity suggestion above; tick Polarity and click Apply.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(4)
        }
        .onAppear { cal.refreshDevices() }
    }
}

struct ResponseGraph: View {
    var bands: [Float]
    var snr: [Float]
    var eq: [Float]
    var body: some View {
        Canvas { ctx, size in
            let n = bands.count
            let w = size.width / CGFloat(n)
            let mid = size.height / 2
            let scale = size.height / 40   // ±20 dB
            // grid
            for db in stride(from: -20, through: 20, by: 10) {
                let y = mid - CGFloat(db) * scale
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.secondary.opacity(db == 0 ? 0.6 : 0.2)), lineWidth: db == 0 ? 1 : 0.5)
            }
            for i in 0..<n {
                let v = max(-20, min(20, bands[i]))
                let x = CGFloat(i) * w + 1
                let rect = CGRect(x: x, y: v >= 0 ? mid - CGFloat(v) * scale : mid, width: w - 2, height: abs(CGFloat(v)) * scale)
                let good = snr[i] >= 10
                ctx.fill(Path(rect), with: .color(good ? (abs(v) > 6 ? .orange : .blue) : .gray.opacity(0.5)))
                if i % 3 == 0 {
                    let label = kThirdOctaveCenters[i] >= 1000 ? String(format: "%gk", kThirdOctaveCenters[i] / 1000) : String(format: "%g", kThirdOctaveCenters[i])
                    ctx.draw(Text(label).font(.system(size: 8)), at: CGPoint(x: x + w / 2, y: size.height - 6))
                }
            }
            // suggested EQ curve (approximate, drawn at the EQ band centers)
            var path = Path()
            for (b, g) in eq.enumerated() {
                let fc = Double(kBandFreqs[b])
                guard let idx = kThirdOctaveCenters.firstIndex(where: { $0 >= fc }) else { continue }
                let x = CGFloat(idx) * w + w / 2
                let y = mid - CGFloat(max(-20, min(20, g))) * scale
                if path.isEmpty { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.green), lineWidth: 2)
        }
    }
}
