import SwiftUI

struct NewEventSheet: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var calendarID = ""
    @State private var day = Date()
    @State private var time = Date()
    @State private var minutes = 60
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    if let failure {
                        ErrorBanner(message: failure)
                    }

                    labelled("标题") {
                        TextField("例如：高等数学", text: $title)
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    labelled("日历") {
                        Picker("日历", selection: $calendarID) {
                            ForEach(store.calendars) { cal in
                                Text(cal.name).tag(cal.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    HStack(spacing: 12) {
                        labelled("日期") {
                            DatePicker("", selection: $day, displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                        }

                        labelled("开始") {
                            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                        }
                    }

                    labelled("时长") {
                        HStack {
                            Stepper(value: $minutes, in: 0...1440, step: 15) {
                                Text(minutes == 0 ? "不设时长" : "\(minutes) 分钟")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    Text("时长填 0 表示待办（只有时间点，没有结束时间）。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("新建日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "保存中…" : "保存") { save() }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if calendarID.isEmpty { calendarID = store.calendars.first?.id ?? "" }
            }
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !calendarID.isEmpty else { return }

        busy = true
        failure = nil

        // 把「日期」和「时间」两个 picker 拼成一个时间点。
        // ⚠️ 服务端要的是 epoch **秒**；这里用 epochSeconds() 拼，
        //    不要用 Date 的 description 或字符串解析 —— 时区一错就是 8 小时。
        let epoch = epochSeconds(date: day, time: time)
        let start = Date(timeIntervalSince1970: TimeInterval(epoch))

        Task {
            do {
                try await store.createEvent(
                    calendarID: calendarID,
                    title: trimmed,
                    start: start,
                    durationMinutes: minutes
                )
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
