import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let engine = EngineController.shared
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            let logURL = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("selftest.log")
            var lines: [String] = []
            func out(_ s: String) { print(s); lines.append(s); try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8) }
            var inMax = [Float](repeating: 0, count: 6), outMax = [Float](repeating: 0, count: 6)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let i = engine.currentInMeters, o = engine.currentOutMeters
                    for c in 0..<6 { inMax[c] = max(inMax[c], i[c]); outMax[c] = max(outMax[c], o[c]) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.start(); out("SELFTEST start: \(engine.status) error=\(engine.lastError ?? "-")") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { engine.playAllRoles(); out("SELFTEST playing all roles") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                out("SELFTEST running=\(engine.isRunning) hdmi=\(engine.hdmiFormat) class=\(engine.meters.state.contentClass) inMax=\(inMax.map { String(format: "%.2f", $0) }) outMax=\(outMax.map { String(format: "%.2f", $0) })")
                out("SELFTEST log:\n" + engine.log.joined(separator: "\n"))
                engine.shutdown(); exit(0)
            }
        } else if engine.settings.autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.start() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { EngineController.shared.shutdown() }
}

struct MenuVolumeLine: View {
    @ObservedObject var volume: VolumeModel
    var body: some View { Text("Volume \(Int((volume.value * 100).rounded())) %" + (volume.muted ? " (muted)" : "")) }
}

@main
struct SixOutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = EngineController.shared

    var body: some Scene {
        WindowGroup("SixOut") {
            ContentView().environmentObject(engine).environmentObject(engine.meters).environmentObject(engine.volume).frame(minWidth: 820, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            Text(engine.status)
            MenuVolumeLine(volume: engine.volume)
            Button(engine.isRunning ? "Stop engine" : "Start engine") { engine.isRunning ? engine.stop() : engine.start() }
            Toggle("Bypass processing", isOn: Binding(get: { engine.settings.bypass }, set: { engine.settings.bypass = $0 }))
            Picker("Orientation", selection: Binding(get: { engine.settings.orientation }, set: { engine.settings.orientation = $0 })) {
                Text("Normal 5.1").tag(0); Text("Turned 90° left (4.1)").tag(1); Text("Turned 90° right (4.1)").tag(2)
            }
            Divider()
            Button("Open SixOut window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title == "SixOut" }?.makeKeyAndOrderFront(nil)
            }
            Button("Quit SixOut") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: engine.isRunning ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
    }
}
