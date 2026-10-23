import Foundation

enum StudyCategory: String, Codable, CaseIterable, Sendable {
    case overview, lecture, reading, assignment, work, announcement
    var label: String {
        switch self {
        case .overview: "课程大纲与安排"
        case .lecture: "课件与讲义"
        case .reading: "阅读材料"
        case .assignment: "作业要求与模板"
        case .work: "作答与提交文件"
        case .announcement: "公告与记录"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "book.closed"
        case .lecture: "rectangle.on.rectangle"
        case .reading: "book"
        case .assignment: "doc.text"
        case .work: "folder"
        case .announcement: "megaphone"
        }
    }
}

struct CourseGuide: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var summary: String
    var schedule: String
    var coverage: String
    var featuredIDs: [String]
    var folder: String?
}

struct StudyResource: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var courseID: String
    var title: String
    var category: StudyCategory
    var format: String
    var originalName: String?
    var originalFile: String?
    var previewFile: String?
    var thumbnailFile: String?
    var sourceURL: String?
    var sourceLabel: String
    var text: String
    var taskIDs: [String]
    var size: Int
    var relativePath: String?
    var modifiedAt: Double?
    var fileRole: String?
    var storageLabel: String {
        if fileRole == "submitted" { return "已提交归档 · 已核对文件摘要" }
        if relativePath?.contains("/90_我的提交/") == true { return "提交目录 · 状态以回执为准" }
        if ["/05_作业成果/", "/08_作业草稿/", "/output/"].contains(where: { relativePath?.contains($0) == true }) { return "草稿 / 制作过程" }
        return sourceLabel
    }

    var isOffline: Bool { originalFile != nil }
    var kindLabel: String {
        switch format {
        case "markdown": "文档"
        case "notebook": "Notebook"
        case "image": "图片"
        case "link": "在线资料"
        case "zip": "完整文件包"
        default: format.uppercased()
        }
    }
    var symbol: String {
        switch format {
        case "pdf": "doc.richtext"
        case "notebook": "chevron.left.forwardslash.chevron.right"
        case "image": "photo"
        case "link": "arrow.up.right.square"
        case "zip": "doc.zipper"
        default: "doc.text"
        }
    }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.allSatisfy { term in
            [title, originalName ?? "", category.label, text].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    /// Resource manifests reference bundled basenames only, never arbitrary files.
    static func validFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".."
            && filename == (filename as NSString).lastPathComponent
            && !filename.contains("\\") && !filename.contains(":")
    }
}

struct StudyCatalog: Codable, Sendable {
    var version: Int
    var generatedAt: String
    var courses: [CourseGuide]
    var resources: [StudyResource]

    static var empty: StudyCatalog { StudyCatalog(version: 1, generatedAt: "", courses: [], resources: []) }

    func validate() throws {
        guard version == 1, Set(courses.map(\.id)).count == courses.count,
              Set(resources.map(\.id)).count == resources.count else {
            throw ImportFailure.invalid("课程资料目录版本或 ID 无效。")
        }
        let courseIDs = Set(courses.map(\.id))
        for resource in resources {
            guard courseIDs.contains(resource.courseID), !resource.title.isEmpty else {
                throw ImportFailure.invalid("课程资料缺少课程或名称。")
            }
            for filename in [resource.originalFile, resource.previewFile, resource.thumbnailFile].compactMap({ $0 }) {
                guard StudyResource.validFilename(filename) else { throw ImportFailure.invalid("资料文件名无效。") }
            }
            if let path = resource.relativePath, !WorkspaceLayout.validRelativePath(path) { throw ImportFailure.invalid("原文件相对路径无效。") }
            if let url = resource.sourceURL, SafeLink.url(url) == nil {
                throw ImportFailure.invalid("资料链接无效。")
            }
        }
        for course in courses {
            if let folder = course.folder, !WorkspaceLayout.validRelativePath(folder) { throw ImportFailure.invalid("课程目录无效。") }
            guard course.featuredIDs.allSatisfy({ id in resources.contains { $0.id == id && $0.courseID == course.id } }) else {
                throw ImportFailure.invalid("课程推荐资料引用无效。")
            }
        }
    }

    func resources(for courseID: String, category: StudyCategory? = nil, query: String = "") -> [StudyResource] {
        resources.filter { $0.courseID == courseID && (category == nil || $0.category == category) && $0.matches(query) }
    }

    /// Prefer the exact assignment page already recorded in that task's source document.
    /// A course-wide assignments listing remains the fallback when no page is known.
    func assignmentURL(for task: Assignment) -> URL? {
        let recorded = SafeLink.url(task.sourceURL)
        let candidates = resources(forTask: task.id).filter {
            $0.courseID == task.courseID && $0.format == "link"
        }.compactMap { resource -> URL? in
            guard let url = SafeLink.url(resource.sourceURL ?? ""),
                  url.host == recorded?.host,
                  url.path.range(of: #"/(assignments|quizzes|discussion_topics)/[0-9]+$"#, options: .regularExpression) != nil else { return nil }
            return url
        }
        if let recorded, recorded.path.range(of: #"/(assignments|quizzes|discussion_topics)/[0-9]+$"#, options: .regularExpression) != nil { return recorded }
        return candidates.count == 1 ? candidates.first : recorded
    }

    func resources(forTask taskID: String) -> [StudyResource] {
        resources.filter { $0.taskIDs.contains(taskID) }
    }
}

enum WorkspaceLayout {
    static let dataPath = "Berkeley 26Fall General/课程数据"
    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("://") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func resolve(_ relative: String, under root: URL) -> URL? {
        guard validRelativePath(relative) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let result = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        return result.path.hasPrefix(base.path + "/") ? result : nil
    }
}
