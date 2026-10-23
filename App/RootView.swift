import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var store: LibraryStore
    @State private var route: SectionRoute = .today
    @State private var selectedTask: String?
    @State private var selectedCourse: String?
    @State private var browsingCategory: StudyCategory?
    @State private var returnTaskID: String?
    @State private var returnRoute: SectionRoute = .today
    @State private var returnCourseID: String?
    @State private var selectedResource: StudyResource?
    @State private var search = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var adding = false
    @State private var settings = false
    @State private var importCandidate: UpdateBundle?
    @State private var importPreview: ImportPreview?
    @State private var exportDocument: LibraryExport?
    @State private var now = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("schedulePresentation") private var schedulePresentation = "calendar"
    @State private var calendarDetail = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if !store.ready {
                ContentUnavailableView("资料库没有打开", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(store.errorMessage ?? "请重新打开 App。原记录未覆盖。"))
            } else if compact {
                TabView(selection: $route) {
                    ForEach(SectionRoute.allCases) { section in
                        Tab(section.rawValue, systemImage: section.symbol, value: section) {
                            NavigationStack {
                                content(for: section, compact: true)
                                    .navigationTitle(section.rawValue)
                                    .navigationDestination(for: String.self) { id in
                                        detail(id: id)
                                    }
                                    .toolbar { actions }
                            }
                        }
                    }
                }
            } else if route == .schedule && schedulePresentation == "calendar" {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 250)
                } detail: {
                    calendarView.navigationTitle("日程").toolbar { actions }
                }
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 250)
                } content: {
                    content(for: route, compact: false)
                        .navigationTitle(route == .courses ? (selectedCourseName ?? "课程") : route.rawValue)
                        .navigationSplitViewColumnWidth(min: 285, ideal: 355, max: 470)
                        .toolbar { actions }
                } detail: {
                    selectedDetail
                        .navigationSplitViewColumnWidth(min: 350, ideal: 480)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let bundle = try store.readImport(result.get())
                importPreview = try store.library.preview(bundle)
                importCandidate = bundle
            } catch { store.errorMessage = "未导入：\(error.localizedDescription)" }
        }
        .sheet(isPresented: Binding(get: { importCandidate != nil }, set: { if !$0 { importCandidate = nil } })) {
            if let bundle = importCandidate, let preview = importPreview {
                ImportReview(bundle: bundle, preview: preview) {
                    if store.importBundle(bundle) { importCandidate = nil }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NewTaskView(store: store) { id in
                selectedResource = nil
                selectedTask = id
                route = .schedule
                selectedCourse = nil
            }
        }
        .sheet(isPresented: $calendarDetail) {
            NavigationStack {
                if let task = store.library.assignments.first(where: { $0.id == selectedTask }) {
                    TaskDetail(store: store, task: task)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回日历") { calendarDetail = false } } }
                }
            }
            #if os(macOS)
            .frame(width: 760, height: 720)
            #endif
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                AppSettings(store: store).padding(24)
                    .navigationTitle("设置")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
            #if os(macOS)
            .frame(width: 720, height: 720)
            #endif
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: "课序-资料与进度-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
                if case .failure(let error) = result { store.errorMessage = "导出失败：\(error.localizedDescription)" }
            }
        .alert("需要处理", isPresented: Binding(get: { store.ready && store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshWorkspace(force: false) }
        }
    }

    var selectedCourseName: String? { store.library.courses.first { $0.id == selectedCourse }?.code }

    // Let the native sidebar own selection, focus, contrast and Liquid Glass.
    // Plain buttons inside selectable List rows produced two competing selection states.
    var sidebarSelection: Binding<String?> {
        Binding(get: { selectedCourse.map { "course:" + $0 } ?? "route:" + route.rawValue }, set: { value in
            guard let value else { return }
            if value.hasPrefix("course:") {
                route = .courses
                selectedCourse = String(value.dropFirst(7))
            } else if let section = SectionRoute(rawValue: String(value.dropFirst(6))) {
                route = section
                selectedCourse = nil
            }
            selectedTask = nil
            selectedResource = nil
            browsingCategory = nil
            returnTaskID = nil
            search = ""
        })
    }

    var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(SectionRoute.allCases) { section in
                    Label {
                        HStack {
                            Text(section.rawValue)
                            Spacer()
                            if section == .inbox {
                                let count = store.library.notices.filter { !store.library.readNoticeIDs.contains($0.id) }.count
                                if count > 0 { Text(count, format: .number).font(.caption).monospacedDigit() }
                            }
                        }
                    } icon: { Image(systemName: section.symbol) }
                    .labelStyle(.titleAndIcon)
                    .font(.body)
                    .padding(.vertical, 7)
                    .tag("route:" + section.rawValue)
                    .accessibilityIdentifier("nav-" + section.rawValue)
                }
            }
            Section("本学期") {
                ForEach(store.library.courses) { course in
                    Label {
                        Text(course.code).font(.callout)
                    } icon: {
                        Circle().fill(Palette.course(course.color)).frame(width: 7, height: 7)
                    }
                    .labelStyle(.titleAndIcon)
                    .padding(.vertical, 6)
                    .tag("course:" + course.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("课序")
        .safeAreaInset(edge: .bottom) {
            Label(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true ? "测试资料库" : "本机资料库", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }

    @ToolbarContentBuilder var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if route == .schedule {
                Button(schedulePresentation == "calendar" ? "列表视图" : "月历视图", systemImage: schedulePresentation == "calendar" ? "list.bullet" : "calendar") {
                    schedulePresentation = schedulePresentation == "calendar" ? "list" : "calendar"
                }
            }
            Button("新建任务", systemImage: "plus") { adding = true }
                .keyboardShortcut("n", modifiers: .command)
            Menu("资料管理", systemImage: "ellipsis") {
                Button("导入课程更新包", systemImage: "square.and.arrow.down") { importing = true }
                if !store.pendingWorkspaceUpdates.isEmpty {
                    Menu("课程文件夹中的待导入更新") {
                        ForEach(store.pendingWorkspaceUpdates, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                do {
                                    let bundle = try store.readImport(url)
                                    importPreview = try store.library.preview(bundle)
                                    importCandidate = bundle
                                } catch { store.errorMessage = "未导入：\(error.localizedDescription)" }
                            }
                        }
                    }
                }
                Button(store.isRefreshing ? "正在后台刷新…" : "刷新本地文件", systemImage: "arrow.clockwise") { store.refreshWorkspace() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("导出资料与进度", systemImage: "square.and.arrow.up") {
                    do {
                        exportDocument = LibraryExport(data: try Codec.encode(store.library))
                        exporting = true
                    } catch { store.errorMessage = error.localizedDescription }
                }
                Divider()
                Button("设置与存储说明", systemImage: "gearshape") { settings = true }
            }
        }
    }

    @ViewBuilder func content(for section: SectionRoute, compact: Bool) -> some View {
        switch section {
        case .schedule where schedulePresentation == "calendar":
            calendarView
        case .inbox:
            InboxView(store: store, compact: compact) { selectedTask = $0; selectedResource = nil }
        case .courses where selectedCourse == nil:
            List(selection: Binding<String?>(get: { selectedCourse }, set: { selectedCourse = $0; selectedTask = nil; selectedResource = nil; browsingCategory = nil })) {
              ForEach(store.library.courses) { course in
                if compact {
                    NavigationLink {
                        courseCollection(course, compact: true)
                    } label: { courseLabel(course) }
                } else {
                    courseLabel(course).tag(course.id)
                }
              }
            }.listStyle(.plain)
        case .courses:
            if let course = store.library.courses.first(where: { $0.id == selectedCourse }) {
                courseCollection(course, compact: compact)
            }
        default:
            taskList(section: section, courseID: selectedCourse, compact: compact).id(section)
        }
    }

    var calendarView: some View {
        ScheduleCalendarView(store: store) { id in
            selectedTask = id
            selectedResource = nil
            calendarDetail = true
        }
    }

    func courseLabel(_ course: Course) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed").foregroundStyle(Palette.course(course.color))
                .font(.title3).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(course.code).font(.headline)
                Text(course.name).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
    }

    func taskList(section: SectionRoute, courseID: String?, compact: Bool) -> some View {
        let all = store.library.assignments.filter {
            (courseID == nil || $0.courseID == courseID) && matches($0)
        }
        let filtered = section == .review ? [] : section == .today && search.isEmpty
            ? store.library.todayTasks(now: now) : store.library.sortedTasks(all.filter { store.library.needsSubmission($0) })
        let completed = store.library.sortedTasks(all.filter { store.library.isResolved($0) && !store.library.isEnded($0) && !$0.cancelled })
        let following = store.library.sortedTasks(all.filter { store.library.needsAssessmentFollowUp($0) && (section == .review || !store.library.needsSubmission($0)) })
        let undated = section == .review ? [] : all.filter { $0.actionDate == nil && store.library.needsSubmission($0) && !filtered.contains($0) }
        let overdue = filtered.filter { $0.actionDate.map { $0 < now } == true }
        let upcoming = filtered.filter { !overdue.contains($0) }
        return ScrollViewReader { proxy in
          List(selection: Binding<String?>(get: { selectedTask }, set: { selectedTask = $0; selectedResource = nil })) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(section == .today ? "本周作业" : section == .review ? "提交之后继续跟进" : "全部作业")
                        .font(.title3).fontWeight(.semibold)
                    Text("资料更新于 \(store.library.generatedAt.map { CourseDate.format($0) } ?? "尚未导入")")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }.listRowSeparator(.hidden)
            if !overdue.isEmpty {
                Section("已过截止 · 待处理") {
                    ForEach(overdue) { task in taskLink(task, compact: compact) }
                }
            }
            if section != .review { Section(section == .today ? "接下来七天" : "待提交 / 待完成") {
                ForEach(upcoming) { task in taskLink(task, compact: compact) }
                if upcoming.isEmpty {
                    Text(search.isEmpty ? "这组没有待完成事项。" : "没有匹配的任务。")
                        .foregroundStyle(.secondary).padding(.vertical, 16)
                }
            } }
            if !undated.isEmpty {
                Section("未设正式截止") {
                    ForEach(store.library.sortedTasks(undated)) { task in taskLink(task, compact: compact) }
                }
            }
            if !following.isEmpty {
                Section("评分与反馈 · 待跟进") { ForEach(following) { task in taskLink(task, compact: compact) } }
            } else if section == .review {
                Text("暂无待评分或待查看反馈的事项。").foregroundStyle(.secondary)
            }
            if !completed.isEmpty && section != .review {
                Section("已完成 / 已核对评分") { ForEach(completed) { task in taskLink(task, compact: compact) } }
            }
            let ended = store.library.sortedTasks(all.filter { store.library.isEnded($0) && !$0.cancelled })
            if !ended.isEmpty && (section != .today || !search.isEmpty) {
                Section("已结束") { ForEach(ended) { task in taskLink(task, compact: compact) } }
            }
            let cancelled = all.filter(\.cancelled)
            if !cancelled.isEmpty {
                Section("已取消") { ForEach(cancelled) { task in taskLink(task, compact: compact) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .searchable(text: $search, prompt: "搜索任务、课程和要求")
        .onAppear { if let selectedTask { proxy.scrollTo(selectedTask, anchor: .center) } }
        }
    }

    func matches(_ task: Assignment) -> Bool {
        search.isEmpty || [task.title, task.subtitle, task.instructions, store.library.course(for: task)?.code ?? ""]
            .joined(separator: " ").localizedCaseInsensitiveContains(search)
    }

    @ViewBuilder func taskLink(_ task: Assignment, compact: Bool) -> some View {
        if compact {
            NavigationLink(value: task.id) { TaskRow(task: task, library: store.library, now: now) }
        } else {
            TaskRow(task: task, library: store.library, now: now).tag(task.id).id(task.id)
        }
    }

    func courseCollection(_ course: Course, compact: Bool) -> some View {
        CourseCollection(store: store, course: course, compact: compact,
            selectedResourceID: selectedResource?.id, selectedTaskID: selectedTask, category: $browsingCategory,
            overview: { selectedTask = nil; selectedResource = nil },
            openResource: { selectedTask = nil; selectedResource = $0 },
            openTask: { selectedResource = nil; selectedTask = $0 })
            .id(course.id)
    }

    var selectedDetail: some View {
        VStack(spacing: 0) {
            if let id = returnTaskID, let task = store.library.assignments.first(where: { $0.id == id }) {
                HStack {
                    Button("返回 " + task.title, systemImage: "chevron.left") {
                        selectedTask = id; selectedResource = nil; returnTaskID = nil
                        route = returnRoute; selectedCourse = returnCourseID; browsingCategory = nil
                    }.buttonStyle(.glass)
                    Spacer()
                }.padding(12)
                Divider()
            }
            detailContent
        }
    }

    @ViewBuilder var detailContent: some View {
        if let resource = selectedResource {
            ResourceReader(store: store, resource: resource).id(resource.id)
        } else if selectedTask != nil {
            detail(id: selectedTask)
        } else if let course = store.library.courses.first(where: { $0.id == selectedCourse }) {
            CourseOverview(store: store, course: course,
                openCategory: { browsingCategory = $0 },
                openResource: { selectedTask = nil; selectedResource = $0 },
                openTask: { selectedResource = nil; selectedTask = $0 }).id(course.id)
        } else {
            ContentUnavailableView(route == .courses ? "选择一门课程" : "选择一项任务",
                systemImage: route == .courses ? "books.vertical" : "checklist",
                description: Text(route == .courses ? "课程概览、讲义、阅读和作业会在这里展开。" : "查看要求、相关资料和完成记录。"))
        }
    }

    @ViewBuilder func detail(id: String?) -> some View {
        if let task = store.library.assignments.first(where: { $0.id == id }) {
            TaskDetail(store: store, task: task, openCourse: compact ? nil : {
                returnTaskID = task.id; returnRoute = route; returnCourseID = selectedCourse
                route = .courses; selectedCourse = task.courseID
                selectedTask = nil; selectedResource = nil; browsingCategory = nil; search = ""
            }).id(task.id)
        } else {
            ContentUnavailableView("选择作业", systemImage: "checklist", description: Text("查看作业要求、文件和提交记录。"))
        }
    }
}

struct TaskRow: View {
    var task: Assignment
    var library: Library
    var now: Date

    var body: some View {
        if task.exam != nil {
            ExamEmphasis(task: task, library: library, now: now)
        } else {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(Palette.course(library.course(for: task)?.color ?? "blue")).frame(width: 5, height: 5)
                Text(library.course(for: task)?.code ?? "课程").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if library.isEnded(task) { Image(systemName: "archivebox").foregroundStyle(.secondary) }
                else if library.isComplete(task) { Image(systemName: library.isResolved(task) ? "checkmark.circle.fill" : "clock").foregroundStyle(library.isResolved(task) ? .teal : .orange) }
            }
            Text(task.title).font(.headline).foregroundStyle(.primary)
            if !task.subtitle.isEmpty { Text(task.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            HStack(alignment: .firstTextBaseline) {
                Text(task.actionDate.map { CourseDate.format($0) } ?? "未设正式截止")
                if task.closesAt != nil { Text("关闭").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(library.status(task))
                if let date = task.actionDate, date < now, library.needsSubmission(task) {
                    Text(task.closesAt != nil ? "· 已关闭" : "· 已过截止").foregroundStyle(.orange)
                }
            }.font(.caption).foregroundStyle(library.isResolved(task) ? .teal : library.needsAssessmentFollowUp(task) ? .orange : .secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        }
    }
}

/// Shared, static warning treatment: visible words and icons, not color or animation alone.
struct ExamEmphasis: View {
    var task: Assignment
    var library: Library
    var now: Date

    var body: some View {
        if let exam = task.exam {
            let active = library.needsSubmission(task)
            let urgent = active && (exam.daysRemaining(now: now) ?? 99) <= 7
            let tint: Color = active ? (urgent ? .red : .orange) : .secondary
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Label(library.course(for: task)?.code ?? task.courseID, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(active ? exam.countdown(now: now) : library.status(task))
                        .font(.caption.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(tint)
                Text(exam.dateLabel).font(.title3.weight(.bold)).foregroundStyle(.primary)
                Text(task.title + " · " + exam.timeLabel).font(.subheadline.weight(.semibold))
                Text(exam.timeNote).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(exam.locationNote).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4) }
            .padding(.vertical, 5).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("exam-emphasis-" + task.id)
        }
    }
}
