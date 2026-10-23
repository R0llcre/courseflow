import SwiftUI

struct ScheduleCalendarView: View {
    @Bindable var store: LibraryStore
    var openTask: (String) -> Void
    @State private var month = ScheduleCalendar.monthStart(.now)
    @State private var selectedDay = ScheduleCalendar.calendar.startOfDay(for: .now)
    @State private var courseID = "all"
    @State private var pendingOnly = false
    @State private var includeOpening = false
    @State private var query = ""

    private var events: [ScheduleEvent] {
        ScheduleCalendar.events(in: store.library, courseID: courseID == "all" ? nil : courseID,
            pendingOnly: pendingOnly, includeOpening: includeOpening, query: query)
    }
    private var byDay: [String: [ScheduleEvent]] { Dictionary(grouping: events) { ScheduleCalendar.dayKey($0.date) } }
    private var undated: [Assignment] {
        store.library.sortedTasks(store.library.assignments.filter { task in
            !task.cancelled && task.exam == nil && task.dueAt == nil && task.closesAt == nil && store.library.progress[task.id]?.plannedAt == nil &&
            (courseID == "all" || task.courseID == courseID) &&
            (!pendingOnly || store.library.needsSubmission(task) || store.library.needsAssessmentFollowUp(task)) &&
            (query.isEmpty || [task.title, task.subtitle, store.library.course(for: task)?.code ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query))
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 560
            let grouped = byDay
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(ScheduleCalendar.label(month, format: "yyyy年 M月")).font(.system(size: wide ? 28 : 22, weight: .semibold))
                            .accessibilityIdentifier("calendar-month")
                        Spacer()
                        Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                        Button("今天") { month = ScheduleCalendar.monthStart(.now); selectedDay = ScheduleCalendar.calendar.startOfDay(for: .now) }
                        Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
                    }.buttonStyle(.bordered)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { filters }
                        VStack(alignment: .leading, spacing: 10) { filters }
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                                Text(day).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 1), count: 7), spacing: 1) {
                            ForEach(ScheduleCalendar.days(in: month), id: \.self) { day in
                                dayCell(day, events: grouped[ScheduleCalendar.dayKey(day)] ?? [], wide: wide)
                            }
                        }.padding(1).background(Color.secondary.opacity(0.15))
                    }
                    HStack(spacing: 12) {
                        Text("课程时间：洛杉矶").fontWeight(.medium)
                        Text("截止 ≠ 页面关闭；个人计划不改动截止日期。")
                    }.font(.caption).foregroundStyle(.secondary)
                    selectedDayList(grouped[ScheduleCalendar.dayKey(selectedDay)] ?? [])
                    if !undated.isEmpty {
                        DisclosureGroup("未安排日期（\(undated.count) 项）") {
                            ForEach(undated) { task in
                                Button { openTask(task.id) } label: {
                                    HStack { Text(store.library.course(for: task)?.code ?? "").foregroundStyle(.secondary); Text(task.title); Spacer(); Image(systemName: "chevron.right") }
                                        .font(.subheadline).padding(.vertical, 9).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Text("日历显示本机已有的作业日期，不代表上课时间表。资料更新：\(store.library.generatedAt.map { CourseDate.format($0) } ?? "尚未导入")。评分仍在“评分跟进”中单独核对。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(wide ? 28 : 14).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.background(Palette.paper)
        }
        .searchable(text: $query, prompt: "搜索日历中的课程或作业")
    }

    @ViewBuilder private var filters: some View {
        Picker("课程", selection: $courseID) {
            Text("全部课程").tag("all")
            ForEach(store.library.courses) { Text($0.code).tag($0.id) }
        }.frame(maxWidth: 260)
        Toggle("仅待办", isOn: $pendingOnly)
        Toggle("显示开放日期", isOn: $includeOpening)
    }

    private func changeMonth(_ offset: Int) {
        month = ScheduleCalendar.shiftMonth(month, by: offset)
        selectedDay = month
    }

    private func dayCell(_ day: Date, events: [ScheduleEvent], wide: Bool) -> some View {
        let calendar = ScheduleCalendar.calendar
        let currentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let today = calendar.isDate(day, inSameDayAs: .now)
        return Button {
            selectedDay = day
            if !currentMonth { month = ScheduleCalendar.monthStart(day) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 14, weight: today || selected ? .bold : .regular))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(today ? .white : currentMonth ? Color.primary : .secondary)
                        .background(today ? Color.accentColor : .clear, in: Circle())
                    Spacer(minLength: 0)
                    if wide && !events.isEmpty { Text("\(events.count)").font(.caption2).foregroundStyle(.secondary) }
                }
                if wide {
                    ForEach(events.prefix(2)) { event in
                        if let task = store.library.assignments.first(where: { $0.id == event.taskID }) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1).fill(event.kind == .exam ? .red : Palette.course(store.library.course(for: task)?.color ?? "blue")).frame(width: 3)
                                Text(event.kind.label + " " + task.title).font(.system(size: 11, weight: event.kind == .exam ? .bold : .regular)).lineLimit(1).foregroundStyle(event.kind == .exam ? .red : .primary)
                            }.frame(height: 16)
                        }
                    }
                    if events.count > 2 { Text("另 \(events.count - 2) 项").font(.system(size: 10)).foregroundStyle(.secondary) }
                } else {
                    HStack(spacing: 3) {
                        ForEach(events.prefix(3)) { event in
                            Circle().fill(Palette.course(store.library.assignments.first(where: { $0.id == event.taskID }).flatMap { store.library.course(for: $0)?.color } ?? "blue")).frame(width: 4, height: 4)
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(wide ? 7 : 3).frame(maxWidth: .infinity).frame(height: wide ? 98 : 52, alignment: .topLeading)
                .background(selected ? Color.accentColor.opacity(0.10) : calendar.isDateInWeekend(day) ? Palette.canvas : Palette.paper)
                .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(ScheduleCalendar.label(day, format: "M月d日 EEEE") + "，\(events.count) 项" + (today ? "，今天" : ""))
        .accessibilityValue(selected ? "已选中" : "")
        .accessibilityIdentifier("calendar-day-" + ScheduleCalendar.dayKey(day))
    }

    private func selectedDayList(_ events: [ScheduleEvent]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ScheduleCalendar.label(selectedDay, format: "M月d日 EEEE")).font(.title3.weight(.semibold))
                Spacer()
                Text("\(events.count) 项").font(.subheadline).foregroundStyle(.secondary)
            }
            if events.isEmpty { Text("当天没有符合筛选条件的作业或计划。").foregroundStyle(.secondary).padding(.vertical, 10) }
            ForEach(events) { event in
                if let task = store.library.assignments.first(where: { $0.id == event.taskID }) {
                    Button { openTask(task.id) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.kind == .exam && task.exam?.startsAt == nil ? "待通知" : ScheduleCalendar.label(event.date, format: "HH:mm")).font(.headline.monospacedDigit())
                                Text(event.kind.label).font(.caption).foregroundStyle(event.kind == .exam ? .red : event.kind == .closes ? .orange : .secondary)
                            }.frame(width: 72, alignment: .leading)
                            Rectangle().fill(Palette.course(store.library.course(for: task)?.color ?? "blue")).frame(width: 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.headline)
                                Text(store.library.course(for: task)?.code ?? "").font(.caption).foregroundStyle(.secondary)
                                if event.kind == .exam, let exam = task.exam {
                                    Text(exam.timeNote).font(.caption)
                                    Text(exam.locationNote).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(store.library.status(task)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("calendar-event-" + event.id)
                    Divider()
                }
            }
        }
    }
}
