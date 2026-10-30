import SwiftUI

// ============================================================
//  待办
//  ------------------------------------------------------------
//
//  为什么从日程列表里拆出来单独一页：
//
//  1. **时间语义不同**。日程是「某个时刻发生的事」，待办是
//     「某天之前要做完的事」。混在一个按日分组的列表里，
//     周二看到一条周一的未完成待办，用户会以为它排在周二。
//  2. **完成态会消失在视野外**。原来勾完的待办留在原位只是变灰，
//     但一翻周就找不到了 —— 想回顾「我这周做完了什么」没有入口。
//  3. **逾期需要集中呈现**。原列表只按日期分组，不区分「已过期」，
//     要用户自己数日子才知道哪条拖了。
//
//  所以这一页按**状态**分组，而不是按日期：
//     逾期 → 进行中 → 已完成
//  这是待办类 App 的标准范式（Things、Reminders、Todoist 都是）。
// ============================================================

@MainActor
struct TasksView: View {

    @Environment(SessionStore.self) private var store

    @State private var detail: ScheduleInstance?
    @State private var showNew = false

    /// 只显示某张日历的待办。nil = 全部。
    /// 用菜单而不是分段控件：日历可能有十几张，分段会挤爆。
    @State private var calendarFilter: String?

    /// 是否显示已完成的待办。默认关 ——
    /// 打开就变成"一堆灰字"，反而把要做的事压下去了。
    @State private var showCompleted = false

    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// 当前范围内所有待办（含已完成）
    private var allTasks: [ScheduleInstance] {
        var list = store.instances.filter { $0.isTask }
        if let cid = calendarFilter {
            list = list.filter { $0.calendarID == cid }
        }
        return list
    }

    /// 今天的零点。用它判断逾期，而不是用「当前时刻」——
    /// 一条今天 23:59 的待办，在 00:01 才该算逾期。
    private var startOfToday: Date {
        Calendar.current.startOfDay(for: .now)
    }

    private var overdue: [ScheduleInstance] {
        allTasks
            .filter { !$0.isDone && $0.start < startOfToday }
            .sorted { $0.start < $1.start }
    }

    private var active: [ScheduleInstance] {
        allTasks
            .filter { !$0.isDone && $0.start >= startOfToday }
            .sorted { $0.start < $1.start }
    }

    private var completed: [ScheduleInstance] {
        allTasks
            .filter { $0.isDone }
            .sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) }
    }

    /// 有未完成待办的日历。筛选项只列这些 ——
    /// 列出一堆没有待办的日历，选了只会看到空白。
    private var filterableCalendars: [CalendarDTO] {
        let ids = Set(store.instances.filter { $0.isTask && !$0.isDone }.map(\.calendarID))
        return store.calendars.filter { ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !filterableCalendars.isEmpty {
                    filterSection
                }

                if overdue.isEmpty && active.isEmpty && completed.isEmpty {
                    emptySection
                } else {
                    if !overdue.isEmpty {
                        section(
                            title: "逾期",
                            items: overdue,
                            tint: Theme.red600
                        )
                    }
                    if !active.isEmpty {
                        section(title: "进行中", items: active, tint: Theme.textPrimary)
                    }
                    if !completed.isEmpty {
                        completedSection
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("待办")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.calendars.isEmpty)
                }
            }
            .refreshable { await store.refresh() }
            .sheet(item: $detail) { item in
                EventDetailSheet(item: item, calendar: store.calendarsByID[item.calendarID])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showNew) {
                NewEventSheet()
                    .presentationDetents([.large])
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.appFootnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.red600)
                        .clipShape(Capsule())
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
        }
    }

    // MARK: - 筛选

    private var filterSection: some View {
        Section {
            Menu {
                Button("全部日历") { calendarFilter = nil }
                Divider()
                ForEach(filterableCalendars) { cal in
                    Button {
                        calendarFilter = cal.id
                    } label: {
                        if calendarFilter == cal.id {
                            Label(cal.name, systemImage: "checkmark")
                        } else {
                            Text(cal.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("日历")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(currentFilterName)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var currentFilterName: String {
        guard let cid = calendarFilter,
              let cal = store.calendarsByID[cid] else { return "全部" }
        return cal.name
    }

    // MARK: - 列表

    private func section(title: String, items: [ScheduleInstance], tint: Color) -> some View {
        Section {
            ForEach(items) { item in
                taskRow(item, overdueHighlight: tint == Theme.red600)
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                if tint == Theme.red600 && !items.isEmpty {
                    Text("\(items.count)")
                        .font(.appBadge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.red600)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var completedSection: some View {
        Section {
            if showCompleted {
                ForEach(completed) { item in
                    taskRow(item, overdueHighlight: false)
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCompleted.toggle()
                }
            } label: {
                HStack {
                    Text(showCompleted ? "收起已完成" : "显示已完成（\(completed.count)）")
                        .font(.appSubheadline)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: showCompleted ? "chevron.up" : "chevron.down")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.appDisplay)
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
                Text("没有待办")
                    .font(.appSubheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("新建日程时把「这是待办」打开，就会出现在这里")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        }
    }

    /// 一行待办。
    ///
    /// 左侧勾选直接可点 —— 待办页的核心动作就是"做完打个勾"，
    /// 再要长按或进详情才勾，等于把最高频的操作藏起来。
    private func taskRow(_ item: ScheduleInstance, overdueHighlight: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                toggleDone(item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.isDone ? Theme.teal600 : Theme.textTertiary)
                    // 44×44 的可点区域，符合 HIG 的最小触控尺寸
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                detail = item
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.nonEmpty(or: "（无标题）"))
                        .font(.appBody)
                        .foregroundStyle(item.isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(item.isDone, color: Theme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.appCaption2)
                        Text(dueText(for: item))
                            .font(.appCaption)
                        if let cal = store.calendarsByID[item.calendarID] {
                            Text("·")
                            Text(cal.name)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(overdueHighlight ? Theme.red600 : Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 截止文案。「今天」「明天」比日期更好读，
    /// 逾期就明说逾期了几天 —— 让人知道拖了多久。
    private func dueText(for item: ScheduleInstance) -> String {
        let due = item.allDay ? item.start : item.end
        let cal = Calendar.current

        if item.isDone {
            guard let ts = item.doneAt else { return "已完成" }
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            return "完成于 " + d.monthDay
        }

        let days = cal.dateComponents([.day], from: startOfToday, to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case 0:  return "今天"
        case 1:  return "明天"
        case -1: return "昨天逾期"
        case ..<(-1): return "逾期 \(-days - 1) 天"
        default: return due.monthDay + " " + due.weekdayName
        }
    }

    // MARK: - 动作

    private func toggleDone(_ item: ScheduleInstance) {
        Task {
            do {
                try await store.setDone(item, done: !item.isDone)
            } catch {
                toast = store.message(for: error)
                toastTask?.cancel()
                toastTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { toast = nil }
                }
            }
        }
    }

    private func delete(_ item: ScheduleInstance) {
        Task {
            do {
                try await store.deleteOccurrence(
                    eventID: item.eventID,
                    occurrenceKey: item.occurrenceKey
                )
            } catch {
                toast = store.message(for: error)
                toastTask?.cancel()
                toastTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { toast = nil }
                }
            }
        }
    }
}
