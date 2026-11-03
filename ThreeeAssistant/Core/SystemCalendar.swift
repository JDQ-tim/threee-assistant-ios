import Foundation
import EventKit
import UIKit

// ============================================================
//  系统日历（EventKit）
//  ------------------------------------------------------------
//  把 3e 的日程和 iOS「日历」App 打通，两个方向：
//
//   导入：系统日历里的课表 → 3e 的一张新日历
//   导出：学习助手的日程 → 系统日历里的一张「学习助手」日历
//
//  ## 为什么必须双向，而不是只做一边
//
//  只导出：用户在系统日历里删掉一条，3e 里还在，
//          下次同步又长回来 —— 用户会觉得"删不掉"。
//  只导入：用户在 3e 里排了课，锁屏、灵动岛、手表、Mac 上全都看不见，
//          而这恰恰是他想要日历 App 的原因。
//
//  ## 三条硬约束
//
//  1. **绝不自动改写系统里别人建的日历。**
//     写回只写到我们自己建的那张（`ekCalendar` 里带标记的那一张）。
//     用户在 iCloud「家庭」日历里的事件，我们一根手指都不碰。
//
//  2. **导入是"复制"，不是"订阅"。**
//     EventKit 没有真正的订阅 API（那是 `.ics` URL 的事，且 iOS 不让
//     第三方 App 建订阅日历）。所以导入的语义是：把这一刻看到的系统事件
//     复制成 3e 的普通日程，之后两边各自独立。
//     这个语义**必须写在界面上**，否则用户以为是同步，
//     在系统日历里改了个时间却发现 3e 没变。
//
//  3. **去重靠 `externalIdentifier`，不靠标题+时间。**
//     同名同时间的两个事件是合法的（两个班在同一间教室）。
//     拿标题当 key 会把它们合成一条，而且删一条会连带删另一条。
// ============================================================

/// 授权状态。**故意不用 `EKAuthorizationStatus`**：
///
/// - iOS 17 把「只写」和「完全访问」拆成两档，枚举多了两个 case；
/// - 我们只关心三件事：能不能读、能不能写、还没问过。
///
/// 直接在视图里 switch `EKAuthorizationStatus` 会让每个调用点都得写
/// `@unknown default`，而且将来 iOS 再拆分档位时要改很多地方。
enum SystemCalendarAccess: Equatable {
    case notDetermined
    /// 只拿到写权限：可以往系统日历里写，但读不到已有的。
    case canWriteOnly
    /// 完全访问：读写都可以。
    case full
    /// 被拒绝，或受家长控制限制。
    case denied

    var canRead: Bool { self == .full }
    var canWrite: Bool { self == .full || self == .canWriteOnly }
}

/// 系统日历里的一张日历（对应 EventKit 的 `EKCalendar`）。
///
/// 只保留 UI 需要的字段，不把 `EKCalendar` 直接漏到视图层 ——
/// 那是引用对象，生命周期由 `EKEventStore` 管，视图持有它会很难判断失效。
struct SystemCalendarInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    /// 只读日历（订阅的节假日、别人共享给你的），写进去会失败。
    let isReadOnly: Bool
    /// 这张日历是不是我们自己建的。
    let isOurs: Bool
}

/// 导入 / 导出的结果。**不要只返回一个 Bool** ——
/// "导了 0 条"和"导失败了"对用户是两件完全不同的事。
struct SystemCalendarSyncResult {
    var created = 0
    var updated = 0
    var skipped = 0
    var failed = 0
    /// 失败原因，逐条给人看。截到前 5 条，够定位问题。
    var errors: [String] = []

    var summary: String {
        var parts: [String] = []
        if created > 0 { parts.append("新增 \(created)") }
        if updated > 0 { parts.append("更新 \(updated)") }
        if skipped > 0 { parts.append("跳过 \(skipped)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        return parts.isEmpty ? "没有需要处理的内容" : parts.joined(separator: " · ")
    }
}

/// EventKit 的封装。**所有 EventKit 调用都必须在主线程** ——
/// `EKEventStore` 不是线程安全的，跨线程用会偶发崩溃，而且崩在系统库里。
///
/// 授权请求是 async 的，但 `requestFullAccessToEvents` 的回调不保证在主线程，
/// 所以这里显式 `@MainActor` 整个类，让 await 之后自动回到主线程。
@MainActor
final class SystemCalendar {

    static let shared = SystemCalendar()

    private let store = EKEventStore()

    /// 我们建的系统日历的标题。用户能在系统日历里看到这个名字。
    static let oursTitle = "学习助手"

    /// 认「哪张日历是我们建的」。
    ///
    /// ⚠️ **旧名字必须留着**，不能因为改名就删掉。
    ///    2026-11-03 之前 App 叫「3e学习助手」，那时候导出过的用户，
    ///    系统日历里已经有一张叫「3e学习助手」的日历。
    ///    只认新名字的话，那些人下次导出会**再建一张新的**，
    ///    于是系统日历里出现两张几乎一样的日历，而旧的那张里
    ///    还留着他们之前导的全部日程 —— 这不是"少了一次更新"，
    ///    是"凭空多出一份重复数据"，很难自己清干净。
    ///
    /// ⚠️ 改名后也不要把它从列表里去掉，除非确定没人用过旧版本。
    private static let legacyTitles = ["学习助手", "3e学习助手", "3e"]

    private init() {}

    // MARK: - 授权

    /// 当前授权状态。
    ///
    /// ⚠️ 必须是 `nonisolated static func`，**不能是 `static var`**：
    ///    `nonisolated` 只能标在方法或存储属性上，
    ///    标在计算属性上编译器会报 `'nonisolated' can not be applied to
    ///    stored properties`（它把 var 当存储属性读），连带三条语法错误。
    ///    这是 2026-11-03 CI 抓出来的，本地粗检看不出来。
    ///
    /// ⚠️ 写成函数而不是实例属性还有一个原因：它会被 `ProfileView`
    ///    的副标题在一堆 `@MainActor` 上下文里同步调用。
    ///    放在实例上会逼所有调用点先 await 到主线程，白白多一层。
    ///
    /// ⚠️ 没有 `.authorized` 分支：iOS 17 起它和 `.fullAccess` 的
    ///    rawValue 相同，两个 case 都写会得到 duplicate case 警告。
    ///    老系统上 `.authorized` 的值会自动落进 `.fullAccess` —— 这是
    ///    Apple 保证的向前兼容，不是我们靠猜。
    nonisolated static func access() -> SystemCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .full
        case .writeOnly:
            return .canWriteOnly
        case .denied, .restricted:
            return .denied
        @unknown default:
            // 将来若再加档位，按"什么都没拿到"处理 —— 宁可提示去设置，
            // 也不要乐观地发请求然后每个调用点都失败。
            return .denied
        }
    }

    /// 申请完全访问（读写都要）。已经决定过就不再弹框。
    @discardableResult
    func requestAccess() async -> SystemCalendarAccess {
        let before = Self.access()
        guard before == .notDetermined else { return before }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // 用户点"不允许"时这里也会走到。不记错误，交给 access() 如实汇报。
        }
        return Self.access()
    }

    // MARK: - 读

    /// 系统里所有可以写事件的日历。只读日历也列出来，但标上 `isReadOnly`。
    func listCalendars() -> [SystemCalendarInfo] {
        guard Self.access().canRead else { return [] }
        return store.calendars(for: .event)
            .map { c in
                SystemCalendarInfo(
                    id: c.calendarIdentifier,
                    title: c.title,
                    sourceTitle: c.source?.title ?? "",
                    isReadOnly: !c.allowsContentModifications,
                    isOurs: Self.legacyTitles.contains(c.title)
                )
            }
            .sorted { a, b in
                if a.isOurs != b.isOurs { return a.isOurs }
                if a.sourceTitle != b.sourceTitle { return a.sourceTitle < b.sourceTitle }
                return a.title < b.title
            }
    }

    /// 找出我们建的那张日历。没有就返回 nil（**不自动创建** ——
    /// 创建要写在用户明确点了"导出"之后，不能在读的时候偷偷建东西）。
    func ourCalendar() -> EKCalendar? {
        guard Self.access().canRead else { return nil }
        return store.calendars(for: .event).first {
            Self.legacyTitles.contains($0.title) && $0.allowsContentModifications
        }
    }

    /// 读某个时间窗内的系统事件。用于导入预览。
    ///
    /// - Parameters:
    ///   - from/to: 闭区间
    ///   - calendarIDs: 为空 = 所有日历
    func fetchEvents(from: Date, to: Date, calendarIDs: [String] = []) -> [EKEvent] {
        guard Self.access().canRead else { return [] }
        let all = store.calendars(for: .event)
        let picked = calendarIDs.isEmpty
            ? all
            : all.filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !picked.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: picked)
        return store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - 写

    /// 拿到（必要时创建）我们那张系统日历。
    func ensureOurCalendar() throws -> EKCalendar {
        if let c = ourCalendar() {
            // 旧版本建的日历还叫旧名字 —— 就地改名，**不要另建一张**。
            //
            // 改名而不是新建的分界线很清楚：
            //   改名 = 那张日历里已有的日程原样保留，用户看不到任何多余的东西；
            //   新建 = 旧日历连同里面几百条日程留在那儿，系统日历里出现两份。
            //
            // 保存失败也不阻断流程：名字没改成的代价是"看起来还叫旧名"，
            // 而抛错会让整次导出失败，那更糟。
            if c.title != Self.oursTitle {
                c.title = Self.oursTitle
                try? store.saveCalendar(c, commit: true)
            }
            return c
        }

        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = Self.oursTitle

        // 默认日历的 source 就是用户主账号（iCloud 或本机）。
        // 直接用 `defaultCalendarForNewEvents?.source` 是最稳的 ——
        // 自己拼 source（比如找 `source.sourceType == .calDAV`）在
        // 只开了 Exchange 的账号上会找不到，然后整条链路失败。
        guard let source = store.defaultCalendarForNewEvents?.source else {
            throw SystemCalendarError.noWritableSource
        }
        cal.source = source
        // 给一个稳定的颜色，用户一眼能认出这是学习助手写的
        cal.cgColor = UIColor(red: 0.06, green: 0.43, blue: 0.34, alpha: 1).cgColor

        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// 把一条 3e 日程写进系统日历。已存在则更新（按 `eventIdentifier`）。
    ///
    /// - Returns: 系统事件的 `eventIdentifier`，调用方存起来下次用。
    @discardableResult
    func upsert(
        ekIdentifier: String?,
        in calendar: EKCalendar,
        title: String,
        start: Date,
        end: Date,
        allDay: Bool,
        notes: String,
        location: String
    ) throws -> String {
        // 已经存在的那条：先按 identifier 找，找不到就用新的。
        //
        // ⚠️ `event(withIdentifier:)` 对**别的日历**里的事件也能返回，
        //    所以必须再判一次它在不在我们这张日历里 —— 否则用户在
        //    iCloud 日历里手动搬过去的条目会被我们改回去。
        var ev: EKEvent?
        if let id = ekIdentifier, let found = store.event(withIdentifier: id),
           found.calendar?.calendarIdentifier == calendar.calendarIdentifier {
            ev = found
        }

        let target = ev ?? EKEvent(eventStore: store)
        target.calendar = calendar
        target.title = title
        target.startDate = start
        target.endDate = max(end, start.addingTimeInterval(60))
        target.isAllDay = allDay
        target.notes = notes.isEmpty ? nil : notes
        target.location = location.isEmpty ? nil : location

        try store.save(target, span: .thisEvent, commit: true)
        return target.eventIdentifier
    }

    /// 删掉一条我们写进系统日历的事件。找不到就静默跳过（用户可能已在系统里删了）。
    func delete(ekIdentifier: String) {
        guard let ev = store.event(withIdentifier: ekIdentifier) else { return }
        try? store.remove(ev, span: .thisEvent, commit: true)
    }

    /// 清空我们那张日历里的**全部**事件（只清我们建的这张）。
    func purgeOurCalendar() throws -> Int {
        guard let cal = ourCalendar() else { return 0 }
        let pred = store.predicateForEvents(
            withStart: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 4_102_444_800),  // 2100-01-01
            calendars: [cal]
        )
        let events = store.events(matching: pred)
        for ev in events {
            try? store.remove(ev, span: .thisEvent, commit: false)
        }
        try store.commit()
        return events.count
    }
}

enum SystemCalendarError: LocalizedError {
    case noWritableSource
    case noAccess
    case noOurCalendar

    var errorDescription: String? {
        switch self {
        case .noWritableSource:
            return "系统里没有可写的日历账号。请先在「设置 → 日历 → 账户」里登录 iCloud 或开启「本机日历」。"
        case .noAccess:
            return "没有日历访问权限。请在「设置 → 学习助手 → 日历」里打开。"
        case .noOurCalendar:
            return "还没有创建「\(SystemCalendar.oursTitle)」日历。先点一次「导出到系统日历」。"
        }
    }
}

// MARK: - 已导入记录的持久化

/// 记住"哪些系统事件已经导入过、对应 3e 的哪条日程"。
///
/// 没有这张表就没有幂等：点两次「导入」会得到两份重复的课程。
///
/// 用 `UserDefaults` 而不是文件：数据量小（一学期几百条），
/// 且丢了的后果只是"下次导入会重复"，不值得为它单开一个文件。
@MainActor
final class ImportedEventMap {

    static let shared = ImportedEventMap()

    /// key = 系统事件的 `eventIdentifier`，value = 3e 的 event id
    private var map: [String: String] = [:]
    private let key = "systemCalendar.imported.v1"

    private init() { load() }

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        map = raw
    }

    private func persist() {
        UserDefaults.standard.set(map, forKey: key)
    }

    func threeeID(for ekID: String) -> String? { map[ekID] }

    func remember(ekID: String, threeeID: String) {
        map[ekID] = threeeID
        persist()
    }

    func forget(ekID: String) {
        map.removeValue(forKey: ekID)
        persist()
    }

    var count: Int { map.count }

    func clear() {
        map.removeAll()
        persist()
    }
}

// MARK: - 导出映射的持久化

/// 记住"3e 的哪条日程写进了系统日历的哪个事件"。
///
/// 和 `ImportedEventMap` 方向相反，不能合并：同一条 3e 日程可能既是
/// 从系统导入的、又被导出回系统（用户自己配的日历），两张表各自独立才不打架。
@MainActor
final class ExportedEventMap {

    static let shared = ExportedEventMap()

    /// key = 3e event id（重复日程用 `eventID#occurrenceKey`），value = EKEvent identifier
    private var map: [String: String] = [:]
    private let key = "systemCalendar.exported.v1"

    private init() { load() }

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        map = raw
    }

    private func persist() {
        UserDefaults.standard.set(map, forKey: key)
    }

    static func mapKey(eventID: String, occurrenceKey: Int64) -> String {
        "\(eventID)#\(occurrenceKey)"
    }

    func ekID(for mapKey: String) -> String? { map[mapKey] }

    func remember(mapKey: String, ekID: String) {
        map[mapKey] = ekID
        persist()
    }

    func forget(mapKey: String) {
        map.removeValue(forKey: mapKey)
        persist()
    }

    var count: Int { map.count }

    func clear() {
        map.removeAll()
        persist()
    }
}
