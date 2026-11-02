import Foundation

/// 给 App Intents / Siri 用的「无界面会话」。
///
/// ## 为什么不直接复用 SessionStore
///
/// `SessionStore` 是 `@MainActor @Observable` 的**界面状态**：它持有
/// 当前周的 `weekStart`、当前月视图的 `monthAnchor`、登录页输入框的
/// 半截文字、还有一片面积不小的 `instances` 缓存。App Intents 在
/// Siri / 快捷指令 / 聚焦搜索里被唤起时，**没有窗口、没有视图层级**，
/// 拿一个界面对象去干活会有两个具体后果：
///
/// 1. **它会把 UI 状态改坏。** 用户在 Siri 里说「我明天下午三点干嘛」，
///    查询过程把 `weekStart` 挪到了明天那周 —— 下次打开 App，
///    日程页停在明天那周，用户以为「App 记住错了位置」。
/// 2. **拿不到依赖。** Intents 的 `perform()` 不是主线程上下文，
///    而 SessionStore 的属性访问是主线程隔离的，跨过去要一路 `await`，
///    代码会变得比它解决的问题更复杂。
///
/// 所以这里做的是「只读的、无状态的、按需请求」：
/// 从 Keychain / UserDefaults 恢复登录凭证，直接调 `APIClient`，
/// 查完就把数据交出去，**不碰任何界面状态**。
///
/// ## 一个必须承认的限制
///
/// 它和 SessionStore 在读同一份凭证。如果用户在 App 里刚登出，
/// 而某个后台任务恰好在这一瞬间跑起来，它可能拿着一个已经作废的 token
/// 发请求 —— 服务端会回 401，这里如实转成「登录已失效」。
/// 不去做额外的互斥：那种窗口只有几十毫秒，而为此引入一把跨进程锁
/// 会让「Siri 问一句今天有什么」变成一个可能卡住的调用，不划算。
struct IntentSession {

    let baseURL: URL
    let token: String
    let user: APIUser

    /// 和 `SessionStore` 里同名常量必须一致，否则查询得到空结果。
    private static let serverKey = "threees.server"
    private static let userKey = "threees.user"
    private static let tokenKey = "token"

    /// 读本机保存的登录态。未登录时抛一个**能直接念给用户听**的错。
    ///
    /// ⚠️ 这里的错误文案会出现在 Siri 的回答和快捷指令的运行日志里，
    ///    所以不能是「notConfigured」这种内部词汇，必须是人话。
    static func current() throws -> IntentSession {
        let defaults = UserDefaults.standard

        guard let serverText = defaults.string(forKey: serverKey), !serverText.isEmpty else {
            throw IntentError.notLoggedIn
        }
        guard let token = Keychain.read(tokenKey), !token.isEmpty else {
            throw IntentError.notLoggedIn
        }
        guard
            let data = defaults.data(forKey: userKey),
            let user = try? JSONDecoder().decode(APIUser.self, from: data)
        else {
            throw IntentError.notLoggedIn
        }
        guard let url = try? APIClient.normalize(serverText) else {
            throw IntentError.notLoggedIn
        }
        return IntentSession(baseURL: url, token: token, user: user)
    }

    /// 把凭证装进 `APIClient` 再发请求，并**在结束后恢复原状**。
    ///
    /// ## 为什么必须恢复
    ///
    /// `APIClient.shared` 是个进程级单例。App 在前台时，它是 App 配好的
    /// （同一个地址、同一个 token）；但如果用户在设置里改了服务器地址
    /// **还没重新登录**，或者 App 正在登录流程里把 token 置成了 nil，
    /// 后台的 Intents 一 `configure` 就会把它们冲掉 ——
    /// 表现是「我说了句话之后 App 就让我重新登录」。
    ///
    /// 恢复成「和这次调用前一样」不能靠读私有字段（`APIClient` 没暴露），
    /// 所以做法是：**每次都用同一个来源重新配置**。
    /// `IntentSession` 的凭证本来就来自 Keychain + UserDefaults，
    /// 而前台登录成功的最后一步也是把凭证写进这两处。
    /// 因此请求结束后再 `configure` 一次同样的值即可对齐。
    func withClient<T>(_ body: (APIClient) async throws -> T) async throws -> T {
        let client = APIClient.shared
        client.configure(baseURL: baseURL, token: token)
        defer { client.configure(baseURL: baseURL, token: token) }
        return try await body(client)
    }

    // MARK: - 查询

    /// 取某个时间区间内的日程实例。
    ///
    /// 半开区间 `[from, to)`，和周/月视图的换算保持一致 ——
    /// 闭区间会让「周一 00:00 到下周一 00:00」把下周一那条日程重复算进来。
    func instances(from: Date, to: Date) async throws -> [ScheduleInstance] {
        let query = [
            URLQueryItem(name: "from", value: String(Int64(from.timeIntervalSince1970))),
            URLQueryItem(name: "to", value: String(Int64(to.timeIntervalSince1970))),
        ]
        return try await withClient { client in
            let res: InstancesResponse = try await client.get("/api/instances", query: query)
            return res.instances
        }
    }

    /// 今天 / 明天 / 本周的区间，全部按**设备本地时区**切。
    ///
    /// 服务端存的是 UTC epoch，但它按 `tzid` 展开重复规则；
    /// 这里再按本地时区切窗，两边口径一致。
    static func dayRange(_ day: Date) -> (Date, Date) {
        let start = day.startOfDay
        return (start, start.addingDays(1))
    }

    /// 一台日程在 Siri 里怎么念。
    ///
    /// ## 三个刻意的取舍
    ///
    /// 1. **全天日程念「全天」，不念 00:00。** 用户不会把「晚上十二点」
    ///    和「一整天」联系起来，念成时间反而制造误解。
    /// 2. **待办带「已完成」标记。** 否则用户问「今天有什么事」，
    ///    得到的回答里混着已经做完的，他还得自己排除一遍。
    /// 3. **地点放最后，且有才念。** 地点常常是空的，
    ///    中间插一句「地点：无」会让整句话听起来像报错。
    static func spokenLine(_ item: ScheduleInstance) -> String {
        let title = (item.title ?? "").nonEmpty(or: "未命名日程")
        var parts: [String] = []

        if item.allDay {
            parts.append("全天")
        } else {
            parts.append(clock(item.startUTC))
        }

        var head = parts.joined(separator: " ")
        head += " " + title

        if item.isTask, item.doneAt != nil {
            head += "（已完成）"
        }
        if let loc = item.location, !loc.isEmpty {
            head += "，在" + loc
        }
        return head
    }

    /// epoch 秒 → `HH:mm`，用**设备本地时区**。
    ///
    /// 直接复用 `Date.hhmm`，不另写一个 DateFormatter：
    /// 时间格式在 App 里有好几处显示（周视图、详情页、这里），
    /// 各写一份的话「详情页 09:00、Siri 念 9:00」这种不一致迟早出现。
    static func clock(_ epoch: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).hhmm
    }
}

/// Intents 里会用到的那几种失败。
///
/// 单独一个枚举而不是复用 `APIError`，是因为**说出去的句子不一样**：
/// `APIError.decoding("...")` 是给开发者看的，
/// 而这里每一条都会直接进 Siri 的回答。
enum IntentError: LocalizedError {
    case notLoggedIn
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            // 不要写「请先登录后在 App 内操作」——Siri 场景下用户已经走开了，
            // 得告诉他「去哪做什么」。
            return "还没在 3e 学习助手里登录，请先打开 App 登录一次。"
        case .queryFailed(let why):
            return "查不到：" + why
        }
    }
}
