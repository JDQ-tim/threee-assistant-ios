import Foundation

/// 「这个学期第几周」的全部推算。
///
/// ## 为什么需要「锚点」这个显式概念
///
/// 「第 8 周」不是日历上的客观事实 —— 它依赖「第 1 周从哪天算起」，
/// 而每个学校都不一样（有的按开学日，有的按第一个周一，有的开学前一周
/// 就教学周 1）。所以这里不猜，让用户填一个**锚点日期**，
/// 之后所有周次都由它推算。
///
/// ## 为什么锚点存在 UserDefaults 而不是跟着账号走
///
/// 严格说，换账号应该换一套周次（不同学校）。但：
/// - 绝大多数人在这个 App 上只有一个账号
/// - 锚点跟着账号存，需要在服务端加字段 —— 而服务端是别人的项目，
///   加字段意味着 iOS 端只能等新版服务端
///
/// 所以存在本机，并在设置页明确写「这台设备上的教学周起点」。
/// 换设备要重填一次，这是能接受的代价；周次算错不能接受。
enum WeekNumbering {

    private static let anchorKey = "threees.weekAnchor"
    private static let totalKey = "threees.weekTotal"

    /// 锚点：第 1 周的**周一** 00:00。nil 表示用户还没设置。
    ///
    /// 存的是「周一那天的 00:00」而不是用户随手选的那天：
    /// 用户可能选周三，若直接拿周三当锚点，之后每一周的减法都会错一天，
    /// 表现为「周三选的第 1 周，周日显示的却是第 2 周」。
    static var anchor: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: anchorKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let d = newValue {
                UserDefaults.standard.set(d.startOfWeekMonday.timeIntervalSince1970,
                                          forKey: anchorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: anchorKey)
            }
        }
    }

    /// 学期总周数（用于「第 8/18 周」和越界提示）。0 表示不限制。
    static var totalWeeks: Int {
        get { UserDefaults.standard.integer(forKey: totalKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: totalKey) }
    }

    /// 某个日期落在第几周。未设锚点时返回 nil。
    ///
    /// ## 算法
    ///
    /// 两周的周一之间相差正好 7 的倍数天（都归一化到 00:00 后减秒数），
    /// 所以 `天数 / 7 + 1` 就是周次。
    ///
    /// ⚠️ **不能用 `Calendar.dateComponents([.weekOfYear], from:to:)`**。
    ///    那个数的是「跨了几个日历周」，在跨年时会因为 ISO 周编号回绕
    ///    （第 52 周之后是第 1 周）算出 -51 这种数。
    ///    这里锚点是用户自定的，跟 ISO 周毫无关系，只能自己按天数算。
    ///
    /// ⚠️ 用 `rounded()` 而不是整数除法：夏令时切换那天只有 23 小时，
    ///    两地毫秒差会有 ±3600 秒的抖动。除以 7 天再四舍五入，
    ///    能把这种抖动吸收掉（误差上限 1 小时，远小于 7 天的一半）。
    static func weekIndex(for date: Date, anchor: Date? = WeekNumbering.anchor) -> Int? {
        guard let anchor else { return nil }
        let a = anchor.startOfWeekMonday
        let b = date.startOfWeekMonday
        let days = b.timeIntervalSince(a) / 86400
        return Int((days / 7).rounded()) + 1
    }

    /// 第几周对应的周一。用于「跳到第 N 周」和算单双周。
    static func monday(ofWeek index: Int, anchor: Date) -> Date {
        anchor.startOfWeekMonday.addingDays((index - 1) * 7)
    }

    /// 单双周。
    ///
    /// ## 判据是「周次是奇是偶」，不是「ISO 周是奇是偶」
    ///
    /// 用户说的「单周」永远指**学期第 1、3、5 周**。
    /// 若按 ISO 周（一年第 40 周）判，同一个学期里单双会莫名其妙地跳一次。
    ///
    /// 负周次（锚点之前）也按同样的奇偶规则：-1 是单周、-2 是双周，
    /// 和自然数一致地向两边延伸。
    enum Parity {
        case odd      // 单周
        case even     // 双周

        var label: String { self == .odd ? "单周" : "双周" }

        /// 短标记，放在紧凑的角落（如月视图格子里）
        var short: String { self == .odd ? "单" : "双" }
    }

    static func parity(ofWeek index: Int) -> Parity {
        // Swift 的 % 对负数返回负数（-3 % 2 == -1），所以用 magunitude 判
        index.magnitude % 2 == 1 ? .odd : .even
    }

    static func parity(for date: Date, anchor: Date? = WeekNumbering.anchor) -> Parity? {
        weekIndex(for: date, anchor: anchor).map(parity(ofWeek:))
    }

    /// 一句话描述，直接显示在日程页顶部。
    ///
    /// 三种状态要分清楚，否则用户看到空白会以为功能坏了：
    /// - 没设锚点 → "设置教学周" (可点)
    /// - 正常 →  "第 8 周 · 单周"
    /// - 超出总周数 → "第 20 周（已结课）"
    static func label(for date: Date) -> WeekLabel {
        guard let anchor = anchor else { return .unset }
        guard let idx = weekIndex(for: date, anchor: anchor) else { return .unset }

        if idx <= 0 {
            // 锚点之前：这是个真实状态（用户翻到开学前那几周），
            // 说「未开学」比显示「第 0 周」「第 -2 周」都清楚
            return .beforeStart(weeksToGo: 1 - idx)
        }

        let total = totalWeeks
        if total > 0 && idx > total {
            return .afterEnd(week: idx, total: total)
        }

        return .normal(week: idx, total: total > 0 ? total : nil, parity: parity(ofWeek: idx))
    }

    enum WeekLabel {
        case unset
        /// 还没开学，`weeksToGo` 周后开课（1 表示下周）
        case beforeStart(weeksToGo: Int)
        case normal(week: Int, total: Int?, parity: Parity)
        case afterEnd(week: Int, total: Int)

        var text: String {
            switch self {
            case .unset:
                return "设置教学周"
            case .beforeStart(let n):
                return n == 1 ? "下周开学" : "\(n) 周后开学"
            case .normal(let week, let total, let parity):
                if let total {
                    return "第 \(week)/\(total) 周 · \(parity.label)"
                }
                return "第 \(week) 周 · \(parity.label)"
            case .afterEnd(let week, let total):
                return "第 \(week) 周（已超 \(total) 周）"
            }
        }

        /// 是否是「需要用户去设置」的状态，UI 上要显示成可点按钮
        var needsSetup: Bool {
            if case .unset = self { return true }
            return false
        }
    }
}
