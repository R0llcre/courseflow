import XCTest
@testable import CourseflowCore

final class ExamScheduleTests: XCTestCase {
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func bundle() throws -> UpdateBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Updates/2026-09-21-期中考试-r13.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("本机课程更新包未提供") }
        return try UpdateBundle.read(Data(contentsOf: url))
    }
    func testDateOnlyDoesNotInventMidnightOrDuration() {
        let exam = ExamSchedule(day: "2026-10-14", timeNote: "待通知", locationNote: "待通知")
        XCTAssertNotNil(exam.dayDate)
        XCTAssertEqual(exam.timeLabel, "具体时间待通知")
        XCTAssertNil(exam.startsAt)
        XCTAssertNil(exam.endsAt)
        XCTAssertNil(ExamSchedule(day: "2026-02-30", timeNote: "", locationNote: "").dayDate)
        XCTAssertNil(ExamSchedule(day: "2026-1-2", timeNote: "", locationNote: "").dayDate)
    }
    func testCountdownUsesPacificCalendarAndKeepsDayVisible() {
        let exam = ExamSchedule(day: "2026-10-14", timeNote: "待通知", locationNote: "待通知")
        XCTAssertEqual(exam.countdown(now: date("2026-10-14T06:59:00Z")), "明天考试")
        XCTAssertEqual(exam.countdown(now: date("2026-10-14T07:00:00Z")), "今天考试")
        XCTAssertEqual(exam.countdown(now: date("2026-10-15T06:59:00Z")), "今天考试")
        XCTAssertEqual(exam.countdown(now: date("2026-10-15T07:00:00Z")), "考试日已过 · 待确认")
        XCTAssertEqual(exam.daysRemaining(now: date("2026-09-21T18:00:00Z")), 23)
        let dst = ExamSchedule(day: "2026-11-02", timeNote: "待通知", locationNote: "待通知")
        XCTAssertEqual(dst.daysRemaining(now: date("2026-11-01T07:00:00Z")), 1)
    }
    func testImportRoundTripKeepsAllThreeAndPreservesProgress() throws {
        let update = try bundle()
        var lib = Library()
        lib.progress["unrelated"] = TaskProgress(notes: "不要覆盖", attachments: [])
        let before = lib.progress
        try lib.apply(update)
        XCTAssertEqual(lib.progress, before)
        XCTAssertEqual(lib.sortedTasks(lib.assignments).map(\.id), ["nlp-midterm", "ml-midterm", "dma-midterm"])
        XCTAssertEqual(try Codec.decode(Library.self, from: Codec.encode(lib)), lib)
        let events = ScheduleCalendar.events(in: lib)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.kind == .exam })
        XCTAssertEqual(events.map { ScheduleCalendar.dayKey($0.date) }, ["2026-10-14", "2026-10-20", "2026-10-21"])
        XCTAssertEqual(lib.assignments.first { $0.id == "ml-midterm" }?.exam?.timeLabel, "17:00–18:30")
        XCTAssertFalse(lib.todayTasks(now: date("2026-09-21T18:00:00Z")).contains { $0.exam != nil })
        // Exams use the ordinary Today window; they remain in the full calendar outside it.
        XCTAssertEqual(lib.todayTasks(now: date("2026-10-07T18:00:00Z")).map(\.id), ["nlp-midterm"])
    }
    func testEndedCancelledAndConfirmedExamsLeavePendingList() throws {
        var lib = try Library.initial(from: bundle())
        lib.setFollowUpEnded(taskID: "nlp-midterm", ended: true)
        lib.assignments[lib.assignments.firstIndex { $0.id == "ml-midterm" }!].cancelled = true
        lib.confirm(taskID: "dma-midterm", deliveryID: "attend", complete: true)
        XCTAssertTrue(lib.todayTasks(now: date("2026-10-21T18:00:00Z")).isEmpty)
        XCTAssertEqual(lib.assignments.first { $0.id == "dma-midterm" }.map { lib.status($0) }, "已参加考试 · 评分待核实")
    }
    func testRejectsMixedDeadlineAndInvalidTimes() throws {
        var update = try bundle()
        update.assignments[0].dueAt = date("2026-10-14T07:00:00Z")
        XCTAssertThrowsError(try update.validate())
        update = try bundle()
        update.assignments[0].exam?.startsAt = date("2026-10-15T20:00:00Z")
        XCTAssertThrowsError(try update.validate())
        update = try bundle()
        update.assignments[0].exam?.endsAt = date("2026-10-14T20:00:00Z")
        XCTAssertThrowsError(try update.validate())
    }
    func testExamIsVisibleBeforeOtherEventsOnSameDay() throws {
        var lib = try Library.initial(from: bundle())
        var hw = lib.assignments[1]
        hw.id = "homework"
        hw.exam = nil
        hw.dueAt = date("2026-10-21T08:00:00Z")
        lib.assignments.append(hw)
        XCTAssertEqual(ScheduleCalendar.events(in: lib).filter { ScheduleCalendar.dayKey($0.date) == "2026-10-21" }.first?.kind, .exam)
    }
}
