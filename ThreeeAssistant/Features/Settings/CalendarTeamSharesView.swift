import SwiftUI

/// 把一张日历共享给哪些团队。
///
/// ## 为什么要有这个页面
///
/// 「把日历一个个分享给一个个具体的人」在班级场景里走不通：三十个人要加三十次。
/// 团队把这件事变成「共享给团队一次」—— 后面新加入团队的人自动能看到，
/// 不需要谁再动这张日历的成员名单。
///
/// ## 源码里的两条硬约束（会直接反映到界面上）
///
/// ① **角色上限 editor**：团队永远拿不到 admin/owner。
///    服务端对更高的角色直接 400，**不静默降级**
///    （源码注释：「静默降级会让共享者以为自己给了 admin」）。
///    所以这里的 Picker 只给「可编辑 / 只读」两项，不做任何自动转换。
///
/// ② **先加入、后共享**：`POST /api/calendars/{id}/teams` 会真的校验
///    「我是不是这个团队的成员」，不是只在界面上藏起来。
///    所以团队候选列表只列「我已经加入的团队」（`GET /api/teams` 本身就只回这些）。
struct CalendarTeamSharesView: View {

    let calendarID: String

    @Environment(SessionStore.self) private var store

    @State private var shares: [TeamCalendarShareDTO] = []
    @State private var teams: [TeamDTO] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?

    @State private var showPicker = false
    @State private var confirmingRemove: TeamCalendarShareDTO?

    private var calendarName: String {
        store.calendarsByID[calendarID]?.name ?? "这张日历"
    }

    /// 还没共享出去的团队（候选池）
    private var candidates: [TeamDTO] {
        let shared = Set(shares.map { $0.teamID })
        return teams.filter { !shared.contains($0.id) }
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
        .navigationTitle("共享给团队")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(busy)
            }
        }
        .sheet(isPresented: $showPicker) {
            ShareToTeamSheet(
                calendarID: calendarID,
                candidates: candidates,
                onShared: { Task { await reload() } }
            )
        }
        .alert("取消共享？", isPresented: Binding(
            get: { confirmingRemove != nil },
            set: { if !$0 { confirmingRemove = nil } }
        ), presenting: confirmingRemove) { s in
            Button("取消共享", role: .destructive) {
                unshare(s)
            }
            Button("返回", role: .cancel) { confirmingRemove = nil }
        } message: { s in
            Text("「\(s.name)」里的人将看不到「\(calendarName)」。他们自己创建的日程不受影响。")
        }
        .task { await reload() }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            Section {
                if shares.isEmpty {
                    Text("还没有共享给任何团队")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(shares) { s in
                        shareRow(s)
                    }
                }
            } header: {
                Text("已共享给 \(shares.count) 个团队")
            } footer: {
                Text("团队里的人通过团队获得权限，不会出现在上面的成员名单里。想收回，取消共享即可。")
            }

            Section {
                NavigationLink {
                    TeamListView()
                } label: {
                    Label("管理我的团队", systemImage: "person.3.sequence")
                }
            } footer: {
                Text("只能共享给「我已经加入的团队」。先去团队里，再回来共享。")
            }
        }
    }

    @ViewBuilder
    private func shareRow(_ s: TeamCalendarShareDTO) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? "（团队已删）" : s.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                Text(s.role == "editor" ? "可编辑这张日历" : "只读")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmingRemove = s
            } label: {
                Label("取消共享", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - 动作

    private func reload() async {
        loading = true
        failure = nil
        do {
            // 两个请求要一起成功：只拿到一半会显示成
            // 「已共享给 2 个团队」但列表里只有一个，或者全空
            async let remoteShares = store.loadCalendarTeamShares(calendarID: calendarID)
            async let remoteTeams = store.loadTeams()
            shares = try await remoteShares
            teams = try await remoteTeams
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func unshare(_ s: TeamCalendarShareDTO) {
        confirmingRemove = nil
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.unshareCalendarFromTeam(calendarID: calendarID, teamID: s.teamID)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 选团队

/// 从「我加入的团队」里挑一个共享出去。
struct ShareToTeamSheet: View {

    let calendarID: String
    let candidates: [TeamDTO]
    let onShared: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var role = "viewer"
    @State private var busyTeamID: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("权限", selection: $role) {
                        Text("只读").tag("viewer")
                        Text("可编辑").tag("editor")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("团队最多只能拿到「可编辑」。管理员权限不能给团队 —— 否则任何团队管理员建个团队就能把别人日历的成员管理权收走。")
                }

                if let msg = failure {
                    Section {
                        ErrorBanner(message: msg)
                    }
                }

                Section {
                    if candidates.isEmpty {
                        Text("没有可共享的团队")
                            .foregroundStyle(Theme.textTertiary)
                        Text("要么你还没加入任何团队，要么已经全共享过了。")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(candidates) { t in
                            Button {
                                share(t)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.name)
                                            .foregroundStyle(Theme.textPrimary)
                                        Text("\(t.memberCount ?? 0) 人 · \(t.roleLabel)")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    if busyTeamID == t.id {
                                        ProgressView().scaleEffect(0.7)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(busyTeamID != nil)
                        }
                    }
                } header: {
                    Text("选一个团队")
                }
            }
            .navigationTitle("共享给团队")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func share(_ t: TeamDTO) {
        guard busyTeamID == nil else { return }
        busyTeamID = t.id
        failure = nil
        Task {
            do {
                try await store.shareCalendarToTeam(
                    calendarID: calendarID, teamID: t.id, role: role
                )
                onShared()
                dismiss()
            } catch {
                failure = store.message(for: error)
                busyTeamID = nil
            }
        }
    }
}
