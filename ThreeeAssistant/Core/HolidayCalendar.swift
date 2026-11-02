import Foundation

// ============================================================
//  法定节假日与调休
//  ------------------------------------------------------------
//
//  中国高校课表最绕的地方不是「放假」，而是**调休**：
//  国庆放假 7 天，但前后的周六周日要补课，而且补的是
//  「第几周星期几的课」。于是同一个周六，
//  有的学院上周三的课，有的上周四的 —— 这件事学校自己排，没有通例。
//
//  所以这里做两件事，两件事都**只影响显示**：
//
//    1. 法定假日当天的日程 → 默认折叠，说清「因为国庆」
//    2. 调休补课的周末 → 可以把「被补的那一天」的日程显示过来
//
//  ## 为什么不能自动改服务端数据
//
//  这台手机上的日程里混着别人共享来的日历、别的客户端导入的 ICS。
//  如果 App 偷偷把「周三的课」挪到「调休的周六」写回服务端，
//  用户在他的电脑上会看到一件自己没做过的事 —— 而且没有任何痕迹说明
//  是哪个客户端干的。所以补课只在本地**映射**，服务端一个字节都不动。
//
//  ## 为什么内置而不是联网取
//
//  国务院的放假安排每年 11 月前后才发，发布前谁都不知道具体怎么调。
//  联网取意味着每年要跟一次接口变更、还要处理断网，
//  而断网时最需要它（比如在教室里）恰恰取不到。
//  内置表 + 允许用户自己补，是唯一永远不会失效的方案。
//
//  ⚠️ 内置数据只到 2027 年。**2028 年及以后的安排我无从得知**，
//     界面上必须明确告诉用户「这一年没有假日数据，点这里自己加」，
//     而不是静默当成「这一年没有节假日」。
// ============================================================

/// 某一天的性质。
enum DayKind: Equatable {
    /// 普通工作日 / 普通周末，什么都不用管
    case normal

    /// 法定节假日。`name` 是「国庆节」这种名字。
    case holiday(name: String)

    /// 调休上班日（被征用的周末）。`workAs` 是被当作那一天上课，
    /// 例如「2026-10-10 上周三的课」里 `workAs` 就是周三（weekday=4）。
    ///
    /// ⚠️ 全国公布的是「10月10日上班」，但**上星期几的课是各校自己定的**。
    ///    默认填周三只是最常见的排法，用户必须能改。
    case makeupWork(name: String, workAs: Int?)
}

/// 一条假日规则。存成「起止日期 + 名称」而不是逐天展开，
/// 因为用户手动添加时是一条一条加的，展开后回不去。
struct HolidayRule: Codable, Hashable, Identifiable {
    let id: String
    /// 起始日，`yyyy-MM-dd`
    let start: String
    /// 结束日（含），`yyyy-MM-dd`。单日假与 start 相同。
    let end: String
    /// 「国庆节」「中秋节」
    let name: String
    /// 内置的（不可删）还是用户自己加的
    let builtin: Bool
}

/// 调休上班日。全国公布「这天要上班」，上哪天的课由学校定。
struct MakeupDay: Codable, Hashable, Identifiable {
    let id: String
    /// `yyyy-MM-dd`
    let date: String
    /// 适用名称，例如「国庆调休」
    let name: String
    /// 当作周几上课。1=周日 … 7=周六（与 Calendar.weekday 一致）。
    /// nil = 只看作普通上班日，不映射任何日程。
    var workAs: Int?
    let builtin: Bool
}

enum HolidayCalendar {

    private static let ruleKey = "threees.holidayRules"
    private static let makeupKey = "threees.makeupDays"

    /// 「用户改过几次假日设置」。
    ///
    /// ⚠️ 存在的唯一原因：`SessionStore.dayGroups` 是 `@Observable` 类里的
    ///    计算属性，但它读的是 `UserDefaults`。用户在设置页加了一个假日，
    ///    观察机制**看不见**这个变化，日程页会一直显示旧结果，
    ///    直到下次下拉刷新 —— 而用户会以为"加了没用"。
    ///
    ///    所以设置页写完之后把它 +1，而视图只要读一下它，
    ///    就建立了一条依赖，能正确失效。
    static var revision: Int {
        get { UserDefaults.standard.integer(forKey: revisionKey) }
        set { UserDefaults.standard.set(newValue, forKey: revisionKey) }
    }
    private static let revisionKey = "threees.holidayRevision"

    /// 改完记得调一次
    static func bumpRevision() { revision &+= 1 }

    // MARK: - 内置数据

    /// 内置假日规则。
    ///
    /// 数据来源：国务院办公厅关于节假日安排的通知（2025 年起施行修订后的
    /// 《全国年节及纪念日放假办法》，法定假日由 11 天增至 13 天）。
    ///
    /// ⚠️ 只收 **2026、2027** 两年。更早的年份用户不会用到（课表都是当年的），
    ///    更晚的年份公布了我也不知道 —— 与其用「往年规律」瞎猜，
    ///    不如留空让用户自己补。猜错的假日比没有假日更糟：
    ///    用户会照着错的表以为那天不上课。
    static let builtinRules: [HolidayRule] = [
        // ── 2026 ──
        // 元旦 1/1–1/3；1/4 起上班
        HolidayRule(id: "2026-newyear", start: "2026-01-01", end: "2026-01-03",
                    name: "元旦", builtin: true),
        // 春节 2/15（除夕）–2/22，共 8 天
        HolidayRule(id: "2026-spring", start: "2026-02-15", end: "2026-02-22",
                    name: "春节", builtin: true),
        // 清明 4/4–4/6
        HolidayRule(id: "2026-qingming", start: "2026-04-04", end: "2026-04-06",
                    name: "清明节", builtin: true),
        // 劳动节 5/1–5/5
        HolidayRule(id: "2026-labour", start: "2026-05-01", end: "2026-05-05",
                    name: "劳动节", builtin: true),
        // 端午 6/19–6/21
        HolidayRule(id: "2026-duanwu", start: "2026-06-19", end: "2026-06-21",
                    name: "端午节", builtin: true),
        // 中秋 9/25–9/27
        HolidayRule(id: "2026-midautumn", start: "2026-09-25", end: "2026-09-27",
                    name: "中秋节", builtin: true),
        // 国庆 10/1–10/7
        HolidayRule(id: "2026-national", start: "2026-10-01", end: "2026-10-07",
                    name: "国庆节", builtin: true),

        // ── 2027 ──
        HolidayRule(id: "2027-newyear", start: "2027-01-01", end: "2027-01-03",
                    name: "元旦", builtin: true),
        // 2027 春节 2/5 是除夕，2/6 春节
        HolidayRule(id: "2027-spring", start: "2027-02-05", end: "2027-02-12",
                    name: "春节", builtin: true),
        HolidayRule(id: "2027-qingming", start: "2027-04-04", end: "2027-04-06",
                    name: "清明节", builtin: true),
        HolidayRule(id: "2027-labour", start: "2027-05-01", end: "2027-05-05",
                    name: "劳动节", builtin: true),
        HolidayRule(id: "2027-duanwu", start: "2027-06-09", end: "2027-06-11",
                    name: "端午节", builtin: true),
        HolidayRule(id: "2027-midautumn", start: "2027-09-15", end: "2027-09-17",
                    name: "中秋节", builtin: true),
        HolidayRule(id: "2027-national", start: "2027-10-01", end: "2027-10-07",
                    name: "国庆节", builtin: true),
    ]

    /// 内置调休上班日。
    ///
    /// ⚠️ `workAs` 填的是**全国最常见的排法**，不是强制的。
    ///    真正的「补哪天的课」各校不同，用户可以在设置页改；
    ///    改过的值存在 UserDefaults 里，覆盖这里。
    static let builtinMakeups: [MakeupDay] = [
        // 2026
        MakeupDay(id: "2026-mk-0104", date: "2026-01-04", name: "元旦调休",
                  workAs: nil, builtin: true),
        MakeupDay(id: "2026-mk-0214", date: "2026-02-14", name: "春节调休",
                  workAs: 6, builtin: true),   // 周六上班，常上周五的课
        MakeupDay(id: "2026-mk-0228", date: "2026-02-28", name: "春节调休",
                  workAs: 6, builtin: true),
        MakeupDay(id: "2026-mk-0509", date: "2026-05-09", name: "劳动节调休",
                  workAs: 6, builtin: true),
        MakeupDay(id: "2026-mk-0920", date: "2026-09-20", name: "中秋调休",
                  workAs: 6, builtin: true),   // 周日常补周五（weekday 口径 6=周五）
        MakeupDay(id: "2026-mk-1010", date: "2026-10-10", name: "国庆调休",
                  workAs: 4, builtin: true),   // 周六上周三
        // 2027
        MakeupDay(id: "2027-mk-0206", date: "2027-02-06", name: "春节调休",
                  workAs: 6, builtin: true),
        MakeupDay(id: "2027-mk-0220", date: "2027-02-20", name: "春节调休",
                  workAs: 6, builtin: true),
        MakeupDay(id: "2027-mk-0508", date: "2027-05-08", name: "劳动节调休",
                  workAs: 6, builtin: true),
        MakeupDay(id: "2027-mk-0925", date: "2027-09-25", name: "国庆调休",
                  workAs: 6, builtin: true),
    ]

    // MARK: - 用户覆盖

    /// 用户自己加的假日（与内置合并后生效）
    static var userRules: [HolidayRule] {
        get { load(ruleKey, as: [HolidayRule].self) ?? [] }
        set { save(newValue, key: ruleKey) }
    }

    /// 用户改过的调休日。**整体覆盖**同名 id 的内置项。
    static var userMakeups: [MakeupDay] {
        get { load(makeupKey, as: [MakeupDay].self) ?? [] }
        set { save(newValue, key: makeupKey) }
    }

    private static func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private static func save<T: Encodable>(_ v: T, key: String) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    // MARK: - 生效的数据

    /// 内置 + 用户添加，按起始日排序
    static var allRules: [HolidayRule] {
        (builtinRules + userRules).sorted { $0.start < $1.start }
    }

    /// 调休日。用户改过的（同 id）覆盖内置的。
    static var allMakeups: [MakeupDay] {
        let overridden = Set(userMakeups.map(\.id))
        let kept = builtinMakeups.filter { !overridden.contains($0.id) }
        return (kept + userMakeups).sorted { $0.date < $1.date }
    }

    /// 表里覆盖了哪些年份。用来在界面上说「2028 年没有数据」。
    static var coveredYears: Set<Int> {
        var s = Set<Int>()
        for r in allRules {
            if let y = Int(r.start.prefix(4)) { s.insert(y) }
        }
        return s
    }

    // MARK: - 查询

    /// 这一天是什么性质。
    ///
    /// 优先级：**调休上班日 > 法定假日 > 普通**。
    /// 顺序不能反：偶尔会出现「调休上班日落在假期区间内」的情况
    /// （比如春节长假中间被征用的那个周六），这时应当按上班日算。
    static func kind(of day: Date, makeups: [MakeupDay]? = nil,
                     rules: [HolidayRule]? = nil) -> DayKind {
        let key = day.dateKey

        for m in (makeups ?? allMakeups) where m.date == key {
            return .makeupWork(name: m.name, workAs: m.workAs)
        }
        for r in (rules ?? allRules) where key >= r.start && key <= r.end {
            return .holiday(name: r.name)
        }
        return .normal
    }

    /// 这一天如果是调休补课日，返回「被当作周几」，否则 nil。
    ///
    /// `workAs` 走 `Calendar.weekday` 的口径（1=周日、2=周一 … 7=周六）。
    static func makeupWeekday(of day: Date) -> Int? {
        if case .makeupWork(_, let w) = kind(of: day) { return w }
        return nil
    }

    /// 把「某天当作周几过」翻译成「应该显示哪一天的日程」。
    ///
    /// 例如 2026-10-10（周六）上周三的课，
    /// 那么这天要显示「本周三」那天原本排的日程。
    ///
    /// ## ⚠️ 为什么不能只算「从周一偏移几天」
    ///
    /// 最初写的是 `offset = (workAs + 5) % 7`（把 weekday 口径转成周一=0）。
    /// 对周一~周六都对，但 `workAs == 1`（周日）时会算出 6，
    /// 也就是**周日自己** —— 于是被下面「源日子就是自己」的判断挡掉，
    /// 「周日补周五的课」这个真实存在的排法就静默失效了。
    ///
    /// 正确做法：补课日永远在本教学周内（周日属于**本**周的末尾，
    /// 不是下周的开头），所以按 `weekdayName` 直接在本周里找，
    /// 不经过"周一偏移"这个中间概念。
    static func sourceDay(for day: Date) -> Date? {
        guard let w = makeupWeekday(of: day) else { return nil }
        let monday = day.startOfWeekMonday
        // 本周里 weekday == w 的那一天。
        // 周一~周六在 monday…monday+5；周日在 monday+6。
        // 用 `Calendar.component` 逐个比，比手算偏移更不容易错
        let cal = Calendar.current
        for i in 0...6 {
            let d = monday.addingDays(i)
            if cal.component(.weekday, from: d) == w {
                // 源日子就是自己 → 不需要映射，否则会自己复制一份自己
                return d.isSameDay(as: day) ? nil : d
            }
        }
        return nil
    }
}

extension Date {
    /// `yyyy-MM-dd`，**本机时区**。假日表就是按这个口径比的。
    var dateKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    /// 从 `yyyy-MM-dd` 解析，失败返回 nil
    static func fromDateKey(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
