import Foundation

public struct HTTPReply: Sendable {
    public let status: Int
    public let data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }
}

public protocol HTTPTransport: Sendable {
    func response(to request: URLRequest) async throws -> HTTPReply
}

/// Ephemeral sessions never persist credentials, cookies or response caches; redirects are rejected.
public final class LocalHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit { self.session.invalidateAndCancel() }

    public func response(to request: URLRequest) async throws -> HTTPReply {
        let (data, response) = try await self.session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              data.count <= 2_000_000 else { throw PersonalError.invalidResponse }
        return HTTPReply(status: response.statusCode, data: data)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

public actor ProxyClient {
    private struct Credential: Decodable, Sendable {
        let name: String?
        let auth_index: String
        let type: String
        let email: String?
        let label: String?
        let disabled: Bool?
        let id_token: Identity?

        struct Identity: Decodable, Sendable { let chatgpt_plan_type: String? }
    }

    private struct Listing: Decodable { let files: [Credential] }
    private struct Wrapped: Decodable { let status_code: Int; let body: String? }
    private struct Profile { let tier: Tier; let expires: Date }

    private let base: URL
    private let key: String
    private let transport: any HTTPTransport
    private var profiles: [String: Profile] = [:]
    private var inFlight: Task<QuotaSnapshot, Error>?
    private var inFlightProviders: Set<Provider> = []

    public init(
        base: URL = URL(string: "http://127.0.0.1:8317")!,
        key: String,
        transport: any HTTPTransport = LocalHTTPTransport()) throws
    {
        guard base.scheme == "http", base.host == "127.0.0.1", base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              ["", "/"].contains(base.path) else { throw PersonalError.invalidURL }
        guard !key.isEmpty else { throw PersonalError.missingCredential }
        self.base = base
        self.key = key
        self.transport = transport
    }

    /// Concurrent callers share one observation; no overlapping quota polling or unbounded task queue.
    /// Only accounts of the requested providers are read, so hidden providers cost no upstream calls.
    public func fetch(providers: Set<Provider> = Set(Provider.allCases)) async throws -> QuotaSnapshot {
        if let inFlight, self.inFlightProviders == providers { return try await inFlight.value }
        let task = Task { try await self.load(providers) }
        self.inFlight = task
        self.inFlightProviders = providers
        defer { self.inFlight = nil }
        return try await task.value
    }

    private func load(_ providers: Set<Provider>) async throws -> QuotaSnapshot {
        let data = try await self.request("credentials")
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let files = listing.files.filter {
            Provider(rawValue: $0.type).map(providers.contains) == true && $0.disabled != true
        }
        guard files.count <= 100 else { throw PersonalError.invalidResponse }
        let ids = Set(files.map(\.auth_index))
        self.profiles = self.profiles.filter { ids.contains($0.key) && $0.value.expires > Date() }
        var accounts: [AccountQuota] = []
        // Two independent reads at a time bound the proxy load even when the pool grows.
        for start in stride(from: 0, to: files.count, by: 2) {
            let batch = Array(files[start..<min(start + 2, files.count)])
            let results = await withTaskGroup(of: AccountQuota.self) { group in
                for file in batch {
                    group.addTask { await self.account(file) }
                }
                var results: [AccountQuota] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            accounts.append(contentsOf: results)
        }
        accounts.sort { ($0.provider.rawValue, $0.label) < ($1.provider.rawValue, $1.label) }
        return QuotaSnapshot(updatedAt: Date(), accounts: accounts)
    }

    private func account(_ file: Credential) async -> AccountQuota {
        let provider = Provider(rawValue: file.type)!
        var tier = provider == .codex ? Tier.codex(file.id_token?.chatgpt_plan_type) : self.profiles[file.auth_index]?
            .tier
        var windows: [QuotaWindow] = []
        var blocked = false
        var accountError: String?
        do {
            let data = try await self.upstream(file, resource: "usage")
            windows = try QuotaParser.windows(provider: provider, data: data)
            blocked = windows.contains { $0.usedPercent >= 100 }
            if provider == .codex {
                let details = try QuotaParser.codexDetails(data)
                tier = details.0 ?? tier
                blocked = blocked || details.1
            }
        } catch let failure as PersonalError {
            accountError = failure.localizedDescription
        } catch {
            accountError = "Não foi possível consultar esta conta."
        }
        if provider == .claude, tier == nil {
            if let data = try? await self.upstream(file, resource: "profile"),
               let resolved = try? QuotaParser.claudeTier(data)
            {
                tier = resolved
                self.profiles[file.auth_index] = Profile(tier: resolved, expires: Date().addingTimeInterval(3600))
            }
        }
        return AccountQuota(
            id: file.auth_index,
            provider: provider,
            label: file.email ?? file.label ?? file.name ?? "Conta",
            tier: tier,
            windows: windows,
            blocked: blocked,
            error: accountError)
    }

    private func upstream(_ file: Credential, resource: String) async throws -> Data {
        let claude = file.type == "claude"
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "User-Agent": claude ? "claude-code/2.1.0" : "codex_cli_rs",
        ]
        if claude { headers["anthropic-beta"] = "oauth-2025-04-20" }
        let payload: [String: Any] = [
            "auth_index": file.auth_index,
            "method": "GET",
            "header": headers,
            "url": claude ? "https://api.anthropic.com/api/oauth/\(resource)"
                : "https://chatgpt.com/backend-api/wham/usage",
        ]
        let data = try await self.request("requests/api-call", body: JSONSerialization.data(withJSONObject: payload))
        let wrapped = try JSONDecoder().decode(Wrapped.self, from: data)
        // Authentication refresh remains owned by the proxy; quota observation does not mutate credentials.
        guard wrapped.status_code == 200 else { throw PersonalError.http(wrapped.status_code) }
        guard let body = wrapped.body?.data(using: .utf8) else { throw PersonalError.invalidResponse }
        return body
    }

    private func request(_ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: self.base.appendingPathComponent("v8/management/\(path)"))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(self.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBarPersonal/0.1", forHTTPHeaderField: "User-Agent")
        let response = try await self.transport.response(to: request)
        guard (200..<300).contains(response.status) else { throw PersonalError.http(response.status) }
        return response.data
    }
}
