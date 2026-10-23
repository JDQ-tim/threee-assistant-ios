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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Picker("重复", selection: $kind) {
                ForEach(RepeatRule.Kind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)

            if kind != .none {
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
        }
    }

    // MARK: - 间隔

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("每")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)

            Stepper(value: $interval, in: 1...30) {
                Text("\(interval)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))

            Text(intervalUnit)
                .font(.system(size: 14))
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
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
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
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    Stepper(value: $count, in: 1...999) {
                        Text("\(count)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    Text("次")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }

            case .until:
                DatePicker(
                    "到",
                    selection: $until,
                    in: start...,
                    displayedComponents: .date
                )
                .font(.system(size: 14))
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
        let rule = RepeatRule.build(
            kind: kind,
            interval: interval,
            weekdays: weekdays,
            end: end,
            count: count,
            until: until,
            start: start
        )
        guard let rule else { return "不重复" }
        return RepeatRule.describe(rule)
    }
}
