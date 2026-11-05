import SwiftUI
import UIKit

// ============================================================
//  日历配色板
//  ------------------------------------------------------------
//  用户需求：「日程的话颜色可挑」。
//
//  这件事本来就有（`CalendarEditSheet` 里有 8 个色块），但只有 8 个、
//  而且全是**浅色下才好看**的 600 档 —— 在深色背景上当色条用时偏暗，
//  尤其是 `#5F5E5A`（灰）和 `#A32D2D`（深红），几乎和背景糊在一起。
//
//  ## 这里的做法
//
//  色板按**色相**给（蓝/蓝绿/绿/青/紫/玫红/橙/黄/红/棕/灰…），
//  每一档两套值：
//
//    · light —— 服务端里存的就是它，浅色背景上看
//    · dark  —— **同一个色相、亮一档**，只在深色下用于显示
//
//  ## ⚠️ 关键约束：深色下**不写回**服务端
//
//  服务端存的是一个 `#RRGGBB` 字段，所有端共用。深色下改存成亮色的话，
//  同一个账号在网页端、安卓端（浅色）就会看到一片荧光色。
//  所以：**存的是浅色那套，显示的由本机按外观决定**。
//
//  这和「节假日只改显示不回写」是同一条纪律 —— 外观是这台设备的属性，
//  不是这条日程的属性。
//
//  ## 已经存了自定义色的日历怎么办
//
//  用户可能通过取色器选了任意颜色（服务端接受任意 `#RRGGBB`）。
//  那种颜色不在色板里，没有"配套的深色版"，所以深色下**只提亮、不换色相** ——
//  见 `displayColor(for:)`。
// ============================================================

enum CalendarPalette {

    struct Swatch {
        let name: String
        /// 存进服务端的值（也是浅色下显示的值）
        let light: String
        /// 深色下显示的值：同一个色相、亮一档
        let dark: String

        /// 深色下的值转成可计算的 UIColor 缓存在外面 —— 这里只留字符串。
    }

    /// 色板顺序 = 实际界面上摆的顺序。
    ///
    /// ⚠️ 前 8 个**必须是原来那 8 个**，且顺序不变。
    ///    已有日历里存的就是这 8 个值中的某一个，改了它们的 `light`
    ///    等于把用户所有日历的颜色都改了 —— 那是不可接受的回退。
    static let swatches: [Swatch] = [
        // —— 原来那 8 个，原样保留 ——
        .init(name: "蓝",   light: "#185FA5", dark: "#85B7EB"),
        .init(name: "蓝绿", light: "#0F6E56", dark: "#5DCAA5"),
        .init(name: "琥珀", light: "#854F0B", dark: "#EF9F27"),
        .init(name: "红",   light: "#A32D2D", dark: "#F09595"),
        .init(name: "紫",   light: "#534AB7", dark: "#AFA9EC"),
        .init(name: "玫红", light: "#993556", dark: "#ED93B1"),
        .init(name: "绿",   light: "#3B6D11", dark: "#97C459"),
        .init(name: "灰",   light: "#5F5E5A", dark: "#B4B2A9"),

        // —— 新增 8 个，补的是"同一色系里更直观的那一档" ——
        //
        // 为什么是这几个而不是随便加：日历配色实际是拿来**区分**的，
        // 而人能一眼分开的色相就那十来个。8 个时经常出现"我这两张日历
        // 颜色差不多"，尤其是蓝/蓝绿、橙/红之间。
        // 补的是青、浅蓝、深紫、深绿、粉、橙红、以及两档中性 ——
        // 中性那两档是给「作息 / 考试 / 假期」这类不需要抢眼的日历用的。
        .init(name: "青",   light: "#0E7490", dark: "#67E8F9"),
        .init(name: "天蓝", light: "#0369A1", dark: "#7DD3FC"),
        .init(name: "靛",   light: "#4338CA", dark: "#A5B4FC"),
        .init(name: "粉",   light: "#BE185D", dark: "#F9A8D4"),
        .init(name: "橙红", light: "#C2410C", dark: "#FDBA74"),
        .init(name: "草绿", light: "#4D7C0F", dark: "#BEF264"),
        .init(name: "石板", light: "#475569", dark: "#CBD5E1"),
        .init(name: "棕",   light: "#92400E", dark: "#D6A87C"),
    ]

    /// 新建日历时的默认色（蓝）。
    static var defaultLight: String { swatches[0].light }

    // MARK: - 显示

    /// 一个日历在**当前外观**下应该显示成什么颜色。
    ///
    /// - Parameter dark: 当前画在深色背景上吗。由视图从
    ///   `@Environment(\.colorScheme)` 传进来 —— 不能在这里自己判断，
    ///   因为 `Theme` 层拿不到 environment，而 `UIColor { traits in }`
    ///   那套又不认 `.preferredColorScheme` 的**强制浅色**
    ///   （那个是 App 层的，不是系统档位，`traits` 里读不到）。
    ///
    /// 这个区别很要命：用户在设置里选了「强制浅色」而系统是深色，
    /// 用 `UIColor { traits }` 的话会拿到深色版 —— 亮色块画在浅色背景上，
    /// 糊成一片。
    static func display(_ hex: String, dark: Bool) -> Color {
        // 先看是不是色板里的。
        if let swatch = swatches.first(where: { $0.light.caseInsensitiveCompare(hex) == .orderedSame }) {
            return Color(hexString: dark ? swatch.dark : swatch.light)
        }
        // 自定义色（取色器选的）：深色下提亮，浅色下原样。
        //
        // 只提亮不改色相 —— 用户自己挑的颜色，换色相就不是他挑的那个了。
        // 提亮用 HSL 的 L 通道，不是简单地和白色混合：
        // 混白会把饱和度一起冲掉（红变成粉），而提 L 保留色相和相对饱和度。
        guard dark else { return Color(hexString: hex) }
        return Color(uiColor: lifted(hex))
    }

    /// 深色下把自定义色提到"在深底上看得见"的亮度。
    ///
    /// 目标 L ≈ 68% —— 大致相当于色板里那批 `dark` 值的平均亮度。
    /// 原本已经够亮的（L ≥ 60%）不动，免得用户挑的浅黄被提成白色。
    private static func lifted(_ hex: String) -> UIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return UIColor(rgb: 0x185FA5)
        }
        // ⚠️ 直接 `.../255` 在 Swift 里是整数除法，会全部得到 0 或 1。
        //    CGFloat 字面量必须写全 —— 这个坑编译不报错，只是颜色变成纯黑。
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0

        let hsl = HSL(r: r, g: g, b: b)
        let target: CGFloat = max(hsl.l, 0.68)
        return hsl.toColor(l: target)
    }

    /// 色块里的字该用什么颜色。
    ///
    /// WCAG 的相对亮度公式算完，**白字/黑字各比一次，取对比度高的那个**。
    ///
    /// ⚠️ 不要用"亮度 > 0.55 就配黑字"这种单阈值写法。第一版就是这么写的，
    ///    被 `check_palette.py` 全部打回：深色档那批亮色块（`#85B7EB`、
    ///    `#EF9F27`、`#B4B2A9`…）亮度落在 0.4~0.5，按阈值会配**白字**，
    ///    实测只有 **2.0:1** —— 也就是"浅蓝底上的白字"，几乎看不见。
    ///    而同一个底配黑字是 10:1。
    ///
    ///    单阈值只在"底色是标准饱和色"时成立；一旦色板里混进明亮档位
    ///    （深色模式必须混），阈值就会在中间那段灰区判反。
    ///    直接比两次对比度没有这个问题 —— 它按定义就取最优。
    ///
    /// 为什么现在还要留一点"倾向"：两个对比度打平时（亮度 ~0.18），
    /// 小字用白更耐看（黑字在中等灰上会显得脏）。所以平手取白。
    static func readableInk(on color: Color) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return .white
        }
        // sRGB → 线性 → 加权亮度（WCAG 2.1 的写法）
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

        // 对比度公式是 (L1 + 0.05) / (L2 + 0.05)。
        // 拿白和底比、黑和底比，分母/分子换一下位置而已：
        //   白字 → 1.05 / (lum + 0.05)
        //   黑字 → (lum + 0.05) / 0.05
        // 两者相等时 lum = sqrt(0.0525) - 0.05 ≈ 0.1791。
        // 大于它就用黑字（更清楚），否则白字。
        return lum > 0.1791 ? Color(hexString: "#1A1A18") : .white
    }

    /// 供离线自检（`tools/check_palette.py`）核对用。
    ///
    /// 要核的三件事，每一条都对应一个真实会出问题的地方：
    /// ① 每个 `light` 互不相同 —— 相同的话用户选不出两张颜色不同的日历
    /// ② 每个 `dark` 在深色背景 `#1E1F23` 上的对比度 ≥ 3:1
    ///    （WCAG 对"图形/UI 组件"的要求，色条属于这一类）
    /// ③ 每个 `light` 在浅色表面 `#FFFFFF` 上的对比度 ≥ 3:1
    ///    （浅色下色条同样是 UI 图形，不是装饰）
    ///
    /// ⚠️ 这个属性本身没有调用方 —— 它的用途是让 Python 那边
    ///    **有东西可读**，而不是让 Swift 运行时用到它。
    ///    自检读的是源文件里的 `swatches` 字面量，见那个脚本。
    static var selfCheckPairs: [(light: String, dark: String)] {
        swatches.map { (light: $0.light, dark: $0.dark) }
    }
}

/// 极简 HSL —— 只为了"保色相、只动亮度"这一件事。
///
/// 为什么不引第三方：整个工程零依赖，为一个提亮函数加包不值得。
private struct HSL {
    var h: CGFloat  // 0..<1
    var s: CGFloat  // 0...1
    var l: CGFloat  // 0...1

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        l = (mx + mn) / 2

        if d == 0 {
            h = 0
            s = 0
            return
        }
        // 除以 (1 - |2l - 1|) 才是"标准 HSL 饱和度"；
        // 除以 d 会得到 HSV 的饱和度，提亮之后颜色会偏灰。
        s = d / (1 - abs(2 * l - 1))

        if mx == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        if h < 0 { h += 1 }
    }

    func toColor(l newL: CGFloat) -> UIColor {
        guard s > 0.0001 else {
            return UIColor(red: newL, green: newL, blue: newL, alpha: 1)
        }
        let q = newL < 0.5 ? newL * (1 + s) : newL + s - newL * s
        let p = 2 * newL - q
        func channel(_ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return UIColor(red: channel(h + 1.0 / 3),
                       green: channel(h),
                       blue: channel(h - 1.0 / 3),
                       alpha: 1)
    }
}
