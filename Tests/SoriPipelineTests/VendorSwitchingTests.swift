import XCTest
import DoongdoongAI
import DoongdoongCodex
import DoongdoongClaude
@testable import SoriApp

final class VendorSwitchingTests: XCTestCase {
    @MainActor private func fixture(codexPath: String = "/usr/bin/true", claudePath: String = "/usr/bin/true", vendor: AIVendor? = .codex,
                                    claude: @escaping AppSettings.ClaudeVerifier = { _, effort in VendorFixture.claude(effort) },
                                    codex: @escaping AppSettings.ConnectionVerifier = { _, _, effort in ConnectionFixture.ready(.sol, effort: effort) },
                                    claudeLogin: @escaping AppSettings.ClaudeLogin = { _ in }) throws -> (UserDefaults, String, AppSettings) {
        let name = "doongdoong-vendor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(codexPath, forKey: "codexPath"); defaults.set(claudePath, forKey: "claudePath")
        if let vendor { defaults.set(vendor.rawValue, forKey: "aiVendor") }
        return (defaults, name, AppSettings(defaults: defaults, connectionVerifier: codex, browserLogin: { _, _ in XCTFail("Codex login") },
                                            claudeVerifier: claude, claudeLogin: claudeLogin))
    }

    @MainActor func testSwitchingBackRestoresVerifiedVendorWithoutAnotherProbe() async throws {
        var codexProbes = 0, claudeProbes = 0
        let (defaults, name, settings) = try fixture(
            claude: { _, effort in claudeProbes += 1; return VendorFixture.claude(effort) },
            codex: { _, _, effort in codexProbes += 1; return ConnectionFixture.ready(.sol, effort: effort) })
        defer { defaults.removePersistentDomain(forName: name) }
        await settings.refreshAIConnection()?.value
        XCTAssertEqual(settings.selectedModel?.vendor, .codex)

        settings.vendor = .claude
        XCTAssertEqual(settings.connectionState, .checking, "An unchecked vendor is verified as soon as it is chosen")
        XCTAssertEqual(settings.connectionState(for: .codex), .ready(.init(vendor: .codex, id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol")))
        while settings.checkingAI { await Task.yield() }
        XCTAssertEqual(settings.selectedModel, .init(vendor: .claude, id: "sonnet", displayName: "Sonnet 5.5"))
        XCTAssertTrue(settings.analysisReady)
        let provider = try XCTUnwrap(settings.makeTextProvider() as? ClaudeTextProvider)
        XCTAssertEqual(provider.identity, .init(provider: "claude", model: "sonnet", reasoningEffort: "medium"))

        settings.vendor = .codex
        XCTAssertEqual(settings.selectedModel?.vendor, .codex, "Switching back is instant")
        XCTAssertTrue(settings.makeTextProvider() is CodexTextProvider)
        settings.vendor = .claude
        XCTAssertEqual(settings.selectedModel?.vendor, .claude)
        XCTAssertEqual(codexProbes, 1); XCTAssertEqual(claudeProbes, 1)
        XCTAssertEqual(AppSettings(defaults: defaults).vendor, .claude, "The choice persists")
        XCTAssertTrue(defaults.bool(forKey: "aiSetup.claude.completed"))
    }

    @MainActor func testChangingAVendorSettingInvalidatesOnlyThatVendorAndKeepsRunningJobs() async throws {
        let (defaults, name, settings) = try fixture(vendor: .claude)
        defer { defaults.removePersistentDomain(forName: name) }
        await settings.refreshAIConnection()?.value
        let job = try XCTUnwrap(settings.makeTextProvider() as? ClaudeTextProvider)
        settings.claudeEffort = .high
        XCTAssertNil(settings.selectedModel, "A new effort must be verified before use")
        XCTAssertEqual(job.configuration.effort, .medium)
        await settings.refreshAIConnection()?.value
        XCTAssertEqual((settings.makeTextProvider() as? ClaudeTextProvider)?.configuration.effort, .high)

        settings.vendor = .codex
        await settings.refreshAIConnection()?.value
        settings.claudePath = "/usr/bin/false"
        XCTAssertEqual(settings.connectionState(for: .claude), .unchecked, "A changed CLI path drops the stored result")
        XCTAssertNotNil(settings.selectedModel, "The active vendor is unaffected")
    }

    @MainActor func testMismatchedIdentityIsNotAccepted() async throws {
        let (defaults, name, settings) = try fixture(vendor: .claude, claude: { _, effort in
            .init(catalog: nil, result: .success(.init(provider: "codex", model: "sonnet", reasoningEffort: effort.rawValue)))
        })
        defer { defaults.removePersistentDomain(forName: name) }
        await settings.refreshAIConnection()?.value
        XCTAssertEqual(settings.connectionIssue?.kind, .invalidResponse)
        XCTAssertNil(settings.makeTextProvider())
    }

    @MainActor func testClaudeSignInUsesClaudeLoginAndStillProbes() async throws {
        var logins = 0, probes = 0
        let (defaults, name, settings) = try fixture(vendor: .claude, claude: { _, effort in
            probes += 1; return VendorFixture.claude(effort)
        }, claudeLogin: { executable in logins += 1; XCTAssertEqual(executable.path, "/usr/bin/true") })
        defer { defaults.removePersistentDomain(forName: name) }
        await settings.signIn { _ in XCTFail("Claude opens its own browser"); return false }.value
        XCTAssertEqual(logins, 1); XCTAssertEqual(probes, 1)
        XCTAssertEqual(settings.selectedModel?.vendor, .claude)
    }

    @MainActor func testNewUserWithoutCodexStartsWithInstalledClaude() throws {
        let (d1, n1, missingCodex) = try fixture(codexPath: "/missing/codex", vendor: nil)
        defer { d1.removePersistentDomain(forName: n1) }
        XCTAssertEqual(missingCodex.vendor, .claude)
        let (d2, n2, both) = try fixture(vendor: nil)
        defer { d2.removePersistentDomain(forName: n2) }
        XCTAssertEqual(both.vendor, .codex, "Existing Codex users are not moved")
        let (d3, n3, neither) = try fixture(codexPath: "/missing/codex", claudePath: "/missing/claude", vendor: nil)
        defer { d3.removePersistentDomain(forName: n3) }
        XCTAssertEqual(neither.vendor, .codex)
        XCTAssertEqual(AIVendorStatus(settings: neither, vendor: .claude).label, "설치 필요")
        XCTAssertEqual(AIVendorStatus(settings: both, vendor: .claude).label, "설치됨")
    }
}

@MainActor enum VendorFixture {
    static func claude(_ effort: ClaudeEffort) -> AppSettings.ConnectionVerification {
        .init(catalog: nil, result: .success(.init(provider: "claude", model: "sonnet", reasoningEffort: effort.rawValue)), modelName: "Sonnet 5.5")
    }
}
