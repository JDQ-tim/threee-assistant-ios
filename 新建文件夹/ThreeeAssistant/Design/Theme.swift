import SwiftUI
import UIKit

// ============================================================
//  配色
//  ------------------------------------------------------------
//  数值直接取自安卓端 `android/app/src/main/java/cn/threees/assistant/ui/Theme.kt`。
//  同一个产品在两端必须是同一套颜色，否则用户换设备会觉得「这不是同一个 App」。
// ============================================================

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Color {

    /// 深色/浅色两套值，跟着系统切换
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// 解析服务端下发的 `#RRGGBB`（日历颜色是用户定的，可能不规范）
    init(hexString: String, fallback: Color = Theme.accent) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = fallback
            return
        }
        self = Color(uiColor: UIColor(rgb: v))
    }
}

enum Theme {

    // 品牌色
    static let blue600 = Color.adaptive(light: 0x185FA5, dark: 0x85B7EB)
    static let blue50 = Color.adaptive(light: 0xE6F1FB, dark: 0x0C447C)
    static let teal600 = Color.adaptive(light: 0x0F6E56, dark: 0x5DCAA5)
    static let teal50 = Color.adaptive(light: 0xE1F5EE, dark: 0x085041)
    static let amber600 = Color.adaptive(light: 0x854F0B, dark: 0xEF9F27)
    static let amber50 = Color.adaptive(light: 0xFAEEDA, dark: 0x4A3508)
    static let red600 = Color.adaptive(light: 0xA32D2D, dark: 0xF09595)
    static let red50 = Color.adaptive(light: 0xFCEBEB, dark: 0x4A1B0B)

    // 表面
    static let background = Color.adaptive(light: 0xFAFAF8, dark: 0x16171A)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1E1F23)
    static let surfaceAlt = Color.adaptive(light: 0xF5F5F2, dark: 0x26272C)
    static let separator = Color.adaptive(light: 0xE8E6E0, dark: 0x32333A)

    // 文字（对比度按 WCAG AA 挑过，和安卓端 Palette.kt 的目标一致）
    static let textPrimary = Color.adaptive(light: 0x1A1A18, dark: 0xF1EFE8)
    static let textSecondary = Color.adaptive(light: 0x5F5E5A, dark: 0xB4B2A9)
    static let textTertiary = Color.adaptive(light: 0x8C8B86, dark: 0x7C7B76)

    static let accent = blue600
    static let onAccent = Color.adaptive(light: 0xFFFFFF, dark: 0x042C53)

    static let corner: CGFloat = 14
    static let cornerSmall: CGFloat = 10
}
