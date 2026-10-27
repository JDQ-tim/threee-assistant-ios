// 契约回归：拿**真实服务端响应**逐个喂给 DTO，看能不能解码。
//
// 为什么需要它：Swift 的 Codable 对字段名/类型错配**编译期零信号**。
// `ScheduleInstance.allDay` 忘了映射 "all_day"、`HealthDTO.modules`
// 把对象声明成 String? —— 这两处都是编译 100% 通过、真连服务端才炸，
// 而且一炸就是整个响应解析失败，界面空白。
//
// 这个程序不需要模拟器、不需要签名、不需要 UIKit：
// Models.swift / SyncModels.swift 只依赖 Foundation，直接和它一起编译即可。
// CI 里跑它，等于把「真机联调」的一部分提前到了每次提交。
//
// 用法：decode-check <fixtures 目录>

import Foundation

/// 每个 fixture 文件 -> 用哪个类型解。
///
/// 这里必须是**显式清单**：Swift 没有运行期按名字找类型的能力，
/// 想加新接口就加一行。故意不写"自动遍历"，那样只会假装覆盖了。
let cases: [(fixture: String, decode: (Data) throws -> Void)] = [
    ("HealthDTO", { _ = try JSONDecoder().decode(HealthDTO.self, from: $0) }),
    ("BootstrapResponse", { _ = try JSONDecoder().decode(BootstrapResponse.self, from: $0) }),
    ("CalendarsResponse", { _ = try JSONDecoder().decode(CalendarsResponse.self, from: $0) }),
    ("SyncSnapshotResponse", { _ = try JSONDecoder().decode(SyncSnapshotResponse.self, from: $0) }),
    ("TierInfoDTO", { _ = try JSONDecoder().decode(TierInfoDTO.self, from: $0) }),
    ("UsersResponse", { _ = try JSONDecoder().decode(UsersResponse.self, from: $0) }),
    ("SiteInviteDTO", { _ = try JSONDecoder().decode(SiteInviteDTO.self, from: $0) }),
    ("ModerationMetaDTO", { _ = try JSONDecoder().decode(ModerationMetaDTO.self, from: $0) }),
    ("WeatherLocationDTO", { _ = try JSONDecoder().decode(WeatherLocationDTO.self, from: $0) }),
    ("CoursePeriodsResponse", { _ = try JSONDecoder().decode(CoursePeriodsResponse.self, from: $0) }),
    ("WeatherDocDTO", { _ = try JSONDecoder().decode(WeatherDocDTO.self, from: $0) }),
    ("WordbookHealthDTO", { _ = try JSONDecoder().decode(WordbookHealthDTO.self, from: $0) }),
    ("WordbookPullResponse", { _ = try JSONDecoder().decode(WordbookPullResponse.self, from: $0) }),
    ("InboxListResponse", { _ = try JSONDecoder().decode(InboxListResponse.self, from: $0) }),
    ("TeamsResponse", { _ = try JSONDecoder().decode(TeamsResponse.self, from: $0) }),
    ("TeamDetailResponse", { _ = try JSONDecoder().decode(TeamDetailResponse.self, from: $0) }),
    ("TeamInvitesResponse", { _ = try JSONDecoder().decode(TeamInvitesResponse.self, from: $0) }),
    ("CalendarInvitesResponse", { _ = try JSONDecoder().decode(CalendarInvitesResponse.self, from: $0) }),
    ("CalendarTeamSharesResponse", { _ = try JSONDecoder().decode(CalendarTeamSharesResponse.self, from: $0) }),
]

/// 把 DecodingError 翻成人能看的一句话。
///
/// 默认的 `localizedDescription` 只给你 "The data couldn't be read"，
/// 完全不知道错在哪个字段 —— 这里的价值全在路径上。
func describe(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return "\(error)" }
    switch e {
    case let .keyNotFound(key, ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return "缺字段 \"\(key.stringValue)\"（在 \(path.isEmpty ? "根" : path)）"
    case let .typeMismatch(type, ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return "类型不符：期望 \(type)，在 \(path.isEmpty ? "根" : path)"
    case let .valueNotFound(type, ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return "值为 null 但声明为非可选 \(type)，在 \(path.isEmpty ? "根" : path)"
    case let .dataCorrupted(ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return "数据损坏：\(ctx.debugDescription)（在 \(path.isEmpty ? "根" : path)）"
    @unknown default:
        return "\(e)"
    }
}

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "Tests/fixtures"
let base = URL(fileURLWithPath: dir)

var failed = 0
var checked = 0

print("契约回归：\(dir)")
print(String(repeating: "-", count: 58))

for (name, decode) in cases {
    let url = base.appendingPathComponent("\(name).json")
    guard let data = try? Data(contentsOf: url) else {
        // fixture 缺失不算失败 —— 有些接口没探到（比如需要特定账号状态）。
        // 但要**明确报出来**，免得以为验过了。
        print("⚠️  \(name)：没有 fixture，跳过")
        continue
    }
    checked += 1
    do {
        try decode(data)
        print("✅ \(name)")
    } catch {
        failed += 1
        print("❌ \(name)：\(describe(error))")
    }
}

print(String(repeating: "-", count: 58))
print("解码 \(checked) 个，失败 \(failed) 个")

// ⚠️ 一个 fixture 都没找到时必须失败。
//
// 否则会假通过：目录改名、路径写错、忘了带 fixtures 上传，
// 程序都会平静地输出「解码 0 个，失败 0 个」然后退出码 0 ——
// 判定那一步 grep 到「失败 0 个」就放行了，等于这一关不存在。
// 「什么都没检查」和「检查了都没问题」必须区分开。
if checked == 0 {
    print("❌ 一个 fixture 都没读到，路径是 \(base.path)")
    print("   这不代表契约没问题，代表这一关根本没跑起来。")
    exit(1)
}

if failed > 0 {
    print("""
    
    提示：这些错在编译期完全看不出来，但在真机上会让**整个响应**解析失败。
    常见原因：
      - CodingKeys 漏了映射（camelCase 属性没写 = "snake_case"）
      - 把服务端的对象声明成了 String / 数组
      - 服务端该字段为 null，客户端却声明成非可选
    """)
    exit(1)
}
