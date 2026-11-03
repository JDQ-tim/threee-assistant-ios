import SwiftUI
import EventKit
import UIKit

// ============================================================
//  系统日历（导入 / 导出）
//  ------------------------------------------------------------
//  这一页要回答的四个问题：
//    1. 能不能读系统日历？（权限）
//    2. 导入：把谁的、哪段时间的、导到 3e 的哪张日历？
//    3. 导出：把 3e 的哪些日程写进系统日历？
//    4. 我怎么撤回去？（删掉导入的 / 清空导出的）
//
//  ## 一个必须写在界面上的事实
//
//  EventKit 没有"订阅"能力 —— 第三方 App 不能建订阅日历
//  （只有系统能，靠 `.ics` URL）。所以这里做的是**复制**，
//  不是同步。导完之后两边各自独立。
//
//  不说清楚的话，用户会在系统日历里改一个时间，
//  然后回到 3e 发现没变，得出"这功能是坏的"这个结论。
//  那句话就写在第 2 节标题下面，不埋在脚注里。
// ============================================================

@MainActor
struct SystemCalendarSyncView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var access: SystemCalendarAccess = .notDetermined
    @State private var calendars: [SystemCalendarInfo] = []

    // 导入
    @State private var pickedSystemIDs: Set<String> = []
    @State private var importDays = 30
    @State private var importing = false
    @State private var importPreview: Int?
    @State private var importResult: SystemCalendarSyncResult?
    @State private var importError: String?

    // 导出
    @State private var exportDays = 14
    @State private var exporting = false
    @State private var exportResult: SystemCalendarSyncResult?
    @State private var exportError: String?

    @State private var importedCount = 0
    @State private var exportedCount = 0
    @State private var confirmPurge = false

    private var sys: SystemCalendar { SystemCalendar.shared }
    private var sync: SystemCalendarSync { SystemCalendarSync.shared }

    var body: some View {
        List {
            accessSection

            if access.canRead {
                importSection
            }
            if access.canWrite {
                exportSection
            }
            if access.canRead || access.canWrite {
                historySection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("系统日历")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onChange(of: pickedSystemIDs) { _, _ in recomputePreview() }
        .onChange(of: importDays) { _, _ in recomputePreview() }
    }

    // MARK: - 权限

    @ViewBuilder
    private var accessSection: some View {
        switch access {
        case .notDetermined:
            Section {
                Button {
                    Task { await askAccess() }
                } label: {
                    Label("允许访问日历", systemImage: "calendar.badge.plus")
                }
            } header: {
                Text("权限")
            } footer: {
                Text("要读系统日历才能导入，要写才能导出。iOS 只会问一次。")
            }

        case .denied:
            Section {
                Button {
                    openSystemSettings()
                } label: {
                    Label("去系统设置开启", systemImage: "gear")
                }
            } header: {
                Text("权限")
            } footer: {
                Text("日历权限被关掉了。去「设置 → 3e学习助手 → 日历」里打开。已经拒绝过的权限，App 再问也不会弹框。")
            }

        case .canWriteOnly:
            Section {
                Button {
                    Task { await askAccess() }
                } label: {
                    Label("升级为完全访问", systemImage: "arrow.up.circle")
                }
            } header: {
                Text("权限：仅写入")
            } footer: {
                Text("现在只能往系统日历里写，读不到已有的 —— 所以只能导出，不能导入。要导入请在系统设置里改成「完全访问」。")
            }

        case .full:
            Section {
                LabeledContent("权限", value: "完全访问")
            } footer: {
                Text("可以读也可以写。App 只读写你自己在下面选中的日历；你导入导出的内容也只写到「\(SystemCalendar.oursTitle)」这一张，不会碰你的 iCloud 家庭日历。")
            }
        }
    }

    // MARK: - 导入

    @ViewBuilder
    private var importSection: some View {
        Section {
            if calendars.isEmpty {
                Text("这台设备上没有任何日历。可能还没登录 iCloud，或者日历同步没打开。")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(calendars) { cal in
                    Button {
                        toggle(cal)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pickedSystemIDs.contains(cal.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(pickedSystemIDs.contains(cal.id)
                                                 ? Theme.accent : Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cal.title)
                                    .font(.appBody)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(subtitle(of: cal))
                                    .font(.appCaption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(cal.isReadOnly)
                }
            }

            Picker("导入最近", selection: $importDays) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("一学期（120 天）").tag(120)
            }

            if let n = importPreview {
                LabeledContent("可导入", value: "\(n) 条")
            }

            Button {
                Task { await runImport() }
            } label: {
                Label(importing ? "正在导入…" : "导入选中的日历", systemImage: "square.and.arrow.down")
            }
            .disabled(importing || pickedSystemIDs.isEmpty)

            if let msg = importError {
                Text(msg)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.red600)
            }

            if let r = importResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入完成：\(r.summary)")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                        Text(e)
                            .font(.appCaption)
                            .foregroundStyle(Theme.red600)
                    }
                }
            }
        } header: {
            Text("导入：系统日历 → 3e")
        } footer: {
            Text("导入是**复制**，不是同步。EventKit 不开放订阅能力（只有系统能建 .ics 订阅），所以导进来的是一条条独立的 3e 日程 —— 之后在系统日历里改时间，3e 这边不会跟着变。\n\n重复点「导入」不会产生重复条目：导过的会跳过。重复日程按展开后的每一次分别导入。")
        }
    }

    private func subtitle(of cal: SystemCalendarInfo) -> String {
        var parts: [String] = []
        if !cal.sourceTitle.isEmpty { parts.append(cal.sourceTitle) }
        if cal.isOurs { parts.append("3e 写入的") }
        if cal.isReadOnly { parts.append("只读") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func toggle(_ cal: SystemCalendarInfo) {
        if pickedSystemIDs.contains(cal.id) {
            pickedSystemIDs.remove(cal.id)
        } else {
            pickedSystemIDs.insert(cal.id)
        }
    }

    private func recomputePreview() {
        guard access.canRead, !pickedSystemIDs.isEmpty else {
            importPreview = nil
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(Double(importDays) * 86_400)
        importPreview = sys.fetchEvents(
            from: now, to: end, calendarIDs: Array(pickedSystemIDs)
        ).count
    }

    private func runImport() async {
        importing = true
        importError = nil
        importResult = nil
        defer { importing = false }

        let now = Date()
        let end = now.addingTimeInterval(Double(importDays) * 86_400)
        let events = sys.fetchEvents(
            from: now, to: end, calendarIDs: Array(pickedSystemIDs)
        )
        guard !events.isEmpty else {
            importError = "这段时间内选中的日历里没有事件。"
            return
        }

        importResult = await sync.importEvents(events, into: nil, store: store)
        await reload()
    }

    // MARK: - 导出

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Picker("导出未来", selection: $exportDays) {
                Text("7 天").tag(7)
                Text("14 天").tag(14)
                Text("30 天").tag(30)
            }

            Button {
                Task { await runExport() }
            } label: {
                Label(exporting ? "正在导出…" : "导出到系统日历", systemImage: "square.and.arrow.up")
            }
            .disabled(exporting)

            if let msg = exportError {
                Text(msg)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.red600)
            }

            if let r = exportResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导出完成：\(r.summary)")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                        Text(e)
                            .font(.appCaption)
                            .foregroundStyle(Theme.red600)
                    }
                }
            }
        } header: {
            Text("导出：3e → 系统日历")
        } footer: {
            Text("只写进系统日历里那张叫「\(SystemCalendar.oursTitle)」的日历，没有就自动建一张。你其他的日历里一个条目都不会被改。\n\n导出的日程会出现在锁屏、灵动岛、Apple Watch、Mac 和所有登录了同一个 Apple ID 的设备上。待办不导出 —— 系统日历没有「待办」这个概念，导出成一整天的日历事件只会污染日历。\n\n重复点「导出」是幂等的：同一条日程对应同一个系统事件，只会更新不会重复建。")
        }
    }

    private func runExport() async {
        exporting = true
        exportError = nil
        exportResult = nil
        defer { exporting = false }

        let now = Date()
        let end = now.addingTimeInterval(Double(exportDays) * 86_400)
        let from = Int64(now.timeIntervalSince1970)
        let to = Int64(end.timeIntervalSince1970)

        do {
            let res: InstancesResponse = try await APIClient.shared.get(
                "/api/instances",
                query: [
                    URLQueryItem(name: "from", value: String(from)),
                    URLQueryItem(name: "to", value: String(to)),
                ]
            )
            exportResult = sync.exportInstances(res.instances)
            await reload()
        } catch {
            exportError = "拿不到日程：\(error.localizedDescription)"
        }
    }

    // MARK: - 已导入 / 已导出

    @ViewBuilder
    private var historySection: some View {
        Section {
            if importedCount > 0 {
                LabeledContent("已导入的事件", value: "\(importedCount) 条")
            }
            if exportedCount > 0 {
                LabeledContent("已导出的日程", value: "\(exportedCount) 条")
                Button(role: .destructive) {
                    confirmPurge = true
                } label: {
                    Label("清空「\(SystemCalendar.oursTitle)」日历", systemImage: "trash")
                }
            }
            if importedCount == 0 && exportedCount == 0 {
                Text("还没有导入或导出过。")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text("记录")
        } footer: {
            Text("「清空」只删「\(SystemCalendar.oursTitle)」那张系统日历里的条目，你自己在 iCloud 或其他日历里建的东西不受影响。3e 这边的日程也不会被删。")
        }
        .confirmationDialog(
            "清空「\(SystemCalendar.oursTitle)」里的全部条目？",
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                _ = sync.removeAllExported()
                exportedCount = 0
                exportResult = nil
                Task { await reload() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("系统日历里这 \(exportedCount) 条会被删掉。3e 里的日程不受影响，下次还能再导一次。")
        }
    }

    // MARK: - 动作

    private func reload() async {
        access = SystemCalendar.access()
        calendars = sys.listCalendars()
        importedCount = ImportedEventMap.shared.count
        exportedCount = ExportedEventMap.shared.count
        // 权限刚拿到时，默认把非只读的日历全选上 —— 用户来这一页
        // 通常就是想"把我现在的课表弄进来"，让他一个个点只是折磨。
        if pickedSystemIDs.isEmpty {
            pickedSystemIDs = Set(calendars.filter { !$0.isReadOnly }.map(\.id))
        }
        recomputePreview()
    }

    private func askAccess() async {
        access = await sys.requestAccess()
        await reload()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
