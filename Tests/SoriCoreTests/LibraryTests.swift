import XCTest
@testable import SoriCore

final class LibraryTests: XCTestCase {
    func testRecordingModesRemainCompatibleWithOlderLibraries() throws {
        let legacy = Recording(projectID: UUID(), title: "기존 녹음")
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("recordingMode"))
        XCTAssertFalse(try JSONDecoder().decode(Recording.self, from: data).recordsAudioOnly)

        var audio = legacy
        audio.recordingMode = .audioOnly; audio.status = .saved
        var restored = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(audio))
        XCTAssertTrue(restored.recordsAudioOnly)
        XCTAssertFalse(restored.recoverInterruptedWork())
        XCTAssertEqual(restored.status, .saved); XCTAssertNil(restored.work)
    }

    func testSummaryRetryIntentAndExistingEditsSurviveRepeatedLaunches() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "강의")
        var item = try repo.createRecording(project: project, title: "사용자 제목")
        item.status = .polishing; item.notes = "작성 중이던 메모"
        item.segments = [.init(id: 7, start: 2, end: 3, text: "직접 수정한 문장", originalText: "원문")]
        item.work = .init(kind: .summary, state: .running, step: .summary)
        try repo.save(item)
        for _ in 0..<2 {
            let loaded = try XCTUnwrap(LibraryRepository(root: root).load().recordings.first)
            XCTAssertEqual(loaded.work?.kind, .summary)
            XCTAssertEqual(loaded.work?.state, .interrupted)
            XCTAssertEqual(loaded.work?.cause, .unexpected)
            XCTAssertEqual(loaded.work?.requestedAt.timeIntervalSince1970 ?? 0, item.work!.requestedAt.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(loaded.segments, item.segments)
            XCTAssertEqual(loaded.notes, item.notes)
        }
    }

    func testQueuedWorkIsRecoverableAndRecoveredPathStaysInsideRecording() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "복구")
        var item = try repo.createRecording(project: project, title: "대기 중")
        item.work = .init(kind: .transcription)
        item.audioFileName = "audio-local-recovered.wav"
        try repo.save(item)
        let loaded = try XCTUnwrap(repo.load().recordings.first)
        XCTAssertEqual(loaded.work?.state, .interrupted)
        XCTAssertEqual(try repo.audioURL(for: loaded).lastPathComponent, "audio-local-recovered.wav")
        for path in ["../audio-local-recovered.wav", "/tmp/audio.wav", "unrelated.wav"] {
            item.audioFileName = path
            XCTAssertThrowsError(try repo.audioURL(for: item))
        }
    }
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("sori-test-\(UUID().uuidString)") }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }

    func testMoveAndRenameKeepAudioAndMetadataTogether() throws {
        let repo = try LibraryRepository(root: root)
        let first = try repo.createProject(name: "회의")
        let second = try repo.createProject(name: "인터뷰")
        var item = try repo.createRecording(project: first, title: "기획 회의")
        item.notes = "결정한 내용"; item.bookmarks = [.init(time: 1.25, label: "중요")]
        try repo.save(item)
        let audio = Data([1, 2, 3, 4]); try audio.write(to: repo.audioURL(for: item))
        let moved = try repo.move(item, to: second)
        _ = try repo.renameProject(second, to: "고객 / 인터뷰")
        XCTAssertEqual(try Data(contentsOf: repo.audioURL(for: moved)), audio)
        let loaded = try LibraryRepository(root: root).load()
        XCTAssertEqual(loaded.recordings.count, 1)
        XCTAssertEqual(loaded.recordings[0].projectID, second.id)
        XCTAssertEqual(loaded.recordings[0].notes, "결정한 내용")
        XCTAssertEqual(loaded.recordings[0].bookmarks[0].time, 1.25)
        XCTAssertTrue(loaded.projects.contains { $0.name == "고객 / 인터뷰" })
    }

    func testInterruptedWorkCanBeRetriedWithoutLosingAudioOrTranscript() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "복구")
        var pending = try repo.createRecording(project: project, title: "진행 중")
        pending.status = .transcribing; try repo.save(pending)
        var polished = try repo.createRecording(project: project, title: "보정 중")
        polished.status = .polishing; polished.segments = [.init(id: 0, start: 0, end: 1, text: "원본")]; try repo.save(polished)
        let loaded = try LibraryRepository(root: root).load().recordings
        XCTAssertEqual(loaded.first { $0.id == pending.id }?.status, .queued)
        XCTAssertEqual(loaded.first { $0.id == polished.id }?.status, .ready)
        XCTAssertEqual(loaded.first { $0.id == polished.id }?.segments[0].text, "원본")
    }

    func testInvalidMetadataAndSymlinksCannotEscapeTheLibrary() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "../../외부:폴더")
        let location = try XCTUnwrap(repo.projectLocations[project.id])
        XCTAssertEqual(location.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: location)
        let result = try repo.load()
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(repo.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.appendingPathComponent("project.json").path))
    }

    func testNonEmptyFolderCannotBeDeleted() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "보관")
        _ = try repo.createRecording(project: project, title: "유지")
        XCTAssertThrowsError(try repo.removeEmptyProject(project))
        XCTAssertEqual(try repo.load().recordings.count, 1)
    }

    func testLooseFilesAndHiddenFilesPreventDeletingProject() throws {
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "직접 보관한 파일")
        let directory = try XCTUnwrap(repo.projectLocations[project.id])
        let attachment = directory.appendingPathComponent(".private-notes.txt")
        try Data("사용자가 보관한 메모".utf8).write(to: attachment)
        XCTAssertThrowsError(try repo.removeEmptyProject(project))
        XCTAssertEqual(try String(contentsOf: attachment, encoding: .utf8), "사용자가 보관한 메모")
    }

    func testEmojiProjectNamesRespectFilesystemByteLimit() throws {
        let repo = try LibraryRepository(root: root)
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 70)
        let project = try repo.createProject(name: name)
        let folder = try XCTUnwrap(repo.projectLocations[project.id])
        XCTAssertLessThanOrEqual(folder.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try repo.load().projects.first?.name, name)
        _ = try repo.renameProject(project, to: String(repeating: "🇰🇷", count: 70))
        XCTAssertEqual(try repo.load().projects.count, 1)
    }

    func testRecoveryOnReadOnlyDirectoryKeepsRecordingVisible() throws {
        guard getuid() != 0 else { throw XCTSkip("Root bypasses directory write permissions") }
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "복구")
        var item = try repo.createRecording(project: project, title: "예상치 못한 종료")
        item.status = .transcribing
        try repo.save(item)
        let directory = try repo.directory(for: item)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let loaded = try repo.load()
        XCTAssertEqual(loaded.recordings.count, 1, "A failed recovery save must not hide readable audio metadata")
        XCTAssertEqual(loaded.recordings.first?.status, .queued)
        XCTAssertTrue(repo.warnings.contains { $0.contains("복구 상태를 저장하지 못했습니다") })
    }

    func testRecordingCreationFailureLeavesNoPhantomLocation() throws {
        guard getuid() != 0 else { throw XCTSkip("Root bypasses directory write permissions") }
        let repo = try LibraryRepository(root: root)
        let project = try repo.createProject(name: "저장 실패")
        let directory = try XCTUnwrap(repo.projectLocations[project.id])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try repo.createRecording(project: project, title: "저장할 수 없음"))
        XCTAssertTrue(repo.recordingLocations.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["project.json"])
    }
}
