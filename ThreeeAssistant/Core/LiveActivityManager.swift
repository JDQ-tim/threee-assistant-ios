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
//    开：课前 30 分钟         ← 提前太多会从早占到晚
//    收：下课 + 5 分钟        ← 由 staleDate 交给系统自动收，
//                              不依赖 App 还活着
//  ```
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
    private(set) var showingTitle: String?

    private var activity: Activity<NextClassActivityAttributes>?

    /// 课前多久开始显示。
    private let leadTime: TimeInterval = 30 * 60
    /// 只在这一段时间内找"下一节课"。再远的事现在开活动没有意义。
    private let horizon: TimeInterval = 8 * 3600
    /// 已经开始了的课，超过这么久就不再顶到岛上（防止一条全天文娱活动挂一整天）。
    private let ongoingLimit: TimeInterval = 3 * 3600

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

        guard let pick = pickTarget(instances) else {
            lastError = nil
            await endAll()
            return
        }

        let state = NextClassActivityAttributes.ContentState(
            title: pick.title.flatMap { $0.isEmpty ? nil : $0 } ?? "（无标题）",
            location: pick.location ?? "",
            start: pick.start,
            end: pick.end
        )
        // 下课之后再留 5 分钟就自动收。用系统时间判定，App 不在也生效。
        let stale = max(pick.end, .now).addingTimeInterval(5 * 60)
        let content = ActivityContent(state: state, staleDate: stale)

        if let current = activity, current.attributes.eventID == pick.eventID {
            await current.update(content)
            showingTitle = state.title
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
    }

    // MARK: - 选哪一条

    /// 挑出"现在该显示的那一节"。
    ///
    /// 优先级：**正在上的** > 30 分钟内要开始的，各自取最近的一条。
    private func pickTarget(_ list: [ScheduleInstance]) -> ScheduleInstance? {
        let now = Date.now

        // 待办和全天日程不进实时活动：
        // 前者没有"什么时候下课"，后者会从零点挂到半夜。
        let pool = list.filter { !$0.isTask && !$0.allDay && $0.end > now }
        guard !pool.isEmpty else { return nil }

        let ongoing = pool.filter {
            $0.start <= now && $0.start > now.addingTimeInterval(-ongoingLimit)
        }
        if let current = ongoing.min(by: { $0.start < $1.start }) {
            return current
        }

        let soon = pool.filter {
            $0.start > now
                && $0.start <= now.addingTimeInterval(horizon)
                && $0.start.timeIntervalSince(now) <= leadTime
        }
        return soon.min(by: { $0.start < $1.start })
    }
}
