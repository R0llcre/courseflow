import XCTest
@testable import CourseflowCore

final class StudyCatalogTests: XCTestCase {
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func catalog() throws -> StudyCatalog {
        let url = root.appendingPathComponent("App/Resources/course-library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("本机课程资料目录未提供") }
        return try JSONDecoder().decode(StudyCatalog.self, from: Data(contentsOf: url))
    }

    func testEveryResourceResolvesAndEachCourseHasReadableMaterial() throws {
        let catalog = try catalog()
        try catalog.validate()
        XCTAssertEqual(catalog.courses.count, 7)
        for course in catalog.courses {
            XCTAssertFalse(catalog.resources(for: course.id).filter(\.isOffline).isEmpty)
        }
        for resource in catalog.resources {
            for filename in [resource.originalFile, resource.previewFile, resource.thumbnailFile].compactMap({ $0 }) {
                let url = root.appendingPathComponent("App/Resources/StudyFiles").appendingPathComponent(filename)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), filename)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0, filename)
            }
            if resource.isOffline { XCTAssertNotEqual(resource.format, "link") }
            else { XCTAssertNotNil(SafeLink.url(resource.sourceURL ?? "")) }
        }
    }

    func testNotebookFigureIsEmbeddedAndAllReaderLinksResolve() throws {
        let catalog = try catalog()
        let notebook = try XCTUnwrap(catalog.resources.first { $0.courseID == "nlp" && $0.format == "notebook" })
        let html = try String(contentsOf: root.appendingPathComponent("App/Resources/StudyFiles").appendingPathComponent(try XCTUnwrap(notebook.previewFile)), encoding: .utf8)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("src=\"A1_Data/f1.png\""))
        let ids = Set(catalog.resources.map(\.id))
        let expression = try NSRegularExpression(pattern: "courseflow-resource://(study-[a-z0-9]+)")
        for resource in catalog.resources where resource.previewFile?.hasSuffix(".html") == true {
            let content = try String(contentsOf: root.appendingPathComponent("App/Resources/StudyFiles").appendingPathComponent(resource.previewFile!), encoding: .utf8)
            let ns = content as NSString
            for match in expression.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                XCTAssertTrue(ids.contains(ns.substring(with: match.range(at: 1))))
            }
            XCTAssertFalse(content.contains("<script"), resource.title)
            XCTAssertFalse(content.contains("<iframe"), resource.title)
        }
    }

    func testSearchFindsTextInsideCourseDocumentsAndRespectsCategory() throws {
        let catalog = try catalog()
        XCTAssertFalse(catalog.resources(for: "dma", query: "cool_votes").isEmpty)
        XCTAssertTrue(catalog.resources(for: "dma", query: "cool_votes").allSatisfy { $0.courseID == "dma" })
        XCTAssertTrue(catalog.resources(for: "203", category: .work).allSatisfy { $0.category == .work })
        XCTAssertTrue(catalog.resources(for: "dma", query: "a phrase that does not occur anywhere 0928439").isEmpty)
    }

    func testPreparedLabFilesDoNotChangeSubmissionState() throws {
        let catalog = try catalog()
        XCTAssertTrue(catalog.resources(forTask: "dma-lab-1").contains { $0.format == "pdf" && $0.category == .work })
        XCTAssertTrue(catalog.resources(forTask: "dma-lab-1").contains { $0.format == "notebook" && $0.category == .work })
        let seed = try UpdateBundle.read(Data(contentsOf: root.appendingPathComponent("App/Resources/berkeley-fall-2026.json")))
        let library = try Library.initial(from: seed)
        let task = try XCTUnwrap(library.assignments.first { $0.id == "dma-lab-1" })
        XCTAssertFalse(library.isComplete(task))
        XCTAssertEqual(library.completedCount(task), 0)
    }

    func testMathAndLongDocumentNavigationWorkOffline() throws {
        let catalog = try catalog()
        let notebook = try XCTUnwrap(catalog.resources.first { $0.courseID == "ml" && $0.title == "fashion pt 1" })
        let html = try String(contentsOf: root.appendingPathComponent("App/Resources/StudyFiles").appendingPathComponent(try XCTUnwrap(notebook.previewFile)), encoding: .utf8)
        XCTAssertTrue(html.contains("<math"))
        XCTAssertFalse(html.contains("COURSEFLOWMATHTOKEN"))
        let malformedID = try NSRegularExpression(pattern: #"id="[^"]*<"#)
        XCTAssertEqual(malformedID.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)), 0)
        XCTAssertTrue(html.contains("class=\"toc\""))
        XCTAssertTrue(html.contains("href=\"#"))
        XCTAssertEqual(catalog.resources(for: "ml", category: .lecture).filter { $0.format == "pdf" }.count, 4)
    }

    func testIndependentAssignmentsHaveTheirOwnMaterials() throws {
        let catalog = try catalog()
        let survey = catalog.resources(forTask: "203-intro-survey")
        XCTAssertTrue(survey.contains { $0.title == "Week 1 (Intro Survey)" })
        XCTAssertFalse(catalog.resources(forTask: "203-week-1").contains { $0.title == "Week 1 (Intro Survey)" })
        XCTAssertFalse(catalog.resources(forTask: "203-week-2").contains { $0.title == "Week 2 Discussion" })
        XCTAssertTrue(catalog.resources(forTask: "203-discussion-2").contains { $0.title == "Week 2 Discussion" })
        XCTAssertFalse(catalog.resources(forTask: "ml-hw-1-part-1").contains { $0.title == "fashion pt 2" })
        XCTAssertFalse(catalog.resources(forTask: "ml-hw-1-part-2").contains { $0.title == "fashion pt 1" })
        XCTAssertTrue(catalog.resources(forTask: "dma-lab-1").contains { $0.format == "notebook" && $0.category == .assignment })
    }

    func testWithdrawnLocalLabPDFIsNotOfferedForSubmission() throws {
        let catalog = try catalog()
        XCTAssertFalse(catalog.resources.contains { $0.originalFile == "study-1d95ef6020dbad8e.pdf" })
        XCTAssertFalse(catalog.resources.contains { $0.originalFile == "study-a592c89b459d8965.ipynb" })
    }

    func testRequiredReadingsTemplatesAndTaskReferences() throws {
        let catalog = try catalog()
        let seed = try UpdateBundle.read(Data(contentsOf: root.appendingPathComponent("App/Resources/berkeley-fall-2026.json")))
        for resource in catalog.resources {
            for id in resource.taskIDs {
                let task = try XCTUnwrap(seed.assignments.first { $0.id == id }, resource.title)
                XCTAssertEqual(resource.courseID, task.courseID, resource.title)
            }
        }
        for id in ["c200-reading-1", "c200-reading-2"] {
            XCTAssertTrue(catalog.resources(forTask: id).contains {
                $0.category == .reading && $0.format == "pdf" && $0.title == "Introduction to Development Engineering 2023"
            })
        }
        XCTAssertTrue(catalog.resources(forTask: "c200-mou").contains { $0.title == "主模板" && $0.sourceURL != nil })
        let week2 = try XCTUnwrap(seed.assignments.first { $0.id == "203-week-2" })
        XCTAssertEqual(catalog.assignmentURL(for: week2)?.absoluteString, "https://bcourses.berkeley.edu/courses/1557602/assignments/9123328")
        let ml = try XCTUnwrap(seed.assignments.first { $0.id == "ml-hw-1-part-1" })
        XCTAssertEqual(catalog.assignmentURL(for: ml)?.absoluteString, ml.sourceURL)
        let discussion = catalog.resources(forTask: "203-discussion-2")
        for name in ["Crameri", "DataFeminism", "Tufte"] {
            XCTAssertTrue(discussion.contains { $0.title.contains(name) && $0.category == .reading })
        }
    }

    func testResourcePathsCannotEscapeTheBundle() {
        for filename in ["../secret.pdf", "/tmp/file.png", ".", "..", "a\\b", "https:file", ""] {
            XCTAssertFalse(StudyResource.validFilename(filename))
        }
        XCTAssertTrue(StudyResource.validFilename("study-1234-read.html"))
    }
}
