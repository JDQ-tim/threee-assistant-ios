import SwiftUI

// ============================================================
//  融合视图
//  ------------------------------------------------------------
//  「课表」看的是**一张** course 日历，网格是节次 × 星期；
//  「融合」看的是**所有**日历，横轴是星期、纵轴是真实时间。
//
//  ## 为什么两个都要
//
//  课表回答"周三第 3 节有课吗" —— 它假设你的生活按节次组织。
//  但真实的学生生活里还有社团、兼职、看病、约会，这些不在节次上。
//  融合视图把这些和课放在同一条时间轴上，才看得出"周四下午
//  第 5 节下课到社团开会之间只有 20 分钟"这种事。
//
//  ## 手机上的取舍
//
//  7 列 × 24 小时塞进 390pt，每格只有 50pt 宽。所以：
//  · **纵向滚动，横向不滚** —— 一屏看全七天，比"能看清单日细节"重要
//  · **块里只放标题**，地点和时间靠位置表达；点开才看详情
//  · **时间范围自动收窄**到有事件的那几个小时（至少留 8:00–22:00），
//    零点到早上七点那种大段空白不该占掉半屏
//
//  ## 重叠的日程
//
//  同一时段两条（比如"上课"和"去医院"撞了）必须都画出来 ——
//  这正是用户需要看见的冲突。按区间聚类分车道，同一簇里平分宽度。
//  ⚠️ **不能整列平分**：如果这一天只有一处重叠，其余几十条不该跟着变半宽。
//     所以分簇算，每簇独立决定车道数。
// ============================================================

@MainActor
struct MergedGridView: View {

    let instances: [ScheduleInstance]
    let calendars: [CalendarDTO]
    let weekStart: Date
    @Binding var hiddenCalendarIDs: Set<String>
    let selectedDate: Date

    var onSelect: ((ScheduleInstance) -> Void)?
    var onPickDay: ((Date) -> Void)?

    private let hourHeight: CGFloat = 44
    private let gutterWidth: CGFloat = 38

    // MARK: - 可见事件

    private var calendarsByID: [String: CalendarDTO] {
        var m: [String: CalendarDTO] = [:]
        for c in calendars { m[c.id] = c }
        return m
    }

    private var visible: [ScheduleInstance] {
        let map = calendarsByID
        return instances.filter { item in
            guard let cal = map[item.calendarID] else { return true }
            return !hiddenCalendarIDs.contains(cal.id)
        }
    }

    // MARK: - 时间范围

    /// 纵轴显示哪几个小时。
    ///
    /// 默认 8:00–22:00。有更早/更晚的事件时向外扩，但**最多扩到 0–24** ——
    /// 一条凌晨 2 点的事件不该把整页拉到 26 小时的滚动长度。
    private var hourRange: (start: Int, end: Int) {
        var lo = 8
        var hi = 22
        let cal = Calendar.current
        for item in visible where !item.allDay {
            let hs = cal.component(.hour, from: item.start)
            let he = max(hs, cal.component(.hour, from: item.end))
            lo = min(lo, hs)
            hi = max(hi, he + 1)
        }
        lo = max(0, lo)
        hi = min(24, hi)
        if hi <= lo { hi = lo + 1 }
        return (lo, hi)
    }

    private var gridHeight: CGFloat {
        CGFloat(hourRange.end - hourRange.start) * hourHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            legend
            headerRow

            if !allDayItems.isEmpty {
                allDayStrip
            }

            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    hourGutter
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            dayColumn(index: i)
                        }
                    }
                }
                .frame(height: gridHeight)
            }
        }
        .background(Theme.background)
    }

    // MARK: - 图例

    /// 日历可见性开关。
    ///
    /// 不放在设置里而放在这一页顶部：融合视图天然会有"这张日历我不想看"
    /// 的时刻（比如把"课程表"隐藏掉只看社团活动），而那一刻就在这里。
    @ViewBuilder
    private var legend: some View {
        if !calendars.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(calendars) { c in
                        let off = hiddenCalendarIDs.contains(c.id)
                        Button {
                            if off { hiddenCalendarIDs.remove(c.id) }
                            else { hiddenCalendarIDs.insert(c.id) }
                        } label: {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(off ? Theme.textTertiary : Color(hexString: c.displayColor))
                                    .frame(width: 9, height: 9)
                                Text(c.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(off ? Theme.textTertiary : Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                            .opacity(off ? 0.55 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 表头

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 34)
            ForEach(0..<7, id: \.self) { i in
                let d = weekStart.addingDays(i)
                let isToday = Calendar.current.isDateInToday(d)
                let isSelected = Calendar.current.isDate(d, inSameDayAs: selectedDate)
                Button {
                    onPickDay?(d)
                } label: {
                    VStack(spacing: 1) {
                        Text(ScheduleView.weekdayShort(i))
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Theme.blue600 : Theme.textTertiary)
                        Text("\(Calendar.current.component(.day, from: d))")
                            .font(.system(size: 13, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Theme.blue600 : Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(isSelected ? Theme.blue50 : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 全天条

    private var allDayItems: [ScheduleInstance] {
        visible.filter(\.allDay)
    }

    /// 全天日程单独一条横带。
    ///
    /// 不放进网格：全天事件没有"几点到几点"，塞进时间轴只能画成
    /// 一根从顶到底的柱子，会盖住同一天所有的课。
    private var allDayStrip: some View {
        HStack(spacing: 0) {
            Text("全天")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: gutterWidth, alignment: .center)

            ForEach(0..<7, id: \.self) { i in
                let day = weekStart.addingDays(i)
                let mine = allDayItems.filter {
                    Calendar.current.isDate($0.start, inSameDayAs: day)
                }
                VStack(spacing: 1) {
                    ForEach(mine.prefix(2)) { item in
                        Button {
                            onSelect?(item)
                        } label: {
                            Text(item.title.nonEmpty(or: "（无标题）"))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hexString: colorHex(item.calendarID)))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    if mine.count > 2 {
                        Text("+\(mine.count - 2)")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 1)
            }
        }
        .frame(height: 30)
        .background(Theme.surfaceAlt.opacity(0.6))
    }

    // MARK: - 左侧时刻

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(hourRange.start..<hourRange.end, id: \.self) { h in
                Text(String(format: "%02d:00", h))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: gutterWidth, height: hourHeight, alignment: .top)
                    .offset(y: -5)
            }
        }
        .frame(width: gutterWidth)
    }

    // MARK: - 一天的列

    private func dayColumn(index: Int) -> some View {
        let day = weekStart.addingDays(index)
        let cal = Calendar.current
        let items = visible.filter {
            !$0.allDay && cal.isDate($0.start, inSameDayAs: day)
        }
        let placed = Self.layout(items)
        let isToday = cal.isDateInToday(day)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 每小时的横线
                VStack(spacing: 0) {
                    ForEach(hourRange.start..<hourRange.end, id: \.self) { _ in
                        Rectangle()
                            .fill(Theme.separator.opacity(0.5))
                            .frame(height: 0.5)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }

                // 今天那一列淡蓝底，扫一眼就知道"现在在哪"
                if isToday {
                    Theme.blue600.opacity(0.04)
                }

                // 左边界竖线
                Rectangle()
                    .fill(Theme.separator.opacity(0.5))
                    .frame(width: 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(placed, id: \.item.id) { p in
                    block(p, columnWidth: geo.size.width)
                }

                if isToday {
                    nowLine(width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: gridHeight, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
    }

    private func nowLine(width: CGFloat) -> some View {
        let cal = Calendar.current
        let h = cal.component(.hour, from: .now)
        let m = cal.component(.minute, from: .now)
        let y = (CGFloat(h - hourRange.start) + CGFloat(m) / 60) * hourHeight
        return Group {
            if y >= 0 && y <= gridHeight {
                HStack(spacing: 0) {
                    Circle().fill(Theme.red600).frame(width: 4, height: 4)
                    Rectangle().fill(Theme.red600).frame(height: 1)
                }
                .frame(width: width, alignment: .leading)
                .offset(y: y - 2)
            }
        }
    }

    // MARK: - 事件块

    private func block(_ p: Placed, columnWidth: CGFloat) -> some View {
        let item = p.item
        let cal = Calendar.current
        let sh = cal.component(.hour, from: item.start)
        let sm = cal.component(.minute, from: item.start)
        let eh = cal.component(.hour, from: item.end)
        let em = cal.component(.minute, from: item.end)

        let startMin = (sh - hourRange.start) * 60 + sm
        let endMin = (eh - hourRange.start) * 60 + em
        let top = CGFloat(startMin) / 60 * hourHeight
        // 至少 20pt：15 分钟的短会也得能点中、能认出有东西
        let h = max(CGFloat(endMin - startMin) / 60 * hourHeight, 20)

        let lanes = CGFloat(max(p.lanes, 1))
        let w = max(columnWidth / lanes - 1, 12)
        let x = CGFloat(p.lane) * (columnWidth / lanes)

        return Button {
            onSelect?(item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title.nonEmpty(or: "（无标题）"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(Color(hexString: colorHex(item.calendarID)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .offset(x: x, y: top)
    }

    private func colorHex(_ calendarID: String) -> String {
        calendarsByID[calendarID]?.displayColor ?? "#185FA5"
    }

    // MARK: - 车道分配

    struct Placed {
        let item: ScheduleInstance
        let lane: Int
        let lanes: Int
    }

    /// 按区间聚类分车道。
    ///
    /// 一个"簇"是一组**传递重叠**的事件（A 撞 B、B 撞 C，则三者同簇）。
    /// 每簇单独算车道数，簇与簇之间互不影响 —— 这样一天里只有一处
    /// 两节课撞了，不会让其余二十条全都变成半宽。
    static func layout(_ items: [ScheduleInstance]) -> [Placed] {
        let sorted = items.sorted { a, b in
            if a.startUTC != b.startUTC { return a.startUTC < b.startUTC }
            return a.id < b.id
        }

        var out: [Placed] = []
        var cluster: [ScheduleInstance] = []
        var clusterEnd: Int64 = .min

        func flush() {
            guard !cluster.isEmpty else { return }
            var laneEnds: [Int64] = []
            var assigned: [(ScheduleInstance, Int)] = []

            for it in cluster {
                // `end` 可能等于 `start`（待办没有时长），给 1 秒兜底，
                // 否则它会"立刻结束"，后面的事件全挤进同一车道。
                let end = max(it.endUTC, it.startUTC + 1)
                var placed = false
                for i in 0..<laneEnds.count where laneEnds[i] <= it.startUTC {
                    laneEnds[i] = end
                    assigned.append((it, i))
                    placed = true
                    break
                }
                if !placed {
                    laneEnds.append(end)
                    assigned.append((it, laneEnds.count - 1))
                }
            }

            let n = max(laneEnds.count, 1)
            for (it, lane) in assigned {
                out.append(Placed(item: it, lane: lane, lanes: n))
            }
            cluster = []
            clusterEnd = .min
        }

        for it in sorted {
            if !cluster.isEmpty && it.startUTC >= clusterEnd {
                flush()
            }
            cluster.append(it)
            clusterEnd = max(clusterEnd, max(it.endUTC, it.startUTC + 1))
        }
        flush()
        return out
    }
}
