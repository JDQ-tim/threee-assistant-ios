import SwiftUI

/// 我提交过的举报及处理结果（`GET /api/reports/mine`）。
///
/// ## 这一页为什么必须有
///
/// 举报提交完就石沉大海的话，用户下次就不报了 ——
/// 而举报机制能起作用的前提是**有人愿意报**。
/// 让他看到「已受理 / 已驳回 + 处理意见」，
/// 哪怕被驳回，也比「点了没反应」可信得多。
///
/// 服务端最多回 100 条（按时间倒序），所以这里不做分页。
@MainActor
struct MyReportsView: View {

    @Environment(SessionStore.self) private var store

    @State private var items: [MyReportDTO] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error = error {
                Section { ErrorBanner(message: error) }
            }

            if loading && items.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在加载…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else if items.isEmpty && error == nil {
                Section {
                    Text("你还没举报过任何内容。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } footer: {
                    Text("在日程详情页最下面可以举报。举报只针对违规内容，比如辱骂、垃圾广告。")
                }
            } else {
                ForEach(items) { r in
                    row(r)
                }
            }
        }
        .navigationTitle("我的举报")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func row(_ r: MyReportDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.targetKindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceAlt)
                    .foregroundStyle(Theme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Text(r.targetTitle.isEmpty ? "（无标题）" : r.targetTitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Text(r.statusLabel)
                    .font(.caption2.weight(.medium))
                    // 三种状态用三种颜色：等待中是中性灰（不是错误），
                    // 驳回是红（结果对用户不利），受理是绿（有结果了）
                    .foregroundStyle(r.isPending
                                     ? Theme.textTertiary
                                     : (r.isRejected ? Theme.red600 : Theme.teal600))
            }

            HStack(spacing: 6) {
                Text(r.reasonLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if !r.detail.isEmpty {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Text(r.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            // 处理意见只在**处理过之后**显示。
            // 等处理时显示一个空白的「处理意见：」只会让人以为漏了内容
            if !r.isPending && !r.handleNote.isEmpty {
                Text("管理员：\(r.handleNote)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            items = try await store.loadMyReports()
        } catch {
            self.error = store.message(for: error)
        }
        loading = false
    }
}
