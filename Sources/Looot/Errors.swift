import Foundation

/// The one error this SDK throws: every non-2xx answer, a missing token, a network failure and
/// a timeout (`status` 0).
///
/// A run that failed is not a `LoootError`. `run` and `runJob` return the run, and you read
/// `status`, `outcome` and `error` on it.
public struct LoootError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The HTTP status, or 0 for a network failure, a timeout or a canceled call.
    public var status: Int
    /// `error.code` from the body, else `http_<status>`. Local codes: `missing_token`,
    /// `network_error`, `timeout`, `canceled`, `invalid_response`.
    public var code: String
    /// `error.message`, else `<METHOD> <path> failed with HTTP <status>`.
    public var message: String
    /// `error.requestId`, else the `x-request-id` header.
    public var requestId: String?
    /// True when the same request may succeed later, with the same idempotency key.
    public var retryable: Bool
    /// The gateway's one-sentence advice, when it sends one.
    public var retryHint: String?
    /// The body's `retryAfterSeconds`, else the `Retry-After` header in seconds.
    public var retryAfterSeconds: Double?
    /// Set on a 402 `insufficient_balance`: where the user can add credit.
    public var topUp: TopUpLink?
    /// The decoded body, or the raw text when it is not JSON.
    public var body: JSONValue?
    /// The HTTP method of the failed request.
    public var method: String?
    /// The path of the failed request.
    public var path: String?

    public init(
        status: Int,
        code: String,
        message: String,
        requestId: String? = nil,
        retryable: Bool = false,
        retryHint: String? = nil,
        retryAfterSeconds: Double? = nil,
        topUp: TopUpLink? = nil,
        body: JSONValue? = nil,
        method: String? = nil,
        path: String? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.requestId = requestId
        self.retryable = retryable
        self.retryHint = retryHint
        self.retryAfterSeconds = retryAfterSeconds
        self.topUp = topUp
        self.body = body
        self.method = method
        self.path = path
    }

    public var description: String {
        var s = "LoootError: \(message) (\(code)"
        if status != 0 { s += ", HTTP \(status)" }
        if let id = requestId, !id.isEmpty { s += ", request \(id)" }
        return s + ")"
    }

    public var errorDescription: String? { description }

    /// Only 429, retryable 503s and transport failures are retried automatically.
    var shouldAutoRetry: Bool {
        guard retryable else { return false }
        switch status {
        case 429, 503: return true
        case 0: return code == "network_error" || code == "timeout"
        default: return false
        }
    }

    /// The contract's table, used when the body does not say.
    static func retryableByStatus(_ status: Int, code: String) -> Bool {
        switch status {
        case 429, 500: return true
        case 503: return code != "billing_unavailable"
        default: return false
        }
    }

    static func missingToken(method: String, path: String) -> LoootError {
        LoootError(
            status: 401,
            code: "missing_token",
            message: "\(method) \(path) needs a token: set LOOOT_TOKEN or pass token",
            method: method,
            path: path
        )
    }

    static func from(response: HTTPResponse, method: String, path: String) -> LoootError {
        var e = LoootError(
            status: response.status,
            code: "http_\(response.status)",
            message: "\(method) \(path) failed with HTTP \(response.status)",
            requestId: response.header("x-request-id"),
            method: method,
            path: path
        )
        var retryableSet = false
        if !response.body.isEmpty,
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: response.body),
            case .object = parsed
        {
            e.body = parsed
            let env = parsed["error"]
            if let s = env["code"].stringValue, !s.isEmpty { e.code = s }
            if let s = env["message"].stringValue, !s.isEmpty { e.message = s }
            if let s = env["requestId"].stringValue, !s.isEmpty { e.requestId = s }
            if let b = env["retryable"].boolValue {
                e.retryable = b
                retryableSet = true
            }
            if let s = env["retryHint"].stringValue { e.retryHint = s }
            if let n = env["retryAfterSeconds"].doubleValue, n > 0 { e.retryAfterSeconds = n }
            if let n = parsed["retryAfterSeconds"].doubleValue, n > 0 { e.retryAfterSeconds = n }
            if e.retryHint == nil, let s = parsed["retryHint"].stringValue { e.retryHint = s }
            if case .object = parsed["topUp"] { e.topUp = TopUpLink(raw: parsed["topUp"]) }
        } else if !response.body.isEmpty {
            e.body = .string(String(decoding: response.body, as: UTF8.self))
        }
        if e.retryAfterSeconds == nil, let h = response.header("retry-after"),
            let n = Double(h.trimmingCharacters(in: .whitespaces)), n > 0
        {
            e.retryAfterSeconds = n
        }
        if !retryableSet { e.retryable = retryableByStatus(e.status, code: e.code) }
        return e
    }

    static func transport(_ error: Error, method: String, path: String) -> LoootError {
        if let e = error as? LoootError { return e }
        if error is CancellationError {
            return LoootError(status: 0, code: "canceled", message: "\(method) \(path) was canceled", method: method, path: path)
        }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled:
                return LoootError(status: 0, code: "canceled", message: "\(method) \(path) was canceled", method: method, path: path)
            case .timedOut:
                return LoootError(status: 0, code: "timeout", message: "\(method) \(path) timed out", retryable: true, method: method, path: path)
            default:
                break
            }
        }
        return LoootError(
            status: 0,
            code: "network_error",
            message: "\(method) \(path) could not reach looot: \(error.localizedDescription)",
            retryable: true,
            method: method,
            path: path
        )
    }
}
