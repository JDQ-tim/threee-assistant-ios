import SwiftUI
import UserNotifications

/// ⚠️ `@MainActor` 标在 App 上是必需的，不是保险。
///
/// Xcode 15.4 + iOS 17.5 SDK 下，`App` 的 `body` 和属性初始化都**不在主线程域**，
/// 因此下面这句
///
///     @State private var store = SessionStore()
///
/// 会报 `call to main actor-isolated initializer 'init()' in a synchronous
/// nonisolated context` —— SessionStore 是 @MainActor 的。
/// 标上 @MainActor 后整个类型都进入主线程域，初始化与 body 一起解决。
@MainActor
@main
struct ThreeeAssistantApp: App {

    /// 全部状态挂在这一个对象上，通过 environment 下发。
    /// 用 @State 持有是 @Observable 的固定写法（不是 @StateObject，那是 ObservableObject 那套）。
    @State private var store = SessionStore()

    /// 校园数据包。
    ///
    /// 和 `SessionStore` 分开是有意的：**它不跟账号走**。
    /// 同一个手机换个人登录，装的还是同一份校园包（那本来就是"这台手机
    /// 在哪所学校"的属性，不是"谁的账号"的属性）。合成一个对象的话，
    /// 退出登录时很容易连它一起清掉，而用户看不出是自己把地图弄没了。
    @State private var navStore = NavPackStore()

    /// 实时活动（灵动岛 / 锁屏卡片）。
    ///
    /// 单独一个对象而不是塞进 SessionStore：它管的是**系统层面的一个可见物**
    /// （锁屏上挂着的那一条），生命周期和"有没有登录"不是一回事 ——
    /// 退出登录时要主动收掉它，但状态本身不该跟着账号清空。
    @State private var liveActivity = LiveActivityManager()

    init() {
        // 通知的 delegate 必须在这里设 —— 晚于第一次投递的话，
        // 那之前前台到达的提醒会被系统直接吞掉（前台默认不展示）。
        // 放在 init 里是因为它在 body 之前、且只跑一次。
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(navStore)
                .environment(liveActivity)
                .tint(Theme.accent)
        }
    }
}

@MainActor
struct RootView: View {

    @Environment(SessionStore.self) private var store
    @Environment(NavPackStore.self) private var nav
    @Environment(LiveActivityManager.self) private var live
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.isLoggedIn {
                // 重构后进入四 Tab 主框架，不再是单个日程页。
                // 原来所有功能挤在日程页右上角的 sheet 里，
                // 现在按 iOS 的信息架构拆成 日程/待办/收件箱/我的。
                MainTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.isLoggedIn)
        // 登录态变化时把周视图重置到今天那周，
        // 否则换账号后可能停在上一个账号翻到的月份，看起来像「数据没了」
        .onChange(of: store.isLoggedIn) { _, loggedIn in
            if loggedIn {
                store.weekStart = Date.now.startOfWeekMonday
                // 登录这一下也要上报一次设备（冷启动那条路走 .task，
                // 因为 restore() 在 init 里跑、onChange 不会为初始值触发）
                Task { await store.reportDevice() }
            }
        }
        // 冷启动时 store 可能已经是登录态（token 从 Keychain 恢复的），
        // 这种情况 onChange 不会触发 —— 补一条。
        //
        // ⚠️ 上报失败静默。它是纯统计用途，
        //    为了它弹错误横幅，用户会以为登录出了问题。
        .task {
            // 校园数据包在启动时读一次。它和登录态无关 ——
            // 没登录也要读（"我的"页面那一行要显示"几栋可定位"）。
            nav.loadIfNeeded()
            if store.isLoggedIn {
                await store.reportDevice()
                await store.prepareReminders()
            }
            await live.sync(instances: store.instances)
        }
        // 日程一有变化就重算"现在岛上该显示哪一节"。
        // 幂等：算出来还是同一条时只走 update，不会把活动重启一遍。
        .onChange(of: store.instances) { _, list in
            Task { await live.sync(instances: list) }
        }
        // 回到前台补排一次。
        //
        // 为什么必须有这条：iOS 只保留最多 64 条待发通知，而排出去的那些
        // 一旦触发就从队列里消失了。用户在后台待了一周再打开，
        // 如果不补排，接下来几天就是"一条提醒都不响"。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.isLoggedIn else { return }
            Task {
                await store.prepareReminders(forceRules: false)
                // 回到前台也重算一次：用户可能在别的设备上改了课表，
                // 或者上一节课已经下了（那时 staleDate 已经把它收掉了）。
                await live.sync(instances: store.instances)
            }
        }
    }
}
