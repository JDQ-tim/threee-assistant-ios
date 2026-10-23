import SwiftUI

struct SettingsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingForget = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    LabeledContent("用户名", value: store.user?.name ?? "—")
                    LabeledContent("身份", value: (store.user?.isAdmin ?? false) ? "管理员" : "普通成员")
                }

                Section("连接") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("服务器")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(store.serverText.isEmpty ? "—" : store.serverText)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }

                Section("数据") {
                    NavigationLink("我的日历（\(store.calendars.count)）") {
                        CalendarsView()
                    }
                    Button("重新同步") {
                        Task { await store.refresh() }
                    }
                }

                Section {
                    Button("忘记已信任的服务器证书") {
                        confirmingForget = true
                    }
                    Text("用于服务器换了证书、连不上时。忘记之后下次连接会重新记录一次。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } header: {
                    Text("安全")
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.1 (1)")
                    Text("原生 iOS 版。日程支持新建、修改、重复、提醒、待办，以及周/月视图；日历支持新建、改名改色、删除。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                Section {
                    Button(role: .destructive) {
                        busy = true
                        Task {
                            await store.logout()
                            busy = false
                            dismiss()
                        }
                    } label: {
                        Text(busy ? "正在退出…" : "退出登录")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("忘记已信任的证书？", isPresented: $confirmingForget) {
                Button("忘记", role: .destructive) { TrustStore.forgetAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("下次连接任意服务器时都会重新记录一次证书指纹。")
            }
        }
    }
}
