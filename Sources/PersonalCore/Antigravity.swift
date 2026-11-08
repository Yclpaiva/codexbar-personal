import Foundation

public struct AntigravityGroup: Sendable {
    public let name: String
    public let windows: [QuotaWindow]

    public init(name: String, windows: [QuotaWindow]) {
        self.name = name
        self.windows = windows
    }
}

public struct AntigravityQuota: Sendable {
    public let updatedAt: Date
    public let groups: [AntigravityGroup]

    public init(updatedAt: Date, groups: [AntigravityGroup]) {
        self.updatedAt = updatedAt
        self.groups = groups
    }

    /// Usage of the shared Gemini and Claude/GPT groups for a window (10080 or 300 minutes).
    /// Model-specific extras such as Argon have their own allowance and stay in the menu instead
    /// of driving the headline.
    public func usedPercent(minutes: Int) -> Double? {
        let windows = self.groups.flatMap(\.windows).filter { $0.minutes == minutes }
        let suffix = minutes == 10080 ? "weekly" : "5h"
        let shared = windows.filter { ["gemini-\(suffix)", "3p-\(suffix)"].contains($0.key) }
        return (shared.isEmpty ? windows : shared).map(\.usedPercent).max()
    }
}

public enum AntigravityParser {
    /// Parses `agy -p /usage --output-format json`. Remaining fractions become used percentages.
    public static func groups(_ data: Data) throws -> [AntigravityGroup] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let command = root["command"] as? [String: Any] ?? [:]
        guard root["status"] as? String == "SUCCESS", command["name"] as? String == "usage" else {
            throw PersonalError.antigravityFailed
        }
        let payload = command["data"] as? [String: Any] ?? [:]
        let groups = (payload["groups"] as? [[String: Any]] ?? []).compactMap { group -> AntigravityGroup? in
            let windows = (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> QuotaWindow? in
                guard let id = bucket["id"] as? String,
                      let fraction = bucket["remaining_fraction"] as? NSNumber,
                      CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                      (0...1).contains(fraction.doubleValue) else { return nil }
                let window = bucket["window"] as? String
                let minutes = window == "weekly" ? 10080 : window == "5h" ? 300 : nil
                return QuotaWindow(
                    key: id,
                    label: minutes == 10080 ? "7d" : minutes == 300 ? "5h" : window ?? "?",
                    usedPercent: (1 - fraction.doubleValue) * 100,
                    resetsAt: (bucket["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                    minutes: minutes)
            }
            guard let name = group["name"] as? String, !windows.isEmpty else { return nil }
            return AntigravityGroup(name: name, windows: windows)
        }
        guard !groups.isEmpty else { throw PersonalError.invalidResponse }
        return groups
    }
}

/// Reads the signed-in `agy` CLI's usage report. Each run gets a private HOME whose only entry is a
/// link to the real ~/Library, so the Keychain login keeps working while the user's MCP servers,
/// conversations and settings under ~/.gemini are not loaded. Browser launchers fail, so an expired
/// login reports an error instead of opening Google sign-in. No model prompt is sent.
public actor AntigravityClient {
    private let executable: URL
    private let timeout: TimeInterval
    private var inFlight: Task<AntigravityQuota, Error>?

    public init(executable: URL, timeout: TimeInterval = 75) {
        self.executable = executable
        self.timeout = timeout
    }

    /// An explicit ANTIGRAVITY_CLI_PATH is authoritative; otherwise the usual install locations are tried.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = environment["ANTIGRAVITY_CLI_PATH"].map { [$0] }
            ?? ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public func fetch() async throws -> AntigravityQuota {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.load() }
        self.inFlight = task
        defer { self.inFlight = nil }
        return try await task.value
    }

    private func load() async throws -> AntigravityQuota {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("codexbar-personal-agy-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let work = root.appendingPathComponent("work")
        let bin = root.appendingPathComponent("bin")
        // removeItem deletes the Library link itself, never the real directory it points to.
        defer { try? manager.removeItem(at: root) }
        for directory in [home, work, bin] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
            ])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try manager.createSymbolicLink(
            at: home.appendingPathComponent("Library"),
            withDestinationURL: manager.homeDirectoryForCurrentUser.appendingPathComponent("Library"))
        for name in ["open", "xdg-open"] {
            let launcher = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: launcher)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }

        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "BROWSER": bin.appendingPathComponent("open").path,
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            "LANG": "en_US.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR"] {
            environment[key] = inherited[key]
        }

        let process = Process()
        process.executableURL = self.executable
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = work
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let timeout = self.timeout
        let data = try await Task.detached { () throws -> Data in
            try process.run()
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return data
        }.value
        guard process.terminationReason == .exit, process.terminationStatus == 0, data.count <= 1_048_576 else {
            throw PersonalError.antigravityFailed
        }
        return try AntigravityQuota(updatedAt: Date(), groups: AntigravityParser.groups(data))
    }
}
