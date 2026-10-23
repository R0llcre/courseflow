import SwiftUI
import UniformTypeIdentifiers
import WebKit
import PDFKit
import QuickLook

struct CourseOverview: View {
    @Bindable var store: LibraryStore
    var course: Course
    var openCategory: ((StudyCategory) -> Void)? = nil
    var openResource: (StudyResource) -> Void
    var openTask: (String) -> Void
    private var resources: [StudyResource] { store.catalog.resources(for: course.id) }
    private var guide: CourseGuide? { store.catalog.courses.first { $0.id == course.id } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(course.code, systemImage: "books.vertical").font(.headline).foregroundStyle(Palette.course(course.color))
                    Text(course.name).font(.largeTitle.bold())
                    if let guide {
                        Text(guide.summary).font(.body).lineSpacing(5)
                        Label(guide.schedule, systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let url = SafeLink.url(course.url) {
                        Link("打开课程平台", destination: url).buttonStyle(.bordered)
                    }
                    if let folder = store.courseFolderURL(course.id) {
                        Button("在访达中显示课程文件夹", systemImage: "folder") { store.reveal(folder) }.buttonStyle(.bordered)
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(store.workspaceRoot == nil ? "资料来源：安装时的内置副本" : "资料来源：已连接的课程文件夹").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("课程资料").font(.title2.bold())
                    ForEach(StudyCategory.allCases, id: \.self) { category in
                        let items = resources.filter { $0.category == category }
                        if !items.isEmpty {
                            if let openCategory {
                                Button { openCategory(category) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: category.symbol).foregroundStyle(Palette.course(course.color)).frame(width: 24)
                                        Text(category.label).font(.headline).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(items.count) 份").foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(15).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            } else {
                                DisclosureGroup(category.label + "（\(items.count)）") {
                                    ForEach(items) { resource in
                                        Button { openResource(resource) } label: { StudyResourceRow(resource: resource, store: store) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                let upcoming = store.library.sortedTasks(store.library.assignments.filter { $0.courseID == course.id && !$0.cancelled && !store.library.isResolved($0) })
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("待完成作业").font(.title2.bold())
                        ForEach(Array(upcoming.prefix(3))) { task in
                            Button { openTask(task.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(task.title + (task.subtitle.isEmpty ? "" : " · " + task.subtitle)).font(.headline).foregroundStyle(.primary)
                                    Text(task.actionDate.map { CourseDate.format($0) } ?? "未设正式截止").font(.subheadline).foregroundStyle(.secondary)
                                    Text(store.library.status(task)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("课程大纲与说明").font(.title2.bold())
                    let featured = resources.filter { $0.category == .overview && $0.isOffline }
                    ForEach(featured) { resource in
                        Button { openResource(resource) } label: { StudyResourceRow(resource: resource, store: store, color: Palette.course(course.color)) }.buttonStyle(.plain)
                    }
                    if featured.isEmpty {
                        ForEach(resources.filter { $0.category == .overview }.prefix(3)) { resource in
                            Button { openResource(resource) } label: { StudyResourceRow(resource: resource, store: store) }.buttonStyle(.plain)
                        }
                    }
                }
                if let guide {
                    Text(guide.coverage).font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
                if let error = store.catalogError { Text(error).foregroundStyle(.orange) }
            }.frame(maxWidth: 760, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.paper)
    }
}

struct CourseCollection: View {
    @Bindable var store: LibraryStore
    var course: Course
    var compact: Bool
    var selectedResourceID: String?
    var selectedTaskID: String?
    @Binding var category: StudyCategory?
    var overview: () -> Void
    var openResource: (StudyResource) -> Void
    var openTask: (String) -> Void
    @State private var mode = "资料"
    @State private var expanded: Set<StudyCategory> = []
    @State private var search = ""

    private var selection: Binding<String?> {
        Binding(get: { selectedResourceID ?? selectedTaskID ?? "overview" }, set: { id in
            guard let id else { return }
            if id == "overview" { overview() }
            else if let resource = store.catalog.resources.first(where: { $0.id == id }) { openResource(resource) }
            else { openTask(id) }
        })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                if compact {
                    NavigationLink { CompactCourseOverview(store: store, course: course) } label: {
                        Label("课程概览", systemImage: "house").font(.headline).padding(.vertical, 8)
                    }
                } else {
                    Label("课程概览", systemImage: "house").font(.headline).padding(.vertical, 8).tag("overview")
                }
                Picker("浏览内容", selection: $mode) {
                    Text("资料").tag("资料")
                    Text("作业").tag("作业")
                }.pickerStyle(.segmented)
                if let category, mode == "资料" {
                    HStack {
                        Text(category.label).font(.headline)
                        Spacer()
                        Button("全部分类") { self.category = nil }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
            if mode == "资料" {
                let matches = store.catalog.resources(for: course.id, category: category, query: search)
                ForEach(StudyCategory.allCases, id: \.self) { group in
                    let items = matches.filter { $0.category == group }
                    if !items.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: {
                            !search.isEmpty || category != nil || expanded.contains(group)
                        }, set: { isOpen in
                            if category != nil { category = nil }
                            if isOpen { expanded.insert(group) } else { expanded.remove(group) }
                        })) {
                            ForEach(items) { resource in
                                if compact {
                                    NavigationLink { ResourceReader(store: store, resource: resource) } label: {
                                        StudyResourceRow(resource: resource, store: store, color: Palette.course(course.color))
                                    }
                                } else {
                                    StudyResourceRow(resource: resource, store: store, color: Palette.course(course.color)).tag(resource.id)
                                }
                            }
                        } label: {
                            HStack {
                                Label(group.label, systemImage: group.symbol).font(.headline)
                                Spacer()
                                Text(items.count, format: .number).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                        }
                    }
                }
                if matches.isEmpty { ContentUnavailableView.search(text: search) }
            } else {
                let tasks = store.library.sortedTasks(store.library.assignments.filter {
                    $0.courseID == course.id && (search.isEmpty || [$0.title,$0.subtitle,$0.instructions].joined(separator: " ").localizedCaseInsensitiveContains(search))
                })
                ForEach(["待提交 / 待完成", "评分与反馈", "已完成", "已结束"], id: \.self) { state in
                    let group = tasks.filter { task in
                        if state == "已结束" { return store.library.isEnded(task) }
                        if state == "评分与反馈" { return store.library.needsAssessmentFollowUp(task) && !store.library.needsSubmission(task) }
                        if state == "已完成" { return store.library.isResolved(task) && !store.library.isEnded(task) && !task.cancelled }
                        return store.library.needsSubmission(task)
                    }
                    if !group.isEmpty {
                        Section(state) {
                            ForEach(group) { task in
                                if compact {
                                    NavigationLink { TaskDetail(store: store, task: task) } label: { TaskRow(task: task, library: store.library, now: .now) }
                                } else {
                                    TaskRow(task: task, library: store.library, now: .now).tag(task.id)
                                }
                            }
                        }
                    }
                }
                if tasks.isEmpty { Text("没有匹配的作业。").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Palette.canvas)
        .searchable(text: $search, prompt: mode == "资料" ? "搜索标题或正文" : "搜索课程作业")
        .navigationTitle(course.code)
        .onChange(of: category) { _, value in if value != nil { mode = "资料"; search = "" } }
    }
}

struct CompactCourseOverview: View {
    @Bindable var store: LibraryStore
    var course: Course
    @State private var reading: StudyResource?
    @State private var taskID: String?
    var body: some View {
        CourseOverview(store: store, course: course,
            openResource: { reading = $0 }, openTask: { taskID = $0 })
            .sheet(item: $reading) { resource in
                NavigationStack {
                    ResourceReader(store: store, resource: resource)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回课程") { reading = nil } } }
                }
            }
            .navigationDestination(isPresented: Binding(get: { taskID != nil }, set: { if !$0 { taskID = nil } })) {
                if let task = store.library.assignments.first(where: { $0.id == taskID }) { TaskDetail(store: store, task: task) }
            }
    }
}

struct StudyResourceRow: View {
    var resource: StudyResource
    var store: LibraryStore? = nil
    var color: Color = .accentColor
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.07))
                Image(systemName: resource.symbol).font(.title2).foregroundStyle(color)
                StudyThumbnail(request: StudyReadRequest(resource, store: store))
            }.frame(width: 48, height: 62).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(resource.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(3)
                Text(resource.kindLabel + (resource.isOffline ? " · 离线可用" : " · 在线打开")).font(.caption).foregroundStyle(.secondary)
                if resource.category == .work { Text(resource.storageLabel).font(.caption2).foregroundStyle(resource.fileRole == "submitted" ? .teal : .secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 9).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("resource-\(resource.id)")
    }
}

struct ResourceReader: View {
    @Bindable var store: LibraryStore
    var resource: StudyResource
    @State private var history: [StudyResource] = []
    @State private var zoom: Double = 1
    @State private var query = ""
    @State private var searchText = ""
    @State private var matchCount = 0
    @State private var matchIndex = 0
    @State private var failure: String?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportDocument = ResourceFileDocument(data: Data())
    @State private var quickLookURL: URL?
    @State private var content: StudyReaderContent?
    @State private var contentKey: StudyReadRequest.Key?
    @State private var exportTask: Task<Void, Never>?
    @State private var preparingExport = false
    @Environment(\.openURL) private var openURL
    private var current: StudyResource {
        let selected = history.last ?? resource
        return store.catalog.resources.first { $0.id == selected.id } ?? selected
    }
    private var request: StudyReadRequest { StudyReadRequest(current, store: store) }
    private var loadedContent: StudyReaderContent? { contentKey == request.key ? content : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if !history.isEmpty {
                    ReaderAction("返回", symbol: "chevron.left") { history.removeLast(); resetReader() }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(current.title).font(.title3.bold()).textSelection(.enabled)
                    Text(current.kindLabel + " · " + current.storageLabel).font(.caption).foregroundStyle(.secondary)
                    if let relative = current.relativePath, store.workspaceRoot != nil {
                        Text(relative).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                if let url = SafeLink.url(current.sourceURL ?? ""), current.isOffline {
                    ReaderAction("来源", symbol: "arrow.up.right") { openURL(url) }
                }
                if current.isOffline {
                    ReaderAction(preparingExport ? "正在准备…" : "导出", symbol: "square.and.arrow.up") {
                        let selected = request
                        preparingExport = true
                        exportTask = Task {
                            defer { preparingExport = false; exportTask = nil }
                            do {
                                let data = try await StudyReaderLoader.shared.export(selected)
                                guard !Task.isCancelled, selected.key == request.key else { return }
                                exportDocument = ResourceFileDocument(data: data)
                                exporting = true
                            } catch {
                                if !Task.isCancelled { exportError = error.localizedDescription }
                            }
                        }
                    }.disabled(preparingExport).help("导出原文件")
                }
                if store.workspaceRoot != nil, let original = loadedContent?.original {
                    ReaderAction("原文件位置", symbol: "folder") { store.reveal(original) }
                }
            }.padding(20)
            if loadedContent?.changed == true {
                Text("原文件已更新或移动，旧阅读缓存不再展示。可打开原文件；请刷新资料索引。").font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }
            if current.previewFile != nil {
                HStack(spacing: 14) {
                    ReaderAction("缩小", symbol: "minus.magnifyingglass") { zoom = max(0.6, zoom - 0.15) }
                    Text("\(Int((zoom * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 40)
                    ReaderAction("放大", symbol: "plus.magnifyingglass") { zoom = min(3, zoom + 0.15) }
                    ReaderAction("重置", symbol: "arrow.counterclockwise") { zoom = 1 }
                    Spacer(minLength: 0)
                }.padding(.horizontal,20).padding(.bottom,12)
                if current.format == "pdf" {
                    HStack(spacing: 10) {
                        TextField("查找 PDF 文字，按回车", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { matchIndex = 0; query = searchText }
                        ReaderAction("查找", symbol: "magnifyingglass") { matchIndex = 0; query = searchText }
                        if !query.isEmpty {
                            Text(matchCount == 0 ? "无匹配" : "\(matchIndex + 1)/\(matchCount)").font(.caption).monospacedDigit()
                            Button { matchIndex = max(0, matchIndex - 1) } label: { Image(systemName: "chevron.up").foregroundStyle(.primary) }
                                .buttonStyle(.plain).disabled(matchIndex == 0).help("上一个结果")
                            Button { matchIndex = min(matchCount - 1, matchIndex + 1) } label: { Image(systemName: "chevron.down").foregroundStyle(.primary) }
                                .buttonStyle(.plain).disabled(matchCount == 0 || matchIndex >= matchCount - 1).help("下一个结果")
                        }
                    }.padding(.horizontal,20).padding(.bottom,12)
                }
            }
            Divider()
            if let failure {
                ContentUnavailableView("无法显示这份材料", systemImage: "doc.badge.ellipsis", description: Text(failure))
            } else {
                preview
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
        .navigationTitle(current.title)
        .task(id: request.key) {
            let selected = request
            content = nil; contentKey = nil; failure = nil
            exportTask?.cancel()
            do {
                let loaded = try await StudyReaderLoader.shared.load(selected)
                guard !Task.isCancelled, selected.key == request.key else { return }
                content = loaded; contentKey = selected.key; failure = loaded.failure
            } catch {
                guard !Task.isCancelled, selected.key == request.key else { return }
                failure = "读取文件失败：" + error.localizedDescription
            }
        }
        .onDisappear {
            exportTask?.cancel()
            content = nil; contentKey = nil
            if !exporting { exportDocument = ResourceFileDocument(data: Data()) }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
            contentType: UTType(filenameExtension: (current.originalName ?? "").split(separator: ".").last.map(String.init) ?? "") ?? .data,
            defaultFilename: current.originalName ?? current.title) { result in
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { exportError = error.localizedDescription }
                exportDocument = ResourceFileDocument(data: Data())
            }
        .quickLookPreview($quickLookURL)
        .alert("未导出文件", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("知道了") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    @ViewBuilder private var preview: some View {
        if loadedContent == nil {
            ProgressView("正在读取资料…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = loadedContent?.preview {
            if current.format == "pdf" {
                if let document = loadedContent?.document { PDFSurface(document: document, zoom: zoom, query: query, matchIndex: matchIndex, matchCount: $matchCount).id(request.key) }
                else { ContentUnavailableView("PDF 无法读取", systemImage: "doc.badge.ellipsis", description: Text("可导出原文件，用系统预览打开。")) }
            } else if current.format == "image" {
                if let decoded = loadedContent?.image {
                    GeometryReader { geometry in
                        ScrollView([.horizontal,.vertical]) {
                            Image(decorative: decoded, scale: 1).resizable().scaledToFit().frame(width: max(1,geometry.size.width - 36) * zoom)
                                .padding(18).background(.white).accessibilityLabel(current.title)
                        }
                    }
                } else { ContentUnavailableView("图片无法读取", systemImage: "photo.badge.exclamationmark") }
            } else {
                HTMLSurface(url: url, zoom: zoom, failure: $failure) { id in
                    if let next = store.catalog.resources.first(where: { $0.id == id }) { history.append(next); resetReader() }
                    else { failure = "链接指向的课程资料不在当前资料包中。" }
                } openExternal: { url in openURL(url) }.id(request.key)
            }
        } else if !current.isOffline, let url = SafeLink.url(current.sourceURL ?? "") {
            ContentUnavailableView {
                Label("这份资料在课程网站上", systemImage: current.symbol)
            } description: {
                Text("\(current.title)\n尚未保存离线副本，可能需要登录学校账号。")
            } actions: {
                Link("打开原始资料", destination: url).buttonStyle(.borderedProminent)
            }
        } else if let url = loadedContent?.original {
            ContentUnavailableView {
                Label(current.format == "zip" ? "完整原始文件包" : "使用系统预览", systemImage: current.symbol)
            } description: {
                Text(current.format == "zip" ? "包含原始目录中的代码、notebook 与数据。使用右上角按钮导出后解压。" : "原文件已收录。可以尝试系统预览，或用“原文件位置”在对应应用中打开。代码和工程文件不会自动执行。")
            } actions: {
                if current.format != "zip" {
                    Button("预览文件") { quickLookURL = url }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            ContentUnavailableView("找不到文件", systemImage: "doc.badge.ellipsis", description: Text("资料目录存在，但原文件缺失。请检查课程文件夹并刷新索引；不会用旧副本假装原文件仍在。"))
        }
    }
    private func resetReader() { zoom = 1; query = ""; searchText = ""; matchCount = 0; matchIndex = 0; failure = nil }
}

struct ReaderAction: View {
    var title: String
    var symbol: String
    var action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

struct ResourceFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

#if os(macOS)
struct PDFSurface: NSViewRepresentable {
    var document: PDFDocument; var zoom: Double; var query: String; var matchIndex: Int; @Binding var matchCount: Int
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator(matchCount: $matchCount) }
    func makeNSView(context: Context) -> PDFView { PDFCoordinator.make(document) }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, zoom: zoom, query: query, matchIndex: matchIndex) }
}
#else
struct PDFSurface: UIViewRepresentable {
    var document: PDFDocument; var zoom: Double; var query: String; var matchIndex: Int; @Binding var matchCount: Int
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator(matchCount: $matchCount) }
    func makeUIView(context: Context) -> PDFView { PDFCoordinator.make(document) }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view, zoom: zoom, query: query, matchIndex: matchIndex) }
}
#endif

@MainActor final class PDFCoordinator {
    var priorZoom: Double = 1
    var priorQuery: String = ""
    var priorIndex = -1
    var selections: [PDFSelection] = []
    var matchCount: Binding<Int>
    init(matchCount: Binding<Int>) { self.matchCount = matchCount }
    static func make(_ document: PDFDocument) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        return view
    }
    func update(_ view: PDFView, zoom: Double, query: String, matchIndex: Int) {
        if zoom != priorZoom {
            if zoom == 1 { view.autoScales = true }
            else { view.autoScales = false; view.scaleFactor = view.scaleFactorForSizeToFit * zoom }
            priorZoom = zoom
        }
        if query != priorQuery {
            selections = query.isEmpty ? [] : view.document?.findString(query, withOptions: .caseInsensitive) ?? []
            view.highlightedSelections = selections
            let count = selections.count
            DispatchQueue.main.async { self.matchCount.wrappedValue = count }
            priorQuery = query
            priorIndex = -1
        }
        if matchIndex != priorIndex {
            if selections.indices.contains(matchIndex) {
                let selection = selections[matchIndex]
                view.go(to: selection); view.setCurrentSelection(selection, animate: true)
            } else { view.clearSelection() }
            priorIndex = matchIndex
        }
    }
}

#if os(macOS)
struct HTMLSurface: NSViewRepresentable {
    var url: URL; var zoom: Double; @Binding var failure: String?
    var openResource: (String) -> Void; var openExternal: (URL) -> Void
    func makeCoordinator() -> HTMLCoordinator { HTMLCoordinator(failure: $failure, openResource: openResource, openExternal: openExternal) }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.make(url) }
    func updateNSView(_ view: WKWebView, context: Context) { view.pageZoom = zoom }
}
#else
struct HTMLSurface: UIViewRepresentable {
    var url: URL; var zoom: Double; @Binding var failure: String?
    var openResource: (String) -> Void; var openExternal: (URL) -> Void
    func makeCoordinator() -> HTMLCoordinator { HTMLCoordinator(failure: $failure, openResource: openResource, openExternal: openExternal) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.make(url) }
    func updateUIView(_ view: WKWebView, context: Context) { view.pageZoom = zoom }
}
#endif

@MainActor final class HTMLCoordinator: NSObject, WKNavigationDelegate {
    var failure: Binding<String?>
    var openResource: (String) -> Void
    var openExternal: (URL) -> Void
    init(failure: Binding<String?>, openResource: @escaping (String) -> Void, openExternal: @escaping (URL) -> Void) {
        self.failure = failure; self.openResource = openResource; self.openExternal = openExternal
    }
    func make(_ url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "courseflow-resource" {
            decisionHandler(.cancel)
            if let id = url.host { openResource(id) }
        } else if navigationAction.navigationType == .linkActivated, SafeLink.url(url.absoluteString) != nil {
            decisionHandler(.cancel); openExternal(url)
        } else if url.isFileURL || url.absoluteString == "about:blank" { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure.wrappedValue = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure.wrappedValue = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure.wrappedValue = "阅读器意外停止。请返回列表后重新打开。" }
}
