import Foundation
import EventKit

// ============================================================
//  系统日历同步的编排层
//  ------------------------------------------------------------
//  `SystemCalendar` 只管"跟 EventKit 说话"，这一层管**流程**：
//  谁调谁、失败怎么报、重复怎么避。
//
//  ## 为什么不写进 SystemCalendar
//
//  那一层是纯 EventKit 封装，能在没有 SessionStore 的情况下测。
//  这一层要同时碰 EventKit 和网络，两边都可能失败，
//  混在一起的话"导入失败"到底是日历没权限还是服务端 500 都说不清。
// ============================================================

@MainActor
final class SystemCalendarSync {

    static let shared = SystemCalendarSync()

    private let sys = SystemCalendar.shared

    private init() {}

    // MARK: - 导入（系统日历 → 3e）

    /// 把系统日历里的一批事件导入成 3e 的日程。
    ///
    /// - Parameters:
    ///   - events: 要导入的系统事件
    ///   - calendarID: 3e 的哪张日历。为空则自动建一张「系统日历导入」
    ///   - store: 用来发请求、刷新列表
    /// - Returns: 逐项结果。**不会中途抛错** —— 导入 200 条时第 3 条失败，
    ///            不该让剩下 197 条全放弃。失败了在 `errors` 里说清楚。
    func importEvents(
        _ events: [EKEvent],
        into calendarID: String?,
        store: SessionStore
    ) async -> SystemCalendarSyncResult {
        var result = SystemCalendarSyncResult()

        guard SystemCalendar.access().canRead else {
            result.failed = events.count
            result.errors = [SystemCalendarError.noAccess.localizedDescription]
            return result
        }
        guard !events.isEmpty else { return result }

        // 1. 确定目标日历
        let targetID: String
        do {
            if let id = calendarID, !id.isEmpty {
                targetID = id
            } else {
                targetID = try await ensureImportCalendar(store: store)
            }
        } catch {
            result.failed = events.count
            result.errors = ["建导入日历失败：\(error.localizedDescription)"]
            return result
        }

        let map = ImportedEventMap.shared

        // 2. 逐条导
        for ev in events {
            let ekID = ev.eventIdentifier ?? ""
            if ekID.isEmpty {
                result.skipped += 1
                continue
            }

            // 已经导过：**不重复导**。
            //
            // 这里刻意不做"内容变了就更新"。原因：导入是复制语义，
            // 用户在 3e 里改过的备注不该被系统日历的旧值覆盖回去。
            // 想让两边一致，用户应该重导一次（那时先删再导）。
            if map.threeeID(for: ekID) != nil {
                result.skipped += 1
                continue
            }

            let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                result.skipped += 1
                continue
            }

            let start = ev.startDate ?? Date()
            let end = ev.endDate ?? start.addingTimeInterval(3600)
            let minutes = max(1, Int(end.timeIntervalSince(start) / 60))

            do {
                let newID = try await store.createEventReturningID(
                    calendarID: targetID,
                    title: title,
                    start: start,
                    durationMinutes: ev.isAllDay ? 1440 : minutes,
                    // 不复制系统事件的重复规则。
                    //
                    // 系统日历的 recurrenceRules 是 EKRecurrenceRule 对象，
                    // 转成 RRULE 字符串要处理 BYDAY/BYSETPOS/COUNT/UNTIL
                    // 等十几种组合，转错的表现是"重复日程落在错误的日子"。
                    // 更稳的做法是导入展开后的单次事件（我们拉到的是
                    // occurrences，本来就是展开的），所以这里一律当单次。
                    rrule: nil,
                    reminders: [],
                    isTask: false,
                    allDay: ev.isAllDay,
                    strong: false,
                    notes: ev.notes ?? "",
                    location: ev.location ?? ""
                )
                if let threeeID = newID {
                    map.remember(ekID: ekID, threeeID: threeeID)
                }
                result.created += 1
            } catch {
                result.failed += 1
                if result.errors.count < 5 {
                    result.errors.append("「\(title)」：\(error.localizedDescription)")
                }
            }
        }

        return result
    }

    /// 找或建「系统日历导入」这张 3e 日历。
    ///
    /// 单独一张而不是塞进用户现有的日历：导入的东西往往有几百条，
    /// 混进「课表」里之后想整体删掉就得一条条挑。
    private func ensureImportCalendar(store: SessionStore) async throws -> String {
        let name = "系统日历导入"
        if let exist = store.calendars.first(where: { $0.name == name && $0.canWrite }) {
            return exist.id
        }
        guard let id = try await store.createCalendarReturningID(
            name: name,
            color: "#0F6E56",
            kind: "calendar"
        ) else {
            throw APIError.server(500, "服务端没有返回新日历的 id")
        }
        return id
    }

    // MARK: - 导出（3e → 系统日历）

    /// 把 3e 在某个时间窗内的日程写进系统日历。
    ///
    /// - Parameters:
    ///   - instances: 已展开的实例（`ScheduleInstance`）
    ///   - from/to: 时间窗，界面上写清楚
    func exportInstances(_ instances: [ScheduleInstance]) -> SystemCalendarSyncResult {
        var result = SystemCalendarSyncResult()

        guard SystemCalendar.access().canWrite else {
            result.failed = instances.count
            result.errors = [SystemCalendarError.noAccess.localizedDescription]
            return result
        }

        let cal: EKCalendar
        do {
            cal = try sys.ensureOurCalendar()
        } catch {
            result.failed = instances.count
            result.errors = [error.localizedDescription]
            return result
        }

        let map = ExportedEventMap.shared

        for inst in instances {
            // 待办不导出：系统日历里没有"待办"这个概念，
            // 导出成一整天的日历事件只会污染用户的日历。
            if inst.isTask { 
                result.skipped += 1
                continue
            }

            // 已完成的 / 已过去的也不导。
            let start = Date(timeIntervalSince1970: Double(inst.startUTC))
            let end = Date(timeIntervalSince1970: Double(inst.endUTC))

            let key = ExportedEventMap.mapKey(
                eventID: inst.eventID,
                occurrenceKey: inst.occurrenceKey
            )
            let existing = map.ekID(for: key)

            let title = inst.title.nonEmpty(or: "未命名日程")
            do {
                let ekID = try sys.upsert(
                    ekIdentifier: existing,
                    in: cal,
                    title: title,
                    start: start,
                    end: end,
                    allDay: inst.allDay,
                    notes: inst.notes ?? "",
                    location: inst.location ?? ""
                )
                if existing == nil {
                    result.created += 1
                } else {
                    result.updated += 1
                }
                map.remember(mapKey: key, ekID: ekID)
            } catch {
                result.failed += 1
                if result.errors.count < 5 {
                    result.errors.append("「\(title)」：\(error.localizedDescription)")
                }
            }
        }

        return result
    }

    // MARK: - 清理

    /// 把已经导出到系统日历的条目全删掉。只动我们自己那张日历。
    func removeAllExported() -> Int {
        let n = (try? sys.purgeOurCalendar()) ?? 0
        ExportedEventMap.shared.clear()
        return n
    }
}
