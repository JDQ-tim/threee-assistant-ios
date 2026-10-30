import SwiftUI

@MainActor
struct ScheduleView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var detail: ScheduleInstance?
    @State private var showNew = false

    /// 勾选失败时的临时提示，几秒后自动消失
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    /// 列表右滑要删的那一条。非 nil 时弹确认。
    @State private var pendingDelete: ScheduleInstance?

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar

                if store.scope == .month {
                    MonthGrid(
                        anchor: store.monthAnchor,
                        days: store.dayGroups,
                        selected: nil,
                        onPick: { day in
                            Task {
                                await store.setScope(.week)
                                await store.jumpTo(day: day)
                            }
                        }
                    )
                    .padding(.bottom, 6)
                }

                ScrollView {
                    if let msg = store.errorMessage {
                        ErrorBanner(message: msg)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    content
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 28)
                }
                .refreshable { await store.refresh() }
            }
            .background(Theme.background)
            .navigationTitle("日程")
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
            .sheet(item: $detail) { item in
                EventDetailSheet(item: item, calendar: store.calendarsByID[item.calendarID])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showNew) {
                NewEventSheet()
                    .presentationDetents([.large])
            }
            // 列表右滑删除的确认。
            //
            // ⚠️ 这里对重复日程**只给「删这一次」一个选项**，不提供「删整个系列」：
            //    滑动删除是个"轻"动作（虽然关了全滑），
            //    在这么轻的入口上放一个能抹掉几十条日程的操作太危险。
            //    想删整个系列去详情页，那里有完整说明和二次文案。
            .alert("删除这条日程？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { item in
                Button("删除", role: .destructive) {
                    performDelete(item)
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(deleteMessage(for: item))
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t)
                        .font(.footnote)
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

    // MARK: - 顶部操作条

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    Task { await store.shift(by: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceAlt)
                        .clipShape(Circle())
                }

                Spacer(minLength: 4)

                VStack(spacing: 1) {
                    Text(rangeLabel)
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                    if store.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }

                Spacer(minLength: 4)

                Button("今天") {
                    Task { await store.goToday() }
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surfaceAlt)
                .clipShape(Capsule())

                Button {
                    Task { await store.shift(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceAlt)
                        .clipShape(Circle())
                }
            }
            .foregroundStyle(Theme.textSecondary)

            // 周/月切换。放在操作条下面单独一行，
            // 是因为它和"翻页"是两种不同层级的选择，挤在一行会让人分不清
            Picker("视图", selection: Binding(
                get: { store.scope },
                set: { s in Task { await store.setScope(s) } }
            )) {
                ForEach(SessionStore.CalendarScope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var rangeLabel: String {
        switch store.scope {
        case .week:
            let start = store.weekStart
            let end = store.weekStart.addingDays(6)
            let cal = Calendar.current
            let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
            if sameMonth {
                return "\(start.monthDay) – \(cal.component(.day, from: end))日"
            }
            return "\(start.monthDay) – \(end.monthDay)"

        case .month:
            return store.monthAnchor.yearMonth
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        let groups = store.dayGroups

        if groups.isEmpty {
            if store.isLoading {
                ProgressView("正在同步…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            } else {
                EmptyHint(
                    icon: "calendar",
                    title: store.scope == .month ? "这个月还没有安排" : "这周还没有安排",
                    subtitle: "点右上角的 + 新建一条"
                )
            }
        } else if isRegular && groups.count >= 2 && store.scope == .week {
            // iPad：分两栏。
            // ⚠️ 不是「隔一天放一栏」，而是**前半周在左、后半周在右** ——
            //    这样每栏高度接近，右边不会出现一大片空白。
            // ⚠️ 只有一天时不分栏（分了会留一个空列，比单列更难看）。
            // ⚠️ 月视图不分栏：一整个月分成两列读起来没有顺序感。
            HStack(alignment: .top, spacing: 20) {
                column(Array(groups.prefix(half(of: groups.count))))
                column(Array(groups.suffix(from: half(of: groups.count))))
            }
        } else {
            column(groups)
        }
    }

    private func half(of count: Int) -> Int {
        max(1, Int((Double(count) / 2).rounded(.up)))
    }

    private func column(_ groups: [DayGroup]) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    DayHeaderView(day: group.day, relativeDays: store.scope == .week)
                    ForEach(group.items) { item in
                        rowButton(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowButton(_ item: ScheduleInstance) -> some View {
        Button {
            detail = item
        } label: {
            EventRowView(
                item: item,
                calendar: store.calendarsByID[item.calendarID],
                repeatRule: store.repeatRuleByEventID[item.eventID]
            )
        }
        .buttonStyle(.plain)
        // 左侧：只有待办才给勾选。日程滑出「完成」没有意义，
        // 给了反而让人误以为能把一节课标记成"做完"。
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.isTask {
                Button {
                    toggleDone(item)
                } label: {
                    Label(item.isDone ? "取消完成" : "完成",
                          systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(item.isDone ? Theme.textSecondary : Theme.teal600)
            }
        }
        // 右侧：删除。`allowsFullSwipe: false` 是刻意的 ——
        // 全滑删除在日程列表上太危险，重复日程一不小心就带走整个系列。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 滑删的确认文案。
    ///
    /// 重复日程必须说清楚「只删这一次」—— 否则用户滑掉一次，
    /// 转头发现后面所有次都还在，会觉得删除坏了；
    /// 反过来如果真删了整个系列又不明说，那是更严重的意外。
    private func deleteMessage(for item: ScheduleInstance) -> String {
        let name = "「\(item.title ?? "无标题")」"
        let recurring = !(store.repeatRuleByEventID[item.eventID] ?? "").isEmpty
        if recurring {
            return name + " 是重复日程。这里只会删掉 "
                + item.start.monthDay + " " + item.start.hhmm + " 这一次，"
                + "其它几次不受影响。\n\n想删掉整个系列，请打开这条日程后在详情页操作。"
        }
        return name + " 将被删除，其它设备同步后也会消失。"
    }

    private func performDelete(_ item: ScheduleInstance) {
        pendingDelete = nil
        Task {
            do {
                // 始终走「只删这一次」：单次日程用这个接口也完全正确
                // （它只有一个实例），而重复日程正是我们要的行为。
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

    private func toggleDone(_ item: ScheduleInstance) {        Task {
            do {
                try await store.setDone(item, done: !item.isDone)
            } catch {
                // 勾选失败不该弹出整页红色横幅 —— 那会盖住整个列表，
                // 而用户只是滑了一下。用一条会自己消失的提示。
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
