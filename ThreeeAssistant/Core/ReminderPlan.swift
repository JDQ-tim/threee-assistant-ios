import Foundation

/// 一条日程的提醒配置（本地缓存的那一份）。
///
/// ## 为空 = 明确不提醒，不是「没同步下来」
///
/// 服务端对 `reminders` **不加 omitempty**：`[]` 表示「这条不提醒我」。
/// 这两种情况必须严格区分：
///
///   · 缓存里**没有**这个 eventID → 不知道，先不排（等快照补）
///   · 缓存里是空数组 → 用户明确关掉了提醒 → **一条都不排**
///
/// 安卓端在这里踩过坑：以前写成 `reminders.ifEmpty { listOf(Reminder(0)) }`，
/// 把上面两种混成一件，结果是「用户在编辑页取消所有提醒、保存，回来闹钟照响」。
/// 这里不设任何默认值。
struct EventReminderRule: Codable, Hashable {
    /// 提前多少分钟。0 = 准点。可以为空（明确不提醒）。
    var minutesBefore: [Int]
    /// 强提醒。到点用 `.timeSensitive`，可以穿透专注模式。
    var strong: Bool

    var isActive: Bool { !minutesBefore.isEmpty }
}

/// 「此刻应该排哪些提醒」—— **纯函数**，不碰 `UserNotifications`、不读文件。
///
/// ## 为什么单独抽出来
///
/// 这是整个提醒功能里唯一有逻辑的部分：什么时候该响、哪几条该被丢掉、
/// 64 条上限怎么截。而它**没法在 Windows 上跑**（iOS 模拟器都没有），
/// 所以必须做到「不依赖任何 iOS 专有类型」，才能在 CI 里用 `swiftc`
/// 编成命令行程序、拿真实数据跑一遍。
///
/// 抽出来之后的边界很干净：
///   · 这里决定「排什么」（纯计算，可测）
///   · `ReminderScheduler` 只负责「怎么排」（调系统 API）
///   · `ReminderRuleCache` 只负责「提醒配置从哪来」（持久化）
///
/// ## 三条必须守住的规则
///
/// 1. **过去的时刻不排。** 排了也不会触发，只会占掉 64 条名额里的一格。
/// 2. **已完成的待办不排。** 用户已经勾掉了，再弹一次是纯骚扰。
/// 3. **按时间从近到远截断。** iOS 对单个 App 的待发通知上限是 64 条，
///    超出的被系统**静默丢弃**，而且丢哪条不确定 —— 所以必须自己截，
///    并且永远保留最近的那些。
struct ReminderPlan {

    /// 一条待排的提醒。
    struct Item: Equatable {
        /// 通知 id。`threee.reminder.<eventID>.<occurrenceKey>.<minutes>`
        let identifier: String
        let eventID: String
        let occurrenceKey: Int64
        let minutesBefore: Int
        let strong: Bool
        /// 触发时刻（epoch 秒）。
        let fireEpoch: Int64
        /// 日程开始时刻（epoch 秒），用来拼通知正文里的时间。
        let startEpoch: Int64
        let title: String?
        let location: String?
        let allDay: Bool
        let endEpoch: Int64
    }

    static let identifierPrefix = "threee.reminder."

    /// 算出该排的全部提醒，已按触发时间升序、已截断到 `limit` 条。
    ///
    /// - Parameters:
    ///   - instances: 未来一段时间的日程实例（`GET /api/instances`）。
    ///   - rules: `eventID -> 提醒配置`。
    ///   - now: 当前时刻。显式传入而不是内部取 `Date()`，否则没法测。
    ///   - limit: 最多排几条。
    static func build(instances: [ScheduleInstance],
                      rules: [String: EventReminderRule],
                      now: Date,
                      limit: Int) -> [Item] {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        var out: [Item] = []

        for inst in instances {
            // 规则不在缓存里 = 不知道，跳过；规则为空 = 明确不提醒，也跳过。
            guard let rule = rules[inst.eventID], rule.isActive else { continue }
            // 已完成的待办不再提醒
            if inst.isTask, inst.doneAt != nil { continue }

            for minutes in rule.minutesBefore {
                let fire = inst.startUTC - Int64(minutes) * 60
                // 只排将来的。等于 now 的也跳过 —— 排了也是立刻触发，
                // 而系统对"间隔 <= 0"的触发器行为不保证。
                guard fire > nowEpoch else { continue }
                out.append(Item(
                    identifier: identifier(eventID: inst.eventID,
                                           occurrenceKey: inst.occurrenceKey,
                                           minutes: minutes),
                    eventID: inst.eventID,
                    occurrenceKey: inst.occurrenceKey,
                    minutesBefore: minutes,
                    strong: rule.strong,
                    fireEpoch: fire,
                    startEpoch: inst.startUTC,
                    title: inst.title,
                    location: inst.location,
                    allDay: inst.allDay,
                    endEpoch: inst.endUTC
                ))
            }
        }

        // 同一时刻的多条按 id 再排一次，保证结果**稳定** ——
        // 不稳定的顺序会让「截断到 60 条」这件事每次选出不同的集合，
        // 表现是提醒忽有忽无。
        out.sort {
            if $0.fireEpoch != $1.fireEpoch { return $0.fireEpoch < $1.fireEpoch }
            return $0.identifier < $1.identifier
        }

        // `prefix` 对负数会**直接 crash**（Precondition failed），
        // 所以先夹一下。调用方永远传 60，但库代码不该靠调用方守规矩。
        let cap = max(0, limit)
        if out.count > cap {
            out = Array(out.prefix(cap))
        }
        return out
    }

    static func identifier(eventID: String, occurrenceKey: Int64, minutes: Int) -> String {
        "\(identifierPrefix)\(eventID).\(occurrenceKey).\(minutes)"
    }
}
