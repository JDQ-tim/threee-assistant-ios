import SwiftUI

/// 天气预报（`GET /api/weather`）。
///
/// ## 坐标是服务器的，不是手机的
///
/// 数据由服务端按其「天气城市」配置去 met.no 取。所以这里**必须显示 `place`** ——
/// 不然人在泉州、服务器配的是北京，看到 3° 只会觉得"这预报真不准"，
/// 而实际上它报的就是北京。
///
/// ## 旧数据要明说
///
/// met.no 挂了的时候服务端会把上次那份继续端出来，同时置 `stale`。
/// 这一页在这种情况下打一条黄条写明"不是最新的"。
/// 不写的话，用户会拿一小时前（甚至六小时前）的温度当现在用。
@MainActor
struct WeatherView: View {

    @Environment(SessionStore.self) private var store

    @State private var doc: WeatherDocDTO?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Group {
            if doc == nil && loading {
                ProgressView("正在获取天气…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = doc {
                content(d)
            } else {
                unavailable
            }
        }
        .navigationTitle("天气")
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
            if doc == nil { await load() }
        }
        .refreshable { await load() }
    }

    // MARK: - 主体

    private func content(_ d: WeatherDocDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                if d.isStale {
                    staleBanner(d)
                }

                nowCard(d)

                if !d.hours.isEmpty {
                    hourlyStrip(d)
                }

                if !d.days.isEmpty {
                    dailyList(d)
                }

                footer(d)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.background)
    }

    /// 现在这一刻 = 逐时里第一个还没过去的，取不到就退回第一个。
    ///
    /// 服务端返回的第一个小时通常是"当前这一小时"，
    /// 但缓存过期边界上可能已经过去了 —— 所以还是按时间挑一下。
    private func currentHour(_ d: WeatherDocDTO) -> WeatherHourDTO? {
        let now = Int64(Date.now.timeIntervalSince1970)
        return d.hours.first { $0.time + 3600 > now } ?? d.hours.first
    }

    private func nowCard(_ d: WeatherDocDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.place.isEmpty ? "（未设置地点）" : d.place)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    if let h = currentHour(d) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(h.temp.rounded()))")
                                .font(.system(size: 64, weight: .thin, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text("°")
                                .font(.largeTitle.weight(.light))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(h.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("暂无数据")
                            .font(.appHeadline)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                if let h = currentHour(d) {
                    WeatherGlyph(symbol: h.symbol, size: 66)
                        .padding(.top, 8)
                }
            }

            if let h = currentHour(d) {
                Divider().padding(.vertical, 12)
                HStack(spacing: 18) {
                    statItem(icon: "humidity.fill", label: "湿度", value: "\(Int(h.humidity.rounded()))%")
                    statItem(icon: "wind", label: "风速", value: String(format: "%.1f m/s", h.wind))
                    statItem(icon: "drop.fill", label: "降水", value: String(format: "%.1f mm", h.precip))
                }
            }
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.appCaption2)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(Theme.textTertiary)

            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - 逐时

    private func hourlyStrip(_ d: WeatherDocDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未来 24 小时")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(d.hours.prefix(24).enumerated()), id: \.element.id) { idx, h in
                        VStack(spacing: 6) {
                            Text(idx == 0 ? "现在" : hourText(h.time))
                                .font(.appCaption2)
                                .foregroundStyle(idx == 0 ? Theme.accent : Theme.textTertiary)

                            WeatherGlyph(symbol: h.symbol, size: 20)

                            Text("\(Int(h.temp.rounded()))°")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(width: 46)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 6)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
        }
    }

    // MARK: - 逐日

    private func dailyList(_ d: WeatherDocDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未来几天")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(Array(d.days.enumerated()), id: \.element.id) { idx, day in
                    HStack(spacing: 12) {
                        Text(dayName(day.date, index: idx))
                            .font(.appFootnote)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 52, alignment: .leading)

                        WeatherGlyph(symbol: day.symbol, size: 18)

                        Text(day.label)
                            .font(.appCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if day.precipSum > 0.05 {
                            Text(String(format: "%.1f", day.precipSum))
                                .font(.appCaption2)
                                .foregroundStyle(Theme.accent)
                        }

                        // 温度条：用当日最低/最高在整段区间里的位置画一小段
                        Text("\(Int(day.tempMin.rounded()))°")
                            .font(.appCaption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 26, alignment: .trailing)
                        Text("\(Int(day.tempMax.rounded()))°")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 26, alignment: .trailing)
                    }
                    .padding(.vertical, 9)

                    if idx != d.days.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }

    // MARK: - 旧数据提示

    private func staleBanner(_ d: WeatherDocDTO) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appCaption)
                .foregroundStyle(Theme.red600)
            VStack(alignment: .leading, spacing: 2) {
                Text("不是最新数据")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                // 服务端给的 note 就是给人看的一句话，直接用
                Text(d.note ?? "上游暂时取不到，显示的是上一次成功获取的预报。")
                    .font(.appCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Theme.red600.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    // MARK: - 数据来源

    private func footer(_ d: WeatherDocDTO) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("数据来源：\(sourceName(d.source))")
            Text("更新时间：\(fullTime(d.updatedAt))")
            if d.note != nil && !d.isStale {
                // 不 stale 但有 note，说明是"换了备选源"这类提示
                Text(d.note ?? "")
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("地点由服务器的「天气城市」设置决定，不是手机定位。")
        }
        .font(.appCaption2)
        .foregroundStyle(Theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    private func sourceName(_ s: String) -> String {
        switch s {
        case "met.no": return "挪威气象局 met.no"
        case "open-meteo": return "Open-Meteo（备选源）"
        case "none": return "无（暂时取不到）"
        default: return s.isEmpty ? "未知" : s
        }
    }

    // MARK: - 取不到

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud.slash")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("暂时取不到天气")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            if let failure = failure {
                Text(failure)
                    .font(.appCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }
            Button("重试") {
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .disabled(loading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - 格式化

    private func hourText(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "H时"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private func fullTime(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// `YYYY-MM-DD` → 「今天」/「明天」/「周三」
    private func dayName(_ date: String, index: Int) -> String {
        // 服务端按日期顺序给，第 0 天就是今天
        if index == 0 { return "今天" }
        if index == 1 { return "明天" }

        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        guard let d = inFmt.date(from: date) else { return date }

        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "zh_CN")
        outFmt.dateFormat = "EEE"
        return outFmt.string(from: d)
    }

    // MARK: - 加载

    private func load() async {
        guard !loading else { return }
        loading = true
        failure = nil
        do {
            doc = try await store.loadWeather()
        } catch {
            // 已经有数据时不要清空 —— 刷新失败不该让屏幕变成空白
            failure = store.message(for: error)
        }
        loading = false
    }
}

// MARK: - 天气图标

/// met.no 的 symbol → SF Symbols。
///
/// ## 为什么要单独一个类型
///
/// 映射规则有三层：先去掉 `_day`/`_night`/`_polartwilight` 后缀，
/// 再查表，最后还要看白天黑夜决定用太阳还是月亮。
/// 三段逻辑塞进视图里会把 `body` 撑成一团 —— 而且天气图标在
/// 逐时和逐日两处都要用，抽出来也只写一遍。
///
/// ## 不认识的符号怎么办
///
/// 返回 `cloud.fill` 而不是问号方块。met.no 会新增代码，
/// 到时显示一个"云"总比一个破图标强 —— 更何况旁边的文字
/// （服务端翻好的 label）本来就是准的。
@MainActor
struct WeatherGlyph: View {
    let symbol: String
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: WeatherGlyph.sfSymbol(for: symbol))
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size + 6, height: size + 6)
    }

    /// 有太阳/月亮的时候用暖色，下雨下雪用蓝灰
    private var tint: Color {
        let base = WeatherGlyph.base(symbol)
        if base.contains("clearsky") || base.contains("fair") {
            return symbol.hasSuffix("_night") ? Theme.textSecondary : .orange
        }
        if base.contains("rain") || base.contains("sleet") {
            return .blue
        }
        if base.contains("snow") {
            return .cyan
        }
        if base.contains("thunder") {
            return .yellow
        }
        return Theme.textSecondary
    }

    static func base(_ raw: String) -> String {
        var s = raw
        for suffix in ["_day", "_night", "_polartwilight"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s
    }

    static func sfSymbol(for raw: String) -> String {
        let b = base(raw)
        let night = raw.hasSuffix("_night") || raw.hasSuffix("_polartwilight")

        switch b {
        case "clearsky":
            return night ? "moon.stars.fill" : "sun.max.fill"
        case "fair":
            return night ? "cloud.moon.fill" : "sun.min.fill"
        case "partlycloudy":
            return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "cloudy":
            return "cloud.fill"
        case "fog":
            return "cloud.fog.fill"
        case "lightrain", "lightrainshowers":
            return "cloud.drizzle.fill"
        case "rain", "rainshowers":
            return "cloud.rain.fill"
        case "heavyrain", "heavyrainshowers":
            return "cloud.heavyrain.fill"
        case "lightsleet", "sleet", "heavysleet",
             "lightsleetandthunder", "sleetandthunder", "heavysleetandthunder":
            return "cloud.sleet.fill"
        case "lightsnow", "lightsnowshowers":
            return "cloud.snow.fill"
        case "snow", "snowshowers":
            return "cloud.snow.fill"
        case "heavysnow", "heavysnowshowers":
            return "snowflake"
        case "rainandthunder", "lightrainandthunder", "heavyrainandthunder",
             "rainshowersandthunder", "heavyrainshowersandthunder":
            return "cloud.bolt.rain.fill"
        case "snowandthunder", "lightsnowandthunder", "heavysnowandthunder":
            return "cloud.bolt.fill"
        default:
            return "cloud.fill"
        }
    }
}
