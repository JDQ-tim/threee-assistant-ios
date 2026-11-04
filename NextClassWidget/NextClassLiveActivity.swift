import ActivityKit
import SwiftUI
import WidgetKit

// ============================================================
//  实时活动的界面
//  ------------------------------------------------------------
//  一个 `ActivityConfiguration` 要同时给出两套东西：
//
//    · 锁屏（闭包 1）—— iPhone / iPad 的锁屏卡片，也是**没有灵动岛**
//      的设备上唯一能看到的形态
//    · 灵动岛（闭包 2）—— 紧凑 / 极简 / 展开 三种版式
//
//  ## ⚠️ 倒计时不要自己算，交给系统
//
//  `Text(date, style: .timer)` 由系统逐秒刷新：日期在未来就倒数，
//  已经过去就正数。**不需要 App 推更新** —— 这一点很关键，
//  因为 App 退到后台之后就不再动了，而实时活动还要继续显示半小时。
//
//  反过来说：**不要**在这里写 `if 现在 < 开始时间 {…} else {…}`。
//  视图不会因为时间流逝重新求值，那个 if 会一直停在创建时的那一支，
//  于是"课已经开始了"却还写着"还有 3 分钟"。
// ============================================================

struct NextClassLiveActivity: Widget {

    /// 和 App 里 `Theme.teal600` 同一个色相。
    /// 扩展是独立模块，拿不到 App 的 Theme，所以这里单独写一份。
    private let accent = Color(red: 0.06, green: 0.43, blue: 0.34)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextClassActivityAttributes.self) { context in
            LockScreenCard(state: context.state, accent: accent)
                .activityBackgroundTint(Color.black.opacity(0.42))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                            .foregroundStyle(accent)
                        Text(timeRange(context.state))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.start, style: .timer)
                        .font(.system(.headline, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .frame(maxWidth: 78)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.location.isEmpty {
                            Label(context.state.location, systemImage: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            } compactLeading: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.start, style: .timer)
                    .font(.system(.caption, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    /// 「08:00 – 09:40」。
    ///
    /// 用 `Text(_:style: .time)` 而不是 DateFormatter：那个遵守用户的
    /// 12/24 小时制设置，而且**不需要**我们带时区字符串进去。
    private func timeRange(_ s: NextClassActivityAttributes.ContentState) -> Text {
        Text(s.start, style: .time) + Text(" – ") + Text(s.end, style: .time)
    }
}

// MARK: - 锁屏卡片

/// iPhone 和 iPad 的锁屏形态。
///
/// iPad 没有灵动岛，这张卡片就是它在 iPad 上的**全部**样子 ——
/// 所以信息要在这一个视图里说全，不能指望用户去展开。
private struct LockScreenCard: View {

    let state: NextClassActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !state.location.isEmpty {
                        Label(state.location, systemImage: "mappin.and.ellipse")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(state.start, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(state.start, style: .timer)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Text(state.end, style: .time)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
