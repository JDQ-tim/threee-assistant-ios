import SwiftUI

// ============================================================
//  关于
//  ------------------------------------------------------------
//  从原设置页最底部剥出来。原设计把版本号和一整段功能介绍
//  （"原生 iOS 版。日程支持新建、修改、重复、提醒…"）
//  直接铺在设置列表里，滚到这里要划十几屏。
//
//  关于页是用户**主动找**的地方（查版本、看更新、
//  或者想搞清楚这 App 到底能干什么），不是路过的地方。
// ============================================================

@MainActor
struct AboutView: View {

    @Environment(SessionStore.self) private var store

    /// 和服务端 `/api/health` 同源。连不上就保持 nil。
    @State private var serverVersion: String?

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("3e")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 76, height: 76)

                    Text("3e 学习助手")
                        .font(.appTitle)
                        .foregroundStyle(Theme.textPrimary)

                    Text("原生 iOS 版")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("App 版本", value: appVersion)
                LabeledContent("服务端版本", value: serverVersion ?? "—")
                LabeledContent("服务器地址") {
                    Text(store.serverText)
                        .font(.appFootnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("版本")
            }

            Section {
                capabilityRow("calendar", "日程", "新建、修改、重复规则、改期、全天、跨天")
                capabilityRow("bell.badge", "提醒", "提前提醒、强提醒（穿透专注模式）、稍后提醒")
                capabilityRow("checklist", "待办", "独立列表、逾期标记、完成回顾")
                capabilityRow("person.2", "协作", "团队、共享日历、日历邀请、收件箱投递")
                capabilityRow("arrow.triangle.2.circlepath", "同步", "增量同步、字段级冲突处理、离线可读")
                capabilityRow("character.book.closed", "背词", "独立端口的词书同步")
            } header: {
                Text("功能")
            }

            Section {
                Text("这是一个自托管的日程服务。所有数据都存在你自己的服务器上，不经过任何第三方。")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 拿服务端版本号。失败静默 —— 这不影响任何功能，
            // 显示一个"—"比弹错误提示合适。
            if let h = try? await store.checkHealth(server: store.serverText) {
                serverVersion = h.version
            }
        }
    }

    private func capabilityRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSubheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.appCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
