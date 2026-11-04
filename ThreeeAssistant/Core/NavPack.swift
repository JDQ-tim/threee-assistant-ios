import CoreLocation
import Foundation

// ============================================================
//  导航数据包（navpack）
//  ------------------------------------------------------------
//  这一层只做两件事：**把一段 JSON 认成包**、**把包变回 JSON**。
//  匹配（文字 → 楼）在 `NavPackStore.swift` 的 `NavMatch` 里。
//
//  权威格式定义在服务端源码包的
//  `docs/格式-导航数据包-navpack-2026-10-12.md`，安卓端的实现是
//  `android/plugin-nav/.../NavPack.kt`。这里逐条对齐它的**判据**，
//  不是"大致能读懂" —— 理由见 `NavPackError` 每一条的注释。
//
//  ## 为什么用手写解析而不是 Codable
//
//  Codable 的失败是**一个笼统的 `dataCorrupted`**，而解析外部文件时
//  用户真正需要知道的是"这不是我们的文件"还是"你的插件该升级了"还是
//  "文件下载坏了"。这三句话的下一步动作完全不同。
//  更现实的一点：服务端那边一个字段写成 `1` 而不是 `"1"`，Codable 会让
//  **整个包**解不出来，而这里只会让那一个字段回落到默认值。
//  （这三条都是本项目踩过的坑，不是假想。）
//
//  ## 为什么"存进去再读出来"也走同一条解析路径
//
//  `toJSON()` 之后落盘，下次启动用 `parse()` 读回来 —— 只有一套判据。
//  如果另写一套 Codable 解码，两份规则一定会有一份先过期，而表现是
//  "导入时好好的，重启之后楼少了一半"。
// ============================================================

// MARK: - 数据模型

/// 一个点。包里的坐标一律是「纬度, 经度」，和国标、和 MapKit 都一致。
struct NavPoint: Hashable {
    let lat: Double
    let lng: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

/// 一个房间。坐标是**归一化偏移**，不是经纬度。
///
/// 以楼栋中心为原点，`x` 向右为负…… 不，是**向右为正、向下为正**，
/// 取值范围 -0.5 ~ +0.5，外墙就是 [-0.5, 0.5] 这个方框。
///
/// 为什么不存经纬度：房间间距只有几米，而手点地图的误差就有十几米 ——
/// 存经纬度是在制造精确的假象。用户要的是"每层每个房间**大概**在哪"。
struct NavRoom: Hashable, Identifiable {
    let name: String
    /// classroom / lecture / lab / office / toilet / stairs / other
    let type: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    var id: String { "\(name)@\(x),\(y)" }
}

struct NavFloor: Hashable, Identifiable {
    let name: String
    let rooms: [NavRoom]

    var id: String { name }
}

/// 地图标注（牌子 / 贴纸 / 箭头之类）。老包没有这个字段 → 空数组。
struct NavMark: Hashable, Identifiable {
    let id: String
    let kind: String
    let lat: Double
    let lng: Double
    let text: String
    let w: Double
    let h: Double
    let rot: Double
    let color: String
    let icon: String

    var hasCoord: Bool { !(lat == 0 && lng == 0) && lat.isFinite && lng.isFinite }

    var coordinate: CLLocationCoordinate2D? {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return hasCoord && CLLocationCoordinate2DIsValid(c) ? c : nil
    }
}

struct NavBuilding: Hashable, Identifiable {
    let id: String
    let name: String
    let alias: [String]
    let lat: Double
    let lng: Double
    let campus: String
    let note: String
    /// 分类（教学楼 / 宿舍 / 食堂 …）。**未知值原样保留** ——
    /// 抹成"其他"将来就认不出来了。
    let type: String
    let floors: [NavFloor]
    /// 底面轮廓。少于 3 个点就是空数组（两个点画不出面）。
    let shape: [NavPoint]
    /// 轮廓是"真的"还是"占位矩形"。老包没有这个字段，缺省 true。
    let shapeExact: Bool

    /// 有**可用**坐标。
    ///
    /// ⚠️ 判据和安卓端逐字一致：`lat != 0 || lng != 0`。
    ///    `0,0` 在几内亚湾，那是"没标"的约定写法，不是一所学校。
    ///    **不要**在这里额外加范围校验 —— 那会让"没标"和"标错了"
    ///    在匹配结果里变得不可区分，而两者的下一步动作不一样。
    var hasCoord: Bool { lat.isFinite && lng.isFinite && (lat != 0 || lng != 0) }

    /// 给 MapKit 用。越界的坐标**不进地图**（MapKit 会拒绝或者画到天上去），
    /// 但 `hasCoord` 仍然是 true，所以详情页照样能说"标了，只是标歪了"。
    var coordinate: CLLocationCoordinate2D? {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return hasCoord && CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    /// 参与匹配的全部名字。**不归一化** —— 归一化在 `NavMatch` 里统一做，
    /// 免得两处各写一遍（那种地方最容易漏掉别名）。
    var keys: [String] {
        ([name] + alias).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 有分层数据吗（决定"楼层"入口显不显示）。
    var hasFloors: Bool { floors.contains { !$0.rooms.isEmpty } }

    /// 给人看的一行（校园 · 备注）。
    var subtitle: String {
        [campus, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 楼栋中心的近似外接矩形，用来在地图上画一个占位框。
    ///
    /// 有真轮廓就用真轮廓，没有就按"一栋楼大约 40 米"合成一个方块 ——
    /// 安卓端也是这么做的，目的是让 3D 视图有东西可拔。
    /// 这里不画 3D，但轮廓能让 2D 地图看起来是"一栋楼"而不是一个图钉。
    var outline: [NavPoint] {
        if !shape.isEmpty { return shape }
        guard let c = coordinate else { return [] }
        // 纬度 1 度 ≈ 111km；经度按纬度收缩
        let halfLat = 20.0 / 111_000.0
        let halfLng = 20.0 / (111_000.0 * max(0.2, cos(c.latitude * .pi / 180)))
        return [
            NavPoint(lat: c.latitude - halfLat, lng: c.longitude - halfLng),
            NavPoint(lat: c.latitude - halfLat, lng: c.longitude + halfLng),
            NavPoint(lat: c.latitude + halfLat, lng: c.longitude + halfLng),
            NavPoint(lat: c.latitude + halfLat, lng: c.longitude - halfLng),
        ]
    }
}

/// 一份装进手机的导航数据包。
struct NavPack: Identifiable, Hashable {
    /// 授权码就是它。服务端"一个包一个码"，不另发随机串。
    let packID: String
    let name: String
    let note: String
    let version: String
    /// 包里的腾讯 Key。iOS **不用**它（有 MapKit），但要原样留着 ——
    /// 用户可能把同一个包给了安卓端，这里丢掉就等于替他改文件。
    let tencentKey: String
    let referer: String
    let origin: NavBuilding?
    /// 已经把 `origin` 并进来的完整楼栋表（按 id 去重，先到先得）。
    let buildings: [NavBuilding]
    let marks: [NavMark]

    /// 导入这个包的时刻（本机时间，只用于排序和显示）。
    let importedAt: Int64

    var id: String { packID }

    var withCoordCount: Int { buildings.filter(\.hasCoord).count }

    var floorCount: Int { buildings.reduce(0) { $0 + $1.floors.count } }

    var roomCount: Int {
        buildings.reduce(0) { sum, b in sum + b.floors.reduce(0) { $0 + $1.rooms.count } }
    }

    /// 地图的初始视野：所有**有坐标**的楼的外接矩形。
    /// 一个都没有时返回 nil（界面要说"这个包没有坐标"，不是显示一片海）。
    var bounds: NavBounds? {
        let coords = buildings.compactMap(\.coordinate)
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lngs = coords.map(\.longitude)
        return NavBounds(
            minLat: lats.min()!,
            maxLat: lats.max()!,
            minLng: lngs.min()!,
            maxLng: lngs.max()!
        )
    }
}

/// 一个纯值的外接矩形。
///
/// 不直接用 `MKCoordinateRegion`：那是 MapKit 的类型，
/// 而 `NavPack` 这一层要能被离线脚本碰到（和 `check_week_numbering.py` 一样，
/// 在没有 Mac 的机器上跑）—— 地图类型带进来就得连 UI 框架一起编。
struct NavBounds: Hashable {
    let minLat: Double
    let maxLat: Double
    let minLng: Double
    let maxLng: Double

    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLng: Double { (minLng + maxLng) / 2 }

    /// 留 35% 的余量：贴着边走会让最外圈的楼正好压在地图边缘上，点不到。
    var spanLat: Double { max(0.0016, (maxLat - minLat) * 1.35) }
    var spanLng: Double { max(0.0016, (maxLng - minLng) * 1.35) }
}

// MARK: - 错误

/// 认不出包的原因。
///
/// ⚠️ **每一种给用户看的话完全不一样**，所以不能压成一个 bool：
///    "不是我们的文件" → 你选错文件了
///    "版本太新"       → 去升级，不是文件的问题
///    "文件坏了"       → 重新导一次
/// 合成一句"导入失败"，用户只能反复重试同一个动作。
enum NavPackError: LocalizedError, Equatable {
    case empty
    case notJSON
    case notOurs
    case badVersion(found: Int, supported: Int)
    case badPackID(String)
    case noBuildings

    var errorDescription: String? {
        switch self {
        case .empty:
            return "文件是空的 —— 可能没下载完，也可能拿错了文件"
        case .notJSON:
            return "这不是一个 JSON 文件 —— 请确认你导出的是 .navpack.json"
        case .notOurs:
            return "这不是导航数据包（缺少 \"format\": \"threees.navpack\"）—— 请确认你导出的是「含标注的 .navpack.json」，不是别的文件"
        case let .badVersion(found, supported):
            return "这个包是更新版本（formatVersion \(found)）做的，当前只认到 \(supported) —— 请先升级学习助手"
        case let .badPackID(raw):
            return "包标识（packId）不合法：\"\(raw)\" —— 它必须是 2~48 位小写字母、数字或连字符，且以字母开头"
        case .noBuildings:
            return "这个包里一栋楼都没有 —— 导进去不能导航到任何地方，请确认导出时标过楼栋"
        }
    }
}

// MARK: - 解析

enum NavPackFormat {
    /// 认得出的 `format` 值。
    static let tag = "threees.navpack"
    /// 支持到哪个 `formatVersion`。
    ///
    /// v1 当作"没有分层"，v2 正常解析。比 2 大就拒绝 ——
    /// 旧客户端不认识新字段，**静默出错比拒绝更坏**（会少一半楼而用户不知道）。
    static let maxVersion = 2
}

enum NavPackParser {

    /// 把一段 JSON 文本解析成包。
    ///
    /// - Parameter text: `.navpack.json` 的原文，也可能是下载接口返回的 body。
    /// - Parameter importedAt: 导入时刻；传 0 表示"读回来时用落盘的时间"。
    static func parse(_ text: String, importedAt: Int64 = 0) throws -> NavPack {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NavPackError.empty
        }
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any]
        else { throw NavPackError.notJSON }

        // ① 身份：认不出就不是我们的文件
        guard str(obj, "format") == NavPackFormat.tag else { throw NavPackError.notOurs }

        // ② 版本：比支持的更新就拒绝，不做"尽力解析"
        let fv = int(obj, "formatVersion")
        if fv <= 0 { throw NavPackError.badVersion(found: fv, supported: NavPackFormat.maxVersion) }
        if fv > NavPackFormat.maxVersion {
            throw NavPackError.badVersion(found: fv, supported: NavPackFormat.maxVersion)
        }

        // ③ 包标识：授权码就是它，格式不对会让"凭码导入"永远失败
        let packID = str(obj, "packId")
        guard isValidPackID(packID) else { throw NavPackError.badPackID(packID) }

        var buildings = parseBuildings(obj["buildings"])
        // ④ 空包：拒绝，并说清为什么 —— 导进去什么都没变，不说清会像"导入失败"
        guard !buildings.isEmpty else { throw NavPackError.noBuildings }

        // 标定原点：它本身也是"一栋楼"吗？不是 —— 它只是坐标提示。
        // 但有名字就一并装进表里（安卓端 `replace()` 就是这么做的）。
        let origin = (obj["origin"] as? [String: Any]).flatMap { parseBuilding($0, fallbackID: "origin") }
        if let o = origin, !o.name.isEmpty, !buildings.contains(where: { $0.id == o.id }) {
            buildings.append(o)
        }

        let name = str(obj, "name")
        let version = str(obj, "version")
        return NavPack(
            packID: packID,
            name: name.isEmpty ? packID : name,
            note: str(obj, "note"),
            version: version.isEmpty ? "1.0.0" : version,
            tencentKey: str(obj, "tencentKey"),
            referer: str(obj, "referer"),
            origin: origin,
            buildings: buildings,
            marks: parseMarks(obj["marks"]),
            importedAt: importedAt
        )
    }

    /// 包标识的格式。和服务端 `validNavPackID` 是同一条规则。
    static func isValidPackID(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 48 else { return false }
        guard let first = s.first, first.isLowercase, first.isLetter else { return false }
        return s.allSatisfy { c in
            c.isLowercase && c.isLetter || c.isNumber || c == "-"
        }
    }

    // MARK: 字段读取
    //
    // 全部**宽容**：类型不对就当没有。这不是"尽力解析"——包的**身份和版本**
    // 是严格校验的，这里宽容的只是内容字段，而内容字段少一个的后果
    // 是"这栋楼少显示一行备注"，不是"用户以为导入成功了其实少一半楼"。

    static func str(_ o: [String: Any], _ k: String) -> String {
        guard let v = o[k] else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func dbl(_ o: [String: Any], _ k: String) -> Double {
        dblOf(o[k])
    }

    static func dblOf(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return .nan
    }

    static func int(_ o: [String: Any], _ k: String) -> Int {
        if let n = o[k] as? NSNumber { return n.intValue }
        if let s = o[k] as? String, let i = Int(s) { return i }
        return 0
    }

    static func bool(_ o: [String: Any], _ k: String, default def: Bool) -> Bool {
        if let n = o[k] as? NSNumber { return n.boolValue }
        if let b = o[k] as? Bool { return b }
        return def
    }

    // MARK: 子结构

    /// 解析楼栋数组。
    ///
    /// ⚠️ **空名字的条目直接丢掉**：留着会让匹配逻辑撞车 ——
    /// 一个没有名字的楼 `keys` 是空集，既匹配不到任何东西，
    /// 又会在"按长度降序"里排到最后当噪声。
    static func parseBuildings(_ v: Any?) -> [NavBuilding] {
        guard let arr = v as? [Any] else { return [] }
        var out: [NavBuilding] = []
        // 上限是防御性的：一个坏掉/恶意的包塞十万栋楼，
        // 主线程解析会卡住界面。真实校园不会超过几千栋。
        for (i, raw) in arr.enumerated() where i < 5000 {
            guard let o = raw as? [String: Any] else { continue }
            guard let b = parseBuilding(o, fallbackID: "b_\(i)") else { continue }
            out.append(b)
        }
        return out
    }

    /// 解析一栋楼。返回 nil = 这一条该丢（没有名字）。
    static func parseBuilding(_ o: [String: Any], fallbackID: String) -> NavBuilding? {
        let name = str(o, "name")
        guard !name.isEmpty else { return nil }

        var id = str(o, "id")
        if id.isEmpty { id = fallbackID }
        guard !id.isEmpty else { return nil }

        let alias = (o["alias"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let lat = dbl(o, "lat")
        let lng = dbl(o, "lng")

        return NavBuilding(
            id: id,
            name: name,
            alias: alias,
            // ⚠️ 字段不存在和"不是数字"都给 NaN —— 两种都当"没标坐标"。
            lat: lat.isFinite ? lat : 0,
            lng: lng.isFinite ? lng : 0,
            campus: str(o, "campus"),
            note: str(o, "note"),
            type: str(o, "type"),
            floors: parseFloors(o["floors"]),
            shape: parseShape(o["shape"]),
            // ⚠️ 缺省 `true` —— 老包里没有这个字段，而那些 shape 都是手描或
            //    OSM 导入来的，都是真的。轮廓不成立时（shape 为空）标记没意义。
            shapeExact: ((o["shape"] as? [Any])?.count ?? 0) >= 3
                && bool(o, "shapeExact", default: true)
        )
    }

    static func parseFloors(_ v: Any?) -> [NavFloor] {
        guard let arr = v as? [Any] else { return [] }
        var out: [NavFloor] = []
        for (i, raw) in arr.enumerated() {
            guard let o = raw as? [String: Any] else { continue }
            var name = str(o, "name")
            if name.isEmpty { name = "第 \(i + 1) 层" }
            let rooms = (o["rooms"] as? [Any] ?? []).compactMap { raw -> NavRoom? in
                (raw as? [String: Any]).flatMap(parseRoom)
            }
            out.append(NavFloor(name: name, rooms: rooms))
        }
        return out
    }

    /// 解析一个房间。
    ///
    /// ⚠️ `x` / `y` 缺失或非数字时**丢弃这一条**，不画在 (0,0)。
    ///    (0,0) 在归一化坐标里是"正中心"，一个落在正中心的房间会让
    ///    整张图看起来是错的，而用户不知道问题出在哪 —— 比"这间没标"坏得多。
    static func parseRoom(_ o: [String: Any]) -> NavRoom? {
        let name = str(o, "name")
        guard !name.isEmpty else { return nil }
        guard o["x"] != nil, o["y"] != nil else { return nil }
        let x = dbl(o, "x")
        let y = dbl(o, "y")
        guard x.isFinite, y.isFinite else { return nil }

        let w = dbl(o, "w")
        let h = dbl(o, "h")
        return NavRoom(
            name: name,
            type: str(o, "type"),
            x: x,
            y: y,
            w: w.isFinite && w > 0 ? w : 0.16,
            h: h.isFinite && h > 0 ? h : 0.12
        )
    }

    /// 解析底面轮廓。
    ///
    /// 坏点**逐点丢**：整条丢掉的代价太大（用户描了半天的楼会变成一根针），
    /// 而一个坏点丢掉不影响形状。
    static func parseShape(_ v: Any?) -> [NavPoint] {
        guard let arr = v as? [Any] else { return [] }
        var out: [NavPoint] = []
        for raw in arr {
            guard let pair = raw as? [Any], pair.count >= 2 else { continue }
            let la = dblOf(pair[0])
            let ln = dblOf(pair[1])
            guard la.isFinite, ln.isFinite else { continue }
            // 中国大陆的粗略范围。和安卓端 `parseShape` 的判据一致 ——
            // 轮廓是要画在地图上的，一个 (0,0) 的点会把整栋楼拉成跨半个地球的三角形。
            guard la >= 3, la <= 54, ln >= 73, ln <= 136 else { continue }
            out.append(NavPoint(lat: la, lng: ln))
        }
        // 少于 3 个点画不出面，交给地图会画出一条没有面积的"墙"
        return out.count >= 3 ? out : []
    }

    /// 解析标注。⚠️ 坏一条**丢一条**，不整包拒绝 ——
    /// 一个标注写坏了不该让整个包导不进来。
    static func parseMarks(_ v: Any?) -> [NavMark] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap { raw -> NavMark? in
            guard let o = raw as? [String: Any] else { return nil }
            let id = str(o, "id")
            guard !id.isEmpty else { return nil }
            let lat = dbl(o, "lat")
            let lng = dbl(o, "lng")
            // 没有坐标的标注没法画 —— 丢掉。留着只会让列表里出现一条
            // "看不见的标注"，而用户永远找不到它。
            guard lat.isFinite, lng.isFinite else { return nil }
            return NavMark(
                id: id,
                kind: str(o, "kind"),
                lat: lat,
                lng: lng,
                text: str(o, "text"),
                w: dbl(o, "w"),
                h: dbl(o, "h"),
                rot: dbl(o, "rot"),
                color: str(o, "color"),
                icon: str(o, "icon")
            )
        }
    }
}

// MARK: - 落盘

extension NavPack {

    /// 变回一份 `.navpack.json` 形状的字典。
    ///
    /// 刻意保留包里原有的 `tencentKey` / `referer`：iOS 不用它们，
    /// 但用户可能把同一个包也给了安卓端 —— 这里悄悄丢掉就是替他改了文件。
    func toJSON() -> [String: Any] {
        var o: [String: Any] = [
            "format": NavPackFormat.tag,
            "formatVersion": NavPackFormat.maxVersion,
            "packId": packID,
            "name": name,
            "note": note,
            "version": version,
            "tencentKey": tencentKey,
            "referer": referer,
            "buildings": buildings.map(\.toJSON),
            "marks": marks.map(\.toJSON),
            "_importedAt": importedAt,
        ]
        if let origin { o["origin"] = origin.toJSON }
        return o
    }
}

extension NavBuilding {
    func toJSON() -> [String: Any] {
        var o: [String: Any] = [
            "id": id,
            "name": name,
            "alias": alias,
            "lat": lat,
            "lng": lng,
            "campus": campus,
            "note": note,
            "type": type,
            "floors": floors.map(\.toJSON),
        ]
        // ⚠️ 空轮廓**不写这个键**，而不是写一个空数组 —— 和安卓端一致。
        //    写了空数组会让"没有轮廓"和"轮廓是空的"在下游分不开。
        if !shape.isEmpty {
            o["shape"] = shape.map { [$0.lat, $0.lng] }
            o["shapeExact"] = shapeExact
        }
        return o
    }
}

extension NavFloor {
    func toJSON() -> [String: Any] {
        ["name": name, "rooms": rooms.map(\.toJSON)]
    }
}

extension NavRoom {
    func toJSON() -> [String: Any] {
        ["name": name, "type": type, "x": x, "y": y, "w": w, "h": h]
    }
}

extension NavMark {
    func toJSON() -> [String: Any] {
        var o: [String: Any] = [
            "id": id, "kind": kind, "lat": lat, "lng": lng, "text": text,
        ]
        // 和 Building 同一条规矩：没内容就不写这个键。0 是"自动"。
        if w > 0 { o["w"] = w }
        if h > 0 { o["h"] = h }
        if rot != 0 { o["rot"] = rot }
        if !color.isEmpty { o["color"] = color }
        if !icon.isEmpty { o["icon"] = icon }
        return o
    }
}
