import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var title: String {
        self == .claude ? "Claude" : "Codex"
    }
}

public enum Tier: String, Codable, Sendable {
    case free = "Free", one = "1x", five = "5x", ten = "10x", twenty = "20x", fifty = "50x"

    public var capacity: Double? {
        switch self {
        case .free: nil
        case .one: 1
        case .five: 5
        case .ten: 10
        case .twenty: 20
        case .fifty: 50
        }
    }

    /// Multiples of Plus as OpenAI published them on 2026-11-08: Pro 100, 200 and 500 give 10, 20 and 50x.
    public static func codex(_ plan: String?) -> Self? {
        switch plan?.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "free": .free
        case "plus": .one
        case "prolite": .ten
        case "pro": .twenty
        case "promax": .fifty
        default: nil
        }
    }
}

public struct QuotaWindow: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let minutes: Int?

    public init(key: String, label: String, usedPercent: Double, resetsAt: Date? = nil, minutes: Int? = nil) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.minutes = minutes
    }
}

public struct AccountQuota: Codable, Sendable {
    public let id: String
    public let provider: Provider
    public let label: String
    public let tier: Tier?
    public let windows: [QuotaWindow]
    public let blocked: Bool
    public let error: String?
    /// Expiry of each saved limit reset still available, soonest first; nil entries never expire.
    /// Nil when the inventory could not be read, so a failed read is not shown as "no resets".
    public let resetCredits: [Date?]?

    public init(
        id: String,
        provider: Provider,
        label: String,
        tier: Tier?,
        windows: [QuotaWindow],
        blocked: Bool,
        error: String?,
        resetCredits: [Date?]? = nil)
    {
        self.id = id
        self.provider = provider
        self.label = label
        self.tier = tier
        self.windows = windows
        self.blocked = blocked
        self.error = error
        self.resetCredits = resetCredits
    }
}

public struct PoolQuota: Codable, Sendable {
    public let provider: Provider
    public let key: String
    public let usedPercent: Double
    public let capacity: Double
    public let usedCapacity: Double
    public let included: Int
    public let excluded: Int
    public let resetsAt: Date?

    public static func calculate(accounts: [AccountQuota], provider: Provider, key: String) -> Self? {
        let candidates = accounts.filter { $0.provider == provider }
        let included = candidates.compactMap { account -> (Double, QuotaWindow)? in
            guard account.error == nil, let capacity = account.tier?.capacity,
                  let window = account.windows.first(where: { $0.key == key }),
                  window.usedPercent.isFinite, window.usedPercent >= 0 else { return nil }
            return (capacity, window)
        }
        guard !included.isEmpty else { return nil }
        let capacity = included.reduce(0) { $0 + $1.0 }
        let used = included.reduce(0) { $0 + $1.0 * $1.1.usedPercent / 100 }
        return Self(
            provider: provider,
            key: key,
            usedPercent: used / capacity * 100,
            capacity: capacity,
            usedCapacity: used,
            included: included.count,
            excluded: candidates.count - included.count,
            resetsAt: included.compactMap(\.1.resetsAt).min())
    }
}

public struct QuotaSnapshot: Codable, Sendable {
    public let updatedAt: Date
    public let accounts: [AccountQuota]

    /// Weighted pools per provider: 5h, weekly and, for Claude, the weekly Fable allowance.
    public var pools: [PoolQuota] {
        Provider.allCases.flatMap { provider in
            ["5h", "7d", "fable"].compactMap { PoolQuota.calculate(accounts: self.accounts, provider: provider, key: $0) }
        }
    }
}

public enum PersonalError: LocalizedError, Sendable {
    case missingCredential, invalidURL, http(Int), invalidResponse, historyUnavailable, invalidHistory
    case antigravityUnavailable, antigravityFailed

    public var errorDescription: String? {
        switch self {
        case .missingCredential: L10n
            .tr("Management credential unavailable. Start the app through the agent-kit launcher.")
        case .invalidURL: L10n.tr("The proxy must use HTTP on 127.0.0.1.")
        case let .http(status): L10n.tr("Request unavailable (HTTP %ld).", status)
        case .invalidResponse: L10n.tr("The service returned incompatible data.")
        case .historyUnavailable: L10n.tr("Could not read the local proxy history.")
        case .invalidHistory: L10n.tr("The history contains incompatible data.")
        case .antigravityUnavailable: L10n.tr("agy not found. Install the Antigravity CLI.")
        case .antigravityFailed: L10n.tr("Antigravity did not respond. Run agy in Terminal to sign in again.")
        }
    }
}

public enum Display {
    public static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return L10n.tr("%.2f B", Double(value) / 1e9) }
        if value >= 1_000_000 { return L10n.tr("%.1f M", Double(value) / 1e6) }
        if value >= 1000 { return L10n.tr("%.1f K", Double(value) / 1000) }
        return String(value)
    }

    public static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L10n.tr("reset unavailable") }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return L10n.tr("resets in %ld min", minutes) }
        if minutes < 2880 { return L10n.tr("resets in %ldh%02ld", minutes / 60, minutes % 60) }
        return L10n.tr("resets in %ldd %ldh", minutes / 1440, minutes % 1440 / 60)
    }

    public static func resetCount(_ count: Int) -> String {
        count == 1 ? L10n.tr("1 reset") : L10n.tr("%ld resets", count)
    }

    /// Countdown under two days, calendar date after that.
    public static func expiry(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L10n.tr("no expiry") }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return L10n.tr("expires in %ld min", minutes) }
        if minutes < 2880 { return L10n.tr("expires in %ldh%02ld", minutes / 60, minutes % 60) }
        return L10n.tr("expires %@", date.formatted(date: .abbreviated, time: .omitted))
    }
}
