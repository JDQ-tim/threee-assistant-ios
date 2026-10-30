import SwiftUI

// ============================================================
//  安全与证书
//  ------------------------------------------------------------
//  原来「忘记已信任的服务器证书」是一个单独按钮摆在设置页底部，
//  没有任何上下文 —— 大多数用户不知道它是什么、什么时候该用。
//
//  这里把它和「清空我创建的数据」放在一起，因为两者都是
//  **不可逆操作**，而且都属于安全范畴。分组让它们的危险性
//  一目了然，而不是散落在页面各处。
//
//  ⚠️ 清空数据不是"删除账号"，文案必须写清楚这件事 ——
//     原来的设计里这个区别只在小字 footer 里，很容易被误读成注销账号。
// ============================================================

@MainActor
struct SecurityView: View {

    @State private var confirmingForget = false
    /// TrustStore 没有暴露"有多少个"的接口，只给了 isEmpty。
    /// 这里就按有无来显示 —— 比为了一个数字去改 TrustStore 的 API 更划算。
    @State private var hasTrusted = false

    var body: some View {
        List {
            Section {
                LabeledContent("服务器证书", value: hasTrusted ? "已记录" : "未记录")
                Button("忘记已信任的证书") {
                    confirmingForget = true
                }
                .disabled(!hasTrusted)
            } header: {
                Text("服务器证书")
            } footer: {
                Text("App 会记住每个服务器的证书指纹，防止连到冒充的服务器。服务器换了证书（重装、换机器）之后连不上，就在这里忘记一次，下次连接会重新记录。")
            }

            Section {
                NavigationLink {
                    WipeDataView()
                } label: {
                    Text("清空我创建的数据")
                        .foregroundStyle(Theme.red600)
                }
            } header: {
                Text("数据")
            } footer: {
                Text("删掉你自己创建的日历、日程，以及你在别人日历里的成员身份。注意：账号本身不会被删除，别人的数据也不受影响。不可撤销。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("安全与证书")
        .navigationBarTitleDisplayMode(.inline)
        .alert("忘记已信任的证书？", isPresented: $confirmingForget) {
            Button("忘记", role: .destructive) {
                TrustStore.forgetAll()
                hasTrusted = !TrustStore.isEmpty
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次连接任意服务器时都会重新记录一次证书指纹。期间如果有服务器冒充，App 识别不出来。")
        }
        .task {
            hasTrusted = !TrustStore.isEmpty
        }
    }
}
