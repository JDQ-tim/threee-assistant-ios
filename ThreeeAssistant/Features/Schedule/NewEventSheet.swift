import SwiftUI

@MainActor
struct NewEventSheet: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var calendarID = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var day = Date()
    @State private var time = Date()
    @State private var minutes = 60

    // 重复
    @State private var repeatKind: RepeatRule.Kind = .none
    @State private var repeatInterval = 1
    @State private var repeatWeekdays: Set<Int> = []
    @State private var repeatEnd: RepeatRule.End = .never
    @State private var repeatCount = 10
    @State private var repeatUntil = Date().addingDays(90)

    // 提醒：用「提前多少分钟」的排序集合，0 表示准点
    @State private var reminderOffsets: Set<Int> = [15]
    @State private var remindersOn = true

    // 待办
    @State private var isTask = false

    // 全天 / 强提醒
    @State private var allDay = false
    @State private var strong = false

    @State private var busy = false
    @State private var failure: String?

    /// 首次开始时间。重复规则和提醒都依赖它
    private var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds(date: day, time: time)))
    }

    /// 全天和待办都是「没有时长」的语义，时长 Stepper 对两者都无意义
    private var hidesDuration: Bool { allDay || isTask }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    if let msg = failure {
                        ErrorBanner(message: msg)
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

                        // 全天日程没有具体时刻 —— 藏起来比禁用好：
                        // 灰掉的时间选择器会让人一直琢磨「为什么点不动」
                        if !allDay {
                            labelled("开始") {
                                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                            }
                        }
                    }

                    labelled("全天") {
                        Toggle(isOn: $allDay) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全天日程")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(allDay ? "占满这一整天，不设具体时刻" : "打开后不设开始时刻和时长")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    labelled("时长") {
                        Stepper(value: $minutes, in: 0...1440, step: 15) {
                            Text(minutes == 0 ? "不设时长" : "\(minutes) 分钟")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        // 待办没有结束时间、全天由「天」决定，改时长都没有意义
                        .disabled(hidesDuration)
                        .opacity(hidesDuration ? 0.5 : 1)
                    }

                    labelled("地点") {
                        TextField("可留空", text: $location)
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    labelled("备注") {
                        TextField("可留空", text: $notes, axis: .vertical)
                            .lineLimit(3...6)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    labelled("重复") {
                        RepeatRuleEditor(
                            kind: $repeatKind,
                            interval: $repeatInterval,
                            weekdays: $repeatWeekdays,
                            end: $repeatEnd,
                            count: $repeatCount,
                            until: $repeatUntil,
                            start: startDate
                        )
                    }

                    reminderSection

                    labelled("强提醒") {
                        Toggle(isOn: $strong) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("到点响铃提醒")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("按人存：共享日历上只影响你自己")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    labelled("待办") {
                        Toggle(isOn: $isTask) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("建成待办")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("只有时间点，可以勾选完成")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }
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

    // MARK: - 提醒

    private var reminderSection: some View {
        labelled("提醒") {
            VStack(spacing: 10) {
                Toggle(isOn: $remindersOn) {
                    Text("到点提醒我")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)

                if remindersOn {
                    // 常用档位。做成多选是因为"提前一天 + 提前 1 小时"是常见组合
                    FlowRow(spacing: 8) {
                        ForEach(Self.reminderChoices, id: \.self) { m in
                            let on = reminderOffsets.contains(m)
                            Button {
                                if on { reminderOffsets.remove(m) } else { reminderOffsets.insert(m) }
                            } label: {
                                Text(m == 0 ? "准点" : "提前 \(labelFor(m))")
                                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(on ? Theme.accent : Theme.surfaceAlt)
                                    .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 开了提醒但系统通知被关掉时必须当场说 ——
                    // 不然用户会以为「我设了提醒」，直到真误了事才发现从来没响过。
                    // （iOS 的通知授权只会问一次，之后只能在系统设置里改。）
                    if !ReminderScheduler.shared.canDeliver {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text("通知权限没开，这条提醒不会响。去「设置 → 提醒」打开。")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.red600)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
    }

    private static let reminderChoices = [0, 5, 15, 30, 60, 120, 1440]

    private func labelFor(_ minutes: Int) -> String {
        if minutes >= 1440 { return "\(minutes / 1440) 天" }
        if minutes >= 60 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    // MARK: - 通用

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
        guard !trimmed.isEmpty, !calendarID.isEmpty, !busy else { return }

        busy = true
        failure = nil

        // 全天日程落在当天 00:00 —— 不然会存成一个 14:30 的「全天日程」，
        // 别的客户端按整天显示时看不出来，但排序和「是否已过」的判断都会错。
        let start: Date = allDay
            ? Calendar.current.startOfDay(for: day)
            : startDate

        let rrule = RepeatRule.build(
            kind: repeatKind,
            interval: repeatInterval,
            weekdays: repeatWeekdays,
            end: repeatEnd,
            count: repeatCount,
            until: repeatUntil,
            start: start
        )

        let reminders: [ReminderDTO] = remindersOn
            ? reminderOffsets.sorted().map { ReminderDTO(minutesBefore: Int64($0)) }
            : []

        Task {
            do {
                try await store.createEvent(
                    calendarID: calendarID,
                    title: trimmed,
                    start: start,
                    // 时长由 createEvent 按 allDay 统一决定：
                    // 全天 → 86400 秒，待办 → 0，其余用这里的分钟数
                    durationMinutes: isTask ? 0 : minutes,
                    rrule: rrule,
                    reminders: reminders,
                    isTask: isTask,
                    allDay: allDay,
                    strong: strong,
                    notes: notes,
                    location: location
                )
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

/// 会换行的横向排列。
///
/// SwiftUI 没有内置的流式布局（`LazyVGrid` 是固定列宽，标签长短不一时很难看）。
/// 提醒档位只有 7 个、宽度不一，用 `Layout` 手写一个最干净。
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = []      // 每行高度
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                rows.append(rowHeight)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        rows.append(rowHeight)

        let totalHeight = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? x, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
