import Foundation

// Response types hold the whole JSON body in `raw` and expose typed accessors for the fields
// the contract lists. A field the gateway adds later is still reachable through `raw` or the
// subscript, for example `run["someNewField"]`.

/// A response (or part of one) backed by its JSON. Decoding keeps every key.
public protocol JSONBacked: Codable, Hashable, Sendable {
    /// The JSON exactly as received.
    var raw: JSONValue { get }
    init(raw: JSONValue)
}

extension JSONBacked {
    public init(from decoder: Decoder) throws {
        self.init(raw: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    /// Any field by name, `.null` when absent.
    public subscript(key: String) -> JSONValue { raw[key] }
}

private extension JSONValue {
    func list<T: JSONBacked>(_ key: String, as _: T.Type) -> [T] {
        (self[key].arrayValue ?? []).map { T(raw: $0) }
    }

    func one<T: JSONBacked>(_ key: String, as _: T.Type) -> T? {
        if case .null = self[key] { return nil }
        return T(raw: self[key])
    }

    func strings(_ key: String) -> [String] {
        (self[key].arrayValue ?? []).compactMap { $0.stringValue }
    }
}

// MARK: - Open string enums

/// Ranks providers. Unknown values pass through as is.
public struct Prefer: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static let cheapest: Prefer = "cheapest"
    public static let reliable: Prefer = "reliable"
    public static let fastest: Prefer = "fastest"
    public static let balanced: Prefer = "balanced"
}

/// A run's lifecycle state. New values may appear, so this is not a closed enum.
public struct RunStatus: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static let queued: RunStatus = "queued"
    public static let running: RunStatus = "running"
    public static let pendingProvider: RunStatus = "pending_provider"
    public static let completed: RunStatus = "completed"
    public static let failed: RunStatus = "failed"
    public static let blocked: RunStatus = "blocked"
    public static let stopped: RunStatus = "stopped"
    public static let reconciliationPending: RunStatus = "reconciliation_pending"

    /// True when polling can stop. An unknown status counts as not terminal.
    public var isTerminal: Bool {
        [.completed, .failed, .blocked, .stopped, .reconciliationPending].contains(self)
    }
}

/// Whether a run's answer was any good. A `completed` run can still be a `miss`.
public struct RunOutcome: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static let hit: RunOutcome = "hit"
    public static let weak: RunOutcome = "weak"
    public static let miss: RunOutcome = "miss"
    public static let error: RunOutcome = "error"
    public static let rejected: RunOutcome = "rejected"
    public static let skipped: RunOutcome = "skipped"
    public static let pending: RunOutcome = "pending"
    public static let failed: RunOutcome = "failed"
    public static let capped: RunOutcome = "capped"
}

// MARK: - Fallback

/// Controls fallback across providers. `FallbackOptions()` with nothing set is sent as
/// `true`, which turns fallback on with the gateway defaults (3 attempts, prefer balanced).
public struct FallbackOptions: Hashable, Sendable {
    public var enabled: Bool?
    /// Providers tried, 1 to 10.
    public var maxAttempts: Int?
    /// Cap for the whole route in USD, above 0 and at most 100.
    public var maxCostUsd: Double?
    public var prefer: Prefer?
    /// Up to 50 endpoint or provider ids.
    public var exclude: [String]?
    public var stopAtFirstMiss: Bool?

    public init(
        enabled: Bool? = nil,
        maxAttempts: Int? = nil,
        maxCostUsd: Double? = nil,
        prefer: Prefer? = nil,
        exclude: [String]? = nil,
        stopAtFirstMiss: Bool? = nil
    ) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
        self.maxCostUsd = maxCostUsd
        self.prefer = prefer
        self.exclude = exclude
        self.stopAtFirstMiss = stopAtFirstMiss
    }

    /// Fallback on with the gateway defaults. Same as `fallback: true`.
    public static let on = FallbackOptions()

    var jsonValue: JSONValue {
        var o: [String: JSONValue] = [:]
        if let enabled = enabled { o["enabled"] = .bool(enabled) }
        if let maxAttempts = maxAttempts { o["maxAttempts"] = .number(Double(maxAttempts)) }
        if let maxCostUsd = maxCostUsd { o["maxCostUsd"] = .number(maxCostUsd) }
        if let prefer = prefer { o["prefer"] = .string(prefer.rawValue) }
        if let exclude = exclude { o["exclude"] = .array(exclude.map { .string($0) }) }
        if let stopAtFirstMiss = stopAtFirstMiss { o["stopAtFirstMiss"] = .bool(stopAtFirstMiss) }
        return o.isEmpty ? .bool(true) : .object(o)
    }
}

// MARK: - Catalog overview

/// The free catalog map: categories by default, matching jobs with `topic`.
public struct CatalogOverview: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var revision: String? { raw["revision"].stringValue ?? raw["revision"].int64Value.map(String.init) }
    public var builtAt: String? { raw["builtAt"].stringValue }
    public var depth: String? { raw["depth"].stringValue }
    public var totals: CatalogTotals? { raw.one("totals", as: CatalogTotals.self) }
    public var categories: [JSONValue] { raw["categories"].arrayValue ?? [] }
    public var topic: String? { raw["topic"].stringValue }
    public var matchCount: Int? { raw["matchCount"].intValue }
    public var truncated: Bool? { raw["truncated"].boolValue }
    public var jobs: [OverviewJob] { raw.list("jobs", as: OverviewJob.self) }
}

/// Counts for the whole catalog.
public struct CatalogTotals: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var categories: Int? { raw["categories"].intValue }
    public var platforms: Int? { raw["platforms"].intValue }
    public var jobs: Int? { raw["jobs"].intValue }
    public var providers: Int? { raw["providers"].intValue }
    public var endpoints: Int? { raw["endpoints"].intValue }
    public var runnableEndpoints: Int? { raw["runnableEndpoints"].intValue }
}

/// One job. Prices are USD. Per call and per result are never compared with each other.
public struct OverviewJob: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String? { raw["id"].stringValue }
    public var title: String? { raw["title"].stringValue }
    public var category: String? { raw["category"].stringValue }
    public var platform: String? { raw["platform"].stringValue }
    public var providerCount: Int? { raw["providerCount"].intValue }
    public var endpointCount: Int? { raw["endpointCount"].intValue }
    public var runnableCount: Int? { raw["runnableCount"].intValue }
    public var cheapestPerCall: Double? { raw["cheapestPerCall"].doubleValue }
    public var cheapestPerResult: Double? { raw["cheapestPerResult"].doubleValue }
}

// MARK: - Public catalog

/// One page of the public catalog.
public struct PublicCatalogPage: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var items: [PublicCatalogItem] { raw.list("items", as: PublicCatalogItem.self) }
    public var catalogDigest: String? { raw["catalogDigest"].stringValue }
    /// Pass it as `cursor` for the next page. Nil on the last page.
    public var nextCursor: String? { raw["nextCursor"].stringValue }
    public var warnings: [JSONValue] { raw["warnings"].arrayValue ?? [] }
}

/// One published catalog item.
public struct PublicCatalogItem: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var catalogItemId: String? { raw["catalogItemId"].stringValue }
    public var providerId: String? { raw["providerId"].stringValue }
    public var operationId: String? { raw["operationId"].stringValue }
    public var title: String? { raw["title"].stringValue }
    public var description: String? { raw["description"].stringValue }
    public var categories: [String] { raw.strings("categories") }
    public var capabilities: [String] { raw.strings("capabilities") }
    public var parameters: [CatalogParameter] { raw.list("parameters", as: CatalogParameter.self) }
    public var price: CatalogPrice? { raw.one("price", as: CatalogPrice.self) }
    public var provenanceTier: String? { raw["provenanceTier"].stringValue }
    public var publishedAt: String? { raw["publishedAt"].stringValue }
    public var itemDigest: String? { raw["itemDigest"].stringValue }
}

/// One input of a public catalog item.
public struct CatalogParameter: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var name: String? { raw["name"].stringValue }
    public var location: String? { raw["location"].stringValue }
    public var isRequired: Bool { raw["required"].boolValue ?? false }
    public var description: String? { raw["description"].stringValue }
}

/// A price that is either known (`state` is `known`, with `amountMicros`) or not (`reason` says why).
public struct CatalogPrice: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var state: String? { raw["state"].stringValue }
    public var amountMicros: Int64? { raw["amountMicros"].int64Value }
    public var currency: String? { raw["currency"].stringValue }
    public var unit: String? { raw["unit"].stringValue }
    public var effectiveAt: String? { raw["effectiveAt"].stringValue }
    public var reason: String? { raw["reason"].stringValue }
}

/// The answer of `POST /v1/public-catalog/compare`.
public struct CatalogComparison: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var items: [PublicCatalogItem] { raw.list("items", as: PublicCatalogItem.self) }
    public var priceComparison: JSONValue { raw["priceComparison"] }
}

// MARK: - Search, discover, endpoint listing

/// One page of search rows.
public struct SearchResult: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var query: String? { raw["query"].stringValue }
    public var total: Int? { raw["total"].intValue }
    public var endpoints: [CatalogEndpoint] { raw.list("endpoints", as: CatalogEndpoint.self) }
    /// Pass it as `offset` for the next page. Nil on the last page.
    public var nextOffset: Int? { raw["nextOffset"].intValue }
    public var prefer: String? { raw["prefer"].stringValue }
    public var warnings: [JSONValue] { raw["warnings"].arrayValue ?? [] }
    public var priceHint: JSONValue { raw["priceHint"] }
}

/// One row from search, discover or the endpoint listing.
public struct CatalogEndpoint: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var endpointId: String? { raw["endpointId"].stringValue }
    public var provider: String? { raw["provider"].stringValue }
    public var name: String? { raw["name"].stringValue }
    /// The job id this endpoint serves, for example `people.email.verify`.
    public var capability: String? { raw["capability"].stringValue }
    public var sourceCapability: String? { raw["sourceCapability"].stringValue }
    public var category: String? { raw["category"].stringValue }
    /// `runs_now`, `needs_your_account` or `coming_soon`.
    public var access: String? { raw["access"].stringValue }
    /// USD.
    public var estimatedPrice: Double? { raw["estimatedPrice"].doubleValue }
    /// `perCall` or `perResult`.
    public var priceBasis: String? { raw["priceBasis"].stringValue }
    public var costPerSuccessUsd: Double? { raw["costPerSuccessUsd"].doubleValue }
    public var works: Works? { raw.one("works", as: Works.self) }
    public var isAsync: Bool { raw["async"].boolValue ?? false }
    public var credential: JSONValue { raw["credential"] }
    public var job: JobRef? { raw.one("job", as: JobRef.self) }
}

/// The measured track record of an endpoint.
public struct Works: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var rate: Double? { raw["rate"].doubleValue }
    public var runs: Int? { raw["runs"].intValue }
    public var p50Ms: Int? { raw["p50Ms"].intValue }
    public var thin: Bool { raw["thin"].boolValue ?? false }
}

/// A job's id and title.
public struct JobRef: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String? { raw["id"].stringValue }
    public var title: String? { raw["title"].stringValue }
}

/// Up to 5 ranked candidates for a task.
public struct DiscoverResult: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var candidates: [CatalogEndpoint] { raw.list("candidates", as: CatalogEndpoint.self) }
    public var meta: JSONValue { raw["meta"] }
}

/// One page of the cursor-paged endpoint listing.
public struct CatalogEndpointsPage: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var endpoints: [CatalogEndpoint] { raw.list("endpoints", as: CatalogEndpoint.self) }
    public var nextCursor: String? { raw["nextCursor"].stringValue }
    public var facets: JSONValue { raw["facets"] }
}

// MARK: - Inspect

/// `GET /v1/operations/{endpointId}`: inputs, price and hints for one endpoint.
public struct Operation: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var endpoint: OperationEndpoint? { raw.one("endpoint", as: OperationEndpoint.self) }
    public var estimatedMaxCost: JSONValue { raw["estimatedMaxCost"] }
    public var priceRange: JSONValue { raw["priceRange"] }
    /// JSON Schema for `input`.
    public var inputSchema: JSONValue { raw["inputSchema"] }
    public var requestBinding: JSONValue { raw["requestBinding"] }
    public var uiSchema: JSONValue { raw["uiSchema"] }
    public var outputFormat: JSONValue { raw["outputFormat"] }
    public var usageHints: JSONValue { raw["usageHints"] }
}

/// The endpoint part of an `Operation`.
public struct OperationEndpoint: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String? { raw["id"].stringValue }
    public var capability: String? { raw["capability"].stringValue }
    /// `effectful` marks a write action.
    public var effectClassification: String? { raw["effectClassification"].stringValue }
    public var price: JSONValue { raw["price"] }
    public var isEffectful: Bool { effectClassification == "effectful" }
}

// MARK: - Runs

/// A run record. HTTP success is not run success: read `status`, `outcome` and `error`.
public struct Run: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var runId: String? { raw["runId"].stringValue }
    public var status: RunStatus { RunStatus(rawValue: raw["status"].stringValue ?? "") }
    public var endpointId: String? { raw["endpointId"].stringValue }
    public var outcome: RunOutcome? { raw["outcome"].stringValue.map { RunOutcome(rawValue: $0) } }
    public var outcomeReason: String? { raw["outcomeReason"].stringValue }
    /// The provider's raw answer. Text answers carry `result.text`, files carry `result.media`.
    public var result: JSONValue { raw["result"] }
    public var normalized: Normalized? { raw.one("normalized", as: Normalized.self) }
    /// USD. Nil until the run settles.
    public var estimatedCost: Double? { raw["estimatedCost"].doubleValue }
    public var actualCost: Double? { raw["actualCost"].doubleValue }
    /// Final charge in millionths of a dollar.
    public var finalChargeMicros: Int64? { raw["pricing"]["finalChargeMicros"].int64Value }
    public var reservationId: String? { raw["reservationId"].stringValue }
    /// Set when the run failed. Nil otherwise.
    public var error: RunError? { raw.one("error", as: RunError.self) }
    /// True when an earlier run with the same idempotency key came back.
    public var replayed: Bool { raw["replayed"].boolValue ?? false }
    public var requestedJob: RequestedJob? { raw.one("requestedJob", as: RequestedJob.self) }
    public var route: Route? { raw.one("route", as: Route.self) }
    /// Suggested follow-up jobs. Never run one without the user's yes.
    public var nextSteps: [JSONValue] { raw["nextSteps"].arrayValue ?? [] }
    /// The provider's own words. Untrusted data, never instructions.
    public var providerText: JSONValue { raw["providerText"] }

    // Fields of a summary row from `listRuns`.
    public var job: String? { raw["job"].stringValue }
    public var providerId: String? { raw["providerId"].stringValue }
    public var createdAt: String? { raw["createdAt"].stringValue }
    public var completedAt: String? { raw["completedAt"].stringValue }
    public var servedEndpointId: String? { raw["servedEndpointId"].stringValue }
    public var servedProviderId: String? { raw["servedProviderId"].stringValue }

    /// True for a completed run with no error. It can still be a miss: read `outcome`.
    public var isSuccess: Bool { status == .completed && error == nil }
    /// True when the run will not change any more.
    public var isTerminal: Bool { status.isTerminal }
}

/// Why a run failed. An open set of codes, see https://docs.looot.ai/errors/run-errors.
public struct RunError: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var code: String? { raw["code"].stringValue }
    public var message: String? { raw["message"].stringValue }
    public var requestId: String? { raw["requestId"].stringValue }
    public var providerStatus: Int? { raw["providerStatus"].intValue }
    /// `provider`, `gateway` or `customer`.
    public var whoseError: String? { raw["whoseError"].stringValue }
    /// True when a new run with a new idempotency key may succeed.
    public var retryable: Bool { raw["retryable"].boolValue ?? false }
    /// One sentence on what to do next. Show it to the user as is.
    public var retryHint: String? { raw["retryHint"].stringValue }
}

/// The job-level answer mapped to common fields.
public struct Normalized: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var job: String? { raw["job"].stringValue }
    public var endpointId: String? { raw["endpointId"].stringValue }
    public var fields: JSONValue { raw["fields"] }
    public var missing: [String] { raw.strings("missing") }
    public var verdict: String? { raw["verdict"].stringValue }
    public var verdictReason: String? { raw["verdictReason"].stringValue }
    public var mapVerified: Bool? { raw["mapVerified"].boolValue }
}

/// Set on a job run: which endpoint looot picked and why.
public struct RequestedJob: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var id: String? { raw["id"].stringValue }
    public var job: String? { raw["job"].stringValue }
    public var prefer: String? { raw["prefer"].stringValue }
    public var pickedEndpointId: String? { raw["pickedEndpointId"].stringValue }
    public var reason: String? { raw["reason"].stringValue }
    public var skipped: [JSONValue] { raw["skipped"].arrayValue ?? [] }
}

/// Set on a fallback run: every provider tried and what each cost.
public struct Route: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var servedBy: String? { raw["servedBy"].stringValue }
    public var outcome: RunOutcome? { raw["outcome"].stringValue.map { RunOutcome(rawValue: $0) } }
    public var chargedUsd: Double? { raw["chargedUsd"].doubleValue }
    public var capped: Bool { raw["capped"].boolValue ?? false }
    public var attempts: [RouteAttempt] { raw.list("attempts", as: RouteAttempt.self) }
    public var skipped: [RouteSkip] { raw.list("skipped", as: RouteSkip.self) }
    public var summary: String? { raw["summary"].stringValue }
}

/// One provider tried by a fallback route.
public struct RouteAttempt: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var n: Int? { raw["n"].intValue }
    public var endpointId: String? { raw["endpointId"].stringValue }
    public var provider: String? { raw["provider"].stringValue }
    public var outcome: RunOutcome? { raw["outcome"].stringValue.map { RunOutcome(rawValue: $0) } }
    public var status: String? { raw["status"].stringValue }
    public var chargedUsd: Double? { raw["chargedUsd"].doubleValue }
    public var billed: Bool? { raw["billed"].boolValue }
    public var ms: Int? { raw["ms"].intValue }
    public var reason: String? { raw["reason"].stringValue }
    public var verdict: String? { raw["verdict"].stringValue }
}

/// One candidate a fallback route did not try.
public struct RouteSkip: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var endpointId: String? { raw["endpointId"].stringValue }
    public var providerId: String? { raw["providerId"].stringValue }
    public var code: String? { raw["code"].stringValue }
    public var reason: String? { raw["reason"].stringValue }
}

/// One page of runs, newest first.
public struct RunList: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var runs: [Run] { raw.list("runs", as: Run.self) }
    public var nextCursor: String? { raw["nextCursor"].stringValue }
}

/// Every durable provider attempt of a run.
public struct RunAttempts: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var attempts: [Attempt] { raw.list("attempts", as: Attempt.self) }
}

/// One provider call.
public struct Attempt: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var providerId: String? { raw["providerId"].stringValue }
    public var status: String? { raw["status"].stringValue }
    public var costMicros: Int64? { raw["costMicros"].int64Value }
}

// MARK: - Money and account

/// The workspace balance. Reading it never opens a payment session.
public struct Balance: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var workspaceId: String? { raw["workspaceId"].stringValue }
    public var currency: String? { raw["currency"].stringValue }
    /// USD.
    public var available: Double? { raw["available"].doubleValue }
    /// USD held for runs in flight.
    public var reserved: Double? { raw["reserved"].doubleValue }
    public var trialCreditMicros: Int64? { raw["trialCreditMicros"].int64Value }
    public var recentSpendMicros: Int64? { raw["recentSpendMicros"].int64Value }
    public var topUpLink: TopUpLink? { raw.one("topUpLink", as: TopUpLink.self) }
}

/// Where the user adds credit.
public struct TopUpLink: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    /// A purchase minimum, not a wallet floor.
    public var minimumUsd: Double? { raw["minimumUsd"].doubleValue }
    public var suggestedUsd: Double? { raw["suggestedUsd"].doubleValue }
    public var checkoutUrl: String? { raw["checkoutUrl"].stringValue }
    public var dashboardUrl: String? { raw["dashboardUrl"].stringValue }
    public var message: String? { raw["message"].stringValue }
    public var reason: String? { raw["reason"].stringValue }
    /// The checkout URL when one is open, else the dashboard URL.
    public var url: String? {
        if let c = checkoutUrl, !c.isEmpty { return c }
        return dashboardUrl
    }
}

/// `GET /v1/top-ups`.
public struct TopUpList: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var topUps: [JSONValue] { raw["topUps"].arrayValue ?? [] }
}

/// One page of ledger entries, newest first.
public struct LedgerPage: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var entries: [JSONValue] { raw["entries"].arrayValue ?? [] }
    public var nextCursor: String? { raw["nextCursor"].stringValue }
}

/// The workspace and role behind the token.
public struct Whoami: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var workspaceId: String? { raw["workspaceId"].stringValue }
    public var membershipId: String? { raw["membershipId"].stringValue }
    public var role: String? { raw["role"].stringValue }
}

/// A stored request for a missing provider or job.
public struct CapabilityRequest: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var requestId: String? { raw["requestId"].stringValue }
    public var status: String? { raw["status"].stringValue }
}

/// A file downloaded from a run.
public struct Media: Sendable {
    public var data: Data
    public var contentType: String?
}
