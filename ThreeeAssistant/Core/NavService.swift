import Foundation

// ============================================================
//  导航数据包的服务端接口
//  ------------------------------------------------------------
//  服务端路由（`server/internal/app/routes.go`）：
//
//      GET /api/navpacks                  列出现有的包（要登录）
//      GET /api/navpacks/download/{id}    凭授权码取包（要登录）
//
//  ## 为什么这两个接口 iOS 能用，而「插件市场」不能用
//
//  插件市场（`/api/market/plugins`）下发的是**原生插件包**，服务端
//  `normalizePlatform()` 的 default 分支返回 `android`，iOS 去拉永远拿到
//  `.apk` —— 那条路是死的，不是配置问题。
//
//  而导航包是**纯数据**（一份 JSON），和平台无关。服务端既不关心
//  谁在下载，也不下发任何可执行的东西。所以这条路对 iOS 是通的。
//
//  ## 一个刻意的取舍：不加本地缓存层
//
//  列表只有几个条目，一次请求几十字节。加缓存会让"管理员刚更新的包
//  在手机上还是旧名字"变成一类说不清的问题，而不加的唯一代价是
//  进页面时等半秒。所以每次进页面都重拉。
// ============================================================

/// `GET /api/navpacks` 的一项。
///
/// ⚠️ 字段全部手写解码并给默认值。
///    Codable 的自动合成遇到一个字段是 `null` 就让**整条**解不出来，
///    而这个列表只是"有哪些包"，某一条少了 `note` 不该让整个页面空白。
struct NavPackListItem: Decodable, Identifiable, Hashable {
    let packID: String
    let name: String
    let note: String
    let version: String
    /// 楼栋总数
    let buildings: Int
    /// 其中标了坐标的
    let withCoord: Int
    /// 包里带着腾讯 Key（iOS 不用，但值得告诉用户"这个包本来是给安卓用的"）
    let keyCarried: Bool
    let updatedAt: Int64
    /// 服务端给的下发地址。**不用它** —— 见 `NavService.download` 的注释。
    let downloadURL: String

    var id: String { packID }

    enum CodingKeys: String, CodingKey {
        case packID = "pack_id"
        case name, note, version, buildings
        case withCoord = "with_coord"
        case keyCarried = "key_carried"
        case updatedAt = "updated_at"
        case downloadURL = "download_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packID = try c.decodeIfPresent(String.self, forKey: .packID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        buildings = try c.decodeIfPresent(Int.self, forKey: .buildings) ?? 0
        withCoord = try c.decodeIfPresent(Int.self, forKey: .withCoord) ?? 0
        keyCarried = try c.decodeIfPresent(Bool.self, forKey: .keyCarried) ?? false
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL) ?? ""
    }
}

struct NavPackListResponse: Decodable {
    let packs: [NavPackListItem]
    let format: String
    let formatVersion: Int
    let serverTime: Int64

    enum CodingKeys: String, CodingKey {
        case packs, format
        case formatVersion = "format_version"
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packs = try c.decodeIfPresent([NavPackListItem].self, forKey: .packs) ?? []
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        serverTime = try c.decodeIfPresent(Int64.self, forKey: .serverTime) ?? 0
    }
}

enum NavService {

    /// 列出现有的包。
    ///
    /// 404 单独翻译一句人话：**旧版服务端根本没有这组路由**，
    /// 而默认的错误文案会是"请求失败（404）"，用户会以为是自己网络的问题。
    static func list() async throws -> [NavPackListItem] {
        do {
            let r: NavPackListResponse = try await APIClient.shared.get("/api/navpacks")
            return r.packs
        } catch APIError.server(let code, _) where code == 404 {
            throw NavServiceError.serverTooOld
        }
    }

    /// 凭授权码取包，返回 `.navpack.json` 的原文。
    ///
    /// ## 为什么不用列表里那个 `download_url`
    ///
    /// 服务端在配了对象存储（COS）时会把 `download_url` 换成对象存储的直链。
    /// 那个地址**不在我们的 `TrustStore` 里**，而且可能是 http ——
    /// 走 `APIClient` 会撞上证书/明文两重问题，而那些问题对用户来说
    /// 只会表现为一句"下载失败"。
    ///
    /// 所以统一走本机服务端的 `/api/navpacks/download/{id}`：
    /// 服务端会 302 到对象存储，`APIClient` 的 URLSession 会自己跟随
    /// （跟随后的域不需要我们的自定义证书校验，因为那是公网证书）。
    ///
    /// ⚠️ 授权码就是 `packID`，服务端那边"一个包一个码"，不另发随机串。
    static func download(packID: String) async throws -> String {
        let data: Data
        do {
            data = try await APIClient.shared.getRaw("/api/navpacks/download/\(packID)")
        } catch APIError.server(let code, let msg) {
            if code == 404 {
                // 服务端的 404 文案已经是"没有这个授权码对应的数据包：xxx"，
                // 比我们再编一句好
                throw NavServiceError.badCode(msg.isEmpty ? "没有这个授权码对应的数据包" : msg)
            }
            throw NavServiceError.server(msg.isEmpty ? "下载失败（\(code)）" : msg)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NavServiceError.notText
        }
        return text
    }
}

enum NavServiceError: LocalizedError {
    case serverTooOld
    case badCode(String)
    case server(String)
    case notText

    var errorDescription: String? {
        switch self {
        case .serverTooOld:
            return "这台服务器还没有导航数据包功能（可能是版本较旧）。你仍然可以让管理员把 .navpack.json 发给你，用下面的「从文件导入」装上。"
        case let .badCode(msg):
            return msg
        case let .server(msg):
            return msg
        case .notText:
            return "下载回来的不是一段文字 —— 可能被代理换成了错误页，换台网络再试"
        }
    }
}
