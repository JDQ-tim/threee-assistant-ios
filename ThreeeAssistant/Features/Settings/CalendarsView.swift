import SwiftUI

/// 日历管理：新建 / 改名改色 / 删除。
///
/// ## 为什么单独一页而不是塞进设置里
///
/// 日历是日程的"容器"，改它比改账号设置频繁得多。塞进设置页深处的话，
/// 用户想给新课建个日历得翻三层，最后干脆全堆在默认日历里，
/// 之后永远分不清哪些课在哪。
@MainActor
struct CalendarsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // 色点要按当前外观取色（深色下用亮一档的那套），所以要读 colorScheme。
    @Environment(\.colorScheme) private var scheme

    @State private var editing: CalendarDTO?
    @State private var creating = false
    @State private var pendingDelete: CalendarDTO?
    @State private var busy = false
    @State private var failure: String?

    /// 点开成员页的那张日历。
    /// 用 item 驱动 navigationDestination，这样行内那个小按钮
    /// 不必被包进 NavigationLink（包进去整行点击都会被它抢走）
    @State private var membersOf: CalendarDTO?

    var body: some View {
        List {
            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(store.calendars) { cal in
                    calendarCard(cal)
                        // 卡片化：把 List 自带的行底色/分隔线/内边距全部让掉，
                        // 只借它做滚动和左滑。否则卡片外面还会套一层灰底，
                        // 看起来像"卡片里又有一行"。
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            // 只有 owner 才有删除权。给所有人显示一个必然失败的按钮
                            // 比不显示更糟 —— 用户会以为是网络问题。
                            if cal.canManage {
                                Button(role: .destructive) {
                                    pendingDelete = cal
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                }
            } header: {
                Text("我的日历")
            } footer: {
                Text("点卡片上半部分改名改色。「分享」进去加人，只有你和被加的人能看。\n左滑可删除自己创建的日历；别人分享给你的不能删，只能在成员页退出。")
            }

            Section {
                Button {
                    creating = true
                } label: {
                    Label("新建日历", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("我的日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $creating) {
            CalendarEditSheet(calendar: nil)
        }
        .navigationDestination(item: $membersOf) { cal in
            CalendarMembersView(calendarID: cal.id)
        }
        .sheet(item: $editing) { cal in
            CalendarEditSheet(calendar: cal)
        }
        .alert("删除这个日历？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { cal in
            Button("删除", role: .destructive) {
                performDelete(cal)
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { cal in
            Text("「\(cal.name)」以及里面所有日程都会被删除，其它设备同步后也会消失。\n\n这个操作撤不回来。")
        }
    }

    /// 一张日历卡。
    ///
    /// 视觉照安卓端：色点 + 名字，第二行是「私有 · 我创建的」这种身份说明，
    /// 再下面一排动作按钮。用卡片而不是 List 行，是因为**动作要直接露出来** ——
    /// 藏在左滑里的「改名」没人会发现，而改名是这个页面最常用的操作。
    private func calendarCard(_ cal: CalendarDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if cal.canManage { editing = cal }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(CalendarPalette.display(cal.displayColor, dark: scheme == .dark))
                            .frame(width: 10, height: 10)
                        Text(cal.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(subtitle(cal))
                        .font(.appCaption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 整块可点，但只有 owner 真有反应 —— 只读日历点了什么都不发生，
                // 所以给个禁用态而不是静默无反应。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!cal.canManage)

            HStack(spacing: 14) {
                if cal.canManage {
                    Button("改名 / 改色") { editing = cal }
                    Button("分享") { membersOf = cal }
                    Button("删除日历") { pendingDelete = cal }
                        .foregroundStyle(Theme.red600)
                } else {
                    // 只读日历没有可做的动作，就明说为什么 ——
                    // 留一行空白按钮会让人以为加载失败。
                    Text(cal.ownerName.map { "只能看 · \($0) 维护" } ?? "只能看")
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)

                if cal.kind == "course" {
                    NavigationLink {
                        CourseTableView(calendar: cal)
                    } label: {
                        Text("打开课表")
                            .foregroundStyle(Theme.blue600)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.appFootnote)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.blue600)
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .stroke(Theme.separator, lineWidth: 0.5))
    }

    private func subtitle(_ cal: CalendarDTO) -> String {
        var parts: [String] = []
        parts.append(kindLabel(cal.kind))
        if let n = cal.members?.count, n > 1 {
            parts.append("\(n) 人")
        }
        if !cal.canManage, let owner = cal.ownerName, !owner.isEmpty {
            parts.append("来自 \(owner)")
        }
        return parts.joined(separator: " · ")
    }

    private func kindLabel(_ kind: String?) -> String {
        switch kind {
        case "course": return "课程表"
        case "shared": return "共享"
        default: return "私人"
        }
    }

    private func performDelete(_ cal: CalendarDTO) {
        busy = true
        failure = nil
        pendingDelete = nil
        Task {
            do {
                try await store.deleteCalendar(id: cal.id)
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}

/// 新建 / 编辑一个日历。
///
/// `calendar == nil` 是新建，否则是修改。
@MainActor
struct CalendarEditSheet: View {

    let calendar: CalendarDTO?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var name = ""
    @State private var color = CalendarPalette.defaultLight
    @State private var kind = "private"
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false

    /// 系统取色器。
    ///
    /// 为什么要它：色板只有 16 个，而"给每门课一个颜色"的人会用到十几种。
    /// 安卓端也是「色板 + 自定义」两个入口。服务端字段就是自由的
    /// `#RRGGBB`（`CalendarDTO.display_color`），不限制成枚举。
    ///
    /// ⚠️ 取色器给的是**存进去的那套**（浅色档），不是深色显示档 ——
    ///    深色档是衍生的，不进服务端。见 `CalendarPalette` 文件头。
    @State private var pickingCustom = false
    @State private var customColor = Color.blue

    private var isNew: Bool { calendar == nil }

    /// 当前这个颜色在色板里吗。不在就是用户自定义的。
    private var isCustomColor: Bool {
        !CalendarPalette.swatches.contains {
            $0.light.caseInsensitiveCompare(color) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let msg = failure {
                        ErrorBanner(message: msg)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("名称")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 2)
                        TextField("例如：大二上课程表", text: $name)
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("颜色")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 2)

                        // 色板 + 自定义。
                        //
                        // ⚠️ 色块画的是**深色档**（`swatch.dark`）而不是
                        //    存进服务端的那一档：用户选色的时候看的就是
                        //    深色背景上的效果，拿浅色档画会出现
                        //    "选的时候挺亮，选了之后变暗"。
                        FlowRow(spacing: 10) {
                            ForEach(CalendarPalette.swatches, id: \.light) { sw in
                                let on = color.caseInsensitiveCompare(sw.light) == .orderedSame
                                Button {
                                    color = sw.light
                                } label: {
                                    Circle()
                                        .fill(CalendarPalette.display(sw.light, dark: scheme == .dark))
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            Circle()
                                                .stroke(Theme.textPrimary.opacity(on ? 0.55 : 0),
                                                        lineWidth: 2)
                                                .padding(-3)
                                        )
                                        .overlay(
                                            // 勾用深色而不是白色：深色档那些亮色块
                                            // 上白勾几乎看不见（黄、青、草绿）
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(Color(hexString: "#1A1A18"))
                                                .opacity(on ? 1 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(sw.name)
                            }
                        }

                        // 自定义色：第 17 个色块，永远排在色板后面。
                        Button {
                            // 打开取色器时用当前值起手 —— 从随机色开始的
                            // 取色器会让人第一眼就迷路
                            customColor = Color(hexString: color)
                            pickingCustom = true
                        } label: {
                            HStack(spacing: 7) {
                                ZStack {
                                    Circle()
                                        .fill(isCustomColor
                                              ? CalendarPalette.display(color, dark: scheme == .dark)
                                              : Theme.surfaceAlt)
                                        .frame(width: 22, height: 22)
                                    Image(systemName: isCustomColor ? "checkmark" : "plus")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(isCustomColor
                                                         ? Color(hexString: "#1A1A18")
                                                         : Theme.textSecondary)
                                }
                                Text(isCustomColor ? "自定义 · \(color.uppercased())" : "自定义颜色")
                                    .font(.appFootnote)
                                    .foregroundStyle(Theme.blue600)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall,
                                                        style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Text("颜色只是给你自己分清楚哪几天是同一类事，不会同步给别人看。")
                            .font(.caption2)
                            .foregroundStyle(Theme.hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("类型")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 2)
                        Picker("类型", selection: $kind) {
                            Text("私人").tag("private")
                            Text("课程表").tag("course")
                            Text("共享").tag("shared")
                        }
                        .pickerStyle(.segmented)
                        // ⚠️ kind 只有 owner 能改（服务端 2026-10-20 收紧）。
                        //    共享给我的日历就别让他点了，点了必然 403。
                        .disabled(!isNew && !(calendar?.canManage ?? false))

                        Text("课程表会在课程的节次视图里更好用；共享日历建好后可以邀请别人。")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle(isNew ? "新建日历" : "编辑日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "保存中…" : "保存") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let c = calendar {
                    name = c.name
                    color = c.displayColor
                    kind = c.kind ?? "private"
                }
            }
            // 系统取色器用 sheet 挂出来，不用 navigationDestination：
            // 它是一个"临时的选择面板"，选完就回去，不该进导航栈。
            .sheet(isPresented: $pickingCustom) {
                customColorSheet
            }
        }
    }

    /// 取色器面板。
    ///
    /// 用 SwiftUI 的 `ColorPicker`（背后是系统的 UIColor 面板），
    /// 而不是自己画一个色轮 —— 系统那个支持取色器吸管、
    /// 支持"从屏幕其他 App 取色"，自己画的做不到，也没必要。
    private var customColorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                ColorPicker("选一个颜色", selection: $customColor, supportsOpacity: false)
                    .font(.appBody)

                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(customColor)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hexString(customColor))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        Text("深色模式下会自动提亮一档，不会刺眼。")
                            .font(.caption2)
                            .foregroundStyle(Theme.hint)
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("自定义颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pickingCustom = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("用这个") {
                        color = hexString(customColor)
                        pickingCustom = false
                    }
                }
            }
        }
    }

    /// `Color` → `#RRGGBB`。
    ///
    /// ⚠️ 必须用 `UIColor` 拿分量，不能自己 `Color` → `Codable`。
    ///    理由：`Color` 是个不透明的协议值，只有转成 `UIColor`
    ///    才能保证拿到 sRGB 分量；直接反射 `components` 在
    ///    某些色彩空间下会返回 nil。
    ///
    /// ⚠️ `supportsOpacity: false` 是配合这个函数的 ——
    ///    服务端存的是 6 位 `#RRGGBB`，带 alpha 的话存进去会变成
    ///    不是合法格式，读取时回落到默认蓝，用户会以为"选了没用"。
    private func hexString(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return CalendarPalette.defaultLight
        }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }

        busy = true
        failure = nil

        Task {
            do {
                if let c = calendar {
                    // 只提交真的变了的字段。全量提交会让 editor 因为
                    // "带了 kind" 而被 403 —— 见 models.go 里 2026-10-20 那条注释
                    try await store.updateCalendar(
                        id: c.id,
                        name: trimmed != c.name ? trimmed : nil,
                        // ⚠️ 比较时忽略大小写：服务端回的是大写，
                        //    而用户没动过颜色时 `color` 也是大写 ——
                        //    但万一哪天回了小写，这里就会误判成"改过"
                        color: color.caseInsensitiveCompare(c.displayColor) == .orderedSame
                            ? nil : color,
                        kind: (c.canManage && kind != (c.kind ?? "private")) ? kind : nil
                    )
                } else {
                    try await store.createCalendar(name: trimmed, color: color, kind: kind)
                }
                dismiss()
            } catch {
                failure = store.message(for: error)
            }
            busy = false
        }
    }
}
