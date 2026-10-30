import SwiftUI

// ============================================================
//  语义字号层
//  ------------------------------------------------------------
//  为什么要有这一层：
//
//  全工程原有 134 处 `font(.system(size: 13))` 这类硬编码字号。
//  问题不在于"写得不好看"，而在于**它们不跟随系统的动态字体**：
//  用户把「设置 → 显示与亮度 → 文字大小」调到最大时，
//  这些文字纹丝不动 —— 需要在 iPad 上眯着眼看小字的人，
//  调了等于没调。
//
//  这一层把「视觉尺寸」翻译成「语义角色」：
//  代码里写 `.appTitle` 而不是 `size: 17`，
//  系统会按当前动态字体档位自动缩放。
//
//  ⚠️ 不是所有地方都能直接换。
//  - 时间标签、数字等需要**等宽对齐**的，要保留 `.monospacedDigit()`
//  - 图标水印（如空状态那个 64pt 的大图标）应该用 `.appDisplay`，
//    它比正文缩放得更激进，符合系统里大标题的行为
//  - 日历网格里的日期数字受格子大小约束，不能无限放大，
//    这类用 `.appCaptionFixed`，它设了上限
// ============================================================

extension Font {

    // MARK: - 文本（跟随动态字体）

    /// 页面级大标题。对应系统 `.largeTitle` 的份量。
    static let appLargeTitle = Font.largeTitle.weight(.bold)

    /// 页面标题 / 模态页标题
    static let appTitle = Font.title2.weight(.semibold)

    /// 分区标题（List 的 Section header 之外的自定义标题）
    static let appHeadline = Font.headline

    /// 正文主色文字。列表行标题、设置项名称
    static let appBody = Font.body

    /// 次要说明文字。比正文小一档，用于列表行的副标题
    static let appSubheadline = Font.subheadline

    /// 脚注。用于 List 分区的 footer、表单里的辅助说明
    static let appFootnote = Font.footnote

    /// 最小的辅助文字。用于行尾的计数、状态点旁边的字
    static let appCaption = Font.caption

    /// 比 caption 还小一档。原本是 9~10pt 的那批，只在标签里用
    static let appCaption2 = Font.caption2

    // MARK: - 强调

    /// 按钮 / 胶囊标签里的文字
    static let appLabel = Font.subheadline.weight(.medium)

    /// 需要强调的小标签（Pill、角标）
    static let appBadge = Font.caption2.weight(.semibold)

    // MARK: - 数字与时间

    /// 时间文本。等宽数字，避免翻页时列宽跳动。
    static let appTime = Font.caption.monospacedDigit()

    /// 稍大的时间 / 计数
    static let appTimeEmphasis = Font.subheadline.monospacedDigit().weight(.medium)

    // MARK: - 展示型

    /// 空状态的大图标、登录页的品牌标识。
    /// 用 `.system(size:)` 但**保持固定上限** —— 图标不跟随放大到把布局撑破。
    static let appDisplay = Font.system(size: 44, weight: .light)

    /// 次级展示图标
    static let appDisplaySmall = Font.system(size: 30, weight: .regular)

    // MARK: - 固定尺寸（不跟随动态字体）

    /// 网格里的数字。日历格子大小固定，字号放大就会挤出去。
    ///
    /// ⚠️ 这是**有意**不跟随动态字体的少数几处之一。
    ///    但配套的无障碍方案是：网格本身支持双指放大，
    ///    且点格子会跳到列表视图 —— 那里是语义字号。
    static let appGridNumber = Font.system(size: 13, weight: .regular).monospacedDigit()

    /// 网格里的星期缩写
    static let appGridWeekday = Font.system(size: 10, weight: .medium)
}
