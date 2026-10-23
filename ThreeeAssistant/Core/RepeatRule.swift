import Foundation

/// 把「每 N 周 / 每月几号」这种给人看的选项，翻译成服务端认的 iCalendar RRULE 字符串。
///
/// ## 为什么值得单独一个文件
///
/// RRULE 是一串几乎没有容错余地的文本。写错一个分号，服务端
/// `StrToROptionInLocation` 解析失败，然后 `occurrenceKeys` 走到 fallback 分支
/// 把整条日程当成**单次**日程 —— 用户看到的结果是「我设了每周重复，但它只出现了一次」。
/// 不报错、不提示，比直接报错难查得多。
///
/// 所以这里只允许构造**已知正确**的几种形态，不做通用 RRULE 编辑器。
/// 服务端的 `allowedFreqs` 白名单也只放行 HOURLY/DAILY/WEEKLY/MONTHLY/YEARLY，
/// 正好和这里保持一一对应。
enum RepeatRule {

    /// 界面上能选的重复方式
    enum Kind: String, CaseIterable, Identifiable {
        case none
        case daily
        case weekly
        case monthly
        case yearly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "不重复"
            case .daily: return "每天"
            case .weekly: return "每周"
            case .monthly: return "每月"
            case .yearly: return "每年"
            }
        }
    }

    /// 重复在什么时候结束
    enum End: String, CaseIterable, Identifiable {
        case never
        case count
        case until

        var id: String { rawValue }

        var label: String {
            switch self {
            case .never: return "一直重复"
            case .count: return "重复次数"
            case .until: return "到某天为止"
            }
        }
    }

    /// 生成 RRULE 字符串。
    ///
    /// - Parameters:
    ///   - kind: 重复频率
    ///   - interval: 间隔，`2` + `.weekly` = 每两周
    ///   - weekdays: 仅 `.weekly` 有意义。**空数组表示「跟随开始那天的星期」** ——
    ///     这不是偷懒，是刻意为之：用户选了「每周」却一个都没勾时，
    ///     生成 `FREQ=WEEKLY` 就是"每周同一天"，这正是他想要的。
    ///   - end: 结束方式
    ///   - count: `.count` 时的次数（含第一次）
    ///   - until: `.until` 时的截止日
    ///   - start: 首次开始时间，用于补 `UNTIL` 的时分秒
    /// - Returns: `nil` 表示不重复（服务端用空字符串表示）
    static func build(
        kind: Kind,
        interval: Int,
        weekdays: Set<Int>,
        end: End,
        count: Int,
        until: Date,
        start: Date
    ) -> String? {
        guard kind != .none else { return nil }

        var parts = ["FREQ=\(freqToken(kind))"]

        // INTERVAL=1 是默认值，写出来只是噪音，而且有些老客户端对显式 1 处理不一致
        if interval > 1 {
            parts.append("INTERVAL=\(interval)")
        }

        if kind == .weekly, !weekdays.isEmpty {
            // ⭐️ 顺序必须固定：Set 的迭代顺序每次都可能不同，
            //    同样的选择生成不同字符串会让服务端认为"规则变了"并重算所有实例
            let tokens = weekdays.sorted().compactMap { weekdayToken($0) }
            if !tokens.isEmpty {
                parts.append("BYDAY=" + tokens.joined(separator: ","))
            }
        }

        switch end {
        case .never:
            break

        case .count:
            // COUNT 至少是 1。填 0 或负数时服务端展开出 0 条，等于"建了但看不见"
            parts.append("COUNT=\(max(1, count))")

        case .until:
            // ⚠️ UNTIL 必须用 **UTC**，且格式是 `yyyyMMdd'T'HHmmss'Z'`。
            //    用本地时间会整体偏 8 小时，截止日看起来少一天或多一天。
            parts.append("UNTIL=" + utcStamp(until, start: start))
        }

        // 截至 2026-10 的服务端只认这几种频率，多余的键一律不写
        return parts.joined(separator: ";")
    }

    private static func freqToken(_ kind: Kind) -> String {
        switch kind {
        case .none: return "DAILY"   // 不会走到，调用方已 guard
        case .daily: return "DAILY"
        case .weekly: return "WEEKLY"
        case .monthly: return "MONTHLY"
        case .yearly: return "YEARLY"
        }
    }

    /// Calendar 的 weekday 是 1=周日 … 7=周六；RRULE 的 BYDAY 用两字母缩写。
    private static func weekdayToken(_ weekday: Int) -> String? {
        switch weekday {
        case 1: return "SU"
        case 2: return "MO"
        case 3: return "TU"
        case 4: return "WE"
        case 5: return "TH"
        case 6: return "FR"
        case 7: return "SA"
        default: return nil
        }
    }

    /// 把截止日转成 UTC 时间戳。
    ///
    /// 取的是**截止日当天、首次开始的时分秒** —— 而不是当天 00:00。
    /// 用户勾"到 12 月 31 日为止"，意思是那天的课也要上，
    /// 用 00:00 会把最后一天整个吃掉。
    private static func utcStamp(_ until: Date, start: Date) -> String {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: until)
        let t = cal.dateComponents([.hour, .minute, .second], from: start)
        var comps = DateComponents()
        comps.year = d.year
        comps.month = d.month
        comps.day = d.day
        comps.hour = t.hour
        comps.minute = t.minute
        comps.second = t.second
        let merged = cal.date(from: comps) ?? until

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: merged)
    }

    // MARK: - 给人看的一句话

    /// 「每 2 周的周一、周三」这种描述，给列表和详情页用。
    /// 解析失败时原样返回 rrule，至少不会显示成空。
    static func describe(_ rrule: String) -> String {
        let raw = rrule.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "不重复" }

        let body = raw.hasPrefix("RRULE:") ? String(raw.dropFirst(6)) : raw
        var dict: [String: String] = [:]
        for seg in body.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0]).uppercased()] = String(kv[1]) }
        }

        let interval = Int(dict["INTERVAL"] ?? "") ?? 1
        let freq = (dict["FREQ"] ?? "").uppercased()

        var text: String
        switch freq {
        case "DAILY":
            text = interval == 1 ? "每天" : "每 \(interval) 天"
        case "WEEKLY":
            text = interval == 1 ? "每周" : "每 \(interval) 周"
            if let byday = dict["BYDAY"], !byday.isEmpty {
                let names = byday.split(separator: ",").compactMap { chineseWeekday(String($0)) }
                if !names.isEmpty { text += "的周" + names.joined(separator: "、周") }
            }
        case "MONTHLY":
            text = interval == 1 ? "每月" : "每 \(interval) 个月"
            if let d = dict["BYMONTHDAY"] { text += " \(d) 号" }
        case "YEARLY":
            text = interval == 1 ? "每年" : "每 \(interval) 年"
        case "HOURLY":
            text = interval == 1 ? "每小时" : "每 \(interval) 小时"
        default:
            return raw
        }

        if let c = dict["COUNT"] {
            text += "，共 \(c) 次"
        } else if let u = dict["UNTIL"] {
            text += "，到 \(friendlyUntil(u)) 为止"
        }
        return text
    }

    private static func chineseWeekday(_ token: String) -> String? {
        switch token.uppercased() {
        case "MO": return "一"
        case "TU": return "二"
        case "WE": return "三"
        case "TH": return "四"
        case "FR": return "五"
        case "SA": return "六"
        case "SU": return "日"
        default: return nil
        }
    }

    /// `20261231T235900Z` → `12月31日`
    private static func friendlyUntil(_ stamp: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let d = f.date(from: stamp) else { return stamp }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_Hans_CN")
        out.timeZone = .current
        out.dateFormat = "M月d日"
        return out.string(from: d)
    }
}
