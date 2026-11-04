import ActivityKit
import Foundation
import Observation

// ============================================================
//  实时活动（Live Activity）的开关与生命周期
//  ------------------------------------------------------------
//  这是「把课表做上灵动岛」在 App 这一侧的全部逻辑。
//  界面在 `NextClassWidget/` 那个独立扩展里。
//
//  ## 为什么是"下一节课"而不是"每条日程都开"
//
//  灵动岛同时最多显示两个活动，锁屏上挂着一条会一直占位。
//  一个学期几百节课，如果每节都开，用户会先学会无视它，
//  然后把整个功能关掉。**只显示"眼下这一节"**，它才有信息量。
//
//  ## 什么时候开、什么时候收
//
//  ```
//    开：正在上 / 2 小时内要上 / 明天第一节（今天已经没课了）
//    收：下课 + 5 分钟        ← 由 staleDate 交给系统自动收，
//                              不依赖 App 还活着
//  ```
//
//  "挑哪一节"全部交给纯函数 `NextClassPlan` —— 它能离线跑用例，
//  这里只负责**怎么挂**（调 ActivityKit）。理由和 `ReminderPlan` 一样。
//
//  ⚠️ 全程**不追求**"每秒更新"。倒计时是界面用
//     `Text(date, style: .timer)` 让系统自己走的 ——
//     App 退到后台就不该再承担刷新的责任。
// ============================================================

@MainActor
@Observable
final class LiveActivityManager {

    private static let enabledKey = "liveActivity.enabled"

    /// 用户开关。默认**开** —— 这个功能本身就是用户点名要的，
    /// 默认关掉等于让他去设置里找一个他不知道自己有的开关。
    private(set) var isEnabled: Bool = true

    /// 最近一次失败的人话。设置页会显示它。
    private(set) var lastError: String?

    /// 正在显示的那条日程的标题（设置页用来回答"现在岛上是什么"）。
    ///
    /// ⚠️ 这个值**只在开着 App 时准**。活动挂上之后用户把 App 划掉，
    ///    `ActivityKit` 仍然让它在锁屏上活着，而这边没人能更新了。
    private(set) var showingTitle: String?

    /// 与 `showingTitle` 同步更新的"何时开始"。设置页用它区分
    /// 「正在上」和「还有 1 小时 20 分」—— 只说标题会让人以为是现在的事。
    private(set) var showingStart: Date?

    private var activity: Activity<NextClassActivityAttributes>?

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    // MARK: - 开关

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            lastError = nil
        } else {
            showingTitle = nil
            showingStart = nil
            Task { await endAll() }
        }
    }

    // MARK: - 同步

    /// 按当前的日程表决定岛上显示什么。可以随便多调，幂等。
    func sync(instances: [ScheduleInstance]) async {
        guard isEnabled else { return }

        // 系统层面的总开关（设置 → 通知 → 实时活动）。
        //
        // ⚠️ `areActivitiesEnabled` 为 false 有**两种完全不同的原因**：
        //    · 用户关掉了
        //    · 这台设备/系统版本根本不支持（iPad 要 iPadOS 26 以上；
        //      在更老的 iPadOS 上 Activity.request 会被静默丢弃）
        //    系统不告诉我们到底是哪一种，所以这句话必须把两种都说出来 ——
        //    只说"你去设置里打开"，iPad 用户会去设置里找一个不存在的开关。
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "实时活动没能启动：要么系统里关掉了（设置 → 通知 → 学习助手 → 实时活动），要么这台设备不支持（iPad 需要 iPadOS 26 以上）。"
            await endAll()
            return
        }

        guard let pick = pickTarget(instances, now: .now) else {
            lastError = nil
            await endAll()
            return
        }

        let state = NextClassActivityAttributes.ContentState(
            title: pick.title.isEmpty ? "（无标题）" : pick.title,
            location: pick.location,
            start: pick.start,
            end: pick.end
        )
        // ⚠️ 下课之后再留 5 分钟就自动收。
        //
        //    这个时刻只是一个"建议"，系统不会因为过了它就丢掉活动 ——
        //    真正让它消失的是下一次 `end()` 或用户手动划掉。
        //    明天那一节也一样：挂到它下课后 5 分钟，而不是"今晚就过期"。
        let stale = max(pick.end, .now).addingTimeInterval(5 * 60)
        let content = ActivityContent(state: state, staleDate: stale)

        if let current = activity, current.attributes.eventID == pick.eventID {
            await current.update(content)
            showingTitle = state.title
            showingStart = pick.start
            lastError = nil
            return
        }

        await endAll()
        do {
            activity = try Activity.request(
                attributes: NextClassActivityAttributes(eventID: pick.eventID),
                content: content,
                pushType: nil
            )
            showingTitle = state.title
            showingStart = pick.start
            lastError = nil
        } catch {
            // 常见原因：系统实时活动总开关关着、或本机不允许。
            // 把系统给的原文带上 —— 它比我们编的话准。
            lastError = "开不了实时活动：\(error.localizedDescription)"
        }
    }

    /// 收起所有活动。关开关、退出登录、算不出下一节课时都走它。
    func endAll() async {
        for a in Activity<NextClassActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        showingTitle = nil
        showingStart = nil
    }

    // MARK: - 选哪一条

    /// 挑出"现在该显示的那一节"。
    ///
    /// 判断本身在 `NextClassPlan.pick`（纯函数、离线可测），
    /// 这里只做**模型的摊平**：把 `ScheduleInstance` 里的可选字段
    /// 收敛成 `Pick` 的非可选字段，并排除两类不该进实时活动的东西。
    ///
    /// ⚠️ 排除待办和全天日程：
    ///    - 待办没有"什么时候下课"，卡片右半边会空着
    ///    - 全天日程会从零点挂到半夜，它更适合做普通提醒
    private func pickTarget(_ list: [ScheduleInstance], now: Date) -> NextClassPlan.Pick? {
        let pool = list
            .filter { !$0.isTask && !$0.allDay && $0.end > now }
            .map {
                NextClassPlan.Pick(
                    eventID: $0.eventID,
                    title: $0.title ?? "",
                    location: $0.location ?? "",
                    start: $0.start,
                    end: $0.end,
                    isUpcoming: $0.start > now,
                    isTomorrow: false
                )
            }
        guard let best = NextClassPlan.pick(items: pool, now: now) else { return nil }
        // `isTomorrow` 由调用方真正需要的地方再算（设置页文案用）。
        //
        // 这里用**自然日**判而不是 `start.timeIntervalSince(now) > 12h`：
        // 晚上 23:50 看明天 08:00 的课只差 8 小时，但它是明天的。
        let isTomorrow: Bool
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                                                to: Calendar.current.startOfDay(for: now)) {
            isTomorrow = Calendar.current.isDate(best.start, inSameDayAs: tomorrow)
        } else {
            isTomorrow = false
        }
        return NextClassPlan.Pick(
            eventID: best.eventID,
            title: best.title,
            location: best.location,
            start: best.start,
            end: best.end,
            isUpcoming: best.start > now,
            isTomorrow: isTomorrow
        )
    }
}
