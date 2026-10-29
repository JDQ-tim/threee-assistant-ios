// 提醒排程的逻辑校验：拿真实快照数据 + 合成数据，验证「该排哪些通知」算得对。
//
// 为什么需要它：提醒功能的核心不是调 `UNUserNotificationCenter`
// （那只是把结果交给系统），而是**决定排什么** ——
// 哪些该响、哪些该被丢掉、64 条上限怎么截、已完成的待办要不要排。
// 这部分逻辑错了，表现是「有些提醒不响」或者「删了还响」，
// 而这两种都极难在真机上复现定位。
//
// 这里只编 ReminderPlan.swift（纯 Foundation），不碰 UserNotifications，
// 所以能在 CI 的 macOS runner 上直接跑，不需要模拟器和签名。
//
// 用法：reminder-check <fixtures 目录>

import Foundation

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "Tests/fixtures"
let snapshotURL = URL(fileURLWithPath: dir).appendingPathComponent("SyncSnapshotResponse.json")

var failures: [String] = []
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures.append(what) }
}

// MARK: - 合成实例

let fixedDoneAt: Int64 = 1_700_000_000

/// `ScheduleInstance` 只声明了 `init(from:)`，memberwise init 被抑制了，
/// 所以这里只能走 JSON —— 顺带也把解码路径覆盖一遍。
func makeInstances(_ specs: [(id: String, eventID: String, start: Int64, isTask: Bool, doneAt: Int64?)]) -> [ScheduleInstance] {
    var rows: [[String: Any]] = []
    for s in specs {
        var row: [String: Any] = [
            "id": s.id,
            "event_id": s.eventID,
            "calendar_id": "cal1",
            "start_utc": s.start,
            "end_utc": s.start + 3600,
            "all_day": false,
            "title": "t",
            "notes": "",
            "location": "",
            "is_task": s.isTask,
            "is_override": false,
            "occurrence_key": s.start,
        ]
        // ⚠️ 不能写 `s.doneAt as Any` —— 那会把 Optional 本身塞进 JSON 字典，
        //    JSONSerialization 遇到 Optional 直接抛 invalidObjectType。
        row["done_at"] = s.doneAt.map { $0 as Any } ?? NSNull()
        rows.append(row)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: rows),
          let parsed = try? JSONDecoder().decode([ScheduleInstance].self, from: data)
    else { return [] }
    return parsed
}

// MARK: - A. 真实快照

print("提醒排程校验：\(snapshotURL.path)")
print(String(repeating: "-", count: 58))

var realInstances: [ScheduleInstance] = []
var realRules: [String: EventReminderRule] = []

if let data = try? Data(contentsOf: snapshotURL),
   let snap = try? JSONDecoder().decode(SyncSnapshotResponse.self, from: data) {
    realInstances = snap.instances ?? []
    for ev in (snap.events ?? []) where !ev.reminders.isEmpty {
        realRules[ev.id] = EventReminderRule(
            minutesBefore: ev.reminders.map { Int($0.minutesBefore) }.sorted(),
            strong: ev.strong
        )
    }
}

if realInstances.isEmpty || realRules.isEmpty {
    // 和契约检查同样的道理：读不到数据不能算通过。
    print("❌ 快照里没有可用的实例或提醒配置，这一关等于没跑")
    exit(1)
}

print("真实数据：\(realInstances.count) 个实例 / \(realRules.count) 条提醒配置")

// `now` 取「比最早实例再早三天」——
// 必须留出余量，因为最长的提醒是"提前 1 天"，只早一天的话
// `fire == now`，会被 `fire > now` 正确地排除掉，导致期望值算不准。
let earliestStart = realInstances.map(\.startUTC).min() ?? 0
let nowEarly = Date(timeIntervalSince1970: Double(earliestStart - 3 * 86_400))
let nowEpoch = Int64(nowEarly.timeIntervalSince1970)

let realPlan = ReminderPlan.build(
    instances: realInstances,
    rules: realRules,
    now: nowEarly,
    limit: 60
)

/// 独立算一遍期望值，不复用被测代码。
var expectedCount = 0
for inst in realInstances {
    guard let rule = realRules[inst.eventID], !rule.minutesBefore.isEmpty else { continue }
    if inst.isTask && inst.doneAt != nil { continue }
    for m in rule.minutesBefore where inst.startUTC - Int64(m) * 60 > nowEpoch {
        expectedCount += 1
    }
}

expect(realPlan.count == expectedCount,
       "真实数据：期望 \(expectedCount) 条，实到 \(realPlan.count) 条")
expect(realPlan.count > 0, "真实数据：一条都没排出来（提醒功能等于没接上）")

expect(realPlan.allSatisfy { $0.fireEpoch > nowEpoch },
       "真实数据：排出了已经过去的时刻")

var ascending = true
for i in 1..<max(realPlan.count, 1) where realPlan[i].fireEpoch < realPlan[i - 1].fireEpoch {
    ascending = false
}
expect(ascending, "真实数据：结果没有按触发时间升序")

let ids = realPlan.map(\.identifier)
expect(Set(ids).count == ids.count, "真实数据：通知 id 有重复（后一条会覆盖前一条）")
expect(ids.allSatisfy { $0.hasPrefix(ReminderPlan.identifierPrefix) },
       "真实数据：id 前缀不对，cancelAll 会清不掉它们")
expect(realPlan.allSatisfy { $0.identifier.hasSuffix(".\($0.minutesBefore)") },
       "真实数据：id 里没有带上提前分钟数")

expect(realPlan.allSatisfy { $0.fireEpoch == $0.startEpoch - Int64($0.minutesBefore) * 60 },
       "真实数据：触发时刻算错了（不等于 start − minutes×60）")

// 已完成的待办不排
for inst in realInstances where inst.isTask && inst.doneAt != nil {
    let leaked = realPlan.contains {
        $0.eventID == inst.eventID && $0.occurrenceKey == inst.occurrenceKey
    }
    expect(!leaked, "真实数据：已完成的待办还是排了提醒（\(inst.id)）")
}

// MARK: - B. 负向

let negativeInstances = makeInstances([
    ("i1", "e1", earliestStart, false, nil),
])
expect(negativeInstances.count == 1, "合成实例解码失败，后面的负向用例不可信")

expect(ReminderPlan.build(instances: negativeInstances, rules: [:], now: nowEarly, limit: 60).isEmpty,
       "负向：没有任何提醒配置却排出了通知")

expect(ReminderPlan.build(
    instances: negativeInstances,
    rules: ["e1": EventReminderRule(minutesBefore: [], strong: false)],
    now: nowEarly,
    limit: 60
).isEmpty, "负向：提醒被清空后仍然排了通知（安卓端踩过的那个坑）")

// 时间已过 → 不排
let afterStart = Date(timeIntervalSince1970: Double(earliestStart + 7200))
expect(ReminderPlan.build(
    instances: negativeInstances,
    rules: ["e1": EventReminderRule(minutesBefore: [15, 0], strong: false)],
    now: afterStart,
    limit: 60
).isEmpty, "负向：所有触发时刻都过去了，还是排出了通知")

// 已完成的待办 → 不排
let doneTasks = makeInstances([("i2", "e1", earliestStart, true, fixedDoneAt)])
expect(ReminderPlan.build(
    instances: doneTasks,
    rules: ["e1": EventReminderRule(minutesBefore: [15], strong: false)],
    now: nowEarly,
    limit: 60
).isEmpty, "负向：已完成的待办还是排了提醒")

// MARK: - C. 64 条上限

var specs: [(id: String, eventID: String, start: Int64, isTask: Bool, doneAt: Int64?)] = []
for i in 0..<200 {
    specs.append(("cap\(i)", "ce\(i)", earliestStart + Int64(i) * 600, false, nil))
}
let manyInstances = makeInstances(specs)
expect(manyInstances.count == 200, "上限用例的实例没造出来（\(manyInstances.count)/200）")

var manyRules: [String: EventReminderRule] = [:]
for i in 0..<200 {
    manyRules["ce\(i)"] = EventReminderRule(minutesBefore: [5], strong: false)
}

let capped = ReminderPlan.build(instances: manyInstances, rules: manyRules, now: nowEarly, limit: 60)
expect(capped.count == 60, "上限：limit=60 却排了 \(capped.count) 条（iOS 只允许 64 条待发通知）")
expect(capped.first?.eventID == "ce0", "上限：截断后没有保留最早的那条")
expect(capped.last?.eventID == "ce59", "上限：保留的不是最早的 60 条")

// 同一份输入两次结果必须一致 —— 否则「截断到 60 条」每次选出不同集合，
// 表现是提醒忽有忽无。
let again = ReminderPlan.build(instances: manyInstances, rules: manyRules, now: nowEarly, limit: 60)
expect(again.map(\.identifier) == capped.map(\.identifier), "上限：同一输入两次结果不一致（顺序不稳定）")

// MARK: - 结论

print(String(repeating: "-", count: 58))
print("断言 \(checks) 条，失败 \(failures.count) 条")

if !failures.isEmpty {
    for f in failures { print("❌ \(f)") }
    print("""

        提示：这些错在编译期完全看不出来。最常见的两个后果是
          · 该响的不响（候选被误判成"没有提醒配置"）
          · 删了还响（过去的时刻没有被过滤掉）
        """)
    exit(1)
}

// 和契约检查一样：一条断言都没跑也算失败，避免"一直绿但什么都没查"
if checks < 15 {
    print("❌ 只跑了 \(checks) 条断言，明显不完整 —— 这一关等于没验")
    exit(1)
}

print("✅ 全部通过")
