import SwiftUI

@MainActor
struct SettingsView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingForget = false
    @State private var busy = false

    /// 待处理冲突数。0 时入口仍然显示 —— 藏起来会让人以为这个功能不存在，
    /// 真遇到冲突时根本找不到地方处理。
    @State private var pendingConflicts = 0
    @State private var teamCount = 0
    /// 待处理收件箱条数（不含过期和系统通知）
    @State private var inboxCount = 0
    /// 自己的用户组（拿不到就保持 nil，行尾显示「—」）
    @State private var tier: TierInfoDTO?

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    LabeledContent("用户名", value: store.user?.name ?? "—")
                    LabeledContent("身份", value: (store.user?.isAdmin ?? false) ? "管理员" : "普通成员")
                    NavigationLink {
                        TierView()
                    } label: {
                        HStack {
                            Text("用户组")
                            Spacer(minLength: 0)
                            // 拿不到就不显示档位名。这里不缓存上一次的值 ——
                            // 缓存了会在管理员改档之后还显示旧档位
                            if let t = tier {
                                Text(t.tierLabel)
                                    .font(.caption)
                                    .foregroundStyle(t.tierExpired ? Theme.red600 : Theme.textSecondary)
                            } else {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }

                Section("连接") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("服务器")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(store.serverText.isEmpty ? "—" : store.serverText)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)

                    NavigationLink {
                        SyncStatusView()
                    } label: {
                        HStack {
                            Text("同步")
                            Spacer(minLength: 0)
                            Text(store.syncCursor > 0 ? "游标 \(store.syncCursor)" : "未同步")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                Section("数据") {
                    NavigationLink("我的日历（\(store.calendars.count)）") {
                        CalendarsView()
                    }
                    NavigationLink {
                        TeamListView()
                    } label: {
                        HStack {
                            Text("我的团队")
                            Spacer(minLength: 0)
                            if teamCount > 0 {
                                Text("\(teamCount)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    NavigationLink {
                        InboxView()
                    } label: {
                        HStack {
                            Text("收件箱")
                            Spacer(minLength: 0)
                            if inboxCount > 0 {
                                Text("\(inboxCount)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            } else {
                                Text("无")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    NavigationLink {
                        ConflictsView()
                    } label: {
                        HStack {
                            Text("修改冲突")
                            Spacer(minLength: 0)
                            if pendingConflicts > 0 {
                                // 有冲突时要显眼：这是「我明明改了却没生效」的根源，
                                // 不点进去永远不会自己消失
                                Text("\(pendingConflicts)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.red600)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            } else {
                                Text("无")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    Button("重新同步") {
                        Task {
                            await store.refresh()
                            await loadConflictCount()
                        }
                    }
                }

                Section {
                    Button("忘记已信任的服务器证书") {
                        confirmingForget = true
                    }
                    Text("用于服务器换了证书、连不上时。忘记之后下次连接会重新记录一次。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                } header: {
                    Text("安全")
                }

                Section {
                    NavigationLink {
                        ChangePasswordView()
                    } label: {
                        Text("修改密码")
                    }
                } footer: {
                    Text("怀疑密码被别人知道时用。改完其它设备上的登录会自动失效，你手上这台不受影响。")
                }

                Section {
                    NavigationLink {
                        WeatherLocationView()
                    } label: {
                        Text("天气城市")
                    }
                } footer: {
                    Text("服务端生成天气预报用的坐标。默认由部署时的启动参数决定。")
                }

                Section {
                    NavigationLink {
                        WipeDataView()
                    } label: {
                        Text("清空我创建的数据")
                            .foregroundStyle(Theme.red600)
                    }
                } footer: {
                    Text("删掉我自己创建的日历、日程，以及我在别人日历里的成员身份。别人的数据不受影响，账号本身也不会被删。不可撤销。")
                }

                // 只有管理员看得到这一节。非管理员也有入口的话，
                // 点进去只会看到「只有管理员能跑」——多一次白跑
                if store.user?.isAdmin ?? false {
                    Section {
                        NavigationLink {
                            DataIntegrityView()
                        } label: {
                            Text("数据自检")
                        }
                    } footer: {
                        Text("扫全库的引用完整性：日历删了但日程还在、成员行指向不存在的日历之类。列表里那种「点不开、改不动」的条目多半是这些。")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.1 (1)")
                    Text("原生 iOS 版。日程支持新建、修改、重复、提醒、强提醒、全天、待办、稍后提醒，以及周/月视图；日历支持新建、改名改色、删除；课程表日历可打开节次网格；还能处理多人同时修改产生的字段级冲突。")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                Section {
                    Button(role: .destructive) {
                        busy = true
                        Task {
                            await store.logout()
                            busy = false
                            dismiss()
                        }
                    } label: {
                        Text(busy ? "正在退出…" : "退出登录")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("忘记已信任的证书？", isPresented: $confirmingForget) {
                Button("忘记", role: .destructive) { TrustStore.forgetAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("下次连接任意服务器时都会重新记录一次证书指纹。")
            }
            .task {
                await loadConflictCount()
                await loadTeamCount()
                await loadInboxCount()
                await loadTier()
            }
        }
    }

    /// 待处理冲突数。
    ///
    /// 失败时静默保持 0：这是个「附加信息」，
    /// 为了它在设置页弹错误横幅，比少显示一个数字更烦人。
    private func loadConflictCount() async {
        let list = (try? await store.loadConflicts()) ?? []
        pendingConflicts = list.count
    }

    /// 我加入的团队数。同样失败静默保持 0。
    private func loadTeamCount() async {
        let list = (try? await store.loadTeams()) ?? []
        teamCount = list.count
    }

    /// 待处理收件箱条数。
    ///
    /// 这里传 `status: "pending"` 只拉待处理的，再本地剔掉过期和系统通知 ——
    /// 服务端不会改过期条目的 status（读操作不写库），不剔掉的话
    /// 角标上会挂着一个永远消不掉的数字。
    private func loadInboxCount() async {
        let list = (try? await store.loadInbox(status: "pending")) ?? []
        inboxCount = list.filter { $0.isPending && !$0.isStale && !$0.isSystem }.count
    }

    /// 用户组。失败静默保持 nil（行尾显示「—」）：
    /// 为了一个附加信息在设置页弹错误横幅不值得，用户点进详情页会看到真实原因。
    private func loadTier() async {
        tier = try? await store.loadTier()
    }
}
