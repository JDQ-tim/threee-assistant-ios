import SwiftUI

/// 修改已有日程。
///
/// ## 和"新建"最大的区别
///
/// 新建是"从无到有"，编辑是"在原值上打补丁"。因此这个页面必须：
///
/// 1. **先加载原始数据**，而不是拿列表里那一条凑合用
///    —— 列表项是 ScheduleInstance（某天的一次展开），
///    用它的值回填会让重复日程的"某一次"被误当成整个事件。
///
/// 2. **只提交用户真正改过的字段**（见 UpdateEventBody 的注释）。
///    全量提交会把没动过的字段也变成一次写入。
///
/// 3. **重复日程要问清楚改哪一次**。服务端有两条完全不同的路径：
///    - `PUT /api/events/{id}`            改整个系列，后续实例全部重算
///    - `PUT /api/events/{id}/occurrence` 只给这一次写一条补丁
///    选错的影响面差别很大，所以必须让用户明确选，不能替 ta 决定。
struct EditEventSheet: View {

    /// 从列表点进来的那个实例，用它的 eventID 去拉真实数据、
    /// 用它的 occurrenceKey 定位「这一次」
    let instance: ScheduleInstance

    /// 保存成功后回调，让上层知道"改完了"
    var onSaved: (() -> Void)?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // 原始数据，用来比对"改了什么"
    @State private var original: APIEvent?

    // 可编辑字段
    @State private var title = ""
    @State private var notes = ""
    @State private var location = ""
    @State private var day = Date()
    @State private var time = Date()
    @State private var minutes = 60
    @State private var calendarID = ""

    // 重复规则（只在「改整个系列」或非重复日程时可用）
    @State private var repeatKind: RepeatRule.Kind = .none
    @State private var repeatInterval = 1
    @State private var repeatWeekdays: Set<Int> = []
    @State private var repeatEnd: RepeatRule.End = .never
    @State private var repeatCount = 10
    @State private var repeatUntil = Date().addingDays(90)

    // 提醒
    @State private var remindersOn = true
    @State private var reminderOffsets: Set<Int> = []

    @State private var isTask = false

    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?
    @State private var loadFailed = false

    /// 重复日程点保存后弹的"改哪一次"，nil 表示不弹
    @State private var pendingPatch: UpdateEventBody?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    loadErrorView
                } else {
                    form
                }
            }
            .background(Theme.background)
            .navigationTitle("修改日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { save() }
                        .disabled(saving || loading || loadFailed || !hasChanges)
                }
            }
            .alert(
                "这是重复日程",
                isPresented: Binding(
                    get: { pendingPatch != nil },
                    set: { if !$0 { pendingPatch = nil } }
                ),
                presenting: pendingPatch
            ) { p in
                Button("只改这一次") {
                    pendingPatch = nil
                    performSave(p, wholeSeries: false)
                }
                Button("改整个系列") {
                    pendingPatch = nil
                    performSave(p, wholeSeries: true)
                }
                Button("取消", role: .cancel) { pendingPatch = nil }
            } message: { _ in
                Text("「\(instance.start.monthDay) \(instance.start.hhmm)」这次之后的安排要不要一起改？\n\n只改这一次：其它几次保持原样。\n改整个系列：之后所有重复安排都会重新计算。")
            }
        }
        .interactiveDismissDisabled(saving)
        .task { await load() }
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        loadFailed = false
        do {
            let ev = try await store.loadEvent(id: instance.eventID)
            original = ev

            // 表单回填用**实例**的值而不是系列的值 ——
            // 重复日程的这一次可能被单独改过（is_override），
            // 用系列原值回填会让用户看到"我明明改过，怎么又变回去了"
            title = instance.title ?? ev.title
            notes = instance.notes ?? ev.notes
            location = instance.location ?? ev.location
            calendarID = ev.calendarID
            minutes = Int((instance.endUTC - instance.startUTC) / 60)

            day = instance.start
            time = instance.start

            // 回填重复规则。只回填频率和间隔，
            // 因为 build() 的反向解析需要能覆盖所有形态，这里不做无谓的复杂度 ——
            // 用户只要不改「重复」这一栏，patch 里就不会出现 rrule
            //
            // filling 在这里全程为 true，挡住 onChange 误把回填当成用户改动
            filling = true
            fillRepeat(from: ev.rrule)
            reminderOffsets = Set(ev.reminders.map { Int($0.minutesBefore) })
            remindersOn = !ev.reminders.isEmpty
            isTask = ev.isTask
        } catch {
            failure = store.message(for: error)
            loadFailed = true
        }
        loading = false
        // 等 SwiftUI 把这一轮 @State 变化处理完再打开 onChange，
        // 否则回填触发的 onChange 会在 filling 还是 false 时到达
        DispatchQueue.main.async { filling = false }
    }

    /// 从 RRULE 反推出界面上的几项。
    ///
    /// 只做**尽力而为**的反向解析：已知形态能完整还原（编辑页打开和原来一致），
    /// 遇到不认识的形态（别的客户端写进去的复杂规则）就退回「不重复」，
    /// 但**只要用户没动重复这一栏，patch 里就不会带 rrule**，原规则不会被破坏。
    /// 这一点很关键 —— 否则打开编辑页看一眼再保存，就把别人的复杂规则洗成"不重复"了。
    private func fillRepeat(from rrule: String) {
        let raw = rrule.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { repeatKind = .none; return }

        let body = raw.hasPrefix("RRULE:") ? String(raw.dropFirst(6)) : raw
        var d: [String: String] = [:]
        for seg in body.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { d[String(kv[0]).uppercased()] = String(kv[1]) }
        }

        switch (d["FREQ"] ?? "").uppercased() {
        case "DAILY": repeatKind = .daily
        case "WEEKLY": repeatKind = .weekly
        case "MONTHLY": repeatKind = .monthly
        case "YEARLY": repeatKind = .yearly
        default:
            // 认不出来（HOURLY、或者格式怪）就假装不重复，
            // 但下面的 comparesRule 会拦住"没动却提交"的情况
            repeatKind = .none
            return
        }

        repeatInterval = Int(d["INTERVAL"] ?? "") ?? 1

        if let byday = d["BYDAY"], !byday.isEmpty {
            let map: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
            repeatWeekdays = Set(byday.split(separator: ",").compactMap { map[String($0).uppercased()] })
        }

        if let c = d["COUNT"], let n = Int(c) {
            repeatEnd = .count
            repeatCount = n
        } else if let u = d["UNTIL"] {
            repeatEnd = .until
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            repeatUntil = f.date(from: u) ?? Date().addingDays(90)
        } else {
            repeatEnd = .never
        }
    }

    private var loadErrorView: some View {        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Theme.red600)
            Text("读取失败")
                .font(.headline)
            if let msg = failure {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Button("重试") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 表单

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                if let msg = failure, !loadFailed {
                    ErrorBanner(message: msg)
                }

                if isRecurring {
                    recurringHint
                }

                labelled("标题") {
                    TextField("日程标题", text: $title)
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
                    // 重复日程的"只改这一次"换不了日历：服务端的单次补丁
                    // 没有 calendar_id 这个字段，改了也不会生效
                    .disabled(isRecurring)
                    .opacity(isRecurring ? 0.55 : 1)
                }

                if isRecurring {
                    Text("重复日程换日历只能「改整个系列」。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 2)
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
                    Stepper(value: $minutes, in: 0...1440, step: 15) {
                        Text(minutes == 0 ? "不设时长（待办）" : "\(minutes) 分钟")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
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
                    VStack(alignment: .leading, spacing: 8) {
                        RepeatRuleEditor(
                            kind: $repeatKind,
                            interval: $repeatInterval,
                            weekdays: $repeatWeekdays,
                            end: $repeatEnd,
                            count: $repeatCount,
                            until: $repeatUntil,
                            start: epochDate
                        )
                        .onChange(of: repeatKind) { _, _ in markRepeatTouched() }
                        .onChange(of: repeatInterval) { _, _ in markRepeatTouched() }
                        .onChange(of: repeatWeekdays) { _, _ in markRepeatTouched() }
                        .onChange(of: repeatEnd) { _, _ in markRepeatTouched() }
                        .onChange(of: repeatCount) { _, _ in markRepeatTouched() }
                        .onChange(of: repeatUntil) { _, _ in markRepeatTouched() }

                        if isRecurring {
                            Text("改重复规则属于「改整个系列」，保存时会一起问。")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                labelled("提醒") {
                    VStack(spacing: 10) {
                        Toggle(isOn: $remindersOn) {
                            Text("到点提醒我")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)

                        if remindersOn {
                            FlowRow(spacing: 8) {
                                ForEach([0, 5, 15, 30, 60, 120, 1440], id: \.self) { m in
                                    let on = reminderOffsets.contains(m)
                                    Button {
                                        if on { reminderOffsets.remove(m) } else { reminderOffsets.insert(m) }
                                    } label: {
                                        Text(EditEventSheet.reminderLabel(m))
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
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                }

                if hasChanges {
                    Text("改动会同步到你的其它设备。")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
            }
            .padding(20)
        }
    }

    private var recurringHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "repeat")
                .font(.footnote)
                .foregroundStyle(Theme.amber600)
            VStack(alignment: .leading, spacing: 3) {
                Text("这是重复日程")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.amber600)
                Text("保存时会问你是只改这一次，还是改整个系列。")
                    .font(.caption)
                    .foregroundStyle(Theme.amber600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.amber50)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    private func labelled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 用户是否真的动过「重复」这一栏。
    ///
    /// 见 patch 里的说明：不能靠"算出来的值和原值不同"来判断，
    /// 因为反向解析对复杂规则是**有损**的。只有用户主动改过才提交。
    @State private var repeatTouched = false

    /// 加载期间要屏蔽 onChange 的置位 —— 回填本身也会触发 onChange，
    /// 那样一进页面 repeatTouched 就是 true，等于没起到作用。
    @State private var filling = false

    private var isRecurring: Bool {
        original?.isRecurring ?? false
    }

    /// 表单当前拼出来的开始时间点
    private var epochDate: Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds(date: day, time: time)))
    }

    private static func reminderLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "准点" }
        if minutes >= 1440 && minutes % 1440 == 0 { return "提前 \(minutes / 1440) 天" }
        if minutes >= 60 && minutes % 60 == 0 { return "提前 \(minutes / 60) 小时" }
        return "提前 \(minutes) 分钟"
    }

    private func markRepeatTouched() {
        if !filling && !loading { repeatTouched = true }
    }

    // MARK: - 差异计算

    /// 把当前表单值和原始值比对，**只打包真正变化的字段**。
    ///
    /// 这是这个页面最核心的一段：少了它，每次保存都会把全部字段重写一遍，
    /// 服务端会认为"所有字段都被改了"，并发冲突检测、字段级 seq 全都会乱。
    ///
    /// ⚠️ 比对基线是**实例**的值（重复日程的这一次可能是 override 过的），
    ///    所以时间/时长跟实例比，标题备注这些也跟实例比 ——
    ///    不然「打开没动」也会被算成改动，保存按钮一进去就是亮的。
    private var patch: UpdateEventBody {
        guard original != nil else { return UpdateEventBody() }
        var p = UpdateEventBody()

        if title != (instance.title ?? original?.title ?? "") { p.title = title }

        let baseNotes = instance.notes ?? original?.notes ?? ""
        if notes != baseNotes { p.notes = notes }

        let baseLocation = instance.location ?? original?.location ?? ""
        if location != baseLocation { p.location = location }

        // 日历只跟系列比：实例上的 calendarID 就是系列的
        if let ev = original, calendarID != ev.calendarID, !calendarID.isEmpty {
            p.calendarID = calendarID
        }

        // 时间：只有真的变了才发。拼出来的时间戳要和实例逐秒比对，
        // 否则「打开页面没动，但 picker 把秒归零」会造成假改动
        let newEpoch = epochSeconds(date: day, time: time)
        if newEpoch != instance.startUTC {
            p.dtstartUTC = newEpoch
            p.tzid = TimeZone.current.identifier
        }

        let newDuration = Int64(max(0, minutes) * 60)
        if newDuration != instance.endUTC - instance.startUTC {
            p.durationSec = newDuration
        }

        // 重复规则：只有**用户真的动了这一栏**才提交。
        //
        // ⚠️ 不能简单地「表单算出来的 rrule != 原 rrule 就提交」。
        //    fillRepeat 对认不出的规则（比如别的客户端写的 FREQ=HOURLY）
        //    会退回 .none，那样一进编辑页就变成"改动"，
        //    保存一下就把别人的规则洗成不重复了。
        //    这里用一个显式脏标记，见 repeatTouched。
        if repeatTouched {
            let newRule = RepeatRule.build(
                kind: repeatKind,
                interval: repeatInterval,
                weekdays: repeatWeekdays,
                end: repeatEnd,
                count: repeatCount,
                until: repeatUntil,
                start: epochDate
            ) ?? ""
            if newRule != (original?.rrule ?? "") {
                p.rrule = newRule
            }
        }

        if let ev = original {
            let newOffsets = remindersOn ? reminderOffsets.sorted() : []
            let oldOffsets = ev.reminders.map { Int($0.minutesBefore) }.sorted()
            if newOffsets != oldOffsets {
                p.reminders = newOffsets.map { ReminderDTO(minutesBefore: Int64($0)) }
            }
        }

        return p
    }

    private var hasChanges: Bool { !patch.isEmpty }

    // MARK: - 保存

    private func save() {
        guard original != nil, !saving else { return }
        let p = patch
        // ⚠️ guard 的 else 块必须以 return/throw 结束。
        //    `else { dismiss() }` 编译不过 —— dismiss() 返回 Void，
        //    编译器认为 else 块会「落下去」继续执行后面的代码。
        guard !p.isEmpty else {
            dismiss()
            return
        }

        // 重复日程：改哪一次的影响面差太多了，必须让用户自己选
        if isRecurring {
            pendingPatch = p
            return
        }

        performSave(p, wholeSeries: false)
    }

    private func performSave(_ p: UpdateEventBody, wholeSeries: Bool) {
        saving = true
        failure = nil
        Task {
            do {
                if wholeSeries {
                    let conflicts = try await store.updateEvent(id: instance.eventID, patch: p)
                    if !conflicts.isEmpty {
                        // 有冲突说明别人也改了同一条。服务端已经按字段合并好了，
                        // 这里只提示一声，不当成失败 —— 拒绝保存会让用户白改一遍
                        failure = "已保存。注意：这条日程在其它设备上也刚被修改过，"
                            + "服务端已按字段合并，请刷新确认结果。"
                        saving = false
                        onSaved?()
                        return
                    }
                } else {
                    try await store.updateOccurrence(
                        eventID: instance.eventID,
                        occurrenceKey: instance.occurrenceKey,
                        patch: p
                    )
                }
                saving = false
                onSaved?()
                dismiss()
            } catch {
                failure = store.message(for: error)
                saving = false
            }
        }
    }
}
