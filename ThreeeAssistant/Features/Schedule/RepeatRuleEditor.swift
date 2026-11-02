import SwiftUI

/// 重复规则的编辑控件。
///
/// 抽成组件是因为**新建和编辑两处都要用**，而且两边必须生成完全一样的
/// RRULE —— 两份代码各写一遍，迟早会出现"新建时是每两周，编辑打开变成每周"。
///
/// 状态用 `@Binding` 逐项传入而不是传一个结构体：
/// SwiftUI 对结构体的 inout 绑定支持不好，拆成基本类型反而最直接。
@MainActor
struct RepeatRuleEditor: View {

    @Binding var kind: RepeatRule.Kind
    @Binding var interval: Int
    @Binding var weekdays: Set<Int>
    @Binding var end: RepeatRule.End
    @Binding var count: Int
    @Binding var until: Date

    /// 首次开始时间。用来决定"每周"默认勾哪一天、UNTIL 用哪个时分。
    let start: Date

    /// 选了「双周」但开始日落在单周时，为凑到双周需要**整体推迟几天**。
    ///
    /// ## 为什么不直接改父视图的日期
    ///
    /// 开始时间在父视图里是由 `day` + `time` 两个 `@State` 算出来的派生值，
    /// 直接改它会破坏单一数据源（改完界面上的日期选择器与实际不符）。
    /// 所以这里只**上报一个偏移量**，父视图把它并进自己那份状态里。
    ///
    /// 值只会是 0 或 7：`INTERVAL=2` 的起点只影响"从哪一周开始",
    /// 需要挪动的距离永远是一周以内。
    @Binding var dayShift: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Picker("重复", selection: $kind) {
                ForEach(RepeatRule.Kind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)

            if kind != .none {
                if kind == .weekly {
                    // 单双周放在「间隔」**上面**：
                    // 对课程表来说「单周/双周」是一等概念，而「每 N 周」是它的
                    // 泛化形式。让用户先去调 Stepper 再心算"N=2 是不是双周"，
                    // 是在用实现细节提问。
                    parityRow
                }

                intervalRow

                if kind == .weekly {
                    weekdayRow
                }

                endRow

                summaryHint
            }
        }
        .onChange(of: kind) { _, newKind in
            // 切到「每周」且一个都没勾时，自动勾上开始那天 ——
            // 用户选"每周"的本意就是"每周这一天"，让他再点一下是没必要的摩擦
            if newKind == .weekly && weekdays.isEmpty {
                weekdays = [Calendar.current.component(.weekday, from: start)]
            }
            // 离开「每周」时，把只为单双周服务的 interval=2 收回去，
            // 否则切到「每天」会变成「每 2 天」—— 用户没这么要求过
            if newKind != .weekly {
                if interval == 2 { interval = 1 }
                dayShift = 0
            }
        }
    }

    // MARK: - 单双周

    /// 「每周 / 单周 / 双周」三选一。
    ///
    /// ## 它和 `interval` 是同一个东西的两种说法
    ///
    /// 单周、双周在 RRULE 里**没有专门的写法**，正确表达就是
    /// `FREQ=WEEKLY;INTERVAL=2`。区别只在于「哪一周算第一次」——
    /// 而这由日程的开始日期决定（开始那周就是"单"，再隔一周就是"双"）。
    ///
    /// 所以这里不是一个新字段，而是 `interval` 的一个**视图**：
    /// - 选「每周」→ interval = 1
    /// - 选「单周」→ interval = 2（开始日所在的周即单周）
    /// - 选「双周」→ interval = 2（开始日往后一周才开始，即双周）
    ///
    /// 单周和双周生成同一个 RRULE 字符串，差别在 `startDate` 上：
    /// 见 `applyParityStart`。
    private var parityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("频率", selection: parityBinding) {
                Text("每周").tag(0)
                Text("单周").tag(1)
                Text("双周").tag(2)
            }
            .pickerStyle(.segmented)

            if let note = parityNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 0 = 每周，1 = 单周，2 = 双周
    private var parityBinding: Binding<Int> {
        Binding(
            get: {
                if interval != 2 { return 0 }
                // 「开始日所在的周是不是单周」由教学周奇偶决定；
                // 没设锚点时无从判断，按「开始那周算单周」处理
                guard let p = WeekNumbering.parity(for: start) else { return 1 }
                return p == .odd ? 1 : 2
            },
            set: { v in
                switch v {
                case 0:
                    interval = 1
                    // 从单双周切回每周时，把为了凑双周而推后的开始日还原，
                    // 否则「每周三」会莫名其妙从下周三才开始
                    dayShift = 0
                case 1:
                    interval = 2
                    // 单周：开始日所在那周就是第一周，不改开始日
                    dayShift = 0
                default:
                    interval = 2
                    // 双周：若开始日落在单周，往后推 7 天，让它落在双周。
                    // 不推的话 `INTERVAL=2` 会从单周开始，用户看到的是
                    // 「我设了双周，结果这周就有课」。
                    dayShift = WeekNumbering.parity(for: start) == .odd ? 7 : 0
                }
            }
        )
    }

    /// 单双周下方的说明。写得具体一点，因为这里是唯一能讲清"从哪周开始"的地方。
    private var parityNote: String? {
        guard interval == 2 else { return nil }

        let d = start.addingDays(dayShift)
        if dayShift != 0 {
            return "双周从 \(d.monthDay) 开始（本周是单周，已自动顺延一周）"
        }
        if let idx = WeekNumbering.weekIndex(for: d) {
            let p = WeekNumbering.parity(ofWeek: idx)
            return "第一次在 \(d.monthDay)，那天是第 \(idx) 周（\(p.label)）"
        }
        return "第一次在 \(d.monthDay)，之后每隔一周"
    }

    // MARK: - 间隔

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("每")
                .font(.appSubheadline)
                .foregroundStyle(Theme.textSecondary)

            Stepper(value: $interval, in: 1...30) {
                Text("\(interval)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))

            Text(intervalUnit)
                .font(.appSubheadline)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 0)
        }
    }

    private var intervalUnit: String {
        switch kind {
        case .none: return ""
        case .daily: return "天"
        case .weekly: return "周"
        case .monthly: return "个月"
        case .yearly: return "年"
        }
    }

    // MARK: - 星期几

    private var weekdayRow: some View {
        // ⚠️ 顺序固定的 7 个按钮，从周一到周日。
        //    不用 ForEach(Calendar 的 weekday 1…7)，那个是周日打头的，
        //    中文语境下"周一周二…周日"才是习惯顺序。
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { wd in
                let on = weekdays.contains(wd)
                Button {
                    if on {
                        // 允许取消到空 —— 空 = 跟随开始那天的星期，
                        // 这是合法且常见的意图，不该强制至少留一个
                        weekdays.remove(wd)
                    } else {
                        weekdays.insert(wd)
                    }
                } label: {
                    Text(shortName(wd))
                        .font(.footnote.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(on ? Theme.accent : Theme.surfaceAlt)
                        .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Calendar 的 weekday：1=周日 … 7=周六。这里排成 一 二 三 四 五 六 日
    private var orderedWeekdays: [Int] { [2, 3, 4, 5, 6, 7, 1] }

    private func shortName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return "?"
        }
    }

    // MARK: - 结束条件

    private var endRow: some View {
        VStack(spacing: 8) {
            Picker("结束", selection: $end) {
                ForEach(RepeatRule.End.allCases) { e in
                    Text(e.label).tag(e)
                }
            }
            .pickerStyle(.segmented)

            switch end {
            case .never:
                EmptyView()

            case .count:
                HStack(spacing: 8) {
                    Text("重复")
                        .font(.appSubheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Stepper(value: $count, in: 1...999) {
                        Text("\(count)")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    Text("次")
                        .font(.appSubheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }

            case .until:
                DatePicker(
                    "到",
                    selection: $until,
                    // 下限跟着 dayShift 走。选「双周」自动顺延一周后，
                    // 真正的第一次在 start+7；若下限还停在 start，
                    // 用户能选出一个「结束日早于第一次」的规则，
                    // 提交上去就是一条永远不出现的日程。
                    in: start.addingDays(dayShift)...,
                    displayedComponents: .date
                )
                .font(.appSubheadline)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
            }
        }
    }

    // MARK: - 一句话预览

    /// 让用户当场看见自己设的规则，而不是保存后回列表才发现"每两周"点成了"每周"。
    private var summaryHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
            Text(previewText)
                .font(.caption)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 2)
    }

    private var previewText: String {
        // ⚠️ 这里必须用 `start.addingDays(dayShift)`，不能用 `start`。
        //    选了「双周」而上报的 dayShift 是 7 时，真正的第一次在
        //    下个同一天 —— 若预览还按 `start` 算，上面 `parityNote` 写着
        //    「双周从 10月1日 开始」，下面预览却按 9月24日 算，
        //    同一个界面里两句话互相矛盾，用户没法判断哪个是真的。
        let rule = RepeatRule.build(
            kind: kind,
            interval: interval,
            weekdays: weekdays,
            end: end,
            count: count,
            until: until,
            start: start.addingDays(dayShift)
        )
        guard let rule else { return "不重复" }
        return RepeatRule.describe(rule)
    }
}
