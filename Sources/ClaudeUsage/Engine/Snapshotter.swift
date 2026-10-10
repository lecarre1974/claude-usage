import SwiftUI
import AppKit

/// `ClaudeUsage --snapshot <dir>` renders every tab (light + dark) to PNGs. Used for visual QA.
@MainActor
enum Snapshotter {
    static func run(dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let store = UsageStore()
            await store.refresh()
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for scheme in [ColorScheme.light, .dark] {
                let bg = scheme == .dark ? Color(white: 0.13) : Color(white: 0.96)
                for tab in Tab.allCases {
                    let content = Group {
                        switch tab {
                        case .now: NowTab()
                        case .usage: UsageTab()
                        case .projects: ProjectsTab()
                        case .models: ModelsTab()
                        case .game: GameTab()
                        case .insights: InsightsTab()
                        }
                    }
                    .padding(12)
                    .frame(width: 460)
                    .background(bg)
                    .environment(store)
                    .environment(\.colorScheme, scheme)
                    save(content, to: "\(dir)/\(tab.rawValue.lowercased())-\(scheme == .dark ? "dark" : "light").png")
                }
                save(PopoverView().environment(store).environment(\.colorScheme, scheme).background(bg),
                     to: "\(dir)/popover-\(scheme == .dark ? "dark" : "light").png")
            }
            // Real-window captures (AppKit controls render properly this way).
            let name = { (s: ColorScheme) in s == .dark ? "dark" : "light" }
            for scheme in [ColorScheme.light, .dark] {
                for tab in [Tab.now, .usage, .game] {
                    await saveWindow(PopoverView(forcedTab: tab).environment(store), size: NSSize(width: 460, height: 660),
                                     scheme: scheme, to: "\(dir)/window-\(tab.rawValue.lowercased())-\(name(scheme)).png")
                }
                await saveWindow(SettingsPanel(isPresented: .constant(true)).environment(store), size: NSSize(width: 460, height: 1420),
                                 scheme: scheme, to: "\(dir)/settings-\(name(scheme)).png")
            }
            save(MenuBarStyles().environment(store), to: "\(dir)/menubar-styles.png")
            exit(0)
        }
        app.run()
    }

    private static func saveWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, to path: String) async {
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).background(bg))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.backgroundColor = scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        win.orderOut(nil)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    private static func save<V: View>(_ view: V, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// README illustration of the menu bar display options (demo data).
private struct MenuBarStyles: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        let rows: [(String, String?, Bool, String)] = [
            ("Icon only (default)", nil, false, "Still when idle"),
            ("Icon only", nil, true, "Animates while Claude is working"),
            ("Session count", "2", true, "Working sessions (or open ones, when idle)"),
            ("Today's cost", Fmt.money(store.today.cost), false, "API-equivalent spend today"),
            ("5-hour block", "42%", false, "Plan usage in the current 5-hour window"),
            ("Burn rate", Fmt.money(store.burnPerHour) + "/h", false, "Spend over the last hour"),
        ]
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(nsImage: MenuBarIcon.starburst(size: 15, phase: 3, busy: r.2, rays: store.game.rays))
                            .renderingMode(.template).foregroundStyle(.white)
                        if let t = r.1 { Text(t).font(.system(size: 13)).monospacedDigit().foregroundStyle(.white) }
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18)))
                    .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.0).font(.system(size: 12, weight: .semibold))
                        Text(r.3).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Color(white: 0.97))
        .environment(\.colorScheme, .light)
    }
}
