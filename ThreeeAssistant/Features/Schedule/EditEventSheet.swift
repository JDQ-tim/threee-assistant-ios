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
        } catch {
            failure = store.message(for: error)
            loadFailed = true
        }
        loading = false
    }

    private var loadErrorView: some View {
        VStack(spacing: 14) {
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

    private var isRecurring: Bool {
        original?.isRecurring ?? false
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

        return p
    }

    private var hasChanges: Bool { !patch.isEmpty }

    // MARK: - 保存

    private func save() {
        guard original != nil, !saving else { return }
        let p = patch
        guard !p.isEmpty else { dismiss() }

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
