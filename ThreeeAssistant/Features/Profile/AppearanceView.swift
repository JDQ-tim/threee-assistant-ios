import SwiftUI

// ============================================================
//  外观
//  ------------------------------------------------------------
//  用户需求：「背景的话做成跟随系统变化的，或者说专门开一个让人家
//  可以用浅色和深色进行变化」。
//
//  这里面只有一件事：浅色 / 深色 / 跟随系统。
//
//  ## 为什么把它单独做一页，而不是塞进设置列表里当一个开关
//
//  三选一没有"开关"这种表达方式。用 Toggle 的话必须再加一行
//  「跟随系统」的开关，两个开关组合出四种状态 —— 而其中一种是
//  "跟着系统、同时强制浅色"，没有意义。所以用分段控件一屏选完。
//
//  ## 为什么要有预览
//
//  这个页面本身就会跟着变（选了深色，整页当场变深），
//  但用户会怀疑"只有这一页变了吗"。所以下面放一块模拟的小卡片，
//  里面用**真实的** Theme 色值画一遍底/面/字/强调色 ——
//  它和 App 其余部分取的是同一套 token，看得见就说明真的生效了。
// ============================================================

@MainActor
struct AppearanceView: View {

    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                sectionTitle("模式")

                Picker("模式", selection: Binding(
                    get: { appearance.mode },
                    set: { appearance.mode = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Text(explainText)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                sectionTitle("预览")

                previewCard

                Text("颜色取自界面上真实在用的那套：底色、卡片、正文、次要文字、强调色。"
                     + "上面切一下，这里和整个 App 会同时变。")
                    .font(.caption2)
                    .foregroundStyle(Theme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var explainText: String {
        switch appearance.mode {
        case .system:
            return "跟着 iOS 走：系统在「设置 → 显示与亮度」里切到深色，这里也变深色。"
                 + "这是默认值，也是大多数人想要的。"
        case .light:
            return "不管系统怎么设，这个 App 一直是浅色。适合手机设了定时深色、"
                 + "但白天看日程不想被切成黑色的情况。"
        case .dark:
            return "不管系统怎么设，这个 App 一直是深色。适合晚上看课表，"
                 + "或者手机是共享的、不想被别人切走的情况。"
        }
    }

    /// 一块「假界面」。用的全是真实 token，所以它不可能和实际界面不一致。
    ///
    /// ⚠️ 外面这层 `Group` 不是多余的：`some View` 的**计算属性**
    ///    没有隐式 `@ViewBuilder`（只有 `body` 有），
    ///    直接写两行同级表达式会被当成"第一条算出个值就丢掉"。
    private var previewCard: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.blue600)
                        .frame(width: 9, height: 9)
                    Text("高等数学（下）")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text("08:00")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("博学楼 3-402 · 大二上课程表")
                    .font(.appCaption)
                    .foregroundStyle(Theme.hint)

                // 一行"按钮"：靠强调色，一眼能看出着色有没有跟着换
                HStack(spacing: 8) {
                    Text("详情")
                        .font(.appFootnote.weight(.medium))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent)
                        .clipShape(Capsule())

                    Text("改期")
                        .font(.appFootnote.weight(.medium))
                        .foregroundStyle(Theme.blue600)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.blue50)
                        .clipShape(Capsule())

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.appFootnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 2)
    }
}
