import SwiftUI

/// 清空我自己创建的数据（`POST /api/account/wipe`）。
///
/// ## 为什么这一页做得这么重
///
/// 这是整个 App 里**唯一不可逆**的操作。服务端是打墓碑（软删）——
/// 也就是说点完之后界面上不一定立刻「啪一下全没了」，
/// 有些端下一次同步才消失。这种「删了但还看得见」的体验极容易让人
/// **再点一次**，所以必须在动手之前就把「会发生什么」说清楚。
///
/// 三层确认，一层比一层实：
/// 1. 红色按钮本身带说明（不是光秃秃一个「删除」）
/// 2. 弹窗列出会删什么、不会删什么
/// 3. 最后要求**原样输入自己的账号名** —— 少一个空格都不行
///
/// 第三层看着繁琐，但它挡住的正是「我以为点的是取消」。
@MainActor
struct WipeDataView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var busy = false
    @State private var confirming = false
    @State private var error: String?
    @State private var result: WipeResultDTO?

    private var myName: String { store.user?.name ?? "" }

    /// 名字对上了才让点
    private var matches: Bool {
        !myName.isEmpty && typed == myName
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("会删掉", value: "我创建的日历和里面的日程")
                LabeledContent("也会删掉", value: "我在别人日历里的成员身份")
                LabeledContent("不会动", value: "别人的日历和别人的日程")
            } header: {
                Text("会发生什么")
            } footer: {
                Text("删除是立刻生效、不可撤销的。服务端不会保留副本，也没有「回收站」。\n\n删除后日历和日程会在**下一次同步时**从各端消失 —— 所以本机可能还会看到一会儿，别以为没删掉又点一次。")
            }

            Section {
                TextField("原样输入账号名：\(myName)", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))

                Button(role: .destructive) {
                    error = nil
                    confirming = true
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView() }
                        Text(busy ? "正在清空…" : "清空我创建的全部数据")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!matches || busy)
            } footer: {
                // 让「为什么按钮是灰的」有答案。
                // 只说 disabled 不说理由，用户会以为是 bug
                if matches {
                    Text("点下去还会再问一次。")
                } else if typed.isEmpty {
                    Text("上面那行必须一字不差地填上你的账号名，按钮才会亮 —— 这一步是为了防止手滑。")
                } else {
                    Text("和账号名对不上。注意大小写和空格，必须完全一致。")
                }
            }

            if let error = error {
                Section {
                    ErrorBanner(message: error)
                }
            }

            if let r = result {
                Section {
                    LabeledContent("日历", value: "\(r.calendars) 张")
                    LabeledContent("日程", value: "\(r.events) 条")
                    LabeledContent("成员身份", value: "\(r.memberships) 个")
                } header: {
                    Text("已清空")
                } footer: {
                    if let note = r.note {
                        Text(note)
                    }
                }
            }
        }
        .navigationTitle("清空我的数据")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确定要清空吗？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { run() }
        } message: {
            Text("会把「\(myName)」创建的 \(myOwnCount) 张日历和里面的全部日程删掉，不可撤销。别人的数据不受影响。")
        }
    }

    /// 我自己创建的日历张数，用来在弹窗里说一个**具体数字**。
    ///
    /// ⚠️ `ownerID` 是 Optional：列表接口在 `omitempty` 时不下发这个字段。
    ///    拿 nil 去做 `==` 比较不会崩，但要顺手排掉 —— 没有 owner 的日历
    ///    不是我的，算进「要删的」里会让弹窗说错话。
    private var myOwnCount: Int {
        guard let me = store.user?.id else { return 0 }
        return store.calendars.filter { $0.ownerID == me }.count
    }

    private func run() {
        guard !busy else { return }
        busy = true
        error = nil
        result = nil
        Task {
            do {
                result = try await store.wipeAccount(confirm: typed)
                // 清完就把输入框清空：留着的话「看起来还能再点一次」，
                // 而这时候再点已经没有任何东西可删，只会让人困惑
                typed = ""
            } catch {
                self.error = store.message(for: error)
            }
            busy = false
        }
    }
}
