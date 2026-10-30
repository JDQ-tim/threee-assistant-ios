import SwiftUI
import UIKit
import UserNotifications

// ============================================================
//  我的
//  ------------------------------------------------------------
//
//  重构前：这里就是 SettingsView，21 个设置项平铺在一个 List 里，
//  「修改密码」在第 12 屏，「清空数据」在第 15 屏。
//  用户根本不知道这些功能存在 —— 更糟的是，收件箱、天气这种
//  **日常功能**也埋在里面。
//
//  重构后的结构（按 iOS「我的/设置」通用范式）：
//
//    ┌─ 头像卡片（名字、身份、服务器）
//    ├─ 常用 ──────── 提醒通知、我的日历
//    ├─ 协作 ──────── 团队、日历共享邀请、我的举报
//    ├─ 数据与同步 ── 同步状态、背词同步、修改冲突
//    ├─ 偏好 ──────── 天气、天气城市、用户组
//    ├─ 安全 ──────── 修改密码、服务器证书
//    ├─ 关于 ──────── 版本、数据自检（管理员）
//    └─ 退出登录
//
//  ⚠️ 首屏只放「高频 + 需要一眼看到异常」的东西。
//     其余全部收进子页 —— 子页之间是平级的，不再有"设置里的设置"。
//
//  ⚠️ 通知权限异常是唯一会"浮到首屏"的告警：
//     用户拒绝通知之后，App 里一切照常（能设提醒、详情页也显示"提前15分钟"），
//     只有明确告诉他"其实一条都不会响"，才不会某天误事。
// ============================================================

@MainActor
struct ProfileView: View {

    @Environment(SessionStore.self) private var store

    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    @State private var armedCount = 0
    @State private var reminderRuleCount = 0
    @State private var pendingConflicts = 0
    @State private var inboxPending = 0
    @State private var teamCount = 0
    @State private var confirmingLogout = false
    @State private var busy = false

    private var isAdmin: Bool { store.user?.isAdmin ?? false }

    var body: some View {
        NavigationStack {
            List {
                profileHeader

                if notifyStatus == .denied || notifyStatus == .notDetermined {
                    notificationWarning
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        row(icon: "bell.badge", tint: .red, title: "提醒与通知",
                            detail: notifyStatus == .authorized
                                ? "已排 \(armedCount) 条"
                                : notifyStatusText)
                    }

                    NavigationLink {
                        CalendarsView()
                    } label: {
                        row(icon: "calendar", tint: .blue, title: "我的日历",
                            detail: "\(store.calendars.count) 张")
                    }
                } header: {
                    Text("常用")
                }

                Section {
                    NavigationLink {
                        TeamListView()
                    } label: {
                        row(icon: "person.2", tint: .green, title: "我的团队",
                            detail: teamCount > 0 ? "\(teamCount) 个" : nil,
                            badge: nil)
                    }

                    NavigationLink {
                        CalendarInvitesHubView()
                    } label: {
                        row(icon: "envelope.badge", tint: .orange, title: "日历邀请",
                            detail: nil, badge: nil)
                    }

                    NavigationLink {
                        MyReportsView()
                    } label: {
                        row(icon: "flag", tint: .gray, title: "我的举报",
                            detail: nil, badge: nil)
                    }
                } header: {
                    Text("协作")
                } footer: {
                    Text("团队和日历邀请都是别人给你的东西。收件箱里放的是单条日程，这里放的是整张日历的共享。")
                }

                Section {
                    NavigationLink {
                        SyncStatusView()
                    } label: {
                        row(icon: "arrow.triangle.2.circlepath", tint: .blue, title: "同步",
                            detail: store.syncCursor > 0 ? "游标 \(store.syncCursor)" : "未同步")
                    }

                    NavigationLink {
                        WordbookSyncView()
                    } label: {
                        row(icon: "character.book.closed", tint: .purple, title: "背词同步",
                            detail: nil, badge: nil)
                    }

                    NavigationLink {
                        ConflictsView()
                    } label: {
                        row(icon: "exclamationmark.triangle", tint: .orange, title: "修改冲突",
                            detail: pendingConflicts > 0 ? nil : "无",
                            badge: pendingConflicts > 0 ? pendingConflicts : nil)
                    }
                } header: {
                    Text("数据与同步")
                } footer: {
                    Text("背词是另一个端口上的独立服务（8446），和日程同步（8443）互不影响。修改冲突指多人同时改同一条时被拦下的字段，不处理会一直显示旧值。")
                }

                Section {
                    NavigationLink {
                        WeatherView()
                    } label: {
                        row(icon: "cloud.sun", tint: .cyan, title: "天气",
                            detail: nil, badge: nil)
                    }

                    NavigationLink {
                        WeatherLocationView()
                    } label: {
                        row(icon: "location", tint: .cyan, title: "天气城市",
                            detail: nil, badge: nil)
                    }

                    NavigationLink {
                        TierView()
                    } label: {
                        row(icon: "star.circle", tint: .yellow, title: "用户组",
                            detail: nil, badge: nil)
                    }
                } header: {
                    Text("偏好")
                } footer: {
                    Text("天气是服务器按配置的坐标取预报，不是设备定位。改「天气城市」就是改那个坐标。")
                }

                Section {
                    NavigationLink {
                        ChangePasswordView()
                    } label: {
                        row(icon: "key", tint: .gray, title: "修改密码",
                            detail: nil, badge: nil)
                    }

                    NavigationLink {
                        SecurityView()
                    } label: {
                        row(icon: "lock.shield", tint: .gray, title: "安全与证书",
                            detail: nil, badge: nil)
                    }
                } header: {
                    Text("安全")
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        row(icon: "info.circle", tint: .gray, title: "关于",
                            detail: "0.1 (1)")
                    }

                    if isAdmin {
                        NavigationLink {
                            SiteInviteView()
                        } label: {
                            row(icon: "person.badge.key", tint: .orange, title: "注册码",
                                detail: nil, badge: nil)
                        }

                        NavigationLink {
                            DataIntegrityView()
                        } label: {
                            row(icon: "stethoscope", tint: .orange, title: "数据自检",
                                detail: nil, badge: nil)
                        }
                    }
                } header: {
                    Text("关于")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingLogout = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(busy ? "正在退出…" : "退出登录")
                                .font(.appBody)
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog("退出登录？", isPresented: $confirmingLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    busy = true
                    Task {
                        await store.logout()
                        busy = false
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已下载的日程和提醒会留在本机，下次登录同一个账号会继续用。")
            }
            .task {
                await loadState()
            }
        }
    }

    // MARK: - 头像卡片

    private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                // 没有头像上传接口，用名字首字生成一个圆形标识。
                // 比空白的人影图标更有辨识度，也不用多一次网络请求。
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(initialOfName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.user?.name.nonEmpty(or: "未命名"))
                        .font(.appTitle)
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 6) {
                        Text(isAdmin ? "管理员" : "普通成员")
                            .font(.appBadge)
                            .foregroundStyle(isAdmin ? Theme.amber600 : Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(isAdmin ? Theme.amber50 : Theme.surfaceAlt)
                            .clipShape(Capsule())

                        Text(store.serverText)
                            .font(.appCaption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private var initialOfName: String {
        let name = store.user?.name ?? ""
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: - 通知告警

    /// 只有「被拒绝」或「还没问」时才浮到首屏。
    private var notificationWarning: some View {
        Section {
            Button {
                if notifyStatus == .notDetermined {
                    Task {
                        await ReminderScheduler.shared.requestAuthorizationIfNeeded()
                        await store.prepareReminders(forceRules: true)
                        await loadState()
                    }
                } else {
                    openSystemSettings()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(Theme.red600)
                        .font(.appSubheadline)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notifyStatus == .notDetermined ? "提醒还没开启" : "提醒已被关闭")
                            .font(.appSubheadline.weight(.semibold))
                            .foregroundStyle(Theme.red600)
                        Text(notifyStatus == .notDetermined
                             ? "点这里开启。不开启的话，日程里设的提醒不会响。"
                             : "系统里关掉了通知，日程提醒不会响。点这里去设置打开。")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 行组件

    private func row(icon: String, tint: Color, title: String,
                     detail: String?, badge: Int? = nil) -> some View {
        HStack(spacing: 12) {
            // 系统设置那种彩色小方块图标。
            // 用 RoundedRectangle + 白色 SF Symbol，
            // 是 iOS「设置」从 iOS 13 起就固化的视觉语言。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(title)
                .font(.appBody)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            if let badge {
                Text("\(badge)")
                    .font(.appBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.red600)
                    .clipShape(Capsule())
            } else if let detail {
                Text(detail)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - 状态

    private var notifyStatusText: String {
        switch notifyStatus {
        case .authorized: return "已开启"
        case .provisional: return "静默送达"
        case .ephemeral: return "临时授权"
        case .denied: return "已关闭"
        case .notDetermined: return "未开启"
        @unknown default: return "未知"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 一次拿齐所有角标要用的数字。
    ///
    /// 全部失败静默 —— 这些是「附加信息」，
    /// 为了它们弹错误横幅，比少显示一个数字更烦人。
    private func loadState() async {
        await ReminderScheduler.shared.refreshAuthorization()
        notifyStatus = ReminderScheduler.shared.authorization
        armedCount = ReminderScheduler.shared.armedCount
        reminderRuleCount = ReminderRuleCache.shared.count

        pendingConflicts = ((try? await store.loadConflicts()) ?? []).count
        teamCount = ((try? await store.loadTeams()) ?? []).count

        let inbox = (try? await store.loadInbox(status: "pending")) ?? []
        inboxPending = inbox.filter { $0.isPending && !$0.isStale && !$0.isSystem }.count
    }
}
