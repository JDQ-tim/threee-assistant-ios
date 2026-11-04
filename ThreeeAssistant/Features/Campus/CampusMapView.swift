import MapKit
import SwiftUI

// ============================================================
//  校园地图
//  ------------------------------------------------------------
//  这是「导航数据包」在 iOS 上的落点。
//
//  ## 和安卓端最大的差别：不用腾讯地图
//
//  安卓端的导航插件是一整套：腾讯 LBS 的 Key、WebView 里的 JS 地图、
//  自己实现的 3D 楼块。iOS 有 MapKit，这些全都不需要 ——
//  楼栋坐标是标准经纬度，直接喂给系统地图就行。
//
//  于是**零 Key、零 WebView、零第三方 SDK**，也就不用问用户要腾讯的授权。
// ============================================================

@MainActor
struct CampusMapView: View {

    /// 从日程点进来时带上那条日程的地点原文（「明德楼B1 302」）。
    /// 有值时进页面就直接定位到认出来的那栋楼，并把房号显示出来。
    var focusText: String? = nil

    @Environment(NavPackStore.self) private var nav

    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: NavBuilding?
    @State private var showList = false
    @State private var didFit = false

    /// 地点原文的解析结果（可能认不出）。
    private var focus: NavSplit? {
        guard let t = focusText, !t.isEmpty else { return nil }
        return nav.split(t)
    }

    private var highlightedID: String? { focus?.building?.id }

    /// 能画到地图上的楼。
    ///
    /// ⚠️ 先 compactMap 成"坐标非空"的小结构，而不是在 `Map { }` 里写
    ///    `if let c = b.coordinate` —— `MapContentBuilder` 对 `if` 的支持
    ///    随 SDK 版本有过变化，而这里的代价只是多一个类型。
    private var pins: [NavPin] {
        nav.mappableBuildings.compactMap { b in
            guard let c = b.coordinate else { return nil }
            return NavPin(building: b, coordinate: c)
        }
    }

    var body: some View {
        Group {
            if nav.hasActivePack {
                mapBody
            } else {
                noPackBody
            }
        }
        .navigationTitle("校园地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if nav.hasActivePack {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showList = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("楼栋列表")
                }
            }
        }
        // ⚠️ 两个 sheet 挂在**不同层级**上。
        //    同一个视图挂两个 `.sheet` 在旧系统上只有最后那个生效 ——
        //    表现是"点列表没反应"，而且不报任何错。
        .sheet(isPresented: $showList) {
            BuildingListSheet { b in
                showList = false
                // 关掉 sheet 和移动镜头是两件事，排一下队，
                // 否则镜头会在 sheet 还盖着的时候动，用户看不到
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    selected = b
                    flyTo(b)
                }
            }
        }
        .onAppear { nav.loadIfNeeded() }
        .task { fitIfNeeded() }
    }

    // MARK: - 地图

    private var mapBody: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                ForEach(pins) { pin in
                    // ⚠️ 用 Button 而不是 Map 的 selection 绑定。
                    //    selection 那套要 `Map(selection:)` + `.tag()`，
                    //    API 在不同 SDK 版本上细节不一致；Button 是最稳的，
                    //    而且天然有无障碍语义（读屏会读出楼名）。
                    Annotation(pin.building.name, coordinate: pin.coordinate) {
                        Button {
                            selected = pin.building
                        } label: {
                            BuildingPin(
                                name: pin.building.name,
                                isFocus: pin.building.id == highlightedID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .sheet(item: $selected) { b in
                NavigationStack {
                    BuildingDetailSheet(
                        building: b,
                        room: focus?.building?.id == b.id ? focus?.room ?? "" : ""
                    )
                }
            }

            focusBanner
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    /// 顶部那条"我从你的日程里认出了这栋楼"的说明。
    ///
    /// 为什么必须有：用户是从某条日程点进来的，他心里有一个预期
    /// （"应该跳到明德楼"）。跳到了却不说明，他会怀疑"是不是跳错了"。
    @ViewBuilder
    private var focusBanner: some View {
        if let t = focusText, !t.isEmpty, let f = focus {
            VStack(alignment: .leading, spacing: 4) {
                if let b = f.building {
                    HStack(spacing: 6) {
                        Image(systemName: f.fuzzy ? "questionmark.circle.fill" : "mappin.circle.fill")
                            .foregroundStyle(f.fuzzy ? Theme.amber600 : Theme.teal600)
                        Text(b.name)
                            .font(.appHeadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    Text(subtitleLine(f))
                        .font(.appCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.slash")
                            .foregroundStyle(Theme.amber600)
                        Text("认不出这个地点")
                            .font(.appHeadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    Text(nav.missReason(t))
                        .font(.appCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    private func subtitleLine(_ f: NavSplit) -> String {
        var parts: [String] = []
        if !f.room.isEmpty { parts.append("教室 \(f.room)") }
        if f.fuzzy { parts.append("模糊匹配，可能会出错") }
        parts.append("你写的是：\(focusText ?? "")")
        return parts.joined(separator: " · ")
    }

    // MARK: - 没装包

    private var noPackBody: some View {
        VStack(spacing: 16) {
            EmptyHint(
                icon: "map",
                title: "还没有校园数据包",
                subtitle: "导入一份之后，日程里写的「明德楼B1 302」就能直接在地图上找到了"
            )
            NavigationLink {
                NavPackView()
            } label: {
                Text("去导入")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: - 镜头

    private func fitIfNeeded() {
        guard !didFit else { return }
        didFit = true

        // 从日程点进来：优先对准那栋楼
        if let b = focus?.building, let c = b.coordinate {
            camera = .region(MKCoordinateRegion(
                center: c,
                span: MKCoordinateSpan(latitudeDelta: 0.0035, longitudeDelta: 0.0035)
            ))
            return
        }
        if let box = nav.activePack?.bounds {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: box.centerLat, longitude: box.centerLng),
                span: MKCoordinateSpan(latitudeDelta: box.spanLat, longitudeDelta: box.spanLng)
            ))
        }
    }

    private func flyTo(_ b: NavBuilding) {
        guard let c = b.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            camera = .region(MKCoordinateRegion(
                center: c,
                span: MKCoordinateSpan(latitudeDelta: 0.0035, longitudeDelta: 0.0035)
            ))
        }
    }
}

// MARK: - 地图上的图钉

/// 一个**能画到地图上**的楼（坐标保证非空）。
///
/// 存在的理由：`Map { }` 的内容构建器里不想写 `if let` ——
/// 见 `CampusMapView.pins` 的注释。
private struct NavPin: Identifiable {
    let building: NavBuilding
    let coordinate: CLLocationCoordinate2D
    var id: String { building.id }
}

@MainActor
private struct BuildingPin: View {
    let name: String
    let isFocus: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocus ? .white : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isFocus ? Theme.teal600 : Theme.surface)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(
                        isFocus ? Theme.teal600 : Theme.separator,
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)

            Image(systemName: "triangle.fill")
                .font(.system(size: 7))
                .rotationEffect(.degrees(180))
                .foregroundStyle(isFocus ? Theme.teal600 : Theme.surface)
                .offset(y: -2)
        }
    }
}

// MARK: - 楼栋列表

@MainActor
private struct BuildingListSheet: View {

    let onPick: (NavBuilding) -> Void

    @Environment(NavPackStore.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var filtered: [NavBuilding] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nav.mappableBuildings }
        let n = NavText.norm(q)
        return nav.mappableBuildings.filter { b in
            b.name.contains(q) || b.keys.contains { NavText.norm($0).contains(n) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Text("没有匹配的楼栋")
                        .font(.appSubheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(filtered) { b in
                        Button {
                            onPick(b)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(b.name)
                                    .font(.appBody)
                                    .foregroundStyle(Theme.textPrimary)
                                let sub = [typeLabel(b.type), b.subtitle]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · ")
                                if !sub.isEmpty {
                                    Text(sub)
                                        .font(.appCaption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(nav.mappableBuildings.count) 栋楼")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "楼名或别名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 楼栋详情

@MainActor
private struct BuildingDetailSheet: View {

    let building: NavBuilding
    /// 从日程地点里拆出来的房号（「302」）。有值时楼层图会把它标出来。
    let room: String

    @Environment(\.dismiss) private var dismiss

    @State private var floorIndex = 0

    private var floors: [NavFloor] { building.floors }

    private var currentFloor: NavFloor? {
        guard floors.indices.contains(floorIndex) else { return nil }
        return floors[floorIndex]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                header

                if !room.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "door.left.hand.open")
                            .foregroundStyle(Theme.teal600)
                        Text("日程里写的教室是「\(room)」")
                            .font(.appSubheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.teal50)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                }

                if !building.floors.isEmpty {
                    floorSection
                } else {
                    Text("这栋楼在标注包里没有分层数据，所以看不到房间位置。导航到楼门口就够了 —— 楼里会有指示牌。")
                        .font(.appFootnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    openInMaps()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        Text("用地图走过去")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }

                Text("会打开系统地图，按步行路线导航到这栋楼。最后几十米（几楼、哪间教室）靠楼里的指示牌。")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle(building.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(building.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !building.type.isEmpty {
                    PillView(text: typeLabel(building.type), tone: .accent)
                }
            }
            let sub = building.subtitle
            if !sub.isEmpty {
                Text(sub)
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(building.hasCoord
                 ? "坐标 \(String(format: "%.5f", building.lat)), \(String(format: "%.5f", building.lng))"
                 : "这栋楼在包里还没标坐标 —— 只能看到名字，导不了航")
                .font(.appCaption)
                .foregroundStyle(building.hasCoord ? Theme.textTertiary : Theme.amber600)
        }
    }

    @ViewBuilder
    private var floorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("楼层")
                    .font(.appHeadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(floors.count) 层 · \(floors.reduce(0) { $0 + $1.rooms.count }) 间")
                    .font(.appCaption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if floors.count > 1 {
                // 楼层用分段控件而不是 TabView：楼层之间要来回切，
                // 分页手势在 ScrollView 里会和外层滚动打架
                Picker("楼层", selection: $floorIndex) {
                    ForEach(Array(floors.enumerated()), id: \.offset) { i, f in
                        Text(f.name).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let f = currentFloor {
                // 房号直接当高亮词传下去：楼层图里的判据是"相等或包含"，
                // 于是「302」能标出「A302」—— 而标注台里这两种写法都有人用。
                FloorPlanView(floor: f, highlight: room)
                    .frame(height: 260)
            }
        }
    }

    private func openInMaps() {
        guard let c = building.coordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = building.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }
}

// MARK: - 分层俯视图

/// 一层的房间排布。
///
/// ## 坐标系
///
/// 房间坐标是**归一化偏移**：以楼栋中心为原点，`x` 向右为正、`y` 向下为正，
/// 范围 -0.5 ~ +0.5，外墙就是 [-0.5, 0.5] 这个方框。
/// 所以这里要做的就是把这个方框映射到实际像素框里。
///
/// ## 为什么不做缩放/拖拽
///
/// 一个正常的教学楼一层有十几间房，260pt 高的框里能看清。
/// 加缩放会让"这个房间在哪"变成一个需要操作才能回答的问题 ——
/// 而这个图的目的恰恰是"一眼看出"。
@MainActor
private struct FloorPlanView: View {

    let floor: NavFloor
    let highlight: String

    /// 房间类型的底色。语义色，不是装饰 ——
    /// 用户扫一眼就该知道哪块是厕所、哪块是楼梯。
    private func fill(_ type: String) -> Color {
        switch type {
        case "classroom": return Theme.blue50
        case "lecture": return Theme.teal50
        case "lab": return Theme.amber50
        case "office": return Theme.surfaceAlt
        case "toilet": return Theme.red50
        case "stairs": return Theme.surfaceAlt
        default: return Theme.surfaceAlt
        }
    }

    private func stroke(_ type: String) -> Color {
        switch type {
        case "classroom": return Theme.blue600
        case "lecture": return Theme.teal600
        case "lab": return Theme.amber600
        case "toilet": return Theme.red600
        default: return Theme.separator
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ox = (geo.size.width - side) / 2
            let oy = (geo.size.height - side) / 2

            ZStack(alignment: .topLeading) {
                // 楼的外墙
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.textTertiary.opacity(0.45), lineWidth: 1.5)
                    }
                    .frame(width: side, height: side)
                    .offset(x: ox, y: oy)

                ForEach(floor.rooms) { r in
                    let isHit = !highlight.isEmpty && (r.name == highlight || r.name.contains(highlight))
                    let w = max(18, CGFloat(r.w) * side)
                    let h = max(16, CGFloat(r.h) * side)
                    let px = ox + side / 2 + CGFloat(r.x) * side
                    let py = oy + side / 2 + CGFloat(r.y) * side

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fill(r.type))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(isHit ? Theme.red600 : stroke(r.type),
                                        lineWidth: isHit ? 2.5 : 0.6)
                        }
                        .frame(width: w, height: h)
                        .overlay {
                            Text(r.name)
                                .font(.system(size: min(11, max(7, w / 4)), weight: isHit ? .bold : .regular))
                                .foregroundStyle(isHit ? Theme.red600 : Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                        }
                        .position(x: px, y: py)
                }
            }
        }
        .accessibilityLabel("\(floor.name) 平面图，共 \(floor.rooms.count) 间")
    }
}

// MARK: - 小工具

/// 楼栋分类的中文名。未知值**原样显示** —— 抹成"其他"会让
/// 「图书馆」和真正的"其他"分不开，而标注台随时可能加新分类。
private func typeLabel(_ raw: String) -> String {
    switch raw {
    case "": return ""
    case "teaching": return "教学楼"
    case "dorm": return "宿舍"
    case "canteen": return "食堂"
    case "library": return "图书馆"
    case "office": return "办公楼"
    case "gym": return "体育馆"
    case "lab": return "实验楼"
    case "gate": return "校门"
    case "other": return "其他"
    default: return raw
    }
}
