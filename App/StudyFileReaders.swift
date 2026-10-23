import SwiftUI
import ImageIO
import PDFKit

struct StudyReadRequest: Sendable {
    struct Key: Hashable, Sendable {
        var generation: UUID
        var resourceID: String
        var thumbnail: String?
        var preview: String?
        var original: String?
        var size: Int
        var modified: Double?
    }
    var key: Key
    var location: StudyFileLocation
    var resource: StudyResource

    @MainActor init(_ resource: StudyResource, store: LibraryStore?) {
        key = Key(generation: store?.fileGeneration ?? Self.bundledGeneration, resourceID: resource.id,
                  thumbnail: resource.thumbnailFile, preview: resource.previewFile,
                  original: resource.relativePath ?? resource.originalFile, size: resource.size, modified: resource.modifiedAt)
        location = store?.fileLocation ?? StudyFileLocation(bundleRoot: Bundle.main.resourceURL)
        self.resource = resource
        self.resource.text = "" // Do not retain large indexed bodies in image-cache requests.
    }

    private static let bundledGeneration = UUID()
}

/// CGImage is immutable. PDFDocument is constructed on one worker and handed off once;
/// that worker never reads/mutates it again after returning it to the main-actor reader.
struct DecodedStudyImage: @unchecked Sendable { let image: CGImage }
struct StudyReaderContent: @unchecked Sendable {
    var access: WorkspaceAccess?
    var original: URL?
    var preview: URL?
    var changed = false
    var document: PDFDocument?
    var image: CGImage?
    var failure: String?
}

private func decodedImage(_ url: URL, maximumPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary)
}

/// Serial reads bound concurrent iCloud requests and deduplicate queued cache hits.
actor StudyThumbnailLoader {
    static let shared = StudyThumbnailLoader()
    private var cache = BoundedCache<StudyReadRequest.Key, DecodedStudyImage>(countLimit: 160, costLimit: 16 * 1_024 * 1_024)

    func image(for request: StudyReadRequest) -> DecodedStudyImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.value(for: request.key) { return cached }
        guard request.resource.thumbnailFile != nil,
              !request.location.originalHasChanged(request.resource),
              let url = request.location.cached(request.resource.thumbnailFile) else { return nil }
        let result = autoreleasepool { decodedImage(url, maximumPixels: 192).map { DecodedStudyImage(image: $0) } }
        guard !Task.isCancelled else { return nil }
        if let result { cache.insert(result, for: request.key, cost: result.image.bytesPerRow * result.image.height) }
        // Missing/cloud-unavailable files are not negatively cached: revisiting can retry.
        return result
    }
}

struct StudyThumbnail: View {
    var request: StudyReadRequest
    @State private var loaded: DecodedStudyImage?
    @State private var loadedKey: StudyReadRequest.Key?

    var body: some View {
        ZStack {
            if loadedKey == request.key, let loaded {
                Image(decorative: loaded.image, scale: 2).resizable().scaledToFit()
                    .padding(3).background(.white, in: RoundedRectangle(cornerRadius: 4))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request.key) {
            loaded = nil; loadedKey = nil
            let key = request.key
            let image = await StudyThumbnailLoader.shared.image(for: request)
            guard !Task.isCancelled, key == request.key else { return }
            loaded = image; loadedKey = key
        }
        .onDisappear {
            // Lazy containers retain row state; don't let offscreen rows defeat the LRU bound.
            loaded = nil; loadedKey = nil
        }
    }
}

/// Reader work is separate from thumbnails: a cloud thumbnail cannot block opening a PDF.
actor StudyReaderLoader {
    static let shared = StudyReaderLoader()

    func load(_ request: StudyReadRequest) throws -> StudyReaderContent {
        try Task.checkCancellation()
        var content = StudyReaderContent(access: request.location.access, original: request.location.original(request.resource),
                                         preview: request.location.preview(request.resource),
                                         changed: request.location.originalHasChanged(request.resource))
        guard let url = content.preview else { return content }
        if request.resource.format == "pdf" {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 100_000_000 else {
                content.preview = nil
                return content // Keep original/Quick Look available without a huge in-memory copy.
            }
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            content.document = autoreleasepool { PDFDocument(data: data) }
            if content.document == nil { content.failure = "PDF 无法读取。可用“原文件位置”在系统预览中打开。" }
        } else if request.resource.format == "image" {
            content.image = autoreleasepool { decodedImage(url, maximumPixels: 3_200) }
            if content.image == nil { content.failure = "图片无法读取。原文件保留不变。" }
        }
        try Task.checkCancellation()
        return content
    }

    func export(_ request: StudyReadRequest) throws -> Data {
        try Task.checkCancellation()
        guard let url = request.location.original(request.resource) else { throw ImportFailure.invalid("原文件缺失，请检查课程文件夹。") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 100_000_000 else {
            throw ImportFailure.invalid("这份文件超过 100 MB，请用“原文件位置”在访达中复制，避免导出占用大量内存。")
        }
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return data
    }
}
