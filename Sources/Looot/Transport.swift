import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request, as the client hands it to a transport.
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Seconds the transport should wait for the answer.
    public var timeout: TimeInterval

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 75) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// One HTTP answer. Header names are stored lowercased.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
    }

    /// The header value for `name`, matched without regard to case.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Sends HTTP requests. The client uses `URLSessionTransport`; tests pass a mock.
///
/// A transport returns the response for any status code and throws only when no response
/// arrived (DNS, TLS, timeout).
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The default transport, built on `URLSession`.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.timeoutInterval = request.timeout
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error = error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (k, v) in http.allHeaderFields {
                        if let k = k as? String, let v = v as? String { headers[k] = v }
                    }
                    cont.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
                }
                #if canImport(Darwin)
                task.delegate = RedirectGuard()
                #endif
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var canceled = false

    func set(_ t: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        task = t
        if canceled { t.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        canceled = true
        task?.cancel()
    }
}

#if canImport(Darwin)
/// Drops the `Authorization` header when a redirect leaves the original host, so the
/// token never reaches a third-party server (for example a storage bucket).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.guarded(request, from: task.originalRequest?.url))
    }

    static func guarded(_ request: URLRequest, from original: URL?) -> URLRequest {
        var next = request
        let sameOrigin = original?.host?.lowercased() == request.url?.host?.lowercased()
            && original?.scheme?.lowercased() == request.url?.scheme?.lowercased()
        if !sameOrigin { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        return next
    }
}
#endif
