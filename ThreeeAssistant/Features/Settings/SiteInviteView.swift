import SwiftUI

/// 读全站注册码（`GET /api/invite`，管理员专用）。
///
/// ## 为什么单独做一页
///
/// 注册码是「部署完想把这台服务器发给同学」的人**唯一需要的东西**。
/// 但它是服务端启动时生成的，客户端平时拿不到 ——
/// 源码注释里写得很直白：没有这个接口的话，
/// 唯一能知道注册码的办法是去读服务器日志。
///
/// 让一个刚把服务部署起来的人 SSH 上去翻日志，是这件小事里最难的一步。
///
/// ## 这一页的设计取向
///
/// 只干一件事，所以做得很「大」：码是一屏上最大的东西，
/// 一眼能看清、能选中、能复制。附近的说明都在解释**同一句话**——
/// 这个码给别人，别人就能注册进来，所以别乱发。
///
/// 没有「重新生成」按钮：服务端没有换码的接口，
/// 放个假按钮比不放更糟（点了没反应 = 用户以为坏了）。
@MainActor
struct SiteInviteView: View {

    @Environment(SessionStore.self) private var store

    @State private var code: String?
    @State private var loading = false
    @State private var error: String?
    /// 复制后的短暂提示。1.5 秒后自己变回去 ——
    /// 常驻的「已复制」会让人不确定刚才那下到底有没有生效
    @State private var copied = false
    /// 把码发出去前的再次确认弹窗
    @State private var confirmingShare = false

    private var isAdmin: Bool { store.user?.isAdmin ?? false }

    var body: some View {
        Form {
            if !isAdmin {
                // 理论上进不来（入口只对管理员显示），但直接从别的页面
                // 跳到这一页、或者管理员中途掉了权限，都会走到这里。
                // 与其让他对着一个永远转圈的加载器，不如直接说清楚
                Section {
                    ContentUnavailableView(
                        "只有管理员能看注册码",
                        systemImage: "lock",
                        description: Text("注册码决定谁能加入这台服务器，所以只有管理员能读。")
                    )
                }
            } else {
                codeSection
                warningSection
                if let error = error {
                    Section {
                        ErrorBanner(message: error)
                    }
                }
            }
        }
        .navigationTitle("注册码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Text("刷新")
                    }
                }
                .disabled(loading || !isAdmin)
            }
        }
        .task {
            // 已经拿到就不再打一次。切回这一页时不该再走一遍网络 ——
            // 注册码在一台服务器上是固定的，重拉没有收益
            if code == nil { await load() }
        }
        .alert("要把注册码发出去？", isPresented: $confirmingShare) {
            Button("取消", role: .cancel) {}
            Button("复制") { copy() }
        } message: {
            Text("拿到这个码的人可以注册成这台服务器的普通成员，能看到别人分享给他的日历。只发给你信任的人。")
        }
    }

    // MARK: - 码

    /// ⚠️ 这里必须用 `Group` 而不是直接摊在 `Form` 里：
    ///    `Section` 里既要放「加载中 / 错误 / 码」三种互斥状态，
    ///    又要保证 `Form` 只看到一个 `Section`。用 `Group` 包一层最省心。
    @ViewBuilder
    private var codeSection: some View {
        Section {
            if let code = code {
                VStack(alignment: .leading, spacing: 10) {
                    Text(code)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        // 大字号 + 等宽下长码会换行。宁可换行也不要
                        // truncationMode 把它截成「fsi_abc…」——
                        // 截断的码是没法用的，而用户会以为那就是全部
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button {
                            confirmingShare = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "已复制" : "复制注册码")
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 0)

                        Text("\(code.count) 位")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.vertical, 4)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                // 加载失败且没有旧码时才会到这里
                Button {
                    Task { await load() }
                } label: {
                    Text("点这里重试")
                }
            }
        } header: {
            Text("全站注册码")
        } footer: {
            Text("在注册页填这个码就能加入服务器。它是这台服务器共用的，不是一人一码。")
        }
    }

    // MARK: - 提醒

    private var warningSection: some View {
        Section {
            Label {
                Text("码泄露了怎么办")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.red600)
            }
            Text("注册码没法在 App 里重置，它是服务端启动参数决定的。真泄露了，要么在服务器上换启动参数重开，要么把不该在的人从成员里踢掉 —— 换码之前发出的码会全部作废。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        } header: {
            Text("注意")
        } footer: {
            Text("管理员自己注册用的是另一套码（以 fsi_ 开头），和你在这里看到的不是同一个。")
        }
    }

    // MARK: - 动作

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            code = try await store.loadSiteInvite()
        } catch {
            self.error = store.message(for: error)
        }
        loading = false
    }

    private func copy() {
        guard let code = code else { return }
        UIPasteboard.general.string = code
        copied = true
        // 1.5 秒后复位。用 Task.sleep 而不是 Timer：
        // 页面被 pop 掉之后 Timer 还在跑，会去改一个已经不存在的视图状态
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
