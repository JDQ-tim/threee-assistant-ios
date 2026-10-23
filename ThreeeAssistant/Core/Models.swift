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

    /// 这一次的"原始时间"（epoch 秒）。改「只改这一次」时要用它当主键。
    ///
    /// ⚠️ 对这个字段缺失有兜底：老服务端可能不返回，这时退回 `startUTC`
    ///    —— 对没被 override 过的实例两者本来就相等，够用；
    ///    对已经被改过时间的实例则会指错，但至少不会崩。
    let occurrenceKey: Int64

    enum CodingKeys: String, CodingKey {
        case id, allDay, title, notes, location
        case eventID = "event_id"
        case calendarID = "calendar_id"
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case isTask = "is_task"
        case isOverride = "is_override"
        case occurrenceKey = "occurrence_key"
    }

    // 服务端会返回 occurrence_key，但为了兼容"万一没返回"的情况，
    // 这里手写解码给它一个兜底值，而不是让整条列表解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(String.self, forKey: .eventID)
        calendarID = try c.decode(String.self, forKey: .calendarID)
        startUTC = try c.decode(Int64.self, forKey: .startUTC)
        endUTC = try c.decode(Int64.self, forKey: .endUTC)
        allDay = try c.decode(Bool.self, forKey: .allDay)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        isTask = try c.decodeIfPresent(Bool.self, forKey: .isTask) ?? false
        isOverride = try c.decodeIfPresent(Bool.self, forKey: .isOverride) ?? false
        occurrenceKey = try c.decodeIfPresent(Int64.self, forKey: .occurrenceKey) ?? startUTC
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

// MARK: - 修改日程

/// `PUT /api/events/{id}` 的请求体。
///
/// ## 为什么每个字段都是 Optional
///
/// 服务端 `eventReq` 里全是指针（`*string` / `*int64` / `*bool`），语义是**局部合并**：
/// - 字段**没传** → 保持库里原值
/// - 字段**传了** → 改成这个值
///
/// 所以这里必须用 Optional，而且要配 `encodeIfPresent` 之外的写法：
/// 直接用默认的 `encode` 会把 nil 编成 `null`，服务端读到 `null` 指针是 nil，
/// 效果碰巧一样，但**语义不对**——`null` 和"没这个键"在别的实现里可能不同。
/// 见下方 `encode(to:)` 的实现。
struct UpdateEventBody: Encodable {
    var calendarID: String?
    var title: String?
    var notes: String?
    var location: String?
    var dtstartUTC: Int64?
    var durationSec: Int64?
    var tzid: String?

    enum CodingKeys: String, CodingKey {
        case title, notes, location, tzid
        case calendarID = "calendar_id"
        case dtstartUTC = "dtstart_utc"
        case durationSec = "duration_sec"
    }

    /// 只编码**非 nil** 的字段。nil 的字段连键都不出现，
    /// 服务端据此判断"这个字段不用动"。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(calendarID, forKey: .calendarID)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(dtstartUTC, forKey: .dtstartUTC)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(tzid, forKey: .tzid)
    }

    /// 一个字段都没改时不要发请求（服务端会正常返回，但白跑一趟）
    var isEmpty: Bool {
        calendarID == nil && title == nil && notes == nil && location == nil
            && dtstartUTC == nil && durationSec == nil && tzid == nil
    }
}

/// 只改重复日程里的**这一次**（`PUT /api/events/{id}/occurrence`）。
///
/// ## 和服务端字段对不上的地方要特别小心
///
/// 服务端存的是一条 override 补丁（`event_overrides.patch`），
/// 这个补丁**只会被打在展开出来的实例上**，所以：
///
/// 1. 时间字段叫 `dtstart_utc`（是**这一次**的绝对时间），
///    而不是 `PUT /api/events/{id}` 里那个"系列的起点"。
/// 2. 没有 `tzid`。override 是按绝对秒存的，换时区也不会漂。
/// 3. 改所属日历（`calendar_id`）在这里**做不到** —— 服务端不认这个键。
///    想换日历只能改整个系列，UI 上要把日历选择器禁掉。
struct OccurrenceBody: Encodable {
    /// 这一次原本的开始时间（epoch 秒）。服务端拿它当 event_overrides 的主键。
    ///
    /// ⚠️ 必须是**这次原本的**时间，不是改完之后的新时间。
    ///    传新时间会变成"给另一个不存在的实例写补丁"，原位置纹丝不动。
    let occurrenceKey: Int64
    let patch: UpdateEventBody

    enum CodingKeys: String, CodingKey {
        case patch
        case occurrenceKey = "occurrence_key"
    }
}

/// `PUT /api/events/{id}` 的响应。
///
/// ⚠️ 不是空对象！服务端返回 `{"event": {...}, "conflicts": [...]}`。
/// `conflicts` 是字段级合并时发现的并发冲突记录，正常情况下是空数组。
struct UpdateEventResponse: Decodable {
    let event: APIEvent?
    let conflicts: [FieldConflict]?
}

/// 并发修改冲突。两台设备同时改同一条日程时服务端会记一条，
/// 这里只用来提示用户「别人也改过」，具体合并策略服务端已经处理了。
struct FieldConflict: Decodable, Hashable {
    let field: String?
    let reason: String?
}

/// 一条**原始**日程（不是展开后的实例）。
///
/// 编辑表单要的是这个，不是 `ScheduleInstance`：实例是"某一天的一次展开"，
/// 改它会把重复日程的一次单独拎出来，语义完全不同。
struct APIEvent: Codable, Identifiable, Hashable {
    let id: String
    let calendarID: String
    let title: String
    let notes: String
    let location: String
    let allDay: Bool
    let dtstartUTC: Int64
    let durationSec: Int64
    let tzid: String
    let rrule: String
    let isTask: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, notes, location, tzid, rrule
        case calendarID = "calendar_id"
        case allDay = "all_day"
        case dtstartUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
    }

    var start: Date { Date(timeIntervalSince1970: TimeInterval(dtstartUTC)) }

    /// 是否是重复日程。有 rrule 就不能简单粗暴地改时间——
    /// 服务端会重算后续所有实例，这也是为什么改时间要二次确认。
    var isRecurring: Bool { !rrule.isEmpty }
}

/// `GET /api/events/{id}` 的响应
struct EventResponse: Decodable {
    let event: APIEvent
}


// MARK: - 界面用的分组

/// 按天分组后的一天。视图直接吃这个，不再自己算排序。
struct DayGroup: Identifiable {
    let day: Date
    let items: [ScheduleInstance]
    var id: Date { day }
}
