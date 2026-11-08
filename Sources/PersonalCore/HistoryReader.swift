import Foundation
import SQLite3

/// Serializes on-demand reads, dropping canceled requests before scanning the database.
public actor HistoryService {
    public static let shared = HistoryService()

    public func load(days: Int) throws -> UsageReport {
        try Task.checkCancellation()
        return try HistoryReader.load(days: days)
    }
}

public struct UsageTotals: Codable, Sendable {
    public var requests: Int64 = 0
    public var failed: Int64 = 0
    public var tokens: Int64 = 0
    public var costUSD: Double = 0
    public var unpricedRequests: Int64 = 0
}

public struct DailyUsage: Codable, Sendable {
    public let day: String
    public let totals: UsageTotals
}

public struct ModelUsage: Codable, Sendable {
    public let provider: Provider
    public let model: String
    public let totals: UsageTotals
}

public struct UsageReport: Codable, Sendable {
    public let generatedAt: Date
    public let days: Int
    public let since: String
    public let until: String
    public let totals: UsageTotals
    public let daily: [DailyUsage]
    public let models: [ModelUsage]
    public let pricingDate: String
}

public enum HistoryReader {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/cpa-usage/usage.db")
    }

    /// Streams one read-only SQLite snapshot, retaining only daily and model aggregates.
    /// Quota refresh never calls this reader; history is loaded only while the dashboard is requested.
    public static func load(
        databaseURL: URL = HistoryReader.defaultURL,
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current,
        prices: PriceBook? = nil) throws -> UsageReport
    {
        guard [1, 7, 30, 90].contains(days) else { throw PersonalError.invalidHistory }
        let book = try prices ?? PriceBook.bundled()
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let until = dayFormatter.string(from: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: now)
        else { throw PersonalError.invalidHistory }
        let since = dayFormatter.string(from: start)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) ==
            SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            throw PersonalError.historyUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        guard sqlite3_exec(database, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK
        else { throw PersonalError.historyUnavailable }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let sql = """
        SELECT day, provider, model, input, output, cache_read, cache_write, reasoning, failed
        FROM events WHERE day >= ? AND day <= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw PersonalError.invalidHistory }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, since, -1, transient)
        sqlite3_bind_text(statement, 2, until, -1, transient)
        var totals = UsageTotals()
        var daily: [String: UsageTotals] = [:]
        var models: [String: ModelUsage] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try autoreleasepool {
                guard let day = Self.text(statement, 0), let providerName = Self.text(statement, 1),
                      let provider = Provider(rawValue: providerName), let model = Self.text(statement, 2),
                      model.utf8.count <= 256,
                      (3...8).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER })
                else { throw PersonalError.invalidHistory }
                let counts = TokenCounts(
                    input: sqlite3_column_int64(statement, 3),
                    output: sqlite3_column_int64(statement, 4),
                    cacheRead: sqlite3_column_int64(statement, 5),
                    cacheWrite: sqlite3_column_int64(statement, 6),
                    reasoning: sqlite3_column_int64(statement, 7))
                let tokens = try counts.total(provider: provider)
                let cost = try book.cost(provider: provider, model: model, tokens: counts)
                let failed = sqlite3_column_int64(statement, 8)
                guard failed == 0 || failed == 1 else { throw PersonalError.invalidHistory }
                try Self.add(&totals, tokens: tokens, cost: cost, failed: failed)
                var dayTotals = daily[day, default: UsageTotals()]
                try Self.add(&dayTotals, tokens: tokens, cost: cost, failed: failed)
                daily[day] = dayTotals
                let key = "\(providerName):\(model)"
                var modelTotals = models[key]?.totals ?? UsageTotals()
                try Self.add(&modelTotals, tokens: tokens, cost: cost, failed: failed)
                models[key] = ModelUsage(provider: provider, model: model, totals: modelTotals)
                guard models.count <= 512, daily.count <= days else { throw PersonalError.invalidHistory }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw PersonalError.historyUnavailable }
        // Include zero days so the chart's visual spacing is a real calendar interval.
        let series = (0..<days).compactMap { offset -> DailyUsage? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayFormatter.string(from: date)
            return DailyUsage(day: key, totals: daily[key, default: UsageTotals()])
        }
        return UsageReport(
            generatedAt: now,
            days: days,
            since: since,
            until: until,
            totals: totals,
            daily: series,
            models: models.values.sorted { $0.totals.tokens > $1.totals.tokens },
            pricingDate: book.fetchedAt)
    }

    private static func add(_ totals: inout UsageTotals, tokens: Int64, cost: Double?, failed: Int64) throws {
        totals.requests = try TokenCounts.sum([totals.requests, 1])
        totals.failed = try TokenCounts.sum([totals.failed, failed])
        totals.tokens = try TokenCounts.sum([totals.tokens, tokens])
        totals.costUSD += cost ?? 0
        totals.unpricedRequests = try TokenCounts.sum([totals.unpricedRequests, cost == nil ? 1 : 0])
        guard totals.costUSD.isFinite else { throw PersonalError.invalidHistory }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
