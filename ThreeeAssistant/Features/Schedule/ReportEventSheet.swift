import SwiftUI

/// 举报一条日程。
///
/// ## 为什么这个功能必须进包（不是"锦上添花"）
///
/// 上架审核会检查「用户产生的内容有没有举报入口」。
/// 没有举报入口的 UGC App 在 App Store 过不了，在国内渠道更是必须。
///
/// ## 流程
///
/// 进页面先 `GET /api/moderation/meta` 拿原因清单 —— **不从客户端写死**。
/// 服务端以后加一条「诈骗」，App 不用更新就能选到。
///
/// ⚠️ 服务端会重新读一遍这条日程并做权限校验。所以
///    「我举报了但对方刚好删了」会得到 404 而不是成功，
///    这是对的，照实把那句话显示出来即可。
@MainActor
struct ReportEventSheet: View {

    let eventID: String
    let calendarID: String?
    /// 用来在页面上说清「你在举报哪一条」，免得用户点错
    let eventTitle: String

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var reasons: [String: String] = [:]
    @State private var reason = ""
    @State private var detail = ""
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var done: ReportCreatedDTO?

    /// 原因按中文名排序，而不是按 JSON 字典的随机顺序 ——
    /// 同样的数据每次打开顺序都不同，会让人以为选项变了
    private var orderedReasons: [(key: String, label: String)] {
        reasons.map { (key: $0.key, label: $0.value) }
            .sorted { $0.label < $1.label }
    }

    private var canSubmit: Bool {
        guard !busy, !loading else { return false }
        guard !reason.isEmpty || !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return detail.count <= 2000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(eventTitle.isEmpty ? "（无标题的日程）" : eventTitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                } header: {
                    Text("正在举报")
                }

                if let done = done {
                    doneSection(done)
                } else {
                    formSection
                    if let error = error {
                        Section { ErrorBanner(message: error) }
                    }
                }
            }
            .navigationTitle("举报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                if done == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(busy ? "提交中…" : "提交") { submit() }
                            .disabled(!canSubmit)
                    }
                }
            }
            .task { await loadReasons() }
        }
    }

    // MARK: - 表单

    private var formSection: some View {
        Group {
            Section {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在获取举报原因…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if orderedReasons.isEmpty {
                    // 拿不到原因清单时不能只剩一个空白区 ——
                    // 用户会以为页面坏了。说明情况，并把「写说明」
                    // 这条唯一的出路留给下面的文本框
                    Text("没能拿到举报原因清单，可以直接在下面写清楚问题。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(orderedReasons, id: \.key) { item in
                        Button {
                            // 再点一次取消选择 —— 用户可能只是想写说明
                            reason = (reason == item.key) ? "" : item.key
                        } label: {
                            HStack {
                                Text(item.label)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                                if reason == item.key {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("原因")
            } footer: {
                Text("选一个最接近的。选错了也不影响处理，管理员会看内容本身。")
            }

            Section {
                TextField("补充说明（选填）", text: $detail, axis: .vertical)
                    .lineLimit(4...10)
            } footer: {
                if detail.count > 2000 {
                    Text("太长了，最多 2000 字（现在 \(detail.count) 字）。")
                        .foregroundStyle(Theme.red600)
                } else {
                    Text("说明里不要写自己的个人信息。你的账号名不会对被举报人显示。")
                }
            }
        }
    }

    private func doneSection(_ r: ReportCreatedDTO) -> some View {
        Section {
            Text(r.updated == true
                 ? "你之前对这条内容的举报还没处理，这次已经更新了它。"
                 : "已经提交，管理员会尽快看。")
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Button("知道了") { dismiss() }
                .frame(maxWidth: .infinity)
        } footer: {
            Text("处理结果可以在「我的 → 我的举报」里看到。")
        }
    }

    // MARK: - 动作

    private func loadReasons() async {
        loading = true
        do {
            reasons = try await store.loadReportReasons()
        } catch {
            // 原因清单拿不到不该挡住举报本身 ——
            // 上面已经有「直接在下面写清楚」的兜底文案，
            // 但把原因也记下来，用户点提交被拒时能对上
            self.error = store.message(for: error)
        }
        loading = false
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            do {
                done = try await store.reportEvent(
                    eventID: eventID,
                    calendarID: calendarID,
                    reason: reason,
                    detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                self.error = store.message(for: error)
            }
            busy = false
        }
    }
}
