import SwiftUI
import AppKit

// MARK: - Palette (validated reference palette; light/dark steps of the same hues)

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Palette {
    /// Categorical slots in fixed order. Slot 8 (red) is held back so it never reads as "critical".
    static let series: [Color] = [
        Color(light: 0x2a78d6, dark: 0x3987e5),  // blue
        Color(light: 0xeb6834, dark: 0xd95926),  // orange
        Color(light: 0x1baf7a, dark: 0x199e70),  // aqua
        Color(light: 0xeda100, dark: 0xc98500),  // yellow
        Color(light: 0xe87ba4, dark: 0xd55181),  // magenta
        Color(light: 0x008300, dark: 0x008300),  // green
        Color(light: 0x6250d6, dark: 0x9085e9),  // violet
    ]
    static let other = Color(light: 0xb4b2a9, dark: 0x5f5e5a)

    static func series(_ slot: Int?) -> Color {
        guard let slot, slot >= 0, slot < series.count else { return other }
        return series[slot]
    }

    /// Sequential blue ramp, lightest -> darkest, for heatmaps.
    static let sequential: [Color] = [
        Color(light: 0xcde2fb, dark: 0x104281),
        Color(light: 0x9ec5f4, dark: 0x1c5cab),
        Color(light: 0x6da7ec, dark: 0x2a78d6),
        Color(light: 0x3987e5, dark: 0x5598e7),
        Color(light: 0x1c5cab, dark: 0x86b6ef),
    ]
    static let emptyCell = Color(light: 0xecebe6, dark: 0x262624)

    // Status - reserved for meaning, always paired with an icon/label.
    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let serious = Color(hex: 0xec835a)
    static let critical = Color(hex: 0xd03b3b)

    static let accent = Color(light: 0xd97757, dark: 0xe08a6d)   // Claude clay, for chrome only
    static let card = Color(light: 0xffffff, dark: 0xffffff).opacity(0.0)
    static let cardFill = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)
    static let grid = Color(light: 0xe1e0d9, dark: 0x2c2c2a)
}

// MARK: - Formatting

enum Fmt {
    static func money(_ v: Double, compact: Bool = false) -> String {
        if compact && v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 0.995 || v == 0 { return String(format: "$%.2f", v) }
        return String(format: "$%.2f", v)
    }

    static func tokens(_ v: Int) -> String {
        let d = Double(v)
        switch d {
        case 1e9...: return String(format: "%.2fB", d / 1e9)
        case 1e6...: return String(format: d >= 1e8 ? "%.0fM" : "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.1fk", d / 1e3)
        default: return "\(v)"
        }
    }

    static func number(_ v: Int) -> String {
        v.formatted(.number.grouping(.automatic))
    }

    static func percent(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", v * 100)
    }

    static func duration(_ seconds: TimeInterval, short: Bool = false) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return short ? "\(d)d" : "\(d)d \(h)h" }
        if h > 0 { return short ? "\(h)h\(m)m" : "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        return Fmt.duration(s, short: true) + " ago"
    }

    static func delta(_ v: Double) -> String {
        let pct = abs(v) * 100
        let arrow = v >= 0 ? "▲" : "▼"
        return pct >= 1000 ? "\(arrow) \(Int(v + 1))×" : String(format: "\(arrow) %.0f%%", pct)
    }
}

// MARK: - Menu bar glyph

enum MenuBarIcon {
    /// A Claude-style starburst. `phase` rotates/pulses it while sessions are busy.
    /// `rays` grows with your game level (6 → 12); at max level a core dot appears.
    static func starburst(size: CGFloat = 16, phase: Int = 0, busy: Bool = false, rays: Int = 8, core: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let rotation = busy ? CGFloat(phase % 16) * (.pi / 32) : 0
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = size * 0.135
            for i in 0..<rays {
                let a = CGFloat(i) / CGFloat(rays) * 2 * .pi + rotation
                // while busy, rays breathe in a travelling wave
                let wave = busy ? 0.8 + 0.2 * sin(CGFloat(phase) * 0.7 + CGFloat(i)) : 1
                let inner = size * 0.13, outer = size * 0.44 * wave
                path.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                path.line(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            }
            NSColor.black.setStroke()
            path.stroke()
            if core {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - size * 0.08, y: c.y - size * 0.08, width: size * 0.16, height: size * 0.16)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// A tiny 12-hour cost histogram for the menu bar.
    static func sparkline(_ values: [Double], width: CGFloat = 30, height: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let maxV = max(values.max() ?? 0, 0.0001)
            let n = max(values.count, 1)
            let gap: CGFloat = 1
            let barW = (rect.width - gap * CGFloat(n - 1)) / CGFloat(n)
            NSColor.black.setFill()
            for (i, v) in values.enumerated() {
                let h = max(1.5, CGFloat(v / maxV) * (rect.height - 3))
                let r = NSRect(x: CGFloat(i) * (barW + gap), y: 1.5, width: barW, height: h)
                NSBezierPath(roundedRect: r, xRadius: min(1, barW / 2), yRadius: min(1, barW / 2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// App icon artwork: clay starburst on a warm squircle.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let bg = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
            NSGradient(starting: NSColor(hex: 0xF4EFE6), ending: NSColor(hex: 0xE9E1D3))?.draw(in: bg, angle: -90)
            let c = CGPoint(x: rect.midX, y: rect.midY + size * 0.04)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = size * 0.055
            for i in 0..<12 {
                let a = CGFloat(i) / 12 * 2 * .pi
                let outer = size * (i % 2 == 0 ? 0.27 : 0.21)
                path.move(to: CGPoint(x: c.x + cos(a) * size * 0.06, y: c.y + sin(a) * size * 0.06))
                path.line(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            }
            NSColor(hex: 0xD97757).setStroke()
            path.stroke()
            // a small bar chart along the bottom
            let bars: [CGFloat] = [0.35, 0.6, 0.45, 0.85, 0.55]
            let bw = size * 0.06, base = inset.minY + size * 0.08
            for (i, b) in bars.enumerated() {
                let x = rect.midX - size * 0.2 + CGFloat(i) * size * 0.09
                let r = NSRect(x: x, y: base, width: bw, height: size * 0.1 * b)
                NSColor(hex: 0x2a78d6).withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: r, xRadius: bw / 3, yRadius: bw / 3).fill()
            }
            return true
        }
    }
}
