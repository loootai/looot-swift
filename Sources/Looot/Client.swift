import Foundation

/// The SDK version, sent in the `User-Agent` header.
public let loootVersion = "0.1.0"

/// The production looot API.
public let defaultBaseURL = "https://api.looot.ai"

/// Per-request timeout in seconds. It covers a run with the longest wait (60 s).
public let defaultTimeout: TimeInterval = 75

/// How many times a retryable error is retried, with the same idempotency key.
public let defaultMaxRetries = 2

/// The Swift compiler version the SDK was built with, for the `User-Agent` header.
private let swiftRuntimeVersion: String = {
    #if compiler(>=6.3)
    return "6.3"
    #elseif compiler(>=6.2)
    return "6.2"
    #elseif compiler(>=6.1)
    return "6.1"
    #elseif compiler(>=6.0)
    return "6.0"
    #elseif compiler(>=5.10)
    return "5.10"
    #else
    return "5.9"
    #endif
}()

/// Calls the looot API. Safe to share between tasks.
///
/// ```swift
/// let looot = Looot()   // reads LOOOT_TOKEN
/// let balance = try await looot.balance()
/// ```
///
/// HTTP errors throw ``LoootError``. A run that failed is not an HTTP error: `run` and `runJob`
/// return the run, and you read `status`, `outcome` and `error` on it.
public final class Looot: Sendable {
    /// The gateway this client calls.
    public let baseURL: String
    /// The `X-Looot-Agent` value, if set.
    public let agent: String?
    /// Per-request timeout in seconds.
    public let timeout: TimeInterval
    /// How many times a retryable error is retried. 0 turns retries off.
    public let maxRetries: Int

    private let token: String?
    private let transport: HTTPTransport
    private let userAgent: String
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let makeKey: @Sendable () -> String

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - token: The bearer token. It wins over `LOOOT_TOKEN`, even when empty: an explicit
    ///     empty token means "no token".
    ///   - baseURL: Another gateway, for example a local one. Trailing slashes are removed.
    ///   - agent: Names the app or agent making the calls, for usage analytics only. Cut to 64
    ///     characters and sent as `X-Looot-Agent`.
    ///   - timeout: Per-request timeout in seconds.
    ///   - maxRetries: Retries for 429, retryable 503s, network errors and timeouts.
    ///   - transport: Replaces the HTTP layer, for tests or a custom session.
    ///   - environment: Where `LOOOT_TOKEN` is read from. Defaults to the process environment.
    public convenience init(
        token: String? = nil,
        baseURL: String = defaultBaseURL,
        agent: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        maxRetries: Int = defaultMaxRetries,
        transport: HTTPTransport? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            token: token, baseURL: baseURL, agent: agent, timeout: timeout, maxRetries: maxRetries,
            transport: transport, environment: environment,
            sleeper: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
            makeKey: { "sdk-" + UUID().uuidString.lowercased() })
    }

    init(
        token: String?,
        baseURL: String,
        agent: String?,
        timeout: TimeInterval,
        maxRetries: Int,
        transport: HTTPTransport?,
        environment: [String: String],
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void,
        makeKey: @escaping @Sendable () -> String
    ) {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base.isEmpty ? defaultBaseURL : base

        let resolved = (token ?? environment["LOOOT_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = resolved.isEmpty ? nil : resolved

        let trimmedAgent = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.agent = trimmedAgent.isEmpty ? nil : String(trimmedAgent.prefix(64))

        self.timeout = timeout > 0 ? timeout : defaultTimeout
        self.maxRetries = max(0, maxRetries)
        self.transport = transport ?? URLSessionTransport()
        self.userAgent = "looot-swift/\(loootVersion) swift/\(swiftRuntimeVersion)"
        self.sleeper = sleeper
        self.makeKey = makeKey
    }

    /// True when the client has a token. It never returns the token itself.
    public var hasToken: Bool { token != nil }

    // MARK: - Free catalog routes (no token sent)

    /// Maps the catalog: categories by default, matching jobs with `topic`. Free, no token sent.
    public func catalogOverview(
        depth: String? = nil, category: String? = nil, platform: String? = nil, topic: String? = nil
    ) async throws -> CatalogOverview {
        try await get("/v1/catalog/overview", [
            ("depth", depth), ("category", category), ("platform", platform), ("topic", topic),
        ], auth: false)
    }

    /// Lists published catalog items. Free, no token sent.
    ///
    /// `capability` is a job id with dots turned into underscores: `people_email_verify`.
    public func publicCatalog(
        q: String? = nil, text: String? = nil, capability: String? = nil, category: String? = nil,
        provider: String? = nil, operationId: String? = nil, limit: Int? = nil, cursor: String? = nil
    ) async throws -> PublicCatalogPage {
        try await get("/v1/public-catalog", [
            ("q", q), ("text", text), ("capability", capability), ("category", category),
            ("provider", provider), ("operationId", operationId), ("limit", int(limit)), ("cursor", cursor),
        ], auth: false)
    }

    /// Returns one published item. Free, no token sent.
    public func publicCatalogItem(_ catalogItemId: String) async throws -> PublicCatalogItem {
        try await get("/v1/public-catalog/" + segment(catalogItemId), [], auth: false)
    }

    /// Compares 2 to 20 public items. Free, no token sent.
    public func comparePublicCatalog(_ catalogItemIds: [String]) async throws -> CatalogComparison {
        try await send(
            method: "POST", path: "/v1/public-catalog/compare", query: [],
            body: .object(["catalogItemIds": .array(catalogItemIds.map { .string($0) })]), auth: false)
    }

    // MARK: - Search and inspect

    /// Finds endpoints for a task in plain words. Needs `catalog.read`. Free.
    ///
    /// `capability` is a job id with dots: `people.email.find`.
    public func search(
        _ q: String? = nil, limit: Int? = nil, offset: Int? = nil, category: String? = nil,
        platform: String? = nil, provider: String? = nil, capability: String? = nil,
        keyless: Bool? = nil, verified: Bool? = nil, mock: Bool? = nil, maxPriceMicros: Int64? = nil,
        prefer: Prefer? = nil
    ) async throws -> SearchResult {
        try await get("/v1/catalog/search", [
            ("q", q), ("limit", int(limit)), ("offset", int(offset)), ("category", category),
            ("platform", platform), ("provider", provider), ("capability", capability),
            ("keyless", bool(keyless)), ("verified", bool(verified)), ("mock", bool(mock)),
            ("maxPriceMicros", maxPriceMicros.map(String.init)), ("prefer", prefer?.rawValue),
        ], auth: true)
    }

    /// Returns up to 5 ranked candidates for a task. Needs `catalog.read`. Free.
    public func discover(
        query: String? = nil, mode: String? = nil, capability: String? = nil, category: String? = nil,
        provider: String? = nil, prefer: Prefer? = nil, resultLimit: Int? = nil, maxPrice: Double? = nil,
        includeUnavailable: Bool? = nil
    ) async throws -> DiscoverResult {
        try await get("/v1/discover", [
            ("query", query), ("mode", mode), ("capability", capability), ("category", category),
            ("provider", provider), ("prefer", prefer?.rawValue), ("resultLimit", int(resultLimit)),
            ("maxPrice", maxPrice.map { number($0) }), ("includeUnavailable", bool(includeUnavailable)),
        ], auth: true)
    }

    /// Lists endpoints page by page. Needs `catalog.read`. Free. `facets: true` adds counts.
    public func catalogEndpoints(
        capability: String? = nil, category: String? = nil, platform: String? = nil,
        provider: String? = nil, keyless: Bool? = nil, verified: Bool? = nil, mock: Bool? = nil,
        maxPriceMicros: Int64? = nil, includeUnavailable: Bool? = nil, facets: Bool? = nil,
        limit: Int? = nil, cursor: String? = nil
    ) async throws -> CatalogEndpointsPage {
        try await get("/v1/catalog/endpoints", [
            ("capability", capability), ("category", category), ("platform", platform),
            ("provider", provider), ("keyless", bool(keyless)), ("verified", bool(verified)),
            ("mock", bool(mock)), ("maxPriceMicros", maxPriceMicros.map(String.init)),
            ("includeUnavailable", bool(includeUnavailable)), ("facets", bool(facets)),
            ("limit", int(limit)), ("cursor", cursor),
        ], auth: true)
    }

    /// Returns one endpoint's inputs, price and hints. Takes an endpoint id, not `job:<id>`. Free.
    public func inspect(_ endpointId: String) async throws -> EndpointDetail {
        try await get("/v1/operations/" + segment(endpointId), [], auth: true)
    }

    // MARK: - Runs

    /// Runs one endpoint. Paid. Needs `runs.execute`.
    ///
    /// A run refused before dispatch comes back as a run with `status` `failed`, not as a
    /// thrown error. A thrown ``LoootError`` means the HTTP call failed (402
    /// `insufficient_balance`, 429, and so on).
    ///
    /// - Parameters:
    ///   - endpointId: A catalog endpoint id, or `job:<job id>`.
    ///   - input: Validated against the endpoint's own schema.
    ///   - idempotencyKey: Build it from your own record (`lead-4821-email`) so a crashed
    ///     worker replays the first run instead of paying twice. The SDK generates
    ///     `sdk-<uuid v4>` when you pass none.
    ///   - fallback: Try the next provider on a miss.
    ///   - output: Optional output selection pin.
    ///   - wait: Seconds (1 to 60) the gateway holds the answer. Nil or 0 returns at once.
    public func run(
        endpointId: String, input: JSONValue = .object([:]), idempotencyKey: String? = nil,
        fallback: FallbackOptions? = nil, output: JSONValue? = nil, wait: Int? = nil
    ) async throws -> Run {
        let key = (idempotencyKey?.isEmpty == false) ? idempotencyKey! : makeKey()
        var body: [String: JSONValue] = [
            "endpointId": .string(endpointId),
            "input": input,
            "idempotencyKey": .string(key),
        ]
        if let fallback = fallback { body["fallback"] = fallback.jsonValue }
        if let output = output { body["output"] = output }
        return try await send(
            method: "POST", path: "/v1/runs", query: [("wait", int(wait))],
            body: .object(body), auth: true, idempotencyKey: key)
    }

    /// Runs a job such as `people.email.find`; looot picks the provider. Paid.
    ///
    /// `prefer` goes into `fallback.prefer` and turns fallback on. With neither `prefer` nor
    /// `fallback`, a job run does not fall back. Take job ids from `catalogOverview` or a search
    /// row's `capability`, never guess one.
    public func runJob(
        _ job: String, input: JSONValue = .object([:]), prefer: Prefer? = nil,
        fallback: FallbackOptions? = nil, wait: Int? = nil, idempotencyKey: String? = nil,
        output: JSONValue? = nil
    ) async throws -> Run {
        var fb = fallback
        if let prefer = prefer {
            var merged = fb ?? FallbackOptions()
            merged.prefer = prefer
            fb = merged
        }
        return try await run(
            endpointId: "job:" + job, input: input, idempotencyKey: idempotencyKey,
            fallback: fb, output: output, wait: wait)
    }

    /// Returns a run. Needs `runs.read`.
    ///
    /// `fields` (dotted paths of `result` to keep) and `maxItems` (1 to 10000) trim the answer.
    /// The charge does not change.
    public func getRun(_ runId: String, fields: [String]? = nil, maxItems: Int? = nil) async throws -> Run {
        try await get("/v1/runs/" + segment(runId), [
            ("fields", fields.flatMap { $0.isEmpty ? nil : $0.joined(separator: ",") }),
            ("max_items", int(maxItems)),
        ], auth: true)
    }

    /// Returns one page of runs, newest first. Needs `runs.read`.
    public func listRuns(
        status: RunStatus? = nil, capability: String? = nil, limit: Int? = nil, cursor: String? = nil,
        includeResult: Bool? = nil
    ) async throws -> RunList {
        try await get("/v1/runs", [
            ("status", status?.rawValue), ("capability", capability), ("limit", int(limit)),
            ("cursor", cursor), ("includeResult", bool(includeResult)),
        ], auth: true)
    }

    /// Follows `nextCursor` until the last page. Stop iterating to stop paging.
    ///
    /// ```swift
    /// for try await run in looot.allRuns(status: .failed) { print(run.runId ?? "") }
    /// ```
    public func allRuns(
        status: RunStatus? = nil, capability: String? = nil, limit: Int? = nil, includeResult: Bool? = nil
    ) -> AsyncThrowingStream<Run, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cursor: String?
                    repeat {
                        let page = try await self.listRuns(
                            status: status, capability: capability, limit: limit, cursor: cursor,
                            includeResult: includeResult)
                        for run in page.runs { continuation.yield(run) }
                        cursor = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
                    } while cursor != nil
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the gateway to stop a run and returns it in its current state. A settled run comes
    /// back unchanged. Needs `runs.execute`.
    public func cancelRun(_ runId: String) async throws -> Run {
        try await send(method: "POST", path: "/v1/runs/" + segment(runId) + "/cancel", query: [], body: nil, auth: true)
    }

    /// Lists every provider attempt of a run. Needs `runs.read`.
    public func runAttempts(_ runId: String) async throws -> RunAttempts {
        try await get("/v1/runs/" + segment(runId) + "/attempts", [], auth: true)
    }

    /// Polls `getRun` until the run reaches a terminal status. The first poll comes after
    /// `interval` seconds, doubling up to `maxInterval`.
    ///
    /// - Parameter timeout: Seconds to wait overall. On expiry this throws a ``LoootError``
    ///   with code `timeout`. Nil waits until the task is canceled.
    public func waitForRun(
        _ runId: String, timeout: TimeInterval? = nil, interval: TimeInterval = 1, maxInterval: TimeInterval = 5
    ) async throws -> Run {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var delay = interval
        let path = "/v1/runs/" + segment(runId)
        while true {
            let run = try await getRun(runId)
            if run.isTerminal { return run }
            if let deadline = deadline, Date().addingTimeInterval(delay) > deadline {
                throw LoootError(
                    status: 0, code: "timeout", message: "GET \(path) did not reach a terminal status in time",
                    retryable: true, method: "GET", path: path)
            }
            do {
                try await sleeper(delay)
            } catch {
                throw LoootError.transport(error, method: "GET", path: path)
            }
            delay = min(delay * 2, maxInterval)
        }
    }

    // MARK: - Money and account

    /// Returns the workspace balance and the top-up link. Needs `usage.read`. Free.
    public func balance() async throws -> Balance {
        try await get("/v1/balance", [], auth: true)
    }

    /// Names the workspace and role behind the token. Needs `organizations.read`.
    public func whoami() async throws -> Whoami {
        try await get("/v1/whoami", [], auth: true)
    }

    /// Lists the workspace's top-ups. Needs `usage.read`. To add credit, show the user
    /// `balance().topUpLink?.url`.
    public func listTopUps() async throws -> TopUpList {
        try await get("/v1/top-ups", [], auth: true)
    }

    /// Returns one page of ledger entries. Needs `usage.read`.
    public func ledger(limit: Int? = nil, cursor: String? = nil) async throws -> LedgerPage {
        try await get("/v1/ledger", [("limit", int(limit)), ("cursor", cursor)], auth: true)
    }

    /// Asks looot to add a missing provider or job. `requestId` and `idempotencyKey` are
    /// generated when you pass none.
    public func capabilityRequest(
        title: String, description: String, desiredInputs: [String]? = nil, desiredOutputs: [String]? = nil,
        requestId: String? = nil, idempotencyKey: String? = nil
    ) async throws -> CapabilityRequest {
        var body: [String: JSONValue] = [
            "requestId": .string(requestId ?? makeKey()),
            "title": .string(title),
            "description": .string(description),
            "idempotencyKey": .string(idempotencyKey ?? makeKey()),
        ]
        if let i = desiredInputs { body["desiredInputs"] = .array(i.map { .string($0) }) }
        if let o = desiredOutputs { body["desiredOutputs"] = .array(o.map { .string($0) }) }
        return try await send(method: "POST", path: "/v1/capability-requests", query: [], body: .object(body), auth: true)
    }

    /// Fetches a run's file from `result.media.downloadPath`. The path must start with a single
    /// `/`, so the token never goes to another host.
    public func downloadMedia(_ downloadPath: String) async throws -> Media {
        guard downloadPath.hasPrefix("/"), !downloadPath.hasPrefix("//") else {
            throw LoootError(
                status: 0, code: "invalid_request",
                message: "download path must start with a single \"/\"", method: "GET", path: downloadPath)
        }
        let parts = downloadPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let rawQuery = parts.count > 1 ? String(parts[1]) : nil
        let response = try await execute(method: "GET", path: path, rawQuery: rawQuery, body: nil, auth: true, idempotencyKey: nil)
        return Media(data: response.body, contentType: response.header("content-type"))
    }

    // MARK: - Request pipeline

    private func get<T: JSONBacked>(_ path: String, _ query: [(String, String?)], auth: Bool) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil, auth: auth)
    }

    private func send<T: JSONBacked>(
        method: String, path: String, query: [(String, String?)], body: JSONValue?, auth: Bool,
        idempotencyKey: String? = nil
    ) async throws -> T {
        let response = try await execute(
            method: method, path: path, rawQuery: encodeQuery(query), body: body, auth: auth,
            idempotencyKey: idempotencyKey)
        if response.body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return T(raw: .object([:]))
        }
        do {
            return T(raw: try JSONDecoder().decode(JSONValue.self, from: response.body))
        } catch {
            throw LoootError(
                status: response.status, code: "invalid_response",
                message: "\(method) \(path) returned a body that is not JSON",
                requestId: response.header("x-request-id"),
                body: .string(String(decoding: response.body.prefix(2000), as: UTF8.self)),
                method: method, path: path)
        }
    }

    /// Sends the request with retries and returns the final 2xx response.
    private func execute(
        method: String, path: String, rawQuery: String?, body: JSONValue?, auth: Bool, idempotencyKey: String?
    ) async throws -> HTTPResponse {
        if auth && token == nil { throw LoootError.missingToken(method: method, path: path) }

        var payload: Data?
        if let body = body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payload = try encoder.encode(body)
        }
        var urlString = baseURL + path
        if let q = rawQuery, !q.isEmpty { urlString += "?" + q }
        guard let url = URL(string: urlString) else {
            throw LoootError(status: 0, code: "invalid_request", message: "\(method) \(path) is not a valid URL", method: method, path: path)
        }

        var headers = ["Accept": "application/json", "User-Agent": userAgent]
        if payload != nil { headers["Content-Type"] = "application/json" }
        if auth, let token = token { headers["Authorization"] = "Bearer " + token }
        if let agent = agent { headers["X-Looot-Agent"] = agent }
        if let key = idempotencyKey { headers["Idempotency-Key"] = key }
        let request = HTTPRequest(url: url, method: method, headers: headers, body: payload, timeout: timeout)

        var attempt = 0
        while true {
            do {
                return try await attemptOnce(request, method: method, path: path)
            } catch let error as LoootError {
                if attempt >= maxRetries || !error.shouldAutoRetry { throw error }
                do {
                    try await sleeper(retryDelay(error, attempt: attempt))
                } catch {
                    throw LoootError.transport(error, method: method, path: path)
                }
                attempt += 1
            }
        }
    }

    private func attemptOnce(_ request: HTTPRequest, method: String, path: String) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw LoootError.transport(error, method: method, path: path)
        }
        if (200..<300).contains(response.status) { return response }
        throw LoootError.from(response: response, method: method, path: path)
    }

    /// Waits `Retry-After` when the gateway sends it, else 0.5 s, 1 s, 2 s with jitter. Capped at 30 s.
    private func retryDelay(_ error: LoootError, attempt: Int) -> TimeInterval {
        var d: TimeInterval
        if let after = error.retryAfterSeconds, after > 0 {
            d = after
        } else {
            d = 0.5 * pow(2, Double(attempt)) + Double.random(in: 0..<0.25)
        }
        return min(d, 30)
    }
}

// MARK: - Encoding helpers

private func int(_ v: Int?) -> String? {
    guard let v = v, v > 0 else { return nil }
    return String(v)
}

private func bool(_ v: Bool?) -> String? {
    v.map { $0 ? "true" : "false" }
}

private func number(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
}

/// Percent-encodes everything except unreserved characters, so one segment stays one segment.
func percentEncode(_ s: String) -> String {
    let hex = Array("0123456789ABCDEF".utf8)
    var out = [UInt8]()
    for b in s.utf8 {
        let unreserved =
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
        if unreserved {
            out.append(b)
        } else {
            out.append(0x25)
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0x0F)])
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func segment(_ s: String) -> String { percentEncode(s) }

/// Builds the query string. Nil and empty values are dropped (the contract's "never send
/// `limit=`" rule). Keys are sorted so requests are stable.
private func encodeQuery(_ items: [(String, String?)]) -> String? {
    let pairs = items.compactMap { (k, v) -> (String, String)? in
        guard let v = v, !v.isEmpty else { return nil }
        return (k, v)
    }
    if pairs.isEmpty { return nil }
    return pairs.sorted { $0.0 < $1.0 }.map { percentEncode($0.0) + "=" + percentEncode($0.1) }.joined(separator: "&")
}

extension Looot: CustomReflectable {
    /// Shows no children, so `dump(client)` and the debugger never print the token.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
