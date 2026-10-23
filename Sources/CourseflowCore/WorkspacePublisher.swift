import Foundation

/// One writer, atomic files, JSON published last as the completion marker.
/// The caller coalesces changes while a write is in flight; SwiftData is still authoritative.
actor WorkspacePublisher {
    func publish(_ library: Library, access: WorkspaceAccess, folders: [String: URL]) throws -> Date {
        guard let dataDirectory = WorkspaceLayout.resolve(WorkspaceLayout.dataPath, under: access.url) else {
            throw ImportFailure.invalid("镜像目录不在课程文件夹中。")
        }
        let date = Date.now
        let snapshot = try Codec.encode(library)
        try statusMarkdown(library, at: date).write(to: dataDirectory.appendingPathComponent("当前总览.md"), atomically: true, encoding: .utf8)
        for course in library.courses {
            guard let folder = folders[course.id] else { continue }
            // Revalidate destinations at write time, not just at scan time.
            let base = access.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(base) else { throw ImportFailure.invalid("课程镜像目录已移动到工作区外。") }
            let target = resolved.appendingPathComponent("当前状态_课序生成.md")
            guard target.resolvingSymlinksInPath().path.hasPrefix(base) else { throw ImportFailure.invalid("课程镜像路径无效。") }
            try statusMarkdown(library, courseID: course.id, at: date).write(to: target, atomically: true, encoding: .utf8)
        }
        try snapshot.write(to: dataDirectory.appendingPathComponent("当前资料与进度.json"), options: .atomic)
        return date
    }

    private func statusMarkdown(_ library: Library, courseID: String? = nil, at date: Date) -> String {
        var text = "# \(courseID.flatMap { id in library.courses.first { $0.id == id }?.code } ?? "课程")当前状态\n\n"
        text += "由课序生成，勿手改。资料 revision \(library.revision)；生成时间 \(CourseDate.format(date, includeYear: true)) PDT。\n\n提交、评分和个人跟进分别记录；旧核对时间不代表当前平台实时状态。\n\n"
        let tasks = library.sortedTasks(library.assignments.filter { courseID == nil || $0.courseID == courseID })
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        text += "待提交/自行完成：\(tasks.filter { library.needsSubmission($0) }.count)；评分/反馈跟进：\(tasks.filter { library.needsAssessmentFollowUp($0) }.count)；已结束：\(tasks.filter { library.isEnded($0) }.count)。\n\n"
        text += "| 课程 / 事项 | 当前状态 | 记录分数 |\n|---|---|---|\n"
        for task in tasks { text += "| \(cell((library.course(for: task)?.code ?? "") + " · " + task.title)) | \(cell(library.status(task))) | \(cell(task.grade ?? "—")) |\n" }
        text += "\n以下保留每项证据和个人跟进，未核实的条目不假装最新。\n\n"
        for task in tasks {
            text += "## \(library.course(for: task)?.code ?? task.courseID) · \(task.title)\n\n"
            text += "- 状态：\(library.status(task))\n"
            if let exam = task.exam {
                text += "- **考试：\(exam.day) · \(exam.timeLabel)（洛杉矶时间）**\n- 时段说明：\(exam.timeNote)\n- 地点 / 形式：\(exam.locationNote)\n"
            } else {
                text += "- 截止：\(task.dueAt.map { CourseDate.format($0, includeYear: true) } ?? "未设")\n"
            }
            if let date = task.closesAt { text += "- 页面关闭（不是正式截止）：\(CourseDate.format(date, includeYear: true))\n" }
            if let date = task.opensAt { text += "- 开放：\(CourseDate.format(date, includeYear: true))\n" }
            text += "- 来源核对：\(CourseDate.format(task.checkedAt, includeYear: true))；[平台](\(task.sourceURL))\n"
            for delivery in task.deliveries { text += "- \(delivery.title)：平台/来源=\(delivery.evidence.label)，本机有效确认=\(library.isComplete(delivery, in: task) ? "完成" : "未完成")；\(delivery.note)\n" }
            text += "- 评分：\(library.followUpLabel(task))；\(task.grade ?? "未记录分数")\n"
            if let assessment = task.assessment { text += "- 评分核对：\(CourseDate.format(assessment.checkedAt, includeYear: true))；\(assessment.note)\n" }
            if let feedback = task.feedback { text += "- 反馈：\(feedback)\n" }
            if let progress = library.progress[task.id] {
                if !progress.notes.isEmpty { text += "- 个人笔记：\(progress.notes)\n" }
                if let date = progress.assessmentReviewedAt { text += "- 个人评分查看：\(CourseDate.format(date, includeYear: true))\n" }
                if let date = progress.endedAt { text += "- 用户结束跟进：\(CourseDate.format(date, includeYear: true))\n" }
            }
            text += "\n"
        }
        return text
    }
}
