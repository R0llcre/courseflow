import XCTest
@testable import CourseflowCore

final class CalendarScheduleTests: XCTestCase {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func library() throws -> Library {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Resources/berkeley-fall-2026.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("本机课程基线未提供") }
        return try Library.initial(from: UpdateBundle.read(Data(contentsOf: url)))
    }
    func testMondayFirstMonthGrid() {
        let days = ScheduleCalendar.days(in: date("2026-09-15T12:00:00Z"))
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(Set(days).count, 35)
        XCTAssertEqual(ScheduleCalendar.dayKey(days[0]), "2026-08-31")
        XCTAssertEqual(ScheduleCalendar.dayKey(days[34]), "2026-10-04")
    }
    func testLeapYearAndYearNavigation() {
        let month = date("2028-02-20T12:00:00Z")
        XCTAssertTrue(ScheduleCalendar.days(in: month).contains { ScheduleCalendar.dayKey($0) == "2028-02-29" })
        XCTAssertEqual(ScheduleCalendar.dayKey(ScheduleCalendar.shiftMonth(date("2026-12-31T12:00:00Z"), by: 1)), "2027-01-01")
        XCTAssertEqual(ScheduleCalendar.dayKey(ScheduleCalendar.shiftMonth(date("2026-01-31T12:00:00Z"), by: 1)), "2026-02-01")
    }
    func testPacificDayBoundaryAndDST() {
        XCTAssertEqual(ScheduleCalendar.dayKey(date("2026-09-11T06:59:00Z")), "2026-09-10")
        let days = ScheduleCalendar.days(in: date("2026-11-15T12:00:00Z"))
        XCTAssertEqual(Set(days.map(ScheduleCalendar.dayKey)).count, 42)
        XCTAssertTrue(days.allSatisfy { ScheduleCalendar.calendar.component(.hour, from: $0) == 0 })
        XCTAssertEqual(ScheduleCalendar.label(date("2026-11-02T07:59:00Z"), format: "HH:mm"), "23:59")
    }
    func testDeadlineAndClosingRemainDistinct() throws {
        let lib = try library()
        let entries = ScheduleCalendar.events(in: lib).filter { $0.taskID == "c200-reading-1" }
        XCTAssertEqual(Set(entries.map(\.kind)), Set([.due, .closes]))
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        let attendance = ScheduleCalendar.events(in: lib).filter { $0.taskID == "c200-attendance-2" }
        XCTAssertEqual(attendance.map(\.kind), [.closes])
    }
    func testPlanIsSeparateAndCalendarDoesNotMutateProgress() throws {
        var lib = try library()
        lib.progress["dma-lab-1"] = TaskProgress(plannedAt: date("2026-09-09T17:00:00Z"))
        let before = lib
        let events = ScheduleCalendar.events(in: lib, courseID: "dma", query: "Lab 1")
        XCTAssertEqual(Set(events.map(\.kind)), Set([.due, .planned]))
        XCTAssertEqual(lib, before)
        XCTAssertTrue(events.allSatisfy { $0.taskID == "dma-lab-1" })
    }
    func testOpeningDatesOptInAndNoInventedDates() throws {
        let lib = try library()
        XCTAssertFalse(ScheduleCalendar.events(in: lib).contains { $0.kind == .opens })
        XCTAssertTrue(ScheduleCalendar.events(in: lib, includeOpening: true).contains { $0.kind == .opens })
        XCTAssertFalse(ScheduleCalendar.events(in: lib).contains { $0.taskID == "shape-training" })
    }
    func testPendingFilterIncludesAwaitingGradeButNotEnded() throws {
        var lib = try library()
        let i = lib.assignments.firstIndex { $0.id == "dma-lab-1" }!
        for d in lib.assignments[i].deliveries.indices { lib.assignments[i].deliveries[d].evidence = .submitted }
        lib.assignments[i].assessment = Assessment(state: .awaiting, checkedAt: lib.assignments[i].checkedAt, sourceURL: lib.assignments[i].sourceURL, note: "待评分")
        XCTAssertTrue(ScheduleCalendar.events(in: lib, pendingOnly: true).contains { $0.taskID == "dma-lab-1" })
        lib.setFollowUpEnded(taskID: "dma-lab-1", ended: true)
        XCTAssertFalse(ScheduleCalendar.events(in: lib, pendingOnly: true).contains { $0.taskID == "dma-lab-1" })
        XCTAssertTrue(ScheduleCalendar.events(in: lib).contains { $0.taskID == "dma-lab-1" })
    }
}
