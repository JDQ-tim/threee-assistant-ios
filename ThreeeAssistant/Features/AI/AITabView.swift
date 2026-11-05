import SwiftUI
import UIKit

// ============================================================
//  AI
//  ------------------------------------------------------------
//  这一页目前做的是**机器接口（API Key）**，不是聊天。
//
//  ## 为什么先做这个、而不是先做一个聊天框
//
//  服务端**没有** `/api/ai/*`。安卓端那个「AI」对话是客户端自己拿
//  用户填的模型 Key 去调第三方的 —— 也就是说，聊天功能要先有一整套
//  「模型选择 + 密钥管理 + 上下文 + 工具调用」的本地实现。
//  那不是一个 Tab 的量。
//
//  而 `/api/ext` 是**服务端已经做好**的东西：它让任何外部程序
//  （包括 AI、脚本、别的客户端）用一把 Key 读写日程。安卓端的
//  「设置 → AI」就是这一页。**先把它做对，聊天之后才好接** ——
//  否则 AI 那边每次都要重新教一遍"怎么读你的课表"。
//
//  ## Key 的显示规则（跟服务端一致）
//
//  完整 Key **只显示一次**（`extapi.go:157`：服务器只存哈希）。
//  所以生成之后必须当场给用户复制走，离开这一页就再也看不到了。
//  这个约束必须在界面上说出来，不然用户会以为"以后还能回来查"。
// ============================================================

@MainActor
struct AITabView: View {

    @Environment(SessionStore.self) private var store

    @State private var keys: [APIKeyRow] = []
    @State private var loading = false
    @State private var failure: String?

    /// 刚生成出来的那把完整 Key。非 nil 时弹一次性的复制卡片。
    @State private var freshKey: String?
    @State private var newName = ""
    @State private var creating = false
    @State private var pendingRevoke: APIKeyRow?

    var body: some View {
        NavigationStack {
            List {
                machineSection
                keySection
                chatNotice
            }
            .listStyle(.insetGrouped)
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .refreshable { await load() }
            .alert("新建 API Key", isPresented: $creating) {
                TextField("Key 名称（比如「我的笔记本」）", text: $newName)
                Button("生成") { Task { await create() } }
                Button("取消", role: .cancel) { newName = "" }
            } message: {
                Text("名称只是给你自己看的，方便以后知道哪一把该撤销。")
            }
            .alert("这把 Key 之后看不到了", isPresented: Binding(
                get: { freshKey != nil },
                set: { if !$0 { freshKey = nil } }
            )) {
                Button("复制") {
                    UIPasteboard.general.string = freshKey ?? ""
                    freshKey = nil
                }
                Button("知道了", role: .cancel) { freshKey = nil }
            } message: {
                Text(freshKey ?? "")
            }
        }
    }

    // MARK: - 机器接口

    private var machineSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("用 API Key 就能让 AI / 脚本直接读写日程，不需要登录界面。把地址和 Key 一起给它就行。")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = extURL {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.blue600)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                        } label: {
                            Text("复制")
                                .font(.appFootnote)
                                .foregroundStyle(Theme.blue600)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("先登录才能拿到接口地址")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.amber600)
                }

                if let guide = guideURL {
                    HStack(spacing: 8) {
                        Text("使用说明")
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button {
                            UIApplication.shared.open(guide)
                        } label: {
                            Text("在浏览器里打开")
                                .font(.appFootnote)
                                .foregroundStyle(Theme.blue600)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("机器接口（给 AI / 脚本用）")
        }
    }

    /// 服务端地址 + `/api/ext`。
    ///
    /// ⚠️ 用 `APIClient.shared.currentBaseURL` 而不是 `store.serverText`：
    ///    后者是登录页那个**原始输入**（可能是 `host:8443` 这种没写 scheme 的），
    ///    而且登录后不一定还留着值。这里要的是"这个 App 此刻真正在打的地址"，
    ///    拼错了用户会拿着一个连不上的 URL 去别处配置，排查成本极高。
    private var extURL: URL? {
        guard let base = APIClient.shared.currentBaseURL else { return nil }
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/api/ext")
    }

    private var guideURL: URL? {
        guard let e = extURL else { return nil }
        return URL(string: e.absoluteString + "/guide")
    }

    // MARK: - Key 列表

    private var keySection: some View {
        Section {
            if loading && keys.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取…").font(.appFootnote).foregroundStyle(Theme.textSecondary)
                }
            } else if keys.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("还没有 Key")
                        .font(.appSubheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("生成一把，就能让外部程序读写你的日程。每把 Key 可以单独撤销，互不影响。")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(keys) { k in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(k.name)
                                .font(.appBody)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(k.prefix + "…")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(usageText(k))
                            .font(.appCaption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingRevoke = k
                        } label: {
                            Label("撤销", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newName = ""
                creating = true
            } label: {
                Label("生成新的 Key", systemImage: "plus.circle")
                    .font(.appBody)
            }

            if let f = failure {
                Text(f)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.red600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("完整 Key **只在生成时显示一次**，服务器只存它的哈希值。丢了只能撤销后重新生成。左滑可以撤销。")
        }
        .confirmationDialog("撤销这把 Key？", isPresented: Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        ), titleVisibility: .visible, presenting: pendingRevoke) { k in
            Button("撤销「\(k.name)」", role: .destructive) {
                Task { await revoke(k) }
            }
            Button("取消", role: .cancel) { pendingRevoke = nil }
        } message: { k in
            Text("用了这把 Key 的 AI 或脚本会立刻失去访问权，日程本身不受影响。")
        }
    }

    private func usageText(_ k: APIKeyRow) -> String {
        let created = Date(timeIntervalSince1970: TimeInterval(k.createdAt))
        if k.lastUsedAt <= 0 {
            return "创建于 \(created.monthDay) · 还没用过"
        }
        let used = Date(timeIntervalSince1970: TimeInterval(k.lastUsedAt))
        return "创建于 \(created.monthDay) · 上次使用 \(used.monthDay) \(used.hhmm)"
    }

    // MARK: - 未做的部分

    /// 明说"对话还没做"。
    ///
    /// 留一个空白的聊天框更糟：用户会打字、会等回复，然后以为 App 坏了。
    /// 我们还没做的功能，界面上就该是一句解释。
    private var chatNotice: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("对话还没做", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.appSubheadline.weight(.medium))
                    .foregroundStyle(Theme.amber600)
                Text("安卓端的 AI 对话是客户端直连第三方模型（要自己填模型和密钥）。iOS 这边还没接。\n\n上面的机器接口已经可用 —— 你可以先把它给任何支持自定义 API 的 AI 工具，让它替你读课表、加日程。")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } header: {
            Text("对话")
        }
    }

    // MARK: - 网络

    private func load() async {
        loading = true
        do {
            let res: APIKeyListResponse = try await APIClient.shared.get("/api/apikeys")
            keys = res.keys
            failure = nil
        } catch {
            failure = "读取 Key 失败：\(store.message(for: error))"
        }
        loading = false
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        do {
            let body = try JSONEncoder().encode(["name": name])
            let res: APIKeyCreateResponse = try await APIClient.shared.post("/api/apikeys", body: body)
            freshKey = res.key
            await load()
        } catch {
            failure = "生成失败：\(store.message(for: error))"
        }
    }

    private func revoke(_ k: APIKeyRow) async {
        pendingRevoke = nil
        do {
            try await APIClient.shared.delete("/api/apikeys/\(k.id)")
            await load()
        } catch {
            failure = "撤销失败：\(store.message(for: error))"
        }
    }
}

// MARK: - DTO

/// `GET /api/apikeys` 的一行。
///
/// ⚠️ **没有** `key` 字段。服务端只回 `prefix`（前 12 位）——
///    完整 Key 在生成那一次之后就不存在任何地方了（只存哈希）。
///    所以这里千万别声明一个 `key: String` 去等它，那会 keyNotFound。
struct APIKeyRow: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let prefix: String
    let createdAt: Int64
    let lastUsedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, prefix
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        lastUsedAt = try c.decodeIfPresent(Int64.self, forKey: .lastUsedAt) ?? 0
    }
}

struct APIKeyListResponse: Decodable {
    let keys: [APIKeyRow]

    enum CodingKeys: String, CodingKey { case keys }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 服务端空列表可能下发 `null` 或直接省掉这个键，
        // 两种都不能让整页解析失败。
        keys = try c.decodeIfPresent([APIKeyRow].self, forKey: .keys) ?? []
    }
}

struct APIKeyCreateResponse: Decodable {
    let id: String
    let name: String
    let key: String
    let note: String?

    enum CodingKeys: String, CodingKey { case id, name, key, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // 这个键是**唯一一次**下发的完整 Key。解不出来说明服务端改了契约，
        // 与其静默给个空串让用户复制走一片空白，不如让解码失败、报错出来。
        key = try c.decode(String.self, forKey: .key)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}
