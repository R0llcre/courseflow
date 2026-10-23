import Foundation
import CryptoKit

/// Read-only discovery of course originals. Never runs code or changes progress.
extension StudyCatalog {
    func discoveringFiles(under root: URL) throws -> StudyCatalog {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var result = self
        var positions = Dictionary(uniqueKeysWithValues: resources.enumerated().compactMap { index, item in
            item.relativePath.map { ($0, index) }
        })
        let excluded: Set<String> = ["tmp", "node_modules", "vendor", "build", "__pycache__", "当前状态_课序生成.md"]
        for course in courses {
            guard let folder = course.folder, let directory = WorkspaceLayout.resolve(folder, under: root) else { continue }
            func visit(_ directory: URL) throws {
                try Task.checkCancellation()
                for file in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) {
                    let name = file.lastPathComponent
                    try Task.checkCancellation()
                    if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix("旧版_") || name.hasPrefix("历史版本") || excluded.contains(name) { continue }
                    let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true { try visit(file); continue }
                    guard values.isRegularFile == true else { continue }
                    let canonicalPath = file.resolvingSymlinksInPath().standardizedFileURL.path
                    guard canonicalPath.hasPrefix(root.path + "/") else { continue }
                    let relative = String(canonicalPath.dropFirst(root.path.count + 1))
                    guard WorkspaceLayout.resolve(relative, under: root) != nil else { continue }
                    let size = values.fileSize ?? 0
                    let modified = values.contentModificationDate?.timeIntervalSince1970
                    if let index = positions[relative] {
                        let timestampChanged = result.resources[index].modifiedAt.map { abs($0 - (modified ?? 0)) > 0.01 } ?? true
                        if result.resources[index].size != size || timestampChanged {
                            result.resources[index].previewFile = nil
                            result.resources[index].thumbnailFile = nil
                            result.resources[index].text = ""
                            result.resources[index].fileRole = nil
                            result.resources[index].size = size
                            result.resources[index].modifiedAt = modified
                        }
                        continue
                    }
                    let local = String(relative.dropFirst(folder.count + 1))
                    let digest = SHA256.hash(data: Data((course.id + "/" + local).utf8)).map { String(format: "%02x", $0) }.joined()
                    let id = "study-" + digest.prefix(16)
                    let ext = file.pathExtension.lowercased()
                    let format = ["md": "markdown", "ipynb": "notebook", "png": "image", "jpg": "image", "jpeg": "image" ][ext] ?? (ext.isEmpty ? "file" : ext)
                    let lower = local.lowercased()
                    let category: StudyCategory = lower.contains("90_我的提交") || lower.contains("05_作业成果") || lower.contains("08_作业草稿") || lower.hasPrefix("output/") ? .work :
                        lower.contains("02_课件") ? .lecture : lower.contains("03_阅读") ? .reading : lower.contains("04_作业") ? .assignment : lower.contains("99_来源") ? .announcement : .overview
                    // Explicit filename associations only; no course-wide guessing.
                    let taskIDs = resources.filter { $0.courseID == course.id && $0.relativePath.map { path in
                        (path as NSString).deletingLastPathComponent == (relative as NSString).deletingLastPathComponent
                    } == true }.flatMap(\.taskIDs)
                    let item = StudyResource(id: String(id), courseID: course.id, title: file.deletingPathExtension().lastPathComponent,
                        category: category, format: format, originalName: name, originalFile: String(id) + (ext.isEmpty ? "" : "." + ext),
                        sourceLabel: "本地原文件 · 刷新时发现", text: "", taskIDs: Array(Set(taskIDs)).sorted(), size: size,
                        relativePath: relative, modifiedAt: modified)
                    positions[relative] = result.resources.count
                    result.resources.append(item)
                }
            }
            try visit(directory)
        }
        for index in result.courses.indices {
            let items = result.resources.filter { $0.courseID == result.courses[index].id }
            result.courses[index].coverage = "已收录 \(items.filter(\.isOffline).count) 份本地资料，另有 \(items.filter { !$0.isOffline }.count) 个在线入口。在线入口不代表已下载；刷新本地文件不等于核对课程平台。"
        }
        try result.validate()
        return result
    }
}
