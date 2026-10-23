import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct TaskDetail: View {
    @Bindable var store: LibraryStore
    var task: Assignment
    var openCourse: (() -> Void)? = nil
    @State private var showingCourse = false
    @State private var editing = false
    @State private var choosingFile = false
    @State private var previewURL: URL?
    @State private var readingResource: StudyResource?

    private var progress: TaskProgress { store.library.progress[task.id] ?? TaskProgress() }
    private var ended: Bool { store.library.isEnded(task) }
    private var complete: Bool { store.library.isComplete(task) }

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                if task.exam != nil {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ExamEmphasis(task: task, library: store.library, now: context.date)
                    }
                }
                HStack(spacing: 10) {
                    Button("作业文件", systemImage: "folder") { proxy.scrollTo("materials", anchor: .top) }
                    Button(task.exam == nil ? "提交清单" : "考后确认", systemImage: "checklist") { proxy.scrollTo("checklist", anchor: .top) }
                }.buttonStyle(.glass)
                if let folder = store.courseFolderURL(task.courseID) {
                    Button("本地课程文件夹", systemImage: "folder") { store.reveal(folder) }.buttonStyle(.glass)
                }
                dates
                VStack(alignment: .leading, spacing: 7) {
                    Text(ended ? "跟进状态" : "下一步").font(.subheadline).fontWeight(.semibold)
                    Text(ended ? "已结束跟进，保留成绩和实际提交记录。可随时恢复。" : complete ? store.library.followUpLabel(task) + "。提交、评分和反馈分别记录。" : task.nextStep)
                        .font(.body).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 12) {
                    Text("要求").font(.headline)
                    Text(task.instructions).foregroundStyle(.primary).lineSpacing(5)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                checklist.id("checklist")
                VStack(alignment: .leading, spacing: 10) {
                    Label("评分与反馈跟进", systemImage: "text.badge.checkmark").font(.headline)
                    Text(store.library.followUpLabel(task)).font(.subheadline.weight(.semibold))
                    if let assessment = task.assessment {
                        Text(assessment.note).textSelection(.enabled)
                        Text("评分核对：" + CourseDate.format(assessment.checkedAt, includeYear: true)).font(.caption).foregroundStyle(.secondary)
                        if let url = SafeLink.url(assessment.sourceURL) { Link("查看平台成绩与反馈", destination: url) }
                    } else {
                        Text("尚无独立评分核对记录，提交完成不代表已经出分。").foregroundStyle(.secondary)
                    }
                    if task.gradingState == .graded && !ended {
                        Button(store.library.hasReviewedAssessment(task) ? "恢复成绩跟进" : "成绩与反馈已查看 / 已处理") {
                            store.update { $0.reviewAssessment(taskID: task.id, reviewed: !store.library.hasReviewedAssessment(task)) }
                        }.buttonStyle(.glass)
                        Text("只记录你已查看或处理，不改变平台成绩；新分数或新反馈会重新进入跟进。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let feedback = task.feedback, !feedback.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("老师反馈", systemImage: "text.bubble").font(.headline)
                        if let grade = task.grade { Text(grade).font(.title3).fontWeight(.semibold) }
                        Text(feedback).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if let grade = task.grade {
                    LabeledContent("成绩", value: grade).font(.headline)
                }
                materials.id("materials")
                personalPlan
                VStack(alignment: .leading, spacing: 8) {
                    Label("来源与核对", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text(task.sourceName)
                    Text("核对时间：\(CourseDate.format(task.checkedAt, includeYear: true)) · 课程时区")
                    Text("这是保存的核对记录，不代表平台当前状态。App 不连接课程账号。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Palette.paper)
        .navigationTitle(task.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if !complete && !ended && !task.cancelled {
                    Button(progress.startedAt == nil ? "开始准备" : "撤销开始", systemImage: progress.startedAt == nil ? "play" : "arrow.uturn.backward") {
                        store.begin(task)
                    }.buttonStyle(.glass)
                } else {
                    Label(task.cancelled ? "已取消" : ended ? "已结束" : store.library.followUpLabel(task), systemImage: task.cancelled ? "minus.circle" : ended ? "archivebox" : "checkmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !task.cancelled {
                    Button(ended ? "恢复跟进" : "结束跟进") {
                        store.setFollowUpEnded(task, ended: !ended)
                    }.buttonStyle(.glass)
                }
                Spacer(minLength: 8)
                if let url = store.catalog.assignmentURL(for: task) {
                    Link(destination: url) { Label("打开作业平台", systemImage: "arrow.up.right") }
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 15)
            .background(.bar)
        }
      }
        .sheet(isPresented: $showingCourse) {
            if let course = store.library.course(for: task) {
                NavigationStack {
                    CompactCourseOverview(store: store, course: course)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回作业") { showingCourse = false } } }
                }
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 650)
                #endif
            }
        }
        .sheet(isPresented: $editing) { PlanEditor(store: store, task: task) }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): store.addAttachment(url, to: task)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $readingResource) { resource in
            NavigationStack {
                ResourceReader(store: store, resource: resource)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回作业") { readingResource = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 780, minHeight: 680)
            #endif
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            let course = store.library.course(for: task)
            Button {
                if let openCourse { openCourse() } else { showingCourse = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed")
                    Text(course?.code ?? "课程")
                    Image(systemName: "chevron.right").font(.caption)
                }.font(.subheadline)
            }.buttonStyle(.glass).accessibilityLabel("查看课程 " + (course?.code ?? ""))
            Text(task.title).font(.largeTitle).fontWeight(.bold)
            Text(task.subtitle).font(.title3).foregroundStyle(.secondary)
            Label(store.library.status(task), systemImage: ended ? "archivebox" : complete ? (store.library.isResolved(task) ? "checkmark.circle" : "clock") : "circle.dashed")
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.canvas, in: Capsule())
                .foregroundStyle(store.library.isResolved(task) ? .teal : store.library.needsAssessmentFollowUp(task) ? .orange : .secondary)
        }
    }

    var dates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if let exam = task.exam {
                LabeledContent("考试日期", value: exam.dateLabel)
                LabeledContent("考试时段", value: exam.timeLabel)
                Text(exam.timeNote).foregroundStyle(.secondary)
                Text(exam.locationNote).foregroundStyle(.secondary)
            } else { LabeledContent("正式截止") {
                Text(task.dueAt.map { CourseDate.format($0) } ?? "未设正式截止").fontWeight(.medium)
            } }
            if let close = task.closesAt {
                LabeledContent("页面关闭", value: CourseDate.format(close))
            }
            if let open = task.opensAt {
                LabeledContent("开放时间", value: CourseDate.format(open))
            }
            Text("课程时间：洛杉矶")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
        }.font(.subheadline)
    }

    var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(task.exam == nil ? "提交清单" : "考后确认（不要提前勾选）").font(.headline)
                Spacer()
                Text("\(store.library.completedCount(task)) / \(task.deliveries.count) 已确认")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("completion-count")
            }.padding(.bottom, 10)
            ForEach(task.deliveries) { item in
                Toggle(isOn: Binding(get: { store.library.isComplete(item, in: task) },
                    set: { store.confirm(task, item, complete: $0) })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.body)
                            Text(item.note).font(.caption).foregroundStyle(.secondary)
                            if let user = progress.confirmations[item.id] {
                                Text("你在 \(CourseDate.format(user.recordedAt)) \(user.isComplete ? "确认完成" : "取消完成标记")")
                                    .font(.caption).foregroundStyle(.teal)
                            } else {
                                Text(item.evidence.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(ChecklistStyle())
                    .disabled(task.cancelled)
                    .accessibilityIdentifier("delivery-\(item.id)")
                    .padding(.vertical, 13)
                Divider()
            }
            Text("勾选记录本机确认，实际提交请到作业平台完成。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }
    }

    var materials: some View {
        LazyVStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("作业文件").font(.headline)
                Spacer()
                Button("添加文件", systemImage: "paperclip") { choosingFile = true }
                    .buttonStyle(.borderless).font(.subheadline)
            }
            let assignmentURL = store.catalog.assignmentURL(for: task)?.absoluteString
            let bundled = store.catalog.resources(forTask: task.id).filter {
                $0.format != "link" || $0.sourceURL != assignmentURL
            }
            ForEach([StudyCategory.work, .assignment, .lecture, .reading, .announcement, .overview], id: \.self) { category in
                let items = bundled.filter { $0.category == category }
                if !items.isEmpty {
                    Text(category == .assignment ? "要求与模板" : category.label)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 5)
                    if category == .work {
                        let archives = items.filter { $0.relativePath?.contains("/90_我的提交/") == true }
                        let drafts = items.filter { $0.relativePath?.contains("/90_我的提交/") != true }
                        ForEach(archives.sorted { ($0.fileRole == "submitted" ? 0 : 1) < ($1.fileRole == "submitted" ? 0 : 1) }) { resource in materialButton(resource) }
                        if !drafts.isEmpty { DisclosureGroup("草稿与制作过程（\(drafts.count) 份，未作为提交证明）") { ForEach(drafts) { resource in materialButton(resource) } } }
                    } else {
                        ForEach(items) { resource in materialButton(resource) }
                    }
                }
            }
            ForEach(task.materials) { material in
                if let url = SafeLink.url(material.url) {
                    Link(destination: url) { Label(material.title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            ForEach(progress.attachments) { attachment in
                Button {
                    if let url = store.attachmentURL(attachment) { previewURL = url }
                    else { store.errorMessage = "本机找不到这份附件。请重新添加原文件。" }
                } label: {
                    Label(attachment.name, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderless)
            }
            if bundled.isEmpty && task.materials.isEmpty && progress.attachments.isEmpty {
                Text("这项作业尚未收录文件。可打开作业平台查看原始要求。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(store.workspaceRoot == nil ? "附件保存在 App 本机库；连接课程文件夹后可统一管理。" : "本课程中的文件直接关联原件；从其他位置添加的文件复制到本课程 90_我的提交/课序添加。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func materialButton(_ resource: StudyResource) -> some View {
        Button { readingResource = resource } label: {
            HStack {
                StudyResourceRow(resource: resource, store: store)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    var personalPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的计划与笔记").font(.headline)
                Spacer()
                Button("编辑", systemImage: "pencil") { editing = true }.buttonStyle(.borderless)
            }
            if let planned = progress.plannedAt { Label(CourseDate.format(planned), systemImage: "calendar.badge.clock") }
            Text(progress.notes.isEmpty ? "尚未添加笔记。" : progress.notes)
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("笔记与个人安排保存在本机。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ChecklistStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(configuration.isOn ? Color.teal : .secondary)
                    .padding(.top, 1)
                configuration.label.foregroundStyle(.primary)
                Spacer(minLength: 0)
            }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已勾选" : "未勾选")
    }
}

struct PlanEditor: View {
    @Bindable var store: LibraryStore
    var task: Assignment
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var planned = false
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("个人安排，不改变正式截止") {
                    Toggle("安排开始时间", isOn: $planned)
                    if planned { DatePicker("开始", selection: $date) }
                }
                Section("笔记") {
                    TextEditor(text: $notes).frame(minHeight: 180).accessibilityLabel("我的笔记")
                }
            }.formStyle(.grouped)
            .navigationTitle("我的计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.update({
                            var progress = $0.progress[task.id] ?? TaskProgress()
                            progress.notes = notes
                            progress.plannedAt = planned ? date : nil
                            $0.progress[task.id] = progress
                        }) { dismiss() }
                    }
                }
            }
        }
        .onAppear {
            let progress = store.library.progress[task.id] ?? TaskProgress()
            notes = progress.notes
            planned = progress.plannedAt != nil
            date = progress.plannedAt ?? .now
        }
        #if os(macOS)
        .frame(width: 520, height: 450)
        #endif
    }
}
