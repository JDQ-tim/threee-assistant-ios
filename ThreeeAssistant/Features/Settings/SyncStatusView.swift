import SwiftUI

/// 同步状态与手动操作。
///
/// ## 为什么需要一个页面而不是「后台自动就好」
///
/// 同步出问题时，用户唯一的线索通常只有「我改的东西不见了」。
/// 没有这个页面的话，能做的只有重装 / 重新登录 —— 那会把尚未推上去的
/// 本地改动一起丢掉。这里至少能回答三个问题：
///
/// 1. **我同步到哪了？** → 游标（`last_seq`）
/// 2. **服务端说库被修过吗？** → `maintenance` 信号，收到就该整份重拉
/// 3. **我上次推的东西有报错吗？** → `errors` 逐条显示
///
/// ## 为什么不给「强制覆盖服务端」的按钮
///
/// 服务端确实允许 `base_seqs` 为 nil 的无条件覆盖（那是给「冲突解决」用的
/// 权威写入）。但这个 App 里没有任何本地库，一旦覆盖就是把服务端
/// 别的设备的改动抹掉 —— 用户的原始数据，没有后悔药。
/// 想重拉有 `resetSyncCursor`，那只是**丢掉本地读游标**，不动服务端任何数据。
@MainActor
struct SyncStatusView: View {

    @Environment(SessionStore.self) private var store

    @State private var busy = false
    @State private var failure: String?
    @State private var lastMessage: String?
    @State private var lastOutcome: Report?

    /// 一次操作的摘要，只为了显示
    private struct Report {
        var kind: String
        var detail: String
        var errors: [String]
        var conflicts: Int
    }

    var body: some View {
        List {
            Section {
                LabeledContent("设备标识", value: store.deviceID)
                LabeledContent("同步游标", value: store.syncCursor > 0
                               ? String(store.syncCursor) : "（未同步）")
                LabeledContent("本地日程", value: "\(store.instances.count) 条")
                LabeledContent("本地日历", value: "\(store.calendars.count) 张")
            } footer: {
                Text("游标是上次同步到服务端的哪个位置。为 0 表示下次会整份重拉。设备标识只是为了让冲突提示能说清是「哪台设备」改的。")
            }

            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            if let r = lastOutcome {
                Section {
                    Text(r.kind)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if !r.detail.isEmpty {
                        Text(r.detail)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if r.conflicts > 0 {
                        Label("有 \(r.conflicts) 个字段和别人撞了，两边都留着，去「修改冲突」里选", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                        Text(e)
                            .font(.caption2)
                            .foregroundStyle(Theme.red600)
                    }
                } header: {
                    Text("上次操作结果")
                } footer: {
                    if !r.errors.isEmpty {
                        Text("这些错误是逐条的，不影响其它条目。像「含违规词」这类和权限无关 —— 服务端特意分开报，免得你一直去翻权限设置。")
                    }
                }
            }

            Section {
                Button {
                    Task { await pull() }
                } label: {
                    HStack {
                        Label("拉一次增量", systemImage: "arrow.down.circle")
                        Spacer(minLength: 0)
                        if busy { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(busy)

                Button {
                    Task { await fullReload() }
                } label: {
                    Label("清掉游标，下次整份重拉", systemImage: "arrow.clockwise.circle")
                }
                .disabled(busy)
            } footer: {
                Text("「整份重拉」只是丢掉本机的读取位置，不动服务端任何数据，也不丢你自己已经推上去的改动。适合「有的东西明明删了却还在」这种本地残渣。")
            }

            if let msg = lastMessage {
                Section {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("同步")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 动作

    private func pull() async {
        guard !busy else { return }
        busy = true
        failure = nil
        lastMessage = nil
        do {
            let out = try await store.pullChanges()
            var detail = "拿到 \(out.calendars.count) 张日历、\(out.events.count) 条日程"
            if out.hasMore { detail += "（还有更多，再来一次）" }
            if out.maintenance { detail += "。服务端做过整库修复，游标已作废，下次会整份重拉" }
            lastOutcome = Report(
                kind: out.isEmpty ? "没有新的改动" : "增量拉取完成",
                detail: detail,
                errors: [],
                conflicts: 0
            )
        } catch {
            failure = store.message(for: error)
        }
        busy = false
    }

    private func fullReload() async {
        guard !busy else { return }
        busy = true
        failure = nil
        lastMessage = nil
        store.resetSyncCursor()
        do {
            let out = try await store.pullChanges()
            lastMessage = "游标已清零并重拉一次：\(out.calendars.count) 张日历、\(out.events.count) 条日程。"
        } catch {
            failure = store.message(for: error)
        }
        busy = false
    }
}
