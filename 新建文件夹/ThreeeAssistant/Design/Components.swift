import SwiftUI

/// 一条日程。列表里最小的单元。
struct EventRowView: View {

    let item: ScheduleInstance
    let calendar: CalendarDTO?

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

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)

                    if item.allDay { PillView(text: "全天", tone: .accent) }
                    if item.isTask { PillView(text: "待办", tone: .amber) }
                    if item.isOverride { PillView(text: "已改期", tone: .teal) }
                }

                Text(item.title?.isEmpty == false ? item.title! : "（无标题）")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
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
    }
}

/// 小标签。颜色是「语义」，不是「装饰」——
/// 全天/待办/已改期三种状态各自固定一个色，别处不要再换。
struct PillView: View {

    enum Tone {
        case accent, teal, amber
    }

    let text: String
    let tone: Tone

    private var fg: Color {
        switch tone {
        case .accent: return Theme.blue600
        case .teal: return Theme.teal600
        case .amber: return Theme.amber600
        }
    }

    private var bg: Color {
        switch tone {
        case .accent: return Theme.blue50
        case .teal: return Theme.teal50
        case .amber: return Theme.amber50
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
    }
}

/// 一天的标题行
struct DayHeaderView: View {
    let day: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.friendlyDay)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(day.weekdayName)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            if day.isSameDay(as: .now) {
                Text("今天")
                    .font(.system(size: 11, weight: .medium))
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
