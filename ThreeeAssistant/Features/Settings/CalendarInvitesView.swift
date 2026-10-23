import SwiftUI

/// 一张日历的邀请码管理。
///
/// ## 邀请码 vs 「直接加成员」
///
/// 两条路都能把人拉进一张日历，区别在于**谁发起**：
///
/// - **加成员**（`CalendarMembersView`）：我在名单里挑人，他立刻进。
///   适合「我们班的课表，我知道都有谁」。
/// - **邀请码**：发一个码出去，谁拿到谁自己进来。适合「人太多 / 不知道都有谁 /
///   对方还没注册」。
///
/// 邀请码更危险一点，所以服务端给它加了三道约束，这个页面必须如实反映：
///
/// 1. **角色上限 editor** —— 邀请不能授予 admin/owner。传更高的直接 400，
///    不静默降级（源码：「静默降级会让邀请人以为自己给的是 admin」）
/// 2. **默认只能用 1 次**，上限 100（注意和团队邀请相反：那边 0 是「不限」）
/// 3. **接受时角色取码里的值**，不接受请求里的值 —— 否则就是提权漏洞
struct CalendarInvitesView: View {

    let calendarID: String

    @Environment(SessionStore.self) private var store

    @State private var invites: [CalendarInviteDTO] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?

    @State private var showCreate = false
    @State private var confirmingRevoke: CalendarInviteDTO?

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
            CreateCalendarInviteSheet(calendarID: calendarID) {
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
            Text("撤销之后这张码就不能再用了。已经用它进来的人不受影响。")
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

            // 加入别人的日历：这里也给个入口，不然得先去「我的日历」里找
            Section {
                NavigationLink {
                    JoinCalendarSheet()
                } label: {
                    Label("用邀请码加入别人的日历", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("拿到别人给你的 fsi_ 开头的码，可以在这里加进去。")
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
            } header: {
                Text("已发出的邀请（\(invites.count)）")
            } footer: {
                Text("邀请码只能给出「可编辑」或「只读」。管理员权限必须通过成员名单逐个授予。")
            }
        }
    }

    @ViewBuilder
    private func inviteRow(_ v: CalendarInviteDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v.code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(v.usable ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(v.roleLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text(v.statusText)
                    .font(.caption2)
                    .foregroundStyle(v.usable ? Theme.textSecondary : Theme.textTertiary)
                Spacer(minLength: 0)
                if v.usable {
                    Text(expiryText(v))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
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

    /// 「7 天后过期」/「已过期」
    private func expiryText(_ v: CalendarInviteDTO) -> String {
        let now = Int64(Date.now.timeIntervalSince1970)
        let left = v.expiresAt - now
        if left <= 0 { return "已过期" }
        let days = left / 86400
        if days >= 1 { return "\(days) 天后过期" }
        let hours = max(1, left / 3600)
        return "\(hours) 小时后过期"
    }

    private func reload() async {
        loading = true
        failure = nil
        do {
            invites = try await store.loadCalendarInvites(calendarID: calendarID)
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func revoke(_ v: CalendarInviteDTO) {
        confirmingRevoke = nil
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                try await store.revokeCalendarInvite(id: v.id)
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 生成邀请码

struct CreateCalendarInviteSheet: View {

    let calendarID: String
    let onCreated: () -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var role = "viewer"
    @State private var days = 7
    /// ⚠️ 日历邀请的默认是 **1 次**，0 在服务端会被改成 1（不是「不限」）
    @State private var maxUses = 1
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("权限", selection: $role) {
                        Text("只读").tag("viewer")
                        Text("可编辑").tag("editor")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("邀请码不能授予管理员或创建者。想给管理员权限，请在成员名单里逐个设置。")
                }

                Section {
                    Stepper("有效期 \(days) 天", value: $days, in: 1...365)
                } footer: {
                    Text("过期后这张码就不能用了。已经用它进来的人不受影响。")
                }

                Section {
                    Stepper("最多 \(maxUses) 人使用", value: $maxUses, in: 1...100)
                } footer: {
                    Text("默认只能用 1 次（一次性邀请）。要发给一群人就调大，上限 100 —— 更大的场景用「共享给团队」。")
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
                let invite = try await store.createCalendarInvite(
                    calendarID: calendarID,
                    role: role,
                    ttlHours: Int64(days) * 24,
                    maxUses: Int64(maxUses)
                )
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

// MARK: - 用邀请码加入

/// 拿别人的 `fsi_` 码把自己加进一张日历。
///
/// 幂等：已经是成员就直接成功，不消耗次数。
/// 角色取码里存的值 —— 这里没有任何「选权限」的控件，那是设计如此。
struct JoinCalendarSheet: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("fsi_...", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("日历邀请码")
                } footer: {
                    Text("以 fsi_ 开头。团队邀请码是 fst_，那是加团队的，不能填在这里。")
                }

                if let msg = failure {
                    Section {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("加入日历")
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
                    .disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func join() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                _ = try await store.acceptCalendarInvite(code: code)
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
