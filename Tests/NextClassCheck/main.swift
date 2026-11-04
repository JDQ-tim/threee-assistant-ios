// 实时活动「该挂哪一节」的逻辑校验。
//
// 为什么需要它：灵动岛这条链路上唯一有判断的地方就是"挑哪一条"，
// 而它**只有在特定的钟点才会走错**，在真机上几乎不可能覆盖全 ——
// 得等到周六下午才看得见那个 bug。
//
// 2026-11-04 就踩了一个：旧判据把 `horizon(8h)` 和 `leadTime(30min)`
// 用 `&&` 串起来，结果"下一节课在两天后"和"下一节课在 1 小时后"
// 走的是同一条判断，而注释里写的意图是两件不同的事。
//
// 这里只编 NextClassPlan.swift（纯 Foundation），不碰 ActivityKit，
// 所以能在 CI 的 macOS runner 上直接跑，不需要模拟器和签名。
//
// 用法：nextclass-check
//
// 所有时刻都用**固定日期 + 固定时区**算，不读当前时间 ——
// 用例要能每天、在任何一个 runner 上跑出同样的结论。
// 2026-11-07 是周六（用一个 11 月的普通周末当基线，避开节假日）。

import Foundation

var failures: [String] = []
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond {
        failures.append(what)
    }
}

// MARK: - 时区固定的日历

var cal = Calendar(identifier: .gregorian)
// 用东八区：用户在国内，且 +8 不会在半夜把日期跳过一天，
// 用例里的"上午 10 点"就是真的上午 10 点。
cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

/// 2026-11-07 是周六。
func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026
    c.month = month
    c.day = day
    c.hour = hour
    c.minute = minute
    return cal.date(from: c)!
}

func item(_ id: String,
          _ start: Date,
          _ end: Date,
          title: String = "某课",
          location: String = "") -> NextClassPlan.Pick {
    NextClassPlan.Pick(eventID: id, title: title, location: location,
                       start: start, end: end, isUpcoming: true, isTomorrow: false)
}

// MARK: - 1. 正在上的课：优先，取开始最早的

do {
    let now = at(11, 7, 10, 30)                      // 周六 10:30
    let a = item("a", at(11, 7, 8), at(11, 7, 10))   // 已下课
    let b = item("b", at(11, 7, 10), at(11, 7, 12))  // 正在上
    let c = item("c", at(11, 7, 14), at(11, 7, 16))  // 下午
    let r = NextClassPlan.pick(items: [a, b, c], now: now, calendar: cal)
    expect(r?.eventID == "b", "正在上的课要优先于后面还没开始的")
}

// MARK: - 2. 正在上、但已经上了太久（超过 ongoingLimit）→ 不挂

do {
    let now = at(11, 7, 12, 30)
    // 08:00 开始，到现在已经 4.5 小时，超过 3 小时的线。
    // 这种多半是一条写错时长的"自习/实验"，挂上去会把整晚的卡片都占掉。
    let long = item("long", at(11, 7, 8), at(11, 7, 18))
    let next = item("next", at(11, 7, 14), at(11, 7, 16))
    let r = NextClassPlan.pick(items: [long, next], now: now, calendar: cal)
    expect(r?.eventID == "next", "上了 3 小时以上的不再顶到岛上，要换成下一节")
}

// MARK: - 3. 正好 3 小时 → 仍然算（边界含等号）

do {
    let now = at(11, 7, 11)
    let exactly = item("e", at(11, 7, 8), at(11, 7, 12))
    let r = NextClassPlan.pick(items: [exactly], now: now, calendar: cal)
    expect(r?.eventID == "e", "正好上满 3 小时仍算正在上（边界是含等号）")
}

// MARK: - 4. leadTime 边界：2 小时内挂，2 小时外不挂

do {
    let now = at(11, 7, 10)
    let inTwo = item("in2", at(11, 7, 12), at(11, 7, 14))
    expect(NextClassPlan.pick(items: [inTwo], now: now, calendar: cal)?.eventID == "in2",
           "2 小时后开始的课要挂出来（含边界）")

    let in209 = item("in209", at(11, 7, 12, 9), at(11, 7, 14))
    expect(NextClassPlan.pick(items: [in209], now: now, calendar: cal) == nil,
           "2 小时 9 分后的课还不该挂 —— 提前太多会从早占到晚")
}

// MARK: - 5. 今天的课排到很晚，中间的空档不能提前挂

do {
    let now = at(11, 7, 9)
    let evening = item("evening", at(11, 7, 19), at(11, 7, 21))
    let r = NextClassPlan.pick(items: [evening], now: now, calendar: cal)
    expect(r == nil, "晚上 7 点的课，上午 9 点不该挂（差 10 小时）")
}

// MARK: - 6. 明天第一节：今天已经没课了 → 挂

do {
    // 周日晚 21 点，周一 08:00 有课。
    let now = at(11, 8, 21)
    let today = item("today", at(11, 8, 8), at(11, 8, 10))
    let tomorrow = item("mon", at(11, 9, 8), at(11, 9, 9, 40), title: "高数")
    let r = NextClassPlan.pick(items: [today, tomorrow], now: now, calendar: cal)
    expect(r?.eventID == "mon", "今天没课了之后，明天第一节要挂出来")
}

// MARK: - 7. 明天第一节：今天还有课 → 不挂（否则看起来像今天没课）

do {
    let now = at(11, 8, 8)
    let todayLater = item("today3", at(11, 8, 15), at(11, 8, 17))
    let tomorrow = item("mon", at(11, 9, 8), at(11, 9, 9, 40))
    let r = NextClassPlan.pick(items: [todayLater, tomorrow], now: now, calendar: cal)
    expect(r == nil, "今天下午还有课，上午不该把明天的课顶上来")
}

// MARK: - 8. 空列表

do {
    let r = NextClassPlan.pick(items: [], now: at(11, 7, 10), calendar: cal)
    expect(r == nil, "没有任何待选日程时返回 nil（调用方据此收掉活动）")
}

// MARK: - 9. 全部是已经上完的课

do {
    let now = at(11, 7, 22)
    let a = item("a", at(11, 7, 8), at(11, 7, 10))
    expect(NextClassPlan.pick(items: [a], now: now, calendar: cal) == nil,
           "今天的课都上完了、明天也没课 → 不挂")
}

// MARK: - 10. 后天及以后：不挂

do {
    let now = at(11, 7, 10)                                  // 周六
    let monday = item("mon", at(11, 9, 8), at(11, 9, 10))    // 周一
    expect(NextClassPlan.pick(items: [monday], now: now, calendar: cal) == nil,
           "周六看周一，差 40 多小时，不该挂（挂了就得连续挂着没人能更新它）")
}

// MARK: - 11. 自然日判定：凌晨不该把昨天 23 点的课当成"正在上"

do {
    // 周日 00:30 看，昨晚 23:00-23:50 那节已经上完 → 不该挂。
    // 如果实现用的是"往前推 24 小时"而不是自然日，这里会判错。
    let now = at(11, 8, 0, 30)
    let late = item("late", at(11, 7, 23), at(11, 7, 23, 50))
    expect(NextClassPlan.pick(items: [late], now: now, calendar: cal) == nil,
           "凌晨 0:30 时，昨晚的课已经结束，不该再挂")
}

// MARK: - 12. 跨零点的课：正在上就挂

do {
    // 周六 23:00 – 周日 01:00 的跨零点活动，周日子夜 0:30 仍应挂。
    let now = at(11, 8, 0, 30)
    let overnight = item("overnight", at(11, 7, 23), at(11, 8, 1))
    let r = NextClassPlan.pick(items: [overnight], now: now, calendar: cal)
    expect(r?.eventID == "overnight", "跨零点的正在进行的日程要照挂（end > now 就够）")
}

// MARK: - 13. 两节同一时间开始 → 结果不抖动

do {
    let now = at(11, 7, 10)
    let x = item("x", at(11, 7, 11), at(11, 7, 12))
    let y = item("y", at(11, 7, 11), at(11, 7, 12))
    // 时间完全相同时取谁都行，但**不能每次都不一样** ——
    // 否则每次 sync 都换一条，活动会被不停地结束再重开，
    // 灵动岛上看得见地跳一下。
    //
    // ⚠️ 这里刻意**不要求**正序和反序得到同一条：
    //    相等元素的取舍取决于容器顺序，硬要求一致就得给 Pick 加
    //    第二排序键（eventID）。而现在 `sync` 的调用方传进来的
    //    `store.instances` 顺序是稳定的（按 startUTC 排好），
    //    所以"同输入同输出"就足以保证不抖。
    let a = NextClassPlan.pick(items: [x, y], now: now, calendar: cal)?.eventID
    let b = NextClassPlan.pick(items: [x, y], now: now, calendar: cal)?.eventID
    let c = NextClassPlan.pick(items: [y, x], now: now, calendar: cal)?.eventID
    let d = NextClassPlan.pick(items: [y, x], now: now, calendar: cal)?.eventID
    expect(a != nil && a == b, "同一输入多次调用结果稳定")
    expect(c != nil && c == d, "同一输入多次调用结果稳定（反序）")
}

// MARK: - 14. 边界常量本身

do {
    // 这两个数会直接印在设置页的文案里，改代码必须同步改文案。
    expect(NextClassPlan.leadTime == 2 * 3600, "leadTime 是 2 小时")
    expect(NextClassPlan.ongoingLimit == 3 * 3600, "ongoingLimit 是 3 小时")
}

// MARK: - 汇总

print("实时活动选课自检：\(checks - failures.count) 通过 / \(failures.count) 失败（共 \(checks) 项）")
if !failures.isEmpty {
    print("")
    for (i, f) in failures.enumerated() {
        print("  \(i + 1). \(f)")
    }
    exit(1)
}
