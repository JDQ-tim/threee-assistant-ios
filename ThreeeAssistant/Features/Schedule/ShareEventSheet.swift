import SwiftUI

/// 把一条日程分享给某个人。
///
/// ## 「分享」在这里是投递快照，不是共享日历
///
/// 走的是 `POST /api/inbox`（`kind: "share"`）。对方会在收件箱里看到一条待处理，
/// 自己决定「加入我的日历」或「忽略」。
///
/// 快照的意思是：发出去的内容是**当时那一刻的副本**。之后你改了原日程，
/// 对方那份不会跟着变；你把原日历删了，对方手上那份也还在（他落成的是自己的日程）。
///
/// ## 服务端会替我们检查的三件事
///
/// 1. 我对 `origin_calendar_id` 要**有读权限** —— 判的是「我有没有资格把这条发出去」，
///    不是「对方能不能看」（对方看到的是快照，不依赖源日历权限）
/// 2. 收件人必须真实存在（否则会产生永远没人看到的幽灵条目）
/// 3. `from_user_id` / `from_name` 由服务端写，**不接受请求里的值**（否则可以伪造发件人）
///
/// 所以这里只需要挑人 + 点发送。挑人同样必须从 `GET /api/users` 点选，
/// 因为接口认的是 `user_id`，不是用户名。
struct ShareEventSheet: View {

    let instance: ScheduleInstance
    /// 详情页拉到的完整事件。有它就能把提醒时间一起带过去；没有也能发，只是不带提醒。
    let full: APIEvent?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var users: [DirectoryUser] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var sendingID: String?
    @State private var keyword = ""
    /// 已经发成功的人 —— 存 **user_id** 不存名字。
    /// 存名字的话，两个同名的人会被误判成「已发给第一个」，第二个反而点不动。
    @State private var sentIDs: [String] = []
    /// 显示用的名字（只在提示条里用，允许同名）
    @State private var sentNames: [String] = []

    private var filtered: [DirectoryUser] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        let me = store.user?.id ?? ""
        let others = users.filter { $0.id != me }
        guard !kw.isEmpty else { return others }
        return others.filter { $0.name.localizedCaseInsensitiveContains(kw) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取名单…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle("分享给同学")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(instance.title?.isEmpty == false ? instance.title! : "（无标题）")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("要分享的日程")
            }

            if !sentNames.isEmpty {
                Section {
                    Label("已发给 \(sentNames.joined(separator: "、"))", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                } footer: {
                    Text("对方会在收件箱里收到这条邀请，要他自己点「加入我的日历」才会出现在他的日历里。")
                }
            }

            if let msg = failure {
                Section {
                    ErrorBanner(message: msg)
                }
            }

            Section {
                ForEach(filtered) { u in
                    Button {
                        send(to: u)
                    } label: {
                        HStack {
                            Text(u.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                            if sendingID == u.id {
                                ProgressView().scaleEffect(0.7)
                            } else if sentIDs.contains(u.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            } else {
                                Image(systemName: "paperplane")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(sendingID != nil)
                }
            } header: {
                Text("发给谁")
            } footer: {
                Text("只能发给这个部署里已有的账号。对方不需要你已经把他加进日历 —— 这是一条独立投递，不产生任何日历权限。")
            }
        }
        .searchable(text: $keyword, prompt: "搜索用户名")
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(instance.start.monthDay)
        parts.append(instance.allDay ? "全天" : instance.start.hhmm + " – " + instance.end.hhmm)
        if let loc = instance.location, !loc.isEmpty {
            parts.append(loc)
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            users = try await store.loadDirectory()
        } catch {
            failure = store.message(for: error)
        }
        loading = false
    }

    private func send(to u: DirectoryUser) {
        guard sendingID == nil else { return }
        sendingID = u.id
        failure = nil

        // 提醒时间从完整事件里取。没有 full 就不带提醒 ——
        // 猜一个「提前 15 分钟」塞给对方，比不带更烦人。
        let reminders: [Int] = (full?.reminders ?? []).map { Int($0.minutesBefore) }

        Task {
            do {
                try await store.sendInboxItem(
                    kind: "share",
                    toUserID: u.id,
                    originCalendarID: instance.calendarID,
                    title: instance.title ?? "",
                    notes: instance.notes ?? "",
                    location: instance.location ?? "",
                    allDay: instance.allDay,
                    startUTC: instance.startUTC,
                    durationSec: instance.endUTC - instance.startUTC,
                    reminders: reminders,
                    source: "calendar"
                )
                if !sentIDs.contains(u.id) {
                    sentIDs.append(u.id)
                    sentNames.append(u.name)
                }
            } catch {
                failure = store.message(for: error)
            }
            sendingID = nil
        }
    }
}
