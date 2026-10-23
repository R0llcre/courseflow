import Foundation
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@Model
final class SavedLibrary {
    var key: String
    var payload: Data
    var savedAt: Date

    init(payload: Data) {
        key = "berkeley-fall-2026"
        self.payload = payload
        savedAt = .now
    }
}

@Observable @MainActor
final class LibraryStore {
    private(set) var library = Library()
    private(set) var ready = false
    private(set) var catalog = StudyCatalog.empty
    private(set) var catalogError: String?
    private(set) var savedAt: Date?
    var errorMessage: String?
    private var container: ModelContainer?
    private var record: SavedLibrary?
    private var directory: URL?
    private(set) var workspaceRoot: URL?
    private(set) var workspaceMessage = "尚未连接课程文件夹，当前阅读安装时的副本。"
    private(set) var lastPublishedAt: Date?
    private var workspaceAccess: WorkspaceAccess?
    private var workspaceUpdates: [WorkspaceUpdate] = []
    private var courseFolders: [String: URL] = [:]
    private let workspaceReader = WorkspaceReader()
    private let workspacePublisher = WorkspacePublisher()
    private var connectionID = UUID()
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGate = WorkspaceRefreshGate()
    private var publishTask: Task<Void, Never>?
    private var pendingPublication: (Library, WorkspaceAccess, [String: URL])?
    private var mirrorNeedsRetry = false
    private(set) var fileGeneration = UUID()
    private(set) var isRefreshing = false
    var fileLocation: StudyFileLocation { StudyFileLocation(access: workspaceAccess, bundleRoot: Bundle.main.resourceURL) }
    var pendingWorkspaceUpdates: [URL] { workspaceUpdates.filter { $0.revision > library.revision }.map(\.url) }
    var storageDirectory: URL? { directory }
    var bundledDirectory: URL? { Bundle.main.resourceURL }
    var isQA: Bool { ProcessInfo.processInfo.arguments.contains("--qa") || Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true }

    init() {
        do {
            // QA is isolated from the real library, including attachments.
            let qa = ProcessInfo.processInfo.arguments.contains("--qa") || Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent(qa ? "Courseflow-QA" : "Courseflow", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            let configuration = ModelConfiguration("Courseflow", url: directory.appendingPathComponent("Library.store"),
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: SavedLibrary.self, configurations: configuration)
            self.container = container
            let records = try container.mainContext.fetch(FetchDescriptor<SavedLibrary>())
            guard records.count <= 1 else { throw ImportFailure.invalid("资料库包含多条主记录。未自动合并或覆盖，请保留资料库后排查。") }
            if let record = records.first {
                let decoded = try Codec.decode(Library.self, from: record.payload)
                guard decoded.schemaVersion == 1, decoded.collectionID == "berkeley-fall-2026" else {
                    throw ImportFailure.invalid("此资料库版本不受支持。原记录保持不变。")
                }
                self.library = decoded
                self.record = record
                self.savedAt = record.savedAt
            } else {
                let initial: Library
                if let url = Bundle.main.url(forResource: "berkeley-fall-2026", withExtension: "json") {
                    let bundle = try UpdateBundle.read(Data(contentsOf: url))
                    initial = try Library.initial(from: bundle)
                } else {
                    initial = Library()
                }
                let record = SavedLibrary(payload: try Codec.encode(initial))
                container.mainContext.insert(record)
                try container.mainContext.save()
                self.library = initial
                self.record = record
                self.savedAt = record.savedAt
            }
            ready = true
            restoreWorkspace()
        } catch { errorMessage = "无法打开资料库：\(error.localizedDescription)" }
    }

    @discardableResult
    func update(_ mutation: (inout Library) throws -> Void) -> Bool {
        guard ready, let container, let record else { return false }
        do {
            var next = library
            try mutation(&next)
            let encoded = try Codec.encode(next)
            record.payload = encoded
            record.savedAt = .now
            do { try container.mainContext.save() }
            catch { container.mainContext.rollback(); throw error }
            library = next
            savedAt = record.savedAt
            publishWorkspace()
            return true
        } catch {
            errorMessage = "未保存此次修改：\(error.localizedDescription)"
            return false
        }
    }

    func confirm(_ task: Assignment, _ item: Delivery, complete: Bool) {
        update { $0.confirm(taskID: task.id, deliveryID: item.id, complete: complete) }
    }

    func setFollowUpEnded(_ task: Assignment, ended: Bool) {
        update { $0.setFollowUpEnded(taskID: task.id, ended: ended) }
    }

    func begin(_ task: Assignment) {
        update {
            var progress = $0.progress[task.id] ?? TaskProgress()
            progress.startedAt = progress.startedAt == nil ? .now : nil
            $0.progress[task.id] = progress
        }
    }

    func markRead(_ notice: UpdateNotice) {
        update { $0.readNoticeIDs.insert(notice.id) }
    }

    func importBundle(_ bundle: UpdateBundle) -> Bool {
        update { try $0.apply(bundle) }
    }

    func readImport(_ url: URL) throws -> UpdateBundle {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw ImportFailure.invalid("更新包超过 10 MB。") }
        return try UpdateBundle.read(Data(contentsOf: url))
    }

    func addAttachment(_ url: URL, to task: Assignment) {
        guard let directory else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 100_000_000 else {
                throw ImportFailure.invalid("请选择不超过 100 MB 的普通文件。视频建议保留来源链接。")
            }
            let attachmentDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let suffix = url.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(16)
            let storedName = suffix.isEmpty ? id : "\(id).\(suffix)"
            let target = attachmentDirectory.appendingPathComponent(storedName)
            if let root = workspaceRoot, let folder = courseFolderURL(task.courseID) {
                guard !isQA else { throw ImportFailure.invalid("QA 模式不向真实课程目录添加文件。") }
                let source = url.resolvingSymlinksInPath().standardizedFileURL
                let courseRoot = folder.resolvingSymlinksInPath().standardizedFileURL
                let linked: URL
                if source.path.hasPrefix(courseRoot.path + "/") {
                    linked = source
                } else {
                    guard let coursePath = catalog.courses.first(where: { $0.id == task.courseID })?.folder,
                          let destination = WorkspaceLayout.resolve(coursePath + "/90_我的提交/课序添加", under: root) else {
                        throw ImportFailure.invalid("附件目标目录不在课程工作区中。")
                    }
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    linked = destination.appendingPathComponent(id + "-" + url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: linked)
                }
                let relative = String(linked.path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
                guard WorkspaceLayout.resolve(relative, under: root) != nil else { throw ImportFailure.invalid("附件路径不在课程文件夹中。") }
                let attachment = Attachment(id: id, name: url.lastPathComponent, storedName: storedName, addedAt: .now, workspacePath: relative)
                _ = update {
                    var progress = $0.progress[task.id] ?? TaskProgress()
                    progress.attachments.append(attachment)
                    $0.progress[task.id] = progress
                }
                return
            }
            try FileManager.default.copyItem(at: url, to: target)
            let attachment = Attachment(id: id, name: url.lastPathComponent, storedName: storedName, addedAt: .now)
            let saved = update {
                var progress = $0.progress[task.id] ?? TaskProgress()
                progress.attachments.append(attachment)
                $0.progress[task.id] = progress
            }
            if !saved { try? FileManager.default.removeItem(at: target) } // Only the new, unreferenced copy.
        } catch { errorMessage = "未添加材料：\(error.localizedDescription)" }
    }

    func attachmentURL(_ attachment: Attachment) -> URL? {
        if let path = attachment.workspacePath {
            guard let root = workspaceRoot, let url = WorkspaceLayout.resolve(path, under: root), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard let directory,
              attachment.storedName == (attachment.storedName as NSString).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent("Attachments").appendingPathComponent(attachment.storedName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func connectWorkspace(_ url: URL) {
        connectionTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        refreshGate = WorkspaceRefreshGate()
        isRefreshing = false
        connectionID = UUID()
        let id = connectionID
        let access = WorkspaceAccess(url)
        workspaceMessage = "正在后台连接课程文件夹…"
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if connectionID == id { connectionTask = nil } }
            do { try await installWorkspace(access, id: id) }
            catch {
                guard !Task.isCancelled, connectionID == id else { return }
                errorMessage = "未连接课程文件夹：请选择包含各课程目录和 Berkeley 26Fall General 的 Fall26 文件夹。\n" + error.localizedDescription
            }
        }
    }

    private func installWorkspace(_ access: WorkspaceAccess, id: UUID) async throws {
        let scan = try await workspaceReader.scan(access, force: true)
        let bookmark = try await workspaceReader.bookmark(for: access)
        try Task.checkCancellation()
        guard connectionID == id else { return }
        workspaceAccess = access
        workspaceRoot = access.url
        UserDefaults.standard.set(bookmark, forKey: "courseWorkspaceBookmark")
        applyScan(scan)
        _ = refreshGate.begin(force: true)
        _ = refreshGate.finish()
        publishWorkspace()
    }

    private func restoreWorkspace() {
        let bookmark = UserDefaults.standard.data(forKey: "courseWorkspaceBookmark")
        let bundledURL = Bundle.main.url(forResource: "course-library", withExtension: "json")
        let id = connectionID
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if connectionID == id { connectionTask = nil } }
            if let bookmark {
                workspaceMessage = "正在后台载入课程文件夹…"
                do {
                    let access = try await workspaceReader.restore(bookmark)
                    try await installWorkspace(access, id: id)
                    return
                } catch {
                    guard !Task.isCancelled, connectionID == id else { return }
                    workspaceMessage = "课程文件夹暂时无法读取，请重新连接或稍后重试。原文件与进度未改动。"
                }
            }
            do {
                guard let bundledURL else { return }
                let loaded = try await workspaceReader.bundledCatalog(at: bundledURL)
                guard !Task.isCancelled, connectionID == id else { return }
                catalog = loaded
                fileGeneration = UUID()
            } catch {
                guard !Task.isCancelled, connectionID == id else { return }
                catalogError = "课程资料目录未载入：" + error.localizedDescription
            }
        }
    }

    func refreshWorkspace(force: Bool = true) {
        guard let access = workspaceAccess, connectionTask == nil,
              refreshGate.begin(force: force) else { return }
        isRefreshing = true
        let id = connectionID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var forced = force
            repeat {
                do {
                    let scan = try await workspaceReader.scan(access, force: forced)
                    guard !Task.isCancelled, connectionID == id else { return }
                    applyScan(scan)
                    if forced || mirrorNeedsRetry { publishWorkspace() }
                } catch {
                    guard !Task.isCancelled, connectionID == id else { return }
                    workspaceMessage = "资料索引刷新失败，保留上一份索引：" + error.localizedDescription
                }
                forced = true
            } while refreshGate.finish()
            isRefreshing = false
            refreshTask = nil
        }
    }

    private func applyScan(_ scan: WorkspaceScan) {
        catalog = scan.catalog
        courseFolders = scan.folders
        workspaceUpdates = scan.updates
        fileGeneration = UUID()
        catalogError = nil
    }

    func courseFolderURL(_ courseID: String) -> URL? { courseFolders[courseID] }

    func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    // Saves stay synchronous in SwiftData; only the derived Finder mirror is queued.
    // A single drain loop always writes the newest waiting snapshot after the active one.
    func publishWorkspace() {
        guard !isQA else { workspaceMessage = "QA 模式：只读课程文件夹，不发布真实状态镜像。"; return }
        guard ready, let access = workspaceAccess else { return }
        pendingPublication = (library, access, courseFolders)
        mirrorNeedsRetry = true
        workspaceMessage = "App 进度已保存，正在后台同步文件夹镜像…"
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            guard let self else { return }
            while let pending = pendingPublication {
                pendingPublication = nil
                do {
                    let date = try await workspacePublisher.publish(pending.0, access: pending.1, folders: pending.2)
                    guard workspaceAccess?.id == pending.1.id, pendingPublication == nil else { continue }
                    mirrorNeedsRetry = false
                    lastPublishedAt = date
                    workspaceMessage = "已连接原文件；当前状态已同步到课程文件夹。资料索引：" + catalog.generatedAt
                } catch {
                    guard workspaceAccess?.id == pending.1.id, pendingPublication == nil else { continue }
                    workspaceMessage = "App 进度已保存，但文件夹镜像未全部写入；可重试同步：" + error.localizedDescription
                }
            }
            publishTask = nil
        }
    }

}

struct LibraryExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
