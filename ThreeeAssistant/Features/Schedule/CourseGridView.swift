import SwiftUI

/// 课程表网格。
///
/// ## 这不是一个新的数据源
///
/// 源码 `course.go:11` 说得很清楚：课表就是 `kind == "course"` 的**普通日历**，
/// 只是渲染成「节次 × 星期」的网格，而不是按天铺开的日程列表。
/// 所以这里不需要任何新接口 —— 用的还是 `ScheduleInstance`，
/// 唯一的额外输入是节次表（决定网格有几行、每行几点）。
///
/// ## 一节课怎么落到格子里
///
/// 服务端展开出来的实例是**绝对时刻**，网格格子是「第 N 节」。
/// 两者靠开始时间落在哪个节次区间来对应：`period.start <= 实例.start < period.end`。
/// 一旦改过节次表，历史上排的课会自动跟着重新落格，
/// 不用去改每一条日程 —— 这也是节次表要放服务端共享的原因。
@MainActor
struct CourseGridView: View {

    /// 只要课程表日历上的日程
    let instances: [ScheduleInstance]
    let periods: [CoursePeriod]
    /// 用哪一周来取「这周几号」。周视图的当前周。
    let weekStart: Date
    /// 日历颜色，用来给课程块上色
    let colorHex: String

    /// 点一格
    var onSelect: ((ScheduleInstance) -> Void)?

    /// 网格的 7 列：周一到周日
    private static let dayCount = 7

    var body: some View {
        ScrollView([.vertical], showsIndicators: false) {
            VStack(spacing: 1) {
                headerRow

                ForEach(periods) { p in
                    HStack(spacing: 1) {
                        periodCell(p)
                        ForEach(0..<Self.dayCount, id: \.self) { dayIndex in
                            slotCell(period: p, dayIndex: dayIndex)
                        }
                    }
                    .frame(height: 56)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            }
            .padding(12)
        }
        .background(Theme.background)
    }

    // MARK: - 表头

    private var headerRow: some View {
        HStack(spacing: 1) {
            // 左上角空着 —— 那里是「节次 / 星期」的交叉，画什么都不对
            Text("")
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(Theme.surfaceAlt)

            ForEach(0..<Self.dayCount, id: \.self) { i in
                let d = weekStart.addingDays(i)
                let isToday = d.isSameDay(as: .now)
                VStack(spacing: 1) {
                    Text(Self.weekdayShort(i))
                        .font(.system(size: 11.5, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? Theme.accent : Theme.textSecondary)
                    Text("\(Calendar.current.component(.day, from: d))")
                        .font(.appCaption2)
                        .foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isToday ? Theme.accent.opacity(0.08) : Theme.surfaceAlt)
            }
        }
        .frame(height: 42)
    }

    // MARK: - 左侧节次列

    private func periodCell(_ p: CoursePeriod) -> some View {
        VStack(spacing: 1) {
            Text("\(p.index)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(p.start)
                .font(.appCaption2)
                .foregroundStyle(Theme.textTertiary)
            Text(p.end)
                .font(.appCaption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(Theme.surfaceAlt)
    }

    // MARK: - 格子

    @ViewBuilder
    private func slotCell(period: CoursePeriod, dayIndex: Int) -> some View {
        let hits = courses(in: period, dayIndex: dayIndex)

        if hits.isEmpty {
            Rectangle()
                .fill(Theme.surface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 一格多课（两周排了不同课、或者一次临时调整）时只显示第一节，
            // 但标一个角标 —— 直接叠两层会看不清字
            Button {
                if let first = hits.first { onSelect?(first) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayTitle(hits[0]))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(hexString: "#FFFFFF"))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.8)
                    if !hits[0].locationOrEmpty.isEmpty {
                        Text(hits[0].locationOrEmpty)
                            .font(.appCaption2)
                            .foregroundStyle(Color(hexString: "#FFFFFF").opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if hits.count > 1 {
                        Text("+\(hits.count - 1)")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(hexString: "#FFFFFF"))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(hexString: "#FFFFFF").opacity(0.25))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hexString: colorHex))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 落格

    /// 找出落在这一格里的课。
    ///
    /// 判定用的是**节次区间**而不是「第几节」字段 —— 服务端存的是绝对时刻，
    /// 没有「第几节」这种字段。用区间判断还有个好处：
    /// 一节课跨了两个节次（比如连上两节）时，两个格子都会命中它。
    private func courses(in period: CoursePeriod, dayIndex: Int) -> [ScheduleInstance] {
        let day = weekStart.addingDays(dayIndex)
        let dayStart = day.startOfDay.timeIntervalSince1970

        return instances.filter { item in
            // 先按天过滤：只保留落在这一个自然日里的
            let itemDay = item.start.startOfDay.timeIntervalSince1970
            guard Int64(itemDay) == Int64(dayStart) else { return false }

            // 全天日程不属于任何一个节次
            if item.allDay { return false }

            guard let ps = Self.minutesOfDay(period.start),
                  let pe = Self.minutesOfDay(period.end) else { return false }

            let cal = Calendar.current
            let h = cal.component(.hour, from: item.start)
            let m = cal.component(.minute, from: item.start)
            let itemMinutes = h * 60 + m

            // 开始时刻落在 [start, end) 以内就算这一节
            return itemMinutes >= ps && itemMinutes < pe
        }
        .sorted { $0.startUTC < $1.startUTC }
    }

    /// `"08:00"` → 480。解析不出来返回 nil（节次表被写坏时的兜底）。
    static func minutesOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        guard h >= 0 && h <= 23 && m >= 0 && m <= 59 else { return nil }
        return h * 60 + m
    }

    private func displayTitle(_ item: ScheduleInstance) -> String {
        let t = item.title ?? ""
        return t.isEmpty ? "（无标题）" : t
    }

    /// 「周一」…「周日」
    static func weekdayShort(_ index: Int) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        guard index >= 0 && index < names.count else { return "" }
        return names[index]
    }
}

private extension ScheduleInstance {
    /// `location` 是 Optional，网格里到处要判断「有没有值」，
    /// 抽一个非空版本免得每处都写 `?? ""`
    var locationOrEmpty: String {
        (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
