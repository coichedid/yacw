import Foundation

public struct ModelPrice: Decodable, Sendable {
    public struct LongPrompt: Decodable, Sendable {
        public var threshold: Int
        public var input, cacheWrite5m, cacheWrite1h, cacheRead, output: Double
    }
    public var input, cacheWrite5m, cacheWrite1h, cacheRead, output: Double
    public var longPrompt: LongPrompt?
}

public struct PricingTable: Decodable, Sendable {
    public var source: String
    public var fetchedOn: String
    public var models: [String: ModelPrice]
    public init(source: String, fetchedOn: String, models: [String: ModelPrice]) {
        self.source = source; self.fetchedOn = fetchedOn; self.models = models
    }

    /// `~/Library/Application Support/YACW/pricing.json` wins over the bundled table.
    public static func load() throws -> PricingTable {
        let override = AppPaths.file("pricing.json")
        guard let url = FileManager.default.fileExists(atPath: override.path) ? override : Resources.url("pricing", "json") else {
            throw ProviderError.message("pricing.json não encontrado no app (reinstale o YACW)")
        }
        return try JSONDecoder().decode(PricingTable.self, from: Data(contentsOf: url))
    }

    /// Estimated USD cost, or nil when the model is not in the table (never guessed).
    public func cost(model: String, usage: TokenUsage) -> Double? {
        guard let p = models[model] else { return nil }
        var r = (p.input, p.cacheWrite5m, p.cacheWrite1h, p.cacheRead, p.output)
        if let l = p.longPrompt, usage.promptTokens > l.threshold {
            r = (l.input, l.cacheWrite5m, l.cacheWrite1h, l.cacheRead, l.output)
        }
        let w1h = min(usage.cacheWrite1h, usage.cacheWrite)
        let w5m = usage.cacheWrite - w1h
        let perM = 1_000_000.0
        return (Double(usage.input) * r.0 + Double(w5m) * r.1 + Double(w1h) * r.2
                + Double(usage.cacheRead) * r.3 + Double(usage.output) * r.4) / perM
    }
}
