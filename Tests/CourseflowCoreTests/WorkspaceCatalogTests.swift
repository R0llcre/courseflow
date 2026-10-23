import XCTest
@testable import CourseflowCore

final class WorkspaceCatalogTests: XCTestCase {
    func testDiscoveryIncludesCodeAndDataWithoutExecutingOrChangingProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Course/08_作业草稿/Lab2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["answer.py", "data.npy", "map.qgz", "notes.txt", "report.pdf", "model:1b.json"] {
            try Data("original".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let catalog = StudyCatalog(version: 1, generatedAt: "test", courses: [CourseGuide(id: "dma", summary: "", schedule: "", coverage: "", featuredIDs: [], folder: "Course")], resources: [])
        let result = try catalog.discoveringFiles(under: root)
        XCTAssertEqual(result.resources.count, 6)
        XCTAssertTrue(result.resources.allSatisfy { $0.category == .work && $0.fileRole == nil })
        XCTAssertEqual(Set(result.resources.map(\.id)), Set(try result.discoveringFiles(under: root).resources.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("answer.py")), Data("original".utf8))
    }

    func testChangedFileLosesOldPreviewAndVerifiedArchiveRole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Course"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Course/test.txt")
        try Data("new".utf8).write(to: file)
        var catalog = StudyCatalog(version: 1, generatedAt: "test", courses: [CourseGuide(id: "dma", summary: "", schedule: "", coverage: "", featuredIDs: [], folder: "Course")], resources: [])
        catalog = try catalog.discoveringFiles(under: root)
        catalog.resources[0].previewFile = "old.html"
        catalog.resources[0].fileRole = "submitted"
        catalog.resources[0].size = 99
        let refreshed = try catalog.discoveringFiles(under: root)
        XCTAssertNil(refreshed.resources[0].previewFile)
        XCTAssertNil(refreshed.resources[0].fileRole)
        XCTAssertEqual(refreshed.resources[0].size, 3)
    }
}
