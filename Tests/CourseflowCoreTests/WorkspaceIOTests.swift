import XCTest
@testable import CourseflowCore

@MainActor final class WorkspaceIOTests: XCTestCase {
    private func fixture() throws -> (URL, StudyCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(WorkspaceLayout.dataPath + "/预览缓存"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Course"), withIntermediateDirectories: true)
        let catalog = StudyCatalog(version: 1, generatedAt: "one", courses: [CourseGuide(id: "dma", summary: "", schedule: "", coverage: "", featuredIDs: [], folder: "Course")], resources: [])
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent(WorkspaceLayout.dataPath + "/course-library.json"))
        return (root, catalog)
    }

    func testRefreshActivationIsThrottledAndManualRequestsCoalesce() {
        var gate = WorkspaceRefreshGate()
        let time = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(gate.begin(force: false, now: time))
        for _ in 0..<50 { XCTAssertFalse(gate.begin(force: false, now: time)) }
        XCTAssertFalse(gate.finish(now: time))
        XCTAssertFalse(gate.begin(force: false, now: time.addingTimeInterval(59)))
        XCTAssertTrue(gate.begin(force: true, now: time))
        for _ in 0..<50 { XCTAssertFalse(gate.begin(force: true, now: time)) }
        XCTAssertTrue(gate.finish(now: time))
        XCTAssertTrue(gate.running)
        XCTAssertFalse(gate.finish(now: time))
        XCTAssertTrue(gate.begin(force: false, now: time.addingTimeInterval(60)))
    }

    func testImageCacheEnforcesCostCountAndLeastRecentUse() {
        var cache = BoundedCache<String, Int>(countLimit: 2, costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.cost, 8)
        cache.insert(4, for: "a", cost: 7)
        XCTAssertNil(cache.value(for: "c"))
        XCTAssertEqual(cache.cost, 7)
        cache.insert(5, for: "large", cost: 11)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.value(for: "large"))
    }

    func testThousandsOfThumbnailKeysCannotGrowCacheUnbounded() {
        var cache = BoundedCache<Int, Int>(countLimit: 160, costLimit: 1_000)
        for i in 0..<10_000 { cache.insert(i, for: i, cost: 12) }
        XCTAssertLessThanOrEqual(cache.count, 160)
        XCTAssertLessThanOrEqual(cache.cost, 1_000)
        XCTAssertEqual(cache.value(for: 9_999), 9_999)
    }

    func testCachedCatalogStillDiscoversNewFilesAndForcedReloadSeesManifest() async throws {
        let (root, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = WorkspaceReader()
        let access = WorkspaceAccess(root)
        let first = try await reader.scan(access, force: false)
        XCTAssertEqual(first.catalog.resources.count, 0)
        try Data("new original".utf8).write(to: root.appendingPathComponent("Course/new.txt"))
        let second = try await reader.scan(access, force: false)
        XCTAssertEqual(second.catalog.resources.count, 1)
        var next = catalog
        next.generatedAt = "two"
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent(WorkspaceLayout.dataPath + "/course-library.json"), options: .atomic)
        let third = try await reader.scan(access, force: true)
        XCTAssertEqual(third.catalog.generatedAt, "two")
        XCTAssertEqual(third.catalog.resources.count, 1)
    }

    func testCancelledScanNeverReturnsAnOldResult() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = WorkspaceReader()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.scan(WorkspaceAccess(root), force: true)
        }
        do { _ = try await task.value; XCTFail("Cancelled scan returned a result") }
        catch is CancellationError {} // Stale connection jobs must not install their result.
    }

    func testMissingWorkspacePreviewNeverFallsBackToBundledCopy() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: bundle.appendingPathComponent("old.html"))
        XCTAssertNotNil(StudyFileLocation(bundleRoot: bundle).cached("old.html"))
        XCTAssertNil(StudyFileLocation(access: WorkspaceAccess(root), bundleRoot: bundle).cached("old.html"))
    }

    func testReaderRejectsChangedMissingAndEscapingSources() throws {
        let (root, catalog) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Course/notes.txt")
        try Data("original".utf8).write(to: original)
        var item = try XCTUnwrap(catalog.discoveringFiles(under: root).resources.first)
        item.previewFile = "preview.html"
        let preview = root.appendingPathComponent(WorkspaceLayout.dataPath + "/预览缓存/preview.html")
        try Data("preview".utf8).write(to: preview)
        let location = StudyFileLocation(access: WorkspaceAccess(root), bundleRoot: nil)
        let attributes = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertFalse(location.originalHasChanged(item), "resource=\(item), resolved=\(String(describing: location.original(item))), size=\(String(describing: attributes.fileSize)), date=\(String(describing: attributes.contentModificationDate?.timeIntervalSince1970))")
        XCTAssertNotNil(location.preview(item))
        try Data("edited original".utf8).write(to: original)
        XCTAssertTrue(location.originalHasChanged(item))
        XCTAssertNil(location.preview(item))
        try FileManager.default.removeItem(at: original)
        XCTAssertNil(location.original(item))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(location.original(item))
        XCTAssertNil(location.cached("../outside"))
    }

    func testPendingUpdatesIgnoreMalformedOversizedAndEscapingFiles() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Berkeley 26Fall General/Courseflow/Updates")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seed = try LibraryTests().seed()
        try Codec.encode(seed).write(to: folder.appendingPathComponent("valid.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("broken.json"))
        try Data(repeating: 32, count: 10_000_001).write(to: folder.appendingPathComponent("large.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let result = try await WorkspaceReader().scan(WorkspaceAccess(root), force: true)
        XCTAssertEqual(result.updates.map(\.url.lastPathComponent), ["valid.json"])
        XCTAssertEqual(result.updates.first?.revision, seed.revision)
    }

    func testMirrorPreservesEveryProgressFieldAndDoesNotTouchOriginals() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var library = try Library.initial(from: LibraryTests().seed())
        var progress = TaskProgress()
        progress.notes = "keep my notes"
        progress.startedAt = Date(timeIntervalSince1970: 123)
        progress.endedAt = Date(timeIntervalSince1970: 456)
        progress.attachments = [Attachment(id: "one", name: "original", storedName: "one.pdf", addedAt: Date(timeIntervalSince1970: 789), workspacePath: "Course/original.txt")]
        library.progress[library.assignments[0].id] = progress
        library.readNoticeIDs = ["preserved"]
        let original = root.appendingPathComponent("Course/original.txt")
        try Data("do not alter".utf8).write(to: original)
        _ = try await WorkspacePublisher().publish(library, access: WorkspaceAccess(root), folders: ["dma": root.appendingPathComponent("Course")])
        let decoded = try Codec.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent(WorkspaceLayout.dataPath + "/当前资料与进度.json")))
        XCTAssertEqual(decoded.progress, library.progress)
        XCTAssertEqual(decoded.readNoticeIDs, library.readNoticeIDs)
        XCTAssertEqual(decoded.assignments, library.assignments)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "do not alter")
    }

    func testFailedMirrorDoesNotPublishNewCompletionSnapshot() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(WorkspaceLayout.dataPath + "/当前资料与进度.json")
        try Data("previous complete mirror".utf8).write(to: file)
        let library = try Library.initial(from: LibraryTests().seed())
        do {
            _ = try await WorkspacePublisher().publish(library, access: WorkspaceAccess(root), folders: ["dma": root.appendingPathComponent("Missing")])
            XCTFail("Missing destination should fail")
        } catch {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "previous complete mirror")
        }
    }
}
