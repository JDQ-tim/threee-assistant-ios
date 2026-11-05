import SwiftUI

// ============================================================
//  主页
//  ------------------------------------------------------------
//  2026-11-05 新增。安卓端把「主页」放在底部导航正中间，
//  它既不是日程页也不是设置页，而是**今天整体的速览**：
//
//      日期头 ─ 今天几号、星期几
//      天气卡 ─ 现在多少度、接下来几小时、这几天
//      今日日程 ─ 今天要上的课 / 要做的事
//      新建日程 ─ 最常用动作，放在拇指够得到的地方
//
//  ## 为什么它值一个一级入口
//
//  「日程」页回答的是"这一周怎么排的"，需要横向对比；
//  主页回答的是"我现在该干什么"，只看今天。
//  这两件事在手机上的使用频率差一个量级 —— 早上睁眼、课间、睡前，
//  打开的都是"今天有什么"，不是"第 8 周周三下午第几节"。
//
//  ## 刻意没做的两样
//
//  1. **更新横幅**。安卓端那条是给 App 自更新和插件更新用的，
//     iOS 走 App Store，没有这个东西可显示。画一条假的只会误导。
//  2. **下拉抽屉**。那是安卓端"下拉看全部功能"的招牌手势。
//     这里换成一个可展开的功能格 —— 手势不同，但**看到的东西一样**，
//     而且不用教用户"往下拽"。
// ============================================================

@MainActor
struct HomeView: View {

    /// 切到别的 Tab。主页上很多卡片点下去其实是"去那一页"。
    var onOpenTab: (MainTabView.AppTab) -> Void = { _ in }

    @Environment(SessionStore.self) private var store
    @Environment(NavPackStore.self) private var nav
    /// 今日日程的颜色按当前外观取
    @Environment(\.colorScheme) private var scheme

    @State private var weather: WeatherDocDTO?
    @State private var weatherLoading = false
    @State private var weatherError: String?

    /// 「刚刚同步」/「3 分钟前同步」
    @State private var lastSyncAt: Date?
    @State private var syncing = false

    /// 功能格展开状态
    @State private var showAllFunctions = false

    @State private var detail: ScheduleInstance?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    dateRow
                    functionToggle

                    if showAllFunctions {
                        functionGrid
                    }

                    weatherCard
                    todayCard
                    newButton

                    if let msg = store.errorMessage {
                        ErrorBanner(message: msg)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .refreshable { await refreshAll() }
            .task { await refreshAll() }
            .sheet(item: $detail) { item in
                EventDetailSheet(item: item, calendar: store.calendarsByID[item.calendarID])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 头部

    /// 「3e学习助手 / 刚刚同步」+ 同步 / 设置。
    ///
    /// 副标题不写"已连接"：那是一个**状态**，用户真正想知道的是
    /// "我刚看到的东西是不是最新的"，所以给的是**上次同步的时间**。
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("3e学习助手")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(syncLabel)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 16) {
                Button {
                    Task { await manualSync() }
                } label: {
                    if syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("同步")
                            .font(.appSubheadline.weight(.medium))
                            .foregroundStyle(Theme.blue600)
                    }
                }
                .disabled(syncing)
                .buttonStyle(.plain)

                NavigationLink {
                    ProfileView(embedded: true)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.blue600)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
        }
        .padding(.top, 8)
    }

    private var syncLabel: String {
        guard let t = lastSyncAt else {
            return store.isLoading ? "正在同步…" : "还没有同步过"
        }
        let secs = Int(Date.now.timeIntervalSince(t))
        if secs < 60 { return "刚刚同步" }
        if secs < 3600 { return "\(secs / 60) 分钟前同步" }
        if Calendar.current.isDateInToday(t) { return "今天 \(t.hhmm) 同步" }
        return t.monthDay + " " + t.hhmm + " 同步"
    }

    // MARK: - 日期行

    /// 「10月30日 周五」。
    ///
    /// 用 large 而不是 title：这是整页的视觉锚点，
    /// 用户扫一眼就要知道"这是哪一天"。
    private var dateRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dateLabel)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.top, 6)
    }

    private var dateLabel: String {
        let now = Date.now
        let cal = Calendar.current
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        return "\(m)月\(d)日 \(Self.weekdayCN(cal.component(.weekday, from: now)))"
    }

    /// `weekday` 在 Calendar 里是 1=周日 … 7=周六，和直觉的"周一=1"不一样。
    /// 这里显式映射，避免用 `weekday - 1` 那种写法（周日会变成 0）。
    static func weekdayCN(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let i = weekday - 1
        guard i >= 0 && i < names.count else { return "" }
        return names[i]
    }

    // MARK: - 功能格

    private var functionToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showAllFunctions.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(showAllFunctions ? "收起全部功能" : "展开全部功能")
                    .font(.appFootnote)
                Image(systemName: showAllFunctions ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// 功能格：和抽屉里那一排是同一批入口。
    ///
    /// ⚠️ 只放**已经做完**的功能。放一个点进去是空页的格子，
    ///    比不放更伤 —— 用户会以为整个 App 都是空壳。
    private var functionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                  spacing: 10) {
            funcTile("列表", "list.bullet", Theme.blue600) { onOpenTab(.schedule) }
            funcTile("课表", "tablecells", Theme.teal600) { onOpenTab(.schedule) }
            funcTile("待办", "checklist", Theme.amber600) { onOpenTab(.schedule) }
            funcTile("日历", "calendar", Theme.blue600) { onOpenTab(.calendars) }
            funcTile("收件箱", "tray", Theme.textSecondary) { onOpenTab(.inbox) }
            funcTile("天气", "cloud.sun", Theme.amber600) { onOpenTab(.home) }
            funcTile("AI", "sparkles", Theme.blue600) { onOpenTab(.ai) }
            funcTile("设置", "gearshape", Theme.textSecondary) {}
        }
        .padding(.vertical, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func funcTile(_ title: String, _ icon: String, _ tint: Color,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 天气卡

    @ViewBuilder
    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(weather?.place ?? "天气")
                    .font(.appCaption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await loadWeather() }
                } label: {
                    if weatherLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("刷新")
                            .font(.appCaption)
                            .foregroundStyle(Theme.blue600)
                    }
                }
                .buttonStyle(.plain)
                .disabled(weatherLoading)
            }

            if let w = weather, let h = currentHour(w) {
                HStack(alignment: .top, spacing: 10) {
                    Text("\(Int(h.temp.rounded()))°C")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.textPrimary)
                    Text(h.label)
                        .font(.appTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 8)
                    Spacer()
                }

                Text(detailLine(w, h))
                    .font(.appCaption2)
                    .foregroundStyle(Theme.textTertiary)

                if !w.hours.isEmpty {
                    hourlyRow(w)
                }

                if !w.days.isEmpty {
                    dailyRows(w)
                }

                // 服务端拿不到上游数据时会端出上一次那份并置 stale。
                // 不说的话用户会拿六小时前的温度当现在用。
                if w.isStale {
                    Text(w.note ?? "这份不是最新的（上游暂时取不到）")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.amber600)
                }
            } else if let e = weatherError {
                Text(e)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("在「设置 → 天气」里可以配置城市")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.textTertiary)
            } else if weatherLoading {
                ProgressView("正在获取天气…")
                    .font(.appFootnote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Text("还没有天气数据")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .stroke(Theme.separator, lineWidth: 0.5))
    }

    /// 现在这一刻 = 逐时里第一个还没过去的，取不到就退回第一个。
    private func currentHour(_ d: WeatherDocDTO) -> WeatherHourDTO? {
        let now = Int64(Date.now.timeIntervalSince1970)
        return d.hours.first { $0.time >= now - 1800 } ?? d.hours.first
    }

    /// 「湿度 76% · 风 5.4 m/s · met.no」
    private func detailLine(_ d: WeatherDocDTO, _ h: WeatherHourDTO) -> String {
        var parts: [String] = []
        parts.append("湿度 \(Int(h.humidity.rounded()))%")
        parts.append(String(format: "风 %.1f m/s", h.wind))
        if !d.source.isEmpty && d.source != "none" { parts.append(d.source) }
        return parts.joined(separator: " · ")
    }

    /// 接下来 6 档逐时。只画 6 格 —— 手机宽度放 8 格每格不到 40pt，
    /// 温度和时间会挤成两行，扫一眼读不出来。
    private func hourlyRow(_ d: WeatherDocDTO) -> some View {
        let now = Int64(Date.now.timeIntervalSince1970)
        var picked = d.hours.filter { $0.time >= now - 1800 }
        if picked.isEmpty { picked = d.hours }
        let shown = Array(picked.prefix(6))

        return HStack(spacing: 0) {
            ForEach(shown) { h in
                VStack(spacing: 3) {
                    Text(h.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(Int(h.temp.rounded()))°")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(Self.hourLabel(h.time))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(Theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    private func dailyRows(_ d: WeatherDocDTO) -> some View {
        // 直接遍历元素，不用 `enumerated()` 取下标 ——
        // 分隔线只需要判断"是不是最后一条"，而这个判断用 `id` 就能做，
        // 多一个下标变量只会多一处可能算错的地方。
        let shown = Array(d.days.prefix(5))
        return VStack(spacing: 0) {
            ForEach(shown) { day in
                HStack(spacing: 10) {
                    Text(Self.dayLabel(day.date))
                        .font(.appCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Text(day.label)
                        .font(.appCaption)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(day.tempMin.rounded()))~\(Int(day.tempMax.rounded()))°")
                        .font(.appCaption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
                if day.id != shown.last?.id {
                    Divider().overlay(Theme.separator)
                }
            }
        }
    }

    /// `"2026-10-30"` → `"10/30"`。解析不出来就原文返回，
    /// 宁可显示得难看一点，也不要空着。
    static func dayLabel(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3 else { return iso }
        let m = Int(parts[1]) ?? 0
        let d = Int(parts[2]) ?? 0
        guard m > 0, d > 0 else { return iso }
        return "\(m)/\(d)"
    }

    static func hourLabel(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - 今日日程

    private var todayItems: [ScheduleInstance] {
        let cal = Calendar.current
        return store.instances
            .filter { cal.isDate($0.start, inSameDayAs: .now) }
            .sorted { a, b in
                // 待办排最前（今天该做的事），然后按时间。
                // 与安卓端 `AgendaTab.kt:501` 的口径一致。
                if a.isTask != b.isTask { return a.isTask }
                if a.allDay != b.allDay { return a.allDay }
                return a.startUTC < b.startUTC
            }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日日程")
                    .font(.appHeadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    onOpenTab(.schedule)
                } label: {
                    Text("全部")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.blue600)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            if todayItems.isEmpty {
                Text("今天没有安排")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(todayItems) { item in
                    Button {
                        detail = item
                    } label: {
                        homeRow(item)
                    }
                    .buttonStyle(.plain)
                    if item.id != todayItems.last?.id {
                        Divider().overlay(Theme.separator)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .stroke(Theme.separator, lineWidth: 0.5))
    }

    /// 一行：左边时间（两行：开始大字、结束小字），右边标题 + 地点。
    /// 这是安卓端 `AgendaTab` 的行结构，比 iOS 原来的单行时间更省横向空间。
    private func homeRow(_ item: ScheduleInstance) -> some View {
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
        }
        .padding(.vertical, 7)
    }

    private func rowMeta(_ item: ScheduleInstance) -> String {
        var parts: [String] = []
        if let loc = item.location, !loc.isEmpty { parts.append(loc) }
        if let name = store.calendarsByID[item.calendarID]?.name { parts.append(name) }
        if item.isTask && item.isDone { parts.append("已完成") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 新建

    private var newButton: some View {
        Button {
            onOpenTab(.schedule)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("新建日程")
                    .font(.appBody.weight(.medium))
            }
            .foregroundStyle(Theme.blue600)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.blue50)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 取数

    private func refreshAll() async {
        await store.refresh()
        lastSyncAt = .now
        await loadWeather()
    }

    private func manualSync() async {
        syncing = true
        await store.refresh()
        lastSyncAt = .now
        syncing = false
    }

    private func loadWeather() async {
        // `loadWeather` 内部已经把服务端缓存（`expiresAt`）考虑进去了，
        // 没过期就是一次内存比较，不会真的打网络。
        weatherLoading = (weather == nil)
        do {
            weather = try await store.loadWeather()
            weatherError = nil
        } catch {
            // 天气失败**不能**显示成"今天没安排"那种空态 ——
            // 它是整页里唯一有外部依赖的卡片，必须说出是它自己拿不到。
            weatherError = "天气暂时取不到（\(store.message(for: error))）"
        }
        weatherLoading = false
    }
}
