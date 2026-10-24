import SwiftUI

/// 背词同步状态（服务端独立端口 8446）。
///
/// ## 这一页为什么只能「查看」不能「同步」
///
/// 服务端 `wordbook_sync.go` 同步的**不是词库**，而是「每张卡的学习状态」
/// （FSRS 的 difficulty / stability / due / reps / lapses）。
/// 它明确写着不同步词库本体，理由有两层：
///
///  1. 内置词库是随包发的，两端本来就有，传一遍纯属浪费；
///  2. **用户自己导入的词库有版权问题** —— 那是他自己提供的教材数据，
///     传到服务器上性质就从「本机自用」变成「我们替他在服务器上存了一份」。
///
/// 而 iOS 版目前**没有内置背单词模块**（没有词库、没有 SRS 引擎），
/// 所以这里没有「本地学习状态」可以推上去。
///
/// 硬要摆一个「立即同步」按钮，点下去只能推一个空数组 ——
/// 那不是同步，那是装样子。这一页就老老实实做它真能做的事：
///
///  · 告诉你**服务端有没有开**这个服务（`WORDBOOK_PORT=off` 时它不启动）
///  · 告诉你**服务器上已经存了多少**（来自你其它设备的记录）
///  · 打卡轨迹 —— 这是跨设备也看得懂的东西
///
/// 将来 iOS 加了背单词模块，这一页就是现成的入口。
@MainActor
struct WordbookSyncView: View {

    @Environment(SessionStore.self) private var store

    /// 探活结果。nil = 还没探过
    @State private var health: WordbookHealthDTO?
    /// 拉回来的数据。nil = 没拉到 / 没拉过
    @State private var pull: WordbookPullResponse?
    @State private var loading = false
    /// 探活失败或拉取失败的原因
    @State private var failure: String?
    /// 是否已经探过一次（用来区分「正在探」和「探完了没服务」）
    @State private var probed = false

    var body: some View {
        Form {
            statusSection

            if let p = pull, !p.cards.isEmpty {
                overviewSection(p)
                streakSection(p)
            } else if pull != nil {
                Section {
                    Text("服务器上还没有任何学习记录。")
                        .foregroundStyle(Theme.textSecondary)
                } footer: {
                    Text("在其它装了背单词功能的客户端上学习之后，这里就会出现卡片数量和打卡记录。")
                }
            }

            explainSection

            if let failure = failure {
                Section {
                    ErrorBanner(message: failure)
                }
            }
        }
        .navigationTitle("背词同步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Text("刷新")
                    }
                }
                .disabled(loading)
            }
        }
        .task {
            if !probed { await load() }
        }
    }

    // MARK: - 服务状态

    private var statusSection: some View {
        Section {
            if loading && !probed {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在连接…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let h = health, h.ok {
                LabeledContent("状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                        Text("在线")
                    }
                }
                LabeledContent("端口", value: "\(APIClient.wordbookPort)")
                LabeledContent("服务名", value: h.service)
            } else if probed {
                LabeledContent("状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.textTertiary)
                            .frame(width: 7, height: 7)
                        Text("未开启")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        } header: {
            Text("服务")
        } footer: {
            if probed && !(health?.ok ?? false) && failure == nil {
                // 这一句很重要：不给解释的话，用户会以为 App 坏了
                Text("主服务是好的，只是背词同步这个独立服务没启动。它默认跑在 8446，服务器上用 WORDBOOK_PORT 控制；设成 off 就会关掉，没放证书时也会拒绝启动。")
            } else if health?.ok == true {
                Text("这是主服务之外的一个独立监听端口，专门给背词同步用 —— 长连接和慢查询不会挤占日程那边的连接。")
            }
        }
    }

    // MARK: - 数据概览

    private func overviewSection(_ p: WordbookPullResponse) -> some View {
        Section {
            LabeledContent("卡片", value: "\(p.cards.count) 张")
            LabeledContent("打卡记录", value: "\(p.daily.count) 天")
            LabeledContent("已复习过的", value: "\(reviewedCount(p)) 张")
            LabeledContent("待复习", value: "\(dueCount(p)) 张")
        } header: {
            Text("服务器上的记录")
        } footer: {
            Text("这些是学习**状态**，不是单词本身 —— 服务端不存词库，所以看不到具体是哪些词。")
        }
    }

    /// 复习过的 = reps > 0。new 卡（一次没学过）reps 是 0
    private func reviewedCount(_ p: WordbookPullResponse) -> Int {
        p.cards.filter { $0.reps > 0 }.count
    }

    /// 待复习 = 到期时间已过
    private func dueCount(_ p: WordbookPullResponse) -> Int {
        let now = Int64(Date.now.timeIntervalSince1970)
        return p.cards.filter { $0.reps > 0 && $0.dueAt > 0 && $0.dueAt <= now }.count
    }

    // MARK: - 打卡

    private func streakSection(_ p: WordbookPullResponse) -> some View {
        Section {
            // 最近 7 天，从旧到新。没有记录的那天显示空格子 ——
            // 直接不显示会让人以为「那天不存在」，而实际上是想说「那天没学」
            HStack(spacing: 6) {
                ForEach(lastDays(7), id: \.key) { day in
                    let n = dailyMap(p)[day.key] ?? 0
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(n > 0 ? Theme.accent : Theme.surfaceAlt)
                            .frame(height: n > 0 ? 34 : 20)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                Text(n > 0 ? "\(n)" : "")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.onAccent)
                            )
                        Text(day.label)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.vertical, 6)

            if let last = p.daily.first {
                LabeledContent("最近一次", value: last.day)
            }
        } header: {
            Text("最近 7 天")
        } footer: {
            Text("柱子上的数字是当天新学 + 复习的张数。空格子代表那天没学。")
        }
    }

    /// `["2026-10-18", ..., "2026-10-24"]`，附带「周几」或日期尾数
    private func lastDays(_ n: Int) -> [(key: String, label: String)] {
        let fmt = DateFormatter()
        // ⚠️ 必须固定成 en_US_POSIX + 固定时区：
        //    服务端的 day 是它本地时区的 YYYY-MM-DD。用设备本地日历算，
        //    跨时区时会错开一天，柱子就对不上了。
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current

        let cal = Calendar(identifier: .gregorian)
        var out: [(String, String)] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let key = fmt.string(from: d)
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "d"
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            dayFmt.timeZone = .current
            out.append((key, dayFmt.string(from: d)))
        }
        return out
    }

    /// `YYYY-MM-DD` → 当天总数
    private func dailyMap(_ p: WordbookPullResponse) -> [String: Int] {
        var m: [String: Int] = [:]
        for d in p.daily { m[d.day] = d.total }
        return m
    }

    // MARK: - 说明

    private var explainSection: some View {
        Section {
            Text("iOS 版目前没有内置背单词模块，所以这一页不提供「把本机学习记录推上去」—— 没有本地记录可推，摆一个同步按钮只是装样子。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Text("等 iOS 加了背单词之后，同步走的是逐卡比较修改时间、后写胜 —— 两台设备各学各的最后会并起来，不会互相覆盖。")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        } header: {
            Text("为什么没有「立即同步」")
        }
    }

    // MARK: - 加载

    private func load() async {
        guard !loading else { return }
        loading = true
        failure = nil
        defer { loading = false; probed = true }

        // 先探活。不探直接 pull 的话，服务没开时用户看到的是
        // 「连接超时」，会误以为整个 App 连不上服务器
        do {
            health = try await store.wordbookHealth()
        } catch {
            health = nil
            pull = nil
            failure = explain(error)
            return
        }

        do {
            pull = try await store.pullWordbook()
        } catch {
            pull = nil
            // 探活成功但拉取失败，说明是鉴权或数据问题 ——
            // 跟「服务没开」是两件事，文案要分开
            failure = store.message(for: error)
        }
    }

    /// 探活失败的文案。
    ///
    /// 这里不能直接用 `store.message(for:)`：那个文案是照着主服务的
    /// 错误格式写的，而这里最常见的情况是**端口根本没监听**（服务被关掉），
    /// 报「网络连接已中断」会让人去查 WiFi。
    private func explain(_ error: Error) -> String {
        if let e = error as? APIError {
            switch e {
            case .network:
                return "8446 端口连不上。多半是服务器上背词同步没开（WORDBOOK_PORT=off），或者防火墙只放了 8443。"
            case .certificateMismatch:
                return "8446 的证书没被这台设备信任。它和主服务共用同一张证书 —— 先在设置里「忘记已信任的服务器证书」再连一次主服务。"
            default:
                break
            }
        }
        return store.message(for: error)
    }
}
