import Foundation

/// 时间显示相关的小工具。
///
/// 全部按**本机时区**算 —— 服务端存的是 UTC 秒，什么时候算成「哪一天」
/// 由设备决定。这一点和安卓端一致（那边用的也是设备时区）。
extension Date {

    static var now: Date { Date() }

    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// 本周的周一（中国习惯周一为一周之始，不是周日）
    var startOfWeekMonday: Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return cal.date(from: comps) ?? startOfDay
    }

    func addingDays(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: self) ?? self
    }

    /// 加月份。
    ///
    /// ⚠️ 不用「加 30 天」代替：1 月 31 日加 30 天是 3 月 2 日，
    ///    连着翻几个月就会越翻越偏。Calendar 会正确处理月末（1/31 + 1 月 = 2/28）。
    func addingMonths(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: n, to: self) ?? self
    }

    /// 当月 1 日 00:00
    var startOfMonth: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: self)
        return cal.date(from: comps) ?? startOfDay
    }

    /// 当月天数
    var daysInMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: self)?.count ?? 30
    }

    /// 从本月 1 日到 1 日之间的空格数（用于月视图首行对齐）。
    /// 以周一为一周之始，返回 0…6。
    var leadingBlankDaysInMonth: Int {
        let cal = Calendar.current
        let firstWeekday = cal.component(.weekday, from: startOfMonth)  // 1=周日
        // 转成「周一=0 … 周日=6」
        return (firstWeekday + 5) % 7
    }

    /// 「2026年10月」
    var yearMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: self)
    }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    /// 「09:00」
    var hhmm: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: self)
    }

    /// 「10月25日」
    var monthDay: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日"
        return f.string(from: self)
    }

    /// 「2027年3月1日」——带年份，用于到期日这类**跨年也要说清**的场合。
    ///
    /// 不用 `monthDay`：会员到期日可能是明年，「3月1日到期」看不出是今年还是明年。
    var yearMonthDay: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: self)
    }

    /// 「周六」
    var weekdayName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "EEEE"
        return f.string(from: self)
    }

    /// 「今天 / 明天 / 昨天 / 10月25日」
    var friendlyDay: String {
        if isSameDay(as: .now) { return "今天" }
        if isSameDay(as: Date.now.addingDays(1)) { return "明天" }
        if isSameDay(as: Date.now.addingDays(-1)) { return "昨天" }
        return monthDay
    }

    /// 90 分钟 → 「1 小时 30 分」
    static func durationText(seconds: Int64) -> String {
        guard seconds > 0 else { return "" }
        let minutes = Int((seconds + 30) / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }
}

/// 把「日期 + 时间」拼成一个 epoch 秒。
///
/// ⚠️ 服务端要的是**秒**。Date 的 timeIntervalSince1970 是秒（Double），
///    `Date().timeIntervalSince1970 * 1000` 才是毫秒 —— 差一千倍，
///    传错的表现是「开始时间不在合理范围（2000~2100 年）」。
func epochSeconds(date: Date, time: Date) -> Int64 {
    let cal = Calendar.current
    let d = cal.dateComponents([.year, .month, .day], from: date)
    let t = cal.dateComponents([.hour, .minute], from: time)
    var comps = DateComponents()
    comps.year = d.year
    comps.month = d.month
    comps.day = d.day
    comps.hour = t.hour
    comps.minute = t.minute
    comps.second = 0
    let merged = cal.date(from: comps) ?? date
    return Int64(merged.timeIntervalSince1970.rounded())
}
