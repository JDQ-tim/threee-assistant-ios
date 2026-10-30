import SwiftUI

/// 收件箱。
///
/// ## 它和「共享日历」不是一回事
///
/// - 共享日历：别人**打开你的整张日历**，实时看到里面所有日程
/// - 收件箱：别人把**一条日程的快照**投给你，你决定收不收
///
/// 快照的好处是收件人看到的内容不依赖源日历权限 —— 发出去之后你把源日历删了，
/// 收件人手上那条也还在（他已经落成自己的日程了）。
///
/// ## 为什么「接受」要先建日程再改状态
///
/// 服务端**没有**「从收件箱造事件」的接口。源码（`inbox.go:32`）：
/// 「服务端不提供『从收件箱造事件』的接口。『加入我的日历』是客户端调既有
/// POST /api/events 建成功之后，再把 event_id 一起提交过来改状态。
/// 否则就多出第二条写事件的路径。」
///
/// 所以 `accept` 是两步：`createEvent` → `decideInboxItem(id:action:"accepted", eventID:)`。
/// 顺序不能反：先改状态再建事件，中间失败的话这条就从收件箱里消失了，
/// 而日历里也没有 —— 用户的东西凭空不见。
@MainActor
struct InboxView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var items: [InboxItemDTO] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?

    /// 接受时要把日程放进哪张日历。默认选第一张我能写的。
    @State private var targetCalendarID: String = ""

    @State private var showArchive = false
    @State private var confirmingDismiss: InboxItemDTO?

    /// 我能往里写日程的日历（viewer 不行）
    private var writableCalendars: [CalendarDTO] {
        store.calendars.filter { c in
            let r = c.role ?? ""
            return r == "owner" || r == "admin" || r == "editor"
        }
    }

    private var pending: [InboxItemDTO] {
        items.filter { $0.isPending && !$0.isSystem }
    }

    /// 值得展示的条目。
    ///
    /// 服务端**不会**把过期条目的 status 改掉（读操作不写库），
    /// 而源码要求「过期条目不占未读数、不进提醒链」。
    /// 所以过滤放在这里 —— 过期一年的分享邀请没必要占着「待处理 3」的角标。
    private var visiblePending: [InboxItemDTO] {
        pending.filter { !$0.isStale }
    }

    private var systemNotes: [InboxItemDTO] {
        items.filter { $0.isSystem }
    }

    var body: some View {
        // ⚠️ 这个 NavigationStack 是必需的，不能省。
        //
        // 四 Tab 重构后这一页成了 Tab 的**根视图**。Tab 的根视图必须自己
        // 提供 NavigationStack —— 否则：
        //   1. `.navigationTitle` 无处可挂，顶部一条标题都不显示
        //   2. 下面那个 `NavigationLink`（→ 已处理记录）点了毫无反应，
        //      因为外面没有可推入的栈
        // 两样都不会编译报错，只会"看起来页面是对的、点了没反应"。
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("收件箱")
            // 重构后这一页是一级 Tab 的根页面，不是从别处推进去的子页，
            // 所以用大标题 —— 和「日程」「待办」「我的」保持一致。
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !visiblePending.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                dismissAll()
                            } label: {
                                Label("全部忽略（\(visiblePending.count)）", systemImage: "tray.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(busy)
                    }
                }
            }
            .alert("忽略这一条？", isPresented: Binding(
                get: { confirmingDismiss != nil },
                set: { if !$0 { confirmingDismiss = nil } }
            ), presenting: confirmingDismiss) { it in
                Button("忽略", role: .destructive) { dismiss_(it) }
                Button("取消", role: .cancel) { confirmingDismiss = nil }
            } message: { _ in
                Text("忽略之后这条不会再出现在收件箱里。发件人那边的原始日程不受影响。")
            }
            .task { await reload() }
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            // 手动加一条投递：目前唯一的「发件」入口在日程详情页，
            // 这里给的是自测/自用通道（capture 给自己）。
            Section {
                if writableCalendars.isEmpty {
                    Text("你还没有可以写入的日历")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Picker("收到后放进", selection: $targetCalendarID) {
                        ForEach(writableCalendars) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                }
            } header: {
                Text("接受后放进哪张日历")
            } footer: {
                Text("接受一条邀请时，会在这张日历里建一条属于你自己的日程。选错可以在日程页改。")
            }

            Section {
                if visiblePending.isEmpty {
                    Text("没有待处理的邀请")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(visiblePending) { it in
                        itemRow(it)
                    }
                }
            } header: {
                Text("待处理（\(visiblePending.count)）")
            }

            if !systemNotes.isEmpty {
                Section {
                    ForEach(systemNotes) { it in
                        systemRow(it)
                    }
                } header: {
                    Text("系统通知")
                }
            }

            Section {
                NavigationLink {
                    InboxArchiveView()
                } label: {
                    Label("看已处理的记录", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ it: InboxItemDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let from = it.fromName, !from.isEmpty {
                    Text(from)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text("发来一条日程")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("本机抓取")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if it.isStale {
                    // 过期不改 status（服务端读操作不写库），只在展示层标出来
                    Text("已过期")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(it.displayTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Text(timeLine(it))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            if let loc = it.location, !loc.isEmpty {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            if let ex = it.sourceExcerpt, !ex.isEmpty {
                Text(ex)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.top, 1)
            }

            HStack(spacing: 10) {
                Button {
                    accept(it)
                } label: {
                    Text("加入我的日历")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy || targetCalendarID.isEmpty)

                Button {
                    confirmingDismiss = it
                } label: {
                    Text("忽略")
                        .font(.appFootnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceAlt)
                        .foregroundStyle(Theme.textSecondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Spacer(minLength: 0)

                if busy {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmingDismiss = it
            } label: {
                Label("忽略", systemImage: "tray.and.arrow.down")
            }
        }
    }

    @ViewBuilder
    private func systemRow(_ it: InboxItemDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(it.displayTitle)
                .font(.appSubheadline)
                .foregroundStyle(Theme.textPrimary)
            if let notes = it.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(Self.stamp(it.createdAt))
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 文案

    private func timeLine(_ it: InboxItemDTO) -> String {
        guard let start = it.dtstartUTC else { return "（没有时间）" }
        let date = Date(timeIntervalSince1970: TimeInterval(start))
        if it.allDay ?? false {
            return date.monthDay + " 全天"
        }
        let dur = Int(it.durationSec ?? 0)
        let end = date.addingTimeInterval(TimeInterval(dur))
        return date.monthDay + " " + date.hhmm + " – " + end.hhmm
    }

    static func stamp(_ epoch: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epoch))
        return d.monthDay + " " + d.hhmm
    }

    // MARK: - 动作

    private func reload() async {
        loading = true
        failure = nil
        do {
            // status=all：待处理和系统通知都要，服务端对 "all" 不加状态条件。
            // 只拉 pending 的话，系统通知（可能已经是 accepted 之外的状态）会漏掉。
            items = try await store.loadInbox(status: "all")
        } catch {
            failure = store.message(for: error)
        }
        if targetCalendarID.isEmpty, let first = writableCalendars.first {
            targetCalendarID = first.id
        }
        loading = false
    }

    /// 接受 = 先建日程，再改状态。
    ///
    /// ⚠️ 顺序不能反。反过来（先改状态再建事件）中间失败的话，
    /// 这条会从收件箱里消失而日历里也没有 —— 用户的东西凭空不见。
    private func accept(_ it: InboxItemDTO) {
        guard !busy, !targetCalendarID.isEmpty else { return }
        guard let start = it.dtstartUTC else {
            failure = "这一条没有开始时间，没法加进日历。"
            return
        }
        busy = true
        failure = nil
        Task {
            do {
                let startDate = Date(timeIntervalSince1970: TimeInterval(start))
                let dur = Int(it.durationSec ?? 3600)
                let minutes = max(1, dur / 60)

                // 先建日程（createEvent 内部会 refresh）
                try await store.createEvent(
                    calendarID: targetCalendarID,
                    title: it.displayTitle,
                    start: startDate,
                    durationMinutes: minutes,
                    reminders: Self.reminders(from: it),
                    allDay: it.allDay ?? false,
                    notes: it.notes ?? "",
                    location: it.location ?? ""
                )

                // 再改状态。这里不传 event_id：createEvent 目前不返回 id，
                // 而服务端在 eventID 为空时会保留原来的 accepted_event_id（空）。
                // 影响只有一个：以后想看「这条邀请落成了哪条日程」时查不到。
                // 比起为此改动 createEvent 的签名（它被很多地方调用），这个取舍更划算。
                _ = try await store.decideInboxItem(id: it.id, action: "accepted")

                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    /// `[30, 60]` → `[ReminderDTO]`
    private static func reminders(from it: InboxItemDTO) -> [ReminderDTO] {
        it.reminderMinutes.map { ReminderDTO(minutesBefore: $0) }
    }

    private func dismiss_(_ it: InboxItemDTO) {
        confirmingDismiss = nil
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do {
                _ = try await store.decideInboxItem(id: it.id, action: "dismissed")
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    /// 全部忽略：走批量接口，一次事务全有或全无。
    ///
    /// 分批是因为服务端上限 200 条。真到 200 条以上的场景很少，
    /// 但一次带 500 个 id 会被 400 挡回来，全都没处理 —— 那更糟。
    private func dismissAll() {
        guard !busy else { return }
        busy = true
        failure = nil
        let ids = visiblePending.map { $0.id }
        Task {
            do {
                var cursor = 0
                while cursor < ids.count {
                    let chunk = Array(ids[cursor..<min(cursor + 200, ids.count)])
                    _ = try await store.decideInboxItems(ids: chunk, action: "dismissed")
                    cursor += chunk.count
                }
                await reload()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

// MARK: - 已处理

/// 已经处理过的条目（accepted / dismissed）。
///
/// 服务端 `status=all` 才会带上这些。这里只做只读展示 ——
/// 已 accepted 的不能撤回（409：「它已经在你或对方的日历里了」）。
@MainActor
struct InboxArchiveView: View {

    @Environment(SessionStore.self) private var store

    @State private var items: [InboxItemDTO] = []
    @State private var loading = true
    @State private var failure: String?

    private var decided: [InboxItemDTO] {
        items.filter { !$0.isPending }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
        .navigationTitle("已处理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private var list: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            Section {
                if decided.isEmpty {
                    Text("还没有处理过的记录")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(decided) { it in
                        HStack(spacing: 10) {
                            Image(systemName: it.status == "accepted" ? "checkmark.circle" : "tray.and.arrow.down")
                                .font(.appSubheadline)
                                .foregroundStyle(it.status == "accepted" ? Theme.accent : Theme.textTertiary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.displayTitle)
                                    .font(.appSubheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(it.status == "accepted" ? "已接受" : "已忽略")
                                    if let d = it.decidedAt, d > 0 {
                                        Text("·")
                                        Text(InboxView.stamp(d))
                                    }
                                    if let from = it.fromName, !from.isEmpty {
                                        Text("·")
                                        Text(from)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            } footer: {
                Text("已经接受的条目不能撤回 —— 它已经在你或对方的日历里成了一条日程。想取消请去日程页删掉那条日程。")
            }
        }
    }

    private func reload() async {
        loading = true
        failure = nil
        do {
            items = try await store.loadInbox(status: "all")
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }
}
