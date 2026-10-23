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

    var isLoading = false
    var errorMessage: String?

    // MARK: - 视图状态

    var weekStart: Date = Date.now.startOfWeekMonday

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
        if token != nil {
            let _: EmptyOK? = try? await APIClient.shared.post("/api/auth/logout", body: nil)
        }
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

        let from = weekStart.startOfDay
        let to = weekStart.addingDays(7).startOfDay
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

    func goToday() async {
        weekStart = Date.now.startOfWeekMonday
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
        durationMinutes: Int
    ) async throws {
        let body = NewEventBody(
            calendarID: calendarID,
            title: title,
            startUTC: Int64(start.timeIntervalSince1970.rounded()),
            durationSec: Int64(max(0, durationMinutes) * 60),
            tzid: TimeZone.current.identifier
        )
        let data = try JSONEncoder().encode(body)
        let _: CreatedEvent = try await APIClient.shared.post("/api/events", body: data)
        await refresh()
    }

    func deleteEvent(eventID: String) async throws {
        try await APIClient.shared.delete("/api/events/\(eventID)")
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

/// 只为「不关心返回体」的 POST 准备（比如登出）
struct EmptyOK: Decodable {}
