import Foundation

public struct TokenCounts: Sendable {
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64

    public init(input: Int64, output: Int64, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public func total(provider: Provider) throws -> Int64 {
        guard [self.input, self.output, self.cacheRead, self.cacheWrite, self.reasoning].allSatisfy({ $0 >= 0 }),
              self.reasoning <= self.output else { throw PersonalError.invalidHistory }
        let cache = try Self.sum([self.cacheRead, self.cacheWrite])
        guard provider != .codex || cache <= self.input else { throw PersonalError.invalidHistory }
        return try Self.sum(provider == .codex ? [self.input, self.output] : [self.input, self.output, cache])
    }

    static func sum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { total, value in
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { throw PersonalError.invalidHistory }
            return next.partialValue
        }
    }
}

/// A small, offline snapshot of the existing CodexBar models.dev catalog. No pricing network fetches.
public struct PriceBook: Sendable, Decodable {
    public struct Rates: Sendable, Decodable {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let threshold: Int64?
        let tiers: [Rates]?
    }

    public let fetchedAt: String
    let models: [String: Rates]

    public static func bundled() throws -> Self {
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("CodexBarPersonal_PersonalCore.bundle/pricing.json")
        let url = packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "pricing", withExtension: "json")
        guard let url
        else { throw PersonalError.invalidHistory }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func cost(provider: Provider, model: String, tokens: TokenCounts) throws -> Double? {
        _ = try tokens.total(provider: provider)
        guard var rates = self.models["\(provider.rawValue):\(model)"] else { return nil }
        let context = try TokenCounts.sum(provider == .codex ? [tokens.input] : [
            tokens.input,
            tokens.cacheRead,
            tokens.cacheWrite,
        ])
        for tier in (rates.tiers ?? []).sorted(by: { ($0.threshold ?? .max) < ($1.threshold ?? .max) }) {
            if let threshold = tier.threshold, context > threshold { rates = tier }
        }
        let uncached = provider == .codex ? tokens.input - tokens.cacheRead - tokens.cacheWrite : tokens.input
        let value = (Double(uncached) * rates.input + Double(tokens.output) * rates.output
            + Double(tokens.cacheRead) * (rates.cacheRead ?? rates.input)
            + Double(tokens.cacheWrite) * (rates.cacheWrite ?? rates.input)) / 1_000_000
        guard value.isFinite, value >= 0 else { throw PersonalError.invalidHistory }
        return value
    }
}
