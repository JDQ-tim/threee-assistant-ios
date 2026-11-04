import SwiftUI
import UniformTypeIdentifiers

// ============================================================
//  校园数据包（导入 / 切换 / 删除）
//  ------------------------------------------------------------
//  这个页面存在的原因：**地图本身没有"数据从哪来"的入口**。
//  空地图 + 一句"还没有数据"会让人以为功能坏了，而真因是
//  "服务器上有一份包，但你还没把它装到这台手机上"。
//
//  三条导入路径，覆盖三种真实场景：
//    ① 从服务器列表挑 —— 学校已经发布过包，最常见
//    ② 输授权码      —— 管理员只给了你一个码（比如群里发的）
//    ③ 从文件导入    —— 别人直接把 .navpack.json 传给你了
// ============================================================

@MainActor
struct NavPackView: View {

    @Environment(NavPackStore.self) private var nav

    @State private var showPicker = false
    @State private var showFilePicker = false
    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var okText: String?

    var body: some View {
        List {
            activeSection
            importSection
            installedSection

            Section {
                Text("数据包里是一所学校的楼栋坐标。它**只在这台手机上**生效，不跟账号同步 —— 换设备要重新导一次。")
                Text("导入之后，日程里写的地点会自动去包里找楼：「明德楼B1 302」→ 定位到明德楼B1，房号单独显示。认不出时会告诉你相近的有哪些。")
            } header: {
                Text("说明")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("校园数据包")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            NavPackPickerSheet { item in
                showPicker = false
                Task { await installFromServer(item.packID, label: item.name) }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            // fileImporter 的回调不保证在主线程域，显式跳一次。
            // 直接调 handleFile 在严格并发下是"跨 actor 同步调用"。
            Task { @MainActor in handleFile(result) }
        }
        .onAppear { nav.loadIfNeeded() }
    }

    // MARK: - 当前生效

    @ViewBuilder
    private var activeSection: some View {
        Section {
            if let p = nav.activePack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(p.name)
                            .font(.appHeadline)
                            .foregroundStyle(Theme.textPrimary)
                        PillView(text: "使用中", tone: .teal)
                        Spacer(minLength: 0)
                    }
                    Text("\(p.buildings.count) 栋楼 · \(p.withCoordCount) 栋有坐标 · \(p.floorCount) 层 · \(p.roomCount) 间房")
                        .font(.appCaption)
                        .foregroundStyle(Theme.textSecondary)
                    if !p.note.isEmpty {
                        Text(p.note)
                            .font(.appCaption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if p.withCoordCount == 0 {
                        // 静默的坏情况：包导进来了、楼也在，但一栋都没标坐标 ——
                        // 地图会是一片空白，而用户会以为"导入失败了"
                        Text("这个包里一栋楼都没标坐标，地图上不会显示任何东西。请让管理员在标注台上补坐标后重新导出。")
                            .font(.appCaption)
                            .foregroundStyle(Theme.amber600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)

                NavigationLink {
                    CampusMapView()
                } label: {
                    Label("打开校园地图", systemImage: "map")
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "map")
                        .foregroundStyle(Theme.textTertiary)
                    Text("还没有导入数据包")
                        .font(.appSubheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("当前使用")
        }
    }

    // MARK: - 导入

    @ViewBuilder
    private var importSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                Label("从服务器挑一个", systemImage: "icloud.and.arrow.down")
            }
            .disabled(busy)

            HStack(spacing: 10) {
                TextField("授权码（例如 qznu-main）", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.appBody)
                    .onSubmit { startCodeImport() }

                Button("导入") { startCodeImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                showFilePicker = true
            } label: {
                Label("从文件导入（.navpack.json）", systemImage: "doc.badge.plus")
            }
            .disabled(busy)

            if busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在导入…")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let msg = errorText {
                ErrorBanner(message: msg)
            }
            if let msg = okText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.teal600)
                        .font(.footnote)
                    Text(msg)
                        .font(.appFootnote)
                        .foregroundStyle(Theme.teal600)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Theme.teal50)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            }
        } header: {
            Text("导入")
        } footer: {
            Text("授权码就是包里那个标识（小写字母开头）。服务器列表里只有名字和楼栋数，真正的下载要凭码。")
        }
    }

    // MARK: - 已装

    @ViewBuilder
    private var installedSection: some View {
        if nav.packs.count > 0 {
            Section {
                ForEach(nav.packs) { p in
                    Button {
                        nav.setActive(p.packID == nav.activePackID ? nil : p.packID)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.packID == nav.activePackID
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(p.packID == nav.activePackID ? Theme.teal600 : Theme.textTertiary)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name)
                                    .font(.appBody)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(p.buildings.count) 栋 · 版本 \(p.version) · \(importedText(p.importedAt))")
                                    .font(.appCaption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            nav.remove(p.packID)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("已安装（\(nav.packs.count)）")
            } footer: {
                Text("同一时刻只有一个包生效。两个学校的包里都可能有「1 号楼」，同时生效会认错。")
            }
        }
    }

    // MARK: - 动作

    private func startCodeImport() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !c.isEmpty else { return }
        Task { await installFromServer(c, label: c) }
    }

    private func installFromServer(_ packID: String, label: String) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        okText = nil
        defer { busy = false }

        do {
            let text = try await NavService.download(packID: packID)
            let pack = try nav.importPack(text)
            okText = "「\(pack.name)」已导入：\(pack.buildings.count) 栋楼，其中 \(pack.withCoordCount) 栋有坐标。"
            code = ""
        } catch {
            // ⚠️ 用 localizedDescription 而不是自己编一句话：
            //    NavPackError / NavServiceError 的文案都是"下一步该怎么办"，
            //    在这里重新包装只会丢掉那一层。
            errorText = "「\(label)」没有导入成功：\(error.localizedDescription)"
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(e):
            errorText = e.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            // 用户从"文件"App里选的文件在沙箱外，必须先开安全作用域，
            // 否则 read 会直接抛权限错误 —— 而那个错误的文案是"打不开文件"，
            // 完全看不出真正的原因。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    errorText = "这个文件不是 UTF-8 文本 —— 可能选错了文件"
                    return
                }
                let pack = try nav.importPack(text)
                okText = "「\(pack.name)」已导入：\(pack.buildings.count) 栋楼，其中 \(pack.withCoordCount) 栋有坐标。"
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func importedText(_ ts: Int64) -> String {
        guard ts > 0 else { return "时间未知" }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        return DateFormatter.navImport.string(from: d)
    }
}

// MARK: - 服务器上的包

@MainActor
private struct NavPackPickerSheet: View {

    let onPick: (NavPackListItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var items: [NavPackListItem] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取服务器上的包…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = errorText {
                    ScrollView {
                        ErrorBanner(message: msg)
                            .padding(20)
                    }
                } else if items.isEmpty {
                    EmptyHint(
                        icon: "shippingbox",
                        title: "服务器上还没有数据包",
                        subtitle: "让管理员在后台「导航数据包」里传一份，或者用授权码 / 文件导入"
                    )
                } else {
                    List(items) { item in
                        Button {
                            onPick(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(item.name.isEmpty ? item.packID : item.name)
                                        .font(.appBody)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer(minLength: 0)
                                    Text(item.packID)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Text("\(item.buildings) 栋楼（\(item.withCoord) 栋有坐标）· 版本 \(item.version)")
                                    .font(.appCaption)
                                    .foregroundStyle(Theme.textSecondary)
                                if !item.note.isEmpty {
                                    Text(item.note)
                                        .font(.appCaption)
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(2)
                                }
                                if item.keyCarried {
                                    // 包里带着腾讯 Key。iOS 用不上，但值得说一句 ——
                                    // 否则用户会疑惑"为什么安卓要填 Key，这边不用"
                                    Text("这个包里带腾讯地图 Key（iOS 用系统地图，不需要它）")
                                        .font(.appCaption2)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("服务器上的包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            items = try await NavService.list()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 日期格式

extension DateFormatter {
    /// 导入时间只显示到"日"。精确到秒没有意义 ——
    /// 用户看它是为了确认"这是不是我刚导的那个"。
    static let navImport: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月 d 日"
        return f
    }()
}
