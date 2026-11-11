import AppKit
import Foundation
import PersonalCore

// Launch Services starts the signed native executable. The existing kit launcher supplies its
// environment on a single re-exec, without a credential file, Keychain prompt or secret in argv.
if ProcessInfo.processInfo.environment["CLIPROXY_MANAGEMENT_KEY"] == nil,
   !CommandLine.arguments.contains("--history"),
   !CommandLine.arguments.contains("--antigravity"),
   !CommandLine.arguments.contains("--demo"),
   !CommandLine.arguments.contains("--credential-relaunch")
{
    let launcher = Process()
    launcher.executableURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/agent-kit/scripts/with-env")
    launcher.arguments = [CommandLine.arguments[0]] + Array(CommandLine.arguments.dropFirst())
        + ["--credential-relaunch"]
    do {
        try launcher.run()
        exit(0)
    } catch {
        // Keep a usable menu with an actionable credential error if the kit is unavailable.
    }
}

/// The proxy's loopback address. Proxyhub serves its dashboard there too, as admin over loopback.
func proxyBaseURL() -> URL? {
    URL(string: ProcessInfo.processInfo.environment["CODEXBAR_PERSONAL_PROXY_URL"] ?? "http://127.0.0.1:8317")
}

/// Proxyhub's account page, where saved limit resets are listed and redeemed.
func proxyAccountsURL() -> URL? {
    guard let base = proxyBaseURL(), var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { return nil }
    components.path = "/"
    components.fragment = "/accounts"
    return components.url
}

func client() throws -> ProxyClient {
    guard let base = proxyBaseURL() else { throw PersonalError.invalidURL }
    return try ProxyClient(base: base, key: ProcessInfo.processInfo.environment["CLIPROXY_MANAGEMENT_KEY"] ?? "")
}

if ["--probe", "--history", "--antigravity"].contains(where: CommandLine.arguments.contains) {
    // Diagnostics deliberately omit account names, auth indexes, credentials and response bodies.
    Task {
        do {
            let started = Date()
            var result: [String: Any] = [:]
            if CommandLine.arguments.contains("--probe") {
                let snapshot = try await client().fetch()
                result["accounts"] = snapshot.accounts.enumerated().map { index, account in
                    [
                        "account": index + 1,
                        "provider": account.provider.rawValue,
                        "tier": account.tier?.rawValue ?? "unknown",
                        "windows": account.windows.count,
                        "error": account.error != nil,
                        "resets": account.resetCredits?.count ?? -1,
                    ] as [String: Any]
                }
                result["pools"] = snapshot.pools.map { pool in
                    [
                        "provider": pool.provider.rawValue,
                        "window": pool.key,
                        "usedPercent": pool.usedPercent,
                        "capacity": pool.capacity,
                        "included": pool.included,
                        "excluded": pool.excluded,
                    ] as [String: Any]
                }
                result["failedAccounts"] = snapshot.accounts.filter { $0.error != nil }.count
            }
            if CommandLine.arguments.contains("--antigravity") {
                guard let executable = AntigravityClient.locate() else { throw PersonalError.antigravityUnavailable }
                let quota = try await AntigravityClient(executable: executable).fetch()
                result["antigravity"] = [
                    "weeklyUsedPercent": quota.usedPercent(minutes: 10080) ?? -1,
                    "groups": quota.groups.map { group in
                        [
                            "name": group.name,
                            "windows": group.windows.map { ["key": $0.key, "usedPercent": $0.usedPercent] },
                        ] as [String: Any]
                    },
                ] as [String: Any]
            }
            if CommandLine.arguments.contains("--history") {
                let report = try HistoryReader.load()
                result["history"] = [
                    "requests": report.totals.requests,
                    "tokens": report.totals.tokens,
                    "costUSD": report.totals.costUSD,
                    "unpricedRequests": report.totals.unpricedRequests,
                    "days": report.days,
                    "models": report.models.count,
                ] as [String: Any]
            }
            result["durationSeconds"] = Date().timeIntervalSince(started)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
            exit((result["failedAccounts"] as? Int ?? 0) == 0 ? 0 : 2)
        } catch {
            print("{\"error\":\"Integration check failed; no credentials or response bodies logged.\"}")
            exit(1)
        }
    }
    dispatchMain()
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
