# looot for Swift

[![CI](https://github.com/loootai/looot-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/loootai/looot-swift/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/loootai/looot-swift)](LICENSE) [![Docs](https://img.shields.io/badge/docs-docs.looot.ai-12A06A)](https://docs.looot.ai)

The Swift client for the [looot](https://looot.ai) API. looot is one gateway to 300+ data
providers (email find and verify, company enrichment, SERP data, social profiles, web
scraping) with one token and one prepaid balance.

Foundation only, no dependencies. Every call is `async` and throws. Swift 5.9 or newer on macOS 12,
iOS 15 and Linux.

## Install

Add the package in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/loootai/looot-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Looot", package: "looot-swift")]),
]
```

In Xcode, use File, Add Package Dependencies and paste the same URL.

Create an API key at [looot.ai](https://looot.ai) (Settings, API keys) and export it:

```bash
export LOOOT_TOKEN=...
```

## Quickstart

Search the catalog, inspect the pick, then run the job. Search and inspect are free. The run
is paid, and `fallback: .on` lets looot try the next provider on a miss.

```swift
import Looot

let looot = Looot() // reads LOOOT_TOKEN

let found = try await looot.search("find a work email", capability: "people.email.find", limit: 3)
for row in found.endpoints {
    print(row.endpointId ?? "", row.estimatedPrice ?? 0, row.access ?? "")
}

let op = try await looot.inspect(found.endpoints[0].endpointId!)
print(op.inputSchema) // what the endpoint wants

let balance = try await looot.balance()
if (balance.available ?? 0) < 0.05 {
    print("Add credit:", balance.topUpLink?.url ?? "")
    return
}

let run = try await looot.runJob(
    "people.email.find",
    input: ["first_name": "Jane", "last_name": "Doe", "domain": "example.com"],
    fallback: .on,
    wait: 30
)
print(run.status.rawValue, run.outcome?.rawValue ?? "", run.result)
```

Browsing the catalog needs no token: `catalogOverview(topic: "email")` and `publicCatalog()`
send no `Authorization` header.

## Read the run, not the HTTP status

A run that failed is not a thrown error. `run` and `runJob` return it with `status` `failed`
and `error` set, even when the gateway answered HTTP 201. A `completed` run can still be a
`miss`.

```swift
if let error = run.error {
    print(error.code ?? "", error.retryHint ?? "") // show retryHint to the user as is
}
```

## Errors

Every non-2xx answer is a `LoootError`. So are a missing token, a network failure and a
timeout (`status` 0).

```swift
do {
    _ = try await looot.runJob("people.email.find", input: ["domain": "example.com"])
} catch let error as LoootError {
    switch error.code {
    case "insufficient_balance":
        print("Add credit:", error.topUp?.url ?? "") // then run again with a new key
    default:
        if error.retryable {
            print("Try later, same key:", error.retryAfterSeconds ?? 0)
        } else {
            print(error.status, error.code, error.message, error.requestId ?? "")
        }
    }
}
```

Fields: `status`, `code`, `message`, `requestId`, `retryable`, `retryHint`, `retryAfterSeconds`,
`topUp` and the decoded `body`. The token never appears in an error or in a description.

## Idempotency and retries

Every `run` and `runJob` sends an idempotency key. Pass your own, built from your record
(`lead-4821-email`), so a crashed worker replays the first run instead of paying twice. With
no key the SDK sends `sdk-<uuid v4>`.

The client retries 429, the retryable 503 codes, network errors and timeouts up to 2 times
with the same key. It waits `Retry-After` when the gateway sends it (capped at 30 s), else a
short backoff. It never retries other 4xx answers. `maxRetries: 0` turns retries off.

After a failed run, or a 402, run again with a new key. The same key only replays the first
answer.

## Options

```swift
let looot = Looot(
    token: "...",                          // default: LOOOT_TOKEN
    baseURL: "http://localhost:8787",      // default: https://api.looot.ai
    agent: "my-app",                       // sent as X-Looot-Agent, analytics only
    timeout: 90,                           // seconds per request, default 75
    maxRetries: 0,                         // default 2
    transport: MyTransport()               // any HTTPTransport, for tests or proxies
)
```

`token: ""` means no token, even when `LOOOT_TOKEN` is set. Free routes never send the token.

## Responses keep every key

Response types are `Codable` and typed for the fields the API documents. Each one also holds
the full JSON as a `JSONValue`, so a field the gateway adds later is still readable:

```swift
print(run.runId ?? "", run.route?.servedBy ?? "")
print(run["someNewField"]["nested"].stringValue ?? "") // not typed yet, still there
print(run.raw)                                        // the whole body
```

Statuses, outcomes and `Prefer` are open string types (`run.status == .completed`), so a new
value from the gateway never crashes a client.

## Methods

| Method | Route | Token scope | Cost |
| --- | --- | --- | --- |
| `catalogOverview(...)` | `GET /v1/catalog/overview` | none | free |
| `publicCatalog(...)` | `GET /v1/public-catalog` | none | free |
| `publicCatalogItem(_:)` | `GET /v1/public-catalog/{id}` | none | free |
| `comparePublicCatalog(_:)` | `POST /v1/public-catalog/compare` | none | free |
| `search(...)` | `GET /v1/catalog/search` | `catalog.read` | free |
| `discover(...)` | `GET /v1/discover` | `catalog.read` | free |
| `catalogEndpoints(...)` | `GET /v1/catalog/endpoints` | `catalog.read` | free |
| `inspect(_:)` | `GET /v1/operations/{id}` | `catalog.read` | free |
| `run(endpointId:...)` | `POST /v1/runs` | `runs.execute` | paid |
| `runJob(_:...)` | `POST /v1/runs` with `job:<id>` | `runs.execute` | paid |
| `getRun(_:...)` | `GET /v1/runs/{id}` | `runs.read` | free |
| `listRuns(...)` | `GET /v1/runs` | `runs.read` | free |
| `allRuns(...)` | `GET /v1/runs`, every page | `runs.read` | free |
| `waitForRun(_:...)` | `GET /v1/runs/{id}` until terminal | `runs.read` | free |
| `cancelRun(_:)` | `POST /v1/runs/{id}/cancel` | `runs.execute` | free |
| `runAttempts(_:)` | `GET /v1/runs/{id}/attempts` | `runs.read` | free |
| `balance()` | `GET /v1/balance` | `usage.read` | free |
| `whoami()` | `GET /v1/whoami` | `organizations.read` | free |
| `listTopUps()` | `GET /v1/top-ups` | `usage.read` | free |
| `ledger(...)` | `GET /v1/ledger` | `usage.read` | free |
| `capabilityRequest(...)` | `POST /v1/capability-requests` | any | free |
| `downloadMedia(_:)` | `GET <result.media.downloadPath>` | any | free |

Unset arguments are not sent. `runJob` puts `prefer` into `fallback.prefer`, which turns
fallback on. With neither `prefer` nor `fallback`, a job run does not fall back. Take job ids
from `catalogOverview` or a search row's `capability`, never guess one.

To top up, show the user `balance().topUpLink?.url`. An agent token cannot open a payment.

## Tests with a mock transport

Implement `HTTPTransport` and pass it in. Nothing in the SDK's own tests touches the network.

```swift
struct Canned: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"available": 12.5}"#.utf8))
    }
}
let looot = Looot(token: "test", transport: Canned())
```

## Develop

```bash
swift build
swift test
bash scripts/leak-scan.sh .
git config core.hooksPath .githooks   # runs the leak scan before each commit
```

`swift test` needs XCTest, which ships with Xcode and with the Linux toolchain.

## Links

- Docs: https://docs.looot.ai
- API reference: https://docs.looot.ai/reference
- Run errors: https://docs.looot.ai/errors/run-errors
- Agent guide: https://looot.ai/skill.md
- Other SDKs: [looot-js](https://github.com/loootai/looot-js), [looot-python](https://github.com/loootai/looot-python), [looot-go](https://github.com/loootai/looot-go)

## License

MIT. See [LICENSE](LICENSE).
