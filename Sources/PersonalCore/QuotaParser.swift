import Foundation

public enum QuotaParser {
    public static func windows(provider: Provider, data: Data) throws -> [QuotaWindow] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var windows: [QuotaWindow] = []
        func add(_ key: String, _ label: String, _ percent: Any?, _ reset: Any?, _ minutes: Int?) {
            guard let value = percent as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return }
            windows.append(QuotaWindow(
                key: key,
                label: label,
                usedPercent: value.doubleValue,
                resetsAt: Self.date(reset),
                minutes: minutes))
        }
        if provider == .claude {
            for limit in root["limits"] as? [[String: Any]] ?? [] {
                let kind = limit["kind"] as? String
                if kind == "session" { add("5h", "5h", limit["percent"], limit["resets_at"], 300) }
                if kind == "weekly_all" { add("7d", "7d", limit["percent"], limit["resets_at"], 10080) }
                if kind == "weekly_scoped",
                   let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                   let label = model["display_name"] as? String
                {
                    add(label.lowercased(), label, limit["percent"], limit["resets_at"], 10080)
                }
            }
            for (key, field, minutes) in [("5h", "five_hour", 300), ("7d", "seven_day", 10080)]
                where !windows.contains(where: { $0.key == key })
            {
                let item = root[field] as? [String: Any] ?? [:]
                add(key, key, item["utilization"], item["resets_at"], minutes)
            }
        } else {
            let rate = root["rate_limit"] as? [String: Any] ?? [:]
            for field in ["primary_window", "secondary_window"] {
                guard let item = rate[field] as? [String: Any] else { continue }
                let minutes = (item["limit_window_seconds"] as? Int).map { $0 / 60 }
                let key = minutes == 300 ? "5h" : minutes == 10080 ? "7d" : minutes.map { "\($0)min" } ?? "?"
                add(key, key, item["used_percent"], item["reset_at"], minutes)
            }
        }
        guard !windows.isEmpty else { throw PersonalError.invalidResponse }
        return windows
    }

    public static func codexDetails(_ data: Data) throws -> (Tier?, Bool) {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rate = root["rate_limit"] as? [String: Any] ?? [:]
        return (
            Tier.codex(root["plan_type"] as? String),
            rate["limit_reached"] as? Bool == true || rate["allowed"] as? Bool == false)
    }

    public static func claudeTier(_ data: Data) throws -> Tier? {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let organization = root["organization"] as? [String: Any] ?? [:]
        let account = root["account"] as? [String: Any] ?? [:]
        let rate = organization["rate_limit_tier"] as? String ?? ""
        if rate.hasSuffix("claude_max_20x") || rate.hasSuffix("claude_max_10x") { return .ten }
        if rate.hasSuffix("claude_max_5x") { return .five }
        if organization["organization_type"] as? String == "claude_pro" || account["has_claude_pro"] as? Bool ==
            true { return .one }
        if ["claude_free", "free"].contains(organization["organization_type"] as? String ?? "") { return .free }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double, seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
