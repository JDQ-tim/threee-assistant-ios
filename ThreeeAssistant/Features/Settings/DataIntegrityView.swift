import SwiftUI

/// 数据自检（`GET /api/maintenance/scan`，管理员专用）。
///
/// ## 这一页解决的是什么事
///
/// 「日历删了、里面的日程还活着」这类库层面的引用断裂，
/// 用户看到的现象是**列表里冒出点不开、改不动的条目**。
/// 他没法自己查，只能觉得「这 App 坏了」。
///
/// 管理员在手机上跑一次就能确认，不必登录服务器敲命令。
///
/// ## 为什么把「扫描」和「修复」分成两个按钮
///
/// 扫描只读、随时能跑；修复**会写库**，而且动的不只是自己的数据。
/// 一个按钮两个动作的话，「顺便点一下看看」就等于改了别人的日历行。
@MainActor
struct DataIntegrityView: View {

    @Environment(SessionStore.self) private var store

    @State private var report: RepairReportDTO?
    @State private var scanning = false
    @State private var repairing = false
    @State private var confirmedRepair = false
    @State private var error: String?
    /// 修复完之后的一句话（"修好了 3 条"）。和 `report` 分开存，
    /// 因为 `report.issues` 是**修复前**那份，不能拿它当「现在还剩几条」
    @State private var repairOutcome: String?

    private var isAdmin: Bool { store.user?.isAdmin ?? false }
    private var busy: Bool { scanning || repairing }

    var body: some View {
        Form {
            if !isAdmin {
                Section {
                    Text("只有管理员能跑数据自检。")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                actionSection
                if let error = error {
                    Section { ErrorBanner(message: error) }
                }
                if let report = report {
                    resultSection(report)
                } else if !busy {
                    emptySection
                }
            }
        }
        .navigationTitle("数据自检")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认修复？", isPresented: $confirmedRepair) {
            Button("取消", role: .cancel) {}
            Button("修复", role: .destructive) { runRepair() }
        } message: {
            Text("修复会**写库**：删掉指向已删对象的孤儿行、给该消失的日程补上删除标记。它动的是整个库里的问题行，不只是你自己的数据。修完会立刻重新扫描一次。")
        }
    }

    // MARK: - 操作区

    private var actionSection: some View {
        Section {
            Button {
                runScan()
            } label: {
                HStack(spacing: 8) {
                    if scanning { ProgressView() }
                    Text(scanning ? "正在扫描…" : "扫描（只读）")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(busy)

            // 修复按钮在**扫出问题之前**不该是活的 ——
            // 没有问题可修的时候点它，用户只会困惑"它在修什么"
            Button(role: .destructive) {
                confirmedRepair = true
            } label: {
                HStack(spacing: 8) {
                    if repairing { ProgressView() }
                    Text(repairing ? "正在修复…" : "扫描并修复")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(busy || (report?.total ?? 0) == 0)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("扫描是只读的，先跑它不会改任何数据。修复会写库，所以先扫一遍确认问题在哪、有多少条，再决定要不要修。")
                if let outcome = repairOutcome {
                    Text(outcome)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    // MARK: - 结果

    private func resultSection(_ r: RepairReportDTO) -> some View {
        Group {
            Section {
                LabeledContent("问题总数", value: "\(r.total)")
                if r.total > 0 {
                    ForEach(r.sortedKinds, id: \.kind) { item in
                        LabeledContent(RepairIssueKind.label(item.kind), value: "\(item.count) 条")
                    }
                }
            } header: {
                Text("结果")
            } footer: {
                if r.total == 0 {
                    Text("库是干净的，没有发现引用完整性问题。")
                } else {
                    Text("这些问题大多是历史遗留：日历软删了、里面的日程没跟着打墓碑。列表上会表现为「点不开、改不动的条目」。")
                }
            }

            if r.total > 0 {
                Section("具体条目（最多显示 50 条）") {
                    // ⚠️ 只渲染前 50 条：库里坏上千条时，
                    //    一次性 ForEach 出来会让这一页卡住。
                    //    完整清单在这里的意义本来就不大 —— 用户要的是
                    //    「有多少、哪一类」，不是逐条读完
                    ForEach(Array(r.issues.prefix(50))) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.detail ?? issue.kind)
                                .font(.footnote)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(issue.id + (issue.extra.map { " · \($0)" } ?? ""))
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                    if r.issues.count > 50 {
                        Text("还有 \(r.issues.count - 50) 条未显示")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var emptySection: some View {
        Section {
            Text("还没扫描过。点上面的「扫描（只读）」开始。")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - 动作

    private func runScan() {
        guard !busy else { return }
        scanning = true
        error = nil
        repairOutcome = nil
        Task {
            do {
                report = try await store.scanDataIntegrity()
            } catch {
                self.error = store.message(for: error)
            }
            scanning = false
        }
    }

    private func runRepair() {
        guard !busy else { return }
        repairing = true
        error = nil
        repairOutcome = nil
        Task {
            do {
                let res = try await store.repairDataIntegrity()
                if res.applied == false {
                    // 服务端保留了「只扫不修」的可能。照实说，
                    // 不能一律显示「已修复」—— 那会让用户以为干净了
                    repairOutcome = "服务端这一轮只做了扫描，没有实际改动。"
                } else {
                    repairOutcome = "修好了 \(res.fixed ?? 0) 条（共扫出 \(res.total) 条）。下面这份是修复前的清单。"
                }
                // 修完重新扫一次：要在界面上看到「现在还剩几条」。
                // 直接复用 repair 返回的 issues 是错的 —— 那是修复前的
                report = try await store.scanDataIntegrity()
            } catch {
                self.error = store.message(for: error)
            }
            repairing = false
        }
    }
}
