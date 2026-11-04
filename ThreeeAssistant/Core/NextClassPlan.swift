import Foundation

/// 「现在锁屏上该挂哪一节」—— **纯函数**，不碰 ActivityKit、不读文件。
///
/// ## 为什么单独抽出来
///
/// 这和 `ReminderPlan` 是同一个理由：`ActivityKit` 在 Windows 上编不了，
/// 而"挑哪一条"恰恰是这块功能里唯一有判断的地方。
/// 抽出来之后，CI 里用 `swiftc` 编成命令行程序，拿人造数据把每个边界跑一遍。
///
/// 抽出来之前的版本有个真 bug（2026-11-04 发现）：
///
/// ```
/// 周六下午，下一节课是周一 08:00。
/// 旧判据：start > now && start <= now + horizon(8h) && lead <= 30min
///         → 周一太远，pool 里挑不出东西 → endAll() → 锁屏空白
/// ```
///
/// 而且注释里写的 `horizon` 是"只在这段时间内找"，实际却被 `&&` 和
/// `leadTime` 串起来，**horizon 永远不起作用**（30 分钟 < 8 小时恒成立）。
/// 那段代码同时有两层错：意图是"30 分钟内才开"，实现却要求"必须在 8 小时内"，
/// 两者都没表达出"多久以内算下一节"。
///
/// ## 现在的规则
///
/// 是否该挂，只看**离这一刻多远**，分段各有一条线：
///
/// | 情形 | 挂不挂 | 线 |
/// |---|---|---|
/// | 正在上的（`start <= now < end`） | 挂 | 开始至今不超过 `ongoingLimit` |
/// | 今天剩下的课，在 `leadTime` 内 | 挂 | 立刻挂，倒计时 |
/// | 今天剩下的课，在 `leadTime` 外 | **不挂** | 等到进 `leadTime` 再挂 |
/// | **明天**的课，在今天最后一节课下课后 | 挂 | 睡前就能看见明早第一节 |
/// | 后天及以后 | 不挂 | 提前两天挂着只会被无视 |
///
/// 「今天」按**自然日**算，不是"往前推 24 小时"——
/// 凌晨 1 点看时，昨天 23 点的课属于"昨天"，不该再挂。
///
/// ## 一个刻意的取舍：周末挂周一的课
///
/// 「明天」那条只解释得了周日晚上的情况。周六下午到周日下午，
/// 下一节课在 40 多个小时之后，按上表属于"不挂"——
/// 锁屏上整整一天半什么都没有。
///
/// 但这里不额外加一条"周一也算明天"的规则。理由：
/// `Activity.request` 挂上去之后，**只要进程不在，就没有任何人能更新它**
/// （这是实时活动的机制，不是这家 App 的限制）。真要连续挂 40 小时，
/// 卡片上的"下周一开始"就得靠静态文本，而它一旦写错、
/// 或者课程被改到别的日子，用户在锁屏上看到的就是一条假信息，
/// 且不会自己消失 —— 比"周末不显示"坏得多。
///
/// 所以周末就是不显示。这是可选功能，缺一天比给错一天便宜。
struct NextClassPlan {

    /// 挑出来的那一节，已经摊平成界面要的字段。
    ///
    /// 不用 `ScheduleInstance` 直接用，是因为离线自检里构造它要走
    /// Decodable，而这里只需要四个字段。
    struct Pick: Equatable {
        let eventID: String
        let title: String
        let location: String
        let start: Date
        let end: Date
        /// 现在还没开始（用于"还有多久"的文案）。
        let isUpcoming: Bool
        /// 这一节其实在**明天**（睡前预告）。
        let isTomorrow: Bool
    }

    /// 开课前多久开始挂。
    static let leadTime: TimeInterval = 2 * 3600

    /// 已经在上的课，开始超过这么久就不再挂 ——
    /// 防止一条 6 小时的"自习"从早上挂到下午，用户会以为 App 卡住了。
    static let ongoingLimit: TimeInterval = 3 * 3600

    /// 选出现在该挂的那一节。没有就返回 nil（调用方据此收掉活动）。
    ///
    /// - Parameters:
    ///   - items: 已摊平的待选日程（调用方负责排除待办和全天）。
    ///   - now: 当前时刻。显式传入，否则没法测。
    ///   - calendar: 判"今天/明天"用。显式传入，避免和用户时区不一致。
    static func pick(items: [Pick],
                     now: Date,
                     calendar: Calendar = .current) -> Pick? {

        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }

        // ① 正在上的：优先，取开始最早的那节（也就是最接近下课的那节）。
        let ongoing = items.filter { $0.start <= now && $0.end > now }
            .filter { now.timeIntervalSince($0.start) <= ongoingLimit }
        if let current = ongoing.min(by: { $0.start < $1.start }) {
            return current
        }

        // ② 还没开始的课，按开始时间排。
        let upcoming = items.filter { $0.start > now }.sorted { $0.start < $1.start }
        guard let next = upcoming.first else { return nil }

        // ③ 是今天的、且在 leadTime 内 → 挂。
        if calendar.isDate(next.start, inSameDayAs: now) {
            return next.start.timeIntervalSince(now) <= leadTime ? next : nil
        }

        // ④ 是明天的 → 只在"今天已经没有课了"之后才挂。
        //
        //    为什么加这个条件：早上 8 点看，今天的课还一整天没上，
        //    这时候把明早第一节顶到锁屏上，用户会以为今天没课。
        if calendar.isDate(next.start, inSameDayAs: tomorrow) {
            let stillToday = items.contains {
                $0.end > now && calendar.isDate($0.start, inSameDayAs: now)
            }
            return stillToday ? nil : next
        }

        // ⑤ 后天及以后：不挂。
        return nil
    }
}
