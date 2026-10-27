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
    case heading, bold, italic, bullet, ordered, task, quote, code, highlight, strikethrough
    case indent, outdent, toggleTask, link, timestamp(String)
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
        case .highlight: return wrap("==", source: source, selection: selection)
        case .strikethrough: return wrap("~~", source: source, selection: selection)
        case .indent: return indentation(source: source, selection: selection, remove: false)
        case .outdent: return indentation(source: source, selection: selection, remove: true)
        case .link:
            let label = source.substring(with: selection)
            let replacement = "[\(label)](https://)"
            return .init(range: selection, replacement: replacement,
                         selection: NSRange(location: selection.location + (label as NSString).length + 3, length: 8))
        case .toggleTask:
            let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
            if let match = try? NSRegularExpression(pattern: #"^[ \t]*[-+*] \[([ xX])\] "#).firstMatch(in: text, range: line) {
                let mark = match.range(at: 1)
                return .init(range: mark, replacement: source.substring(with: mark) == " " ? "x" : " ", selection: selection)
            }
            return prefix("- [ ] ", source: source, selection: selection)
        case .timestamp(let value):
            let insertion = "[\(value)] "
            return .init(range: selection, replacement: insertion,
                         selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        case .heading: return prefix("## ", source: source, selection: selection)
        case .bullet: return prefix("- ", source: source, selection: selection)
        case .ordered: return prefix("1. ", source: source, selection: selection)
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
        let content = source.substring(with: selection)
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
        let pattern = marker.hasPrefix("#") ? #"^#{1,6} "# : marker == "> " ? #"^> "# : #"^(?:[-+*] (?:\[[ xX]\] )?|\d+[.)] )"#
        let parts = lines.map { line -> (indent: String, prefix: String, body: String) in
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = String(line.dropFirst(indent.count))
            let existing = content.range(of: pattern, options: .regularExpression).map { String(content[$0]) } ?? ""
            return (indent, existing, String(content.dropFirst(existing.count)))
        }
        let remove = parts.allSatisfy { $0.prefix == marker }
        let result = parts.map { $0.indent + (remove ? "" : marker) + $0.body }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let delta = (remove ? 0 : (marker as NSString).length) - ((parts.first?.prefix ?? "") as NSString).length

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

    private static func indentation(source: NSString, selection: NSRange, remove: Bool) -> MarkdownEdit {
        let range = source.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let value = source.substring(with: range)
        var lines = value.components(separatedBy: "\n")
        let trailing = value.hasSuffix("\n")
        if trailing { lines.removeLast() }
        var firstDelta = 0
        let changed = lines.enumerated().map { index, line -> String in
            let removed = line.hasPrefix("\t") ? 1 : min(4, line.prefix(while: { $0 == " " }).count)
            let delta = remove ? -removed : 4
            if index == 0 { firstDelta = delta }
            return remove ? String(line.dropFirst(removed)) : "    " + line
        }.joined(separator: "\n") + (trailing ? "\n" : "")
        let newSelection = selection.length == 0
            ? NSRange(location: max(range.location, selection.location + firstDelta), length: 0)
            : NSRange(location: range.location, length: (changed as NSString).length - (trailing ? 1 : 0))
        return .init(range: range, replacement: changed, selection: newSelection)
    }

    static func removeListPrefix(text: String, selection: NSRange) -> MarkdownEdit? {
        guard selection.length == 0, selection.location > 0, selection.location <= (text as NSString).length else { return nil }
        let source = text as NSString, line = (text as NSString).lineRange(for: selection)
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        guard before.range(of: #"^[ \t]*(?:[-+*] (?:\[[ xX]\] )?|\d+[.)] |> )$"#, options: .regularExpression) != nil else { return nil }
        if before.hasPrefix("    ") || before.hasPrefix("\t") { return indentation(source: source, selection: selection, remove: true) }
        return .init(range: NSRange(location: line.location, length: (before as NSString).length), replacement: "", selection: NSRange(location: line.location, length: 0))
    }
}
