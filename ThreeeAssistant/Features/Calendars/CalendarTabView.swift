import SwiftUI

/// 「日历」页 —— 日历 / 团队 两个子视图。
///
/// ## 为什么把「团队」并到这一页
///
/// 安卓端底部只有 5 个位置（`Pages.kt:11`），放不下 6 个一级入口。
/// 而团队和日历是**同一层概念**：团队是一群人的日历集合，
/// 用户要"给谁开权限"时，脑子里想的就是"这个日历归哪个团队"。
/// 拆成两个一级入口反而要在两页之间来回跳。
///
/// 这和 iOS 原来把「团队」塞进设置页深处是不同的：那是"配置项"，
/// 这是"和日历并列的东西"。
@MainActor
struct CalendarTabView: View {

    @State private var mode: Mode = .calendars

    enum Mode: String, CaseIterable, Identifiable {
        case calendars, teams
        var id: String { rawValue }
        var label: String {
            switch self {
            case .calendars: return "日历"
            case .teams:     return "团队"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

                switch mode {
                case .calendars:
                    CalendarsView()
                case .teams:
                    TeamListView()
                }
            }
            .background(Theme.background)
        }
    }
}
