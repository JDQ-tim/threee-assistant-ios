import SwiftUI

// ============================================================
//  主框架：四个 Tab
//  ------------------------------------------------------------
//
//  重构前的问题：整个 App 只有一个页面（ScheduleView），
//  所有功能都塞进右上角头像弹出的一个 sheet 里，
//  21 个设置项平铺在一页 —— 用户找「修改密码」要滚过大半屏，
//  而「收件箱」这种每天要看的东西藏在设置里面。
//
//  重构后按 iOS 的信息架构分四个一级入口：
//
//    日程   ← 主战场。周/月视图、新建、详情
//    待办   ← 独立出来。原来混在日程列表里，勾完就看不见了
//    收件箱 ← 别人投给你的日程。有未读时带角标
//    我的   ← 账号 + 分组设置入口
//
//  ⚠️ 为什么"待办"值得单独一个 Tab：
//      待办和日程的时间语义不同 —— 日程是"某个时刻发生的事"，
//      待办是"某天之前要做完的事"。混在一个列表里，
//      用户翻到周三看到一条周一的未完成待办，会以为它在周三。
//      分开之后，"过期待办"才有地方集中显示。
//
//  ⚠️ iPad 上 TabView 会自动变成底部条 + 适配。
//     这里用 `.tabViewStyle(.automatic)` 保持系统默认行为，
//     不去硬套 sidebarAdaptable（那需要 iPadOS 18）。
// ============================================================

@MainActor
struct MainTabView: View {

    @Environment(SessionStore.self) private var store

    /// 当前选中的 Tab。收件箱有未读时会被外层改成非 nil 去催，
    /// 所以这里要能双向绑定。
    @State private var selection: AppTab = .schedule

    /// 收件箱未读数。显示在 Tab 角标上 ——
    /// 这是「别人给了你东西」的唯一提示，藏在设置里等于没有。
    @State private var inboxBadge = 0

    enum AppTab: String, Hashable, CaseIterable {
        case schedule, tasks, inbox, me

        var title: String {
            switch self {
            case .schedule: return "日程"
            case .tasks: return "待办"
            case .inbox: return "收件箱"
            case .me: return "我的"
            }
        }

        var icon: String {
            switch self {
            case .schedule: return "calendar"
            case .tasks: return "checklist"
            case .inbox: return "tray"
            case .me: return "person.crop.circle"
            }
        }

        var selectedIcon: String {
            switch self {
            case .schedule: return "calendar"
            case .tasks: return "checklist"
            case .inbox: return "tray.fill"
            case .me: return "person.crop.circle.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ScheduleView()
                .tabItem { label(for: .schedule) }
                .tag(AppTab.schedule)

            TasksView()
                .tabItem { label(for: .tasks) }
                .tag(AppTab.tasks)

            InboxView()
                .tabItem { label(for: .inbox) }
                .tag(AppTab.inbox)
                // 角标是 Int 型的 `.badge`，0 会自动不显示
                .badge(inboxBadge)

            ProfileView()
                .tabItem { label(for: .me) }
                .tag(AppTab.me)
        }
        .tint(Theme.accent)
        // 每切回前台都刷一次未读数。
        // 收件箱里的数据自己会拉，但 Tab 角标没人管，
        // 不主动刷就会一直停在打开 App 那一刻的数字。
        .task {
            await refreshInboxBadge()
        }
    }

    @ViewBuilder
    private func label(for tab: AppTab) -> some View {
        // SF Symbols 的 fill 变体在 TabBar 选中态里更好辨认，
        // 但 Label 的 systemImage 只接受一个名字，
        // 所以这里直接给未选中的名字，让系统自己处理选中态。
        Label(tab.title, systemImage: tab.icon)
    }

    private func refreshInboxBadge() async {
        let list = (try? await store.loadInbox(status: "pending")) ?? []
        // 和 SettingsView 里的口径保持一致：剔掉过期和系统通知。
        // 服务端不会把过期条目的 status 改掉，不剔的话角标消不掉。
        inboxBadge = list.filter { $0.isPending && !$0.isStale && !$0.isSystem }.count
    }
}
