import SwiftUI

struct EventDetailSheet: View {

    let item: ScheduleInstance
    let calendar: CalendarDTO?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false
    @State private var busy = false
    @State private var failure: String?

    @State private var showEdit = false
    /// 改完要关掉详情页，否则详情页还显示着改之前的内容 —— 看起来像没保存成功
    @State private var edited = false

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

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "正在删除…" : "删除这条日程")
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

                    Text("删除只影响这一次。如果它是重复日程中的一次，其它几次不受影响。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)
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
            .onChange(of: showEdit) { _, isShowing in
                // 编辑页关掉之后，详情页的内容已经过期了：直接退出，
                // 让用户回到列表看到最新结果，比留一个旧快照更不容易误解
                if !isShowing && edited { dismiss() }
            }
            .alert("确定删除？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「\(item.title ?? "无标题")」将被删除，其它设备同步后也会消失。")
            }
            .task { await loadFull() }
        }
    }

    /// 拉一次原始日程，补齐实例里没有的字段。
    ///
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

    private func performDelete() {
        busy = true
        failure = nil
        Task {
            do {
                try await store.deleteEvent(eventID: item.eventID)
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}