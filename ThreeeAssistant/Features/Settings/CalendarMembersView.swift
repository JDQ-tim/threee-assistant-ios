import SwiftUI

/// 管理某张日历的成员。
///
/// ## 三件事要分清
///
/// 1. **加人 / 减人** —— 成员名单
/// 2. **改角色** —— editor / admin
/// 3. **「共享」开关** —— 只是控制「以后还能不能加人」，
///    **不等于**收回权限。关掉之后，已经分享出去的人照样看得到这张日历。
///
/// 第 3 点是源码 `acl.go:631` 特意写明的，也是这个页面上最容易被误解的地方，
/// 所以文案必须直说，不能写成「关闭共享 = 取消分享」。
@MainActor
struct CalendarMembersView: View {

    /// 要管理的日历
    let calendarID: String

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var members: [MemberDTO] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var busy = false

    @State private var showPicker = false
    @State private var confirmingRemove: MemberDTO?
    @State private var confirmingLeave = false

    /// 每次都从 store 现取：`refresh()` 之后 `calendars` 会整体替换，
    /// 拿一份拷贝存进 @State 会显示成旧数据
    private var calendar: CalendarDTO? {
        store.calendarsByID[calendarID]
    }

    private var canManage: Bool {
        let role = calendar?.role ?? ""
        // 服务端 canManageMembers 认 owner 和 admin
        return role == "owner" || role == "admin"
    }

    /// 我是不是创建者。只有创建者能「改共享开关 / 转让」这类动作，
    /// admin 只能管成员
    private var isOwner: Bool { (calendar?.role ?? "") == "owner" }

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
        .navigationTitle("成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .disabled(busy)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            AddMemberSheet(calendarID: calendarID, existing: members.map { $0.userID })
        }
        .alert("移出这个成员？", isPresented: Binding(
            get: { confirmingRemove != nil },
            set: { if !$0 { confirmingRemove = nil } }
        ), presenting: confirmingRemove) { m in
            Button("移出", role: .destructive) {
                remove(m)
            }
            Button("取消", role: .cancel) { confirmingRemove = nil }
        } message: { m in
            Text("「\(m.name)」将看不到这张日历上的日程。他自己创建的日程不受影响。")
        }
        .alert("退出这张日历？", isPresented: $confirmingLeave) {
            Button("退出", role: .destructive) { leave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后这张日历和里面的日程会从你的列表里消失。想再看到，需要创建者重新加你。")
        }
        .task { await reload() }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if canManage, let cal = calendar {
                Section {
                    Toggle(isOn: Binding(
                        get: { cal.kind == "shared" },
                        set: { on in setShared(on) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许添加成员")
                                .font(.system(size: 15))
                            Text("关掉只是不让再加人，已经加进来的人仍然看得到")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .tint(Theme.accent)
                    .disabled(busy || !isOwner)
                } footer: {
                    if !isOwner {
                        Text("只有创建者能改这个开关。")
                    }
                }
            }

            Section {
                ForEach(members) { m in
                    memberRow(m)
                }
            } header: {
                Text("\(members.count) 位成员")
            } footer: {
                if canManage {
                    Text("管理员可以继续加人和改权限；可编辑只能改日程。")
                }
            }

            // 团队共享：一个个加人太累，一个班三十人加不完。
            // 共享给团队一次，新同学拿团队邀请码自己进来。
            if canManage {
                Section {
                    NavigationLink {
                        CalendarTeamSharesView(calendarID: calendarID)
                    } label: {
                        Label("共享给团队", systemImage: "person.3")
                    }
                    NavigationLink {
                        CalendarInvitesView(calendarID: calendarID)
                    } label: {
                        Label("邀请码", systemImage: "ticket")
                    }
                } footer: {
                    Text("共享给团队：团队里所有人都能看到这张日历，新成员用团队码加入就自动可见。邀请码：发一张码给某个人，他自己加进来。")
                }
            }

            // 不是 owner 才给「退出」：owner 退出会把日历变成孤儿
            if !isOwner, calendar != nil {
                Section {
                    Button(role: .destructive) {
                        confirmingLeave = true
                    } label: {
                        Text("退出这张日历")
                    }
                    .disabled(busy)
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: MemberDTO) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                Text(m.roleLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)

            if canManage && m.canChangeRole {
                // 用菜单而不是滑动：改角色是「选一个值」，
                // 滑动只能放固定几个按钮，角色多一个就装不下了
                Menu {
                    ForEach([("editor", "可编辑"), ("admin", "管理员")], id: \.0) { pair in
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
            if canManage && m.canChangeRole {
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
            // 成员信息在日历详情里，列表接口可能不下发 members，
            // 所以这里先刷新整份日历再取
            await store.refresh()
            if let c = store.calendarsByID[calendarID] {
                members = (c.members ?? []).sorted { a, b in
                    // 创建者排最前，其余按名字
                    if a.role == "owner" { return true }
                    if b.role == "owner" { return false }
                    return a.name < b.name
                }
            } else {
                // 刷新后找不到这张日历 —— 极可能是被移除了
                failure = "这张日历已不在你的列表里（可能已被移出）。"
            }
        }
        loading = false
    }

    private func setShared(_ on: Bool) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.setShared(calendarID: calendarID, shared: on)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    private func changeRole(_ m: MemberDTO, to role: String) {
        guard !busy, role != m.role else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.setPermissions(calendarID: calendarID, userID: m.userID, role: role)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    private func remove(_ m: MemberDTO) {
        confirmingRemove = nil
        busy = true
        failure = nil
        Task {
            do {
                try await store.removeMember(calendarID: calendarID, userID: m.userID)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    private func leave() {
        busy = true
        failure = nil
        Task {
            do {
                try await store.leaveCalendar(id: calendarID)
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 加成员

/// 从用户名单里挑人加进来。
///
/// ⚠️ **必须点选，不能手打名字**。加成员接口认的是 `user_id`，
/// 传用户名服务端回 404「没有这个账号」，而用户明明输入的是正确的名字。
@MainActor
struct AddMemberSheet: View {

    let calendarID: String
    /// 已在成员里的 user_id，用来标灰避免重复添加
    let existing: [String]

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var users: [DirectoryUser] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var addingID: String?
    @State private var keyword = ""
    @State private var role = "editor"

    private var filtered: [DirectoryUser] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return users }
        return users.filter { $0.name.localizedCaseInsensitiveContains(kw) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取成员名单…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("添加成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var list: some View {
        List {
            Section {
                Picker("权限", selection: $role) {
                    Text("可编辑").tag("editor")
                    Text("管理员").tag("admin")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("可编辑只能改日程；管理员还能管成员。创建者身份不能通过这里转让。")
            }

            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            Section {
                ForEach(filtered) { u in
                    let already = existing.contains(u.id)
                    Button {
                        add(u)
                    } label: {
                        HStack {
                            Text(u.name)
                                .foregroundStyle(already ? Theme.textTertiary : Theme.textPrimary)
                            Spacer(minLength: 0)
                            if addingID == u.id {
                                ProgressView().scaleEffect(0.7)
                            } else if already {
                                Text("已在名单")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(already || addingID != nil)
                }
            } header: {
                Text("选一个人")
            }
        }
        .searchable(text: $keyword, prompt: "搜索用户名")
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            users = try await store.loadDirectory()
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func add(_ u: DirectoryUser) {
        guard addingID == nil else { return }
        addingID = u.id
        failure = nil
        Task {
            do {
                try await store.addMember(calendarID: calendarID, userID: u.id, role: role)
            } catch {
                failure = store.message(for: error)
            }
            addingID = nil
        }
    }
}
