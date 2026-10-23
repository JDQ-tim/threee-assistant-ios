import SwiftUI

/// 我的团队。
///
/// ## 这个列表为什么«一定»只有我自己的团队
///
/// 服务端 `GET /api/teams` 的 SQL 里写死了 `team_members.user_id = 我`
/// （源码 `teams.go:211`，旁边还有一行注释说这是安全边界而不是过滤器便利）。
/// 用户原话：「注意,仅显示自己已添加的团队,而不是全服的团队」。
///
/// 所以客户端这里**不做任何额外过滤**。做了反而有害：
/// 万一哪天服务端漏了这个 WHERE，客户端过滤会把问题藏起来，
/// 变成「界面上看不出来，但数据已经发出去了」。
@MainActor
struct TeamListView: View {

    @Environment(SessionStore.self) private var store

    @State private var teams: [TeamDTO] = []
    @State private var loading = true
    @State private var failure: String?

    @State private var showCreate = false
    @State private var showJoin = false

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
        .navigationTitle("我的团队")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCreate = true
                    } label: {
                        Label("建一个团队", systemImage: "plus.circle")
                    }
                    Button {
                        showJoin = true
                    } label: {
                        Label("用邀请码加入", systemImage: "ticket")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateTeamSheet {
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showJoin) {
            // 加入成功后只刷新列表。这里不做「自动跳进刚加入的团队」——
            // 那需要额外的一个 navigationDestination(item:)，而 @State 值类型
            // 在 sheet 关闭动画期间改导航栈会跳一下再回来，反而更乱。
            // 列表刷新后新团队就在第一行（服务端按 created_at DESC 排）。
            JoinTeamSheet {
                Task { await reload() }
            }
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
                if teams.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有加入任何团队")
                            .foregroundStyle(Theme.textSecondary)
                        Text("团队是用来「一次把日历分享给一群人」的。建一个团队，把邀请码发给同学，他们自己进来就能看到你共享的日历。")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(teams) { t in
                        NavigationLink {
                            TeamDetailView(teamID: t.id)
                        } label: {
                            teamRow(t)
                        }
                    }
                }
            } header: {
                Text("\(teams.count) 个团队")
            } footer: {
                Text("这里只显示你已经加入的团队。别人建的团队只有拿到邀请码才能看到。")
            }
        }
    }

    @ViewBuilder
    private func teamRow(_ t: TeamDTO) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Text("\(t.memberCount ?? 0) 人")
                    Text("·")
                    Text("\(t.calendarCount ?? 0) 张日历")
                    if t.isAdmin {
                        Text("·")
                        Text("你是管理员")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)

                if let note = t.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func reload() async {
        loading = true
        failure = nil
        do {
            teams = try await store.loadTeams()
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }
}

// MARK: - 建团队

@MainActor
struct CreateTeamSheet: View {

    let onCreated: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var note = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("团队名", text: $name)
                    TextField("一句话说明（可选）", text: $note)
                } footer: {
                    Text("建完之后你是这支团队的管理员。团队名最多 40 个字。")
                }

                if let msg = failure {
                    Section {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("建一个团队")
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
                            Text("创建")
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                _ = try await store.createTeam(name: name, note: note)
                onCreated()
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 用邀请码加入

/// 加入团队。
///
/// 直接填码加入（不先 peek）：peek 那个端点是为了**没登录的人**看落地页用的。
/// 已经登录的人多一次往返只是多一次失败机会。
///
/// 幂等：已经是成员时服务端返回 `already_member` 且成功、**不消耗次数**，
/// 所以重复点是安全的。
///
/// ## 为什么要先看一眼
///
/// 加入团队的后果比加入日历更重：团队里共享给团队的日历，**加入的瞬间全部对我可见**，
/// 而且管理员可能还能改我的角色。用户在不认识这个团队名的情况下点「加入」，
/// 是一次没有知情同意的授权。
///
/// `GET /api/team-invites/{code}` 是匿名端点，只回团队名 / 邀请人 / 角色，够用了。
@MainActor
struct JoinTeamSheet: View {

    /// 加入成功后回调（不传 team_id：调用方只需要刷新列表）
    let onJoined: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?

    /// 「看一眼」的结果，输入一变就作废
    @State private var preview: TeamInvitePeekDTO?
    @State private var previewing = false

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("fst_...", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: code) { _, _ in
                            preview = nil
                            failure = nil
                        }
                } header: {
                    Text("团队邀请码")
                } footer: {
                    Text("把管理员给你的邀请码粘进来。团队邀请码以 fst_ 开头（日历邀请码是 fsi_，两者不通用）。")
                }

                previewSection

                if let msg = failure {
                    Section {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("加入团队")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        join()
                    } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Text("加入")
                        }
                    }
                    .disabled(busy || !(preview?.valid ?? false))
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if previewing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在确认这张邀请码…").foregroundStyle(.secondary)
                }
            } else if let p = preview {
                if p.valid {
                    LabeledContent("团队", value: p.teamName)
                    LabeledContent("邀请人", value: p.inviterName)
                    LabeledContent("你的角色", value: p.role == "admin" ? "管理员" : "成员")
                } else {
                    Text(p.reasonText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    peek()
                } label: {
                    Text("先确认一下")
                }
                .disabled(trimmedCode.isEmpty || previewing)
            }
        } header: {
            Text("确认")
        } footer: {
            if preview?.valid == true {
                Text(preview?.role == "admin"
                     ? "管理员：能添加移除成员、改成员角色、生成邀请码。"
                     : "成员：能看团队共享的日历，不能管成员。")
            }
        }
    }

    private func peek() {
        guard !previewing else { return }
        previewing = true
        failure = nil
        Task {
            do {
                preview = try await store.peekTeamInvite(code: trimmedCode)
            } catch {
                failure = store.message(for: error)
                preview = nil
            }
            previewing = false
        }
    }

    private func join() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                _ = try await store.acceptTeamInvite(code: code)
                onJoined()
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
