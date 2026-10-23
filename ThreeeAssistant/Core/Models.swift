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
    /// 全天日程。
    ///
    /// ⚠️ 服务端这里用的不是指针而是 `boolToInt(req.AllDay != nil && *req.AllDay)`，
    ///    所以**不传 = false**，是安全的。但既然这里是非可选 `Bool`，
    ///    永远会被编出来，行为也一致。
    ///
    /// ⚠️ 全天日程的 `duration_sec` 服务端按"整天"理解，但存的是秒。
    ///    传 0 也能建出来（表现是「全天但时长为零」），
    ///    稳妥做法是传 86400（见 `SessionStore.createEvent`）。
    let allDay: Bool
    let reminders: [ReminderDTO]
    /// 强提醒。
    ///
    /// ⚠️ 这个字段**不在**服务端 `incomingMap` 里 —— 它不是共享字段，
    ///    而是按 (event_id, user_id) 单独存进 `strong_reminders` 表的。
    ///    同一张共享日历上，你能开强提醒而我不用开。
    ///
    /// ⚠️ POST 和 PUT 两条路径都要写（`event.go:292` / `event.go:423`）。
    ///    只加 POST 会表现成「新建时能设、之后改不了」。
    let strong: Bool

    enum CodingKeys: String, CodingKey {
        case title, notes, location, tzid, rrule, reminders, strong
        case calendarID = "calendar_id"
        case startUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
        case allDay = "all_day"
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
    /// 改成 / 改回全天日程。
    ///
    /// ⚠️ `all_day` **在**服务端 `incomingMap` 里（是共享字段，参与字段级合并），
    ///    但 `overridePatch` 也认它 —— 所以「只改这一次」也能切全天。
    var allDay: Bool?
    /// 我自己的强提醒开关。
    ///
    /// ⚠️ 这里必须存在，否则就是源码注释里警告的那个坑：
    ///    「只加 POST 的话会表现成『新建时能设、之后改不了』
    ///      —— 用户点开关保存后没反应，且不报错」。
    var strong: Bool?

    enum CodingKeys: String, CodingKey {
        case title, notes, location, tzid, rrule, reminders, strong
        case calendarID = "calendar_id"
        case dtstartUTC = "dtstart_utc"
        case durationSec = "duration_sec"
        case isTask = "is_task"
        case doneAt = "done_at"
        case allDay = "all_day"
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
        try c.encodeIfPresent(allDay, forKey: .allDay)
        try c.encodeIfPresent(strong, forKey: .strong)
    }

    /// 一个字段都没改时不要发请求（服务端会正常返回，但白跑一趟）。
    ///
    /// ⚠️ 加了新字段一定要同步加到这里，否则「只改了全天」或「只改了强提醒」
    ///    会被判成空补丁 —— 表现是保存按钮一直是灰的，用户以为界面卡了。
    var isEmpty: Bool {
        calendarID == nil && title == nil && notes == nil && location == nil
            && dtstartUTC == nil && durationSec == nil && tzid == nil
            && rrule == nil && reminders == nil && isTask == nil && doneAt == nil
            && allDay == nil && strong == nil
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

/// `POST /api/events/{id}/snooze` 的请求体。
///
/// ## 为什么要存到服务端而不是只改本地闹钟
///
/// 源码注释（`event.go:668`）写得很直白：
/// 「if it stayed local, snoozing on the phone would still let the desktop ring」
/// —— 手机上点了「稍后提醒」，如果只改本地，电脑还会按原时间响。
/// 所以服务端专门有 `snoozes` 表，按 (event_id, occurrence_key, user_id) 存。
///
/// ## 一个硬约束
///
/// `minutes <= 0` 服务端直接 400（`if err := readJSON(...); err != nil || req.Minutes <= 0`）。
/// 所以「取消稍后提醒」不能靠传 0 分钟，必须调 `DELETE /api/events/{id}/snooze`。
struct SnoozeBody: Encodable {
    /// 这一次原本的开始时间（epoch 秒）。
    /// 单次日程也要传 —— 服务端会原样存，不校验它是否真的是一次展开。
    let occurrenceKey: Int64
    /// 延后多少分钟。必须 > 0。
    let minutes: Int64
    /// 哪台设备发起的。服务端只记录、不据此过滤，但排查"哪台设备没响"时有用。
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case minutes
        case occurrenceKey = "occurrence_key"
        case deviceID = "device_id"
    }
}

/// `POST /api/events/{id}/snooze` 的响应：`{"ok":true,"remind_at_utc":<epoch秒>}`。
///
/// 服务端**回传算好的提醒时刻**，客户端应该用这个值而不是自己 `now + minutes*60`：
/// 两端的时钟可能差几十秒，而闹钟差几十秒就是「明明设了却提前响了」。
struct SnoozeResponse: Decodable {
    let remindAtUTC: Int64?

    enum CodingKeys: String, CodingKey {
        case remindAtUTC = "remind_at_utc"
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

// MARK: - 冲突（完整形态）

/// `GET /api/conflicts` 里的一条冲突。
///
/// ## ⚠️ 服务端不会把别人的冲突推给你，但**表里是全放一起的**
///
/// `conflicts` 表只有 `entity_id`，没有 `user_id`（见 `sync.go:1206` 的 SQL）。
/// 所以 `conflictsFor` 会逐条回查所属日历的权限再过滤 —— 这个过滤
/// **只在服务端做**。客户端拿到什么就显示什么，不要自己缓存后
/// 换个账号还继续显示（登出时 `SessionStore` 会清空这些）。
///
/// ## `server_value` / `client_value` 是什么形态
///
/// 服务端存的是 **JSON 片段**，不是原始字符串。比如字段 `title` 的
/// server_value 是 `"\"高数\""`（带引号），`duration_sec` 是 `3600`。
/// 解析时 `JSONDecoder` 能直接吃掉这层包装，但要按字段类型区分对待 ——
/// 见 `displayValue(_:)`。
struct ConflictDTO: Decodable, Identifiable, Hashable {
    let id: String
    /// `"event"` 或 `"calendar"`
    let entity: String
    let entityID: String
    /// 出冲突的**单个字段名**，和 API 的 json tag 一致（`title` / `notes` …）
    let field: String
    let baseSeq: Int64
    let serverValue: String?
    let clientValue: String?
    let clientDevice: String
    let createdAt: Int64
    let resolvedAt: Int64?
    let resolution: String?

    enum CodingKeys: String, CodingKey {
        case id, entity, field, resolution
        case entityID = "entity_id"
        case baseSeq = "base_seq"
        case serverValue = "server_value"
        case clientValue = "client_value"
        case clientDevice = "client_device"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    var isResolved: Bool { resolvedAt != nil }
}

struct ConflictsResponse: Decodable {
    let conflicts: [ConflictDTO]
}

/// `POST /api/conflicts/{id}/resolve` 的请求体。
///
/// ## 三个取值，服务端只认这三个
///
/// - `keep_mine`   —— 用我的版本覆盖
/// - `keep_server` —— 保留服务端的，什么都不写
/// - `keep_both`   —— **复制一条日程**，把两个版本都留下来
///
/// 源码注释（`sync.go:1280`）特意解释了为什么 `keep_both` 是一等公民：
/// 「blindly picking a winner loses data in the common family case of
///   two people booking the same slot」——
/// 一家两口都不小心订了同一时段，二选一必然丢一个人的记录。
struct ResolveConflictBody: Encodable {
    let resolution: String

    static let keepMine = "keep_mine"
    static let keepServer = "keep_server"
    static let keepBoth = "keep_both"

    static func valid(_ s: String) -> Bool {
        s == keepMine || s == keepServer || s == keepBoth
    }
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


// MARK: - 课程表

/// 一节课的「钟点」。
///
/// ## 课表不是一种新实体
///
/// 源码 `course.go:11` 开头就写明了：
/// 「A timetable is not a new entity: it is an ordinary calendar whose kind is
///   "course", rendered as a periods x weekdays grid instead of an agenda.」
///
/// 所以课表就是 `kind == "course"` 的普通日历，日程数据完全复用
/// `ScheduleInstance`。**唯一新增的状态是这张节次表** ——
/// 它决定网格有哪几行、每行对应几点。
struct CoursePeriod: Codable, Identifiable, Hashable {
    /// 从 1 开始。服务端按它排序，也是网格的行号。
    let index: Int
    /// 显示名，比如「第1节」。服务端在 label 为空时会自动补成这个格式。
    let label: String
    /// `HH:MM`，**不是** epoch 秒。服务端用 `time.Parse("15:04", ...)` 校验，
    /// 格式不对直接 400，而且要求 `start < end`（按字符串比较，所以必须补零）。
    let start: String
    let end: String

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, label, start, end
    }

    init(index: Int, label: String, start: String, end: String) {
        self.index = index
        self.label = label
        self.start = start
        self.end = end
    }

    // label 可能缺失（服务端在返回老数据时不会补），给个兜底
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? "00:00"
        end = try c.decodeIfPresent(String.self, forKey: .end) ?? "00:00"
        label = try c.decodeIfPresent(String.self, forKey: .label)
            ?? "第\(index)节"
    }
}

struct CoursePeriodsResponse: Decodable {
    let periods: [CoursePeriod]
}

/// `PUT /api/course/periods` 的请求体。
///
/// ## ⚠️ 这是全局配置，不是个人设置
///
/// 节次表存在服务端 `app_settings` 里，**所有客户端共享**。
/// 而且 2026-10-16 起这条接口要求 **admin**（`routes.go:442` 只包了 `s.auth`，
/// 但 handler 内部第一行就是 `s.requireAdmin`）。
/// 所以普通用户点保存会拿到 403 —— UI 上必须对非管理员禁掉编辑入口，
/// 而不是让他改完才被拒。
struct CoursePeriodsBody: Encodable {
    let periods: [CoursePeriod]
}

/// 服务端默认的节次表（10 节，上午四节、下午四节、晚上两节）。
///
/// 客户端**保留一份副本是有意义的**：拉取失败时用它兜底渲染网格，
/// 总比让用户看到一个空白课表好。但要和服务端 `defaultCoursePeriods()` 保持一致 ——
/// 这边改了那边没改，首次登录的两个客户端会显示出不同的行布局。
enum CourseDefaults {
    static let periods: [CoursePeriod] = [
        CoursePeriod(index: 1, label: "第1节", start: "08:00", end: "08:45"),
        CoursePeriod(index: 2, label: "第2节", start: "08:55", end: "09:40"),
        CoursePeriod(index: 3, label: "第3节", start: "10:00", end: "10:45"),
        CoursePeriod(index: 4, label: "第4节", start: "10:55", end: "11:40"),
        CoursePeriod(index: 5, label: "第5节", start: "14:30", end: "15:15"),
        CoursePeriod(index: 6, label: "第6节", start: "15:25", end: "16:10"),
        CoursePeriod(index: 7, label: "第7节", start: "16:30", end: "17:15"),
        CoursePeriod(index: 8, label: "第8节", start: "17:25", end: "18:10"),
        CoursePeriod(index: 9, label: "第9节", start: "19:30", end: "20:15"),
        CoursePeriod(index: 10, label: "第10节", start: "20:25", end: "21:10")
    ]
}

// MARK: - 界面用的分组

/// 按天分组后的一天。视图直接吃这个，不再自己算排序。
struct DayGroup: Identifiable {
    let day: Date
    let items: [ScheduleInstance]
    var id: Date { day }
}
