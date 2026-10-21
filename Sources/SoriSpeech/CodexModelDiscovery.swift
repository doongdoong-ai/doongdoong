import Foundation
import SoriCore

/// Reads account/catalog metadata only. Never starts a model turn or asks for tokens.
@MainActor
public enum CodexModelDiscovery {
    public enum DiscoveryError: LocalizedError {
        case loginRequired, noSupportedModel, invalidCatalog
        public var errorDescription: String? {
            switch self {
            case .loginRequired: "ChatGPT 계정으로 로그인해 주세요."
            case .noSupportedModel: "현재 계정과 CLI에서 지원하는 AI를 찾지 못했습니다."
            case .invalidCatalog: "사용 가능한 AI 목록을 확인하지 못했습니다. 다시 연결해 주세요."
            }
        }
    }

    public static func resolve(executable: URL) async throws -> CodexModel {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-models-\(UUID().uuidString)")
        let client = CodexAppServerClient()
        defer {
            client.stop()
            try? FileManager.default.removeItem(at: workspace)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        try await client.start(executable: executable, workingDirectory: workspace)
        return try await discover { method, params in
            try await client.request(method: method, params: params, timeout: 20)
        }
    }

    static func discover(request: (String, [String: Any]) async throws -> [String: Any]) async throws -> CodexModel {
        try Task.checkCancellation()
        let account = try await request("account/read", ["refreshToken": false])
        guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
            throw DiscoveryError.loginRequired
        }
        var available: Set<CodexModel> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<10 {
            try Task.checkCancellation()
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("model/list", params)
            guard let entries = page["data"] as? [[String: Any]], entries.count <= 1000 else {
                throw DiscoveryError.invalidCatalog
            }
            for entry in entries {
                guard entry["hidden"] as? Bool != true,
                      let name = entry["model"] as? String,
                      let model = CodexModel(rawValue: name),
                      let efforts = entry["supportedReasoningEfforts"] as? [[String: Any]],
                      efforts.contains(where: { $0["reasoningEffort"] as? String == CodexModel.reasoningEffort }) else { continue }
                if let value = entry["inputModalities"] {
                    guard let modalities = value as? [String] else { throw DiscoveryError.invalidCatalog }
                    if !modalities.contains("text") { continue }
                }
                available.insert(model)
            }
            let next = page["nextCursor"]
            if next == nil || next is NSNull {
                try Task.checkCancellation()
                guard let chosen = CodexModel.allCases.first(where: { available.contains($0) }) else {
                    throw DiscoveryError.noSupportedModel
                }
                return chosen
            }
            guard let next = next as? String, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw DiscoveryError.invalidCatalog
            }
            cursor = next
        }
        throw DiscoveryError.invalidCatalog
    }
}
