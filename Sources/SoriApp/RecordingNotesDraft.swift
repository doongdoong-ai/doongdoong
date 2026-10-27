import Foundation
import Observation
import SoriCore

/// A draft belongs to one recording, not to the currently selected library item.
@Observable @MainActor
final class RecordingNotesDraft {
    let recordingID: UUID
    var text: String { didSet { if text != oldValue { scheduleSave() } } }
    private(set) var savedText: String
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: AppStore, recording: Recording) {
        self.store = store
        recordingID = recording.id
        text = recording.notes
        savedText = recording.notes
    }

    var isDirty: Bool { text != savedText }

    func synchronize(_ value: String) {
        guard !isDirty else { return }
        savedText = value
        text = value
    }

    func acknowledgeSave() {
        if !store.unsavedIDs.contains(recordingID),
           store.recordings.first(where: { $0.id == recordingID })?.notes == text {
            savedText = text
        }
    }

    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard isDirty else { return !store.unsavedIDs.contains(recordingID) }
        let value = text
        let saved = store.update(recordingID) { $0.notes = value }
        if saved { savedText = value }
        return saved
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard isDirty else { return }
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

enum MarkdownCommand {
    case heading, bold, italic, bullet, task, quote, code, timestamp(String)
}

struct MarkdownEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

/// All ranges use UTF-16, matching NSTextView (including Korean and emoji).
enum MarkdownEditing {
    static func edit(_ command: MarkdownCommand, text: String, selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, NSMaxRange(selection) <= source.length else { return nil }
        switch command {
        case .bold: return wrap("**", source: source, selection: selection)
        case .italic: return wrap("*", source: source, selection: selection)
        case .code: return wrap("`", source: source, selection: selection)
        case .timestamp(let value):
            let insertion = "[\(value)] "
            return .init(range: selection, replacement: insertion,
                         selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        case .heading: return prefix("## ", source: source, selection: selection)
        case .bullet: return prefix("- ", source: source, selection: selection)
        case .task: return prefix("- [ ] ", source: source, selection: selection)
        case .quote: return prefix("> ", source: source, selection: selection)
        }
    }

    private static func wrap(_ marker: String, source: NSString, selection: NSRange) -> MarkdownEdit {
        let length = (marker as NSString).length
        // Toggle a selection that is already enclosed, without changing its contents.
        if selection.location >= length, NSMaxRange(selection) + length <= source.length,
           source.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker {
            return .init(range: NSRange(location: selection.location - length, length: selection.length + 2 * length),
                         replacement: source.substring(with: selection),
                         selection: NSRange(location: selection.location - length, length: selection.length))
        }
        let content = selection.length == 0 ? "텍스트" : source.substring(with: selection)
        return .init(range: selection, replacement: marker + content + marker,
                     selection: NSRange(location: selection.location + length, length: (content as NSString).length))
    }

    private static func prefix(_ marker: String, source: NSString, selection: NSRange) -> MarkdownEdit {
        // A selection ending at the next line's beginning must not format that line.
        let covered = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = source.lineRange(for: covered)
        let value = source.substring(with: range)
        let trailingNewline = value.hasSuffix("\n")
        var lines = value.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        let remove = lines.allSatisfy { $0.hasPrefix(marker) }
        let result = lines.map { remove ? String($0.dropFirst(marker.count)) : marker + $0 }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let delta = remove ? -(marker as NSString).length : (marker as NSString).length
        let caret = max(range.location, min(range.location + (result as NSString).length, selection.location + delta))
        return .init(range: range, replacement: result,
                     selection: selection.length == 0 ? NSRange(location: caret, length: 0)
                        : NSRange(location: range.location, length: (result as NSString).length - (trailingNewline ? 1 : 0)))
    }

    static func newline(text: String, selection: NSRange) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.length == 0, selection.location != NSNotFound,
              selection.location >= 0, selection.location <= source.length else { return nil }
        let lineRange = source.lineRange(for: selection)
        let before = source.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
        let pattern = #"^(\s*)([-+*] \[[ xX]\] |[-+*] |\d+\. |> )(.*)$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return nil }
        let ns = before as NSString
        let indent = ns.substring(with: match.range(at: 1)), marker = ns.substring(with: match.range(at: 2))
        let body = ns.substring(with: match.range(at: 3))
        if body.isEmpty {
            return .init(range: NSRange(location: lineRange.location, length: (before as NSString).length),
                         replacement: "", selection: NSRange(location: lineRange.location, length: 0))
        }
        let next: String
        if marker.contains("[") { next = "- [ ] " }
        else if let number = Int(marker.dropLast(2)) { next = "\(number + 1). " }
        else { next = marker }
        let insertion = "\n" + indent + next
        return .init(range: selection, replacement: insertion,
                     selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }
}
