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
        isTask: Bool = false,
        allDay: Bool = false,
        strong: Bool = false,
        notes: String = "",
        location: String = ""
    ) async throws {
        // 全天日程的时长由「天」决定，调用方传的分钟数不可信 ——
        // 用户在新建页把「全天」打开时，时长 Stepper 是被禁用的，
        // 那里面残留的 30 分钟会把日程存成「全天但只有半小时」。
        let seconds: Int64 = allDay
            ? 86400
            : Int64(max(0, durationMinutes) * 60)

        let body = NewEventBody(
            calendarID: calendarID,
            title: title,
            // 服务端 notes / location 是可空字段，传空串和省略等价。
            // 这里统一 trim 一下：用户误按空格进去的备注会变成一条"看起来有内容"的记录
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            startUTC: Int64(start.timeIntervalSince1970.rounded()),
            durationSec: seconds,
            tzid: TimeZone.current.identifier,
            rrule: rrule ?? "",
            isTask: isTask,
            allDay: allDay,
            reminders: reminders,
            strong: strong
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

    /// 删除整条日程 / 整个重复系列。
    ///
    /// 对重复日程来说这会**删掉所有次**（服务端 `deleteEventCore` 抬 seq +
    /// `recomputeInstances`）。只想删某一次请用 `deleteOccurrence`。
    func deleteEvent(eventID: String) async throws {
        try await APIClient.shared.delete("/api/events/\(eventID)")
        await refresh()
    }

    /// 只删重复日程里的**这一次**。
    ///
    /// ## 为什么不复用 deleteEvent
    ///
    /// 服务端是两个完全不同的接口：
    /// - `DELETE /api/events/{id}` → 删系列（`deleteEventCore`）
    /// - `DELETE /api/events/{id}/occurrence?key=<epoch秒>` → 只删一次
    ///
    /// ## 两个容易踩的点
    ///
    /// 1. `key` 走的是 **query 参数**，不是请求体。服务端读的是
    ///    `r.URL.Query().Get("key")`（`handleDeleteOccurrence`），
    ///    DELETE 带 body 在很多代理/网关会被直接丢掉。
    /// 2. `key` 必须是这一次**原本的**开始时间（`occurrence_key`），
    ///    不是改过之后的新时间。
    ///
    /// ## 服务端怎么实现「删一次」
    ///
    /// 它不是真的删行，而是往 `event_overrides` 写一条 `cancelled=1`，
    /// 展开时 `if cancelled[k] { continue }` 直接跳过。
    /// 所以：
    /// - 删掉的那次**后续还能恢复**（再写一条 cancelled=0 即可）
    /// - 但同一个系列里如果之后又改了整个系列的时间，
    ///   被跳过的仍是**原来那个 key**，不会误伤别的次
    func deleteOccurrence(eventID: String, occurrenceKey: Int64) async throws {
        try await APIClient.shared.delete(
            "/api/events/\(eventID)/occurrence",
            query: [URLQueryItem(name: "key", value: String(occurrenceKey))]
        )
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
        // ⚠️ `strong` 也要清掉 —— 强提醒是按人存的（strong_reminders 表），
        //    跟「这一次」这个维度无关，override 补丁里没有它。
        //    不清的话指令会静默失效：请求成功、开关没变。
        p.strong = nil
        // ⚠️ 但 `allDay` **必须保留** —— overridePatch 明确认 `all_day`。
        //    以后往这里加过滤项时别顺手把它一起清了。

        let body = OccurrenceBody(occurrenceKey: occurrenceKey, patch: p)
        let data = try JSONEncoder().encode(body)

        // 服务端返回 {"event": {...}}，但这里不需要它的内容 ——
        // 改完之后要的是实例列表，refresh() 会重新拉一遍
        _ = try await APIClient.shared.putRaw(
            "/api/events/\(eventID)/occurrence", body: data
        )
        await refresh()
    }

    // MARK: - 日历共享

    /// 加成员时的候选名单。
    ///
    /// ⚠️ 必须用这个列表让人**点选**，不能让用户手打：
    /// 加成员接口认的是 `user_id`（`usr_xxx` 这种），不是用户名。
    /// 让用户打名字的话，服务端会回 404「没有这个账号」，
    /// 而用户看到的明明就是那个名字，只会以为程序坏了。
    func loadDirectory() async throws -> [DirectoryUser] {
        let res: UsersResponse = try await APIClient.shared.get("/api/users")
        return res.users
    }

    /// 把某人加进日历（或改他的角色）。
    ///
    /// 服务端要求 **owner**（`canManageMembers`），且：
    /// - 加自己 → 400「你自己已经在名单里了」
    /// - 用户不存在 → 404
    /// - 传 `owner` 会被**静默降成 admin**（转让所有权是另一个动作）
    func addMember(calendarID: String, userID: String, role: String) async throws {
        // 先挡掉那个静默降级：与其让用户以为设成了创建者，不如直接说清楚
        guard role != "owner" else {
            throw APIError.server(400, "不能把别人设成创建者。想转让日历请用别的入口。")
        }
        let data = try JSONEncoder().encode(AddMemberBody(userID: userID, role: role))
        _ = try await APIClient.shared.postRaw("/api/calendars/\(calendarID)/members", body: data)
        await refresh()
    }

    /// 把某人移出日历。
    ///
    /// 服务端不允许移自己（400「不能移除自己」）—— 自己想退出请用 `leaveCalendar`。
    func removeMember(calendarID: String, userID: String) async throws {
        try await APIClient.shared.delete("/api/calendars/\(calendarID)/members/\(userID)")
        await refresh()
    }

    /// 改某个成员的角色。同样要 owner。
    func setPermissions(calendarID: String, userID: String, role: String) async throws {
        guard role != "owner" else {
            throw APIError.server(400, "不能把别人设成创建者。")
        }
        let data = try JSONEncoder().encode(SetPermissionsBody(userID: userID, role: role))
        _ = try await APIClient.shared.putRaw("/api/calendars/\(calendarID)/permissions", body: data)
        await refresh()
    }

    /// 「共享」开关。
    ///
    /// ⚠️ 这**不是**收回权限。源码注释（`acl.go:631`）：
    /// 「关掉共享只是让『以后再加人』需要重新打开，已经分享出去的同学会继续看到这张日历」。
    /// UI 上必须照实说明，否则用户会以为关掉就收回了。
    func setShared(calendarID: String, shared: Bool) async throws {
        let data = try JSONEncoder().encode(ShareBody(shared: shared))
        _ = try await APIClient.shared.postRaw("/api/calendars/\(calendarID)/share", body: data)
        await refresh()
    }

    /// 退出别人分享给我的日历。
    ///
    /// 这是**唯一**由非 owner 发起的成员变更 —— owner 想收回权限得移除别人。
    func leaveCalendar(id: String) async throws {
        _ = try await APIClient.shared.postRaw("/api/calendars/\(id)/leave", body: nil)
        await refresh()
    }

    // MARK: - 团队

    /// 我加入的团队。
    ///
    /// ⚠️ 服务端的 WHERE 里带 `team_members.user_id = 我`，
    ///    所以这个接口**永远**只回我自己的团队，不会有全服列表。
    ///    客户端不需要（也不该）再做过滤 —— 做了反而掩盖了服务端漏条件的问题。
    func loadTeams() async throws -> [TeamDTO] {
        let res: TeamsResponse = try await APIClient.shared.get("/api/teams")
        return res.teams
    }

    /// 建一个团队。创建者自动成为管理员。
    func createTeam(name: String, note: String) async throws -> TeamDTO {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.server(400, "团队名不能为空")
        }
        // 服务端按 rune 数算，上限 40。Swift 的 count 也是「字符数」，
        // 但 emoji 在 Go 里算 1 个 rune、在 Swift 里也可能算 1 个 Character，
        // 两边一致；真正会分叉的是组合字符，这里不追那个精度 ——
        // 服务端仍然会兜底拒绝，不会写坏数据。
        guard trimmed.count <= 40 else {
            throw APIError.server(400, "团队名太长了（最多 40 个字）")
        }
        let data = try JSONEncoder().encode(
            CreateTeamBody(name: trimmed, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let res: TeamEnvelopeDTO = try await APIClient.shared.post("/api/teams", body: data)
        return res.team
    }

    /// 团队详情（成员名单 + 已绑定的日历）。
    ///
    /// **非成员一律 404** —— 服务端刻意不回 403，因为 403 会泄漏「这个团队存在」。
    func loadTeamDetail(id: String) async throws -> TeamDetailResponse {
        try await APIClient.shared.get("/api/teams/\(id)")
    }

    /// 退出团队。创建者不能退（服务端 409），UI 上不给这个按钮。
    func leaveTeam(id: String) async throws {
        _ = try await APIClient.shared.postRaw("/api/teams/\(id)/leave", body: nil)
    }

    /// 团队管理员移除成员。创建者不可被移除（服务端 409）。
    func removeTeamMember(teamID: String, userID: String) async throws {
        try await APIClient.shared.delete("/api/teams/\(teamID)/members/\(userID)")
    }

    /// 改团队成员角色（`admin` ↔ `member`）。仅团队管理员。
    ///
    /// 服务端只认这两个值，别的直接 400。创建者必须保持 admin（409）。
    func setTeamMemberRole(teamID: String, userID: String, role: String) async throws {
        guard role == "admin" || role == "member" else {
            throw APIError.server(400, "团队角色只能是管理员或成员")
        }
        let data = try JSONEncoder().encode(SetTeamRoleBody(role: role))
        _ = try await APIClient.shared.putRaw("/api/teams/\(teamID)/members/\(userID)", body: data)
    }

    // MARK: - 团队邀请码

    /// 生成团队邀请码。
    ///
    /// ⚠️ `role == "admin"` 的邀请**只有创建者能发** —— 普通管理员只能发 member 邀请。
    ///    源码（`teams.go:477`）：「一个管理员手上的『发 admin 邀请』能力 = 可以无限复制
    ///    管理员身份……足以让爸妈看不到共享日历。」UI 上要按 `team.ownerID` 判断，
    ///    别只看 `isAdmin`，否则普通管理员点了才吃 403。
    ///
    /// `maxUses == 0` 表示不限次数（团队邀请的默认值和日历邀请故意不同）。
    func createTeamInvite(
        teamID: String,
        role: String,
        ttlHours: Int64 = 7 * 24,
        maxUses: Int64 = 0
    ) async throws -> TeamInviteDTO {
        guard role == "admin" || role == "member" else {
            throw APIError.server(400, "团队角色只能是管理员或成员")
        }
        let data = try JSONEncoder().encode(
            CreateTeamInviteBody(role: role, ttlHours: ttlHours, maxUses: maxUses)
        )
        let res: TeamInviteEnvelopeDTO = try await APIClient.shared.post(
            "/api/teams/\(teamID)/invites", body: data
        )
        return res.invite
    }

    func loadTeamInvites(teamID: String) async throws -> [TeamInviteDTO] {
        let res: TeamInvitesResponse = try await APIClient.shared.get(
            "/api/teams/\(teamID)/invites"
        )
        return res.invites
    }

    func revokeTeamInvite(id: String) async throws {
        try await APIClient.shared.delete("/api/team-invites/\(id)")
    }

    /// 用邀请码加入团队。**已经是成员时服务端返回 `already_member` 并成功**，
    /// 且不消耗次数 —— 所以重复点是安全的，不需要客户端先查一遍。
    func acceptTeamInvite(code: String) async throws -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.server(400, "请填写邀请码")
        }
        // 返回体带 team_id，用来进入团队页；这里只取 id，其余字段用不上。
        struct AcceptResult: Decodable { let teamID: String?
            enum CodingKeys: String, CodingKey { case teamID = "team_id" } }
        let res: AcceptResult = try await APIClient.shared.post(
            "/api/team-invites/\(trimmed)/accept", body: nil
        )
        return res.teamID ?? ""
    }

    // MARK: - 日历 ↔ 团队

    /// 这张日历共享给了哪些团队。需要我对这张日历 `canManageMembers`。
    func loadCalendarTeamShares(calendarID: String) async throws -> [TeamCalendarShareDTO] {
        let res: CalendarTeamSharesResponse = try await APIClient.shared.get(
            "/api/calendars/\(calendarID)/teams"
        )
        return res.shares
    }

    /// 把日历共享给团队。
    ///
    /// ## 三个前置条件，缺一不可
    ///
    /// 1. 我对这张日历 `canManageMembers`
    /// 2. **我是这个团队的成员**（「先加入、后共享」）
    /// 3. 角色只能是 `editor` / `viewer`
    ///
    /// 第 3 条**不做静默降级**：服务端对 admin/owner 直接 400，
    /// 因为「静默降级会让共享者以为自己给了 admin」。
    /// 所以这里也直接抛错，不替用户改成 editor 再发。
    func shareCalendarToTeam(
        calendarID: String,
        teamID: String,
        role: String
    ) async throws {
        guard role == "editor" || role == "viewer" else {
            throw APIError.server(400, "团队能拿到的角色只有「可编辑」和「只读」")
        }
        let data = try JSONEncoder().encode(
            ShareCalendarToTeamBody(teamID: teamID, role: role)
        )
        _ = try await APIClient.shared.postRaw(
            "/api/calendars/\(calendarID)/teams", body: data
        )
        await refresh()
    }

    /// 取消某团队对这张日历的共享。
    ///
    /// 服务端会重挂同步流 —— 否则被取消的团队本地还能看到旧内容。
    func unshareCalendarFromTeam(calendarID: String, teamID: String) async throws {
        try await APIClient.shared.delete("/api/calendars/\(calendarID)/teams/\(teamID)")
        await refresh()
    }

    // MARK: - 课程表节次

    /// 课表的「节次表」—— 网格有哪几行、每行几点到几点。

    /// 失败时退回 `CourseDefaults.periods` 而不是抛错：
    /// 拉不到节次表就把课表画成空白，比显示一个服务端默认布局更糟。
    /// 这个兜底和源码 `coursePeriods()` 里 `raw == ""` 的处理方式一致。
    func loadCoursePeriods() async -> [CoursePeriod] {
        do {
            let res: CoursePeriodsResponse = try await APIClient.shared.get("/api/course/periods")
            return res.periods.isEmpty ? CourseDefaults.periods : res.periods.sorted { $0.index < $1.index }
        } catch {
            return CourseDefaults.periods
        }
    }

    /// 保存节次表。**只有管理员能调** —— 服务端 handler 第一行就是 requireAdmin。
    ///
    /// 客户端这边也做了同样的校验前置，本地把不合法的数据挡住，
    /// 免得把用户辛苦排好的表发出去吃一个 400 再回来改。
    func saveCoursePeriods(_ periods: [CoursePeriod]) async throws {
        guard !periods.isEmpty, periods.count <= 20 else {
            throw APIError.server(400, "节次数需要在 1~20 之间")
        }
        // 序号不能重复 —— 服务端用它当网格行标识
        var seen = Set<Int>()
        for p in periods {
            guard !seen.contains(p.index) else {
                throw APIError.server(400, "第 \(p.index) 节重复了")
            }
            seen.insert(p.index)
            // 必须是严格的 HH:MM 且 start < end。
            // 服务端是按**字符串**比较的，所以「9:00」这种不补零的写法会得到错误的大小关系，
            // 这里也按字符串比，保持和服务端一致的判断。
            guard Self.isClock(p.start), Self.isClock(p.end) else {
                throw APIError.server(400, "第 \(p.index) 节的时间要写成 HH:MM")
            }
            guard p.start < p.end else {
                throw APIError.server(400, "第 \(p.index) 节的结束时间要晚于开始时间")
            }
        }

        let body = CoursePeriodsBody(periods: periods.sorted { $0.index < $1.index })
        let data = try JSONEncoder().encode(body)
        _ = try await APIClient.shared.putRaw("/api/course/periods", body: data)
    }

    /// `HH:MM`，两位小时 + 两位分钟，且取值合法。
    private static func isClock(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return h >= 0 && h <= 23 && m >= 0 && m <= 59
    }

    // MARK: - 冲突

    /// 拉冲突列表。
    ///
    /// `includeResolved` 对应服务端的 `?all=1`：默认只返回未解决的。
    ///
    /// ⚠️ 这里有**外键级**的坑：`conflicts` 表没有 user_id，
    ///    服务端在返回前会逐条回查日历权限做过滤。所以不要把这个列表
    ///    在本地持久化后跨账号复用 —— 换了人登录，那些条目本不该被看见。
    func loadConflicts(includeResolved: Bool = false) async throws -> [ConflictDTO] {
        let query: [URLQueryItem] = includeResolved
            ? [URLQueryItem(name: "all", value: "1")]
            : []
        let res: ConflictsResponse = try await APIClient.shared.get(
            "/api/conflicts", query: query
        )
        return res.conflicts
    }

    /// 解决一条冲突。
    ///
    /// `resolution` 只能是 `ResolveConflictBody` 里那三个常量之一，
    /// 服务端对别的值直接 400（`resolution 必须是 keep_mine / keep_server / keep_both`）。
    func resolveConflict(id: String, resolution: String) async throws {
        guard ResolveConflictBody.valid(resolution) else {
            throw APIError.server(400, "无法识别的处理方式：\(resolution)")
        }
        let data = try JSONEncoder().encode(ResolveConflictBody(resolution: resolution))
        _ = try await APIClient.shared.postRaw(
            "/api/conflicts/\(id)/resolve", body: data
        )
        // 冲突解决完，服务端可能复制了新日程或改了字段，列表必须重拉
        await refresh()
    }

    // MARK: - 稍后提醒

    /// 把这一次的提醒往后推 `minutes` 分钟。
    ///
    /// 返回服务端算好的提醒时刻（epoch 秒），nil 表示服务端没回这个字段
    /// —— 调用方应该退回用 `Date() + minutes*60` 自己算。
    ///
    /// ⚠️ `minutes` 必须 > 0。服务端 `if req.Minutes <= 0 { 400 }`，
    ///    所以「取消」走 `clearSnooze` 而不是传 0。
    @discardableResult
    func snooze(
        eventID: String,
        occurrenceKey: Int64,
        minutes: Int,
        deviceID: String = "ios"
    ) async throws -> Int64? {
        guard minutes > 0 else { throw APIError.server(400, "稍后提醒的时长必须大于 0") }

        let body = SnoozeBody(
            occurrenceKey: occurrenceKey,
            minutes: Int64(minutes),
            deviceID: deviceID
        )
        let data = try JSONEncoder().encode(body)
        let res: SnoozeResponse = try await APIClient.shared.post(
            "/api/events/\(eventID)/snooze", body: data
        )
        return res.remindAtUTC
    }

    /// 取消这条日程上**我自己**的所有稍后提醒。
    ///
    /// 服务端按 (event_id, user_id) 清理，不会动别人的 ——
    /// 共享日历上你取消了稍后提醒，别人该响还是响。
    func clearSnooze(eventID: String) async throws {
        try await APIClient.shared.delete("/api/events/\(eventID)/snooze")
    }

    // MARK: - 日历

    private struct CalendarEnvelope: Decodable {
        let calendar: CalendarDTO?
    }

    func createCalendar(name: String, color: String, kind: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.server(400, "日历名称不能为空") }

        let body = CalendarBody(name: trimmed, color: color, kind: kind)
        let data = try JSONEncoder().encode(body)
        let _: CalendarEnvelope = try await APIClient.shared.post("/api/calendars", body: data)
        await refresh()
    }

    /// 改名 / 改颜色。
    ///
    /// ⚠️ `kind` 只有 owner 能改（服务端 2026-10-20 收紧过）。
    ///    所以这里只在传了 kind 且确实变化时才带它，
    ///    不然 editor 改个颜色会被 403 拦下来 —— 而他明明只改了颜色。
    func updateCalendar(
        id: String,
        name: String?,
        color: String?,
        kind: String?
    ) async throws {
        var body = CalendarBody()
        body.name = name
        body.color = color
        body.kind = kind

        let data = try JSONEncoder().encode(body)
        let _: CalendarEnvelope = try await APIClient.shared.put(
            "/api/calendars/\(id)", body: data
        )
        await refresh()
    }

    /// 删除日历（连带里面的日程）。服务端只允许 owner。
    func deleteCalendar(id: String) async throws {
        try await APIClient.shared.delete("/api/calendars/\(id)")
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
