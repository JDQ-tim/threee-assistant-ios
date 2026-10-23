import SwiftUI

@MainActor
struct LoginView: View {

    @Environment(SessionStore.self) private var store

    @State private var name = ""
    @State private var pass = ""
    @State private var busy = false
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("连不上时先做这一步")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("用 Safari 打开「服务器地址/api/health」，看到一段 JSON 就说明证书和网络都是通的。自签证书第一次会提示「此连接非私人连接」，点「显示详细信息 → 访问此网站」，回来再登录。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
private struct FieldBox<Content: View>: View {

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
