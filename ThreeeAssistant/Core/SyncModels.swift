import Foundation

// ============================================================
//  离线同步
//  ------------------------------------------------------------
//  服务端有三个接口（`sync.go`），这是一个最小的客户端实现：
//
//      GET  /api/sync/changes?since=<seq>   增量拉（带 maintenance 信号）
//      POST /api/sync/push                 批量推（字段级合并）
//
//  ## 为什么不直接用 refresh() 覆盖
//
//  现在的 `SessionStore.refresh()` 是「拉一份最新的，替换本地」。
//  在单设备上没问题，但它**没法把本机的离线改动送上去** ——
//  用户在地铁里改了标题，回到有网的地方只会被服务端那份覆盖掉。
//
//  ## 这个引擎负责什么，不负责什么
//
//  负责：
//    - 把本地攒下的操作按批推上去（每批 <= 500 条，服务端上限）
//    - 把服务端的 `conflicts` / `errors` 原样交回去给界面对话
//    - 记住 `last_seq` 游标，下次接着拉
//    - 收到 `maintenance: true` 就丢掉游标（下一轮做全量）
//
//  不负责：
//    - 本地数据库（这个 App 目前是「进页面就 refresh」的模型，没有离线库）
//    - 冲突的自动解决（服务端把双方的值都留着，人自己选）
//
//  ## 三个容易踩的点（都写在源码注释里）
//
//  1. **每条 op 必须带 `field_base_seqs`**。省略它 = 「无条件覆盖服务端」，
//     而且**不产生冲突记录**。push 路由专门检查这个键，缺了直接报
//     `missing field_base_seqs`。（2026-10-16 审计 M1）
//  2. **一次 push 上限 500 条**。超了 400，整批都不执行。
//     而且**每用户每分钟最多 60 次 push** —— 超了 429。
//  3. **`errors` 里的 banned_word 不是权限问题**。服务端特意和 `forbidden`
//     分开报，因为混在一起用户会去翻权限设置，永远找不到真正的原因。
// ============================================================

/// 一条要推上去的操作。
///
/// `data` 只放**改动了的那几个字段**，不是整条实体。
/// 这是字段级合并的前提：只报「我改了标题」，服务端才能判断
/// 「别人改的是时间、不冲突，两个都留下」。
struct SyncOp: Codable {
    /// `calendar` / `event` / `inbox` / `snooze`
    let entity: String
    /// `upsert` / `delete`
    let op: String
    let id: String
    let data: [String: JSONValue]
    /// ⚠️ **不能为 nil**。见文件头第 1 点。
    let baseSeqs: [String: Int64]
    let deviceID: String?

    enum CodingKeys: String, CodingKey {
        case entity, op, id, data
        case baseSeqs = "field_base_seqs"
        case deviceID = "device_id"
    }

    init(
        entity: String,
        op: String,
        id: String,
        data: [String: JSONValue] = [:],
        baseSeqs: [String: Int64] = [:],
        deviceID: String? = nil
    ) {
        self.entity = entity
        self.op = op
        self.id = id
        self.data = data
        self.baseSeqs = baseSeqs
        self.deviceID = deviceID
    }
}

/// 一个可以编进 JSON 的值。
///
/// 为什么不直接用 `Any`：`Any` 不是 `Encodable`，`JSONEncoder` 编不了。
/// 而同步这边必须能编出「`all_day` 是布尔、`dtstart_utc` 是数字、
/// `title` 是字符串」这种混合体 —— 服务端的字段类型表是严格的
/// （`models.go` 的 `eventFieldKinds`），类型发错会被跳过，
/// 表现成「推成功了但什么都没改」。
enum JSONValue: Codable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case double(Double)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "不是可识别的 JSON 标量"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .double(let d): try c.encode(d)
        case .null: try c.encodeNil()
        }
    }
}

struct SyncPushRequest: Codable {
    let deviceID: String
    let ops: [SyncOp]

    enum CodingKeys: String, CodingKey {
        case ops
        case deviceID = "device_id"
    }
}

/// push 的响应。
///
/// `applied` 只说「哪几个字段写进去了」，不和请求逐条对齐 ——
/// 服务端是按字段粒度回报的，一条 op 可能只写进去一部分。
struct SyncPushResponse: Decodable {
    let applied: [AppliedOp]
    let conflicts: [ConflictDTO]
    /// 人能看懂的逐条错误（`entity id: 原因`）
    let errors: [String]
    let seq: Int64?

    struct AppliedOp: Decodable {
        let entity: String
        let id: String
        let fields: [String]?
    }
}

/// changes / snapshot 的响应。两者结构相同，只差 `maintenance` 字段。
struct SyncChangesResponse: Decodable {
    let calendars: [CalendarDTO]?
    let events: [APIEvent]?
    let instances: [ScheduleInstance]?
    let lastSeq: Int64?
    let hasMore: Bool?
    /// true = 服务端做过整库修复，客户端必须丢掉游标重拉。
    ///
    /// 源码（`sync.go:305`）：「原来只是往 sync_log 里写一条 entity='maintenance'
    /// 的记录，指望客户端『看到不认识的 entity 就整份重拉』—— 但 loadEntities
    /// 的 switch 根本不认识它 …… 客户端只看到 last_seq 往前走了一点点，
    /// **永远不知道库被修过**。」所以现在显式下发这个布尔。
    let maintenance: Bool?

    enum CodingKeys: String, CodingKey {
        case calendars, events, instances, maintenance
        case lastSeq = "last_seq"
        case hasMore = "has_more"
    }
}

/// 一次 push 的汇总结果。
///
/// 三个列表**都要给用户看**，不能只看 applied：
/// - `errors`  里可能是「标题含违规词」—— 服务端特意和「没权限」分开报，
///              因为它俩的下一步动作完全不同（去改内容 vs 去查权限）
/// - `conflicts` 里是「你和别人改了同一个字段」，服务端两边都留了值，
///              要人去冲突中心选一个
/// - `applied` 只说明哪几个字段写进去了，**不说明整条成功**
struct SyncPushOutcome {
    var applied: [String] = []
    var conflicts: [ConflictDTO] = []
    var errors: [String] = []
    var serverSeq: Int64?

    var hasTrouble: Bool { !errors.isEmpty || !conflicts.isEmpty }
}

/// 一次增量拉的结果。
struct SyncPullOutcome {
    var calendars: [CalendarDTO] = []
    var events: [APIEvent] = []
    /// 服务端做过整库修复 → 本地游标已作废，下一轮做全量。
    var maintenance = false
    /// 一次没拉完，还有更多。
    var hasMore = false

    /// 什么都没拉到。用来决定要不要给用户提示。
    var isEmpty: Bool { calendars.isEmpty && events.isEmpty && !maintenance }
}

