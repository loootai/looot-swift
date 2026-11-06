import Foundation
import XCTest
@testable import Looot

final class HeaderAndAuthTests: XCTestCase {
    func testTokenRouteSendsAllHeaders() async throws {
        let t = MockTransport(json: #"{"endpoints":[]}"#)
        let c = makeClient(t, agent: "my-app")
        _ = try await c.search("verify an email")
        let h = t.last.headers
        XCTAssertEqual(h["Authorization"], "Bearer \(fakeToken)")
        XCTAssertEqual(h["Accept"], "application/json")
        XCTAssertEqual(h["X-Looot-Agent"], "my-app")
        XCTAssertNil(h["Content-Type"], "GET never sends Content-Type")
        XCTAssertNil(h["Idempotency-Key"])
        let ua = h["User-Agent"] ?? ""
        XCTAssertTrue(ua.hasPrefix("looot-swift/0.1.0 swift/"), ua)
    }

    func testAgentIsOmittedWhenNotSetAndCutTo64() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).balance()
        XCTAssertNil(t.last.headers["X-Looot-Agent"])
        let long = String(repeating: "a", count: 100)
        _ = try await makeClient(t, agent: long).balance()
        XCTAssertEqual(t.last.headers["X-Looot-Agent"]?.count, 64)
    }

    func testPostSendsContentTypeAndIdempotencyHeaderEqualToBody() async throws {
        let t = MockTransport(json: #"{"runId":"run_1","status":"queued"}"#)
        _ = try await makeClient(t).run(endpointId: "icypeas-email-verify", input: ["email": "jane@example.com"], idempotencyKey: "k-1")
        XCTAssertEqual(t.last.headers["Content-Type"], "application/json")
        XCTAssertEqual(t.last.headers["Idempotency-Key"], "k-1")
        XCTAssertEqual(try bodyJSON(t.last)["idempotencyKey"].stringValue, "k-1")
    }

    func testFreeRoutesSendNoAuthorizationEvenWithAToken() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t)
        _ = try await c.catalogOverview(topic: "email")
        XCTAssertNil(t.last.headers["Authorization"])
        _ = try await c.publicCatalog(capability: "people_email_verify", limit: 1)
        XCTAssertNil(t.last.headers["Authorization"])
        _ = try await c.publicCatalogItem("icypeas-email-verify")
        XCTAssertNil(t.last.headers["Authorization"])
        _ = try await c.comparePublicCatalog(["a", "b"])
        XCTAssertNil(t.last.headers["Authorization"])
        XCTAssertEqual(t.requests.count, 4)
    }

    func testFreeRoutesWorkWithNoToken() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t, token: nil)
        _ = try await c.catalogOverview()
        XCTAssertEqual(t.requests.count, 1)
    }

    func testMissingTokenOnEveryTokenRouteSendsNothing() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t, token: nil)
        let calls: [(String, () async throws -> Any)] = [
            ("search", { try await c.search("x") }),
            ("discover", { try await c.discover(query: "x") }),
            ("catalogEndpoints", { try await c.catalogEndpoints() }),
            ("inspect", { try await c.inspect("e") }),
            ("run", { try await c.run(endpointId: "e") }),
            ("runJob", { try await c.runJob("people.email.find") }),
            ("getRun", { try await c.getRun("r") }),
            ("listRuns", { try await c.listRuns() }),
            ("cancelRun", { try await c.cancelRun("r") }),
            ("runAttempts", { try await c.runAttempts("r") }),
            ("balance", { try await c.balance() }),
            ("whoami", { try await c.whoami() }),
            ("listTopUps", { try await c.listTopUps() }),
            ("ledger", { try await c.ledger() }),
            ("capabilityRequest", { try await c.capabilityRequest(title: "t", description: "d") }),
            ("downloadMedia", { try await c.downloadMedia("/v1/media/x") }),
        ]
        for (name, call) in calls {
            do {
                _ = try await call()
                XCTFail("\(name) should throw")
            } catch let e as LoootError {
                XCTAssertEqual(e.status, 401, name)
                XCTAssertEqual(e.code, "missing_token", name)
            }
        }
        XCTAssertEqual(t.requests.count, 0)
    }

    func testMissingTokenMessageNamesMethodPathAndFix() async throws {
        let c = makeClient(MockTransport(), token: nil)
        do {
            _ = try await c.balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.message, "GET /v1/balance needs a token: set LOOOT_TOKEN or pass token")
        }
    }

    func testTokenComesFromEnvironmentTrimmed() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t, token: nil, environment: ["LOOOT_TOKEN": "  env-token \n"])
        XCTAssertTrue(c.hasToken)
        _ = try await c.balance()
        XCTAssertEqual(t.last.headers["Authorization"], "Bearer env-token")
    }

    func testOptionBeatsEnvironmentAndEmptyMeansNoToken() async throws {
        let t = MockTransport(json: "{}")
        let a = makeClient(t, token: "opt", environment: ["LOOOT_TOKEN": "env"])
        _ = try await a.balance()
        XCTAssertEqual(t.last.headers["Authorization"], "Bearer opt")

        let b = makeClient(t, token: "", environment: ["LOOOT_TOKEN": "env"])
        XCTAssertFalse(b.hasToken)
        let c = makeClient(t, token: nil, environment: ["LOOOT_TOKEN": "   "])
        XCTAssertFalse(c.hasToken)
    }

    func testBaseURLOverrideStripsTrailingSlashes() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t, baseURL: "http://localhost:8787///")
        XCTAssertEqual(c.baseURL, "http://localhost:8787")
        _ = try await c.balance()
        XCTAssertEqual(t.last.url.absoluteString, "http://localhost:8787/v1/balance")
    }

    func testTokenNeverAppearsInDescriptions() async throws {
        let t = MockTransport(json: #"{"error":{"code":"forbidden","message":"no"}}"#, status: 403)
        let c = makeClient(t)
        do {
            _ = try await c.balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertFalse(e.description.contains(fakeToken))
            XCTAssertFalse("\(e)".contains(fakeToken))
            XCTAssertFalse((e.errorDescription ?? "").contains(fakeToken))
            XCTAssertFalse(String(describing: e.body).contains(fakeToken))
        }
        XCTAssertFalse("\(c)".contains(fakeToken))
        XCTAssertFalse(String(reflecting: c).contains(fakeToken))
    }
}

final class RouteTests: XCTestCase {
    func testCatalogOverviewRouteAndQuery() async throws {
        let t = MockTransport(json: #"{"revision":"1","topic":"email","matchCount":74,"truncated":true,"jobs":[{"id":"people.email.find","cheapestPerCall":0.003598,"cheapestPerResult":null}]}"#)
        let o = try await makeClient(t).catalogOverview(topic: "email")
        XCTAssertEqual(t.last.method, "GET")
        XCTAssertEqual(path(t.last), "/v1/catalog/overview")
        XCTAssertEqual(query(t.last), ["topic": "email"])
        XCTAssertEqual(o.topic, "email")
        XCTAssertEqual(o.matchCount, 74)
        XCTAssertEqual(o.truncated, true)
        XCTAssertEqual(o.jobs.first?.id, "people.email.find")
        XCTAssertEqual(o.jobs.first?.cheapestPerCall, 0.003598)
        XCTAssertNil(o.jobs.first?.cheapestPerResult)
    }

    func testPublicCatalogAndItem() async throws {
        let t = MockTransport(json: #"{"items":[{"catalogItemId":"x","parameters":[{"name":"email","required":true}],"price":{"state":"known","amountMicros":143880,"currency":"USD"}}],"nextCursor":"abc"}"#)
        let c = makeClient(t)
        let page = try await c.publicCatalog(q: "verify", text: "t", capability: "people_email_verify", category: "web-data", provider: "anysite", operationId: "op", limit: 1, cursor: "cur")
        XCTAssertEqual(path(t.last), "/v1/public-catalog")
        XCTAssertEqual(query(t.last), ["q": "verify", "text": "t", "capability": "people_email_verify", "category": "web-data", "provider": "anysite", "operationId": "op", "limit": "1", "cursor": "cur"])
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.items.first?.parameters.first?.isRequired, true)
        XCTAssertEqual(page.items.first?.price?.amountMicros, 143_880)

        _ = try await c.publicCatalogItem("icypeas-email-verify")
        XCTAssertEqual(path(t.last), "/v1/public-catalog/icypeas-email-verify")
    }

    func testComparePostsIds() async throws {
        let t = MockTransport(json: #"{"items":[]}"#)
        _ = try await makeClient(t).comparePublicCatalog(["a", "b"])
        XCTAssertEqual(t.last.method, "POST")
        XCTAssertEqual(path(t.last), "/v1/public-catalog/compare")
        XCTAssertEqual(try bodyJSON(t.last), ["catalogItemIds": ["a", "b"]])
    }

    func testSearchMapsFiltersAndDropsUnset() async throws {
        let t = MockTransport(json: #"{"query":"q","total":7,"nextOffset":5,"endpoints":[{"endpointId":"icypeas-email-verify","capability":"people.email.verify","estimatedPrice":0.0019,"priceBasis":"perCall","access":"runs_now","works":{"rate":0.9,"runs":10,"thin":false},"job":{"id":"people.email.verify"}}]}"#)
        let r = try await makeClient(t).search("verify an email", keyless: true, maxPriceMicros: 5000, prefer: .cheapest)
        XCTAssertEqual(path(t.last), "/v1/catalog/search")
        XCTAssertEqual(query(t.last), ["q": "verify an email", "prefer": "cheapest", "maxPriceMicros": "5000", "keyless": "true"])
        XCTAssertEqual(t.last.headers["Authorization"], "Bearer \(fakeToken)")
        XCTAssertEqual(r.total, 7)
        XCTAssertEqual(r.nextOffset, 5)
        let first: CatalogEndpoint? = r.endpoints.first
        let e = try XCTUnwrap(first)
        XCTAssertEqual(e.endpointId, "icypeas-email-verify")
        XCTAssertEqual(e.estimatedPrice, 0.0019)
        XCTAssertEqual(e.works?.runs, 10)
        XCTAssertEqual(e.job?.id, "people.email.verify")
    }

    func testBooleansAreLowercaseAndFalseIsSent() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).search("x", verified: false, mock: false)
        XCTAssertEqual(query(t.last)["verified"], "false")
        XCTAssertEqual(query(t.last)["mock"], "false")
    }

    func testNilAndEmptyParamsAreDropped() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t)
        _ = try await c.search("hello", limit: nil, offset: nil, category: "")
        XCTAssertEqual(query(t.last), ["q": "hello"])
        XCTAssertFalse(t.last.url.absoluteString.contains("limit"))
        _ = try await c.listRuns(limit: 0)
        XCTAssertNil(t.last.url.query)
    }

    func testQueryValuesArePercentEncoded() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).search("a&b=c d+e")
        XCTAssertTrue(t.last.url.absoluteString.hasSuffix("?q=a%26b%3Dc%20d%2Be"), t.last.url.absoluteString)
        XCTAssertEqual(query(t.last)["q"], "a&b=c d+e")
    }

    func testDiscoverAndEndpoints() async throws {
        let t = MockTransport(json: #"{"candidates":[{"endpointId":"e1"}],"meta":{"k":1},"endpoints":[],"nextCursor":null}"#)
        let c = makeClient(t)
        let d = try await c.discover(query: "find email", prefer: .fastest, resultLimit: 3, maxPrice: 0.05, includeUnavailable: true)
        XCTAssertEqual(path(t.last), "/v1/discover")
        XCTAssertEqual(query(t.last), ["query": "find email", "prefer": "fastest", "resultLimit": "3", "maxPrice": "0.05", "includeUnavailable": "true"])
        XCTAssertEqual(d.candidates.first?.endpointId, "e1")
        XCTAssertEqual(d.meta["k"].intValue, 1)

        let p = try await c.catalogEndpoints(capability: "people.email.find", facets: true, limit: 100, cursor: "c")
        XCTAssertEqual(path(t.last), "/v1/catalog/endpoints")
        XCTAssertEqual(query(t.last), ["capability": "people.email.find", "facets": "true", "limit": "100", "cursor": "c"])
        XCTAssertNil(p.nextCursor)
    }

    func testInspectEncodesTheIdAsOneSegment() async throws {
        let t = MockTransport(json: #"{"endpoint":{"id":"x","effectClassification":"effectful"},"inputSchema":{"type":"object"}}"#)
        let c = makeClient(t)
        let op = try await c.inspect("icypeas-email-verify")
        XCTAssertEqual(path(t.last), "/v1/operations/icypeas-email-verify")
        XCTAssertEqual(op.endpoint?.isEffectful, true)
        XCTAssertEqual(op.inputSchema["type"].stringValue, "object")

        _ = try await c.inspect("job:people.email.find")
        XCTAssertEqual(path(t.last), "/v1/operations/job%3Apeople.email.find")
    }

    func testPathSegmentsAreEncoded() async throws {
        let t = MockTransport(json: "{}")
        let c = makeClient(t)
        _ = try await c.getRun("a/b")
        XCTAssertEqual(path(t.last), "/v1/runs/a%2Fb")
        _ = try await c.cancelRun("a/b?x#y")
        XCTAssertEqual(path(t.last), "/v1/runs/a%2Fb%3Fx%23y/cancel")
        _ = try await c.runAttempts("../x")
        XCTAssertEqual(path(t.last), "/v1/runs/..%2Fx/attempts")
        _ = try await c.publicCatalogItem("é ü")
        XCTAssertEqual(path(t.last), "/v1/public-catalog/%C3%A9%20%C3%BC")
    }

    func testGetRunTrimQuery() async throws {
        let t = MockTransport(json: #"{"runId":"run_1","status":"completed","trimmed":{"n":1}}"#)
        let r = try await makeClient(t).getRun("run_1", fields: ["result.a", "result.b"], maxItems: 5)
        XCTAssertEqual(path(t.last), "/v1/runs/run_1")
        XCTAssertEqual(query(t.last), ["fields": "result.a,result.b", "max_items": "5"])
        XCTAssertEqual(r["trimmed"]["n"].intValue, 1)
    }

    func testListRunsQuery() async throws {
        let t = MockTransport(json: #"{"runs":[{"runId":"run_1","status":"completed","actualCost":0.005,"error":null}],"nextCursor":"n"}"#)
        let l = try await makeClient(t).listRuns(status: .completed, capability: "people.email.find", limit: 5, cursor: "c", includeResult: true)
        XCTAssertEqual(path(t.last), "/v1/runs")
        XCTAssertEqual(query(t.last), ["status": "completed", "capability": "people.email.find", "limit": "5", "cursor": "c", "includeResult": "true"])
        XCTAssertEqual(l.runs.first?.actualCost, 0.005)
        XCTAssertNil(l.runs.first?.error)
        XCTAssertEqual(l.nextCursor, "n")
    }

    func testCancelAndAttempts() async throws {
        let t = MockTransport(json: #"{"status":"stopped","attempts":[{"providerId":"hunter","status":"succeeded","costMicros":12250}]}"#)
        let c = makeClient(t)
        let run = try await c.cancelRun("run_1")
        XCTAssertEqual(t.last.method, "POST")
        XCTAssertEqual(path(t.last), "/v1/runs/run_1/cancel")
        XCTAssertNil(t.last.body)
        XCTAssertNil(t.last.headers["Content-Type"])
        XCTAssertEqual(run.status, .stopped)

        let a = try await c.runAttempts("run_1")
        XCTAssertEqual(path(t.last), "/v1/runs/run_1/attempts")
        XCTAssertEqual(a.attempts.first?.costMicros, 12_250)
    }

    func testBalanceAndTopUpLink() async throws {
        let t = MockTransport(json: #"{"workspaceId":"w","currency":"USD","available":94.628918,"reserved":0,"topUpLink":{"minimumUsd":5,"suggestedUsd":5,"checkoutUrl":null,"dashboardUrl":"https://looot.ai/usage?top_up=1"}}"#)
        let b = try await makeClient(t).balance()
        XCTAssertEqual(path(t.last), "/v1/balance")
        XCTAssertEqual(b.available, 94.628918)
        XCTAssertEqual(b.topUpLink?.minimumUsd, 5)
        XCTAssertNil(b.topUpLink?.checkoutUrl)
        XCTAssertEqual(b.topUpLink?.url, "https://looot.ai/usage?top_up=1")
    }

    func testAccountRoutes() async throws {
        let t = MockTransport(json: #"{"workspaceId":"w","role":"owner","topUps":[{"a":1}],"entries":[],"nextCursor":null,"requestId":"r","status":"open"}"#)
        let c = makeClient(t)
        let who = try await c.whoami()
        XCTAssertEqual(who.role, "owner")
        XCTAssertEqual(path(t.last), "/v1/whoami")
        let tops = try await c.listTopUps()
        XCTAssertEqual(tops.topUps.count, 1)
        XCTAssertEqual(path(t.last), "/v1/top-ups")
        _ = try await c.ledger(limit: 10, cursor: "c")
        XCTAssertEqual(path(t.last), "/v1/ledger")
        XCTAssertEqual(query(t.last), ["limit": "10", "cursor": "c"])

        let cr = try await c.capabilityRequest(title: "T", description: "D", desiredInputs: ["domain"])
        XCTAssertEqual(t.last.method, "POST")
        XCTAssertEqual(path(t.last), "/v1/capability-requests")
        let body = try bodyJSON(t.last)
        XCTAssertEqual(body["title"].stringValue, "T")
        XCTAssertEqual(body["desiredInputs"], ["domain"])
        XCTAssertTrue(body["idempotencyKey"].stringValue?.hasPrefix("sdk-") == true)
        XCTAssertNotNil(body["requestId"].stringValue)
        XCTAssertEqual(cr.status, "open")
    }

    func testDownloadMedia() async throws {
        let t = MockTransport([.response(HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3])))])
        let c = makeClient(t)
        let m = try await c.downloadMedia("/v1/runs/run_1/media?name=a%20b")
        XCTAssertEqual(t.last.url.absoluteString, "https://api.looot.ai/v1/runs/run_1/media?name=a%20b")
        XCTAssertEqual(t.last.headers["Authorization"], "Bearer \(fakeToken)")
        XCTAssertEqual(m.data, Data([1, 2, 3]))
        XCTAssertEqual(m.contentType, "image/png")

        for bad in ["https://evil.example/x", "//evil.example/x", "v1/x"] {
            do {
                _ = try await c.downloadMedia(bad)
                XCTFail("should reject \(bad)")
            } catch let e as LoootError {
                XCTAssertEqual(e.code, "invalid_request")
            }
        }
        XCTAssertEqual(t.requests.count, 1)
    }
}

final class RunTests: XCTestCase {
    func testRunKeepsExplicitFallbackAndGeneratesSdkKey() async throws {
        let t = MockTransport(json: #"{"runId":"run_1","status":"queued"}"#)
        _ = try await makeClient(t).run(
            endpointId: "icypeas-email-verify", input: ["email": "jane.doe@example.com"],
            fallback: FallbackOptions(maxAttempts: 2, maxCostUsd: 0.05), output: ["pick": "x"])
        XCTAssertEqual(t.last.method, "POST")
        XCTAssertEqual(path(t.last), "/v1/runs")
        let b = try bodyJSON(t.last)
        XCTAssertEqual(b["endpointId"].stringValue, "icypeas-email-verify")
        XCTAssertEqual(b["input"], ["email": "jane.doe@example.com"])
        XCTAssertEqual(b["fallback"], ["maxAttempts": 2, "maxCostUsd": 0.05])
        XCTAssertEqual(b["output"], ["pick": "x"])
        let key = try XCTUnwrap(b["idempotencyKey"].stringValue)
        XCTAssertTrue(key.hasPrefix("sdk-"), key)
        XCTAssertEqual(key.count, 4 + 36)
        XCTAssertEqual(t.last.headers["Idempotency-Key"], key)
        XCTAssertEqual(b.objectValue?.keys.sorted(), ["endpointId", "fallback", "idempotencyKey", "input", "output"])
    }

    func testRunWithoutFallbackOrOutputSendsNeither() async throws {
        let t = MockTransport(json: #"{"runId":"run_1","status":"queued"}"#)
        _ = try await makeClient(t).run(endpointId: "e")
        let b = try bodyJSON(t.last)
        XCTAssertEqual(b.objectValue?.keys.sorted(), ["endpointId", "idempotencyKey", "input"])
        XCTAssertEqual(b["input"], [:])
    }

    func testFallbackOnSendsTrue() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).run(endpointId: "e", fallback: .on)
        XCTAssertEqual(try bodyJSON(t.last)["fallback"], true)
    }

    func testWaitGoesInTheQueryNotTheBody() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).run(endpointId: "e", wait: 20)
        XCTAssertEqual(query(t.last), ["wait": "20"])
        XCTAssertNil(try bodyJSON(t.last)["wait"].stringValue)
        XCTAssertNil(try bodyJSON(t.last).objectValue?["wait"])
        _ = try await makeClient(t).run(endpointId: "e")
        XCTAssertNil(t.last.url.query)
    }

    func testRunJobPostsJobIdAndMergesPreferIntoFallback() async throws {
        let t = MockTransport(json: #"{"runId":"run_1","status":"completed","outcome":"hit"}"#)
        let c = makeClient(t)
        _ = try await c.runJob("people.email.verify", input: ["email": "jane.doe@example.com"], prefer: .cheapest, wait: 20, idempotencyKey: "k1")
        var b = try bodyJSON(t.last)
        XCTAssertEqual(b["endpointId"].stringValue, "job:people.email.verify")
        XCTAssertEqual(b["fallback"], ["prefer": "cheapest"])
        XCTAssertEqual(b["idempotencyKey"].stringValue, "k1")
        XCTAssertEqual(query(t.last), ["wait": "20"])

        _ = try await c.runJob("people.email.verify", prefer: .fastest, fallback: FallbackOptions(maxAttempts: 3))
        b = try bodyJSON(t.last)
        XCTAssertEqual(b["fallback"], ["maxAttempts": 3, "prefer": "fastest"])

        _ = try await c.runJob("people.email.verify", prefer: .reliable, fallback: .on)
        XCTAssertEqual(try bodyJSON(t.last)["fallback"], ["prefer": "reliable"])
    }

    func testRunJobWithoutPreferOrFallbackSendsNoFallbackKey() async throws {
        let t = MockTransport(json: "{}")
        _ = try await makeClient(t).runJob("people.email.find")
        XCTAssertNil(try bodyJSON(t.last).objectValue?["fallback"])
    }

    func testA201FailedRunIsReturnedNotThrown() async throws {
        let json = #"{"runId":"run_9","status":"failed","outcome":"rejected","actualCost":0,"error":{"code":"validation_error","message":"needs input","whoseError":"customer","retryable":false,"retryHint":"Add the domain."},"result":{"code":"needs_input","needs":["domain"]}}"#
        let t = MockTransport(json: json, status: 201)
        let run = try await makeClient(t).runJob("people.email.find")
        XCTAssertEqual(run.status, .failed)
        XCTAssertFalse(run.isSuccess)
        XCTAssertTrue(run.isTerminal)
        XCTAssertEqual(run.outcome, .rejected)
        XCTAssertEqual(run.error?.code, "validation_error")
        XCTAssertEqual(run.error?.whoseError, "customer")
        XCTAssertEqual(run.error?.retryHint, "Add the domain.")
        XCTAssertEqual(run.result["needs"][0].stringValue, "domain")
        XCTAssertEqual(t.requests.count, 1, "a failed run is never retried")
    }

    func testFullRunDecodesAndKeepsUnknownKeys() async throws {
        let json = """
        {"runId":"run_1","status":"completed","outcome":"hit","endpointId":"icypeas-email-verify",
         "estimatedCost":0.002,"actualCost":0.0019,"pricing":{"finalChargeMicros":1900},"replayed":true,
         "error":null,
         "requestedJob":{"id":"job:people.email.verify","job":"people.email.verify","pickedEndpointId":"icypeas-email-verify","skipped":[]},
         "route":{"servedBy":"icypeas-email-verify","outcome":"hit","chargedUsd":0.0019,"capped":false,
           "attempts":[{"n":1,"endpointId":"icypeas-email-verify","provider":"icypeas","outcome":"hit","status":"completed","chargedUsd":0.0019,"billed":true,"ms":380}],
           "skipped":[{"endpointId":"x","code":"no_key"}]},
         "normalized":{"job":"people.email.verify","fields":{"valid":true},"missing":["a"],"verdict":"valid"},
         "nextSteps":[{"suggestionId":"s1"}],
         "brandNewField":{"deep":[1,2,3]}}
        """
        let t = MockTransport(json: json)
        let run = try await makeClient(t).getRun("run_1")
        XCTAssertTrue(run.isSuccess)
        XCTAssertEqual(run.runId, "run_1")
        XCTAssertEqual(run.finalChargeMicros, 1900)
        XCTAssertTrue(run.replayed)
        XCTAssertEqual(run.requestedJob?.pickedEndpointId, "icypeas-email-verify")
        XCTAssertEqual(run.route?.servedBy, "icypeas-email-verify")
        XCTAssertEqual(run.route?.attempts.first?.billed, true)
        XCTAssertEqual(run.route?.attempts.first?.ms, 380)
        XCTAssertEqual(run.route?.skipped.first?.code, "no_key")
        XCTAssertEqual(run.normalized?.fields["valid"].boolValue, true)
        XCTAssertEqual(run.normalized?.missing, ["a"])
        XCTAssertEqual(run.nextSteps.count, 1)
        XCTAssertEqual(run["brandNewField"]["deep"][2].intValue, 3)
        XCTAssertEqual(run.raw["brandNewField"]["deep"].arrayValue?.count, 3)
        // Round trip keeps the unknown key.
        let again = try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(again, run)
    }

    func testUnknownStatusIsKeptAndNotTerminal() async throws {
        let t = MockTransport(json: #"{"runId":"r","status":"warming_up","outcome":"shiny"}"#)
        let run = try await makeClient(t).getRun("r")
        XCTAssertEqual(run.status.rawValue, "warming_up")
        XCTAssertFalse(run.isTerminal)
        XCTAssertEqual(run.outcome?.rawValue, "shiny")
    }

    func testWaitForRunPollsUntilTerminalWithBackoff() async throws {
        let t = MockTransport([
            reply(#"{"runId":"r","status":"queued"}"#),
            reply(#"{"runId":"r","status":"running"}"#),
            reply(#"{"runId":"r","status":"pending_provider"}"#),
            reply(#"{"runId":"r","status":"completed"}"#),
        ])
        let sleeps = Sleeps()
        let run = try await makeClient(t, sleeps: sleeps).waitForRun("r")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(t.requests.count, 4)
        XCTAssertEqual(sleeps.all, [1, 2, 4])
    }

    func testWaitForRunTimesOut() async throws {
        let t = MockTransport(json: #"{"runId":"r","status":"running"}"#)
        do {
            _ = try await makeClient(t).waitForRun("r", timeout: 0.5, interval: 1)
            XCTFail("should time out")
        } catch let e as LoootError {
            XCTAssertEqual(e.code, "timeout")
        }
    }

    func testAllRunsFollowsCursorsUntilNull() async throws {
        let t = MockTransport([
            reply(#"{"runs":[{"runId":"1"},{"runId":"2"}],"nextCursor":"c1"}"#),
            reply(#"{"runs":[{"runId":"3"}],"nextCursor":"c2"}"#),
            reply(#"{"runs":[{"runId":"4"}],"nextCursor":null}"#),
        ])
        var ids: [String] = []
        for try await run in makeClient(t).allRuns(status: .completed) { ids.append(run.runId ?? "") }
        XCTAssertEqual(ids, ["1", "2", "3", "4"])
        XCTAssertEqual(t.requests.map { query($0)["cursor"] }, [nil, "c1", "c2"])
        XCTAssertEqual(t.requests.map { query($0)["status"] }, ["completed", "completed", "completed"])
    }
}

final class ErrorTests: XCTestCase {
    func testPaymentRequiredBecomesLoootErrorWithTopUp() async throws {
        let json = #"{"error":{"code":"insufficient_balance","message":"Not enough credit.","requestId":"req_1"},"topUp":{"checkoutUrl":"https://pay.example/c","dashboardUrl":"https://looot.ai/usage?top_up=1","minimumUsd":5}}"#
        let t = MockTransport(json: json, status: 402)
        let c = makeClient(t)
        do {
            _ = try await c.runJob("people.email.find")
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.status, 402)
            XCTAssertEqual(e.code, "insufficient_balance")
            XCTAssertEqual(e.message, "Not enough credit.")
            XCTAssertEqual(e.requestId, "req_1")
            XCTAssertFalse(e.retryable)
            XCTAssertEqual(e.topUp?.checkoutUrl, "https://pay.example/c")
            XCTAssertEqual(e.topUp?.url, "https://pay.example/c")
            XCTAssertEqual(e.topUp?.minimumUsd, 5)
            XCTAssertEqual(e.body?["topUp"]["dashboardUrl"].stringValue, "https://looot.ai/usage?top_up=1")
            XCTAssertTrue(e.description.contains("insufficient_balance"))
            XCTAssertTrue(e.description.contains("req_1"))
        }
        XCTAssertEqual(t.requests.count, 1, "402 is never retried")
    }

    func testFallbacksWhenTheEnvelopeIsMissing() async throws {
        let t = MockTransport(json: "<html>bad gateway</html>", status: 502, headers: ["X-Request-Id": "req_hdr"])
        do {
            _ = try await makeClient(t).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.status, 502)
            XCTAssertEqual(e.code, "http_502")
            XCTAssertEqual(e.message, "GET /v1/balance failed with HTTP 502")
            XCTAssertEqual(e.requestId, "req_hdr")
            XCTAssertEqual(e.body, .string("<html>bad gateway</html>"))
            XCTAssertFalse(e.retryable)
        }
    }

    func testRetryableTable() async throws {
        let cases: [(Int, String, Bool)] = [
            (400, "validation_error", false), (401, "unauthorized", false), (402, "insufficient_balance", false),
            (403, "forbidden", false), (404, "not_found", false), (405, "method_not_allowed", false),
            (409, "idempotency_conflict", false), (422, "rows_mode_unsupported", false),
            (429, "run_rate_limited", true), (500, "internal_error", true),
            (503, "catalog_loading", true), (503, "storage_busy", true), (503, "billing_unavailable", false),
        ]
        for (status, code, want) in cases {
            let t = MockTransport(json: #"{"error":{"code":"\#(code)","message":"m"}}"#, status: status)
            do {
                _ = try await makeClient(t, maxRetries: 0).balance()
                XCTFail("should throw")
            } catch let e as LoootError {
                XCTAssertEqual(e.retryable, want, "\(status) \(code)")
            }
        }
    }

    func testBodyRetryableWinsOverTable() async throws {
        let t = MockTransport(json: #"{"error":{"code":"internal_error","message":"m","retryable":false,"retryHint":"Report it."}}"#, status: 500)
        do {
            _ = try await makeClient(t).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertFalse(e.retryable)
            XCTAssertEqual(e.retryHint, "Report it.")
        }
    }

    func testRetryAfterFromBodyThenHeader() async throws {
        let a = MockTransport(json: #"{"error":{"code":"run_rate_limited","message":"m"},"retryAfterSeconds":7}"#, status: 429, headers: ["Retry-After": "3"])
        do {
            _ = try await makeClient(a, maxRetries: 0).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.retryAfterSeconds, 7)
        }
        let b = MockTransport(json: #"{"error":{"code":"run_rate_limited","message":"m"}}"#, status: 429, headers: ["Retry-After": "3"])
        do {
            _ = try await makeClient(b, maxRetries: 0).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.retryAfterSeconds, 3)
        }
    }
}

final class RetryTests: XCTestCase {
    func testRetriesA429WithTheSameIdempotencyKey() async throws {
        let t = MockTransport([
            reply(#"{"error":{"code":"too_many_inflight_runs","message":"slow down"}}"#, status: 429, headers: ["Retry-After": "2"]),
            reply(#"{"error":{"code":"run_rate_limited","message":"slow down"}}"#, status: 429),
            reply(#"{"runId":"run_1","status":"completed"}"#),
        ])
        let sleeps = Sleeps()
        let run = try await makeClient(t, sleeps: sleeps).runJob("people.email.find", input: ["domain": "example.com"])
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(t.requests.count, 3)
        let keys = Set(t.requests.map { $0.headers["Idempotency-Key"] ?? "" })
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.first!.hasPrefix("sdk-"))
        let bodyKeys = try Set(t.requests.map { try bodyJSON($0)["idempotencyKey"].stringValue ?? "" })
        XCTAssertEqual(bodyKeys, keys)
        XCTAssertEqual(sleeps.all.count, 2)
        XCTAssertEqual(sleeps.all[0], 2, "waits Retry-After")
        XCTAssertTrue(sleeps.all[1] >= 1 && sleeps.all[1] < 1.5, "backoff 1 s plus jitter")
    }

    func testRetriesARetryable503ThenGivesUpAfterTwoRetries() async throws {
        let t = MockTransport(json: #"{"error":{"code":"storage_busy","message":"busy"}}"#, status: 503)
        do {
            _ = try await makeClient(t).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.code, "storage_busy")
        }
        XCTAssertEqual(t.requests.count, 3)
    }

    func testRetryDelayIsCappedAt30Seconds() async throws {
        let t = MockTransport([
            reply(#"{"error":{"code":"run_rate_limited","message":"m"}}"#, status: 429, headers: ["Retry-After": "120"]),
            reply("{}"),
        ])
        let sleeps = Sleeps()
        _ = try await makeClient(t, sleeps: sleeps).balance()
        XCTAssertEqual(sleeps.all, [30])
    }

    func testDoesNotRetryOtherClientErrorsOrBillingOr500() async throws {
        for (status, code) in [(400, "validation_error"), (401, "unauthorized"), (402, "insufficient_balance"), (403, "forbidden"), (404, "not_found"), (409, "idempotency_conflict"), (422, "rows_mode_unsupported"), (500, "internal_error"), (503, "billing_unavailable")] {
            let t = MockTransport(json: #"{"error":{"code":"\#(code)","message":"m"}}"#, status: status)
            let sleeps = Sleeps()
            do {
                _ = try await makeClient(t, sleeps: sleeps).run(endpointId: "e")
                XCTFail("should throw")
            } catch is LoootError {}
            XCTAssertEqual(t.requests.count, 1, "\(status) \(code) must not retry")
            XCTAssertTrue(sleeps.all.isEmpty)
        }
    }

    func testMaxRetriesZeroTurnsRetriesOff() async throws {
        let t = MockTransport(json: #"{"error":{"code":"run_rate_limited","message":"m"}}"#, status: 429)
        do {
            _ = try await makeClient(t, maxRetries: 0).balance()
            XCTFail("should throw")
        } catch is LoootError {}
        XCTAssertEqual(t.requests.count, 1)
    }

    func testNetworkErrorBecomesLoootErrorAndIsRetried() async throws {
        let t = MockTransport([.failure(URLError(.notConnectedToInternet)), reply(#"{"workspaceId":"w"}"#)])
        let b = try await makeClient(t).balance()
        XCTAssertEqual(b.workspaceId, "w")
        XCTAssertEqual(t.requests.count, 2)

        let dead = MockTransport([.failure(URLError(.cannotFindHost))])
        do {
            _ = try await makeClient(dead).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.status, 0)
            XCTAssertEqual(e.code, "network_error")
            XCTAssertTrue(e.retryable)
        }
        XCTAssertEqual(dead.requests.count, 3)
    }

    func testTimeoutBecomesLoootError() async throws {
        let t = MockTransport([.failure(URLError(.timedOut))])
        do {
            _ = try await makeClient(t, maxRetries: 0).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.status, 0)
            XCTAssertEqual(e.code, "timeout")
            XCTAssertTrue(e.retryable)
        }
    }

    func testCancellationIsNotRetried() async throws {
        let t = MockTransport([.failure(CancellationError())])
        do {
            _ = try await makeClient(t).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.code, "canceled")
            XCTAssertFalse(e.retryable)
        }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testNonJSONSuccessBodyIsInvalidResponse() async throws {
        let t = MockTransport(json: "not json")
        do {
            _ = try await makeClient(t).balance()
            XCTFail("should throw")
        } catch let e as LoootError {
            XCTAssertEqual(e.code, "invalid_response")
            XCTAssertEqual(e.status, 200)
        }
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripKeepsEverything() throws {
        let text = #"{"a":[1,2.5,"x",null,true],"b":{"c":{}}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(v["a"][1].doubleValue, 2.5)
        XCTAssertEqual(v["a"][0].intValue, 1)
        XCTAssertNil(v["a"][1].intValue)
        XCTAssertTrue(v["a"][3].isNull)
        XCTAssertTrue(v["missing"]["deeper"].isNull)
        XCTAssertEqual(v.jsonString, text)
    }

    func testBooleansAndNumbersStayDistinct() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true,1,false,0]"#.utf8))
        XCTAssertEqual(v, [true, 1, false, 0])
        XCTAssertEqual(v[0].boolValue, true)
        XCTAssertNil(v[1].boolValue)
    }

    func testLiteralsBuildInput() {
        let v: JSONValue = ["email": "jane@example.com", "limit": 5, "flags": [true, nil], "price": 0.5]
        XCTAssertEqual(v["limit"].intValue, 5)
        XCTAssertEqual(v["flags"][1], .null)
        XCTAssertEqual(v["price"].doubleValue, 0.5)
    }
}
