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

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var armedCount = 0
    @State private var ruleCount = 0
    @State private var loading = false

    var body: some View {
        List {
            Section {
                LabeledContent("系统权限", value: statusText)
            } footer: {
                Text(statusFooter)
            }

            if ruleCount > 0 {
                Section {
                    LabeledContent("配了提醒的日程", value: "\(ruleCount) 条")
                    LabeledContent("已排进系统", value: "\(armedCount) 条")
                } footer: {
                    Text("iOS 单个 App 的待发通知上限是 64 条，这里按 \(ReminderScheduler.maxPending) 条自截。只排未来 \(ReminderScheduler.horizonDays) 天 —— 明年的日程现在排不进去，等它进入 30 天窗口时会自动补上。")
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
                    Text("iOS 的通知授权只会询问一次。你之前拒绝过，系统就不会再弹框了 —— 只能去「设置 → 通知 → 3e学习助手」里手动打开。")
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

    private func load() async {
        await ReminderScheduler.shared.refreshAuthorization()
        status = ReminderScheduler.shared.authorization
        armedCount = ReminderScheduler.shared.armedCount
        ruleCount = ReminderRuleCache.shared.count
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
