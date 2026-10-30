import SwiftUI

/// 改密码。
///
/// ## 为什么这个页面值得单独做
///
/// 改密码是**账号被夺走之后唯一能自救的按钮**。之前「我的」页只有「退出登录」，
/// 用户发现密码泄露时在 App 里什么都做不了 —— 只能去网页端，或者干脆删了 App
/// 以为已经安全了（实际上别处的会话还活着）。
///
/// ## 三个输入框都是密码
///
/// - 旧密码：服务端强制要求（`handleChangePassword` 里先 verifyPassword）。
///   没有它就等于"临时拿到手机的人可以直接换掉密码锁死你"。
/// - 新密码 / 再输一遍：第二次输入只用来挡手滑，不发给服务端。
///
/// ## 改完之后
///
/// 服务端会作废**除当前设备外**的所有会话。这里把被踢的数量如实说出来：
/// 「其它 2 台设备的登录已失效」比「修改成功」有信息量得多 ——
/// 用户正是在确认"那个不该登录的人是不是已经掉了"。
@MainActor
struct ChangePasswordView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var oldPass = ""
    @State private var newPass = ""
    @State private var confirmPass = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var doneMessage: String?

    private var canSubmit: Bool {
        !busy
            && !oldPass.isEmpty
            && newPass.count >= 4
            && newPass == confirmPass
            && newPass != oldPass
    }

    /// 本地先挡一遍，说清楚哪里不对。
    ///
    /// 服务端也会验（409/400 带中文原因），但这些判断在本地做能省一次往返，
    /// 而且**错误提示能贴着输入框**，比顶部弹一条更清楚。
    /// 服务端的校验照样保留 —— 客户端校验永远只是体验优化，不是安全边界。
    private var localHint: String? {
        if !oldPass.isEmpty && !newPass.isEmpty && newPass == oldPass {
            return "新密码不能和旧密码一样"
        }
        if !newPass.isEmpty && newPass.count < 4 {
            return "新密码至少 4 位"
        }
        if !confirmPass.isEmpty && newPass != confirmPass {
            return "两次输入的新密码不一致"
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                SecureField("当前密码", text: $oldPass)
                    .textContentType(.password)
            } header: {
                Text("当前密码")
            } footer: {
                Text("确认是你本人在改。服务端会核对这一项。")
            }

            Section {
                SecureField("新密码（至少 4 位）", text: $newPass)
                    .textContentType(.newPassword)
                SecureField("再输一遍", text: $confirmPass)
                    .textContentType(.newPassword)
            } header: {
                Text("新密码")
            } footer: {
                if let hint = localHint {
                    Text(hint).foregroundStyle(.red)
                } else {
                    Text("改完之后，其它设备上的登录会自动失效，这台设备不受影响。")
                }
            }

            if let msg = failure {
                Section {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let ok = doneMessage {
                Section {
                    Label(ok, systemImage: "checkmark.shield")
                        .font(.footnote)
                        .foregroundStyle(Theme.teal600)
                }
            }
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    submit()
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Text("修改")
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        failure = nil
        doneMessage = nil

        Task {
            do {
                let kicked = try await store.changePassword(oldPass: oldPass, newPass: newPass)
                if kicked > 0 {
                    doneMessage = "密码已修改。其它 \(kicked) 台设备的登录已失效。"
                } else {
                    doneMessage = "密码已修改。当时没有其它设备登录。"
                }
                // 清空输入，避免密码明文留在内存里的时间比必要更长
                oldPass = ""
                newPass = ""
                confirmPass = ""
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
