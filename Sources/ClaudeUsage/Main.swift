import SwiftUI
import AppKit
import Observation
import Carbon

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            let done = DispatchSemaphore(value: 0)
            Task.detached { await Dump.run(); done.signal() }
            done.wait()
            return
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            renderIconset(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshotter.run(dir: args[i + 1]) }
            return
        }
        MainActor.assumeIsolated { ClaudeUsageApp.main() }
    }

    /// Writes an .iconset folder for `iconutil` (used by build.sh).
    static func renderIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                let img = MenuBarIcon.appIcon(size: px)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}

/// Owns the NSStatusItem + NSPopover. Driving the button directly (instead of MenuBarExtra)
/// keeps the animated icon cheap: a frame is an image swap, not a SwiftUI re-render.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let store = UsageStore()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var spinner: Timer?
    private var phase = 0
    private var hotKey: HotKey?
    private var hotKeyWanted = false

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        observe()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton(); self?.updateHotKey() }
        }
        updateHotKey()
        updateButton()
    }

    private func observe() {
        withObservationTracking {
            _ = store.today.cost
            _ = store.live
            _ = store.last12h
            _ = store.blocks.count
            _ = store.loaded
            _ = store.burnPerHour
            _ = store.game.level
            _ = store.plan
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateButton(); self?.observe() }
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let busy = store.busyCount > 0
        let style = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.menuBarStyle) ?? "") ?? .iconOnly

        if style == .sparkline {
            button.image = composite(star(busy: busy), MenuBarIcon.sparkline(store.last12h))
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.image = star(busy: busy)
            let text = store.menuBarText.map { " " + $0 } ?? ""
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        // Hovering the icon gives the headline numbers without opening anything.
        var tip = busy ? "Claude is working in \(store.busyCount) of \(store.live.count) open session(s)"
                       : "Claude Usage — \(store.live.count) session(s) open, none working"
        for l in store.plan.limits { tip += "\n\(l.label): \(Int(l.percent.rounded()))% used" }
        if store.loaded {
            tip += "\nToday: \(Fmt.money(store.today.cost)) API-equivalent · \(store.today.prompts) prompts"
            tip += "\nLevel \(store.game.level) \(store.game.title) · 🔥 \(store.game.streak)-day streak"
        }
        if UserDefaults.standard.bool(forKey: Prefs.hotkey) { tip += "\n⌥⌘C to open" }
        button.toolTip = tip

        let animate = busy && UserDefaults.standard.bool(forKey: Prefs.animateIcon)
        if animate, spinner == nil {
            spinner = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !animate, let t = spinner {
            t.invalidate(); spinner = nil; phase = 0
        }
    }

    private func star(busy: Bool) -> NSImage {
        MenuBarIcon.starburst(size: 15, phase: phase, busy: busy, rays: store.game.rays, core: store.game.level >= 41)
    }

    private func updateHotKey() {
        let want = UserDefaults.standard.bool(forKey: Prefs.hotkey)
        guard want != hotKeyWanted else { return }   // only (re)register when the setting changes
        hotKeyWanted = want
        if want && hotKey == nil {
            hotKey = HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
                MainActor.assumeIsolated { self?.toggle() }
            }
        } else if !want { hotKey = nil }
    }

    private func tick() {
        phase &+= 1
        guard let button = item.button else { return }
        let star = star(busy: true)
        let style = UserDefaults.standard.string(forKey: Prefs.menuBarStyle)
        button.image = style == MenuBarStyle.sparkline.rawValue ? composite(star, MenuBarIcon.sparkline(store.last12h)) : star
    }

    private func composite(_ a: NSImage, _ b: NSImage) -> NSImage {
        let gap: CGFloat = 4
        let size = NSSize(width: a.size.width + gap + b.size.width, height: max(a.size.height, b.size.height))
        let img = NSImage(size: size, flipped: false) { _ in
            a.draw(in: NSRect(x: 0, y: (size.height - a.size.height) / 2, width: a.size.width, height: a.size.height))
            b.draw(in: NSRect(x: a.size.width + gap, y: (size.height - b.size.height) / 2, width: b.size.width, height: b.size.height))
            return true
        }
        img.isTemplate = true
        return img
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { popover.contentViewController = nil }
    }

    func open() { if !popover.isShown { toggle() } }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Built on open and dropped on close, so SwiftUI does zero work while the popover is hidden.
            popover.contentViewController = NSHostingController(rootView: PopoverView().environment(store))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
            Task { await store.refresh() }
            store.refreshPlanIfStale()
        }
    }
}

/// Global hotkey via Carbon (works without Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handler)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x434C5553), id: 1)   // 'CLUS'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusController()
        if CommandLine.arguments.contains("--open") {   // dev aid: open the popover on launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.controller?.open() }
        }
        if !UsageStore.isSandboxed && UserDefaults.standard.bool(forKey: Prefs.notifyFinished) { UsageStore.requestNotificationPermission() }
    }
}

@MainActor
enum ClaudeUsageApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
