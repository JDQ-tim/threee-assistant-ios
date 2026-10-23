import SwiftUI

@MainActor
struct EventDetailSheet: View {

    let item: ScheduleInstance
    let calendar: CalendarDTO?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false
    @State private var busy = false
    @State private var failure: String?

    /// 稍后提醒正在发请求
    @State private var snoozing = false
    /// 已经推到的时刻。非 nil 时显示「已延后到 …」并给一个撤销入口
    @State private var snoozedUntil: Int64?

    @State private var showEdit = false
    /// 改完要关掉详情页，否则详情页还显示着改之前的内容 —— 看起来像没保存成功
    @State private var edited = false

    /// 分享给别人的弹窗
    @State private var showShare = false

    /// 举报弹窗
    @State private var showReport = false

    /// 打开详情时拉一次原始数据。列表里只有展开后的实例，
    /// 重复规则、提醒、强提醒这些只有 `GET /api/events/{id}` 才有。
    @State private var full: APIEvent?

    private var timeText: String {
        if item.allDay { return "全天" }
        if !item.hasSpan { return item.start.hhmm }
        return "\(item.start.hhmm) – \(item.end.hhmm)"
    }

    private var durationText: String {
        let d = Date.durationText(seconds: item.endUTC - item.startUTC)
        return d.isEmpty ? "—" : d
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hexString: calendar?.displayColor ?? "#185FA5"))
                            .frame(width: 4, height: 30)

                        Text(item.title?.isEmpty == false ? item.title! : "（无标题）")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 18)

                    if let msg = failure {
                        ErrorBanner(message: msg)
                            .padding(.bottom, 14)
                    }

                    infoRow("时间", timeText)
                    infoRow("日期", "\(item.start.monthDay) \(item.start.weekdayName)")
                    infoRow("时长", durationText)
                    infoRow("日历", calendar?.name ?? "—")
                    if let r = store.repeatRuleByEventID[item.eventID], !r.isEmpty {
                        infoRow("重复", RepeatRule.describe(r))
                    }
                    if let ev = full {
                        infoRow("提醒", reminderText(ev.reminders))
                        if ev.strong {
                            infoRow("强提醒", "已开启")
                        }
                    }
                    infoRow("地点", item.location?.isEmpty == false ? item.location! : "—")
                    infoRow("备注", item.notes?.isEmpty == false ? item.notes! : "—")

                    snoozeSection

                    Button {
                        showEdit = true
                    } label: {
                        Text("修改这条日程")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Theme.accent)
                            .foregroundStyle(Theme.onAccent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    }
                    .disabled(busy)
                    .padding(.top, 22)

                    Text("修改会同步到其它设备。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)

                    Button {
                        showShare = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane")
                            Text("分享给同学")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.surfaceAlt)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    }
                    .disabled(busy)
                    .padding(.top, 14)

                    Text("会把这条日程的一份快照投到对方的收件箱，他要自己点「加入我的日历」才会出现在他的日历里。分享出去之后你再改这条，对方那份不会跟着变。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "正在删除…" : deleteButtonTitle)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.red600)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    }
                    .disabled(busy)
                    .padding(.top, 10)

                    Text(deleteHintText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)

                    // 举报入口刻意做得比删除**轻**：它不是常规操作，
                    // 放成一个红色大按钮会让人误点，也会让这一页看起来像
                    // 「一进来就该删点什么」。一行灰色文字链足够，
                    // 需要它的人找得到，不需要的人不会碰到
                    Button {
                        showReport = true
                    } label: {
                        Text("举报这条日程")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .padding(.top, 14)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("日程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // ⚠️ 用 fullScreenCover 而不是再套一层 sheet。
            //    详情页本身就是 sheet，sheet 上再 present 一个 sheet，
            //    iOS 会静默不显示（不报错，点了编辑没任何反应）。
            .fullScreenCover(isPresented: $showEdit) {
                EditEventSheet(instance: item) {
                    edited = true
                }
            }
            // 分享也是 sheet 套 sheet —— 同样要吃 iOS 的那个亏，所以也走全屏。
            // 但它不需要在关闭后退出详情页：分享不改变这条日程本身。
            .fullScreenCover(isPresented: $showShare) {
                ShareEventSheet(instance: item, full: full)
            }
            // 举报同样走全屏（sheet 套 sheet 会被 iOS 静默忽略）。
            .fullScreenCover(isPresented: $showReport) {
                ReportEventSheet(
                    eventID: item.eventID,
                    calendarID: item.calendarID,
                    eventTitle: item.title ?? ""
                )
            }
            .onChange(of: showEdit) { _, isShowing in
                // 编辑页关掉之后，详情页的内容已经过期了：直接退出，
                // 让用户回到列表看到最新结果，比留一个旧快照更不容易误解
                if !isShowing && edited { dismiss() }
            }
            .alert("确定删除？", isPresented: $confirmDelete) {
                if isRecurring {
                    Button("删除这一次", role: .destructive) {
                        performDelete(wholeSeries: false)
                    }
                    Button("删除整个系列", role: .destructive) {
                        performDelete(wholeSeries: true)
                    }
                } else {
                    Button("删除", role: .destructive) {
                        performDelete(wholeSeries: false)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .task { await loadFull() }
        }
    }

    // MARK: - 稍后提醒

    /// 快捷档位（分钟）。源码服务端对 `minutes` 没有上限，但 UI 上给太多选择等于没选择。
    private static let snoozeChoices = [5, 10, 30, 60]

    /// 只有「还没开始、也没结束」的日程才值得推后提醒。
    ///
    /// 已经过去的日程再推后毫无意义 —— 提醒早就不存在了，
    /// 服务端照样会写一条 snooze 记录，但那是个永远不会响的孤儿。
    private var canSnooze: Bool {
        item.endUTC > Int64(Date().timeIntervalSince1970)
    }

    @ViewBuilder
    private var snoozeSection: some View {
        if canSnooze {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                    Text(snoozedUntil == nil ? "稍后提醒" : "已延后提醒")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)

                if let until = snoozedUntil {
                    // 已推后：给出确切时刻 + 撤销
                    HStack(spacing: 10) {
                        Text(Date(timeIntervalSince1970: TimeInterval(until)).monthDay
                             + " " + Date(timeIntervalSince1970: TimeInterval(until)).hhmm)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Button {
                            clearSnooze()
                        } label: {
                            Text("撤销")
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.surfaceAlt)
                                .foregroundStyle(Theme.textSecondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(snoozing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                } else {
                    FlowRow(spacing: 8) {
                        ForEach(Self.snoozeChoices, id: \.self) { m in
                            Button {
                                doSnooze(minutes: m)
                            } label: {
                                Text(m >= 60 ? "\(m / 60) 小时后" : "\(m) 分钟后")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Theme.surfaceAlt)
                                    .foregroundStyle(Theme.textPrimary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(snoozing)
                        }
                        if snoozing {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }

                Text("延后是存在服务端的：手机推后了，电脑也不会再按原时间响。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
        }
    }

    private func doSnooze(minutes: Int) {
        guard !snoozing else { return }
        snoozing = true
        failure = nil
        Task {
            do {
                let until = try await store.snooze(
                    eventID: item.eventID,
                    occurrenceKey: item.occurrenceKey,
                    minutes: minutes
                )
                // 服务端回了确切时刻就用它 —— 两端时钟可能差几十秒，
                // 自己按 now + minutes 算会导致「明明设了 10 分钟却提前响」
                snoozedUntil = until
                    ?? Int64(Date().timeIntervalSince1970) + Int64(minutes * 60)
            } catch {
                failure = store.message(for: error)
            }
            snoozing = false
        }
    }

    private func clearSnooze() {
        guard !snoozing else { return }
        snoozing = true
        failure = nil
        Task {
            do {
                try await store.clearSnooze(eventID: item.eventID)
                snoozedUntil = nil
            } catch {
                failure = store.message(for: error)
            }
            snoozing = false
        }
    }

    /// 拉一次原始日程，补齐实例里没有的字段。
    /// 失败不提示：这是「补充信息」，拉不到只是少显示两行，
    /// 不该让用户看到一个「读取失败」的页面 —— 他点的是一次正常的详情查看。
    private func loadFull() async {
        full = try? await store.loadEvent(id: item.eventID)
    }

    private func reminderText(_ list: [ReminderDTO]) -> String {
        guard !list.isEmpty else { return "不提醒" }
        let parts = list.map { r -> String in
            let m = Int(r.minutesBefore)
            if m <= 0 { return "准点" }
            if m >= 1440 && m % 1440 == 0 { return "提前 \(m / 1440) 天" }
            if m >= 60 && m % 60 == 0 { return "提前 \(m / 60) 小时" }
            return "提前 \(m) 分钟"
        }
        return parts.joined(separator: "、")
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)
        }
    }

    private func performDelete(wholeSeries: Bool) {
        busy = true
        failure = nil
        Task {
            do {
                if wholeSeries {
                    // DELETE /api/events/{id} —— 删整个系列
                    try await store.deleteEvent(eventID: item.eventID)
                } else {
                    // DELETE /api/events/{id}/occurrence?key= —— 只删这一次。
                    //
                    // ⚠️ 对非重复日程来说这两条其实等价（只有一个实例），
                    //    但走 occurrence 更精确：万一以后有人给单次日程
                    //    也写了 override，删一次不会连带把整个事件抹掉。
                    try await store.deleteOccurrence(
                        eventID: item.eventID,
                        occurrenceKey: item.occurrenceKey
                    )
                }
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }

    // MARK: - 删除的文案

    /// 重复日程和单次日程的删除语义完全不同，按钮和说明都得跟着变。
    ///
    /// 之前这里的说明写着「删除只影响这一次」，但代码走的是删整个系列 ——
    /// 文案和行为对不上，用户按提示操作会连带删掉后面所有次。
    private var isRecurring: Bool {
        // 先用本地缓存（列表里已经有），没有就看刚拉到的原始数据
        if let r = store.repeatRuleByEventID[item.eventID], !r.isEmpty { return true }
        if let ev = full { return ev.isRecurring }
        return false
    }

    private var deleteButtonTitle: String {
        isRecurring ? "删除这次日程" : "删除这条日程"
    }

    private var deleteHintText: String {
        if isRecurring {
            return "这是重复日程。可以在下一步选「只删这一次」或「删掉整个系列」。"
        }
        return "删除后其它设备同步时也会消失。"
    }

    private var confirmMessage: String {
        let name = "「\(item.title ?? "无标题")」"
        if isRecurring {
            return name + "是重复日程。\n\n只删这一次："
                + "\(item.start.monthDay) \(item.start.hhmm) 这条不再出现，其它几次照常。\n"
                + "删掉整个系列：之后所有重复安排一起消失。"
        }
        return name + "将被删除，其它设备同步后也会消失。"
    }
}