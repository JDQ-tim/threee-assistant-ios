import SwiftUI
import Observation

// ============================================================
//  外观：浅色 / 深色 / 跟随系统
//  ------------------------------------------------------------
//  需求原话：「背景的话做成跟随系统变化的，或者说专门开一个
//  让人家可以用浅色和深色进行变化」。
//
//  所以是三档，不是两档：
//
//    · 跟随系统（默认）—— 用户在「显示与亮度」里拨，App 自动跟
//    · 浅色 / 深色    —— 强制一档，不管系统
//
//  ## 为什么默认是「跟随系统」
//
//  用户说这句话的时候，"跟随系统"是**第一个**选项，而"专门开一个"
//  是备选的第二方案。默认落在用户第一句话上，是不用猜的。
//  而且 iOS 上的约定也是跟随 —— 强制一档是"我就要这个"的明确选择。
//
//  ## 为什么不用 @AppStorage
//
//  @AppStorage 能落盘、也能当状态用，但它有两个这里过不去的毛病：
//
//  ① 它只在 **View** 里有效。`RootView` 要把它变成
//     `.preferredColorScheme(...)` 没问题，可 `Theme` 那一层
//     （比如"深色下要不要把日历色提亮"）也想读它时就没地方读了。
//  ② 它没有"类型安全的三态"。存成 Int 或 String 的话，
//     某个分支忘了处理就会静默落回默认值。
//
//  所以这里用一个 @Observable 对象（和 `NavPackStore` 同一个写法），
//  根视图 `.environment(...)` 下发，谁都能读、读了就订阅。
// ============================================================

/// 外观偏好。
///
/// ⚠️ `String` 原始值直接当 `UserDefaults` 的键值用 —— 改了 case 名字
///    等于让老用户的设置失效（会静默回到「跟随系统」，不崩，但设置丢了）。
enum AppearanceMode: String, CaseIterable, Identifiable {

    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// 交给 `.preferredColorScheme` 的值。
    ///
    /// ⚠️ `nil` **不是**"没设置"，而是"由系统决定" —— 这是这个 API 的语义。
    ///    写成 `.light` 当默认值的话，用户系统是深色、App 却是白的，
    ///    看起来像"深色模式坏了"。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
@Observable
final class AppearanceStore {

    private static let key = "appearance.mode.v1"

    /// 当前档位。**改它会立刻重画整个 App** ——
    /// `@Observable` 的读取即订阅，根视图读了它，所以写它就唤醒了根视图。
    var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.key)
        }
    }

    private let defaults: UserDefaults

    /// 显式 `init` 是给"读盘"留的位置。
    ///
    /// 如果像别的 store 那样全程惰性读（`loadIfNeeded()`），
    /// 第一帧就会用默认值渲染 —— 用户设的是深色，启动瞬间白一下再变黑。
    /// 那种闪烁在真机上非常刺眼，所以这里在 `init` 里就读完，
    /// 保证第一次布局用的就是用户选的那档。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 存的串可能是被改坏的（老版本键名、手工改过 plist）——
        // 认不出就当没设置过，回到「跟随系统」，不崩。
        let raw = defaults.string(forKey: Self.key) ?? ""
        self.mode = AppearanceMode(rawValue: raw) ?? .system
    }

    /// 当前是不是深色。
    ///
    /// ⚠️ 只有「跟随系统」时才需要问系统 —— 系统档位在别的进程（SpringBoard）
    ///    里，SwiftUI 通过 environment 的 `colorScheme` 才知道。
    ///    所以这个函数只在**已经拿到 colorScheme 的视图里**调它才有意义，
    ///    别在 Theme 那种全局地方调（那里拿不到 environment）。
    func isDark(in systemScheme: ColorScheme) -> Bool {
        switch mode {
        case .system: return systemScheme == .dark
        case .light:  return false
        case .dark:   return true
        }
    }
}
