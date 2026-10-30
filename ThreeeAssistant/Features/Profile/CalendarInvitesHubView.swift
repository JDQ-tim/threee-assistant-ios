import SwiftUI
import UIKit

// ============================================================
//  日历邀请（我的 → 协作 → 日历邀请）
//  ------------------------------------------------------------
//
//  ## 为什么不是直接复用 CalendarInvitesView
//
//  那个页面是**单张日历**的邀请码管理（`let calendarID: String`），
//  进得去是因为先在某张日历的上下文里。放在「我的」这一层没有上下文可用，
//  硬塞一个 `store.calendars.first` 会让用户莫名其妙地看到别人的码。
//
//  所以这里是**汇总**：遍历我参与的所有日历，把邀请码按日历分组摊开。
//  语义上，「我的」该回答的是「我发出去过哪些码、哪些还有效、快去撤掉」，
//  而不是「这张日历有哪些码」——后者属于日历自己。
//
//  ## 两个入口的分工
//
//  - **用邀请码加入别人的日历** —— 全局动作，和我在不在任何日历里无关。
//    这条必须有，而且必须显眼：新用户第一件事就是加入别人的日历。
//  - **按日历分组的已发出邀请** —— 只读汇总，撤销走原页面。
//    这里不做新建/撤销：那需要日历上下文，点进去才对。
// ============================================================

@MainActor
struct CalendarInvitesHubView: View {

    @Environment(SessionStore.self) private var store

    @State private var groups: [InviteGroup] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var showJoin = false

    /// 一张日历 + 它名下的邀请码
    struct InviteGroup: Identifiable {
        let calendar: CalendarDTO
        let invites: [CalendarInviteDTO]
        var id: String { calendar.id }
    }

    /// 我只想看「还能用的」有几张 —— 这个数字是「我的」页面上的角标
    private var usableCount: Int {
        groups.reduce(0) { $0 + $1.invites.filter(\.usable).count }
    }

    /// 我没有管理权限的日历查不了邀请码（服务端 403）。
    /// 与其每个都报一次错，不如先按角色过滤，只查能查的。
    ///
    /// 注意这里用 `cal.role` 而不是 `cal.canManage` —— 后者在 `CalendarDTO` 上
    /// 只认 `owner`（那是「能不能改日历本身」），而成员管理服务端认 owner + admin。
    private var manageableCalendars: [CalendarDTO] {
        store.calendars.filter { cal in
            let role = cal.role ?? ""
            return role == "owner" || role == "admin"
        }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .navigationTitle("日历邀请")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showJoin) {
            JoinCalendarSheet()
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            // 加入别人的日历：全局动作，永远排第一
            Section {
                Button {
                    showJoin = true
                } label: {
                    Label("用邀请码加入别人的日历",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("拿到别人给你的 fsi_ 开头的码，从这里加进去。团队邀请码是 fst_，那个要去「我的团队」。")
            }

            if groups.isEmpty {
                Section {
                    Text(manageableCalendars.isEmpty
                         ? "你还没有能管理邀请码的日历。只有创建者和管理员能发邀请码。"
                         : "你还没发出过邀请码。要发的话，去「我的日历」里选一张，进成员页生成。")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textTertiary)
                } header: {
                    Text("已发出的邀请")
                }
            } else {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.invites) { v in
                            inviteRow(v)
                        }
                    } header: {
                        HStack {
                            Text(g.calendar.name)
                            Spacer(minLength: 0)
                            Text("\(g.invites.filter(\.usable).count) 张可用 / 共 \(g.invites.count)")
                                .font(.appCaption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    } footer: {
                        if g.id == groups.last?.id {
                            Text("这里只做查看和复制。要新建或撤销，进那张日历的成员页。")
                        }
                    }
                }
            }
        }
    }

    /// 一行一张码。故意做得比单日历页面简：这里只是「巡检」，
    /// 不提供撤销 —— 撤销需要确认上下文，混在汇总页容易误触。
    private func inviteRow(_ v: CalendarInviteDTO) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(v.code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(v.usable ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text(v.roleLabel)
                    Text("·")
                    Text(v.statusText)
                    Spacer(minLength: 0)
                    Text(expiryText(v))
                }
                .font(.appCaption2)
                .foregroundStyle(Theme.textTertiary)
            }

            if v.usable {
                Button {
                    UIPasteboard.general.string = v.code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appFootnote)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func expiryText(_ v: CalendarInviteDTO) -> String {
        guard v.usable else { return "" }
        let now = Int64(Date.now.timeIntervalSince1970)
        let left = v.expiresAt - now
        if left <= 0 { return "已过期" }
        let days = left / 86400
        if days >= 1 { return "\(days) 天后过期" }
        return "\(max(1, left / 3600)) 小时后过期"
    }

    /// 并发拉每张日历的邀请码。
    ///
    /// 单张失败不拖垮整体：某张日历 403/超时，跳过它、记一条错误，
    /// 其余照常显示。日历多的时候串行会卡很久，所以用 withTaskGroup。
    private func reload() async {
        loading = true
        failure = nil

        let targets = manageableCalendars
        if targets.isEmpty {
            groups = []
            loading = false
            return
        }

        var collected: [InviteGroup] = []
        var firstError: String?

        await withTaskGroup(of: (CalendarDTO, Result<[CalendarInviteDTO], Error>).self) { task in
            for cal in targets {
                task.addTask { [store] in
                    do {
                        let invites = try await store.loadCalendarInvites(calendarID: cal.id)
                        return (cal, .success(invites))
                    } catch {
                        return (cal, .failure(error))
                    }
                }
            }
            for await (cal, result) in task {
                switch result {
                case .success(let invites):
                    if !invites.isEmpty {
                        collected.append(InviteGroup(calendar: cal, invites: invites))
                    }
                case .failure(let err):
                    if firstError == nil {
                        firstError = "「\(cal.name)」的邀请码没读到：\(store.message(for: err))"
                    }
                }
            }
        }

        // 按日历顺序排，和「我的日历」页面一致，避免每次刷新顺序乱跳
        let order = targets.map(\.id)
        collected.sort { a, b in
            (order.firstIndex(of: a.id) ?? 0) < (order.firstIndex(of: b.id) ?? 0)
        }

        groups = collected
        failure = firstError
        loading = false
    }
}
