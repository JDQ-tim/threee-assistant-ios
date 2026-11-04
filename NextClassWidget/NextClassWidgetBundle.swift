import SwiftUI
import WidgetKit

/// 扩展的入口。
///
/// ⚠️ `@main` **只能有一个**，而且不能和 App 的 `@main` 在同一个 target 里 ——
///    这也是为什么实时活动的 UI 必须放在独立的 Widget Extension 里。
@main
struct NextClassWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextClassLiveActivity()
    }
}
