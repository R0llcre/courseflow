import Foundation

/// A job retains its own lease, so switching folders cannot revoke an in-flight read.
final class WorkspaceAccess: Sendable {
    let url: URL
    let id = UUID()
    private let granted: Bool

    init(_ url: URL) {
        self.url = url
        granted = url.startAccessingSecurityScopedResource()
    }

    deinit { if granted { url.stopAccessingSecurityScopedResource() } }
}

/// At most one scan plus one requested follow-up. Activation never queues another scan.
struct WorkspaceRefreshGate {
    private(set) var running = false
    private var queued = false
    private var finishedAt: Date?
    var interval: TimeInterval = 60

    mutating func begin(force: Bool, now: Date = .now) -> Bool {
        if running { queued = queued || force; return false }
        if !force, let finishedAt, now.timeIntervalSince(finishedAt) < interval { return false }
        running = true
        return true
    }

    mutating func finish(now: Date = .now) -> Bool {
        finishedAt = now
        let again = queued
        queued = false
        running = again
        return again
    }
}

/// A deterministic cost/count bound, rather than an unbounded dictionary of images.
struct BoundedCache<Key: Hashable, Value> {
    private struct Entry { var value: Value; var cost: Int; var use: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    var count: Int { entries.count }
    let countLimit: Int
    let costLimit: Int

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.use = clock; entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost newCost: Int) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard newCost >= 0, newCost <= costLimit, countLimit > 0 else { return }
        while !entries.isEmpty && (entries.count >= countLimit || cost > costLimit - newCost) {
            guard let oldest = entries.min(by: { $0.value.use < $1.value.use })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            cost -= removed.cost
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: newCost, use: clock)
        cost += newCost
    }
}

struct WorkspaceUpdate: Sendable {
    var url: URL
    var revision: Int
}

struct WorkspaceScan: Sendable {
    var catalog: StudyCatalog
    var updates: [WorkspaceUpdate]
    var folders: [String: URL]
}

/// Synchronous filesystem work is confined to this actor's background executor.
/// It never touches SwiftData, view state, or the user's originals.
actor WorkspaceReader {
    private struct Stamp: Equatable {
        var date: Date?
        var size: Int?
        init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            date = values.contentModificationDate; size = values.fileSize
        }
    }
    private var cachedCatalog: (URL, Stamp, StudyCatalog)?

    func bundledCatalog(at url: URL) throws -> StudyCatalog {
        try loadCatalog(at: url, force: false)
    }

    private func loadCatalog(at url: URL, force: Bool) throws -> StudyCatalog {
        try Task.checkCancellation()
        let stamp = try Stamp(url)
        if !force, let cachedCatalog, cachedCatalog.0 == url, cachedCatalog.1 == stamp { return cachedCatalog.2 }
        let loaded = try JSONDecoder().decode(StudyCatalog.self, from: Data(contentsOf: url))
        try loaded.validate()
        try Task.checkCancellation()
        cachedCatalog = (url, stamp, loaded)
        return loaded
    }

    func scan(_ access: WorkspaceAccess, force: Bool) throws -> WorkspaceScan {
        guard let url = WorkspaceLayout.resolve(WorkspaceLayout.dataPath + "/course-library.json", under: access.url) else {
            throw ImportFailure.invalid("课程目录路径无效。")
        }
        let loaded = try loadCatalog(at: url, force: force)
        let catalog = try loaded.discoveringFiles(under: access.url)
        var folders: [String: URL] = [:]
        for course in catalog.courses {
            if let path = course.folder { folders[course.id] = WorkspaceLayout.resolve(path, under: access.url) }
        }
        var updates: [WorkspaceUpdate] = []
        let updatePath = "Berkeley 26Fall General/Courseflow/Updates"
        if let folder = WorkspaceLayout.resolve(updatePath, under: access.url),
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try Task.checkCancellation()
                guard let safe = WorkspaceLayout.resolve(updatePath + "/" + file.lastPathComponent, under: access.url),
                      let values = try? safe.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size <= 10_000_000,
                      let data = try? Data(contentsOf: safe), let bundle = try? UpdateBundle.read(data) else { continue }
                updates.append(WorkspaceUpdate(url: safe, revision: bundle.revision))
            }
        }
        return WorkspaceScan(catalog: catalog, updates: updates.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }, folders: folders)
    }

    func bookmark(for access: WorkspaceAccess) throws -> Data {
        #if os(macOS)
        try access.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try access.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    func restore(_ data: Data) throws -> WorkspaceAccess {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return WorkspaceAccess(url)
    }
}

/// Resolution is used only by background readers. Do not call it from a View body.
struct StudyFileLocation: Sendable {
    var access: WorkspaceAccess?
    var bundleRoot: URL?

    func cached(_ filename: String?) -> URL? {
        guard let filename, StudyResource.validFilename(filename) else { return nil }
        if let access {
            guard let url = WorkspaceLayout.resolve(WorkspaceLayout.dataPath + "/预览缓存/" + filename, under: access.url),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard let bundleRoot else { return nil }
        for relative in [filename, "StudyFiles/" + filename, "Resources/StudyFiles/" + filename] {
            let url = bundleRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func original(_ resource: StudyResource) -> URL? {
        if let access, let relative = resource.relativePath {
            guard let url = WorkspaceLayout.resolve(relative, under: access.url),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        return cached(resource.originalFile)
    }

    func originalHasChanged(_ resource: StudyResource) -> Bool {
        guard access != nil, resource.relativePath != nil else { return false }
        guard let url = original(resource), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return true }
        return values.fileSize != resource.size || (resource.modifiedAt.map { abs((values.contentModificationDate?.timeIntervalSince1970 ?? 0) - $0) > 0.01 } ?? false)
    }

    func preview(_ resource: StudyResource) -> URL? {
        if resource.format == "pdf" || resource.format == "image" { return original(resource) }
        return originalHasChanged(resource) ? nil : cached(resource.previewFile)
    }
}
