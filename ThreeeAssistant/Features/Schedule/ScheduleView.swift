import SwiftUI

struct ScheduleView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var detail: ScheduleInstance?
    @State private var showNew = false
    @State private var showSettings = false

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                weekStrip

                ScrollView {
                    if let msg = store.errorMessage {
                        ErrorBanner(message: msg)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    content
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 28)
                }
                .refreshable { await store.refresh() }
            }
            .background(Theme.background)
            .navigationTitle("日程")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.calendars.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .sheet(item: $detail) { item in
                EventDetailSheet(item: item, calendar: store.calendarsByID[item.calendarID])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showNew) {
                NewEventSheet()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - 周切换条

    private var weekStrip: some View {
        HStack(spacing: 12) {
            Button {
                Task { await store.shiftWeek(by: -7) }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceAlt)
                    .clipShape(Circle())
            }

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Text(rangeLabel)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }

            Spacer(minLength: 4)

            Button("今天") {
                Task { await store.goToday() }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surfaceAlt)
            .clipShape(Capsule())

            Button {
                Task { await store.shiftWeek(by: 7) }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceAlt)
                    .clipShape(Circle())
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var rangeLabel: String {
        let start = store.weekStart
        let end = store.weekEnd
        let cal = Calendar.current
        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        if sameMonth {
            return "\(start.monthDay) – \(cal.component(.day, from: end))日"
        }
        return "\(start.monthDay) – \(end.monthDay)"
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        let groups = store.dayGroups

        if groups.isEmpty {
            if store.isLoading {
                ProgressView("正在同步…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            } else {
                EmptyHint(
                    icon: "calendar",
                    title: "这周还没有安排",
                    subtitle: "点右上角的 + 新建一条"
                )
            }
        } else if isRegular && groups.count >= 2 {
            // iPad：分两栏。
            // ⚠️ 不是「隔一天放一栏」，而是**前半周在左、后半周在右** ——
            //    这样每栏高度接近，右边不会出现一大片空白。
            // ⚠️ 只有一天时不分栏（分了会留一个空列，比单列更难看）。
            HStack(alignment: .top, spacing: 20) {
                column(Array(groups.prefix(half(of: groups.count))))
                column(Array(groups.suffix(from: half(of: groups.count))))
            }
        } else {
            column(groups)
        }
    }

    private func half(of count: Int) -> Int {
        max(1, Int((Double(count) / 2).rounded(.up)))
    }

    private func column(_ groups: [DayGroup]) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    DayHeaderView(day: group.day)
                    ForEach(group.items) { item in
                        Button {
                            detail = item
                        } label: {
                            EventRowView(item: item, calendar: store.calendarsByID[item.calendarID])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
