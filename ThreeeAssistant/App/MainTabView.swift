import SwiftUI

// ============================================================
//  主框架：五个 Tab（与安卓端对齐）
//  ------------------------------------------------------------
//  2026-11-05 按安卓端录屏重做。之前是 4 个（日程/待办/收件箱/我的），
//  安卓端是 5 个：日历 / 日程 / **主页** / 收件箱 / AI。
//
//  ## 三处结构性变化，都是有意的
//
//  **① 主页成为落地页。**
//  安卓端把「主页」放在正中间，它是各模块的汇总 —— 天气、今日日程、
//  更新提示都在那儿。iOS 原来落在「日程」上，那是一个"办具体事"的页，
//  不是"看今天整体"的页。这两种页的职责不一样。
//
//  **② 「待办」不再是独立 Tab。**
//  安卓端也没有这个 Tab：待办是「日程 → 列表」里的一个分组
//  （`AgendaTab.kt:171` 的 `SectionHeader("待办")`）。理由在那边写得很清楚：
//  待办和日程是同一份数据（`is_task` 一个布尔位），分成两个 Tab
//  会出现"这条算日程还是待办"的二义性。
//
//  ⚠️ 但功能不能丢。`TasksView` 保留，从「日程 → 列表」顶部的
//     「全部待办」进去 —— 那里才有跨天的待办汇总。
//
//  **③ 底部导航栏是自绘的，不是系统 TabView。**
//  ------------------------------------------------------------
//  见 `AndroidStyleTabBar` 上面那段。一句话：iOS 26 的 TabView 会变成
//  悬浮的玻璃胶囊，而安卓端（和录屏里）是**贴着屏幕底边的一整条实底**。
//  要"一模一样"，就只能自己画。
// ============================================================

@MainActor
struct MainTabView: View {

    @Environment(SessionStore.self) private var store

    @State private var selection: AppTab = .home

    /// 收件箱未读数。显示在 Tab 角标上 ——
    /// 这是「别人给了你东西」的唯一提示，藏在设置里等于没有。
    @State private var inboxBadge = 0

    enum AppTab: String, Hashable, CaseIterable {
        case calendars, schedule, home, inbox, ai

        var title: String {
            switch self {
            case .calendars: return "日历"
            case .schedule:  return "日程"
            case .home:      return "主页"
            case .inbox:     return "收件箱"
            case .ai:        return "AI"
            }
        }

        /// ⚠️ 顺序必须和安卓端一致：日历 / 日程 / 主页 / 收件箱 / AI。
        ///    主页在正中间这件事在两端都是刻意的 —— 它是"回家"的位置。
        var icon: String {
            switch self {
            case .calendars: return "calendar"
            case .schedule:  return "list.bullet.rectangle"
            case .home:      return "house"
            case .inbox:     return "tray"
            case .ai:        return "sparkles"
            }
        }

        /// 选中时换实心图标。
        ///
        /// 安卓端是"选中项背后垫一块圆角容器"，iOS 上没有直接对应物；
        /// 实心/描边 + 着色，是 iOS 用户一眼就懂的表达，
        /// 同时也不会像胶囊那样抢标题的注意力。
        var iconSelected: String {
            switch self {
            case .calendars: return "calendar.circle.fill"
            case .schedule:  return "list.bullet.rectangle.fill"
            case .home:      return "house.fill"
            case .inbox:     return "tray.fill"
            case .ai:        return "sparkles"
            }
        }
    }

    var body: some View {
        // ⚠️ 用 ZStack 而不是 TabView，是为了让底栏自己画（见文件头 ③）。
        //
        //    用 ZStack + opacity 而不是 switch：五页里每一页都自带
        //    NavigationStack（各自有滚动位置、各自 push 着子页），
        //    用 switch 换的是**另一个视图实例**，切回来就回到根页面了。
        //
        //    ⚠️ 代价是五个 Tab 在同一个布局里 / 里同时存在。
        //    `.opacity(0)` 的页仍然会参与布局、仍然在响应链里 ——
        //    这恰恰是我们要的（状态保住），但它也确实占内存。
        //    对五个都是列表页的 App 来说，这点开销换"切回来还记得
        //    你翻到哪一周"，是划算的。
        // ⚠️ 底栏用 `safeAreaInset` 挂上去，不是塞进 VStack ——
        //    见 `AndroidStyleTabBar` 里那段。VStack 里放的话，
        //    列表会把最后一条内容滚到底栏**下面**去。
        ZStack {
            CalendarTabView().tabPane(selection == .calendars)
            ScheduleView().tabPane(selection == .schedule)
            HomeView(onOpenTab: { selection = $0 }).tabPane(selection == .home)
            InboxView().tabPane(selection == .inbox)
            AITabView().tabPane(selection == .ai)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AndroidStyleTabBar(
                selection: $selection,
                inboxBadge: inboxBadge
            )
        }
        .background(Theme.background)
        // 每切回前台都刷一次未读数。
        // 收件箱里的数据自己会拉，但底栏角标没人管，
        // 不主动刷就会一直停在打开 App 那一刻的数字。
        .task {
            await refreshInboxBadge()
        }
    }

    private func refreshInboxBadge() async {
        let list = (try? await store.loadInbox(status: "pending")) ?? []
        // 和 SettingsView 里的口径保持一致：剔掉过期和系统通知。
        // 服务端不会把过期条目的 status 改掉，不剔的话角标消不掉。
        inboxBadge = list.filter { $0.isPending && !$0.isStale && !$0.isSystem }.count
    }
}

private extension View {
    /// 一页 Tab 的显示/隐藏。
    ///
    /// 三个修饰符缺一不可：
    /// · `opacity`  —— 看不见
    /// · `allowsHitTesting` —— 挡住了下面的页就点不动（否则五页的
    ///   按钮全叠在一起，点哪儿都可能是另一个 Tab 的东西）
    /// · `accessibilityHidden` —— 否则读屏软件会把五个 Tab 的内容
    ///   全部念一遍，用户会以为界面坏了
    func tabPane(_ visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

// ============================================================
//  底部导航栏（照安卓端录屏画的）
//  ------------------------------------------------------------
//  ## 为什么不直接用系统的 `TabView { ... .tabItem }`
//
//  iOS 26 起 TabView 的底栏变成了**悬浮的液体玻璃胶囊**：
//  左右留白、圆角、和屏幕底边之间有一条缝、滚动时会缩。
//  而安卓端（也就是录屏里那一版）是**贴着屏幕底边的一整条实底**，
//  顶边一条细分隔线，五个图标等分铺满。
//
//  用户的要求是「一模一样」。这两个形态的差别不是颜色和圆角，
//  是**底栏是不是一整条** —— 调 TabView 的参数调不出来。
//  所以这里自绘。
//
//  ## 自绘之后失去的东西（代价，写明白）
//
//  · iOS 26 的玻璃/收缩动画 —— 本来就和安卓端不一样，本来就不要
//  · 系统的 Tab 无障碍分组 —— 用 `.accessibilityAddTraits(.isButton)`
//    和 `accessibilityLabel` 补回来，VoiceOver 仍然能读能点
//  · 侧滑返回、双击状态栏回顶 —— 那些属于 `NavigationStack`，
//    每页自己的 `NavigationStack` 里还在，没受影响
//
//  ## 高度为什么是 52 + 安全区
//
//  安卓端底栏内容区约 56dp。`minHeight: 52` 是给"内容不撑高"
//  兜底的，安全区（全面屏那条 home indicator）由 `safeAreaInset` 自动补 ——
//  自己加数字的话，在 iPad 上会多出一条空。
// ============================================================

@MainActor
private struct AndroidStyleTabBar: View {

    @Binding var selection: MainTabView.AppTab

    let inboxBadge: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTabView.AppTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        // 顶边那条分隔线 + 实底。
        //
        // ⚠️ 用 `.overlay(alignment: .top)` 而不是 `VStack { Divider(); ... }`：
        //    Divider 会占掉高度，底栏就比算好的 52 高一截；
        //    而且系统 Divider 的颜色在深色下偏亮，和安卓端那条细线对不上。
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)
        }
        // 底栏必须一直看得见，页面滚到内容下面时不能跟着动 ——
        // 挂载点用的是 `safeAreaInset`（见 MainTabView），所以这里只管画。
        .frame(minHeight: 52)
    }

    private func item(_ tab: MainTabView.AppTab) -> some View {
        let on = selection == tab

        return Button {
            guard !on else { return }
            // 换 Tab 时不加弹簧：安卓端是淡入淡出，
            // 弹一下反而像"按歪了又弹回来"。
            selection = tab
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: on ? tab.iconSelected : tab.icon)
                        .font(.system(size: 20, weight: on ? .semibold : .regular))
                        .frame(width: 30, height: 24)

                    // 角标。位置固定在图标右上角外侧一点点 ——
                    // 跟着文字宽度走的话，收件箱三个字会把角标推到格子边缘
                    if tab == .inbox && inboxBadge > 0 {
                        Text(inboxBadge > 99 ? "99+" : "\(inboxBadge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Theme.red600)
                            .clipShape(Capsule())
                            .offset(x: 11, y: -5)
                    }
                }

                Text(tab.title)
                    .font(.system(size: 10, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                    // 「收件箱」三个字在小字号下最容易被挤，
                    // 允许它缩到 0.85 —— 不缩的话五个格子不等宽，看着歪
                    .minimumScaleFactor(0.85)
            }
            // 触摸区铺满整个格子，而不是只有图标那点大 ——
            // 底栏是拇指最容易按偏的地方
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 选中用主色 + 文字加重，未选中用次要色（不是三等灰）：
        // 三等灰在深色背景上几乎看不见，用户会以为那个 Tab 是禁用的
        .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityText(tab))
    }

    private func accessibilityText(_ tab: MainTabView.AppTab) -> String {
        if tab == .inbox && inboxBadge > 0 {
            return "\(tab.title)，\(inboxBadge) 条未读"
        }
        return tab.title
    }
}
