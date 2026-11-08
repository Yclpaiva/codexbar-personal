import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var title: String {
        self == .claude ? "Claude" : "Codex"
    }
}

public enum Tier: String, Codable, Sendable {
    case free = "Free", one = "1x", five = "5x", ten = "10x", twenty = "20x"

    public var capacity: Double? {
        switch self {
        case .free: nil
        case .one: 1
        case .five: 5
        case .ten: 10
        case .twenty: 20
        }
    }

    public static func codex(_ plan: String?) -> Self? {
        switch plan?.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "free": .free
        case "plus": .one
        case "prolite": .five
        case "pro": .twenty
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

    public init(
        id: String,
        provider: Provider,
        label: String,
        tier: Tier?,
        windows: [QuotaWindow],
        blocked: Bool,
        error: String?)
    {
        self.id = id
        self.provider = provider
        self.label = label
        self.tier = tier
        self.windows = windows
        self.blocked = blocked
        self.error = error
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

    public var pools: [PoolQuota] {
        Provider.allCases.flatMap { provider in
            ["5h", "7d"].compactMap { PoolQuota.calculate(accounts: self.accounts, provider: provider, key: $0) }
        }
    }
}

public enum PersonalError: LocalizedError, Sendable {
    case missingCredential, invalidURL, http(Int), invalidResponse, historyUnavailable, invalidHistory
    case antigravityUnavailable, antigravityFailed

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Credencial de gestão indisponível. Inicie pelo launcher do agent-kit."
        case .invalidURL: "O proxy deve usar HTTP em 127.0.0.1."
        case let .http(status): "Consulta indisponível (HTTP \(status))."
        case .invalidResponse: "O serviço retornou dados incompatíveis."
        case .historyUnavailable: "Não foi possível ler o histórico local do proxy."
        case .invalidHistory: "O histórico contém dados incompatíveis."
        case .antigravityUnavailable: "agy não encontrado. Instale o Antigravity CLI."
        case .antigravityFailed: "Antigravity não respondeu. Rode agy no Terminal para entrar de novo."
        }
    }
}

public enum Display {
    public static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2f bi", Double(value) / 1e9) }
        if value >= 1_000_000 { return String(format: "%.1f mi", Double(value) / 1e6) }
        if value >= 1000 { return String(format: "%.1f mil", Double(value) / 1000) }
        return String(value)
    }

    public static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "reset indisponível" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "reset em \(minutes) min" }
        if minutes < 2880 { return "reset em \(minutes / 60)h\(minutes % 60)" }
        return "reset em \(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
}
