import SwiftUI

// ============================================================
//  日程
//  ------------------------------------------------------------
//  2026-11-05 按安卓端重做。四个子视图在**页内**切换：
//
//      列表 ─ 选中那一天，按「待办 / 全天 / 上午 / 下午 / 晚上」分段
//      月   ─ 整月，一格只表达"这天有几条"
//      课表 ─ 节次 × 星期，只看 kind=="course" 的那张日历
//      融合 ─ 一周 × 时间轴，所有日历叠在一起
//
//  ## 为什么四个挤在一页而不是各占一个底部 Tab
//
//  安卓端的注释说得很直白（`Pages.kt:14`）：底部只有 5 个位置，
//  月历/课表/融合各占一个的话，「收件箱」和「AI」根本没地方放。
//  而且这四个视图看的是**同一份数据**的不同切面，切换时用户期待
//  "还停在这一周" —— 分到不同 Tab 反而每次都要重新定位。
//
//  ## 「待办」不再是独立 Tab
//
//  它是「列表」里的第一个分组。理由：待办和日程是同一份数据
//  （`is_task` 一个布尔位），分成两个入口会出现"这条算哪边"的二义性。
//  跨天的待办汇总仍然保留，从列表顶部的「全部待办」进。
//
//  ## 顶部周条只跟「天」有关，跟视图无关
//
//  列表/课表/融合都用它选"看哪一周的哪天"；月视图有自己的格子，
//  不需要周条 —— 两套日期控件同时出现会让人不知道该点哪个。
// ============================================================

@MainActor
struct ScheduleView: View {

    @Environment(SessionStore.self) private var store
    /// 日历色条、课块颜色要按当前外观取（深色下用亮一档那套）。
    /// 这是**读 environment**，不是读 `AppearanceStore` ——
    /// 后者已经被根视图翻译成 `preferredColorScheme` 了，
    /// 视图里能拿到的 `colorScheme` 才是真正生效的那个。
    @Environment(\.colorScheme) private var scheme

    @State private var mode: SubView = .agenda
    @State private var selectedDate: Date = Date.now.startOfDay

    @State private var detail: ScheduleInstance?
    @State private var showNew = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var pendingDelete: ScheduleInstance?

    @State private var periods: [CoursePeriod] = CourseDefaults.periods
    @State private var hiddenCalendarIDs: Set<String> = []

    enum SubView: String, CaseIterable, Identifiable {
        case agenda, month, timetable, merged
        var id: String { rawValue }
        var label: String {
            switch self {
            case .agenda:    return "列表"
            case .month:     return "月"
            case .timetable: return "课表"
            case .merged:    return "融合"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                subTabBar

                if mode != .month {
                    weekStrip
                }

                ScrollView {
                    if let msg = store.errorMessage {
                        ErrorBanner(message: msg)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    content
                        .padding(.horizontal, 16)
                        .padding(.top, mode == .month ? 6 : 2)
                        .padding(.bottom, 90)
                }
                .refreshable { await store.refresh() }
            }
            .background(Theme.background)
            .navigationTitle("日程")
            .navigationBarTitleDisplayMode(.inline)
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
            .overlay(alignment: .bottomTrailing) {
                // 悬浮加号。安卓端也是这个位置 —— 列表可能很长，
                // 工具栏那个 + 在滚动之后离拇指太远。
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Theme.blue600)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                }
                .disabled(store.calendars.isEmpty)
                .padding(.trailing, 20)
                .padding(.bottom, 18)
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
                        .padding(.bottom, 84)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
            .sheet(item: $detail) { item in
                EventDetailSheet(item: item, calendar: store.calendarsByID[item.calendarID])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showNew) {
                NewEventSheet()
                    .presentationDetents([.large])
            }
            .alert("删除这条日程？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { item in
                Button("删除", role: .destructive) { performDelete(item) }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(deleteMessage(for: item))
            }
            .task {
                periods = await store.loadCoursePeriods()
                // 进页面先把 scope 校准成"周" —— 上一次可能是月视图退出的，
                // 否则列表会拿到整个月的数据，分段里混进别的日子。
                if mode != .month { await store.setScope(.week) }
            }
            .onChange(of: mode) { _, m in
                Task { await store.setScope(m == .month ? .month : .week) }
            }
        }
    }

    // MARK: - 子标签

    private var subTabBar: some View {
        HStack(spacing: 6) {
            ForEach(SubView.allCases) { v in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { mode = v }
                } label: {
                    Text(v.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mode == v ? Theme.blue600 : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(mode == v ? Theme.blue50 : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - 周条

    /// 七个格子，选中日填色。
    ///
    /// 值取的是 `store.weekStart`，不是 `selectedDate` 所在周 ——
    /// 两者在跳周时会短暂不同步，以 store 为准才不会出现
    /// "点了一天，条上却没有它"。
    private var weekStrip: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let d = store.weekStart.addingDays(i)
                let isSelected = Calendar.current.isDate(d, inSameDayAs: selectedDate)
                let isToday = Calendar.current.isDateInToday(d)
                Button {
                    selectedDate = d.startOfDay
                } label: {
                    VStack(spacing: 2) {
                        Text(Self.weekdayShort(i))
                            .font(.system(size: 10.5))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Theme.textTertiary)
                        Text("\(Calendar.current.component(.day, from: d))")
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : (isToday ? Theme.blue600 : Theme.textPrimary))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Theme.blue600 : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 周条里第 0 格永远是周一，和 `startOfWeekMonday` 对齐。
    static func weekdayShort(_ index: Int) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        guard index >= 0 && index < names.count else { return "" }
        return names[index]
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .agenda:
            agendaView
        case .month:
            monthView
        case .timetable:
            timetableView
        case .merged:
            mergedView
        }
    }

    // MARK: 列表

    /// 待办：没做完、且开始时间不晚于今天结束。
    ///
    /// ⚠️ 口径照抄安卓端 `AgendaTab.kt:166`。它**不按选中日期过滤** ——
    ///    昨天没做完的那件今天还得做，按日期滤掉等于帮用户藏事。
    private var pendingTasks: [ScheduleInstance] {
        let endOfToday = Date.now.startOfDay.addingDays(1)
        return store.instances
            .filter { $0.isTask && !$0.isDone && $0.start < endOfToday }
            .sorted { $0.startUTC < $1.startUTC }
    }

    /// 选中那天的日程（不含上面已被"待办"收走的那批）。
    private var selectedDayItems: [ScheduleInstance] {
        let cal = Calendar.current
        let pendingIDs = Set(pendingTasks.map(\.id))
        return store.instances
            .filter { cal.isDate($0.start, inSameDayAs: selectedDate) }
            .filter { !pendingIDs.contains($0.id) }
            .sorted { $0.startUTC < $1.startUTC }
    }

    private var agendaView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(dayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                NavigationLink {
                    TasksView()
                } label: {
                    Text("全部待办")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.blue600)
                }
            }

            if pendingTasks.isEmpty && selectedDayItems.isEmpty {
                emptyDay
            } else {
                if !pendingTasks.isEmpty {
                    section("待办", items: pendingTasks)
                }

                let allDay = selectedDayItems.filter(\.allDay)
                if !allDay.isEmpty {
                    section("全天", items: allDay)
                }

                ForEach(Self.partOrder, id: \.self) { part in
                    let list = selectedDayItems.filter { !$0.allDay && Self.partOfDay($0.start) == part }
                    if !list.isEmpty {
                        section(part, items: list)
                    }
                }
            }
        }
    }

    /// 分段顺序与时段划分照抄安卓端 `AgendaTab.kt:694`：
    /// 上午 h<12，下午 h<18，晚上其余。
    static let partOrder = ["上午", "下午", "晚上"]

    static func partOfDay(_ d: Date) -> String {
        let h = Calendar.current.component(.hour, from: d)
        if h < 12 { return "上午" }
        if h < 18 { return "下午" }
        return "晚上"
    }

    private var dayTitle: String {
        let cal = Calendar.current
        let rel: String
        if cal.isDateInToday(selectedDate) { rel = "今天" }
        else if cal.isDateInTomorrow(selectedDate) { rel = "明天" }
        else if cal.isDateInYesterday(selectedDate) { rel = "昨天" }
        else { rel = Self.weekdayCN(selectedDate) }
        let m = cal.component(.month, from: selectedDate)
        let d = cal.component(.day, from: selectedDate)
        return "\(rel) · \(m)月\(d)日"
    }

    static func weekdayCN(_ d: Date) -> String {
        let w = Calendar.current.component(.weekday, from: d)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let i = w - 1
        return (i >= 0 && i < names.count) ? names[i] : ""
    }

    private func section(_ title: String, items: [ScheduleInstance]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        detail = item
                    } label: {
                        agendaRow(item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    if item.id != items.last?.id {
                        Divider().overlay(Theme.separator)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
        }
    }

    /// 一行：时间（开始大字、结束小字）+ 日历色条 + 标题/地点。
    private func agendaRow(_ item: ScheduleInstance) -> some View {
        let color = CalendarPalette.display(
            store.calendarsByID[item.calendarID]?.displayColor ?? CalendarPalette.defaultLight,
            dark: scheme == .dark
        )
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.allDay ? "全天" : item.start.hhmm)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                if !item.allDay && item.hasSpan {
                    Text(item.end.hhmm)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 44, alignment: .trailing)

            Rectangle()
                .fill(color)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.nonEmpty(or: "（无标题）"))
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(item.isDone ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(item.isDone, color: Theme.textTertiary)
                    .lineLimit(1)
                let meta = rowMeta(item)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.appCaption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if item.isTask {
                Button {
                    toggleDone(item)
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(item.isDone ? Theme.teal600 : Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private func rowMeta(_ item: ScheduleInstance) -> String {
        var parts: [String] = []
        if let loc = item.location, !loc.isEmpty { parts.append(loc) }
        if let name = store.calendarsByID[item.calendarID]?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var emptyDay: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 30))
                .foregroundStyle(Theme.textTertiary)
            Text(store.isLoading ? "正在读取…" : "这一天还没有安排")
                .font(.appSubheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("点右下角的 + 新建一条")
                .font(.appFootnote)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: 月

    private var monthView: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    Task { await store.shiftMonth(by: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 1) {
                    Text(store.monthAnchor.yearMonth)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    weekBadge
                }

                Spacer()

                Button {
                    Task { await store.goToday() }
                } label: {
                    Text("今天")
                        .font(.appFootnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceAlt)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await store.shiftMonth(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 2)

            MonthGrid(
                anchor: store.monthAnchor,
                days: store.dayGroups,
                selected: nil,
                onPick: { day in
                    Task {
                        selectedDate = day.startOfDay
                        await store.jumpTo(day: day)
                        withAnimation(.easeInOut(duration: 0.18)) { mode = .agenda }
                    }
                }
            )

            // 月视图下也列这一周的日程 —— 光有格子看不到内容，
            // 用户还得再点一次才看得见"这周到底有什么"。
            let weekItems = weekAgenda
            if !weekItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(weekItems) { bucket in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(dayTitleFor(bucket.day) + " · \(bucket.items.count) 条")
                                .font(.appFootnote.weight(.medium))
                                .foregroundStyle(Theme.textTertiary)
                            VStack(spacing: 0) {
                                ForEach(bucket.items) { item in
                                    Button {
                                        detail = item
                                    } label: {
                                        agendaRow(item)
                                    }
                                    .buttonStyle(.plain)
                                    if item.id != bucket.items.last?.id {
                                        Divider().overlay(Theme.separator)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    /// 按天分桶。用一个具名结构体而不是元组：
    /// `ForEach` 要 `Identifiable`，而 **Swift 的 key path 不能指向元组元素**
    /// （`id: \.0` 编译不过）。这是踩过一次的坑。
    struct DayBucket: Identifiable {
        let day: Date
        let items: [ScheduleInstance]
        var id: Date { day }
    }

    private var weekAgenda: [DayBucket] {
        var buckets: [Date: [ScheduleInstance]] = [:]
        for item in store.instances {
            buckets[item.start.startOfDay, default: []].append(item)
        }
        return buckets
            .map { DayBucket(day: $0.key, items: $0.value.sorted { $0.startUTC < $1.startUTC }) }
            .sorted { $0.day < $1.day }
    }

    private func dayTitleFor(_ d: Date) -> String {
        let cal = Calendar.current
        let m = cal.component(.month, from: d)
        let day = cal.component(.day, from: d)
        return "\(m)月\(day)日 \(Self.weekdayCN(d))"
    }

    @ViewBuilder
    private var weekBadge: some View {
        let label = WeekNumbering.label(for: store.monthAnchor)
        if !label.needsSetup {
            Text(label.text)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: 课表

    /// 课表视图要一张 `kind == "course"` 的日历。
    ///
    /// 没有就说明用户还没建课程表 —— 这时候给一句解释，
    /// 而不是画一张全空的网格（空网格会被读成"我的课没了"）。
    private var courseCalendar: CalendarDTO? {
        store.calendars.first { $0.kind == "course" }
    }

    @ViewBuilder
    private var timetableView: some View {
        if let cal = courseCalendar {
            VStack(spacing: 8) {
                HStack {
                    Text(cal.name)
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        Task { periods = await store.loadCoursePeriods() }
                    } label: {
                        Text("刷新节次")
                            .font(.appCaption)
                            .foregroundStyle(Theme.blue600)
                    }
                    .buttonStyle(.plain)
                }
                CourseGridView(
                    instances: store.instances.filter { $0.calendarID == cal.id },
                    periods: periods,
                    weekStart: store.weekStart,
                    onSelect: { item in
                        detail = item
                    },
                    blockColor: CalendarPalette.display(cal.displayColor,
                                                        dark: scheme == .dark)
                )
                .padding(.horizontal, -16)
            }
        } else {
            noCourseCalendar
        }
    }

    private var noCourseCalendar: some View {
        VStack(spacing: 10) {
            Image(systemName: "tablecells")
                .font(.system(size: 30))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有课程表")
                .font(.appSubheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("去「日历」页新建一个日历，把类型选成「课程表」，这里就有节次网格了。")
                .font(.appFootnote)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: 融合

    private var mergedView: some View {
        MergedGridView(
            instances: store.instances,
            calendars: store.calendars,
            weekStart: store.weekStart,
            hiddenCalendarIDs: $hiddenCalendarIDs,
            selectedDate: selectedDate,
            onSelect: { detail = $0 },
            onPickDay: { d in
                selectedDate = d.startOfDay
                withAnimation(.easeInOut(duration: 0.18)) { mode = .agenda }
            }
        )
        .padding(.horizontal, -16)
    }

    // MARK: - 动作

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
                try await store.deleteOccurrence(
                    eventID: item.eventID,
                    occurrenceKey: item.occurrenceKey
                )
            } catch {
                showToast(store.message(for: error))
            }
        }
    }

    private func toggleDone(_ item: ScheduleInstance) {
        Task {
            do {
                try await store.setDone(item, done: !item.isDone)
            } catch {
                showToast(store.message(for: error))
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}
