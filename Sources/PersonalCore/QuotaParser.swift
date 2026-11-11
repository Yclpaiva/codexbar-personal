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
                // Free accounts get a 30-day window: name it in the largest whole unit ("30d", not "43200min").
                let key = minutes.map { $0 % 1440 == 0 ? "\($0 / 1440)d" : $0 % 60 == 0 ? "\($0 / 60)h" : "\($0)min" } ?? "?"
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

    /// `cedar_ember` block of Claude's `/api/oauth/usage?cedar_ember=1`: one entry per reset left in a grant
    /// that is not paused, has started and has not expired. Nil when the block is missing or the account is
    /// not eligible; a malformed grant is skipped.
    public static func claudeResetCredits(_ data: Data, now: Date = Date()) -> [Date?]? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let block = root["cedar_ember"] as? [String: Any], block["eligible"] as? Bool == true else { return nil }
        var expirations: [Date?] = []
        for grant in block["grants"] as? [[String: Any]] ?? [] {
            guard grant["paused"] as? Bool == false, let left = grant["resets_left"] as? Int, left > 0 else { continue }
            if let starts = Self.date(grant["starts_at"]), starts > now { continue }
            let ends = Self.date(grant["ends_at"])
            if let ends, ends <= now { continue }
            // Grants hold one reset each; a larger count is capped instead of trusted.
            expirations += Array(repeating: ends, count: min(left, 50))
        }
        return Self.soonestFirst(expirations)
    }

    /// Codex `/wham/rate-limit-reset-credits`: credits with status `available` that have not expired.
    public static func codexResetCredits(_ data: Data, now: Date = Date()) -> [Date?]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let credits = root["credits"] as? [[String: Any]] else { return nil }
        let expirations = credits.compactMap { credit -> Date?? in
            guard credit["status"] as? String == "available" else { return nil }
            let expires = Self.date(credit["expires_at"])
            return expires.map { $0 > now } ?? true ? .some(expires) : nil
        }
        return Self.soonestFirst(expirations)
    }

    private static func soonestFirst(_ dates: [Date?]) -> [Date?] {
        dates.sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) }
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double, seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
