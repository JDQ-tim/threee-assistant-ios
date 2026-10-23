import Foundation
import Observation

/// 全部界面状态。视图不持有数据、不自己发请求 —— 都从这里拿。
///
/// 为什么集中在一个对象里：日程是**多端同步**的数据，
/// 页面 A 新建了一条，页面 B 的列表必须跟着变。状态分散到各个视图里时，
/// 这种「改了一处另一处不动」的问题几乎必然出现，而且很难复现。
@MainActor
@Observable
final class SessionStore {

    // MARK: - 登录态

    private(set) var token: String?
    private(set) var user: APIUser?

    /// 登录页上的输入（放在这里是为了切页不丢）
    var serverText: String = ""

    // MARK: - 数据

    private(set) var calendars: [CalendarDTO] = []
    private(set) var instances: [ScheduleInstance] = []

    /// `eventID → rrule`。实例列表里只有展开结果，不带重复规则，
    /// 而列表上要显示「每周」这类标记。
    ///
    /// ⚠️ 不为每条日程单独发 `GET /api/events/{id}`：一周 20 条就是 20 个请求。
    ///    这里用**本地记录**的方式填 —— 见 `rememberRules(for:)`。
    ///    拿不到就是 nil，列表上不显示重复标记，不影响任何功能。
    private(set) var repeatRuleByEventID: [String: String] = [:]

    var isLoading = false
    var errorMessage: String?

    // MARK: - 视图状态

    var weekStart: Date = Date.now.startOfWeekMonday

    /// 当前显示的月份（月视图用），恒为当月 1 日
    var monthAnchor: Date = Date.now.startOfMonth

    /// 周视图还是月视图。切换时要把拉取范围换掉，
    /// 否则月视图只会显示第一周的数据 —— 看起来像"这个月别的日子都没安排"。
    var scope: CalendarScope = .week

    enum CalendarScope: String, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }
        var label: String { self == .week ? "周" : "月" }
    }

    private let serverKey = "threees.server"
    private let userKey = "threees.user"
    private let tokenKey = "token"

    var isLoggedIn: Bool { token != nil && user != nil }

    var calendarsByID: [String: CalendarDTO] {
        Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
    }

    /// 按天分组，全天排最前，其余按开始时间
    var dayGroups: [DayGroup] {
        var buckets: [Date: [ScheduleInstance]] = [:]
        for item in instances {
            let day = item.start.startOfDay
            buckets[day, default: []].append(item)
        }
        return buckets
            .map { day, items in
                DayGroup(day: day, items: items.sorted { a, b in
                    if a.allDay != b.allDay { return a.allDay }
                    return a.startUTC < b.startUTC
                })
            }
            .sorted { $0.day < $1.day }
    }

    var weekEnd: Date { weekStart.addingDays(6) }

    // MARK: - 启动

    /// ⚠️ 标 `@MainActor` 是因为整个类都是主线程隔离的；
    ///    Swift 6 的并发检查下，从 `@State` 初始化时就是主线程，不会冲突。
    @MainActor
    init() {
        restore()
    }

    private func restore() {
        let defaults = UserDefaults.standard
        serverText = defaults.string(forKey: serverKey) ?? ""

        guard
            !serverText.isEmpty,
            let savedToken = Keychain.read(tokenKey),
            let userData = defaults.data(forKey: userKey),
            let savedUser = try? JSONDecoder().decode(APIUser.self, from: userData),
            let url = try? APIClient.normalize(serverText)
        else { return }

        token = savedToken
        user = savedUser
        APIClient.shared.configure(baseURL: url, token: savedToken)
    }

    // MARK: - 登录 / 登出

    func login(server: String, name: String, pass: String) async {
        errorMessage = nil

        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedServer.isEmpty else { errorMessage = "请填服务器地址"; return }
        guard !trimmedName.isEmpty else { errorMessage = "请填用户名"; return }
        guard !pass.isEmpty else { errorMessage = "请填密码"; return }

        do {
            let url = try APIClient.normalize(trimmedServer)
            APIClient.shared.configure(baseURL: url, token: nil)

            let body = try JSONEncoder().encode(LoginBody(name: trimmedName, pass: pass))
            let res: LoginResponse = try await APIClient.shared.post("/api/auth/login", body: body)

            token = res.token
            user = res.user
            serverText = url.absoluteString

            APIClient.shared.setToken(res.token)
            Keychain.save(res.token, for: tokenKey)
            UserDefaults.standard.set(serverText, forKey: serverKey)
            if let data = try? JSONEncoder().encode(res.user) {
                UserDefaults.standard.set(data, forKey: userKey)
            }

            weekStart = Date.now.startOfWeekMonday
            await refresh()
        } catch {
            errorMessage = message(for: error)
        }
    }

    /// 只清本地登录态。服务端的 token 记录顺手作废，
    /// 失败也无所谓 —— 它本来就只是个失效的凭证。
    func logout() async {
        // 用 try? 吞掉一切失败：登出必须无条件成功，不能因为网络断了就退不出去
        _ = try? await APIClient.shared.postRaw("/api/auth/logout", body: nil)
        token = nil
        user = nil
        calendars = []
        instances = []
        errorMessage = nil

        Keychain.delete(tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    // MARK: - 数据同步

    func refresh() async {
        guard isLoggedIn else { return }

        isLoading = true
        errorMessage = nil

        // 拉取范围跟着视图走。
        // 月视图按「当月 1 日 00:00 ~ 下月 1 日 00:00」取，
        // 周视图按周一 ~ 下周一取 —— 两者都用半开区间，避免最后一天重复计入。
        let from: Date
        let to: Date
        switch scope {
        case .week:
            from = weekStart.startOfDay
            to = weekStart.addingDays(7).startOfDay
        case .month:
            from = monthAnchor.startOfDay
            to = monthAnchor.addingMonths(1).startOfDay
        }
        let query = [
            URLQueryItem(name: "from", value: String(Int64(from.timeIntervalSince1970))),
            URLQueryItem(name: "to", value: String(Int64(to.timeIntervalSince1970))),
        ]

        do {
            // 两个请求并发：日历清单和日程实例互不依赖
            async let calTask: CalendarsResponse = APIClient.shared.get("/api/calendars")
            async let instTask: InstancesResponse = APIClient.shared.get("/api/instances", query: query)

            let cals = try await calTask
            let insts = try await instTask

            calendars = cals.calendars
            instances = insts.instances

            // 顺手把「这次新建/编辑时知道的规则」回填进去。
            // 只对当前窗口里出现过的 eventID 保留，避免字典无限增长
            let alive = Set(insts.instances.map { $0.eventID })
            repeatRuleByEventID = repeatRuleByEventID.filter { alive.contains($0.key) }
        } catch {
            if case APIError.unauthorized = error {
                handleExpiredToken()
            } else {
                errorMessage = message(for: error)
            }
        }

        isLoading = false
    }

    private func handleExpiredToken() {
        // 令牌失效就让用户重新登录，而不是留一个「什么都加载不出来」的界面
        token = nil
        user = nil
        calendars = []
        instances = []
        Keychain.delete(tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        errorMessage = "登录已失效，请重新登录"
    }

    func shiftWeek(by days: Int) async {
        weekStart = weekStart.addingDays(days)
        await refresh()
    }

    /// 月视图翻月。用 `addingMonths` 而不是加 30 天 ——
    /// 后者在 2 月会漂到 3 月初，翻两次就乱了。
    func shiftMonth(by months: Int) async {
        monthAnchor = monthAnchor.addingMonths(months).startOfMonth
        await refresh()
    }

    /// 统一的「往前 / 往后」入口，按当前视图决定是翻周还是翻月。
    /// 视图层不该自己判断 scope —— 判断散在几处就一定会有一处忘了。
    func shift(by direction: Int) async {
        switch scope {
        case .week: await shiftWeek(by: direction * 7)
        case .month: await shiftMonth(by: direction)
        }
    }

    func goToday() async {
        weekStart = Date.now.startOfWeekMonday
        monthAnchor = Date.now.startOfMonth
        await refresh()
    }

    /// 切换周/月视图。切完必须重新拉一次范围。
    func setScope(_ s: CalendarScope) async {
        guard scope != s else { return }
        scope = s
        await refresh()
    }

    /// 月视图点某一天：直接跳过去，切回周视图看那天。
    /// 月视图里格子太小，看不了详情，所以点日期 = "看这周"。
    func jumpTo(day: Date) async {
        weekStart = day.startOfWeekMonday
        monthAnchor = day.startOfMonth
        await refresh()
    }

    // MARK: - 写操作

    private struct CreatedEvent: Decodable {
        let id: String?
    }

    func createEvent(
        calendarID: String,
        title: String,
        start: Date,
        durationMinutes: Int,
        rrule: String? = nil,
        reminders: [ReminderDTO] = [],
        isTask: Bool = false
    ) async throws {
        let body = NewEventBody(
            calendarID: calendarID,
            title: title,
            notes: "",
            location: "",
            startUTC: Int64(start.timeIntervalSince1970.rounded()),
            durationSec: Int64(max(0, durationMinutes) * 60),
            tzid: TimeZone.current.identifier,
            rrule: rrule ?? "",
            isTask: isTask,
            reminders: reminders
        )
        let data = try JSONEncoder().encode(body)
        let created: CreatedEvent = try await APIClient.shared.post("/api/events", body: data)

        // 新建时规则是我们自己算的，直接记下来，列表立刻能显示重复标记，
        // 不需要再多发一次详情请求
        if let id = created.id, !(rrule ?? "").isEmpty {
            repeatRuleByEventID[id] = rrule
        }

        await refresh()
    }

    /// 勾上 / 取消一个待办。
    ///
    /// 不走 `PUT /api/events/{id}` 而是走「只改这一次」：
    /// 重复待办（比如"每天背 30 个单词"）勾掉今天不应该把整个系列都标成完成。
    /// 服务端的 `overridePatch` 有 `done_at` 字段，正好干这个。
    func setDone(_ instance: ScheduleInstance, done: Bool) async throws {
        var p = UpdateEventBody()
        // ⚠️ 取消完成发的是**当前时间戳以外的一个"有值"的 0**，不是 nil。
        //    nil 表示"这个字段不改"，那样点了取消毫无反应。
        //    服务端 `DoneAt *int64` 收到 0 会存成 0，客户端按 0 视为未完成。
        p.doneAt = done ? Int64(Date().timeIntervalSince1970) : 0

        try await updateOccurrence(
            eventID: instance.eventID,
            occurrenceKey: instance.occurrenceKey,
            patch: p
        )
    }

    func deleteEvent(eventID: String) async throws {
        try await APIClient.shared.delete("/api/events/\(eventID)")
        await refresh()
    }

    // MARK: - 修改日程

    /// 取一条日程的**原始**数据（不是展开后的实例）。
    ///
    /// 编辑表单必须用这个：`ScheduleInstance` 是"某天的一次展开"，
    /// 拿它去编辑会把重复日程的一次单独改掉，语义完全不同。
    func loadEvent(id: String) async throws -> APIEvent {
        let res: EventResponse = try await APIClient.shared.get("/api/events/\(id)")
        // 打开过详情就等于知道了它的规则，顺手记下来给列表用
        repeatRuleByEventID[id] = res.event.rrule
        return res.event
    }

    /// 保存修改。
    ///
    /// ⚠️ **只发送真正改动的字段**，这不是为了省流量，是正确性问题：
    /// 服务端是局部合并，把没改的字段也发过去等于"确认设置为原值"，
    /// 会让服务端把这些字段也记一次变更、参与冲突检测，
    /// 还可能因为历史脏数据（比如旧标题里有违禁词）被拦下来。
    @discardableResult
    func updateEvent(id: String, patch: UpdateEventBody) async throws -> [FieldConflict] {
        if patch.isEmpty { return [] }

        let data = try JSONEncoder().encode(patch)
        let res: UpdateEventResponse = try await APIClient.shared.put(
            "/api/events/\(id)", body: data
        )
        // 改完规则可能变了（比如取消了重复），记住最新值
        if let r = patch.rrule {
            repeatRuleByEventID[id] = r
        }
        await refresh()
        return res.conflicts ?? []
    }

    /// 只改重复日程的**这一次**，不动整个系列。
    ///
    /// ## 和 updateEvent 的关键区别
    ///
    /// `updateEvent` 改的是"系列定义"，服务端会 `recomputeInstances`
    /// 把之后所有实例重算一遍；这个只往 `event_overrides` 里写一条补丁，
    /// 只影响 `occurrenceKey` 那一次。
    ///
    /// ⚠️ `occurrenceKey` 必须是**这一次原本的**开始时间，
    ///    而不是改完之后的新时间 —— 它就是这个补丁的定位主键。
    ///
    /// ⚠️ 日历改不了：服务端的 override 补丁只认 `title/notes/location/
    ///    all_day/dtstart_utc/duration_sec/done_at`，没有 `calendar_id`。
    ///    调用方（EditEventSheet）已经在单次模式下禁用了日历选择器。
    func updateOccurrence(
        eventID: String,
        occurrenceKey: Int64,
        patch: UpdateEventBody
    ) async throws {
        // 只保留 overridePatch 认识的键。
        //
        // ⚠️ 服务端对不认识的键是**静默忽略**，不会报错。所以如果这里不拦住，
        //    用户在「只改这一次」里改了重复规则或提醒，请求会成功返回，
        //    但改动根本没落库 —— 下次打开发现白改了，而且完全无从排查。
        //    overridePatch 只认：title / notes / location / all_day /
        //    dtstart_utc / duration_sec / done_at。
        var p = patch
        p.calendarID = nil
        p.tzid = nil
        p.rrule = nil
        p.reminders = nil
        p.isTask = nil

        let body = OccurrenceBody(occurrenceKey: occurrenceKey, patch: p)
        let data = try JSONEncoder().encode(body)

        // 服务端返回 {"event": {...}}，但这里不需要它的内容 ——
        // 改完之后要的是实例列表，refresh() 会重新拉一遍
        _ = try await APIClient.shared.putRaw(
            "/api/events/\(eventID)/occurrence", body: data
        )
        await refresh()
    }

    // MARK: - 文案

    func message(for error: Error) -> String {
        if let api = error as? APIError {
            return api.errorDescription ?? "出错了"
        }
        return error.localizedDescription
    }
}
