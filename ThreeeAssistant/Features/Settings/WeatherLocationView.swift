import SwiftUI

/// 天气城市设置。
///
/// ## 为什么这个页面必须存在
///
/// 服务端的天气坐标原本只能靠启动参数 `-lat/-lon` 指定，改一次要重启服务。
/// 后来加了 `PUT /api/weather/location` 存进 `app_settings`，理由写在
/// `weather.go` 里：用户装在自己机器上，城市会变（放假回家、出差），
/// 让他为了改个城市去改计划任务参数是不合理的。
///
/// ## 一个必须做对的细节
///
/// **三个字段只传用户真改了的。** 服务端用 `*float64` / `*string` 接，
/// 就是为了区分「没传」和「传了 0」—— 经度 0（格林尼治）、纬度 0（赤道）
/// 都是合法坐标。如果这里「没填就当 0 发给服务端」，等于把城市挪到几内亚湾。
///
/// 所以本页的规则是：
/// - 只改名字 → 只发 `place`
/// - 只挪坐标 → 只发 `lat`/`lon`
/// - 什么都没改 → 按钮不可点
///
/// ## 谁可以改
///
/// 只有管理员（服务端 `handleSetWeatherLocation` 里验 isAdmin）。
/// 非管理员进来是**只读**的，并且明说「只有管理员能改」——
/// 不给一个点了会 403 的按钮。
@MainActor
struct WeatherLocationView: View {

    @Environment(SessionStore.self) private var store

    @State private var current: WeatherLocationDTO?
    @State private var loading = true
    @State private var loadFailure: String?

    /// 输入框的值（字符串，方便用户手打，也方便判断「有没有改过」）
    @State private var latText = ""
    @State private var lonText = ""
    @State private var placeText = ""

    @State private var saving = false
    @State private var saveFailure: String?
    @State private var saveNote: String?

    private var isAdmin: Bool { store.user?.isAdmin ?? false }

    /// 原始值的字符串形式。用来判断用户到底改没改。
    ///
    /// 不用 `Double` 比较：用户把 `24.8740` 改成 `24.874` 时数值相等，
    /// 但字符串不等 —— 这时当作「没改」是对的（服务端存 4 位小数，
    /// 两者最终都存成 24.8740）。
    private var originalLat: String { current.map { fmt($0.lat) } ?? "" }
    private var originalLon: String { current.map { fmt($0.lon) } ?? "" }
    private var originalPlace: String { current?.place ?? "" }

    private var latChanged: Bool { latText.trimmingCharacters(in: .whitespaces) != originalLat }
    private var lonChanged: Bool { lonText.trimmingCharacters(in: .whitespaces) != originalLon }
    private var placeChanged: Bool {
        placeText.trimmingCharacters(in: .whitespaces) != originalPlace
    }
    private var anyChanged: Bool { latChanged || lonChanged || placeChanged }

    /// 本地提示：只做「明显不对」的拦截，说清楚哪里不对。
    /// 服务端照样会验，那才是安全边界。
    private var localHint: String? {
        if latChanged {
            guard let v = Double(latText.trimmingCharacters(in: .whitespaces)) else {
                return "纬度要是数字，比如 24.8740"
            }
            if v < -90 || v > 90 { return "纬度要在 -90 ~ 90 之间" }
        }
        if lonChanged {
            guard let v = Double(lonText.trimmingCharacters(in: .whitespaces)) else {
                return "经度要是数字，比如 118.6757"
            }
            if v < -180 || v > 180 { return "经度要在 -180 ~ 180 之间" }
        }
        return nil
    }

    private var canSave: Bool {
        isAdmin && anyChanged && !saving && localHint == nil
    }

    var body: some View {
        Form {
            if loading {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                }
            } else if let msg = loadFailure {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.red)
                    Button("重试") { Task { await load() } }
                }
            } else {
                currentSection
                editSection

                if let msg = saveFailure {
                    Section {
                        Text(msg).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let note = saveNote {
                    Section {
                        Label(note, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.teal600)
                    }
                }
            }
        }
        .navigationTitle("天气城市")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var currentSection: some View {
        Section {
            if let c = current {
                LabeledContent("当前城市", value: c.place.isEmpty ? "—" : c.place)
                LabeledContent("坐标", value: c.coordinateText)
                LabeledContent("来源", value: c.source)
            }
        } header: {
            Text("现在用的是")
        } footer: {
            Text("「启动参数」表示由服务端启动时指定，这里改过之后会变成「应用内设置」，并优先生效。")
        }
    }

    /// ⚠️ 整个属性必须包在 `Group` 里 —— 下面有**两个** Section。
    ///
    /// `private var editSection: some View { ... }` 只有**一个**返回值。
    /// 没有 `Group` 时，第二个 `Section` 会被当成一条独立语句，
    /// 编译器于是报两件事：
    ///   · `result of 'Section<...>' initializer is unused`（第一个被丢了）
    ///   · `function declares an opaque return type, but has no return statements`
    /// 这两条一起出现，症状看着很奇怪，根因就是「一个表达式位置放了两个值」。
    /// 换成一个普通的 `var body` 不会触发（因为它是 @ViewBuilder），
    /// 但这个属性不是 —— 它是手写的 `some View`。
    private var editSection: some View {
        Group {
            Section {
                TextField("城市名，比如 泉州", text: $placeText)
                    .disabled(!isAdmin)
                TextField("纬度", text: $latText)
                    .keyboardType(.numbersAndPunctuation)
                    .disabled(!isAdmin)
                TextField("经度", text: $lonText)
                    .keyboardType(.numbersAndPunctuation)
                    .disabled(!isAdmin)
            } header: {
                Text("改")
            } footer: {
                if let hint = localHint {
                    Text(hint).foregroundStyle(.red)
                } else if !isAdmin {
                    Text("只有管理员能改天气城市。")
                } else {
                    Text("只改你动过的项：只换城市名就只填名字，只挪坐标就只改坐标。")
                }
            }

            if isAdmin {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("保存")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                } footer: {
                    if !anyChanged {
                        Text("还没有改动。")
                    }
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }

    private func load() async {
        loading = true
        loadFailure = nil
        do {
            let c = try await store.loadWeatherLocation()
            current = c
            // 回填输入框。注意是回填**服务端存的原值**，
            // 不是上一次输入 —— 否则刷新之后会看到自己没提交的草稿还在。
            latText = fmt(c.lat)
            lonText = fmt(c.lon)
            placeText = c.place
        } catch {
            loadFailure = store.message(for: error)
        }
        loading = false
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        saveFailure = nil
        saveNote = nil

        // ⚠️ 只把**用户改过的字段**放进请求。
        //    漏掉这个判断就是把「没填」当成「0」发出去，
        //    城市会被挪到赤道/本初子午线的交叉点（几内亚湾）。
        let newLat = latChanged ? Double(latText.trimmingCharacters(in: .whitespaces)) : nil
        let newLon = lonChanged ? Double(lonText.trimmingCharacters(in: .whitespaces)) : nil
        let newPlace = placeChanged ? placeText.trimmingCharacters(in: .whitespaces) : nil

        do {
            let updated = try await store.setWeatherLocation(
                lat: newLat, lon: newLon, place: newPlace
            )
            current = updated
            latText = fmt(updated.lat)
            lonText = fmt(updated.lon)
            placeText = updated.place
            saveNote = "已保存。天气预报会按新城市重新生成。"
        } catch {
            saveFailure = store.message(for: error)
        }
        saving = false
    }
}
