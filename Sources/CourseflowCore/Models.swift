import Foundation

enum Codec {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

struct Course: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var code: String
    var name: String
    var color: String
    var url: String
}

enum Evidence: String, Codable, Sendable {
    case unknown, notSubmitted, submitted, userConfirmed

    var label: String {
        switch self {
        case .unknown: "待核实"
        case .notSubmitted: "核对时未提交"
        case .submitted: "平台记录已提交"
        case .userConfirmed: "用户确认"
        }
    }

    var isComplete: Bool { self == .submitted || self == .userConfirmed }
}

struct Delivery: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var note: String
    var evidence: Evidence
}

struct Material: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var url: String
}

enum GradingState: String, Codable, Sendable {
    case unknown, awaiting, partial, graded, notRequired
    var label: String {
        switch self {
        case .unknown: "评分待核实"
        case .awaiting: "待评分"
        case .partial: "部分评分 · 非最终"
        case .graded: "已评分"
        case .notRequired: "无需评分"
        }
    }
}

struct Assessment: Codable, Equatable, Sendable {
    var state: GradingState
    var checkedAt: Date
    var sourceURL: String
    var note: String
    var actionRequired: Bool = false
}

/// A known exam day is not a fabricated midnight deadline or a class-length exam.
struct ExamSchedule: Codable, Equatable, Sendable {
    var day: String // yyyy-MM-dd in America/Los_Angeles
    var startsAt: Date?
    var endsAt: Date?
    var timeNote: String
    var locationNote: String

    var dayDate: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let date = f.date(from: day), f.string(from: date) == day else { return nil }
        return date
    }
    var dateLabel: String { dayDate.map { ScheduleCalendar.label($0, format: "M月d日 EEEE") } ?? day }
    var timeLabel: String {
        guard let startsAt else { return "具体时间待通知" }
        let start = ScheduleCalendar.label(startsAt, format: "HH:mm")
        return endsAt.map { start + "–" + ScheduleCalendar.label($0, format: "HH:mm") } ?? start
    }
    func daysRemaining(now: Date) -> Int? {
        guard let dayDate else { return nil }
        return ScheduleCalendar.calendar.dateComponents([.day], from: ScheduleCalendar.calendar.startOfDay(for: now), to: dayDate).day
    }
    func countdown(now: Date) -> String {
        guard let days = daysRemaining(now: now) else { return "考试日期待核实" }
        if days < 0 { return "考试日已过 · 待确认" }
        if days == 0 { return "今天考试" }
        if days == 1 { return "明天考试" }
        return "距考试 \(days) 天"
    }
}

struct Assignment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var courseID: String
    var title: String
    var subtitle: String
    var dueAt: Date?
    var closesAt: Date?
    var opensAt: Date?
    var nextStep: String
    var instructions: String
    var deliveries: [Delivery]
    var materials: [Material]
    var sourceName: String
    var sourceURL: String
    var checkedAt: Date
    var feedback: String?
    var grade: String?
    var cancelled: Bool
    var selfTracked: Bool?
    var assessment: Assessment?
    var exam: ExamSchedule?

    /// A close time is useful for sorting but must not be relabeled as a due date.
    var actionDate: Date? { exam.map { $0.startsAt ?? $0.dayDate } ?? (closesAt ?? dueAt) }
    var isLocal: Bool { id.hasPrefix("local-") }
    var gradingState: GradingState { assessment?.state ?? (selfTracked == true ? .notRequired : .unknown) }
    // Refreshing the same evidence does not reset the user's review. A changed
    // score, comment, or action requirement does require a new review.
    var reviewKey: String {
        [gradingState.rawValue, grade ?? "", feedback ?? "", assessment?.actionRequired == true ? "action" : "none"].joined(separator: "\u{001F}")
    }
}

struct Confirmation: Codable, Equatable, Sendable {
    var isComplete: Bool
    var recordedAt: Date
}

struct Attachment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var storedName: String
    var addedAt: Date
    var workspacePath: String?
}

struct TaskProgress: Codable, Equatable, Sendable {
    var confirmations: [String: Confirmation] = [:]
    var startedAt: Date?
    var plannedAt: Date?
    var endedAt: Date?
    var reviewedAssessmentKey: String?
    var assessmentReviewedAt: Date?
    var notes: String = ""
    var attachments: [Attachment] = []
}

struct UpdateNotice: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var taskID: String?
    var title: String
    var detail: String
    var createdAt: Date
}

struct UpdateBundle: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var collectionID: String
    var revision: Int
    var generatedAt: Date
    var courses: [Course]
    var assignments: [Assignment]
}

struct Library: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var collectionID = "berkeley-fall-2026"
    var revision = 0
    var generatedAt: Date?
    var courses: [Course] = []
    var assignments: [Assignment] = []
    var progress: [String: TaskProgress] = [:]
    var appliedRevisions: [String: String] = [:]
    var notices: [UpdateNotice] = []
    var readNoticeIDs: Set<String> = []

    func course(for task: Assignment) -> Course? { courses.first { $0.id == task.courseID } }

    func isComplete(_ delivery: Delivery, in task: Assignment) -> Bool {
        progress[task.id]?.confirmations[delivery.id]?.isComplete ?? delivery.evidence.isComplete
    }

    func completedCount(_ task: Assignment) -> Int {
        task.deliveries.filter { isComplete($0, in: task) }.count
    }

    func isComplete(_ task: Assignment) -> Bool {
        !task.deliveries.isEmpty && completedCount(task) == task.deliveries.count
    }

    func isEnded(_ task: Assignment) -> Bool { progress[task.id]?.endedAt != nil }
    func isResolved(_ task: Assignment) -> Bool {
        isEnded(task) || (isComplete(task) && (task.gradingState == .notRequired ||
            (task.gradingState == .graded && hasReviewedAssessment(task))))
    }

    func hasReviewedAssessment(_ task: Assignment) -> Bool {
        progress[task.id]?.reviewedAssessmentKey == task.reviewKey
    }

    func needsSubmission(_ task: Assignment) -> Bool {
        !task.cancelled && !isEnded(task) && !isComplete(task) && !(task.selfTracked == true && task.assessment?.actionRequired == true)
    }
    func needsAssessmentFollowUp(_ task: Assignment) -> Bool {
        !task.cancelled && !isEnded(task) && !isResolved(task) &&
            (isComplete(task) || task.assessment?.actionRequired == true || task.gradingState == .partial || task.gradingState == .graded)
    }

    mutating func reviewAssessment(taskID: String, reviewed: Bool, at date: Date = .now) {
        guard let task = assignments.first(where: { $0.id == taskID }), task.gradingState == .graded else { return }
        var record = progress[taskID] ?? TaskProgress()
        record.reviewedAssessmentKey = reviewed ? task.reviewKey : nil
        record.assessmentReviewedAt = reviewed ? date : nil
        progress[taskID] = record
    }

    func followUpLabel(_ task: Assignment) -> String {
        if isEnded(task) { return task.gradingState.label + "（已结束跟进）" }
        if task.assessment?.actionRequired == true && !hasReviewedAssessment(task) { return "待处理反馈 / 记录疑点" }
        if task.gradingState == .graded {
            if hasReviewedAssessment(task) { return "已评分 · 已查看" }
            return task.assessment?.actionRequired == true ? "待处理反馈" : "成绩与反馈待查看"
        }
        return task.gradingState.label
    }

    mutating func setFollowUpEnded(taskID: String, ended: Bool, at date: Date = .now) {
        guard assignments.contains(where: { $0.id == taskID && !$0.cancelled }) else { return }
        var record = progress[taskID] ?? TaskProgress()
        record.endedAt = ended ? date : nil
        progress[taskID] = record
    }

    func status(_ task: Assignment) -> String {
        if task.cancelled { return "已取消" }
        if isEnded(task) { return "已结束" + (task.grade.map { " · " + $0 } ?? "") }
        if task.selfTracked == true && task.assessment?.actionRequired == true { return followUpLabel(task) }
        if task.exam != nil {
            return isComplete(task) ? "已参加考试 · " + followUpLabel(task) : "待参加考试"
        }
        let count = completedCount(task)
        if isComplete(task) {
            let userConfirmed = task.deliveries.contains {
                progress[task.id]?.confirmations[$0.id] != nil || $0.evidence == .userConfirmed
            }
            if task.gradingState == .notRequired { return userConfirmed ? "已完成 · 用户确认" : "已完成 · 平台核对" }
            return (userConfirmed && !task.deliveries.allSatisfy { $0.evidence == .submitted } ? "用户确认已交 · " : "已提交 · ") + followUpLabel(task)
        }
        if count > 0 { return "还有 \(task.deliveries.count - count) 项" }
        if progress[task.id]?.startedAt != nil { return "进行中" }
        if task.selfTracked == true { return "待完成" }
        if task.deliveries.allSatisfy({ $0.evidence == .unknown }) { return "提交状态待核实" }
        return "未完成"
    }

    func sortedTasks(_ tasks: [Assignment]) -> [Assignment] {
        tasks.sorted {
            if $0.actionDate != $1.actionDate {
                return ($0.actionDate ?? .distantFuture) < ($1.actionDate ?? .distantFuture)
            }
            return $0.id < $1.id
        }
    }

    func todayTasks(now: Date = .now) -> [Assignment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let horizon = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now))!
        return sortedTasks(assignments.filter { task in
            guard needsSubmission(task) else { return false }
            return task.actionDate.map { $0 < horizon } == true
                || progress[task.id]?.plannedAt.map { $0 < horizon } == true
                || progress[task.id]?.startedAt != nil
        })
    }

    mutating func confirm(taskID: String, deliveryID: String, complete: Bool, at date: Date = .now) {
        guard let task = assignments.first(where: { $0.id == taskID }),
              task.deliveries.contains(where: { $0.id == deliveryID }), !task.cancelled else { return }
        var record = progress[taskID] ?? TaskProgress()
        record.confirmations[deliveryID] = Confirmation(isComplete: complete, recordedAt: date)
        progress[taskID] = record
    }

    static func initial(from bundle: UpdateBundle) throws -> Library {
        var library = Library()
        try library.apply(bundle, initial: true)
        return library
    }
}

enum CourseDate {
    static func format(_ date: Date, includeYear: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = includeYear ? "yyyy/M/d HH:mm" : "M/d E HH:mm"
        return formatter.string(from: date)
    }
}

enum SafeLink {
    /// Imported bundles cannot launch file:, javascript:, custom schemes, or credential-bearing URLs.
    static func url(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}
