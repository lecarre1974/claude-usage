import Foundation

/// Per-million-token API list prices. Cache writes are 1.25x (5m) / 2x (1h) input;
/// cache reads vary per model. Subscription users don't pay these, so the UI
/// labels them "API-equivalent".
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2.0 }
}

enum Pricing {
    /// Ordered most-specific first; matched by prefix against the normalized model id.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1",  ModelPrice(input: 10,   output: 50,   cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10,   output: 50,   cacheRead: 0.25)),
        ("claude-fable-5",    ModelPrice(input: 10,   output: 50,   cacheRead: 1.00)),
        ("claude-mythos-5",   ModelPrice(input: 10,   output: 50,   cacheRead: 1.00)),
        ("claude-opus-5-5",   ModelPrice(input: 4,    output: 20,   cacheRead: 0.20)),
        ("claude-opus-5",     ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),
        ("claude-opus-4-8",   ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),
        ("claude-opus-4-7",   ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),
        ("claude-opus-4-6",   ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),
        ("claude-opus-4-5",   ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),
        ("claude-opus-4",     ModelPrice(input: 15,   output: 75,   cacheRead: 1.50)),
        ("claude-sonnet-5",   ModelPrice(input: 2,    output: 10,   cacheRead: 0.20)),
        ("claude-sonnet-4",   ModelPrice(input: 3,    output: 15,   cacheRead: 0.30)),
        ("claude-3-7-sonnet", ModelPrice(input: 3,    output: 15,   cacheRead: 0.30)),
        ("claude-3-5-sonnet", ModelPrice(input: 3,    output: 15,   cacheRead: 0.30)),
        ("claude-3-opus",     ModelPrice(input: 15,   output: 75,   cacheRead: 1.50)),
        ("claude-3-haiku",    ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03)),
        ("claude-haiku-5-5",  ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4",    ModelPrice(input: 1,    output: 5,    cacheRead: 0.10)),
        ("claude-3-5-haiku",  ModelPrice(input: 0.80, output: 4,    cacheRead: 0.08)),
    ]

    private static let fallback = ModelPrice(input: 5, output: 25, cacheRead: 0.50)

    static func price(for model: String) -> ModelPrice {
        for row in table where model.hasPrefix(row.prefix) { return row.price }
        if model.contains("haiku") { return ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01) }
        if model.contains("sonnet") { return ModelPrice(input: 2, output: 10, cacheRead: 0.20) }
        if model.contains("fable") { return ModelPrice(input: 10, output: 50, cacheRead: 0.25) }
        return fallback
    }

    static func cost(model: String, input: Int, output: Int, cw5m: Int, cw1h: Int, cacheRead: Int, fast: Bool) -> Double {
        var p = price(for: model)
        // Haiku 5.5 switches to its long-prompt rate card above 100K prompt tokens.
        if model.hasPrefix("claude-haiku-5-5"), input + cw5m + cw1h + cacheRead > 100_000 {
            p = ModelPrice(input: 0.50, output: 2.50, cacheRead: 0.05)
        }
        // Fast mode is a 2x premium; it only exists on Opus 5.x / 4.8.
        let fastModels = ["claude-opus-5", "claude-opus-4-8"]
        let m = fast && fastModels.contains(where: model.hasPrefix) ? 2.0 : 1.0
        let dollars = Double(input) * p.input * m
            + Double(output) * p.output * m
            + Double(cw5m) * p.cacheWrite5m * m
            + Double(cw1h) * p.cacheWrite1h * m
            + Double(cacheRead) * p.cacheRead * m
        return dollars / 1_000_000
    }

    /// Default context window in Claude Code: 1M on current models, 200k on older ones.
    static func contextWindow(_ model: String) -> Int {
        let million = ["claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"]
        if million.contains(where: model.hasPrefix) { return 1_000_000 }
        let legacy = ["claude-3", "claude-sonnet-4", "claude-haiku-4", "claude-opus-4"]
        return legacy.contains(where: model.hasPrefix) ? 200_000 : 1_000_000
    }

    /// Premium paid when a cache entry has to be rebuilt instead of read.
    static func rebuildPremium(model: String, tokens: Int) -> Double {
        let p = price(for: model)
        return Double(tokens) * (p.cacheWrite1h - p.cacheRead) / 1_000_000
    }

    /// What the cache reads would have cost if billed as fresh input.
    static func cacheSavings(model: String, cacheRead: Int) -> Double {
        let p = price(for: model)
        return Double(cacheRead) * (p.input - p.cacheRead) / 1_000_000
    }

    /// "claude-opus-5[1m]" -> "claude-opus-5"; aliases like "sonnet" kept as-is.
    static func normalize(_ model: String) -> String {
        if let i = model.firstIndex(of: "[") { return String(model[..<i]) }
        return model
    }

    static func displayName(_ model: String) -> String {
        let m = normalize(model)
        guard m.hasPrefix("claude-") else { return m.capitalized }
        var parts = m.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // drop trailing date stamps like 20250514
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return m }
        let version = parts.dropFirst().joined(separator: ".")
        // legacy ids: claude-3-5-haiku
        if Int(family) != nil, let fam = parts.last {
            return "\(fam.capitalized) \(parts.dropLast().joined(separator: "."))"
        }
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
