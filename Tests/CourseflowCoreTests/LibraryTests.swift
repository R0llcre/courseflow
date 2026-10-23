import XCTest
@testable import CourseflowCore

final class LibraryTests: XCTestCase {
    func seed() throws -> UpdateBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Resources/berkeley-fall-2026.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("本机课程基线未提供") }
        return try UpdateBundle.read(Data(contentsOf: url))
    }

    func next(_ bundle: UpdateBundle) -> UpdateBundle {
        var update = bundle
        update.revision += 1
        update.generatedAt = bundle.generatedAt.addingTimeInterval(3600)
        return update
    }

    func testEndingFollowUpDoesNotInventSubmission() throws {
        var library = try Library.initial(from: seed())
        let task = try XCTUnwrap(library.assignments.first { $0.id == "c200-reading-1" })
        let reply = try XCTUnwrap(task.deliveries.first { $0.id == "reply" })
        let now = task.checkedAt.addingTimeInterval(86400 * 3)
        library.setFollowUpEnded(taskID: task.id, ended: true, at: now)
        XCTAssertFalse(library.isComplete(reply, in: task))
        XCTAssertFalse(library.isComplete(task))
        XCTAssertTrue(library.isEnded(task))
        XCTAssertEqual(library.status(task), "已结束 · 4 / 5")
        XCTAssertFalse(library.todayTasks(now: now).contains { $0.id == task.id })
        library.setFollowUpEnded(taskID: task.id, ended: false)
        XCTAssertFalse(library.isEnded(task))
        XCTAssertTrue(library.todayTasks(now: now).contains { $0.id == task.id })
    }

    func testEndedStateSurvivesPersistenceAndCourseUpdates() throws {
        let initial = try seed()
        var library = try Library.initial(from: initial)
        library.setFollowUpEnded(taskID: "c200-reading-1", ended: true, at: initial.generatedAt)
        let saved = library.progress
        library = try Codec.decode(Library.self, from: Codec.encode(library))
        try library.apply(next(initial))
        XCTAssertEqual(library.progress, saved)
        XCTAssertNotNil(library.progress["c200-reading-1"]?.endedAt)
    }

    func testOldPersonalRecordDecodesWithoutEndedDate() throws {
        let data = Data(#"{"confirmations":{},"notes":"保留笔记","attachments":[]}"#.utf8)
        let progress = try Codec.decode(TaskProgress.self, from: data)
        XCTAssertNil(progress.endedAt)
        XCTAssertEqual(progress.notes, "保留笔记")
    }

    func testBundledSnapshotIsValidAndComplete() throws {
        let bundle = try seed()
        XCTAssertEqual(bundle.courses.count, 7)
        XCTAssertEqual(bundle.assignments.count, 21)
        let library = try Library.initial(from: bundle)
        XCTAssertEqual(library.assignments.count, 21)
        XCTAssertEqual(library.notices.count, 1)
        XCTAssertEqual(library.revision, 1)
    }

    func testQuestionnaireIsUserConfirmedNotOfficiallyVerified() throws {
        let library = try Library.initial(from: seed())
        let task = try XCTUnwrap(library.assignments.first { $0.id == "c200-project-preference" })
        XCTAssertTrue(library.isComplete(task))
        XCTAssertEqual(library.status(task), "用户确认已交 · 评分待核实")
    }

    func testGradeDoesNotCompleteMissingReply() throws {
        let library = try Library.initial(from: seed())
        let task = try XCTUnwrap(library.assignments.first { $0.id == "c200-reading-1" })
        XCTAssertEqual(task.grade, "4 / 5")
        XCTAssertEqual(library.completedCount(task), 1)
        XCTAssertFalse(library.isComplete(task))
    }

    func testSubmittedWorkRemainsInAssessmentFollowUpButNotOverdue() throws {
        var library = try Library.initial(from: seed())
        var task = try XCTUnwrap(library.assignments.first { $0.id == "dma-lab-1" })
        task.deliveries = task.deliveries.map { var d = $0; d.evidence = .submitted; return d }
        task.assessment = Assessment(state: .awaiting, checkedAt: task.checkedAt, sourceURL: task.sourceURL, note: "尚未出分")
        library.assignments = [task]
        XCTAssertTrue(library.isComplete(task))
        XCTAssertFalse(library.isResolved(task))
        XCTAssertTrue(library.needsAssessmentFollowUp(task))
        XCTAssertFalse(library.needsSubmission(task))
        XCTAssertTrue(library.todayTasks(now: task.checkedAt.addingTimeInterval(86400 * 10)).isEmpty)
        XCTAssertEqual(library.status(task), "已提交 · 待评分")
    }

    func testPartialGradeCannotBeReviewedAsFinal() throws {
        var library = try Library.initial(from: seed())
        var task = library.assignments[0]
        task.assessment = Assessment(state: .partial, checkedAt: task.checkedAt, sourceURL: task.sourceURL, note: "简答未批")
        task.grade = "2 / 3"
        library.assignments = [task]
        library.reviewAssessment(taskID: task.id, reviewed: true)
        XCTAssertFalse(library.hasReviewedAssessment(task))
        XCTAssertFalse(library.isResolved(task))
    }

    func testGradeReviewPersistsAndNewFeedbackReopensFollowUp() throws {
        var library = try Library.initial(from: seed())
        var task = library.assignments[0]
        task.assessment = Assessment(state: .graded, checkedAt: task.checkedAt, sourceURL: task.sourceURL, note: "已评分")
        task.grade = "1 / 1"
        library.assignments = [task]
        XCTAssertFalse(library.isResolved(task))
        library.reviewAssessment(taskID: task.id, reviewed: true, at: task.checkedAt)
        XCTAssertTrue(library.isResolved(task))
        library = try Codec.decode(Library.self, from: Codec.encode(library))
        task.assessment?.checkedAt = task.checkedAt.addingTimeInterval(60)
        XCTAssertTrue(library.hasReviewedAssessment(task))
        task.feedback = "请修改引用"
        XCTAssertFalse(library.hasReviewedAssessment(task))
        XCTAssertTrue(library.needsAssessmentFollowUp(task))
    }

    func testOlderGradingCannotOverwriteNewerEvidence() throws {
        var bundle = try seed()
        bundle.assignments[0].assessment = Assessment(state: .graded, checkedAt: bundle.generatedAt, sourceURL: bundle.assignments[0].sourceURL, note: "已批")
        bundle.assignments[0].grade = "1 / 1"
        var library = try Library.initial(from: bundle)
        var update = next(bundle)
        update.assignments[0].assessment = nil
        update.assignments[0].grade = nil
        try library.apply(update)
        XCTAssertEqual(library.assignments[0].grade, "1 / 1")
        XCTAssertEqual(library.assignments[0].gradingState, .graded)
    }

    func testWorkspacePathConfinement() {
        let root = URL(fileURLWithPath: "/tmp/courseflow-test-root")
        XCTAssertNil(WorkspaceLayout.resolve("../private", under: root))
        XCTAssertNil(WorkspaceLayout.resolve("/etc/passwd", under: root))
        XCTAssertNil(WorkspaceLayout.resolve("a//b", under: root))
        XCTAssertNil(WorkspaceLayout.resolve("a/./b", under: root))
        XCTAssertNotNil(WorkspaceLayout.resolve("DEVENG 203/Week2.pdf", under: root))
    }

    func testUnknownPensiveStateIsNotInventedAsNoSubmission() throws {
        let library = try Library.initial(from: seed())
        let task = try XCTUnwrap(library.assignments.first { $0.id == "ml-hw-1-part-1" })
        XCTAssertEqual(library.status(task), "提交状态待核实")
    }

    func testBothLabDeliveriesRequiredAndUndoWorks() throws {
        var library = try Library.initial(from: seed())
        let task = try XCTUnwrap(library.assignments.first { $0.id == "dma-lab-1" })
        library.confirm(taskID: task.id, deliveryID: "pdf", complete: true)
        XCTAssertEqual(library.completedCount(task), 1)
        XCTAssertFalse(library.isComplete(task))
        library.confirm(taskID: task.id, deliveryID: "ipynb", complete: true)
        XCTAssertTrue(library.isComplete(task))
        library.confirm(taskID: task.id, deliveryID: "pdf", complete: false)
        XCTAssertFalse(library.isComplete(task))
    }

    func testImportedUpdatesPreserveProgressNotesPlanAttachments() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        library.confirm(taskID: "dma-lab-1", deliveryID: "pdf", complete: true)
        library.progress["dma-lab-1"]?.notes = "自己写的笔记"
        library.progress["dma-lab-1"]?.plannedAt = .now
        library.progress["dma-lab-1"]?.attachments = [Attachment(id: "a", name: "材料.pdf", storedName: "a.pdf", addedAt: .now)]
        let original = library.progress
        var update = next(bundle)
        update.assignments[2].dueAt = bundle.assignments[2].dueAt?.addingTimeInterval(3600)
        try library.apply(update)
        XCTAssertEqual(library.progress, original)
        XCTAssertEqual(library.assignments[2].dueAt, update.assignments[2].dueAt)
        XCTAssertTrue(library.notices.contains { $0.detail.contains("正式截止") })
    }

    func testExplicitUserUncheckSurvivesNewOfficialEvidence() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        library.confirm(taskID: "dma-lab-1", deliveryID: "pdf", complete: false)
        var update = next(bundle)
        update.assignments[2].deliveries[0].evidence = .submitted
        try library.apply(update)
        XCTAssertFalse(library.isComplete(library.assignments[2].deliveries[0], in: library.assignments[2]))
    }

    func testDuplicateImportIsNoOp() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        let before = library
        XCTAssertTrue(try library.preview(bundle).isDuplicate)
        try library.apply(bundle)
        XCTAssertEqual(library, before)
    }

    func testSameRevisionDifferentContentRejectedAtomically() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        let original = library
        var altered = bundle
        altered.assignments[0].title = "不一致的内容"
        XCTAssertThrowsError(try library.apply(altered))
        XCTAssertEqual(library, original)
    }

    func testOlderRevisionCannotDowngradeData() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        var update = next(bundle)
        update.revision = 4
        try library.apply(update)
        var old = next(bundle)
        old.revision = 3
        XCTAssertThrowsError(try library.apply(old))
        XCTAssertEqual(library.revision, 4)
    }

    func testOldSourceWithinNewBundleIsSkipped() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        var update = next(bundle)
        update.assignments[2].checkedAt = bundle.assignments[2].checkedAt.addingTimeInterval(-60)
        update.assignments[2].title = "旧源标题"
        XCTAssertEqual(try library.preview(update).skipped.count, 1)
        try library.apply(update)
        XCTAssertEqual(library.assignments[2].title, "Lab 1")
    }

    func testMissingTaskDoesNotMeanDelete() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        var update = next(bundle)
        update.assignments.removeAll()
        try library.apply(update)
        XCTAssertEqual(library.assignments.count, 21)
    }

    func testCancellationExplicitAndPreservesProgress() throws {
        let bundle = try seed()
        var library = try Library.initial(from: bundle)
        library.confirm(taskID: "dma-lab-1", deliveryID: "pdf", complete: true)
        let old = library.progress
        var update = next(bundle)
        update.assignments[2].cancelled = true
        try library.apply(update)
        XCTAssertEqual(library.status(library.assignments[2]), "已取消")
        XCTAssertEqual(library.progress, old)
        library.confirm(taskID: "dma-lab-1", deliveryID: "ipynb", complete: true)
        XCTAssertEqual(library.progress, old)
    }

    func testDuplicateIDsRejected() throws {
        var bundle = try seed()
        bundle.assignments.append(bundle.assignments[0])
        XCTAssertThrowsError(try bundle.validate())
    }

    func testDuplicateDeliveryIDsRejected() throws {
        var bundle = try seed()
        bundle.assignments[2].deliveries[1].id = "pdf"
        XCTAssertThrowsError(try bundle.validate())
    }

    func testForeignCollectionAndVersionRejected() throws {
        var bundle = try seed()
        bundle.schemaVersion = 99
        XCTAssertThrowsError(try bundle.validate())
        bundle.schemaVersion = 1
        bundle.collectionID = "other"
        XCTAssertThrowsError(try bundle.validate())
    }

    func testMissingCourseRejected() throws {
        var bundle = try seed()
        bundle.courses.removeFirst()
        XCTAssertThrowsError(try bundle.validate())
    }

    func testInvalidDatesRejected() throws {
        var bundle = try seed()
        bundle.assignments[2].closesAt = Date.distantPast
        XCTAssertThrowsError(try bundle.validate())
    }

    func testEmptyChecklistRejected() throws {
        var bundle = try seed()
        bundle.assignments[2].deliveries = []
        XCTAssertThrowsError(try bundle.validate())
    }

    func testUnsafeURLsAndReservedIDsRejected() throws {
        var bundle = try seed()
        bundle.assignments[2].sourceURL = "file:///etc/passwd"
        XCTAssertThrowsError(try bundle.validate())
        bundle = try seed()
        bundle.assignments[2].id = "local-collision"
        XCTAssertThrowsError(try bundle.validate())
        XCTAssertNil(SafeLink.url("javascript:alert(1)"))
        XCTAssertNil(SafeLink.url("https://user:password@example.com"))
        XCTAssertNotNil(SafeLink.url("https://bcourses.berkeley.edu"))
    }

    func testCorruptJSONRejected() throws {
        XCTAssertThrowsError(try UpdateBundle.read(Data("{broken".utf8)))
    }

    func testLibraryExportRoundTrip() throws {
        var library = try Library.initial(from: seed())
        library.confirm(taskID: "dma-lab-1", deliveryID: "pdf", complete: true)
        library.readNoticeIDs.insert("seed-feedback-c200-reading-1")
        // ISO timestamps intentionally have second precision.
        library.progress["dma-lab-1"]?.confirmations["pdf"]?.recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try Codec.decode(Library.self, from: Codec.encode(library)), library)
    }

    func testTodayRetainsOverdueAndSeparatesNoDueDate() throws {
        let library = try Library.initial(from: seed())
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-08T18:00:00Z"))
        let today = library.todayTasks(now: now)
        XCTAssertTrue(today.contains { $0.id == "c200-reading-1" })
        XCTAssertTrue(today.contains { $0.id == "dma-lab-1" })
        XCTAssertFalse(today.contains { $0.id == "c200-project-preference" })
        XCTAssertFalse(today.contains { $0.id == "shape-training" })
        let attendance = try XCTUnwrap(library.assignments.first { $0.id == "c200-attendance-2" })
        XCTAssertNil(attendance.dueAt)
        XCTAssertNotNil(attendance.closesAt)
        let reading = try XCTUnwrap(library.assignments.first { $0.id == "c200-reading-week-3" })
        XCTAssertNil(reading.actionDate)
    }

    func testPacificDateFormattingUsesDaylightSavingRules() throws {
        let formatter = ISO8601DateFormatter()
        XCTAssertTrue(CourseDate.format(try XCTUnwrap(formatter.date(from: "2026-09-09T19:00:00Z"))).contains("12:00"))
        XCTAssertTrue(CourseDate.format(try XCTUnwrap(formatter.date(from: "2026-12-09T20:00:00Z"))).contains("12:00"))
    }
}
