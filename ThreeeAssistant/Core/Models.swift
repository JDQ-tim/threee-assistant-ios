import Foundation

// ============================================================
//  服务端数据模型
//  ------------------------------------------------------------
//  字段名与 Go 服务端 `server/internal/app/models.go` 的 json tag 逐字对应。
//  改动这里必须同时看那边 —— 两边写岔不会报错，只会静默丢字段。
//
//  ⚠️ 时间一律是 **epoch 秒**，不是毫秒，也不是 Date。
//     服务端会对明显不合理的时间直接 400（见 saneStartUTC），
//     传毫秒进去表现为「开始时间不在合理范围」。
// ============================================================

struct APIUser: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isAdmin: Bool
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name
        case isAdmin = "is_admin"
        case createdAt = "created_at"
    }
}

/// 一部日历。
///
/// ⚠️ 不能叫 `Calendar` —— 会和 Foundation.Calendar 撞名，
///    撞了之后所有 `Calendar.current` 都变成这个类型，报错会出现在完全无关的文件里。
struct CalendarDTO: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let kind: String?
    let role: String?
    let ownerID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, kind, role
        case ownerID = "owner_id"
    }

    /// 服务端给的是 `#RRGGBB`，解析不出来时给一个兜底色
    var displayColor: String {
        guard let c = color, c.hasPrefix("#"), c.count >= 7 else { return "#185FA5" }
        return c
    }
}

/// 一条**展开后**的日程实例。
///
/// 重复日程在服务端会被展开成多个实例（`occurrence_key` 区分是哪一次），
/// 客户端看到的永远是「某一天的一次具体安排」。
struct ScheduleInstance: Codable, Identifiable, Hashable {
    let id: String
    let eventID: String
    let calendarID: String
    let startUTC: Int64
    let endUTC: Int64
    let allDay: Bool
    let title: String?
    let notes: String?
    let location: String?
    let isTask: Bool
    let isOverride: Bool

    enum CodingKeys: String, CodingKey {
        case id, allDay, title, notes, location
        case eventID = "event_id"
        case calendarID = "calendar_id"
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case isTask = "is_task"
        case isOverride = "is_override"
    }

    var start: Date { Date(timeIntervalSince1970: TimeInterval(startUTC)) }
    var end: Date { Date(timeIntervalSince1970: TimeInterval(endUTC)) }

    /// 任务型日程没有时长（`end_utc == start_utc`），
    /// 直接拼成「09:00 – 09:00」会让人以为时间填错了
    var hasSpan: Bool { endUTC > startUTC }
}

// MARK: - 响应包络

struct LoginResponse: Codable {
    let token: String
    let user: APIUser
}

struct CalendarsResponse: Codable {
    let calendars: [CalendarDTO]
}

struct InstancesResponse: Codable {
    let instances: [ScheduleInstance]
}

struct HealthResponse: Codable {
    let version: String?
}

// MARK: - 请求体

/// 新建日程。只带服务端认识的字段 —— `eventReq` 里其它字段都是指针类型，
/// 传了就等于「明确要设成这个值」，不传表示「不管」。
struct NewEventBody: Encodable {
    let calendarID: String
    let title: String
    let startUTC: Int64
    let durationSec: Int64
    let tzid: String

    enum CodingKeys: String, CodingKey {
        case title, tzid
        case calendarID = "calendar_id"
        case startUTC = "dtstart_utc"
        case durationSec = "duration_sec"
    }
}

struct LoginBody: Encodable {
    let name: String
    let pass: String
}

// MARK: - 界面用的分组

/// 按天分组后的一天。视图直接吃这个，不再自己算排序。
struct DayGroup: Identifiable {
    let day: Date
    let items: [ScheduleInstance]
    var id: Date { day }
}
