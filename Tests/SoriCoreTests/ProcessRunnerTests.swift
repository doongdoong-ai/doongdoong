import XCTest
@testable import SoriCore

final class ProcessRunnerTests: XCTestCase {
    func testOptInEnvironmentFilteringRemovesKeyAndOverridesValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("output.txt")
        try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s|%s' \"${USER-unset}\" \"$BUNGBUNGI_TEST_VALUE\""],
            directory: directory, log: log, environmentOverrides: ["BUNGBUNGI_TEST_VALUE": "정상"],
            removingEnvironmentKeys: ["USER"])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "unset|정상")
    }

    func testInputDoesNotExecuteShellMetacharacters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("output.txt")
        let input = "한국어\n$(touch should-not-exist) `echo danger`\n"
        try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], directory: directory, log: log, input: input)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".stdin-") })
    }

    func testSuccessCleansInputBeforeReturningAndAllowsImmediateReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner()
        let log = directory.appendingPathComponent("output.txt")

        for index in 0..<10 {
            let input = "연속 실행 \(index)\n"
            try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], directory: directory, log: log, input: input)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".stdin-") },
                           "Input cleanup must finish before run returns")
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), input)
        }
    }

    func testCancellationTerminatesChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ProcessRunner()
        let start = Date()
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: directory, log: directory.appendingPathComponent("output.txt"))
        }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellationAlsoStopsCLIWrapperDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("output.txt")
        let task = Task {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!; wait"], directory: directory, log: log)
        }
        try await Task.sleep(for: .milliseconds(200))
        let pid = try XCTUnwrap(Int32(String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotEqual(kill(pid, 0), 0, "The wrapper's child must not keep running")
    }

    func testFailureIncludesBoundedLogTailAndCleansInputFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = String(repeating: "진행 로그 ", count: 100_000) + "최종 오류의 원인"
        do {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; exit 7"], directory: directory, log: directory.appendingPathComponent("output.txt"), input: input)
            XCTFail("Expected nonzero exit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("최종 오류의 원인"))
            XCTAssertTrue(error.localizedDescription.contains("(7)"))
            XCTAssertLessThan(error.localizedDescription.count, 1800)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".stdin-") })
    }

    func testTimeoutTerminatesProcessAndReportsRetryableError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sori-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        do {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: directory, log: directory.appendingPathComponent("output.txt"), timeout: 0.15)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("처리 시간이 초과")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
