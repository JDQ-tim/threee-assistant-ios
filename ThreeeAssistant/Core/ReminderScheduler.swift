import Foundation
import UserNotifications

/// 把日程的提醒**真正排进系统**，让到点能响。
///
/// ## 这个类存在的理由
///
/// 2026-10-29 之前，App 的提醒是**假的**：新建页有「到点提醒我」、
/// 详情页会显示「提醒 提前 15 分钟」，但全工程 `UserNotifications` 引用数为 0
/// —— 数据发到服务端就没了下文，设备上永远不会响。
/// 比"没做"更糟的是它**看起来像做了**，用户会把正事交给它然后误掉。
///
/// ## 三条设计约束
///
/// 1. **交给系统排，不靠进程常驻。** `UNTimeIntervalNotificationTrigger`
///    一旦交给 `UNUserNotificationCenter`，App 被杀、被系统回收都照样触发。
///    这和安卓端 `AlarmScheduler` 的思路一致（那边用 `AlarmManager`）。
///
/// 2. **一次只排 30 天，且最多 60 条。** iOS 对单个 App 的待发通知硬上限是
///    **64 条**，超出的会被系统静默丢弃 —— 不报错、不提示，表现就是
///    "有些提醒莫名其妙不响"。所以按触发时间从近到远取前 60 条，
///    剩下的等下次重排（每次刷新、每次回前台都会补）。
///    留 4 条余量给将来别的通知（比如插件更新）。
///
/// 3. **重排是幂等的全量对账，不是增量追加。** 每次都算出"此刻应该存在的
///    那批通知"，和系统里现有的比：多的删、缺的加、时间变了的覆盖。
///    增量追加的话，删日程、改时间、关提醒这些操作迟早会漏掉一个，
///    而漏掉的表现是"改了时间但到老时间还是响" —— 用户会觉得这 App 疯了。
///
/// ## 和安卓端对齐的地方
///
/// - 触发时刻 = `startUtc - minutesBefore * 60`，**全天日程也一样**
///   （全天日程的 `start_utc` 就是当天零点，所以"提前 15 分钟"= 前一天 23:45。
///   看着怪，但和安卓端行为一致；两边不一致才是更糟的问题）
/// - 没有提醒配置就**一条都不排**，绝不兜底成"默认提前 15 分钟"
/// - 已完成的待办不提醒
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    /// 所有通知 id 的前缀。清理时靠它区分"我们排的"和"别人的"。
    ///
    /// ⚠️ 转发到 `ReminderPlan.identifierPrefix`，不自己再写一份字面量 ——
    ///    两份字面量迟早会漂移，而漂移的表现是"旧通知清不掉"：
    ///    `cancelAll` 找不到它们，用户换账号后锁屏还在弹上一个人的日程。
    static var identifierPrefix: String { ReminderPlan.identifierPrefix }

    /// 往后排多少天。和安卓端 `AlarmScheduler.WINDOW_DAYS` 一致。
    static let horizonDays = 30

    /// 最多排多少条。iOS 上限 64，留 4 条余量。
    static let maxPending = 60

    /// 两次重排之间的最小间隔，避免连续操作时反复打服务端。
    private static let minInterval: TimeInterval = 60

    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// 现在系统里排了多少条 —— 设置页显示这个数字。
    ///
    /// 为什么要有它：链路断在哪一环（没权限 / 没提醒配置 / 排上了）
    /// 从界面上完全看不出来。有个数字至少能回答"到底排上了没有"。
    private(set) var armedCount = 0
    private(set) var armedAt: Date?
    private(set) var lastError: String?

    private var lastRun: Date?
    private var running = false

    private init() {}

    /// 是否拿到了可以发通知的权限。
    var canDeliver: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    // MARK: - 权限

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// 需要时才弹系统授权框。已经决定过（同意或拒绝）就不再弹 ——
    /// iOS 一个 App 只会弹一次，第二次调用是直接返回上次的结果。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return canDeliver }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            lastError = "申请通知权限失败：\(error.localizedDescription)"
            await refreshAuthorization()
            return false
        }
    }

    // MARK: - 重排

    /// 登录成功 / App 回到前台时调。会先要权限，再排。
    func bootstrap() async {
        await requestAuthorizationIfNeeded()
        await resync(force: true)
    }

    /// 对账一次。
    ///
    /// - Parameter force: 忽略 60 秒的节流。用户主动操作（新建/改/删）后用。
    func resync(force: Bool = false) async {
        guard !running else { return }
        if !force, let last = lastRun, Date.now.timeIntervalSince(last) < Self.minInterval {
            return
        }
        running = true
        defer { running = false }

        await refreshAuthorization()
        guard canDeliver else {
            // 没权限时把已排的清掉：留着也永远不会展示，反而占着 64 条的名额。
            // 用户以后在系统设置里打开权限，回到 App 会自动重排（见 bootstrap / resync）。
            await self.cancelAll()
            return
        }

        let now = Date.now
        let from = Int64(now.timeIntervalSince1970)
        let to = from + Int64(Self.horizonDays) * 86_400
        do {
            let res: InstancesResponse = try await APIClient.shared.get(
                "/api/instances",
                query: [
                    URLQueryItem(name: "from", value: String(from)),
                    URLQueryItem(name: "to", value: String(to)),
                ]
            )
            await reconcile(instances: res.instances, now: now)
            lastRun = .now
            lastError = nil
        } catch {
            // 排通知失败**不能**影响主流程：用户只是少一次提醒，
            // 不该连日程列表都刷不出来。所以这里只记状态，不往上抛。
            lastError = "排提醒时拿不到日程：\(error.localizedDescription)"
        }
    }

    /// 退出登录 / 清空数据时调。
    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        if !mine.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: mine)
        }
        center.removeAllDeliveredNotifications()
        armedCount = 0
        armedAt = nil
        lastRun = nil
    }

    // MARK: - 对账

    private func reconcile(instances: [ScheduleInstance], now: Date) async {
        let cache = ReminderRuleCache.shared
        cache.loadIfNeeded()

        // 「排什么」全部交给纯函数（`ReminderPlan`）——
        // 那部分能在 CI 里用真实数据跑，这里只负责「怎么排」。
        let plan = ReminderPlan.build(
            instances: instances,
            rules: cache.rules,
            now: now,
            limit: Self.maxPending
        )

        // ⚠️ 用循环而不是 `Dictionary(uniqueKeysWithValues:)`。
        //    那个初始化器遇到重复 key 会 **直接 crash**，
        //    而这里 key 是 (eventID, occurrenceKey, minutes) 拼出来的 ——
        //    正常不会重复，但服务端如果某天返回了两条 occurrence_key 相同的实例
        //    （历史脏数据、override 表里残留），App 就会在排提醒时闪退，
        //    而且崩溃点离现场很远，根本查不出来。
        //    重复时后来的覆盖先来的，行为可预测。
        var desired: [String: UNNotificationRequest] = [:]
        for item in plan {
            desired[item.identifier] = Self.request(for: item, now: now)
        }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let mine = pending.filter { $0.identifier.hasPrefix(Self.identifierPrefix) }

        // 3. 删掉不该再存在的
        let stale = mine.map(\.identifier).filter { desired[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        // 4. 只加「缺的」和「时间变了的」。
        //    同 id 重复 add 会覆盖，但每次都重加 60 条没必要 ——
        //    而且时刻在变，重加会让系统反复重算触发点。
        //    触发时刻记在 userInfo 里就是为了这里能比。
        var existingFire: [String: Int64] = [:]
        for req in mine {
            if let v = Self.fireEpoch(in: req.content) {
                existingFire[req.identifier] = v
            }
        }

        for (id, req) in desired {
            let want = Self.fireEpoch(in: req.content) ?? 0
            if let have = existingFire[id], have == want { continue }
            do {
                try await center.add(req)
            } catch {
                lastError = "有一条提醒没排上：\(error.localizedDescription)"
            }
        }

        armedCount = desired.count
        armedAt = .now
    }

    /// 从 `userInfo` 里取回触发时刻。
    ///
    /// ⚠️ 别直接写 `userInfo["fire"] as? Int64`：`userInfo` 过了一遍
    ///    property-list 桥接，回来的其实是 `NSNumber`。`as? Int64` 在多数
    ///    情况下能桥成功，但不是契约保证的 —— 一旦桥失败就变成
    ///    「每次对账都认为时刻变了」，于是每次刷新都重排一遍全部通知。
    ///    显式按 `NSNumber` 取，稳。
    private static func fireEpoch(in content: UNNotificationContent) -> Int64? {
        if let n = content.userInfo["fire"] as? NSNumber { return n.int64Value }
        if let v = content.userInfo["fire"] as? Int64 { return v }
        return nil
    }

    // MARK: - 构造

    private static func request(for item: ReminderPlan.Item, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title.nonEmpty(or: "日程提醒")
        content.subtitle = headline(for: item)

        // 正文**不放备注**。
        //
        // 通知一旦落到锁屏，内容就同时暴露给锁屏预览、通知中心、
        // 以及用户误授权的通知读取类 App。而日程备注往往是最私密的一段
        // （面试准备、看病科室、给谁买什么）。标题 / 时间 / 地点是
        // "这条提醒有用"的必要信息，备注不是 —— 点进 App 就能看。
        // 安卓端 2026-10-20 那轮审计也是这么改的，这里保持一致。
        var parts = [leadText(minutes: item.minutesBefore)]
        let loc = item.location.nonEmpty(or: "")
        if !loc.isEmpty { parts.append(loc) }
        content.body = parts.joined(separator: " · ")

        content.sound = .default
        // 强提醒 = 可以穿透专注模式（对应安卓端的 HIGH 渠道 +
        // 强提醒表）。普通提醒就是常规的 .active。
        content.interruptionLevel = item.strong ? .timeSensitive : .active
        // 同一条日程的多个提醒归成一组，不会在通知中心散成一列
        content.threadIdentifier = item.eventID

        // `fire` 存进 userInfo，让下一次对账能判断"这条已经排过且时刻没变"。
        // 显式标成 `[AnyHashable: Any]` —— 字典字面量里混了 Int64 和 String，
        // 让它自己推的话可能推成 `[String: Any]`，那个类型赋不给 `userInfo`。
        let info: [AnyHashable: Any] = [
            "fire": item.fireEpoch,
            "event_id": item.eventID,
            "occurrence_key": item.occurrenceKey,
            "minutes_before": item.minutesBefore,
        ]
        content.userInfo = info

        // 用 timeInterval 而不是 calendar trigger：
        // `start_utc` 是一个**绝对时刻**，用户在别的时区时它不应该平移。
        // calendar trigger 按墙上时间算，跨时区会错开。
        let fire = Date(timeIntervalSince1970: Double(item.fireEpoch))
        let interval = max(fire.timeIntervalSince(now), 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
    }

    /// 「什么时候开始」那一句。和安卓端 `Notifier.showReminder` 的文案一致。
    private static func leadText(minutes: Int) -> String {
        if minutes <= 0 { return "现在开始" }
        if minutes < 60 { return "\(minutes) 分钟后开始" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天后开始" }
        return "\(minutes / 60) 小时后开始"
    }

    private static func headline(for item: ReminderPlan.Item) -> String {
        if item.allDay { return "全天" }
        let start = Date(timeIntervalSince1970: Double(item.startEpoch))
        let end = Date(timeIntervalSince1970: Double(item.endEpoch))
        return "\(start.hhmm) – \(end.hhmm)"
    }
}

/// 让提醒在**前台**也能弹出来。
///
/// ## 为什么必须有这个类
///
/// iOS 的默认行为是：App 正在前台时收到通知，**什么都不显示**
/// —— 系统认为"用户已经在用这个 App 了，不需要再告诉他"。
///
/// 对日程提醒来说这个默认是错的：用户正开着 App 翻下周的安排，
/// 这时候"十分钟后开会"的提醒被系统吞掉，他就真错过了。
/// 安卓端没有这个问题（`NotificationManager` 照发），
/// 所以这里如果不处理，两个平台的表现会不一样，而且 iOS 这边是**静默**的不一样。
///
/// ⚠️ delegate 必须在 App 启动时设好（见 `ThreeeAssistantApp.init`），
///    晚于第一次投递才有的话，那之前前台来的通知就丢了。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    /// 前台也展示：横幅 + 通知中心列表 + 声音。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// 用户点通知时：目前只把 App 拉到前台。
    ///
    /// 没有做「直接跳到那条日程」是因为那需要一条从通知到
    /// `ScheduleView` 的导航链路（选中日期 + 滚动 + 打开详情），
    /// 而导航状态现在全在视图内部。等真机验证过主流程再补，
    /// 现在硬做反而容易做出"点通知跳到一个空页面"的效果。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // 刻意留空
    }
}
