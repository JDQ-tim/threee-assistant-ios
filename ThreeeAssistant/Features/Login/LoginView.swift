import SwiftUI

@MainActor
struct LoginView: View {

    @Environment(SessionStore.self) private var store

    @State private var name = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var showRegister = false

    /// 连通性自检的状态
    @State private var checking = false
    @State private var healthText: String?
    @State private var healthOK = false

    @FocusState private var focused: Field?

    private enum Field { case server, name, pass }

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // 图标用自绘的方块，和 App Icon 一致
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 68, height: 68)
                    .overlay(
                        Text("3e")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    )
                    .padding(.top, 60)

                Text("3e 学习助手")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 18)

                Text("连你自己的服务器")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
                    .padding(.bottom, 26)

                if let msg = store.errorMessage {
                    ErrorBanner(message: msg)
                        .padding(.bottom, 14)
                }

                FieldBox(label: "服务器地址") {
                    TextField("https://example.com:8443", text: $store.serverText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .server)
                        .onSubmit { focused = .name }
                }

                FieldBox(label: "用户名") {
                    TextField("和手机端同一个账号", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .name)
                        .onSubmit { focused = .pass }
                }

                FieldBox(label: "密码") {
                    SecureField("••••••", text: $pass)
                        .submitLabel(.go)
                        .focused($focused, equals: .pass)
                        .onSubmit { submit() }
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Theme.onAccent) }
                        Text(busy ? "正在连接…" : "登录")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
                .disabled(busy)
                .opacity(busy ? 0.6 : 1)
                .padding(.top, 10)

                // 注册入口。做成文字链而不是第二个同色按钮：
                // 主操作只有一个，两个等重的按钮会让人犹豫点哪个
                Button {
                    store.errorMessage = nil
                    showRegister = true
                } label: {
                    Text("还没有账号？注册")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .disabled(busy)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("连不上时先做这一步")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("点下面的「测试连接」，通不通当场就知道。也可以手动用 Safari 打开「服务器地址/api/health」，看到一段 JSON 就说明证书和网络都是通的。\n\n自签证书第一次会提示「此连接非私人连接」，点「显示详细信息 → 访问此网站」。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Task { await runHealthCheck() }
                    } label: {
                        HStack(spacing: 6) {
                            if checking { ProgressView().controlSize(.small) }
                            Text(checking ? "正在测试…" : "测试连接")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surfaceAlt)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                                .stroke(Theme.separator, lineWidth: 0.5)
                        )
                    }
                    .disabled(checking || busy)
                    .padding(.top, 6)

                    if let result = healthText {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(healthOK ? Theme.teal600 : Theme.red600)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showRegister) {
            RegisterView()
        }
    }

    // MARK: - 连通性自检

    private func runHealthCheck() async {
        guard !checking else { return }
        checking = true
        healthText = nil
        do {
            let h = try await store.checkHealth(server: store.serverText)
            healthOK = h.ok
            // 把「时钟差」也算出来：时间不对会让日程时间全错，
            // 而且这种错很难联想到时钟。这里顺手查一遍
            var parts = ["连上了"]
            if let v = h.version, !v.isEmpty { parts.append("版本 \(v)") }
            if let t = h.time {
                let drift = t - Int64(Date.now.timeIntervalSince1970)
                if abs(drift) > 300 {
                    // 5 分钟以上才算问题。手机和服务器本来就允许小误差，
                    // 报一个「差 3 秒」只会制造焦虑
                    parts.append("⚠️ 设备时钟和服务器差 \(abs(drift) / 60) 分钟，日程时间会显示错")
                }
            }
            if h.pendingUpdate == true {
                parts.append("服务端有待生效的更新")
            }
            healthText = parts.joined(separator: " · ")
        } catch {
            healthOK = false
            healthText = store.message(for: error)
        }
        checking = false
    }
    private func submit() {
        guard !busy else { return }
        focused = nil
        busy = true
        Task {
            await store.login(server: store.serverText, name: name, pass: pass)
            busy = false
        }
    }
}

/// 带标签的输入框容器。抽出来是为了三个框的间距/圆角只有一处定义
///
/// ⚠️ 不加 `private`：注册页（`RegisterView`）也要用。
///    两页的输入框必须长得一模一样 —— 用户在登录和注册之间切来切去时，
///    如果框的圆角、内边距、标签色差一点，会被读成「这是两个不同的东西」。
///
/// ⚠️ `@MainActor` 在这里不是形式主义：`Content` 是调用方给的视图，
///    而调用方（LoginView / RegisterView）都是 @MainActor 的 View。
///    在 Xcode 15.4 + iOS 17.5 SDK 下，View 的 body 是非隔离上下文，
///    这个容器如果不进主线程域，它包着的 `TextField` 绑定的 `@State` 会被报隔离冲突。
@MainActor
struct FieldBox<Content: View>: View {

    let label: String
    let content: Content

    // 显式写 init 而不是靠自动合成的 memberwise：
    // @ViewBuilder 加在存储属性上虽然也能合成，但那是编译器版本相关的行为，
    // 写清楚一次就不用赌
    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 2)

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
        }
        .padding(.bottom, 12)
    }
}
