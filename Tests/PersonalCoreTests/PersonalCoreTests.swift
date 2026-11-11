import Foundation
import PersonalCore
import SQLite3

struct PersonalCoreTests {
    func `pool weights paid capacity and explicitly excludes free failed and missing windows`() throws {
        let accounts = [
            Self.account("one", tier: .one, used: 100),
            Self.account("five", tier: .five, used: 20),
            Self.account("free", tier: .free, used: 100),
            Self.account("unknown", tier: nil, used: 100),
            Self.account("failed", tier: .twenty, used: 90, error: "HTTP 503"),
        ]
        let pool = try require(PoolQuota.calculate(accounts: accounts, provider: .codex, key: "7d"))
        try expect(pool.capacity == 6)
        try expect(abs(pool.usedPercent - 100.0 / 3) < 0.0001)
        try expect(pool.usedCapacity == 2)
        try expect(pool.included == 2)
        try expect(pool.excluded == 3)
        try expect(PoolQuota.calculate(accounts: accounts, provider: .claude, key: "7d") == nil)
        try expect(PoolQuota.calculate(accounts: accounts, provider: .codex, key: "5h") == nil)
    }

    func `codex windows use duration rather than primary secondary ordering`() throws {
        let data = Data(
            #"""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 81,
                  "limit_window_seconds": 604800,
                  "reset_at": 1794000000
                },
                "secondary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 18000
                }
              }
            }
            """#
                .utf8)
        let windows = try QuotaParser.windows(provider: .codex, data: data)
        try expect(windows.map(\.key) == ["7d", "5h"])
        try expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1_794_000_000))
        let free = Data(#"{"rate_limit":{"primary_window":{"used_percent":43,"limit_window_seconds":2592000}}}"#.utf8)
        try expect(try QuotaParser.windows(provider: .codex, data: free).map(\.key) == ["30d"])
    }

    func `claude supports structured and legacy quotas without duplicate session windows`() throws {
        let data = Data(
            #"""
            {
              "limits": [
                {
                  "kind": "session",
                  "percent": 24,
                  "resets_at": "2026-11-08T18:00:00Z"
                }
              ],
              "five_hour": {
                "utilization": 99
              },
              "seven_day": {
                "utilization": 62
              }
            }
            """#
                .utf8)
        let windows = try QuotaParser.windows(provider: .claude, data: data)
        try expect(windows.map(\.usedPercent) == [24, 62])
        try expect(windows.first?.resetsAt != nil)
        try expectThrows {
            try QuotaParser.windows(provider: .claude, data: Data(#"{"five_hour":{"utilization":true}}"#.utf8))
        }
    }

    func `tiers preserve Yuri effective Claude max capacity and Codex Pro multiples`() throws {
        try expect(Tier.codex("pro_lite") == .ten)
        try expect(Tier.codex("promax") == .fifty)
        try expect(Tier.codex("pro-max") == .fifty)
        try expect(Tier.codex("pro") == .twenty)
        try expect(try QuotaParser
            .claudeTier(Data(#"{"organization":{"rate_limit_tier":"default_claude_max_20x"}}"#.utf8)) == .ten)
    }

    func `cache and reasoning are not billed twice and long context uses whole request rates`() throws {
        let prices = try Self.prices()
        let codex = TokenCounts(input: 1000, output: 100, cacheRead: 200, cacheWrite: 100, reasoning: 30)
        try expect(try codex.total(provider: .codex) == 1100)
        try expect(try prices.cost(provider: .codex, model: "fictional-test", tokens: codex) == 0.00267)
        let claude = TokenCounts(input: 1000, output: 100, cacheRead: 200, cacheWrite: 300, reasoning: 50)
        try expect(try claude.total(provider: .claude) == 1600)
        try expect(try abs(require(prices.cost(provider: .claude, model: "fictional-test", tokens: claude)) -
                0.005685) <
            1e-12)
        let exact = TokenCounts(input: 272_000, output: 100)
        let above = TokenCounts(input: 272_001, output: 100)
        try expect(try prices.cost(provider: .codex, model: "fictional-test", tokens: exact) == 0.545)
        try expect(try abs(require(prices.cost(provider: .codex, model: "fictional-test", tokens: above)) - 1.089504) <
            1e-12)
        try expect(try prices.cost(provider: .codex, model: "unknown", tokens: exact) == nil)
        try expectThrows {
            try TokenCounts(input: 10, output: 0, cacheRead: 11).total(provider: .codex)
        }
        try expectThrows { try TokenCounts(input: .max, output: 1).total(provider: .codex) }
    }

    func `history keeps range totals unknown prices and failed attempts without writes`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.execute("""
        INSERT INTO events VALUES ('2026-11-08','codex','fictional-test',1000,100,200,100,30,0);
        INSERT INTO events VALUES ('2026-11-07','claude','fictional-test',1000,100,200,300,50,1);
        INSERT INTO events VALUES ('2026-11-08','codex','unknown',100,5,0,0,0,0);
        INSERT INTO events VALUES ('2026-10-01','codex','fictional-test',9000,900,0,0,0,0);
        INSERT INTO events VALUES ('2026-11-09','codex','fictional-test',9000,900,0,0,0,0);
        """)
        let before = try Data(contentsOf: fixture.url)
        let report = try HistoryReader.load(
            databaseURL: fixture.url,
            days: 7,
            now: Self.now,
            calendar: Self.calendar,
            prices: Self.prices())
        try expect(report.totals.requests == 3)
        try expect(report.totals.tokens == 2805)
        try expect(report.totals.failed == 1)
        try expect(report.totals.unpricedRequests == 1)
        try expect(abs(report.totals.costUSD - 0.008355) < 1e-12)
        try expect(report.daily.count == 7)
        try expect(report.daily.first?.day == "2026-11-02")
        try expect(report.daily.map(\.totals.tokens).reduce(0, +) == report.totals.tokens)
        try expect(report.models.map(\.totals.tokens).reduce(0, +) == report.totals.tokens)
        try expect(try Data(contentsOf: fixture.url) == before)
    }

    func `missing and malformed history fail visibly without creating a database`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = fixture.url.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
        try expectThrows { try HistoryReader.load(databaseURL: missing) }
        try expect(!FileManager.default.fileExists(atPath: missing.path))
        try fixture.execute("INSERT INTO events VALUES ('2026-11-08','codex','x',1,1,0,0,2,0)")
        try expectThrows {
            try HistoryReader.load(
                databaseURL: fixture.url,
                now: Self.now,
                calendar: Self.calendar,
                prices: Self.prices())
        }
    }

    func `network shares refreshes and keeps upstream token placeholders`() async throws {
        let transport = FixtureTransport()
        let client = try ProxyClient(key: "fixture-key", transport: transport)
        let snapshots = try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.fetch() }
            }
            var snapshots: [QuotaSnapshot] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
        try expect(snapshots.count == 8)
        try expect(snapshots.allSatisfy { $0.accounts.count == 1 && $0.accounts[0].tier == .ten })
        try expect(snapshots[0].accounts[0].resetCredits?.count == 1)
        let requests = await transport.requests
        try expect(requests.count == 3)
        try expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
        let body = try require(requests.last?.httpBody)
        let payload = try require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        try expect(payload["method"] as? String == "GET")
        try expect((payload["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$")
        try expect(!(String(data: body, encoding: .utf8) ?? "").contains("fixture-key"))
    }

    func `client preserves partial account errors and rejects credential destinations outside loopback`() async throws {
        let transport = FixtureTransport(status: 429)
        let snapshot = try await ProxyClient(key: "fixture", transport: transport).fetch()
        try expect(snapshot.accounts.first?.error?.contains("429") == true)
        try expect(snapshot.pools.isEmpty)
        try expectThrows { try ProxyClient(
            base: require(URL(string: "http://example.com")),
            key: "fixture") }
        try expectThrows { try ProxyClient(
            base: require(URL(string: "http://127.0.0.1?secret=1")),
            key: "fixture") }
    }

    func `antigravity converts remaining fractions and keeps model extras out of the headline`() throws {
        let groups = try AntigravityParser.groups(Self.antigravityReport)
        try expect(groups.map(\.name) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
        try expect(groups[0].windows.map(\.label) == ["7d", "5h"])
        try expect(abs(groups[1].windows[0].usedPercent - 25) < 0.0001)
        try expect(groups[0].windows[0].resetsAt == Date(timeIntervalSince1970: 1_794_776_014))
        let quota = AntigravityQuota(updatedAt: Date(), groups: groups)
        try expect(abs((quota.usedPercent(minutes: 10080) ?? -1) - 25) < 0.0001)
        try expect(abs((quota.usedPercent(minutes: 300) ?? -1) - 10) < 0.0001)
        try expectThrows { try AntigravityParser.groups(Data(#"{"status":"ERROR"}"#.utf8)) }
        try expectThrows { try AntigravityParser.groups(Data(
            #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"G","buckets":[{"id":"x","window":"5h","remaining_fraction":true}]}]}}}"#
                .utf8)) }
    }

    func `antigravity runs agy with private home blocked browser and bounded time`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("report.json")
        try Self.antigravityReport.write(to: report)
        let seen = directory.appendingPathComponent("seen")
        // The fake agy only answers when the private environment is in place, and records its HOME.
        let script = """
        #!/bin/sh
        [ "$*" = "-p /usage --output-format json" ] || exit 4
        [ -L "$HOME/Library" ] && [ ! -e "$HOME/.gemini" ] || exit 5
        [ "$AGY_CLI_DISABLE_AUTO_UPDATE" = "true" ] || exit 6
        open https://accounts.google.com && exit 7
        "$BROWSER" https://accounts.google.com && exit 8
        printf '%s' "$HOME" > '\(seen.path)'
        cat '\(report.path)'
        """
        let fake = try Self.executable(script, in: directory, named: "agy")
        let quota = try await AntigravityClient(executable: fake).fetch()
        try expect(quota.groups.count == 3)
        let home = try String(contentsOf: seen, encoding: .utf8)
        try expect(home != FileManager.default.homeDirectoryForCurrentUser.path)
        try expect(!FileManager.default.fileExists(atPath: home))
        try expect(FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path))

        let slow = try Self.executable("#!/bin/sh\nexec sleep 30\n", in: directory, named: "slow")
        let started = Date()
        do {
            _ = try await AntigravityClient(executable: slow, timeout: 1).fetch()
            throw CheckFailure(description: "Expected timeout")
        } catch is PersonalError {}
        try expect(Date().timeIntervalSince(started) < 10)
        let failing = try Self.executable("#!/bin/sh\necho '{}'\nexit 1\n", in: directory, named: "failing")
        do {
            _ = try await AntigravityClient(executable: failing).fetch()
            throw CheckFailure(description: "Expected failure")
        } catch is PersonalError {}
    }

    func `settings keep new providers visible and fall back when the chosen one is hidden`() throws {
        let suite = "personal-tests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Nothing stored: the menu bar follows the selected tab, as in CodexBar.
        try expect(PersonalSettings.load(from: defaults).barMode == .selectedTab)
        // Stored by an older version: unknown and duplicate entries, Antigravity missing, bad interval.
        defaults.set(["codex", "gemini", "codex"], forKey: "providerOrder")
        defaults.set(["claude"], forKey: "hiddenProviders")
        defaults.set("claude", forKey: "barMode")
        defaults.set("claude", forKey: "lastTab")
        defaults.set(7, forKey: "refreshMinutes")
        var settings = PersonalSettings.load(from: defaults)
        try expect(settings.order == [.codex, .claude, .antigravity])
        try expect(settings.visible == [.codex, .antigravity])
        try expect(settings.refreshMinutes == 5)
        try expect(settings.tab == nil)
        let usage: [MenuProvider: Double] = [.claude: 99, .codex: 40, .antigravity: 60]
        // Hidden fixed provider falls back to the highest visible one.
        try expect(settings.headline { usage[$0] }?.provider == .antigravity)
        settings.hidden = []
        try expect(settings.headline { usage[$0] }?.provider == .claude)

        settings.barMode = .selectedTab
        settings.lastTab = .codex
        try expect(settings.headline { usage[$0] }?.provider == .codex)
        try expect(settings.headline { $0 == .codex ? nil : usage[$0] }.map { $0.provider == .codex
                && $0.usedPercent == nil
        } == true)
        settings.lastTab = nil
        try expect(settings.headline { usage[$0] }?.usedPercent == 99)

        settings.barMode = .highest
        settings.lastTab = .codex
        settings.showIcon = false
        settings.showBars = true
        settings.barPercent = .both
        settings.order = [.antigravity, .codex, .claude]
        settings.save(to: defaults)
        let reloaded = PersonalSettings.load(from: defaults)
        try expect(reloaded == settings)
        try expect(reloaded.headline { usage[$0] }?.provider == .claude)
        try expect(reloaded.headline { _ in nil } == nil)
        try expect(BarMode.choices.allSatisfy { BarMode(stored: $0.stored) == $0 })
        let now = Date()
        try expect(Display.reset(now.addingTimeInterval(125 * 60 + 30), now: now).hasSuffix(" 2h05"))
    }

    func `menu bar drops an exhausted or missing five hour lane and follows it in the percentages`() throws {
        let both = MenuBarContent(fiveHours: 13, week: 94, percent: .both)
        try expect(both.fiveHours == 13 && both.week == 94 && both.text == "13% · 94%")
        try expect(MenuBarContent(fiveHours: 13, week: 94, percent: .week).text == "94%")
        try expect(MenuBarContent(fiveHours: 13, week: 94, percent: .fiveHours).text == "13%")
        // Every account with a 5h window is exhausted: only the weekly meter and percentage remain.
        let exhausted = MenuBarContent(fiveHours: 100, week: 37, percent: .both)
        try expect(exhausted.fiveHours == nil && exhausted.week == 37 && exhausted.text == "37%")
        try expect(MenuBarContent(fiveHours: 100, week: 37, percent: .fiveHours).text == "37%")
        // Weekly-only plans have no 5h pool at all.
        let weekly = MenuBarContent(fiveHours: nil, week: 100, percent: .fiveHours)
        try expect(weekly.fiveHours == nil && weekly.text == "100%")
        try expect(MenuBarContent(fiveHours: 40, week: nil, percent: .week).text == "40%")
        try expect(MenuBarContent(fiveHours: 13, week: 94, percent: .none).text == nil)
        try expect(MenuBarContent(fiveHours: nil, week: nil, percent: .both).text == "—")
        try expect(PersonalSettings(barPercent: .fiveHours).rankingWindow == .fiveHours)
        try expect(PersonalSettings(barPercent: .both).rankingWindow == .week)
    }

    func `every localized key used in the sources has a Portuguese translation`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/PersonalCore/Resources")
        func table(_ language: String) throws -> [String: String] {
            try require(NSDictionary(contentsOf: resources.appendingPathComponent(
                "\(language).lproj/Localizable.strings")) as? [String: String])
        }
        let english = try table("en"), portuguese = try table("pt-BR")
        let pattern = try NSRegularExpression(pattern: #"L10n\s*\.tr\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]).replacingOccurrences(
                    of: #"\""#,
                    with: "\""))
            }
        }
        try expect(keys.count > 50)
        try expect(keys.allSatisfy { english[$0] == $0 && portuguese[$0].map { !$0.isEmpty } == true })
        try expect(Set(portuguese.keys) == keys && Set(english.keys) == keys)
        // Format specifiers must survive translation, or String(format:) would read the wrong arguments.
        let specifiers = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-0-9.]*(?:l{0,2})[@dfs%]"#)
        func specs(_ value: String) -> [String] {
            specifiers.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { String(value[Range($0.range, in: value)!]) }
        }
        try expect(keys.allSatisfy { specs($0) == specs(portuguese[$0] ?? "") })
    }

    func `hidden proxy providers cost no account reads`() async throws {
        let transport = FixtureTransport()
        let client = try ProxyClient(key: "fixture", transport: transport)
        let snapshot = try await client.fetch(providers: [.claude])
        try expect(snapshot.accounts.isEmpty)
        let reads = await transport.requests.count
        try expect(reads == 1)
        let both = try await client.fetch()
        try expect(both.accounts.count == 1)
        let quota = try AntigravityQuota(updatedAt: Date(), groups: AntigravityParser.groups(Self.antigravityReport))
        let fiveHours = Usage.percent(.antigravity, window: .fiveHours, snapshot: both, antigravity: quota)
        try expect(abs((fiveHours ?? -1) - 10) < 0.0001)
        try expect(Usage.percent(.codex, window: .week, snapshot: both, antigravity: nil) == 20)
        try expect(Usage.percent(.claude, window: .week, snapshot: both, antigravity: quota) == nil)
    }

    func `saved limit resets count only usable grants and credits soonest first`() throws {
        let claude = Data(
            #"""
            {"cedar_ember":{"eligible":true,"grants":[
              {"resets_left":1,"starts_at":"2026-11-09T18:00:00+00:00","ends_at":"2027-03-09T07:59:00+00:00","paused":false},
              {"resets_left":2,"ends_at":null,"paused":false},
              {"resets_left":1,"ends_at":"2026-11-17T07:59:00+00:00","paused":false},
              {"resets_left":1,"ends_at":"2026-12-01T00:00:00+00:00","paused":true},
              {"resets_left":1,"starts_at":"2026-12-01T00:00:00+00:00","paused":false},
              {"resets_left":0,"paused":false},
              {"resets_left":1,"ends_at":"2026-11-01T00:00:00+00:00","paused":false},
              {"resets_left":"1","paused":false}]}}
            """#.utf8)
        let resets = try require(QuotaParser.claudeResetCredits(claude, now: Self.resetNow))
        try expect(resets.count == 4)
        try expect(resets[0] == ISO8601DateFormatter().date(from: "2026-11-17T07:59:00Z"))
        try expect(resets[1] == ISO8601DateFormatter().date(from: "2027-03-09T07:59:00Z"))
        try expect(resets[2] == nil && resets[3] == nil)
        try expect(QuotaParser.claudeResetCredits(Data(#"{"cedar_ember":{"eligible":false,"grants":[]}}"#.utf8)) == nil)
        try expect(QuotaParser.claudeResetCredits(Data(#"{"five_hour":{}}"#.utf8)) == nil)

        let codex = Data(
            #"""
            {"available_count":2,"credits":[
              {"status":"available","expires_at":"2026-12-01T22:17:43.978726Z"},
              {"status":"available","expires_at":"2026-11-30T19:28:46.435195Z"},
              {"status":"redeemed","expires_at":"2026-11-30T19:28:46Z"},
              {"status":"available","expires_at":"2026-11-01T00:00:00Z"}]}
            """#.utf8)
        let credits = try require(QuotaParser.codexResetCredits(codex, now: Self.resetNow))
        try expect(credits.count == 2)
        try expect(credits.allSatisfy { $0 != nil })
        try expect(credits[0]! < credits[1]!)
        try expect(QuotaParser.codexResetCredits(Data(#"{"detail":"Unauthorized"}"#.utf8)) == nil)
    }

    private static var resetNow: Date {
        ISO8601DateFormatter().date(from: "2026-11-09T20:00:00Z")!
    }

    private static var antigravityReport: Data {
        Data(#"""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-15T20:53:34Z"},
            {"id":"gemini-5h","window":"5h","remaining_fraction":0.9,"reset_time":"2026-11-09T01:53:34Z"}]},
          {"name":"Claude and GPT models","buckets":[
            {"id":"3p-weekly","window":"weekly","remaining_fraction":0.75},
            {"id":"3p-5h","window":"5h","remaining_fraction":1}]},
          {"name":"Gemini 4 Argon","buckets":[
            {"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.001}]}]}}}
        """#.utf8)
    }

    private static func executable(_ script: String, in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static var now: Date {
        Date(timeIntervalSince1970: 1_794_153_600)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func account(_ id: String, tier: Tier?, used: Double, error: String? = nil) -> AccountQuota {
        AccountQuota(
            id: id,
            provider: .codex,
            label: id,
            tier: tier,
            windows: [QuotaWindow(key: "7d", label: "7d", usedPercent: used)],
            blocked: false,
            error: error)
    }

    private static func prices() throws -> PriceBook {
        try JSONDecoder().decode(
            PriceBook.self,
            from: Data(
                #"""
                {
                  "fetchedAt": "2026-11-08",
                  "models": {
                    "codex:fictional-test": {
                      "input": 2,
                      "output": 10,
                      "cacheRead": 0.1,
                      "cacheWrite": 2.5,
                      "tiers": [
                        {
                          "threshold": 272000,
                          "input": 4,
                          "output": 15,
                          "cacheRead": 0.2,
                          "cacheWrite": 5
                        }
                      ]
                    },
                    "claude:fictional-test": {
                      "input": 3,
                      "output": 15,
                      "cacheRead": 0.3,
                      "cacheWrite": 3.75
                    }
                  }
                }
                """#
                    .utf8))
    }
}

private actor FixtureTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int

    init(status: Int = 200) { self.status = status }

    func response(to request: URLRequest) async throws -> HTTPReply {
        self.requests.append(request)
        try await Task.sleep(for: .milliseconds(10))
        if request.url?.lastPathComponent == "credentials" {
            return HTTPReply(
                status: 200,
                data: Data(#"{"files":[{"auth_index":"synthetic","name":"fixture","type":"codex","disabled":false}]}"#
                    .utf8))
        }
        if let body = request.httpBody,
           String(data: body, encoding: .utf8)?.contains("rate-limit-reset-credits") == true
        {
            let credits = #"{"credits":[{"status":"available","expires_at":"2099-01-01T00:00:00Z"}]}"#
            return try HTTPReply(
                status: 200,
                data: JSONSerialization.data(withJSONObject: ["status_code": self.status, "body": credits]))
        }
        let body = #"""
        {"plan_type":"pro_lite","rate_limit":{
          "primary_window":{"used_percent":20,"limit_window_seconds":604800}
        }}
        """#
        let wrapped: [String: Any] = ["status_code": self.status, "body": body]
        return try HTTPReply(status: 200, data: JSONSerialization.data(withJSONObject: wrapped))
    }
}

private struct Fixture {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("usage.sqlite")
        try self
            .execute(
                """
                CREATE TABLE events(day TEXT,provider TEXT,model TEXT,input INTEGER,output INTEGER,
                cache_read INTEGER,cache_write INTEGER,reasoning INTEGER,failed INTEGER)
                """)
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(self.url.path, &database) == SQLITE_OK,
              let database else { throw PersonalError.historyUnavailable }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw PersonalError.invalidHistory }
    }

    func cleanup() { try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent()) }
}

@main
struct PersonalCoreCheckRunner {
    static func main() async {
        let checks = PersonalCoreTests()
        do {
            try checks.`pool weights paid capacity and explicitly excludes free failed and missing windows`()
            print("PASS pool weights paid capacity and explicitly excludes free failed and missing windows")
            try checks.`codex windows use duration rather than primary secondary ordering`()
            print("PASS codex windows use duration rather than primary secondary ordering")
            try checks.`claude supports structured and legacy quotas without duplicate session windows`()
            print("PASS claude supports structured and legacy quotas without duplicate session windows")
            try checks.`tiers preserve Yuri effective Claude max capacity and Codex Pro multiples`()
            print("PASS tiers preserve Yuri effective Claude max capacity and Codex Pro multiples")
            try checks.`cache and reasoning are not billed twice and long context uses whole request rates`()
            print("PASS cache and reasoning are not billed twice and long context uses whole request rates")
            try checks
                .`history keeps range totals unknown prices and failed attempts without writes`()
            print(
                "PASS history keeps range totals unknown prices and failed attempts without writes")
            try checks.`missing and malformed history fail visibly without creating a database`()
            print("PASS missing and malformed history fail visibly without creating a database")
            try await checks
                .`network shares refreshes and keeps upstream token placeholders`()
            print(
                "PASS network shares refreshes and keeps upstream token placeholders")
            try await checks
                .`client preserves partial account errors and rejects credential destinations outside loopback`()
            print("PASS client preserves partial account errors and rejects credential destinations outside loopback")
            try checks.`antigravity converts remaining fractions and keeps model extras out of the headline`()
            print("PASS antigravity converts remaining fractions and keeps model extras out of the headline")
            try await checks.`antigravity runs agy with private home blocked browser and bounded time`()
            print("PASS antigravity runs agy with private home blocked browser and bounded time")
            try checks.`settings keep new providers visible and fall back when the chosen one is hidden`()
            print("PASS settings keep new providers visible and fall back when the chosen one is hidden")
            try checks.`menu bar drops an exhausted or missing five hour lane and follows it in the percentages`()
            print("PASS menu bar drops an exhausted or missing five hour lane and follows it in the percentages")
            try checks.`every localized key used in the sources has a Portuguese translation`()
            print("PASS every localized key used in the sources has a Portuguese translation")
            try await checks.`hidden proxy providers cost no account reads`()
            print("PASS hidden proxy providers cost no account reads")
            try checks.`saved limit resets count only usable grants and credits soonest first`()
            print("PASS saved limit resets count only usable grants and credits soonest first")
            print("16 behavior checks passed")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line) throws
{
    guard try condition() else { throw CheckFailure(description: "Assertion failed at \(file):\(line)") }
}

private func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "Required value missing at \(file):\(line)") }
    return value
}

private func expectThrows(_ action: () throws -> some Any, file: StaticString = #filePath, line: UInt = #line) throws {
    do {
        _ = try action()
    } catch is PersonalError {
        return
    }
    throw CheckFailure(description: "Expected PersonalError at \(file):\(line)")
}
