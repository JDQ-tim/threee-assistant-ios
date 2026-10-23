import SwiftUI

struct ScheduleView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var detail: ScheduleInstance?
    @State private var showNew = false
    @State private var showSettings = false

    /// 勾选失败时的临时提示，几秒后自动消失
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
                        .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 13, weight: .medium))
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
        let row = Button {
            detail = item
        } label: {
            EventRowView(
                item: item,
                calendar: store.calendarsByID[item.calendarID],
                repeatRule: store.repeatRuleByEventID[item.eventID]
            )
        }
        .buttonStyle(.plain)

        // 只有待办才给勾选滑动。日程滑出「完成」是没有意义的动作，
        // 给了反而让人误以为能把一节课标记成"做完"。
        if item.isTask {
            row.swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    toggleDone(item)
                } label: {
                    Label(item.isDone ? "取消完成" : "完成",
                          systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(item.isDone ? Theme.textSecondary : Theme.teal600)
            }
        } else {
            row
        }
    }

    private func toggleDone(_ item: ScheduleInstance) {
        Task {
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
