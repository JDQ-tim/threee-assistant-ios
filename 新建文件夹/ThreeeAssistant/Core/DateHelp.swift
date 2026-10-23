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
