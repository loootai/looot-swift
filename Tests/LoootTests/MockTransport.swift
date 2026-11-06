import Foundation
@testable import Looot

/// Records every request and answers from a queue of canned responses. No network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(HTTPResponse)
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [HTTPRequest] = []

    init(_ replies: [Reply] = []) { self.replies = replies }

    convenience init(json: String, status: Int = 200, headers: [String: String] = [:]) {
        self.init([.response(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))])
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var last: HTTPRequest { requests.last! }

    private func next(_ request: HTTPRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return replies.count > 1 ? replies.removeFirst() : (replies.first ?? .response(HTTPResponse(status: 200, body: Data("{}".utf8))))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch next(request) {
        case .response(let r): return r
        case .failure(let e): throw e
        }
    }
}

func reply(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> MockTransport.Reply {
    .response(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))
}

let fakeToken = "test-token-value-123"

/// A client with a recorded sleeper and a counting key maker.
final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

func makeClient(
    _ transport: MockTransport,
    token: String? = fakeToken,
    baseURL: String = "https://api.looot.ai",
    agent: String? = nil,
    maxRetries: Int = 2,
    environment: [String: String] = [:],
    sleeps: Sleeps = Sleeps()
) -> Looot {
    Looot(
        token: token, baseURL: baseURL, agent: agent, timeout: 75, maxRetries: maxRetries,
        transport: transport, environment: environment,
        sleeper: { sleeps.add($0) },
        makeKey: { "sdk-" + UUID().uuidString.lowercased() })
}

func query(_ request: HTTPRequest) -> [String: String] {
    var out: [String: String] = [:]
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    for i in items { out[i.name] = i.value ?? "" }
    return out
}

func path(_ request: HTTPRequest) -> String {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
}

func bodyJSON(_ request: HTTPRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data("null".utf8))
}
