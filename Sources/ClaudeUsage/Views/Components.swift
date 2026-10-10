import SwiftUI
import Charts

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var delta: Double? = nil
    var deltaGoodWhenUp = false
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                if let delta {
                    let up = delta >= 0
                    // Spend rising isn't "good" or "bad" by itself; keep it in neutral ink with the arrow.
                    Text(Fmt.delta(delta))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(deltaGoodWhenUp ? (up ? Palette.good : Palette.serious) : .secondary)
                }
                if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.cardFill))
        .help(help ?? "")
    }
}

struct ColorDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct PulsingDot: View {
    let active: Bool
    var color: Color = Palette.good
    var body: some View {
        // SF Symbol effects run in CoreAnimation, so a pulsing row costs ~nothing per frame.
        Image(systemName: active ? "circle.circle.fill" : "circle.fill")
            .font(.system(size: active ? 11 : 7))
            .foregroundStyle(active ? color : Color.secondary.opacity(0.5))
            .symbolEffect(.pulse, options: .repeating, isActive: active)
            .frame(width: 14, height: 14)
    }
}

struct RingGauge: View {
    let fraction: Double
    var lineWidth: CGFloat = 7
    var color: Color = Palette.series[0]
    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if fraction > 1 {
                Circle()
                    .trim(from: 0, to: min(fraction - 1, 1))
                    .stroke(Palette.critical, style: StrokeStyle(lineWidth: lineWidth * 0.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.easeOut(duration: 0.5), value: fraction)
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Palette.series[0]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color.opacity(0.18))
                .interpolationMethod(.monotone)
            LineMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(max(values.max() ?? 0, 0.0001) * 1.1))
        .chartLegend(.hidden)
    }
}

/// Horizontal 100% stacked bar with a legend underneath; values are always printed (never color-only).
struct CompositionBar: View {
    struct Part: Identifiable { let id: String; let value: Double; let color: Color; let detail: String }
    let parts: [Part]

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 0.000001)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.value > 0 }) { p in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(p.color)
                            .frame(width: max(3, (geo.size.width - CGFloat(parts.count) * 2) * p.value / total))
                            .help("\(p.id): \(p.detail)")
                    }
                }
            }
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(parts) { p in
                    HStack(spacing: 6) {
                        ColorDot(color: p.color, size: 7)
                        Text(p.id).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(p.detail).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        Text(Fmt.percent(p.value / total)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct BarListRow: View {
    let label: String
    let value: Double
    let maxValue: Double
    let valueText: String
    var color: Color = Palette.series[0]
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).lineLimit(1).frame(width: 120, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(2, g.size.width * value / max(maxValue, 0.0001)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
            Text(valueText).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Palette.hairline : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Chip: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let color { ColorDot(color: color, size: 6) }
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Palette.hairline))
        .foregroundStyle(.secondary)
    }
}

struct EmptyHint: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 14)
    }
}

/// A pure-SwiftUI link (renders in snapshots, unlike AppKit-backed Link/Button).
struct LinkText: View {
    let text: String
    let url: String
    @State private var hover = false
    var body: some View {
        Text(text)
            .foregroundStyle(Color.accentColor)
            .underline(hover)
            .onHover { hover = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .onTapGesture { UsageStore.open(url) }
            .help(url)
    }
}

/// Thin capsule progress bar (pure SwiftUI so it renders identically everywhere).
struct Bar: View {
    let value: Double
    var color: Color = Palette.series[0]
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule().fill(color).frame(width: value > 0 ? max(height, g.size.width * min(max(value, 0), 1)) : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}
