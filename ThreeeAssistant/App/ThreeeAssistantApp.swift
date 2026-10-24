import SwiftUI

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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
        }
    }
}

@MainActor
struct RootView: View {

    @Environment(SessionStore.self) private var store

    var body: some View {
        Group {
            if store.isLoggedIn {
                ScheduleView()
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
            if store.isLoggedIn {
                await store.reportDevice()
            }
        }
    }
}
