import Foundation

/// Product choices, in preference order. The catalog must list a choice before
/// the app uses it; discovery alone does not guarantee execution access or quota.
public enum CodexModel: String, Codable, Sendable, CaseIterable {
    case sol = "gpt-6.1-sol"
    case luna = "gpt-6-luna"

    public static let reasoningEffort = "medium"
    public var displayName: String { self == .sol ? "GPT-6.1 Sol" : "GPT-6 Luna" }
}
