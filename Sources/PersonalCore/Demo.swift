import Foundation

/// Fictional quotas for `--demo`, used for screenshots without real accounts, network or agy.
public enum Demo {
    public static func snapshot(now: Date = Date()) -> QuotaSnapshot {
        func window(_ key: String, _ used: Double, hours: Double) -> QuotaWindow {
            QuotaWindow(
                key: key,
                label: key,
                usedPercent: used,
                resetsAt: now.addingTimeInterval(hours * 3600),
                minutes: key == "5h" ? 300 : 10080)
        }
        func account(_ provider: Provider, _ label: String, _ tier: Tier, _ week: Double, _ session: Double?)
            -> AccountQuota
        {
            let windows = [window("7d", week, hours: 52)] + (session.map { [window("5h", $0, hours: 3.2)] } ?? [])
            return AccountQuota(
                id: label,
                provider: provider,
                label: label,
                tier: tier,
                windows: windows,
                blocked: week >= 100,
                error: nil)
        }
        return QuotaSnapshot(updatedAt: now, accounts: [
            account(.claude, "studio@example.com", .ten, 58, 22),
            account(.claude, "personal@example.com", .five, 41, 12),
            account(.claude, "side-project@example.com", .one, 73, nil),
            // A weekly-only high plan plus an exhausted 5h window: Codex shows a single weekly meter.
            account(.codex, "studio@example.com", .twenty, 36, nil),
            account(.codex, "personal@example.com", .one, 64, 100),
            account(.codex, "sandbox@example.com", .free, 12, nil),
        ])
    }

    public static func antigravity(now: Date = Date()) -> AntigravityQuota {
        func window(_ key: String, _ used: Double, weekly: Bool) -> QuotaWindow {
            QuotaWindow(
                key: key,
                label: weekly ? "7d" : "5h",
                usedPercent: used,
                resetsAt: now.addingTimeInterval(weekly ? 4.5 * 86400 : 2.1 * 3600),
                minutes: weekly ? 10080 : 300)
        }
        return AntigravityQuota(updatedAt: now, groups: [
            AntigravityGroup(name: "Gemini Models", windows: [
                window("gemini-weekly", 27, weekly: true), window("gemini-5h", 8, weekly: false),
            ]),
            AntigravityGroup(name: "Claude and GPT models", windows: [
                window("3p-weekly", 46, weekly: true), window("3p-5h", 15, weekly: false),
            ]),
        ])
    }
}
