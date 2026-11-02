import AppIntents
import Foundation

// ============================================================
//  Siri / 快捷指令 / 聚焦搜索的入口
//  ------------------------------------------------------------
//
//  ⚠️ 这一组文件的定位：**只读 + 一条写入**（新建日程）。
//     不做「改时间」「删日程」「分享」—— 那些需要用户在列表里
//     先看清是哪一条，语音里说不清楚，做出来只会误操作。
//
//  ⚠️ 所有 `perform()` 都在**非主线程**的后台上下文里跑。
//     所以这里不碰 SessionStore、不碰任何 View，
//     数据全部经由 `IntentSession` 直接走 APIClient。
//
//  ⚠️ 返回给 Siri 的字符串要短。Siri 会把整段念出来，
//     超过三四句用户就记不住了 —— 所以下面凡是列表类的，
//     最多列 5 条，剩下的只说「另有 N 条」。
// ============================================================

// MARK: - 今天有什么

struct TodayEventsIntent: AppIntent {
    static var title: LocalizedStringResource = "今天有什么安排"
    static var description = IntentDescription("念出今天还没结束的日程和待办。")

    /// 允许在锁屏、Siri 里不打开 App 直接跑。
    ///
    /// ⚠️ 只在用户明确唤起（说出来 / 点快捷指令）时才允许 ——
    ///    不要设 `openAppWhenRun = true`，那会把一次查询变成一次跳转。
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try IntentSession.current()
        let (from, to) = IntentSession.dayRange(.now)

        let items: [ScheduleInstance]
        do {
            items = try await session.instances(from: from, to: to)
        } catch {
            return .result(dialog: "今天查不到，\(Self.reason(error))")
        }

        // 待办里已完成的在「念出来」这个场景没有价值 ——
        // 用户问「今天有什么安排」不是想知道自己已经做完了什么。
        let visible = items
            .filter { !($0.isTask && $0.doneAt != nil) }
            .sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }
                return a.startUTC < b.startUTC
            }

        guard !visible.isEmpty else {
            return .result(dialog: "今天没有安排了。")
        }

        let lines = visible.prefix(5).map(IntentSession.spokenLine)
        var text = "今天有 \(visible.count) 项：" + lines.joined(separator: "；")
        if visible.count > 5 {
            text += "；另有 \(visible.count - 5) 项"
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }

    /// 把异常翻成半句话，拼在「今天查不到，」后面。
    ///
    /// ⚠️ 刻意**不**标 private：另外三个 Intent 也要用同一套翻译。
    ///    各写一份的话，「登录失效」这条会出现三种说法。
    static func reason(_ error: Error) -> String {
        if let api = error as? APIError, case .unauthorized = api {
            return "登录已失效，请打开 App 重新登录。"
        }
        if let i = error as? IntentError {
            return i.errorDescription ?? "稍后再试。"
        }
        // ⚠️ 不要拼 error.localizedDescription：URLError 的原生描述是
        //    「The request timed out.」这种英文，混在一句中文里更让人困惑。
        return "网络或服务器连不上，稍后再试。"
    }
}

// MARK: - 明天有什么

struct TomorrowEventsIntent: AppIntent {
    static var title: LocalizedStringResource = "明天有什么安排"
    static var description = IntentDescription("念出明天的日程和待办。")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try IntentSession.current()
        let (from, to) = IntentSession.dayRange(Date.now.addingDays(1))

        let items: [ScheduleInstance]
        do {
            items = try await session.instances(from: from, to: to)
        } catch {
            return .result(dialog: "明天查不到，\(TodayEventsIntent.reason(error))")
        }

        let visible = items
            .filter { !($0.isTask && $0.doneAt != nil) }
            .sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }
                return a.startUTC < b.startUTC
            }

        guard !visible.isEmpty else {
            return .result(dialog: "明天没有安排。")
        }

        let lines = visible.prefix(5).map(IntentSession.spokenLine)
        var text = "明天有 \(visible.count) 项：" + lines.joined(separator: "；")
        if visible.count > 5 {
            text += "；另有 \(visible.count - 5) 项"
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - 我还有哪些待办

struct PendingTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "我还有哪些待办"
    static var description = IntentDescription("念出最近 30 天里还没勾掉的待办。")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try IntentSession.current()

        // 往前看 30 天而不是「全部未来」：
        // 服务端按区间展开实例，区间越宽响应越大；而待办本来就该是
        // 「最近这一段要做的事」，30 天足够覆盖真实使用。
        let from = Date.now.startOfDay.addingDays(-30)
        let to = Date.now.startOfDay.addingDays(30)

        let items: [ScheduleInstance]
        do {
            items = try await session.instances(from: from, to: to)
        } catch {
            return .result(dialog: "查不到待办，\(TodayEventsIntent.reason(error))")
        }

        let tasks = items
            .filter { $0.isTask && $0.doneAt == nil }
            .sorted { $0.startUTC < $1.startUTC }

        guard !tasks.isEmpty else {
            return .result(dialog: "待办都清空了，没有未完成的。")
        }

        // 过期的要单独点出来 —— 这是用户最需要知道的那一类，
        // 混在列表里念完等于没说。
        let todayStart = Date.now.startOfDay
        let overdue = tasks.filter {
            Date(timeIntervalSince1970: TimeInterval($0.startUTC)) < todayStart
        }

        let lines = tasks.prefix(5).map { item -> String in
            let title = (item.title ?? "").nonEmpty(or: "未命名待办")
            let day = Date(timeIntervalSince1970: TimeInterval(item.startUTC))
            if item.allDay || item.startUTC == Int64(day.startOfDay.timeIntervalSince1970) {
                return "\(day.monthDay) \(title)"
            }
            return "\(day.monthDay) \(IntentSession.clock(item.startUTC)) \(title)"
        }

        var text = "还有 \(tasks.count) 项待办"
        if !overdue.isEmpty {
            text += "，其中 \(overdue.count) 项已过期"
        }
        text += "：" + lines.joined(separator: "；")
        if tasks.count > 5 {
            text += "；另有 \(tasks.count - 5) 项"
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - 新建日程（唯一一个写操作）

struct CreateEventIntent: AppIntent {
    static var title: LocalizedStringResource = "新建日程"
    static var description = IntentDescription("说一句话就把日程记进默认日历。")

    static var openAppWhenRun: Bool = false

    /// Siri 会把用户那句话里的槽位填进来。
    @Parameter(title: "内容", requestValueDialog: "要记什么？")
    var title: String

    @Parameter(title: "开始时间")
    var start: Date?

    /// 时长用分钟数而不是 `Date`，是因为「开一小时会」比
    /// 「十点到十一点」更符合说话习惯。
    @Parameter(title: "时长（分钟）", default: 60)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try IntentSession.current()

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "没说是什么事，没有建。")
        }

        // 没给时间就默认「下一个整点」，并**在回答里说出具体时间**。
        // 悄悄替用户挑一个时间是最坏的做法：他会发现日程在
        // 一个自己没提过的时刻。
        //
        // ⚠️ 不能用 `date(bySettingHour: hour + 1, ...)`：23 点时会传 24，
        //    那是个非法值，`bySettingHour` 返回 nil。这里改成在「去掉分钟秒」
        //    的基准上 +1 小时，跨天由 Calendar 自己处理。
        let when: Date
        var assumed = false
        if let s = start {
            when = s
        } else {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: .now)
            let topOfHour = Calendar.current.date(from: comps) ?? Date.now
            when = topOfHour.addingTimeInterval(3600)
            assumed = true
        }

        // 服务端要求的时长单位是秒，且不接受 0 —— 0 会让日程变成
        // 一个零长度的点，在周视图里根本看不见。
        let dur = max(5, minutes)

        do {
            let calendars: CalendarsResponse = try await session.withClient { client in
                try await client.get("/api/calendars")
            }

            // 挑默认日历：优先「可写自己拥有」的那一张。
            // ⚠️ 不能随便取第一张 —— 那可能是别人共享给我的**只读**日历，
            //    建进去会吃 403，而用户完全不知道发生了什么。
            guard let target = calendars.calendars.first(where: { $0.canWrite }) else {
                return .result(dialog: "没有可写入口的日历，请先在 App 里建一个。")
            }

            struct Body: Encodable {
                let calendarID: String
                let title: String
                let startUTC: Int64
                let durationSec: Int64
                let tzid: String
                enum CodingKeys: String, CodingKey {
                    case calendarID = "calendar_id"
                    case title
                    case startUTC = "start_utc"
                    case durationSec = "duration_sec"
                    case tzid
                }
            }
            let body = Body(
                calendarID: target.id,
                title: trimmed,
                startUTC: Int64(when.timeIntervalSince1970.rounded()),
                durationSec: Int64(dur) * 60,
                // 用设备时区而不是服务器的：用户说的是「我这里的三点」。
                tzid: TimeZone.current.identifier
            )
            struct Created: Decodable { let id: String? }
            let data = try JSONEncoder().encode(body)
            let _: Created = try await session.withClient { client in
                try await client.post("/api/events", body: data)
            }

            let at = IntentSession.clock(Int64(when.timeIntervalSince1970))
            let day = when.monthDay
            var text = "已记下：\(day) \(at) \(trimmed)，\(dur) 分钟。"
            if assumed {
                text += "（你没说时间，先放在下一个整点，可以进 App 改。）"
            }
            return .result(dialog: IntentDialog(stringLiteral: text))
        } catch {
            return .result(dialog: "没建成，\(TodayEventsIntent.reason(error))")
        }
    }
}

// MARK: - 让 Siri 认识这些动作

/// 把上面几个 Intent 注册进 Siri 的建议列表。
///
/// 不做这一步的话，App Intents 只能在**快捷指令 App 里手动加**，
/// Siri 不会主动认识它们 —— 用户说「今天有什么安排」会被当成闲聊。
struct ThreeeAssistantShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodayEventsIntent(),
            phrases: [
                "用\(.applicationName)看看今天有什么安排",
                "\(.applicationName)今天有什么事",
            ],
            shortTitle: "今天安排",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: TomorrowEventsIntent(),
            phrases: [
                "用\(.applicationName)看看明天有什么安排",
            ],
            shortTitle: "明天安排",
            systemImageName: "calendar.badge.clock"
        )
        AppShortcut(
            intent: PendingTasksIntent(),
            phrases: [
                "用\(.applicationName)看看还有什么待办",
                "\(.applicationName)我还有哪些待办",
            ],
            shortTitle: "待办清单",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CreateEventIntent(),
            phrases: [
                // 这条短语**故意不带** \(\.$title) 槽位。
                //
                // ## 一段走过的弯路（2026-11-02，留作反面教材）
                //
                // 我一度以为这条短语「被系统静默丢弃」了，理由是可执行文件里
                // grep 不到「记一件事」这串字，而另外三条都能 grep 到。
                // 于是把短语改成了「用\(.applicationName)记\(\.$title)」，
                // 还在提交说明里写了一大段「必填参数必须给槽位」的解释。
                //
                // **这个结论是错的。** App Intents 的短语注册结果不在可执行
                // 文件里，而在 .app 包内的 `Metadata.appintents/root.ssu.yaml`。
                // 那份文件里有：
                //
                //     - metadata:
                //         name: CreateEventIntent_3
                //       corpuses:
                //         training:
                //         - locale: zh_CN
                //           utterances:
                //           - 用${+applicationName}记一件事
                //
                // 也就是说纯文本短语一直是对的。可执行文件里搜不到，
                // 只是因为短语是编译进元数据资源的，不是编进 Mach-O 的。
                //
                // ## 为什么改回纯文本
                //
                // 带槽位要求用户一口气说出「记 明天下午答辩」，Siri 才肯认；
                // 纯文本则允许先说「记一件事」，把「要记什么」留到
                // `requestValueDialog` 再问。后者在手持设备上更自然。
                "用\(.applicationName)记一件事",
                "\(.applicationName)记一件事",
            ],
            shortTitle: "新建日程",
            systemImageName: "plus.circle"
        )
    }
}
