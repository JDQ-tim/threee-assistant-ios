import Foundation
import Observation

// ============================================================
//  装在本机的导航数据包
//  ------------------------------------------------------------
//  一份包里是一所学校（或一个校区）的楼栋表。可以有多个包，
//  但**同时只有一个生效** —— 见 `activePackID` 下面那段。
//
//  ## 为什么落在文件里而不是 UserDefaults
//
//  一份包动辄几百栋楼、上千个房间，序列化之后几百 KB 到几 MB。
//  UserDefaults 是给"一小把开关"用的，塞这种体量进去会让
//  每次 App 启动都变慢（它是整份读进内存的）。
// ============================================================

@MainActor
@Observable
final class NavPackStore {

    // MARK: - 状态

    private(set) var packs: [NavPack] = []

    /// 当前生效的包。
    ///
    /// ## 为什么只允许一个生效（而不是"全都能匹配"）
    ///
    /// 两个学校的包里都可能有「1 号楼」。同时生效时，一句「1号楼302」
    /// 会命中先遍历到的那个 —— 而用户看不出是哪一所的。
    /// 用户的原话是**「不能匹配除了我标注包以外的楼，不然真的闹笑话」**，
    /// 所以这里宁可"要切就切一下"，也不要"全都匹配一下"。
    private(set) var activePackID: String?

    /// 匹配缓存：地点原文 → 拆分结果。
    ///
    /// 一周 30 条日程，每条都要走一次"逐楼比对 + LCS 兜底"。
    /// 放在视图 body 里现算的话，滚动列表会明显掉帧。
    /// 包一变就整体清掉（`invalidate()`）。
    private var cache: [String: NavSplit] = [:]

    private var didLoad = false

    // MARK: - 派生

    var activePack: NavPack? {
        guard let id = activePackID else { return nil }
        return packs.first { $0.packID == id }
    }

    var buildings: [NavBuilding] { activePack?.buildings ?? [] }

    var hasActivePack: Bool { activePack != nil }

    /// 有坐标、能画在地图上的楼。
    var mappableBuildings: [NavBuilding] { buildings.filter { $0.coordinate != nil } }

    // MARK: - 读写

    /// 第一次访问时读盘。**幂等** —— 视图 onAppear 里调它不用先判断。
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        reload()
    }

    func reload() {
        cache.removeAll()
        packs = []
        activePackID = nil

        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any]
        else { return }

        let rawPacks = obj["packs"] as? [[String: Any]] ?? []
        var loaded: [NavPack] = []
        for raw in rawPacks {
            // ⚠️ 落盘的东西也可能坏（写到一半、被别的工具改过）。
            //    **坏一个丢一个**，不让一份坏包把整个库拖死 ——
            //    否则表现是"以前好好的，现在一个包都没了"。
            guard let text = Self.jsonText(raw),
                  let pack = try? NavPackParser.parse(text, importedAt: importedAt(of: raw))
            else { continue }
            loaded.append(pack)
        }
        packs = loaded

        let active = (obj["active"] as? String) ?? ""
        if loaded.contains(where: { $0.packID == active }) {
            activePackID = active
        } else {
            // 存的那个包已经不在表里了（被删/坏掉）：退回第一个，而不是"什么都不生效"
            activePackID = loaded.first?.packID
        }
    }

    /// 导入一份包（文本形式，可能来自下载接口，也可能来自用户选的文件）。
    ///
    /// ## 装包 = **整体替换**，不是合并
    ///
    /// 这条口径是上游产品定的（见 `NavPack.kt` 里 `replace()` 那段：
    /// 用户原话"只保留被标注的数据，其他的建筑统一清掉"）。
    ///
    /// 之所以敢丢数据，是因为**替换前会备份**旧文件到 `navpacks.bak.json` ——
    /// 这条纪律松绑的前提是"丢掉的还能捞回来"，不是"丢了就丢了"。
    @discardableResult
    func importPack(_ text: String, activate: Bool = true) throws -> NavPack {
        let pack = try NavPackParser.parse(text, importedAt: Int64(Date().timeIntervalSince1970))

        // 先备份。失败不阻断导入（备份是保险，不是前置条件）。
        backup()

        if let i = packs.firstIndex(where: { $0.packID == pack.packID }) {
            packs[i] = pack
        } else {
            packs.append(pack)
        }
        if activate || activePackID == nil {
            activePackID = pack.packID
        }
        invalidate()
        save()
        return pack
    }

    /// 切换生效的包。传 nil = 一个都不用。
    func setActive(_ id: String?) {
        if let id, !packs.contains(where: { $0.packID == id }) { return }
        activePackID = id
        invalidate()
        save()
    }

    func remove(_ id: String) {
        packs.removeAll { $0.packID == id }
        if activePackID == id { activePackID = packs.first?.packID }
        invalidate()
        save()
    }

    func removeAll() {
        packs = []
        activePackID = nil
        invalidate()
        save()
    }

    // MARK: - 匹配

    /// 解析一段地点文字。**带缓存**。
    func split(_ text: String) -> NavSplit {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .unmatched("") }
        if let hit = cache[key] { return hit }

        let result = NavMatcher.split(key, in: buildings)
        // 只缓存"认到了"的。
        //
        // ⚠️ 不缓存失败：用户可能刚把楼名写对（改了日程地点），
        //    缓存住"认不出"会让他改完还是认不出 —— "改了没用"的经典坑。
        //    上游安卓端缓存联网结果时也是同一条规矩。
        if result.building != nil { cache[key] = result }
        return result
    }

    /// 只认楼、不拆房号。给"这条日程要不要显示地图按钮"这种判断用。
    func match(_ text: String) -> NavMatch? {
        NavMatcher.match(text, in: buildings)
    }

    /// 认不出时，说几个"长得像"的名字。
    ///
    /// 用户报"明明标注了还是认不出"时，只回一句"认不出"没法查 ——
    /// 而这一句能直接看出是名字写法不同、还是楼根本不在启用的包里。
    func nearMisses(_ text: String, limit: Int = 4) -> [String] {
        let q = NavText.norm(NavText.corePlace(text))
        guard let first = q.first else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for b in buildings {
            let n = NavText.norm(NavText.corePlace(b.name))
            guard let f = n.first, f == first, !b.name.isEmpty else { continue }
            if seen.insert(b.name).inserted { out.append(b.name) }
            if out.count >= limit { break }
        }
        return out
    }

    /// 给界面的一句话诊断（认不出时显示在下面）。
    func missReason(_ text: String) -> String {
        let q = NavText.norm(NavText.corePlace(text))
        guard !q.isEmpty else { return "" }

        guard let pack = activePack else {
            return "还没有导入任何校园数据包 —— 去「个人 → 校园地图」导入一个"
        }
        let near = nearMisses(text)
        let scope = "（匹配范围：\(pack.name)）"
        if near.isEmpty { return "校内表里没有「\(q)」\(scope)" }
        return "校内表里没有「\(q)」，相近的有：\(near.joined(separator: "、"))\(scope)"
    }

    private func invalidate() { cache.removeAll() }

    // MARK: - 落盘

    private static var fileURL: URL? { url(named: "navpacks.json") }

    private static func backupURL() -> URL? { url(named: "navpacks.bak.json") }

    private static func url(named name: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true) else { return nil }
        let sub = dir.appendingPathComponent("ThreeeAssistant", isDirectory: true)
        if !fm.fileExists(atPath: sub.path) {
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        return sub.appendingPathComponent(name)
    }

    private func backup() {
        guard let src = Self.fileURL, let dst = Self.backupURL() else { return }
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        let payload: [String: Any] = [
            "active": activePackID ?? "",
            "packs": packs.map { $0.toJSON() },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        // 落盘挪到后台：一份包几百 KB，写在主线程上会让"导入"按钮卡一下。
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func jsonText(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func importedAt(of obj: [String: Any]) -> Int64 {
        if let n = obj["_importedAt"] as? NSNumber { return n.int64Value }
        return 0
    }
}
