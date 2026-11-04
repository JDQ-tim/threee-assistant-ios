import ActivityKit
import Foundation

// ============================================================
//  「下一节课 / 正在上课」的实时活动契约
//  ------------------------------------------------------------
//  ⚠️ **这个文件同时编进两个 target**：
//      · ThreeeAssistant（App 本体，负责 start/update/end）
//      · NextClassWidget（Widget Extension，负责渲染）
//
//  两个 target 是两个**不同的模块**，所以这里的类型必须 `public`，
//  属性和 init 也要 public —— 否则扩展里读不到，而报错只会说
//  "cannot find type in scope"，完全不指向访问级别。
//
//  ## 为什么灵动岛要靠它
//
//  通知（UNNotification）**进不了灵动岛**。能进灵动岛的只有
//  Live Activity —— 由 ActivityKit 发起、由 WidgetKit 扩展渲染。
//  所以"把课表做上灵动岛"这件事，本质是"做一个实时活动"。
//
//  ## 为什么状态里存的是**绝对时间**而不是"还有 12 分钟"
//
//  实时活动在 App 退出后还要继续显示。如果存的是算好的分钟数，
//  过了五分钟它还是写着"还有 12 分钟"，而用户没有理由怀疑它。
//  存 Date，让界面用 `Text(date, style: .timer)` 自己走 ——
//  那个倒计时由系统逐秒刷新，**不需要我们推更新**。
// ============================================================

public struct NextClassActivityAttributes: ActivityAttributes {

    /// 会随时间变的部分。
    public struct ContentState: Codable, Hashable {

        /// 课名
        public var title: String
        /// 地点（可能为空串）
        public var location: String
        /// 开始时刻
        public var start: Date
        /// 结束时刻
        public var end: Date

        public init(title: String, location: String, start: Date, end: Date) {
            self.title = title
            self.location = location
            self.start = start
            self.end = end
        }
    }

    /// 整场活动期间**不变**的部分：这条日程是谁。
    ///
    /// 存 eventID 而不是标题：标题会被改（"高数"→"高等数学"），
    /// 而我们要靠它判断"手机上正在显示的那一条，是不是刚算出来的这一条"。
    public let eventID: String

    public init(eventID: String) {
        self.eventID = eventID
    }
}
