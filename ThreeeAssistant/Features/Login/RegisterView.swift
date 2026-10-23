import SwiftUI

/// 注册页。以 sheet 形式盖在登录页上。
///
/// ## 这一页为什么要先问服务端一句
///
/// 全新部署上「第一个账号」是**免邀请码、且自动成为管理员**的
/// （服务端 `handleRegister` 里 `isAdmin := n == 0`）。
/// 如果不管这件事，第一次装 App 的人会看到一个「请输入邀请码」的框 ——
/// 而他手上根本没有邀请码，部署就卡死在这一步。
///
/// 所以进页面先 `GET /api/bootstrap`：
/// - `need_admin == true` → 「创建管理员」，**不显示**邀请码框
/// - `need_admin == false` → 「注册」，显示邀请码框
///
/// ## 服务器地址为什么在注册页也能改
///
/// 因为从登录页过来的人，多数是**第一次用**，地址多半还没填对。
/// 让他退回去改地址再点一次注册，是最没必要的来回。
/// 但改了地址就得重新探测 —— 见 `onChange` 里的 `clearBootstrap()`。
@MainActor
struct RegisterView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pass = ""
    @State private var pass2 = ""
    @State private var invite = ""
    @State private var busy = false
    @State private var probing = false
    /// 本页自己的错误。**不用** `store.errorMessage` ——
    /// 那是登录页的提示位，注册失败的信息不该在登录页残留到下一个人看见
    @State private var localError: String?
    /// 探测失败的原因（和注册失败分开：这是「连不上」，不是「填错了」）
    @State private var probeError: String?

    @FocusState private var focused: Field?

    private enum Field { case server, name, pass, pass2, invite }

    /// 现在能不能确定「这是不是一台空服务器」
    private var knowNeedAdmin: Bool {
        store.bootstrapIsFresh && store.bootstrap != nil
    }

    private var needAdmin: Bool {
        store.bootstrap?.needAdmin ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    header

                    if let msg = localError {
                        ErrorBanner(message: msg).padding(.bottom, 14)
                    }

                    // 还没探到结果时**不渲染表单**：
                    // 否则用户会先看到「邀请码」框、一秒后又消失，
                    // 那种跳动比多等半秒难受得多
                    if let msg = probeError {
                        probeFailedBox(msg)
                    } else if !knowNeedAdmin {
                        probingBox
                    } else {
                        form
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(needAdmin ? "创建管理员" : "注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
            }
        }
        .task { await probe() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(needAdmin ? "这台服务器还是空的" : "加入这台服务器")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(needAdmin
                 ? "第一个注册的账号会自动成为管理员，不需要邀请码。"
                 : "需要部署者给的注册码，或者一张别人分享给你的日历邀请码。")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    // MARK: - 探测中 / 探测失败

    private var probingBox: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在确认服务器状态…")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    private func probeFailedBox(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ErrorBanner(message: msg)

            FieldBox(label: "服务器地址") {
                TextField("https://example.com:8443", text: $store.serverText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused, equals: .server)
                    .onSubmit { Task { await probe() } }
                    .onChange(of: store.serverText) { _, _ in
                        // 改了地址，上次的失败原因就作废了 —— 不然用户改对了
                        // 也还挂着一行红字，只能靠再点一次按钮才知道
                        probeError = nil
                        store.clearBootstrap()
                    }
            }

            Button {
                Task { await probe() }
            } label: {
                HStack(spacing: 8) {
                    if probing { ProgressView().tint(Theme.onAccent) }
                    Text(probing ? "正在连接…" : "重新连接")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .foregroundStyle(Theme.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .disabled(probing)
            .opacity(probing ? 0.6 : 1)

            Text("连不上时先用 Safari 打开「服务器地址/api/health」，看到一段 JSON 就说明证书和网络都通。")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {

            FieldBox(label: "服务器地址") {
                TextField("https://example.com:8443", text: $store.serverText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focused, equals: .server)
                    .onSubmit { focused = .name }
                    .onChange(of: store.serverText) { _, _ in
                        // ⚠️ 地址一改，`needAdmin` 就是**上一台**服务器的答案了。
                        //    不清掉的话，用户会按 A 服务器的状态去填 B 服务器的表 ——
                        //    比如 A 是空库所以没显示邀请码框，换成已部署的 B 就注册失败。
                        guard store.bootstrapServer != nil else { return }
                        store.clearBootstrap()
                        localError = nil
                        Task { await probe() }
                    }
            }

            FieldBox(label: "用户名") {
                TextField("英文或数字，用来登录", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focused, equals: .name)
                    .onSubmit { focused = .pass }
            }

            FieldBox(label: "密码") {
                SecureField("至少 4 位", text: $pass)
                    .submitLabel(.next)
                    .focused($focused, equals: .pass)
                    .onSubmit { focused = .invite }
            }

            FieldBox(label: "再输一遍密码") {
                SecureField("••••••", text: $pass2)
                    .submitLabel(needAdmin ? .go : .next)
                    .focused($focused, equals: .pass2)
                    .onSubmit {
                        if needAdmin { submit() } else { focused = .invite }
                    }
            }

            if !needAdmin {
                FieldBox(label: "邀请码") {
                    TextField("部署者给的注册码，或 fsi_ 开头的日历邀请码", text: $invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused, equals: .invite)
                        .onSubmit { submit() }
                }

                Text("两种码都行：全站注册码让这个账号能进来但看不到别人的日程；fsi_ 开头的日历邀请码会把你直接加进那张日历。")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -2)
                    .padding(.bottom, 14)
            }

            // 本地能判定的错就地提示，不要等发请求回来再说
            if let hint = localHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Theme.onAccent) }
                    Text(busy ? "正在创建…" : (needAdmin ? "创建管理员" : "注册"))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .foregroundStyle(Theme.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .padding(.top, 4)

            Text(needAdmin
                 ? "注册完直接进入 App。之后可以在「设置 → 安全管理 → 注册码」里给同学发码。"
                 : "注册完直接进入 App，不用再登一次。")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // MARK: - 判定

    /// 本地能判出来的问题。没有就是 nil
    private var localHint: String? {
        if !pass.isEmpty && pass.count < 4 {
            return "密码至少 4 位"
        }
        if !pass2.isEmpty && pass != pass2 {
            return "两次输入的密码不一样"
        }
        if !needAdmin && !invite.isEmpty {
            let t = invite.trimmingCharacters(in: .whitespacesAndNewlines)
            // 只做**格式**上的提醒，不判有效性 —— 有效性只有服务端知道。
            // 这里给个下限，是为了拦住「就填了一个字母」这种明显的手滑
            if t.count < 6 {
                return "邀请码看起来不太对，确认一下是不是复制全了"
            }
        }
        return nil
    }

    private var canSubmit: Bool {
        guard !busy, !probing else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard pass.count >= 4, pass == pass2 else { return false }
        if !needAdmin && invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    // MARK: - 动作

    private func probe() async {
        guard !probing else { return }
        probing = true
        probeError = nil
        localError = nil
        do {
            _ = try await store.checkBootstrap(server: store.serverText)
        } catch {
            probeError = store.message(for: error)
        }
        probing = false
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        localError = nil
        busy = true

        let t = invite.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                // 只有一张「邀请码」输入框，但服务端认两种码。
                // 按前缀分流：`fsi_` 是日历邀请码，别的按全站注册码处理。
                // （服务端两处都做了兼容，这里分流只是让日志和报错更准）
                let isCalendar = t.hasPrefix("fsi_")
                _ = try await store.register(
                    server: store.serverText,
                    name: name,
                    pass: pass,
                    inviteCode: isCalendar ? "" : t,
                    calendarInvite: isCalendar ? t : ""
                )
                // 注册成功 = 已经进入登录态，`RootView` 会自己切到主界面，
                // 这个 sheet 跟着一起消失。不用手动 dismiss
                busy = false
            } catch {
                localError = store.message(for: error)
                busy = false
            }
        }
    }
}
