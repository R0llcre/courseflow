import SwiftUI
import UniformTypeIdentifiers

struct InboxView: View {
    @Bindable var store: LibraryStore
    var compact: Bool
    var select: (String) -> Void

    var body: some View {
        List {
            Section {
                Text("课程更新与反馈")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            ForEach(store.library.notices.sorted { $0.createdAt > $1.createdAt }) { notice in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        if !store.library.readNoticeIDs.contains(notice.id) {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 6)
                        }
                        Text(notice.title).font(.headline)
                    }
                    Text(notice.detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(CourseDate.format(notice.createdAt)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let id = notice.taskID {
                            if compact { NavigationLink("查看任务", value: id) }
                            else { Button("查看任务") { select(id) }.buttonStyle(.borderless) }
                        }
                        Spacer()
                        if !store.library.readNoticeIDs.contains(notice.id) {
                            Button("标为已读") { store.markRead(notice) }.buttonStyle(.borderless)
                        } else { Label("已读", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 12)
            }
            if store.library.notices.isEmpty {
                ContentUnavailableView("暂无更新", systemImage: "tray",
                    description: Text("导入课程更新包后，可在这里查看变化。"))
            }
        }.listStyle(.plain)
    }
}

struct ImportReview: View {
    let bundle: UpdateBundle
    let preview: ImportPreview
    var apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("第 \(bundle.revision) 版 · \(CourseDate.format(bundle.generatedAt))") {
                    Text(preview.isDuplicate ? "这份更新包已导入，无需重复处理。" : "新增 \(preview.additions.count) 项，更新 \(preview.changes.count) 项，课程资料变化 \(preview.courseChanges) 项。")
                    Text("你的勾选、计划、笔记和附件关联保留；更新包未包含的任务不会删除。")
                        .foregroundStyle(.secondary)
                }
                changeSection("新增任务", changes: preview.additions)
                changeSection("变化预览", changes: preview.changes)
                changeSection("不覆盖旧来源", changes: preview.skipped)
            }
            .navigationTitle("核对课程更新")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if preview.isDuplicate { Button("完成") { dismiss() } }
                    else { Button("确认导入", action: apply) }
                }
            }
        }
        #if os(macOS)
        .frame(width: 620, height: 520)
        #endif
    }

    @ViewBuilder func changeSection(_ title: String, changes: [ImportChange]) -> some View {
        if !changes.isEmpty {
            Section(title) {
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.title).font(.headline)
                        Text(change.detail).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }
    }
}

struct NewTaskView: View {
    @Bindable var store: LibraryStore
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var courseID = "dma"
    @State private var title = ""
    @State private var dueEnabled = true
    @State private var due = Date.now
    @State private var checklist = "已完成"
    @State private var instructions = ""

    private var items: [String] { checklist.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty && items.count <= 30 }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("名称", text: $title)
                    Picker("课程", selection: $courseID) {
                        ForEach(store.library.courses) { Text($0.code).tag($0.id) }
                    }
                    Toggle("有正式截止", isOn: $dueEnabled)
                    if dueEnabled { DatePicker("正式截止", selection: $due) }
                }
                Section("交付或完成项：一行一个，最多 30 项") {
                    TextEditor(text: $checklist).frame(minHeight: 85).accessibilityLabel("交付项")
                }
                Section("要求与下一步") {
                    TextEditor(text: $instructions).frame(minHeight: 100).accessibilityLabel("任务要求")
                }
                Text("这是你新增的本地任务，不会被助手更新包覆盖。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            .navigationTitle("新建任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        guard let course = store.library.courses.first(where: { $0.id == courseID }), valid else { return }
                        let id = "local-\(UUID().uuidString)"
                        let task = Assignment(id: id, courseID: courseID,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines), subtitle: "个人任务",
                            dueAt: dueEnabled ? due : nil, nextStep: instructions.isEmpty ? "按清单完成。" : instructions,
                            instructions: instructions,
                            deliveries: items.map { Delivery(id: UUID().uuidString, title: $0, note: "用户自行记录", evidence: .unknown) },
                            materials: [], sourceName: "用户新建", sourceURL: course.url, checkedAt: .now, cancelled: false, selfTracked: true)
                        if store.update({ $0.assignments.append(task) }) {
                            onSave(id)
                            dismiss()
                        }
                    }.disabled(!valid)
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 620)
        #endif
    }
}

struct AppSettings: View {
    var store: LibraryStore
    @AppStorage("appearance") private var appearance = "system"
    @State private var choosingWorkspace = false

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Label("课序", systemImage: "square.stack.3d.up").font(.largeTitle).fontWeight(.semibold)
            Text("Berkeley · Fall 2026").foregroundStyle(.secondary)
            Divider()
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            LabeledContent("存储", value: "SwiftData · 仅本机")
            LabeledContent("课程资料", value: "助手维护 · 第 \(store.library.revision) 版")
            if let saved = store.savedAt {
                LabeledContent("最近保存", value: CourseDate.format(saved))
            }
            Text("iCloud 同步、系统提醒和小组件尚未启用；当前版本不会推送截止通知。").foregroundStyle(.secondary)
            Text("导出的 JSON 包含课程资料、笔记与进度，供备份和下次维护核对；不包含附件文件。此版本的导入入口仅接受课程更新包，不用于恢复整个资料库。").foregroundStyle(.secondary)
            Text("App 不保存课程平台账号，不自动抓取或代交作业。打开平台不会改变完成状态。").foregroundStyle(.secondary)
            Divider()
            Text("文件与状态统一入口").font(.headline)
            Text(store.workspaceMessage).textSelection(.enabled)
            Button(store.workspaceRoot == nil ? "连接 Fall26 课程文件夹" : "更换课程文件夹") { choosingWorkspace = true }
            if let root = store.workspaceRoot {
                Text("原文件：" + root.path).textSelection(.enabled)
                HStack {
                    Button("在访达中显示课程文件夹") { store.reveal(root) }
                    Button(store.isRefreshing ? "正在后台刷新…" : "刷新本地索引与状态") { store.refreshWorkspace() }
                }
                if let date = store.lastPublishedAt { Text("文件夹状态同步：" + CourseDate.format(date, includeYear: true)).font(.caption) }
                Text("原始讲义、草稿和提交文件留在课程文件夹。App 直接读取原文件；预览缓存和当前状态位于 Berkeley 26Fall General/课程数据。刷新索引不等于刷新平台成绩。").foregroundStyle(.secondary)
            }
            if let url = store.storageDirectory {
                Text("个人进度主库：" + url.path).font(.caption).textSelection(.enabled)
                Button("显示个人进度存储位置") { store.reveal(url) }
            }
            if let url = store.bundledDirectory {
                Text("未连接文件夹时的内置副本：" + url.path).font(.caption).textSelection(.enabled)
            }
            Text("连接后，App 每次保存都会生成当前总览和各课程状态文件；它们是只读镜像，不是第二套进度库。新增讲义/材料需要助手重建本地索引，然后点刷新；无需重装 App。旧附件仍保留在本机库，不会丢失。").foregroundStyle(.secondary)
        }.font(.subheadline).frame(maxWidth: 700, alignment: .leading) }
        .frame(minWidth: 440, minHeight: 500)
        .fileImporter(isPresented: $choosingWorkspace, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): store.connectWorkspace(url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
    }
}
