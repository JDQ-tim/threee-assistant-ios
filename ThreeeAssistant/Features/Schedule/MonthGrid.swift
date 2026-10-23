import SwiftUI

/// 月视图。
///
/// ## 它不是"周视图的缩小版"
///
/// 格子只有几十点宽，塞不下标题。所以这里只表达三件事：
///
/// 1. **哪天有安排**（用圆点数量表示，最多 3 个点 + "+"）
/// 2. **今天在哪**（实心圆底）
/// 3. **选中的是哪天**（描边）
///
/// 点某一天 = 跳到那周的周视图 —— 在格子里展开列表会挤成一团，不如直接跳转。
struct MonthGrid: View {

    let anchor: Date
    let days: [DayGroup]
    let selected: Date?
    let onPick: (Date) -> Void

    private let cal = Calendar.current
    private let weekLabels = ["一", "二", "三", "四", "五", "六", "日"]

    /// 6 行 × 7 列，固定 42 格。
    ///
    /// ⚠️ 固定 42 格而不是"按需要的行数算"：行数变化会让整块高度跳动，
    ///    翻月时下面的内容跟着上下窜，非常难受。固定高度最稳。
    private var cells: [Date?] {
        let lead = anchor.leadingBlankDaysInMonth
        let total = anchor.daysInMonth
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<total {
            out.append(anchor.addingDays(d))
        }
        while out.count < 42 { out.append(nil) }
        return Array(out.prefix(42))
    }

    /// 按天索引，避免每个格子都去遍历一遍 days（42 × N 次）
    private var countByDay: [Date: Int] {
        var m: [Date: Int] = [:]
        for g in days {
            m[g.day] = g.items.count
        }
        return m
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(weekLabels, id: \.self) { w in
                    Text(w)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                spacing: 4
            ) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let d = date {
                        cell(for: d)
                    } else {
                        Color.clear.frame(height: 46)
                    }
                }
            }

            legend
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func cell(for date: Date) -> some View {
        let isToday = date.isSameDay(as: .now)
        let isSelected = selected.map { date.isSameDay(as: $0) } ?? false
        let n = countByDay[date.startOfDay] ?? 0
        let isWeekend = {
            let wd = cal.component(.weekday, from: date)
            return wd == 1 || wd == 7
        }()

        return Button {
            onPick(date)
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 14, weight: isToday ? .semibold : .regular))
                    .monospacedDigit()
                    // ⚠️ foregroundStyle 只写一次。写在 background 之前之后都行，
                    //    但连写两次时后写的会覆盖前面的，今天那个圆底就白底白字了
                    .foregroundStyle(isToday ? Theme.onAccent : (isWeekend ? Theme.textTertiary : Theme.textPrimary))
                    .frame(width: 26, height: 26)
                    .background(isToday ? Theme.accent : Color.clear)
                    .clipShape(Circle())

                dots(count: n)
                    .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected && !isToday ? Theme.surfaceAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected && !isToday ? Theme.accent.opacity(0.55) : Color.clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 最多画 3 个点，第 3 个之后折成 "+"。
    /// 画 8 个点在小格子里就是一条糊掉的黑线，信息量反而更低。
    private func dots(count n: Int) -> some View {
        HStack(spacing: 2.5) {
            if n == 0 {
                // 占位，保持行高一致；不画东西
                Color.clear.frame(width: 4, height: 4)
            } else {
                ForEach(0..<min(n, 3), id: \.self) { _ in
                    Circle()
                        .fill(Theme.accent.opacity(0.75))
                        .frame(width: 4, height: 4)
                }
                if n > 3 {
                    Text("+")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.accent.opacity(0.75))
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent.opacity(0.75)).frame(width: 4, height: 4)
            Text("有安排")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text("点日期查看那一周")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 4)
    }
}
