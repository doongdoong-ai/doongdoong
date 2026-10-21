import XCTest
import SoriCore
@testable import SoriSpeech

final class CodexModelDiscoveryTests: XCTestCase {
    private func entry(_ name: String, hidden: Bool = false, effort: String = "medium") -> [String: Any] {
        ["model": name, "hidden": hidden, "supportedReasoningEfforts": [["reasoningEffort": effort]]]
    }

    @MainActor func testSolOnLaterPageWinsWithoutInferenceOrTokenRequests() async throws {
        var calls: [String] = []
        let chosen = try await CodexModelDiscovery.discover { method, params in
            calls.append(method)
            if method == "account/read" {
                XCTAssertEqual(params["refreshToken"] as? Bool, false)
                return ["account": ["type": "chatgpt"]]
            }
            XCTAssertEqual(method, "model/list")
            XCTAssertEqual(params["includeHidden"] as? Bool, false)
            if params["cursor"] == nil {
                return ["data": [self.entry("gpt-6-luna")], "nextCursor": "page-2"]
            }
            XCTAssertEqual(params["cursor"] as? String, "page-2")
            return ["data": [self.entry("gpt-6.1-sol")], "nextCursor": NSNull()]
        }
        XCTAssertEqual(chosen, .sol)
        XCTAssertEqual(calls, ["account/read", "model/list", "model/list"])
    }

    @MainActor func testLunaWhenSolMissingHiddenOrCannotUseMedium() async throws {
        for sol in [entry("gpt-6-sol"), entry("gpt-6.1-sol", hidden: true), entry("gpt-6.1-sol", effort: "high")] {
            let chosen = try await CodexModelDiscovery.discover { method, _ in
                if method == "account/read" { return ["account": ["type": "chatgpt"]] }
                return ["data": [sol, self.entry("gpt-6-luna")]]
            }
            XCTAssertEqual(chosen, .luna)
        }
    }

    @MainActor func testNeitherSupportedModelDoesNotInventFallback() async throws {
        var imageOnly = entry("gpt-6.1-sol"); imageOnly["inputModalities"] = ["image"]
        for entries in [[], [entry("other")], [imageOnly], [entry("gpt-6-luna", effort: "low")]] {
            do {
                _ = try await CodexModelDiscovery.discover { method, _ in
                    method == "account/read" ? ["account": ["type": "chatgpt"]] : ["data": entries]
                }
                XCTFail("No authorized model")
            } catch CodexModelDiscovery.DiscoveryError.noSupportedModel {} catch { XCTFail("\(error)") }
        }
    }

    @MainActor func testMissingLoginAndAPIKeyNeverQueryModels() async throws {
        for account in [NSNull() as Any, ["type": "apiKey"] as Any] {
            var calls: [String] = []
            do {
                _ = try await CodexModelDiscovery.discover { method, _ in
                    calls.append(method); return ["account": account]
                }
                XCTFail("ChatGPT login required")
            } catch CodexModelDiscovery.DiscoveryError.loginRequired {} catch { XCTFail("\(error)") }
            XCTAssertEqual(calls, ["account/read"])
        }
    }

    @MainActor func testPartialOrMalformedCatalogNeverFallsBack() async throws {
        let pages: [[String: Any]] = [["nextCursor": NSNull()], ["data": [], "nextCursor": 5],
                                     ["data": [entry("gpt-6-luna")], "nextCursor": "repeat"]]
        for page in pages {
            var count = 0
            do {
                _ = try await CodexModelDiscovery.discover { method, _ in
                    if method == "account/read" { return ["account": ["type": "chatgpt"]] }
                    count += 1; return page
                }
                XCTFail("Invalid catalog")
            } catch CodexModelDiscovery.DiscoveryError.invalidCatalog {} catch { XCTFail("\(error)") }
            XCTAssertLessThanOrEqual(count, 2)
        }
    }

    @MainActor func testTransportFailureAndCancellationDoNotSelectLuna() async throws {
        let failures: [Error] = [URLError(.notConnectedToInternet), CancellationError()]
        for failure in failures {
            do {
                _ = try await CodexModelDiscovery.discover { method, _ in
                    if method == "account/read" { return ["account": ["type": "chatgpt"]] }
                    throw failure
                }
                XCTFail("Must propagate failure")
            } catch { XCTAssertEqual(String(reflecting: type(of: error)), String(reflecting: type(of: failure))) }
        }
    }
}
