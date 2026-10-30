import SwiftUI

/// 「我的用户组」。
///
/// ## 这个页面解决什么
///
/// 之前用户不知道自己是哪一档、什么时候到期、有哪些功能用不了。
/// 结果是：功能没出现就以为是 Bug（其实是档位不够），
/// 到期了不知道，去问管理员「我的 SVIP 呢」。
///
/// ## 三条界面纪律（和 `TierInfoDTO` 的注释一一对应）
///
/// 1. **不自己判档。** 「已过期」用服务端给的 `tierExpired`，
///    不看 `now > expiresAt`。两边时钟差几分钟就会出现
///    「界面说过期了、服务端还让我用」的诡异状态。
/// 2. **0 显示成「不限」，不是「0」。**
///    `maxDevices == 0` 是「不限台数」，直接渲染成「最多 0 台设备」是灾难。
/// 3. **只显示中文名。** `tier` 是品牌串，`tierLabel` 才是给人看的；
///    中文名只在服务端 `tierLabels` 定义一处，客户端不再抄一遍。
@MainActor
struct TierView: View {

    @Environment(SessionStore.self) private var store

    @State private var tier: TierInfoDTO?
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        Form {
            if loading {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                }
            } else if let msg = failure {
                Section {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("重试") { Task { await load() } }
                }
            } else if let t = tier {
                currentSection(t)
                abilitySection(t.entitlements)
                Section {
                    Text("用户组由管理员设置。想升级请联系部署这个服务的人。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .navigationTitle("我的用户组")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func currentSection(_ t: TierInfoDTO) -> some View {
        Section {
            HStack {
                Text(t.tierLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(t.tierExpired ? Theme.textSecondary : Theme.accent)
                Spacer()
                if t.tierExpired {
                    Text("已过期")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.red600)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            LabeledContent("有效期", value: t.expiryText)
        } header: {
            Text("当前档位")
        } footer: {
            if t.tierExpired {
                Text("已经过期，现在按普通用户的能力使用。已有数据不会被删。")
            }
        }
    }

    private func abilitySection(_ e: EntitlementsDTO) -> some View {
        Section {
            abilityRow("实时协作", on: e.liveCollab)
            abilityRow("外部 API", on: e.extApi)
            abilityRow("插件市场", on: e.market)
            abilityRow("社团插件", on: e.club)

            quotaRow("设备数", value: e.maxDevices)
            quotaRow("API Key", value: e.maxApiKeys)
            quotaRow("日程数", value: e.maxEvents)
        } header: {
            Text("能用什么")
        } footer: {
            Text("「不限」表示这一项没有数量上限。")
        }
    }

    private func abilityRow(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.teal600)
            } else {
                // 用「—」而不是红叉：没有这项能力不是错误状态，
                // 只是这个档位不包含它，画个叉会让人以为出故障了
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(on ? "可用" : "不可用")")
    }

    /// ⚠️ `0` 是**不限**，不是零额度。这是服务端 `Entitlements` 的明确约定，
    ///    写成「最多 0 台」会让用户以为账号被限制了。
    private func quotaRow(_ title: String, value: Int) -> some View {
        LabeledContent(title, value: value == 0 ? "不限" : "\(value)")
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            tier = try await store.loadTier()
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }
}
