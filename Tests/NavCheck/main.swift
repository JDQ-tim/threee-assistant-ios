// 导航数据包（navpack）的离线自检。
//
// 为什么需要它：`NavMatch.swift` 里全是"哪种写法算同一栋楼"的判据，
// 而那类判据**编译器一个字都不会帮你检查** —— 阈值写错、正则贪婪、
// 字符串切歪，全都表现为"某类地点认不出"，只有人工试才发现。
//
// 这个程序不需要模拟器、不需要签名、不需要 UIKit：
// `NavPack.swift`（只依赖 Foundation + CoreLocation）和
// `NavMatch.swift`（只依赖 Foundation）直接和它一起用 swiftc 编成
// 命令行程序就能跑，几秒钟出结果。
//
// 用法：navcheck <fixture.json>
//
// ⚠️ 每个用例的期望值都是**人工核对过**的，不是"跑出来是什么就写什么"。
//    后者只会把 bug 固化成基线 —— 这个项目在 `check_week_numbering.py`
//    上踩过这个坑。

import CoreLocation
import Foundation

// MARK: - 判分

var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        let d = detail()
        print("❌ \(name)\(d.isEmpty ? "" : "：\(d)")")
    }
}

func eq(_ name: String, _ got: String, _ want: String) {
    check(name, got == want, "期望 \(want.debugDescription)，实际 \(got.debugDescription)")
}

// MARK: - 读样本

let args = CommandLine.arguments
guard args.count > 1 else {
    print("用法: navcheck <fixture.json>")
    exit(2)
}
let path = args[1]
guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("❌ 读不到样本文件：\(path)")
    exit(2)
}

print("导航数据包自检：\(path)")
print(String(repeating: "-", count: 58))

// MARK: - 解析

let pack: NavPack
do {
    pack = try NavPackParser.parse(text, importedAt: 1_700_000_000)
} catch {
    print("❌ 样本解析失败：\(error.localizedDescription)")
    print("   这一条挂了，后面的匹配用例全都没意义。")
    exit(1)
}

eq("packId", pack.packID, "demo-campus")
eq("包名", pack.name, "演示校区")
eq("版本", pack.version, "1.2.0")

// 5 栋楼 + origin（origin 有名字，会被并进楼栋表）
eq("楼栋数", "\(pack.buildings.count)", "6")
// 体育馆 lat/lng 都是 0，按约定算"没标坐标"
eq("有坐标的楼栋数", "\(pack.withCoordCount)", "5")
// 有一条标注没有坐标，必须被丢掉
eq("标注数", "\(pack.marks.count)", "1")
// 楼层/房间统计只在明德楼B1 上有
eq("楼层数", "\(pack.floorCount)", "2")
eq("房间数", "\(pack.roomCount)", "6")

func building(_ name: String) -> NavBuilding? {
    pack.buildings.first { $0.name == name }
}

check("找到明德楼B1", building("明德楼B1") != nil)
check("明德楼B1 有分层", building("明德楼B1")?.hasFloors == true)
check("明德楼B1 轮廓有 4 个点", building("明德楼B1")?.shape.count == 4,
      "实际 \(building("明德楼B1")?.shape.count ?? -1)")
check("体育馆没有可用坐标", building("体育馆")?.hasCoord == false)
check("体育馆进不了地图", building("体育馆")?.coordinate == nil)
check("明德楼B1 能进地图", building("明德楼B1")?.coordinate != nil)
check("外接矩形非空", pack.bounds != nil)

// 别名参与匹配（明德楼B1 的别名里有「明德B1」）
check("别名被保留", building("明德楼B1")?.alias.contains("明德B1") == true)

// MARK: - 拒绝路径
//
// 这五条的文案给用户看的**下一步完全不同**，所以必须分别对上，
// 不能压成一句"导入失败"。

func expectError(_ name: String, _ body: String, _ want: String) {
    do {
        _ = try NavPackParser.parse(body, importedAt: 0)
        check(name, false, "本该报错，却解析成功了")
    } catch let e as NavPackError {
        let desc = e.errorDescription ?? ""
        check(name, desc == want, "错误文案不符：\(desc.debugDescription)")
    } catch {
        check(name, false, "抛的不是 NavPackError：\(error)")
    }
}

expectError("空文件被拒", "   ",
            "文件是空的 —— 可能没下载完，也可能拿错了文件")
expectError("不是 JSON 被拒", "{ 这不是 json",
            "这不是一个 JSON 文件 —— 请确认你导出的是 .navpack.json")
expectError("不是我们的文件被拒", #"{"format":"other","formatVersion":1}"#,
            "这不是导航数据包（缺少 \"format\": \"threees.navpack\"）—— 请确认你导出的是「含标注的 .navpack.json」，不是别的文件")
expectError("版本太新被拒",
            #"{"format":"threees.navpack","formatVersion":99,"packId":"abc","buildings":[{"name":"x"}]}"#,
            "这个包是更新版本（formatVersion 99）做的，当前只认到 2 —— 请先升级学习助手")
expectError("授权码格式不对被拒",
            #"{"format":"threees.navpack","formatVersion":2,"packId":"Bad_ID","buildings":[{"name":"x"}]}"#,
            "包标识（packId）不合法：\"Bad_ID\" —— 它必须是 2~48 位小写字母、数字或连字符，且以字母开头")
expectError("空包被拒",
            #"{"format":"threees.navpack","formatVersion":2,"packId":"abc","buildings":[{"name":""}]}"#,
            "这个包里一栋楼都没有 —— 导进去不能导航到任何地方，请确认导出时标过楼栋")

// MARK: - 匹配
//
// 期望值全部按**用户的真实写法**人工定，覆盖：
//   完全一致 / 带房号 / 连字符 / 紧跟楼名 / 中文单位 / 方位词 /
//   别名 / 名字里带井号 / 全角 / 错一个字 / 认不出

struct Case {
    let input: String
    /// 期望命中的楼名；nil = 认不出
    let building: String?
    let room: String
    let kind: String
}

let cases: [Case] = [
    Case(input: "明德楼B1", building: "明德楼B1", room: "", kind: "exact"),
    Case(input: "明德楼B1 302", building: "明德楼B1", room: "302", kind: "room"),
    Case(input: "明德楼B1-302", building: "明德楼B1", room: "302", kind: "room"),
    Case(input: "明德楼B1302", building: "明德楼B1", room: "302", kind: "room"),
    Case(input: "明德楼B1 13楼", building: "明德楼B1", room: "13楼", kind: "room"),
    // 方位词后缀：iOS 没有联网兜底，必须靠规则认出来
    Case(input: "明德楼B1门口", building: "明德楼B1", room: "", kind: "room"),
    Case(input: "第一食堂 2楼", building: "第一食堂", room: "2楼", kind: "room"),
    Case(input: "第一食堂楼下", building: "第一食堂", room: "", kind: "room"),
    // 别名
    Case(input: "明德B1 203", building: "明德楼B1", room: "203", kind: "room"),
    // 楼名自己就带井号：不能因为切了井号就认不出
    Case(input: "主4#201", building: "主4#201", room: "201", kind: "exact"),
    Case(input: "主4 305", building: "主4#201", room: "305", kind: "room"),
    // 全角：中文输入法下打出来的样子
    Case(input: "明德楼Ｂ１ ３０２", building: "明德楼B1", room: "302", kind: "room"),
    // 错一个字 → 模糊命中，界面要标"可能会错"
    Case(input: "明得楼B1", building: "明德楼B1", room: "", kind: "fuzzy"),
    // 没标坐标的楼也要认出来（只是导不了航）
    Case(input: "体育馆", building: "体育馆", room: "", kind: "exact"),
    // 楼名太短（一个字）不参与匹配，避免乱认
    Case(input: "图书馆", building: nil, room: "", kind: "无"),
]

for c in cases {
    let s = NavMatcher.split(c.input, in: pack.buildings)
    let gotName = s.building?.name ?? "（认不出）"
    let wantName = c.building ?? "（认不出）"
    let kind: String
    if let m = NavMatcher.match(c.input, in: pack.buildings) {
        switch m.kind {
        case .exact: kind = "exact"
        case .room: kind = "room"
        case .fuzzy: kind = "fuzzy"
        }
    } else {
        kind = "无"
    }

    let label = "「\(c.input)」"
    check(label + " 命中楼栋", gotName == wantName, "期望 \(wantName)，实际 \(gotName)")
    check(label + " 房号", s.room == c.room, "期望 \(c.room.debugDescription)，实际 \(s.room.debugDescription)")
    check(label + " 匹配类型", kind == c.kind, "期望 \(c.kind)，实际 \(kind)")
}

// 数字太多时**不能编一个房号出来**：`\d{1,6}` 贪婪截取会把 7 位截成 6 位
let longDigits = NavMatcher.split("明德楼B1 1234567", in: pack.buildings)
check("7 位数字不当房号", longDigits.room.isEmpty, "实际 \(longDigits.room.debugDescription)")

// 拆不动时**原文原样返回**，一个字都不能动
let untouched = NavMatcher.split("完全不存在的地方", in: pack.buildings)
check("认不出时原文不动", untouched.place == "完全不存在的地方",
      "实际 \(untouched.place.debugDescription)")

// 终点名必须是楼自己的名字，不能带房号 ——
// 带房号会让地图去搜一个不存在的地点
let nav = NavMatcher.split("明德楼B1 302", in: pack.buildings)
check("终点名不带房号", nav.place == "明德楼B1", "实际 \(nav.place.debugDescription)")

print(String(repeating: "-", count: 58))
print("通过 \(passed) 项，失败 \(failed) 项")

if failed > 0 {
    print("""
    
    提示：这些错编译期看不出来，真机上表现为"某类地点突然认不出"。
    常见原因：
      - 归一化没做（全角/空格/大小写）
      - 贪心正则把长数字截成假房号
      - 阈值改动后没有重新核对样本
    """)
    exit(1)
}
