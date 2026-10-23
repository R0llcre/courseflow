import Foundation

enum ScheduleEventKind: String, CaseIterable, Sendable {
    case due, closes, planned, opens, exam
    var label: String {
        switch self {
        case .due: "截止"
        case .closes: "关闭"
        case .planned: "个人计划"
        case .opens: "开放"
        case .exam: "考试"
        }
    }
}

struct ScheduleEvent: Identifiable, Equatable, Sendable {
    var taskID: String
    var kind: ScheduleEventKind
    var date: Date
    var id: String { taskID + ":" + kind.rawValue }
}

enum ScheduleCalendar {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.firstWeekday = 2
        return value
    }
    static func monthStart(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    static func shiftMonth(_ date: Date, by offset: Int) -> Date { calendar.date(byAdding: .month, value: offset, to: monthStart(date))! }
    static func days(in month: Date) -> [Date] {
        let start = monthStart(month)
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -leading, to: start)!
        let count = ((leading + calendar.range(of: .day, in: .month, for: start)!.count + 6) / 7) * 7
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    static func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func label(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }
    static func events(in library: Library, courseID: String? = nil, pendingOnly: Bool = false,
                       includeOpening: Bool = false, query: String = "") -> [ScheduleEvent] {
        var events: [ScheduleEvent] = []
        for task in library.assignments where !task.cancelled {
            guard courseID == nil || task.courseID == courseID,
                  !pendingOnly || library.needsSubmission(task) || library.needsAssessmentFollowUp(task),
                  query.isEmpty || [task.title, task.subtitle, library.course(for: task)?.code ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query) else { continue }
            if let exam = task.exam, let date = exam.startsAt ?? exam.dayDate {
                events.append(ScheduleEvent(taskID: task.id, kind: .exam, date: date))
            }
            if let date = task.dueAt { events.append(ScheduleEvent(taskID: task.id, kind: .due, date: date)) }
            if let date = task.closesAt { events.append(ScheduleEvent(taskID: task.id, kind: .closes, date: date)) }
            if let date = library.progress[task.id]?.plannedAt { events.append(ScheduleEvent(taskID: task.id, kind: .planned, date: date)) }
            if includeOpening, let date = task.opensAt { events.append(ScheduleEvent(taskID: task.id, kind: .opens, date: date)) }
        }
        return events.sorted {
            if dayKey($0.date) == dayKey($1.date), ($0.kind == .exam) != ($1.kind == .exam) { return $0.kind == .exam }
            return $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }
}
