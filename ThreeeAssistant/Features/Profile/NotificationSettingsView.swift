import SwiftUI
import UIKit
import UserNotifications

// ============================================================
//  提醒与通知
//  ------------------------------------------------------------
//  从原 SettingsView 里剥出来单独一页。
//
//  原设计把这个 Section 埋在 21 个设置项中间，但它其实是
//  **唯一能让用户知道"提醒到底会不会响"的地方**。
//  一个藏起来的真相等于没有真相。
//
//  这一页要回答三个问题：
//    1. 通知权限开了吗？
//    2. 现在排了多少条？
//    3. 为什么有些日程没排上？（60 条上限 / 30 天窗口）
// ============================================================

@MainActor
struct NotificationSettingsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(LiveActivityManager.self) private var live

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var armedCount = 0
    @State private var ruleCount = 0
    /// 系统里**真实**待发的条数。`armedCount` 是"我们认为应该排多少"，
    /// 这个是从 `UNUserNotificationCenter` 实际数回来的。两者不一致就说明
    /// 有通知没排进去（超出上限 / add 失败），不讲出来用户永远不知道。
    @State private var pendingCount = 0
    /// 未来窗口内一共拉到多少条日程，以及其中有多少条是"该有提醒但没排上"的。
    @State private var instanceCount = 0
    @State private var expiredCount = 0
    @State private var loading = false

    var body: some View {
        List {
            Section {
                LabeledContent("系统权限", value: statusText)
            } footer: {
                Text(statusFooter)
            }

            liveActivitySection

            // 这一段以前是 `if ruleCount > 0` —— 零条时整段消失。
            // 结果是：用户看到「系统权限：已开启」+「重新排一遍」两行，
            // 找不到任何一句解释"为什么到点不响"。
            // 而真实原因恰恰就是这一段该说的话：你的日程一条都没配提醒。
            // 沉默不是中立，沉默会被读成"功能坏了"。
            if ruleCount > 0 {
                Section {
                    LabeledContent("配了提醒的日程", value: "\(ruleCount) 条")
                    LabeledContent("已排进系统", value: "\(armedCount) 条")
                    if pendingCount != armedCount {
                        LabeledContent("系统里实际待发", value: "\(pendingCount) 条")
                            .foregroundStyle(Theme.amber600)
                    }
                } footer: {
                    Text("iOS 单个 App 的待发通知上限是 64 条，这里按 \(ReminderScheduler.maxPending) 条自截。只排未来 \(ReminderScheduler.horizonDays) 天 —— 明年的日程现在排不进去，等它进入 30 天窗口时会自动补上。")
                }

                if expiredCount > 0 {
                    Section {
                        Text("有 \(expiredCount) 条日程已经过了开始时间，它们的提醒时刻也一起过去了，所以不会响 —— 这是正常的。")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Section {
                    Label(
                        instanceCount > 0
                            ? "未来 \(ReminderScheduler.horizonDays) 天有 \(instanceCount) 条日程，但一条提醒都没配"
                            : "还没有任何日程",
                        systemImage: "bell.slash"
                    )
                    .foregroundStyle(Theme.amber600)
                } footer: {
                    Text(emptyRuleHint)
                }
            }

            Section {
                switch status {
                case .denied:
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("去系统设置开启", systemImage: "gear")
                    }
                case .notDetermined:
                    Button {
                        Task { await enable() }
                    } label: {
                        Label("开启提醒", systemImage: "bell.badge")
                    }
                    .disabled(loading)
                default:
                    Button {
                        Task { await reschedule() }
                    } label: {
                        Label(loading ? "正在重排…" : "重新排一遍", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            } footer: {
                if status == .authorized || status == .provisional {
                    Text("「重新排一遍」用在换了设备、或者改了系统时间之后。平时每次打开 App 会自动补排，不需要手动点。")
                }
            }

            if status == .denied {
                Section {
                    Text("iOS 的通知授权只会询问一次。你之前拒绝过，系统就不会再弹框了 —— 只能去「设置 → 通知 → 学习助手」里手动打开。")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("提醒与通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var statusText: String {
        switch status {
        case .authorized: return "已开启"
        case .provisional: return "静默送达"
        case .ephemeral: return "临时授权"
        case .denied: return "已关闭"
        case .notDetermined: return "未询问"
        @unknown default: return "未知"
        }
    }

    /// 实时活动（灵动岛 / 锁屏卡片）。
    ///
    /// ## 为什么单独开一段，而不是并进"提醒"
    ///
    /// 它和提醒是**两套东西**，只是都长在锁屏上：
    ///   · 提醒 = `UNNotification`，到点弹一下就走
    ///   · 实时活动 = 一条**常驻**的状态，下课才收
    /// 混在一起写，用户会以为关了提醒它也消失。
    ///
    /// ## 为什么这里必须说清"iPad 上没有灵动岛"
    ///
    /// 用户在 iPad 上打开这个开关，然后去主屏找灵动岛，找不到 ——
    /// 会以为功能坏了。它在这里的真实形态是**锁屏底部那张卡片**。
    @ViewBuilder
    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { live.isEnabled },
                set: { on in
                    live.setEnabled(on)
                    if on {
                        Task { await live.sync(instances: store.instances) }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示下一节课")
                        .font(.appBody)
                    Text("课前 30 分钟出现，下课后自动收起")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let t = live.showingTitle {
                LabeledContent("正在显示", value: t)
            }

            if let e = live.lastError {
                Text(e)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.amber600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("实时活动")
        } footer: {
            Text("它和上面的「提醒」是两回事：提醒到点弹一下就走，实时活动是一条**常驻**的状态，下课才收。\n\niPhone 14 Pro 及以上会同时出现在灵动岛里；iPad 上没有灵动岛，只会显示成锁屏底部的一张卡片（需要 iPadOS 26 以上）。\n\n系统总开关在「设置 → 通知 → 学习助手 → 实时活动」。")
        }
    }

    private var statusFooter: String {
        switch status {
        case .denied:
            return "通知被关掉了，日程提醒不会响。"
        case .notDetermined:
            return "还没申请通知权限。不打开的话，日程里设的提醒不会响。"
        case .provisional:
            return "静默送达：通知会出现在通知中心，但不会弹出来也不会响。想要真正提醒，请去系统设置里改成「允许通知」。"
        default:
            return "提醒会在设定的时刻弹出。强提醒（时效性通知）即使开了专注模式也能穿透。"
        }
    }

    private var emptyRuleHint: String {
        if instanceCount > 0 {
            return "通知不是按「有日程」发的，是按「这条日程设了提醒」发的。新建日程时把「到点提醒我」打开（默认就是开着的，提前 15 分钟），或者在已有日程的详情里补一个提醒 —— 加完之后回到这一页点「重新排一遍」。"
        }
        return "先去「日程」里建一条，建的时候「到点提醒我」默认是开着的。完成后回到这一页点「重新排一遍」。"
    }

    private func load() async {
        await ReminderScheduler.shared.refreshAuthorization()
        status = ReminderScheduler.shared.authorization
        armedCount = ReminderScheduler.shared.armedCount
        ruleCount = ReminderRuleCache.shared.count
        pendingCount = await ReminderScheduler.shared.pendingCountNow()
        let stats = await ReminderScheduler.shared.windowStats()
        instanceCount = stats.instances
        expiredCount = stats.expired
    }

    private func enable() async {
        loading = true
        await ReminderScheduler.shared.requestAuthorizationIfNeeded()
        await store.prepareReminders(forceRules: true)
        await load()
        loading = false
    }

    private func reschedule() async {
        loading = true
        await store.prepareReminders(forceRules: true)
        await load()
        loading = false
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
