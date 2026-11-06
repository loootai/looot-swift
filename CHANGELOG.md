# Changelog

## 0.1.0 (2026-11-06)

First release.

- One `Looot` client for the looot REST API. Foundation only, `async` on every call.
- Core methods: `catalogOverview`, `publicCatalog`, `publicCatalogItem`, `search`, `inspect`,
  `run`, `runJob`, `getRun`, `listRuns`, `cancelRun`, `runAttempts`, `balance`.
- Extended methods: `discover`, `catalogEndpoints`, `comparePublicCatalog`, `whoami`,
  `listTopUps`, `ledger`, `capabilityRequest`, `downloadMedia`.
- Helpers: `waitForRun` (polls 1 s to 5 s) and `allRuns` (an `AsyncThrowingStream` over every page).
- `Codable` response types that keep unknown keys through a `JSONValue` enum.
- `LoootError` for every non-2xx answer, missing token, network error and timeout, with `code`,
  `retryable`, `retryHint`, `retryAfterSeconds` and the 402 `topUp` link.
- Retries 429, retryable 503s, network errors and timeouts twice by default with the same
  idempotency key. `maxRetries: 0` turns them off.
- Injectable `HTTPTransport` so tests mock HTTP. The default uses `URLSession`.
- Sends `User-Agent: looot-swift/0.1.0 swift/<version>` and, with `agent:`, `X-Looot-Agent`.
