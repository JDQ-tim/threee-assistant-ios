import SwiftUI

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
            }
        }
    }
}
