import SwiftUI

/// 一个团队的详情：成员名单、已绑定的日历、邀请码、退出。
///
/// ## 三条规则直接影响这里的每一行 UI
///
/// ① **创建者不能退**（服务端 409：「你是这个团队的创建者，不能退出」）。
///    所以「退出团队」只对非创建者显示。
/// ② **创建者不能被移除**（409：「不能移除团队创建者」），
///    而且**创建者必须保持管理员**（改角色时 409）。
/// ③ **admin 邀请只有创建者能发**。普通管理员只能生成 member 邀请。
///    这条要按 `team.ownerID` 判断，不能只看 `isAdmin` ——
///    否则普通管理员点了才吃 403。
struct TeamDetailView: View {

    let teamID: String

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var detail: TeamDetailResponse?
    @State private var loading = true
    @State private var failure: String?
    @State private var busy = false

    @State private var confirmingLeave = false
    @State private var confirmingRemove: TeamMemberDTO?

    private var team: TeamDTO? { detail?.team }
    private var members: [TeamMemberDTO] { detail?.members ?? [] }
    private var calendars: [TeamCalendarShareDTO] { detail?.calendars ?? [] }

    /// 我是不是这支团队的管理员（能邀人、能移除人）
    private var isAdmin: Bool { team?.isAdmin ?? false }
    /// 我是不是创建者
    private var isOwner: Bool {
        guard let t = team, let me = store.user?.id else { return false }
        return t.ownerID == me
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let msg = failure, detail == nil {
                // 加载彻底失败（比如已被移出团队 → 服务端 404）
                VStack(spacing: 10) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.textTertiary)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("返回") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .navigationTitle(team?.name ?? "团队")
        .navigationBarTitleDisplayMode(.inline)
        .alert("退出这支团队？", isPresented: $confirmingLeave) {
            Button("退出", role: .destructive) { leave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后，这支团队共享的日历会从你的列表里消失。想再进来，需要向管理员要邀请码。")
        }
        .alert("移出这个成员？", isPresented: Binding(
            get: { confirmingRemove != nil },
            set: { if !$0 { confirmingRemove = nil } }
        ), presenting: confirmingRemove) { m in
            Button("移出", role: .destructive) { remove(m) }
            Button("取消", role: .cancel) { confirmingRemove = nil }
        } message: { m in
            Text("「\(m.name)」将看不到这支团队共享的日历。他自己创建的日程不受影响。")
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

            if let t = team {
                Section {
                    if let note = t.note, !note.isEmpty {
                        LabeledContent("说明", value: note)
                    }
                    LabeledContent("我的身份", value: t.roleLabel)
                    LabeledContent("人数", value: "\(t.memberCount ?? Int64(members.count)) 人")
                }
            }

            // 邀请码：只有管理员能看能发
            if isAdmin {
                Section {
                    NavigationLink {
                        TeamInvitesView(teamID: teamID, canCreateAdminInvite: isOwner)
                    } label: {
                        Label("邀请码", systemImage: "ticket")
                    }
                } footer: {
                    Text(isOwner
                         ? "把邀请码发到群里，别人打开就能加入。你作为创建者还能发「管理员邀请」。"
                         : "把邀请码发到群里，别人打开就能加入。管理员邀请只有团队创建者能发。")
                }
            }

            Section {
                if calendars.isEmpty {
                    Text("这支团队还没有绑定任何日历")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(calendars) { c in
                        HStack(spacing: 10) {
                            Image(systemName: c.role == "editor" ? "square.and.pencil" : "eye")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 20)
                            Text(c.name.isEmpty ? "（已删）" : c.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            Text(c.role == "editor" ? "可编辑" : "只读")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            } header: {
                Text("共享的日历")
            } footer: {
                Text("团队能被共享的日历，需要日历拥有者在「日历 → 成员 → 共享给团队」里操作。团队本身不能去拿别人的日历。")
            }

            Section {
                ForEach(members) { m in
                    memberRow(m)
                }
            } header: {
                Text("\(members.count) 位成员")
            }

            // 创建者退出会把团队变成没人管的孤儿 —— 服务端 409，这里干脆不给按钮
            if !isOwner, team != nil {
                Section {
                    Button(role: .destructive) {
                        confirmingLeave = true
                    } label: {
                        Text("退出这支团队")
                    }
                    .disabled(busy)
                } footer: {
                    Text("你是团队创建者，不能退出。")
                        .opacity(isOwner ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: TeamMemberDTO) -> some View {
        let isCreator = team?.ownerID == m.userID
        let isMe = m.userID == store.user?.id

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(m.name)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    if isMe {
                        Text("你")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceAlt)
                            .foregroundStyle(Theme.textSecondary)
                            .clipShape(Capsule())
                    }
                }
                Text(isCreator ? "创建者 · 管理员" : m.roleLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)

            // 改角色：管理员可改别人；创建者恒定管理员，不可改
            if isAdmin && !isCreator {
                Menu {
                    ForEach([("admin", "管理员"), ("member", "成员")], id: \.0) { pair in
                        Button {
                            changeRole(m, to: pair.0)
                        } label: {
                            if m.role == pair.0 {
                                Label(pair.1, systemImage: "checkmark")
                            } else {
                                Text(pair.1)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
                .disabled(busy)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isAdmin && !isCreator && !isMe {
                Button(role: .destructive) {
                    confirmingRemove = m
                } label: {
                    Label("移出", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: - 动作

    private func reload() async {
        loading = true
        failure = nil
        do {
            detail = try await store.loadTeamDetail(id: teamID)
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func changeRole(_ m: TeamMemberDTO, to role: String) {
        guard !busy, role != m.role else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.setTeamMemberRole(teamID: teamID, userID: m.userID, role: role)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    private func remove(_ m: TeamMemberDTO) {
        confirmingRemove = nil
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.removeTeamMember(teamID: teamID, userID: m.userID)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    private func leave() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.leaveTeam(id: teamID)
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 团队邀请码

/// 团队邀请码的生成与撤销。
///
/// ## 为什么默认「不限次数」
///
/// 服务端团队邀请的默认值和日历邀请**故意不同**：日历默认 1 次，
/// 团队默认不限（要给一个班的人）。传 0 就是不限。
///
/// ## 为什么「管理员邀请」只有创建者能发
///
/// 源码（`teams.go:477`）：「一个管理员手上的『发 admin 邀请』能力 =
/// 可以无限复制管理员身份：拿到码的人能踢成员、能再发邀请 ——
/// 足以让爸妈看不到共享日历。所以升权这件事只能由创建者本人做。」
struct TeamInvitesView: View {

    let teamID: String
    /// 当前用户是不是团队创建者（决定能不能发管理员邀请）
    let canCreateAdminInvite: Bool

    @Environment(SessionStore.self) private var store

    @State private var invites: [TeamInviteDTO] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?

    @State private var showCreate = false
    @State private var confirmingRevoke: TeamInviteDTO?

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
        .navigationTitle("邀请码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(busy)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateTeamInviteSheet(
                teamID: teamID,
                canCreateAdminInvite: canCreateAdminInvite
            ) {
                Task { await reload() }
            }
        }
        .alert("撤销这张邀请码？", isPresented: Binding(
            get: { confirmingRevoke != nil },
            set: { if !$0 { confirmingRevoke = nil } }
        ), presenting: confirmingRevoke) { v in
            Button("撤销", role: .destructive) { revoke(v) }
            Button("取消", role: .cancel) { confirmingRevoke = nil }
        } message: { _ in
            Text("撤销之后这张码就不能再用来加入了，已经加入的人不受影响。")
        }
        .task { await reload() }
    }

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            Section {
                if invites.isEmpty {
                    Text("还没有生成过邀请码")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(invites) { v in
                        inviteRow(v)
                    }
                }
            } footer: {
                Text("团队邀请码以 fst_ 开头，和日历邀请码（fsi_）不通用。默认 7 天有效、不限使用次数。")
            }
        }
    }

    @ViewBuilder
    private func inviteRow(_ v: TeamInviteDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(v.code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(v.usable ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if v.role == "admin" {
                    Text("管理员")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.15))
                        .foregroundStyle(Theme.accent)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                Text(v.statusText)
                    .font(.caption2)
                    .foregroundStyle(v.usable ? Theme.textSecondary : Theme.textTertiary)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text(v.roleLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                if v.usable {
                    Button {
                        UIPasteboard.general.string = v.code
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("复制")
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if v.usable {
                Button(role: .destructive) {
                    confirmingRevoke = v
                } label: {
                    Label("撤销", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func reload() async {
        loading = true
        failure = nil
        do {
            invites = try await store.loadTeamInvites(teamID: teamID)
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func revoke(_ v: TeamInviteDTO) {
        confirmingRevoke = nil
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.revokeTeamInvite(id: v.id)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

/// 生成团队邀请码。
struct CreateTeamInviteSheet: View {

    let teamID: String
    let canCreateAdminInvite: Bool
    let onCreated: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var role = "member"
    /// 有效期（天）。0 = 不过期（服务端 ttl<=0 会改成 7 天，所以这里不提供 0）
    @State private var days = 7
    /// 0 = 不限次数
    @State private var maxUses = 0
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("身份", selection: $role) {
                        Text("成员").tag("member")
                        if canCreateAdminInvite {
                            Text("管理员").tag("admin")
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(canCreateAdminInvite
                         ? "管理员拿到码后能踢人、能再发邀请。只给信得过的人发。"
                         : "只有团队创建者能发「管理员」邀请。")
                }

                Section {
                    Stepper("有效期 \(days) 天", value: $days, in: 1...365)
                } footer: {
                    Text("过期后这张码就不能用了。已经在团队里的人不受影响。")
                }

                Section {
                    Toggle("不限使用次数", isOn: Binding(
                        get: { maxUses == 0 },
                        set: { maxUses = $0 ? 0 : 30 }
                    ))
                    if maxUses > 0 {
                        Stepper("最多 \(maxUses) 人", value: $maxUses, in: 1...500)
                    }
                } footer: {
                    Text("团队邀请默认不限次数（要给一个班的人）。团队人数上限 500，满了之后即使码还有次数也加不进来。")
                }

                if let msg = failure {
                    Section {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("生成邀请码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        create()
                    } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Text("生成")
                        }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func create() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                let invite = try await store.createTeamInvite(
                    teamID: teamID,
                    role: role,
                    ttlHours: Int64(days) * 24,
                    maxUses: Int64(maxUses)
                )
                // 生成完直接把码放进剪贴板 —— 这个码的唯一用途就是发出去
                UIPasteboard.general.string = invite.code
                onCreated()
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
