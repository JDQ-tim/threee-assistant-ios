import SwiftUI

// ============================================================
//  节假日与调休
//  ------------------------------------------------------------
//
//  内置表只到 2027 年。**2028 年及以后的安排我无从得知** ——
//  国务院每年 11 月前后才发，而且每年都不一样。
//
//  所以这一页的核心不是"展示内置数据"，而是**让用户能自己补**。
//  设计上围绕三件事：
//
//    1. 今年有没有数据，一眼可见（没有就直接告诉你，而不是装作没有假日）
//    2. 加一个假日只要选起止日 + 填名字，不要求任何术语
//    3. 调休日能改「上星期几的课」，因为全国公布的是"10月10日上班"，
//       而上周三还是上周四的课，**是各校自己定的**
//
//  ⚠️ 所有修改只影响本机显示，不会写回服务端。
//     页面上要明说这一点，否则用户会担心"我在这改了会不会影响别人"。
// ============================================================

@MainActor
struct HolidaysView: View {

    @Environment(SessionStore.self) private var store

    @State private var rules: [HolidayRule] = HolidayCalendar.allRules
    @State private var makeups: [MakeupDay] = HolidayCalendar.allMakeups

    @State private var showAddHoliday = false
    @State private var editingMakeup: MakeupDay?

    /// 新增假日表单
    @State private var newStart = Date.now.startOfDay
    @State private var newEnd = Date.now.startOfDay
    @State private var newName = ""

    private let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        List {
            coverageSection
            holidaySection
            makeupSection
            explainSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("节假日与调休")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddHoliday = true
                    } label: {
                        Label("添加假日", systemImage: "calendar.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddHoliday) {
            addHolidaySheet
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingMakeup) { m in
            MakeupEditSheet(day: m) { newWorkAs in
                applyMakeupEdit(m, workAs: newWorkAs)
            }
            .presentationDetents([.height(320)])
        }
        .onAppear {
            rules = HolidayCalendar.allRules
            makeups = HolidayCalendar.allMakeups
        }
    }

    // MARK: - 覆盖情况

    /// 这一块是整个页面的"诚实声明"。
    ///
    /// 内置表只到 2027。如果不说，用户 2028 年打开会发现假日全部失效，
    /// 而界面看起来一切正常 —— 那是最糟的失败方式（静默错误）。
    private var coverageSection: some View {
        Section {
            if HolidayCalendar.coveredYears.contains(thisYear) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.teal600)
                    Text("\(String(thisYear)) 年的假日数据已内置")
                        .font(.appBody)
                        .foregroundStyle(Theme.textPrimary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.amber600)
                        Text("\(String(thisYear)) 年没有假日数据")
                            .font(.appBody.weight(.medium))
                            .foregroundStyle(Theme.amber600)
                    }
                    Text("内置数据只到 2027 年。这一年的放假安排公布后，请点右上角 + 添加，否则节假日不会自动跳过。")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // 用户自己加过的，也给个计数，让他知道自己改过什么
            let mine = rules.filter { !$0.builtin }.count
            if mine > 0 {
                Text("你自己添加了 \(mine) 条")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
            }
        } header: {
            Text("\(String(thisYear)) 年")
        }
    }

    // MARK: - 假日

    private var holidaySection: some View {
        Section {
            if rules.isEmpty {
                Text("还没有任何假日数据")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(groupedByYear, id: \.0) { year, list in
                DisclosureGroup {
                    ForEach(list) { r in
                        holidayRow(r)
                    }
                    .onDelete { idx in
                        deleteRules(list, at: idx)
                    }
                } label: {
                    HStack {
                        Text("\(String(year)) 年")
                            .font(.appBody)
                        Spacer()
                        Text("\(list.count) 段")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        } header: {
            Text("法定节假日")
        } footer: {
            Text("这些日子当天的日程会自动隐藏（待办不隐藏）。左滑可以删掉自己加的条目。")
        }
    }

    private var groupedByYear: [(Int, [HolidayRule])] {
        let dict = Dictionary(grouping: rules) { Int($0.start.prefix(4)) ?? 0 }
        return dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func holidayRow(_ r: HolidayRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name)
                    .font(.appBody)
                    .foregroundStyle(Theme.textPrimary)
                Text(r.start == r.end
                     ? shortDate(r.start)
                     : "\(shortDate(r.start)) – \(shortDate(r.end))")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            Spacer()
            if !r.builtin {
                Text("自加")
                    .font(.appBadge)
                    .foregroundStyle(Theme.blue600)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.blue50)
                    .clipShape(Capsule())
            }
        }
    }

    /// `2026-10-01` → `10月1日`
    private func shortDate(_ key: String) -> String {
        guard let d = Date.fromDateKey(key) else { return key }
        return d.monthDay
    }

    // MARK: - 调休

    private var makeupSection: some View {
        Section {
            if makeups.isEmpty {
                Text("这几年没有调休上班日")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(makeups) { m in
                Button {
                    editingMakeup = m
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.name)
                                    .font(.appBody)
                                    .foregroundStyle(Theme.textPrimary)
                                if !m.builtin {
                                    Text("自改")
                                        .font(.appBadge)
                                        .foregroundStyle(Theme.blue600)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Theme.blue50)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(makeupSubtitle(m))
                                .font(.appFootnote)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("调休上班日")
        } footer: {
            Text("这些是周末被征用来上班的日子。点进去可以选「补星期几的课」—— 全国只公布哪几天上班，补哪天的课是各校自己排的，所以这里让你改。")
        }
    }

    private func makeupSubtitle(_ m: MakeupDay) -> String {
        let date = Date.fromDateKey(m.date)?.monthDay ?? m.date
        guard let w = m.workAs else { return "\(date) · 不补课" }
        let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let label = (1...7).contains(w) ? names[w] : "周?"
        return "\(date) · 补\(label)的课"
    }

    private func applyMakeupEdit(_ original: MakeupDay, workAs: Int?) {
        var copy = original
        copy.workAs = workAs
        // 用户改过的一律标成非内置，并进入 userMakeups（同 id 覆盖内置）
        var user = HolidayCalendar.userMakeups
        let stored = MakeupDay(id: copy.id, date: copy.date, name: copy.name,
                               workAs: workAs, builtin: false)
        if let i = user.firstIndex(where: { $0.id == copy.id }) {
            user[i] = stored
        } else {
            user.append(stored)
        }
        HolidayCalendar.userMakeups = user
        store.reloadHolidays()
        makeups = HolidayCalendar.allMakeups
    }

    // MARK: - 说明

    private var explainSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                note("假日当天的日程只是**不显示**，没有删除。",
                     "把假日删掉，那天的事立刻回来。服务端数据一个字节都没动。")
                note("补课那天显示的是**被补的那一天**的日程。",
                     "比如 10 月 10 日上周三的课，这天就会列出周三原本的安排。")
                note("待办不受影响。",
                     "一个 10 月 1 日到期的待办不会因为放假就消失 —— 它和「哪天有课」不是一回事。")
                note("只在这台设备生效。",
                     "不会同步到服务端，也不影响和你共享日历的人。")
            }
            .padding(.vertical, 2)
        } header: {
            Text("说明")
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(.init(title))
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Text(detail)
                .font(.appFootnote)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 添加假日

    private var addHolidaySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，如「国庆节」", text: $newName)
                        .font(.appBody)
                    DatePicker("开始", selection: $newStart,
                               displayedComponents: .date)
                        .font(.appBody)
                    DatePicker("结束", selection: $newEnd,
                               in: newStart..., displayedComponents: .date)
                        .font(.appBody)
                } footer: {
                    Text("单日假把开始和结束选成同一天。「结束」不能早于「开始」。")
                }

                Section {
                    Button {
                        addHoliday()
                    } label: {
                        Text("添加")
                            .font(.appBody.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canAdd)
                } footer: {
                    if !canAdd {
                        Text("请填写名称。")
                            .foregroundStyle(Theme.amber600)
                    }
                }
            }
            .navigationTitle("添加假日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddHoliday = false }
                }
            }
        }
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addHoliday() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // id 用「用户 + 起始日」，重复添加同一天的会覆盖而不是堆两条
        let rule = HolidayRule(id: "user-\(newStart.dateKey)",
                               start: newStart.dateKey,
                               end: newEnd.dateKey,
                               name: name,
                               builtin: false)

        var user = HolidayCalendar.userRules
        user.removeAll { $0.id == rule.id }
        user.append(rule)
        HolidayCalendar.userRules = user

        store.reloadHolidays()
        rules = HolidayCalendar.allRules

        newName = ""
        showAddHoliday = false
    }

    private func deleteRules(_ list: [HolidayRule], at offsets: IndexSet) {
        // 只能删自己加的。内置的删了，下次 App 更新会"复活"，
        // 用户会以为删除失败 —— 与其这样不如明确不许删。
        let removable = offsets.map { list[$0] }.filter { !$0.builtin }
        guard !removable.isEmpty else { return }
        let ids = Set(removable.map(\.id))
        HolidayCalendar.userRules = HolidayCalendar.userRules.filter {
            !ids.contains($0.id)
        }
        store.reloadHolidays()
        rules = HolidayCalendar.allRules
    }
}

// MARK: - 改调休日补哪天的课

@MainActor
private struct MakeupEditSheet: View {

    let day: MakeupDay
    let onSave: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workAs: Int?

    init(day: MakeupDay, onSave: @escaping (Int?) -> Void) {
        self.day = day
        self.onSave = onSave
        _workAs = State(initialValue: day.workAs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 用「不补课」而不是「无」。前者是用户能理解的意图。
                    Picker("补哪天的课", selection: $workAs) {
                        Text("不补课").tag(Int?.none)
                        Text("周一").tag(Int?.some(2))
                        Text("周二").tag(Int?.some(3))
                        Text("周三").tag(Int?.some(4))
                        Text("周四").tag(Int?.some(5))
                        Text("周五").tag(Int?.some(6))
                        Text("周六").tag(Int?.some(7))
                        Text("周日").tag(Int?.some(1))
                    }
                    .font(.appBody)
                } footer: {
                    Text("选「不补课」的话，这天就当作普通的一天，除了原本排在这天的日程之外不多显示任何东西。")
                }
            }
            .navigationTitle(day.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(workAs)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
