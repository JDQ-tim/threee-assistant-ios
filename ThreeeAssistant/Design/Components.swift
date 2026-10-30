import SwiftUI

extension Optional where Wrapped == String {
    /// 取「非空值」，空串和 nil 一律换成兜底文案。
    ///
    /// 存在的理由：以前四处都写成
    /// ```
    /// item.title?.isEmpty == false ? item.title! : "（无标题）"
    /// ```
    /// 靠 `nil == false` 走 else 分支来保证安全 —— **确实不会崩**，
    /// 但每多一处就是一颗地雷：哪天有人把条件改成 `!= true`
    /// 或者把 `?` 去掉，`!` 立刻变成真崩溃，而编译器不会拦。
    /// 换成 flatMap 之后根本没有强解，条件改了也崩不了。
    func nonEmpty(or fallback: String) -> String {
        guard let self, !self.isEmpty else { return fallback }
        return self
    }
}

/// 一条日程。列表里最小的单元。
@MainActor
struct EventRowView: View {

    let item: ScheduleInstance
    let calendar: CalendarDTO?

    /// 所属日程的重复规则原文。实例本身不知道自己是哪条重复规则展开来的，
    /// 由上层从 `store.repeatRuleByEventID` 查出来传进来。
    var repeatRule: String?

    private var barColor: Color {
        Color(hexString: calendar?.displayColor ?? "#185FA5")
    }

    private var timeText: String {
        if item.allDay { return "全天" }
        if !item.hasSpan { return item.start.hhmm }
        return "\(item.start.hhmm) – \(item.end.hhmm)"
    }

    private var metaText: String {
        [item.location, calendar?.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 3)

            // 已完成的待办：左侧一个实心勾。
            // ⚠️ 勾号画在这里而不是整行按钮，是因为整行还要响应「点开详情」，
            //    两个点击热区重叠时子按钮优先，但父按钮的 highlighted 状态会跟着变，
            //    看起来像整行都被按下去了。所以勾选热区单独做成 44×44 的明确区域。
            if item.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.appHeadline)
                    .foregroundStyle(Theme.teal600)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)

                    if item.allDay { PillView(text: "全天", tone: .accent) }
                    if item.isTask && !item.isDone { PillView(text: "待办", tone: .amber) }
                    if item.isDone { PillView(text: "已完成", tone: .teal) }
                    if item.isOverride { PillView(text: "已改期", tone: .teal) }

                    if let rt = repeatText {
                        PillView(text: rt, tone: .plain)
                    }
                }

                Text(item.title.nonEmpty(or: "（无标题）"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.isDone ? Theme.textTertiary : Theme.textPrimary)
                    // 完成的划掉。这是"完成"最不需要解释的表达方式
                    .strikethrough(item.isDone, color: Theme.textTertiary)
                    .lineLimit(1)

                if !metaText.isEmpty {
                    Text(metaText)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        // 完成的整行降低对比度，让未完成的自然浮上来
        .opacity(item.isDone ? 0.72 : 1)
    }

    /// 列表里给一个极简标记就够了（「重复」「每周」太长会挤掉标题）。
    /// 具体规则在详情页用 RepeatRule.describe 展开。
    private var repeatText: String? {
        guard let r = repeatRule, !r.isEmpty else { return nil }
        let desc = RepeatRule.describe(r)
        // 「每天」这种两个字的直接显示；更长的统一显示「重复」，
        // 否则一行里塞「每周的周一、周三、周五」会把标题挤没
        return desc.count <= 3 ? desc : "重复"
    }
}

/// 小标签。颜色是「语义」，不是「装饰」——
/// 全天/待办/已改期三种状态各自固定一个色，别处不要再换。
@MainActor
struct PillView: View {

    enum Tone {
        case accent, teal, amber
        /// 中性档：用于「重复」这类只是说明事实、不带状态含义的标记。
        /// 用彩色会让人误以为它是某种需要注意的状态。
        case plain
    }

    let text: String
    let tone: Tone

    private var fg: Color {
        switch tone {
        case .accent: return Theme.blue600
        case .teal: return Theme.teal600
        case .amber: return Theme.amber600
        case .plain: return Theme.textSecondary
        }
    }

    private var bg: Color {
        switch tone {
        case .accent: return Theme.blue50
        case .teal: return Theme.teal50
        case .amber: return Theme.amber50
        case .plain: return Theme.surfaceAlt
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
    }
}

/// 一天的标题行
@MainActor
struct DayHeaderView: View {
    let day: Date

    /// 是否用「今天/明天」这种相对说法。
    ///
    /// ⚠️ 月视图必须关掉：一个月的列表里如果出现十几个"今天"式的相对标签，
    ///    读者根本分不清哪天是哪天 —— 相对词只在"近在手边的几天"里才有意义。
    var relativeDays: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(relativeDays ? day.friendlyDay : day.monthDay)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(day.weekdayName)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            if day.isSameDay(as: .now) {
                Text("今天")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            Spacer()
        }
        .padding(.bottom, 8)
    }
}

/// 错误提示条。文案可能很长（含排查步骤），所以不折行数
@MainActor
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red600)
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.red600)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.red50)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }
}

/// 空状态
@MainActor
struct EmptyHint: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary.opacity(0.6))
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
