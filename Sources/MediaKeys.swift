import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Takes the keyboard volume keys while the system output is a device without a volume control
/// (the SoundPusher virtual device) and turns them into SixOut's own volume, with a bezel like macOS's.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isInstalled = false
    var shouldHandle: () -> Bool = { false }
    var onVolume: ((Int) -> Void)?       // +1 / −1 steps (fine steps arrive as ±1 with `fine` true)
    var onMute: (() -> Void)?
    var fineStep = false

    private init() {}

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Asks macOS for the Accessibility permission (shows the system dialog once).
    static func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        guard MediaKeys.hasAccessibilityPermission else { return false }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media keys arrive as system-defined events
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        isInstalled = true
        return true
    }

    func uninstall() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; isInstalled = false
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// Returns true when the event was consumed.
    fileprivate func handle(keyCode: Int, keyDown: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        guard shouldHandle() else { return false }
        guard keyDown else { return true }   // swallow the key-up of a key we handle
        fineStep = flags.contains(.shift) && flags.contains(.option)
        switch keyCode {
        case 0: onVolume?(+1)      // NX_KEYTYPE_SOUND_UP
        case 1: onVolume?(-1)      // NX_KEYTYPE_SOUND_DOWN
        case 7: onMute?()          // NX_KEYTYPE_MUTE
        default: return false
        }
        return true
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<MediaKeys>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { keys.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
    let data1 = ns.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = data1 & 0x0000FFFF
    let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
    guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return Unmanaged.passUnretained(event) }
    let consumed = MainActor.assumeIsolated { keys.handle(keyCode: keyCode, keyDown: keyDown, flags: ns.modifierFlags) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

/// A small floating bezel that mimics the macOS volume overlay.
@MainActor
final class VolumeBezel {
    static let shared = VolumeBezel()
    private var panel: NSPanel?
    private var icon = NSImageView()
    private var bar = SegmentBar(frame: .zero)
    private var hideWork: DispatchWorkItem?

    private init() {}

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 200, height: 200)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 20; effect.layer?.masksToBounds = true
        icon = NSImageView(frame: NSRect(x: 60, y: 70, width: 80, height: 80))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        bar = SegmentBar(frame: NSRect(x: 20, y: 24, width: 160, height: 12))
        effect.addSubview(icon); effect.addSubview(bar)
        p.contentView = effect
        return p
    }

    func show(volume: Float, muted: Bool) {
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        let name = muted || volume <= 0 ? "speaker.slash.fill" : (volume < 0.34 ? "speaker.wave.1.fill" : (volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        bar.fraction = muted ? 0 : CGFloat(volume)
        bar.needsDisplay = true
        if let screen = NSScreen.main {
            let f = screen.frame
            p.setFrameOrigin(NSPoint(x: f.midX - 100, y: f.minY + 140))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.35; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    private final class SegmentBar: NSView {
        var fraction: CGFloat = 0
        override func draw(_ dirtyRect: NSRect) {
            let segments = 16
            let gap: CGFloat = 2
            let w = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let lit = Int((fraction * CGFloat(segments)).rounded())
            for i in 0..<segments {
                let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
                (i < lit ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.25)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}
