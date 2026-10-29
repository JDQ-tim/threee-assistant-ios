import Foundation

/// `eventID -> 提醒配置` 的本地缓存，落盘保存。
///
/// ## 为什么需要这张缓存
///
/// `GET /api/instances` 回来的实例**不带提醒** —— 提醒是**事件级**的，
/// 按 (event_id, user_id) 存在服务端 `reminders` 表里，只有
/// `GET /api/events/{id}`（详情）和 `/api/sync/snapshot`（整份快照）才带。
///
/// 而排本地通知必须在**拿到实例**的那一刻就知道「这条提前几分钟响」。
/// 一屏 30 天的实例可能有几千条，逐条去请求详情是不可接受的，
/// 所以在本地留一份映射：
///
///   · 登录后拉一次快照补全（`SessionStore.refreshReminderRulesIfStale`）
///   · 自己新建 / 编辑时当场更新（请求体里本来就有 reminders）
///   · 打开详情页时顺手更新
///
/// ## 为什么必须落盘
///
/// 不落盘的话，冷启动到第一次快照回来之间那几秒，重排逻辑会认为
/// 「所有日程都没有提醒」从而把已排的通知**全部撤掉** ——
/// 表现是「每次杀后台重开，当天的提醒全没了」，而且完全无法复现（取决于网速）。
@MainActor
final class ReminderRuleCache {
    static let shared = ReminderRuleCache()

    /// 多久重拉一次全量快照。跨设备改了提醒，最多滞后这么久。
    static let fullSyncInterval: TimeInterval = 6 * 3600

    private(set) var rules: [String: EventReminderRule] = [:]
    private(set) var lastFullSyncAt: Date?

    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: - 读

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        rules = box.rules
        lastFullSyncAt = box.lastFullSyncAt
    }

    func rule(for eventID: String) -> EventReminderRule? {
        loadIfNeeded()
        return rules[eventID]
    }

    /// 该不该去拉一次全量快照。
    var needsFullSync: Bool {
        loadIfNeeded()
        guard let t = lastFullSyncAt else { return true }
        return Date.now.timeIntervalSince(t) >= Self.fullSyncInterval
    }

    var count: Int {
        loadIfNeeded()
        return rules.count
    }

    // MARK: - 写

    /// 用一整份事件列表覆盖缓存（快照回来的路径）。
    ///
    /// **只保留有提醒的**：没提醒的事件存进去只会让文件变大，
    /// 而 `rules[id] == nil` 和 `rules[id] == 空` 在排通知时等价。
    func replaceAll(_ events: [APIEvent], syncedAt: Date = .now) {
        loadIfNeeded()
        var next: [String: EventReminderRule] = [:]
        for ev in events {
            let minutes = ev.reminders.map { Int($0.minutesBefore) }.sorted()
            guard !minutes.isEmpty else { continue }
            next[ev.id] = EventReminderRule(minutesBefore: minutes, strong: ev.strong)
        }
        rules = next
        lastFullSyncAt = syncedAt
        // ⚠️ 无论内容有没有变都要落盘：`lastFullSyncAt` 变了。
        //    只在"规则变了"时才写的话，一个提醒配置从来没改过的账号，
        //    每次启动都会因为 needsFullSync 仍为 true 而重拉快照。
        scheduleSave()
    }

    /// 单条更新（新建 / 编辑 / 打开详情时）。空数组表示这条不提醒了。
    func upsert(eventID: String, minutesBefore: [Int], strong: Bool) {
        loadIfNeeded()
        let minutes = minutesBefore.sorted()
        if minutes.isEmpty {
            if rules.removeValue(forKey: eventID) != nil { scheduleSave() }
            return
        }
        let rule = EventReminderRule(minutesBefore: minutes, strong: strong)
        if rules[eventID] != rule {
            rules[eventID] = rule
            scheduleSave()
        }
    }

    func remove(eventID: String) {
        loadIfNeeded()
        if rules.removeValue(forKey: eventID) != nil { scheduleSave() }
    }

    /// 退出登录 / 清空数据时调 —— 否则换账号后会拿上个账号的提醒去排通知。
    func clear() {
        loadIfNeeded()
        rules = [:]
        lastFullSyncAt = nil
        saveNow()
    }

    // MARK: - 落盘

    private struct Stored: Codable {
        var rules: [String: EventReminderRule]
        var lastFullSyncAt: Date?
    }

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true) else { return nil }
        let sub = dir.appendingPathComponent("ThreeeAssistant", isDirectory: true)
        if !fm.fileExists(atPath: sub.path) {
            try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        return sub.appendingPathComponent("reminder-rules.json")
    }

    /// 合并短时间内的多次写入，避免编辑时每敲一下都写盘。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let url = Self.fileURL else { return }
        let box = Stored(rules: rules, lastFullSyncAt: lastFullSyncAt)
        guard let data = try? JSONEncoder().encode(box) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
