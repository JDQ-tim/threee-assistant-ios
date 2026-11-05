import SwiftUI

// ============================================================
//  主框架：五个 Tab（与安卓端对齐）
//  ------------------------------------------------------------
//  2026-11-05 按安卓端录屏重做。之前是 4 个（日程/待办/收件箱/我的），
//  安卓端是 5 个：日历 / 日程 / **主页** / 收件箱 / AI。
//
//  ## 两处结构性变化，都是有意的
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
    }

    var body: some View {
        TabView(selection: $selection) {
            CalendarTabView()
                .tabItem { Label(AppTab.calendars.title, systemImage: AppTab.calendars.icon) }
                .tag(AppTab.calendars)

            ScheduleView()
                .tabItem { Label(AppTab.schedule.title, systemImage: AppTab.schedule.icon) }
                .tag(AppTab.schedule)

            HomeView(onOpenTab: { selection = $0 })
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            InboxView()
                .tabItem { Label(AppTab.inbox.title, systemImage: AppTab.inbox.icon) }
                .tag(AppTab.inbox)
                .badge(inboxBadge)

            AITabView()
                .tabItem { Label(AppTab.ai.title, systemImage: AppTab.ai.icon) }
                .tag(AppTab.ai)
        }
        .tint(Theme.accent)
        // 每切回前台都刷一次未读数。
        // 收件箱里的数据自己会拉，但 Tab 角标没人管，
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
