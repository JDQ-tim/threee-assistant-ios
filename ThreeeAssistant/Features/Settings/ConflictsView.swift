import SwiftUI

/// 并发修改冲突的处理页。
///
/// ## 这个页面解决的是什么问题
///
/// 两个人（或同一个人两台设备）几乎同时改同一条日程的**同一个字段**时，
/// 服务端做的是**字段级合并**：谁先到谁生效，后到的那个值写进 `conflicts` 表，
/// 但**不会直接覆盖**——它留着等用户自己决定。
///
/// 所以不处理它不会丢数据，只是「我明明改了，怎么没生效」这种困惑会一直挂着。
///
/// ## 三种处理方式为什么都要有
///
/// `keep_both` 看着很怪（复制一条日程？），但源码里解释了原因：
/// 一家两口都不小心订了同一时段，二选一必然丢掉一个人的记录。
/// 复制成两条、改成不同标题，才是真实场景里最不伤人的做法。
@MainActor
struct ConflictsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ConflictDTO] = []
    @State private var loading = true
    @State private var failure: String?
    /// 正在处理中的那一条 id，用来禁掉它的按钮，避免重复提交
    @State private var resolvingID: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let msg = failure, items.isEmpty {
                errorState(msg)
            } else if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.background)
        .navigationTitle("修改冲突")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                ForEach(items) { c in
                    ConflictRow(
                        conflict: c,
                        busy: resolvingID == c.id,
                        disabled: resolvingID != nil
                    ) { resolution in
                        resolve(c, with: resolution)
                    }
                }
            } header: {
                Text("\(items.count) 条待处理")
            } footer: {
                Text("这些是你的修改和别人的修改撞在了一起。服务端已经保住了两边的值，选一个处理方式即可；不处理也不会丢数据。")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)
            Text("没有待处理的冲突")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("多人或多设备同时改同一条日程的同一个字段时，才会产生冲突。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Theme.red600)
            Text("读取失败")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("重试") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func load() async {
        loading = true
        failure = nil
        do {
            items = try await store.loadConflicts()
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func resolve(_ c: ConflictDTO, with resolution: String) {
        guard resolvingID == nil else { return }
        resolvingID = c.id
        failure = nil
        Task {
            do {
                try await store.resolveConflict(id: c.id, resolution: resolution)
                // 处理完就把它从列表里摘掉。
                // 这里不用整表重拉：服务端已经把 resolved_at 写上去了，
                // 但重拉会顺带刷新整份日程，比本地移除慢得多，
                // 用户在等着看结果。
                items.removeAll { $0.id == c.id }
            } catch {
                failure = store.message(for: error)
            }
            resolvingID = nil
        }
    }
}

// MARK: - 单条

/// 一条冲突。
///
/// ⚠️ 服务端存的两个值是 **JSON 片段**，不是裸字符串：
/// `title` 存的是 `"\"高数\""`（带引号），`duration_sec` 存的是 `3600`。
/// 直接显示会把引号一起印出来，所以统一交给 `pretty()` 解一层。
private struct ConflictRow: View {

    let conflict: ConflictDTO
    let busy: Bool
    let disabled: Bool
    let onResolve: (String) -> Void

    @State private var confirmingKeepBoth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 6) {
                Text(ConflictRow.fieldLabel(conflict.field))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if conflict.entity == "calendar" {
                    // 日历冲突和日程冲突处理起来是同一套，但来源不一样，
                    // 标出来免得用户以为自己改的是日程
                    PillView(text: "日历", tone: .plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                valueLine("服务器上现在", conflict.serverValue ?? "（空）")
                valueLine("我的修改", conflict.clientValue ?? "（空）")
            }

            Text("来自 \(conflict.clientDevice.isEmpty ? "另一台设备" : conflict.clientDevice)"
                 + " · " + ConflictRow.whenText(conflict.createdAt))
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)

            if busy {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("处理中…")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                FlowRow(spacing: 8) {
                    actionButton("用我的", tone: .brand) {
                        onResolve(ResolveConflictBody.keepMine)
                    }
                    actionButton("用服务器的", tone: .plain) {
                        onResolve(ResolveConflictBody.keepServer)
                    }
                    if conflict.entity == "event" {
                        actionButton("两个都留", tone: .plain) {
                            confirmingKeepBoth = true
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(disabled && !busy)
        .alert("保留两份？", isPresented: $confirmingKeepBoth) {
            Button("保留两份") { onResolve(ResolveConflictBody.keepBoth) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务端会复制出一条新日程（标题带「（副本）」）来放我的版本，原来那条保持服务器上的值。两边都不会丢。")
        }
    }

    private func valueLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 76, alignment: .leading)
            Text(ConflictRow.pretty(value))
                .font(.appFootnote)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private enum Tone { case brand, plain }

    private func actionButton(_ title: String, tone: Tone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(tone == .brand ? .semibold : .regular))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(tone == .brand ? Theme.accent : Theme.surfaceAlt)
                .foregroundStyle(tone == .brand ? Theme.onAccent : Theme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 展示换算

    /// 服务端存的是 JSON 片段，这里解一层。
    ///
    /// `"高数"` → `高数`；`3600` → `3600`；解不动就原样返回。
    /// 不用 `JSONSerialization` 是因为它对裸数字/裸字符串要求先包一层，
    /// 直接试两种类型更省事。
    static func pretty(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "（空）" }

        if s.hasPrefix("\"") {
            if let d = s.data(using: .utf8),
               let str = try? JSONDecoder().decode(String.self, from: d) {
                return str.isEmpty ? "（空）" : str
            }
        }
        // 布尔值在冲突里很少见，但时间戳、时长会是数字 —— 原样给就行，
        // 不解成 Double 再拼回去，那样会把 3600 变成 3600.0
        return s
    }

    /// 字段名 → 用户看得懂的中文
    static func fieldLabel(_ raw: String) -> String {
        switch raw {
        case "title": return "标题"
        case "notes": return "备注"
        case "location": return "地点"
        case "all_day": return "全天"
        case "dtstart_utc": return "开始时间"
        case "duration_sec": return "时长"
        case "tzid": return "时区"
        case "rrule": return "重复规则"
        case "is_task": return "待办"
        case "done_at": return "完成状态"
        case "name": return "名称"
        case "color": return "颜色"
        case "kind": return "类型"
        default: return raw
        }
    }

    static func whenText(_ epoch: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epoch))
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.hhmm }
        if cal.isDateInYesterday(d) { return "昨天 " + d.hhmm }
        return d.monthDay + " " + d.hhmm
    }
}
