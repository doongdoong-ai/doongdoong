import XCTest
@testable import SoriSpeech

final class CodexClientTests: XCTestCase {
    private func helper(tool: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("rpc.py")
        let body = """
        import sys,json
        for line in sys.stdin:
            m=json.loads(line)
            if m.get('id') == 999:
                print(json.dumps({'method':'tool/finished','params':{'success':m.get('result',{}).get('success',False)}}),flush=True)
            elif m.get('method') == 'probe':
                print(json.dumps({'id':m['id'],'result':{}}),flush=True)
                print(json.dumps({'id':999,'method':'item/tool/call','params':{'tool':'\(tool)','arguments':{},'threadId':'fixture'}}),flush=True)
            elif 'id' in m:
                print(json.dumps({'id':m['id'],'result':{}}),flush=True)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("codex")
        let command = "#!/bin/sh\nexec /usr/bin/python3 -u '\(script.path)'\n"
        try command.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    @MainActor func testOnlyBoundTranscriptionToolCanRun() async throws {
        let (root, executable) = try helper(tool: "transcribe_recording")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = CodexAppServerClient()
        defer { client.stop() }
        let finished = expectation(description: "host tool result returned")
        var calls = 0
        client.onTranscriptionTool = { params in
            XCTAssertEqual(params["threadId"] as? String, "fixture")
            calls += 1
            return ["success": true, "contentItems": [["type": "inputText", "text": "saved"]]]
        }
        client.onNotification = { method, params in
            if method == "tool/finished" {
                XCTAssertEqual(params["success"] as? Bool, true)
                finished.fulfill()
            }
        }
        try await client.start(executable: executable, workingDirectory: root, transcription: true)
        _ = try await client.request(method: "probe", params: [:])
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testUnexpectedToolIsRefusedEvenInTranscriptionMode() async throws {
        let (root, executable) = try helper(tool: "shell")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = CodexAppServerClient()
        defer { client.stop() }
        let refused = expectation(description: "unrelated tool refused")
        client.onTranscriptionTool = { _ in XCTFail("Unexpected capability"); return [:] }
        client.onFailure = { _ in refused.fulfill() }
        try await client.start(executable: executable, workingDirectory: root, transcription: true)
        _ = try await client.request(method: "probe", params: [:])
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertFalse(client.isRunning)
    }
}
