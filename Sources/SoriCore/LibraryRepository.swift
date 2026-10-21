import Foundation

/// Plain, portable folders. Metadata is replaced atomically; original audio is never overwritten.
public final class LibraryRepository {
    public let root: URL
    public private(set) var projectLocations: [UUID: URL] = [:]
    public private(set) var recordingLocations: [UUID: URL] = [:]
    public private(set) var warnings: [String] = []
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private let decoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func load() throws -> (projects: [Project], recordings: [Recording]) {
        warnings = []; projectLocations = [:]; recordingLocations = [:]
        var projects: [Project] = [], recordings: [Recording] = []
        for folder in try directories(in: root) {
            let metadata = folder.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: metadata.path) else { continue }
            do {
                let project = try decoder.decode(Project.self, from: Data(contentsOf: metadata))
                guard projectLocations[project.id] == nil else { throw SoriError.message("중복 프로젝트 식별자") }
                projects.append(project); projectLocations[project.id] = folder
                for session in try directories(in: folder) {
                    let path = session.appendingPathComponent("recording.json")
                    guard fm.fileExists(atPath: path.path) else { continue }
                    do {
                        var recording = try decoder.decode(Recording.self, from: Data(contentsOf: path))
                        guard recordingLocations[recording.id] == nil else { throw SoriError.message("중복 녹음 식별자") }
                        let parentChanged = recording.projectID != project.id
                        recording.projectID = project.id
                        var needsRecovery = parentChanged
                        if recording.status == .recording || recording.status.isProcessing {
                            recording.status = recording.segments.isEmpty ? .queued : recording.completedStatus
                            recording.message = "이전 작업이 중단되었습니다. 저장된 오디오로 다시 전사할 수 있습니다."
                            needsRecovery = true
                        }
                        if needsRecovery {
                            // Readable recordings remain visible even when the volume is full or read-only.
                            do { try write(recording, to: path) }
                            catch { warnings.append("\(session.lastPathComponent): 복구 상태를 저장하지 못했습니다. \(error.localizedDescription)") }
                        }
                        recordings.append(recording); recordingLocations[recording.id] = session
                    } catch { warnings.append("\(session.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { warnings.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
        }
        return (projects.sorted { $0.createdAt < $1.createdAt }, recordings.sorted { $0.createdAt > $1.createdAt })
    }

    public func createProject(name: String) throws -> Project {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SoriError.message("폴더 이름을 입력해 주세요.") }
        let project = Project(name: clean)
        let folder = root.appendingPathComponent("\(Self.safeName(clean))--\(project.id.uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try write(project, to: folder.appendingPathComponent("project.json")) }
        catch { try? fm.removeItem(at: folder); throw error }
        projectLocations[project.id] = folder
        return project
    }

    public func renameProject(_ project: Project, to name: String) throws -> Project {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let old = projectLocations[project.id] else { throw SoriError.message("폴더를 찾을 수 없습니다.") }
        var copy = project; copy.name = clean
        let new = root.appendingPathComponent("\(Self.safeName(clean))--\(project.id.uuidString.prefix(8))", isDirectory: true)
        if old != new { try fm.moveItem(at: old, to: new) }
        do { try write(copy, to: new.appendingPathComponent("project.json")) }
        catch { if old != new { try? fm.moveItem(at: new, to: old) }; throw error }
        projectLocations[project.id] = new
        for (id, path) in recordingLocations where path.deletingLastPathComponent() == old {
            recordingLocations[id] = new.appendingPathComponent(path.lastPathComponent)
        }
        return copy
    }

    public func createRecording(project: Project, title: String) throws -> Recording {
        guard let parent = projectLocations[project.id] else { throw SoriError.message("작업 폴더가 없습니다.") }
        let recording = Recording(projectID: project.id, title: title)
        let stamp = ISO8601DateFormatter().string(from: recording.createdAt).replacingOccurrences(of: ":", with: "-")
        let folder = parent.appendingPathComponent("\(stamp)--\(recording.id.uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try write(recording, to: folder.appendingPathComponent("recording.json")) }
        catch { try? fm.removeItem(at: folder); throw error }
        recordingLocations[recording.id] = folder
        return recording
    }

    public func save(_ recording: Recording) throws {
        guard let folder = recordingLocations[recording.id] else { throw SoriError.message("녹음 폴더가 없습니다.") }
        try write(recording, to: folder.appendingPathComponent("recording.json"))
    }

    /// Keep an earlier transcript, including manual edits, before publishing an empty result.
    /// A failed backup must leave the current transcript intact.
    public func archiveTranscript(_ recording: Recording) throws {
        guard !recording.segments.isEmpty else { return }
        let history = try directory(for: recording).appendingPathComponent("transcript-history", isDirectory: true)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        var previous = recording
        previous.status = .ready
        let identifier = UUID().uuidString
        try write(previous, to: history.appendingPathComponent("\(identifier).json"))
        let correction = try directory(for: recording).appendingPathComponent("codex-corrections.json")
        if fm.fileExists(atPath: correction.path) {
            try fm.moveItem(at: correction, to: history.appendingPathComponent("\(identifier)-corrections.json"))
        }
    }

    public func directory(for recording: Recording) throws -> URL {
        guard let folder = recordingLocations[recording.id] else { throw SoriError.message("녹음 폴더가 없습니다.") }
        return folder
    }

    public func audioURL(for recording: Recording) throws -> URL {
        let name = recording.audioFileName ?? "audio.wav"
        guard ["audio.wav", "audio-recovered.wav"].contains(name) else { throw SoriError.message("녹음 파일 경로를 확인해 주세요.") }
        return try directory(for: recording).appendingPathComponent(name)
    }

    public func move(_ recording: Recording, to project: Project) throws -> Recording {
        let old = try directory(for: recording)
        guard let parent = projectLocations[project.id] else { throw SoriError.message("대상 폴더가 없습니다.") }
        if recording.projectID == project.id { return recording }
        let new = parent.appendingPathComponent(old.lastPathComponent)
        try fm.moveItem(at: old, to: new)
        var copy = recording; copy.projectID = project.id
        do { try write(copy, to: new.appendingPathComponent("recording.json")) }
        catch { try? fm.moveItem(at: new, to: old); throw error }
        recordingLocations[recording.id] = new
        return copy
    }

    public func trash(_ recording: Recording) throws {
        try fm.trashItem(at: directory(for: recording), resultingItemURL: nil)
        recordingLocations[recording.id] = nil
    }

    public func removeEmptyProject(_ project: Project) throws {
        guard let folder = projectLocations[project.id] else { return }
        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard contents.allSatisfy({ $0.lastPathComponent == "project.json" || $0.lastPathComponent == ".DS_Store" }) else {
            throw SoriError.message("폴더 안에 녹음 또는 다른 파일이 있습니다. Finder에서 확인한 뒤 비워 주세요.")
        }
        try fm.trashItem(at: folder, resultingItemURL: nil)
        projectLocations[project.id] = nil
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws { try encoder.encode(value).write(to: url, options: .atomic) }
    private func directories(in url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
    public static func safeName(_ name: String) -> String {
        let value = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !value.isEmpty else { return "폴더" }
        // APFS limits components by UTF-8 bytes; a character count fails for emoji names.
        var result = ""
        for character in value.prefix(70) {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "폴더" : result
    }
}
