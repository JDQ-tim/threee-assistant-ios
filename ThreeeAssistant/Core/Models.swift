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
    let ownerName: String?
    let members: [MemberDTO]?

    enum CodingKeys: String, CodingKey {
        case id, name, color, kind, role, members
        case ownerID = "owner_id"
        case ownerName = "owner_name"
    }

    // 手写解码：members / owner_name 在列表接口里可能不下发（`omitempty`），
    // 而它们是 let 常量，没有默认值 —— 不手写的话整条日历会解析失败，
    // 表现是"登录成功但一个日历都没有"，非常难查。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        members = try c.decodeIfPresent([MemberDTO].self, forKey: .members)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(ownerID, forKey: .ownerID)
        try c.encodeIfPresent(ownerName, forKey: .ownerName)
        try c.encodeIfPresent(members, forKey: .members)
    }

    /// 服务端给的是 `#RRGGBB`，解析不出来时给一个兜底色
    var displayColor: String {
        guard let c = color, c.hasPrefix("#"), c.count >= 7 else { return "#185FA5" }
        return c
    }

    /// 我能不能改这个日历的名字 / 删掉它。
    /// 服务端：改名要 owner，改颜色 editor 就行，删除只有 owner。
    /// 这里统一按最严的 owner 判断 —— 给一个改不了名字的日历开放编辑页，
    /// 用户改完点保存才被拒，体验比一开始就不给入口差得多。
    var canManage: Bool { role == "owner" }
}

/// 日历成员。共享日历上用来展示"都有谁"。
struct MemberDTO: Codable, Hashable, Identifiable {
    let userID: String
    let name: String
    let role: String

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case name, role
        case userID = "user_id"
    }
}

/// 新建 / 修改日历的请求体。
/// 两边共用：PUT 时没传的字段保持原值（服务端是局部合并）。
struct CalendarBody: Encodable {
    var name: String?
    var color: String?
    /// ⚠️ 只允许 `private` / `shared` / `course`。
    ///    服务端对别的值**不报错，直接改成 private** —— 传错了表现是"设了没生效"。
    var kind: String?

    enum CodingKeys: String, CodingKey {
        case name, color, kind
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

    /// 待办的完成时间。nil = 未完成。非待办恒为 nil。
    let doneAt: Int64?

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
        case doneAt = "done_at"
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
        doneAt = try c.decodeIfPresent(Int64.self, forKey: .doneAt)
    }

    var start: Date { Date(timeIntervalSince1970: TimeInterval(startUTC)) }
    var end: Date { Date(timeIntervalSince1970: TimeInterval(endUTC)) }

    /// 任务型日程没有时长（`end_utc == start_utc`），
    /// 直接拼成「09:00 – 09:00」会让人以为时间填错了
    var hasSpan: Bool { endUTC > startUTC }

    /// 已完成的待办。列表里要画勾号并加删除线。
    var isDone: Bool { doneAt != nil }

    /// 手写 init(from:) 后需要补 encode(to:) 才是完整 Codable。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(calendarID, forKey: .calendarID)
        try c.encode(startUTC, forKey: .startUTC)
        try c.encode(endUTC, forKey: .endUTC)
        try c.encode(allDay, forKey: .allDay)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(isTask, forKey: .isTask)
        try c.encode(isOverride, forKey: .isOverride)
        try c.encode(occurrenceKey, forKey: .occurrenceKey)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
    }
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
/// 一条提醒。
///
/// ⚠️ 字段名是 `minutes_before`（**分钟**），不是 API 文档里写的 `offset_sec`（秒）。
///    文档和实际代码不一致，这里以 `server/internal/app/models.go` 的
///    `Reminder` 结构为准。写成 offset_sec 不会报错，只会静默失效 ——
///    服务端读不到 minutes_before 就当成 0，等于"准点提醒"。
struct ReminderDTO: Codable, Hashable, Identifiable {
    let id: String?
    let minutesBefore: Int64
    let channel: String

    enum CodingKeys: String, CodingKey {
        case id, channel
        case minutesBefore = "minutes_before"
    }

    init(id: String? = nil, minutesBefore: Int64, channel: String = "notify") {
        self.id = id
        self.minutesBefore = minutesBefore
        self.channel = channel
    }
}

/// 新建日程的请求体。
struct NewEventBody: Encodable {
    let calendarID: String
    let title: String
    let notes: String
    let location: String
    let startUTC: Int64
    let durationSec: Int64
    let tzid: String
    /// 空字符串 = 不重复。服务端按 `rrule == ""` 判单次。
    let rrule: String
    let isTask: Bool
    let reminders: [ReminderDTO]

    enum CodingKeys: String, CodingKey {
        case title, notes, location, tzid, rrule, reminders
        case calendarID = "calendar_id"
        case startUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
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
    /// 传空字符串表示"取消重复"，转成单次日程。服务端按 `rrule == ""` 判单次。
    var rrule: String?
    var reminders: [ReminderDTO]?
    var isTask: Bool?
    /// 待办完成时间。发 0 表示"取消完成"（不是 nil —— nil 表示这个字段不改）。
    var doneAt: Int64?

    enum CodingKeys: String, CodingKey {
        case title, notes, location, tzid, rrule, reminders
        case calendarID = "calendar_id"
        case dtstartUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
        case doneAt = "done_at"
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
        try c.encodeIfPresent(rrule, forKey: .rrule)
        try c.encodeIfPresent(reminders, forKey: .reminders)
        try c.encodeIfPresent(isTask, forKey: .isTask)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
    }

    /// 一个字段都没改时不要发请求（服务端会正常返回，但白跑一趟）
    var isEmpty: Bool {
        calendarID == nil && title == nil && notes == nil && location == nil
            && dtstartUTC == nil && durationSec == nil && tzid == nil
            && rrule == nil && reminders == nil && isTask == nil && doneAt == nil
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
    let doneAt: Int64?
    let reminders: [ReminderDTO]
    /// 我自己对这条开的强提醒。**是按调用者过滤过的值**，不是共享字段。
    let strong: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, notes, location, tzid, rrule, reminders, strong
        case calendarID = "calendar_id"
        case allDay = "all_day"
        case dtstartUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
        case doneAt = "done_at"
    }

    // 手写解码只为给 reminders / strong 兜底。
    //
    // ⚠️ 服务端**明确不加 omitempty**：`reminders: []` 表示"这条不提醒我"，
    //    和"字段没下发"是两件不同的事。所以缺失时必须当成空数组，
    //    不能退回成"默认提前 15 分钟"——那会让用户在设置里关掉提醒后，
    //    下次打开又自己长回来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        calendarID = try c.decode(String.self, forKey: .calendarID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        dtstartUTC = try c.decode(Int64.self, forKey: .dtstartUTC)
        durationSec = try c.decodeIfPresent(Int64.self, forKey: .durationSec) ?? 0
        tzid = try c.decodeIfPresent(String.self, forKey: .tzid) ?? "Asia/Shanghai"
        rrule = try c.decodeIfPresent(String.self, forKey: .rrule) ?? ""
        isTask = try c.decodeIfPresent(Bool.self, forKey: .isTask) ?? false
        doneAt = try c.decodeIfPresent(Int64.self, forKey: .doneAt)
        reminders = try c.decodeIfPresent([ReminderDTO].self, forKey: .reminders) ?? []
        strong = try c.decodeIfPresent(Bool.self, forKey: .strong) ?? false
    }

    var start: Date { Date(timeIntervalSince1970: TimeInterval(dtstartUTC)) }

    /// 是否是重复日程。有 rrule 就不能简单粗暴地改时间——
    /// 服务端会重算后续所有实例，这也是为什么改时间要二次确认。
    var isRecurring: Bool { !rrule.isEmpty }

    /// 手写 init(from:) 之后编译器不再自动合成 encode(to:)，
    /// 而 Codable 要求两个都有。这里补齐——目前只有缓存会用到。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(calendarID, forKey: .calendarID)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(location, forKey: .location)
        try c.encode(allDay, forKey: .allDay)
        try c.encode(dtstartUTC, forKey: .dtstartUTC)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(tzid, forKey: .tzid)
        try c.encode(rrule, forKey: .rrule)
        try c.encode(isTask, forKey: .isTask)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
        try c.encode(reminders, forKey: .reminders)
        try c.encode(strong, forKey: .strong)
    }
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
