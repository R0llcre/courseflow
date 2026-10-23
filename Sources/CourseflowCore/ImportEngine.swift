import Foundation
import CryptoKit

enum ImportFailure: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

struct ImportChange: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
}

struct ImportPreview: Sendable {
    var additions: [ImportChange] = []
    var changes: [ImportChange] = []
    var skipped: [ImportChange] = []
    var courseChanges = 0
    var isDuplicate = false
}

extension UpdateBundle {
    func validate() throws {
        guard schemaVersion == 1 else { throw ImportFailure.invalid("不支持此更新包版本；需要 schemaVersion 1。") }
        guard revision > 0 else { throw ImportFailure.invalid("更新包 revision 必须是正整数。") }
        guard collectionID == "berkeley-fall-2026" else { throw ImportFailure.invalid("更新包不属于 Berkeley Fall 2026。") }
        guard courses.count <= 100, assignments.count <= 10_000 else { throw ImportFailure.invalid("更新包条目过多。") }
        try unique(courses.map(\.id), kind: "课程")
        try unique(assignments.map(\.id), kind: "任务")
        let courseIDs = Set(courses.map(\.id))
        for course in courses {
            guard !course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  SafeLink.url(course.url) != nil else { throw ImportFailure.invalid("课程名称或 HTTPS 入口无效：\(course.id)") }
        }
        for task in assignments {
            guard !task.isLocal else { throw ImportFailure.invalid("更新包不能使用保留的 local- 任务 ID。") }
            guard courseIDs.contains(task.courseID) else { throw ImportFailure.invalid("任务引用了未提供的课程：\(task.id)") }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !task.deliveries.isEmpty else { throw ImportFailure.invalid("任务需要名称和至少一个交付/完成项：\(task.id)") }
            guard task.checkedAt <= generatedAt else { throw ImportFailure.invalid("来源核对时间晚于更新包生成时间：\(task.id)") }
            if let exam = task.exam {
                guard exam.dayDate != nil, !exam.timeNote.isEmpty, !exam.locationNote.isEmpty,
                      task.dueAt == nil, task.closesAt == nil, task.opensAt == nil else {
                    throw ImportFailure.invalid("考试需要有效日期、时段及地点说明，不能混用作业截止字段：\(task.id)")
                }
                if let start = exam.startsAt {
                    guard ScheduleCalendar.dayKey(start) == exam.day else { throw ImportFailure.invalid("考试开始时间与考试日不一致：\(task.id)") }
                }
                if let end = exam.endsAt {
                    guard let start = exam.startsAt, end > start, ScheduleCalendar.dayKey(end) == exam.day else {
                        throw ImportFailure.invalid("考试结束时间无效：\(task.id)")
                    }
                }
            }
            if let assessment = task.assessment {
                guard assessment.checkedAt <= generatedAt, SafeLink.url(assessment.sourceURL) != nil else {
                    throw ImportFailure.invalid("评分核对时间或来源无效：\(task.id)")
                }
                if assessment.state == .graded || assessment.state == .partial {
                    guard task.grade?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        throw ImportFailure.invalid("已评分或部分评分必须附有实际成绩：\(task.id)")
                    }
                }
            }
            if let due = task.dueAt, let close = task.closesAt, close < due {
                throw ImportFailure.invalid("关闭时间早于正式截止：\(task.id)")
            }
            if let open = task.opensAt, let end = task.actionDate, open > end {
                throw ImportFailure.invalid("开放时间晚于截止/关闭：\(task.id)")
            }
            try unique(task.deliveries.map(\.id), kind: "交付项")
            try unique(task.materials.map(\.id), kind: "材料")
            guard SafeLink.url(task.sourceURL) != nil,
                  task.materials.allSatisfy({ SafeLink.url($0.url) != nil }) else {
                throw ImportFailure.invalid("只接受不含账号密码的 HTTPS 来源和材料链接：\(task.id)")
            }
        }
    }

    private func unique(_ ids: [String], kind: String) throws {
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(ids).count == ids.count else { throw ImportFailure.invalid("\(kind) ID 为空或重复。") }
    }

    func fingerprint() throws -> String {
        SHA256.hash(data: try Codec.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ data: Data) throws -> UpdateBundle {
        guard data.count <= 10_000_000 else { throw ImportFailure.invalid("更新包超过 10 MB。") }
        let bundle = try Codec.decode(UpdateBundle.self, from: data)
        try bundle.validate()
        return bundle
    }
}

extension Library {
    func preview(_ bundle: UpdateBundle) throws -> ImportPreview {
        try bundle.validate()
        guard bundle.collectionID == collectionID else { throw ImportFailure.invalid("不能混入其他学期的数据。") }
        let digest = try bundle.fingerprint()
        if let existing = appliedRevisions[String(bundle.revision)] {
            guard existing == digest else { throw ImportFailure.invalid("同一 revision 对应不同内容，请让维护者生成新的版本号。") }
            return ImportPreview(isDuplicate: true)
        }
        guard bundle.revision > revision else { throw ImportFailure.invalid("这是旧版更新包，当前已是第 \(revision) 版。") }
        var result = ImportPreview()
        result.courseChanges = bundle.courses.filter { incoming in courses.first { $0.id == incoming.id } != incoming }.count
        for task in bundle.assignments {
            let change = ImportChange(id: task.id, title: task.title, detail: "新增任务")
            guard let old = assignments.first(where: { $0.id == task.id }) else {
                result.additions.append(change)
                continue
            }
            guard old != task else { continue }
            if task.checkedAt < old.checkedAt {
                result.skipped.append(ImportChange(id: task.id, title: task.title, detail: "来源比现有记录旧，保留现有资料"))
                continue
            }
            var details: [String] = []
            if old.exam != task.exam { details.append("考试日期、时段或地点更新；请重点核对") }
            if old.dueAt != task.dueAt {
                details.append("正式截止：\(old.dueAt.map { CourseDate.format($0) } ?? "未设") → \(task.dueAt.map { CourseDate.format($0) } ?? "未设")")
            }
            if old.closesAt != task.closesAt {
                details.append("关闭时间：\(old.closesAt.map { CourseDate.format($0) } ?? "未设") → \(task.closesAt.map { CourseDate.format($0) } ?? "未设")")
            }
            if old.deliveries != task.deliveries { details.append("交付项或核对证据有变化；你的确认保留") }
            if old.feedback != task.feedback { details.append("老师反馈有更新") }
            if old.grade != task.grade || old.assessment != task.assessment { details.append("评分与跟进记录更新") }
            if old.cancelled != task.cancelled { details.append(task.cancelled ? "任务已取消" : "任务已恢复") }
            if details.isEmpty { details.append("要求、材料或来源记录更新") }
            result.changes.append(ImportChange(id: task.id, title: task.title, detail: details.joined(separator: "\n")))
        }
        return result
    }

    mutating func apply(_ bundle: UpdateBundle, initial: Bool = false) throws {
        let result = try preview(bundle)
        guard !result.isDuplicate else { return }
        // Construct in a value copy: a failed validation never partially mutates the library.
        var next = self
        for course in bundle.courses {
            if let index = next.courses.firstIndex(where: { $0.id == course.id }) { next.courses[index] = course }
            else { next.courses.append(course) }
        }
        let skipped = Set(result.skipped.map(\.id))
        for task in bundle.assignments where !skipped.contains(task.id) {
            if let index = next.assignments.firstIndex(where: { $0.id == task.id }) {
                var incoming = task
                let old = next.assignments[index]
                // Submission and grading may have different verification dates.
                if let prior = old.assessment, incoming.assessment == nil || incoming.assessment!.checkedAt < prior.checkedAt {
                    incoming.assessment = prior
                    incoming.grade = old.grade
                    incoming.feedback = old.feedback
                }
                next.assignments[index] = incoming
            }
            else { next.assignments.append(task) }
        }
        if initial {
            for task in bundle.assignments {
                if let feedback = task.feedback, !feedback.isEmpty {
                    next.notices.append(UpdateNotice(id: "seed-feedback-\(task.id)", taskID: task.id,
                        title: "老师反馈 · \(task.title)", detail: feedback, createdAt: task.checkedAt))
                }
            }
        } else {
            for change in result.additions + result.changes {
                next.notices.append(UpdateNotice(id: "r\(bundle.revision)-\(change.id)", taskID: change.id,
                    title: change.title, detail: change.detail, createdAt: bundle.generatedAt))
            }
        }
        next.revision = bundle.revision
        next.generatedAt = bundle.generatedAt
        next.appliedRevisions[String(bundle.revision)] = try bundle.fingerprint()
        // Never replace progress, attachments, read markers, or missing tasks from an update bundle.
        self = next
    }
}
