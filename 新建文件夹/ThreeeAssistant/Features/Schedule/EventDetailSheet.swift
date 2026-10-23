import SwiftUI

struct EventDetailSheet: View {

    let item: ScheduleInstance
    let calendar: CalendarDTO?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false
    @State private var busy = false
    @State private var failure: String?

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
                    infoRow("地点", item.location?.isEmpty == false ? item.location! : "—")
                    infoRow("备注", item.notes?.isEmpty == false ? item.notes! : "—")

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
                    .padding(.top, 22)

                    Text("只删除这一次。如果它是重复日程中的一次，其它几次不受影响。")
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
            .alert("确定删除？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「\(item.title ?? "无标题")」将被删除，其它设备同步后也会消失。")
            }
        }
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
