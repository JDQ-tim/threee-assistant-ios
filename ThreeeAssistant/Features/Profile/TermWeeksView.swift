import SwiftUI

// ============================================================
//  教学周设置
//  ------------------------------------------------------------
//
//  「这是第几周」不是日历上的客观事实 —— 它完全取决于「第 1 周从哪天算起」,
//  而这个起点每所学校都不一样:
//
//    - 有的按**正式上课那天**算（可能是周三）
//    - 有的按开学典礼那一周的周一
//    - 有的开学前一周就算第 1 周（军训周）
//    - 少数学校用**周日**为一周之始
//
//  所以这里不猜，也不做「自动识别」——一个猜错的周次比没有周次更糟,
//  用户会照着错的单双周去上课。
//
//  ⚠️ 起点存的是**周一的 00:00**，不是用户选的那一天。
//     用户可能选周三（开学典礼），若直接拿周三当锚点，
//     之后每周的差值都会错一天，表现为「周三设的第 1 周，周日变第 2 周」。
//     归一化在 `WeekNumbering.anchor` 的 setter 里做。
//
//  ⚠️ 这个设置只存在**本机**（UserDefaults），不跟账号走。
//     iOS 端没有改服务端的能力（那是别人的项目），
//     页面上要明确写清「这台设备」，换手机要重填。
// ============================================================

@MainActor
struct TermWeeksView: View {

    @Environment(\.dismiss) private var dismiss

    /// 编辑器里暂存的值。点「保存」才落到 UserDefaults ——
    /// 日期选择器是连续变化的（拖动时就一直在触发），
    /// 边拖边存会让顶部周次跟着乱跳。
    @State private var anchor: Date = WeekNumbering.anchor ?? Date.now.startOfWeekMonday
    @State private var hasAnchor: Bool = WeekNumbering.anchor != nil
    @State private var totalWeeks: Int = WeekNumbering.totalWeeks

    @State private var showClearConfirm = false

    /// 学期总周数的可选范围。18 周是本科最常见的，21 周左右多见于医学/工科。
    private let totalChoices = Array(0...30)

    var body: some View {
        Form {
            previewSection
            anchorSection
            totalSection
            if hasAnchor { dangerSection }
            explainSection
        }
        .navigationTitle("教学周")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(!hasAnchor)
            }
        }
        .confirmationDialog("清除教学周设置？", isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                WeekNumbering.anchor = nil
                WeekNumbering.totalWeeks = 0
                hasAnchor = false
                totalWeeks = 0
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("日程页顶部会变回「设置教学周」。已建好的单双周日程本身不受影响。")
        }
    }

    // MARK: - 实时预览

    /// 让用户在点保存**之前**就看到「今天算第几周」。
    ///
    /// 这是本页最重要的一块：用户填锚点时的心理是「我填的对不对」,
    /// 只给一个日期选择器他心里没底，给一行「今天 = 第 8 周 · 双周」
    /// 他立刻能验证。
    private var previewSection: some View {
        Section {
            HStack {
                Text("今天")
                    .font(.appBody)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if hasAnchor {
                    let idx = WeekNumbering.weekIndex(for: .now, anchor: anchor)
                    let idxText = idx.map { $0 > 0 ? "第 \($0) 周" : "还没开学" } ?? "—"
                    Text(idxText)
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(idx.map { $0 > 0 } == true ? Theme.textPrimary : Theme.textTertiary)
                        .monospacedDigit()

                    if let i = idx, i > 0 {
                        let p = WeekNumbering.parity(ofWeek: i)
                        Text(p.label)
                            .font(.appBadge)
                            .foregroundStyle(p == .odd ? Theme.blue600 : Theme.teal600)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(p == .odd ? Theme.blue50 : Theme.teal50)
                            .clipShape(Capsule())
                    }
                } else {
                    Text("未设置")
                        .font(.appBody)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if hasAnchor, totalWeeks > 0,
               let idx = WeekNumbering.weekIndex(for: .now, anchor: anchor), idx > totalWeeks {
                // 超出总周数不是错误，只是常见于「用户填错了学期」或「真放假了」。
                // 用提醒色而不是错误色 —— 不该吓得用户去改什么。
                Label("已超过设定的 \(totalWeeks) 周，检查一下起点是否填成了上一个学期。",
                      systemImage: "exclamationmark.circle")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.amber600)
            }
        } header: {
            Text("预览")
        }
    }

    // MARK: - 起点

    private var anchorSection: some View {
        Section {
            Toggle(isOn: $hasAnchor.animation()) {
                Text("启用教学周")
                    .font(.appBody)
            }

            if hasAnchor {
                DatePicker(
                    "第 1 周（周一）",
                    selection: Binding(
                        get: { anchor.startOfWeekMonday },
                        set: { anchor = $0.startOfWeekMonday }
                    ),
                    displayedComponents: .date
                )
                .font(.appBody)

                // 用户选一天，我们按「那天的周一」算。
                // 这一行把它明说出来 —— 否则用户选了周三、周日却看到「第 2 周」，
                // 会以为算错了。归一是刻意的，但要让它可见。
                HStack {
                    Text("按整周计算")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("\(anchor.startOfWeekMonday.monthDay) 起，每周一换周次")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } header: {
            Text("起点")
        } footer: {
            Text("选开学第一周里**任意一天**即可，会自动归到那一周的周一。若学校按开学典礼那天起算，选那天就行。")
        }
    }

    // MARK: - 总周数

    private var totalSection: some View {
        Section {
            Picker("学期总周数", selection: $totalWeeks) {
                Text("不限制").tag(0)
                ForEach(totalChoices.dropFirst(), id: \.self) { n in
                    Text("\(n) 周").tag(n)
                }
            }
            .font(.appBody)
            .disabled(!hasAnchor)
        } footer: {
            Text("只影响显示（「第 8/18 周」），不影响任何日程。不确定就选「不限制」。")
        }
    }

    // MARK: - 清除

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Text("清除教学周设置")
                    .font(.appBody)
            }
        }
    }

    // MARK: - 说明

    private var explainSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                bullet("单周 / 双周按**第几周的奇偶**判定，不是按日历周。",
                       "所以「第 1、3、5 周」永远是单周，跨年也不会跳。")
                bullet("这个设置只在这台设备上生效。",
                       "换手机、重装 App 需要重填一次。它不会同步到服务端，也不会影响别人。")
                bullet("从网页或 ICS 导入的日程照样受它影响。",
                       "单双周标记是建日程时存进去的，导入的日程如果没带这个信息，就按每周显示。")
            }
            .padding(.vertical, 2)
        } header: {
            Text("说明")
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Markdown 让 **粗体** 生效，比拆成两个 Text 简单
            Text(.init(title))
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Text(detail)
                .font(.appFootnote)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 保存

    private func save() {
        WeekNumbering.anchor = anchor
        WeekNumbering.totalWeeks = totalWeeks
        dismiss()
    }
}
