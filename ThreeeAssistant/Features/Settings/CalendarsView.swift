import SwiftUI

/// 日历管理：新建 / 改名改色 / 删除。
///
/// ## 为什么单独一页而不是塞进设置里
///
/// 日历是日程的"容器"，改它比改账号设置频繁得多。塞进设置页深处的话，
/// 用户想给新课建个日历得翻三层，最后干脆全堆在默认日历里，
/// 之后永远分不清哪些课在哪。
struct CalendarsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var editing: CalendarDTO?
    @State private var creating = false
    @State private var pendingDelete: CalendarDTO?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
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
                        // 课程表日历单独给一个「打开课表」入口 ——
                        // 它和普通日历的读法完全不同（节次 × 星期网格），
                        // 塞进日程页的周/月 Picker 里会把那三个选项变成四选一，
                        // 而且课表自己也要翻周，两套翻页逻辑会打架。
                        if cal.kind == "course" {
                            NavigationLink {
                                CourseTableView(calendar: cal)
                            } label: {
                                row(cal)
                            }
                            .swipeActions(edge: .trailing) {
                                if cal.canManage {
                                    Button(role: .destructive) {
                                        pendingDelete = cal
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        } else {
                            Button {
                                editing = cal
                            } label: {
                                row(cal)
                            }
                            .buttonStyle(.plain)
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
                    }
                } footer: {
                    Text("左滑可删除自己创建的日历。别人分享给你的日历不能删，只能退出。\n点「课程表」日历可直接打开课表网格。")
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
    }

    private func row(_ cal: CalendarDTO) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hexString: cal.displayColor))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(cal.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle(cal))
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            if cal.canManage {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("共享")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceAlt)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
struct CalendarEditSheet: View {

    let calendar: CalendarDTO?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = "#185FA5"
    @State private var kind = "private"
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false

    private var isNew: Bool { calendar == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let msg = failure {
                        ErrorBanner(message: msg)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("名称")
                            .font(.system(size: 12.5))
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
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 2)

                        // 给一组固定色板而不是完整取色器：
                        // 日程列表里靠颜色区分日历，色板太自由反而让人选出
                        // 一堆相近的颜色，最后分不出来
                        FlowRow(spacing: 10) {
                            ForEach(Self.palette, id: \.self) { hex in
                                let on = color.uppercased() == hex.uppercased()
                                Button {
                                    color = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hexString: hex))
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            Circle()
                                                .stroke(Theme.textPrimary.opacity(on ? 0.55 : 0),
                                                        lineWidth: 2)
                                                .padding(-3)
                                        )
                                        .overlay(
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(.white)
                                                .opacity(on ? 1 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("类型")
                            .font(.system(size: 12.5))
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
        }
    }

    private static let palette = [
        "#185FA5", "#0F6E56", "#854F0B", "#A32D2D",
        "#534AB7", "#993556", "#3B6D11", "#5F5E5A",
    ]

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
                        color: color.uppercased() != c.displayColor.uppercased() ? color : nil,
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
