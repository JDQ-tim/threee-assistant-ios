import SwiftUI

/// 课程表页面。
///
/// ## 为什么单独做一个页面，而不是给主日程页加个「课表模式」
///
/// 两者是**完全不同的读法**：
/// - 日程页回答「今天/这周我有什么安排」，按时间线铺开
/// - 课表回答「周三下午第几节有课」，一眼看整周的课表结构
///
/// 把课表塞进日程页的模式切换里，会让那个 Picker 变成「周/月/课表」三选一，
/// 而课表本身也需要周切换 —— 两套翻页逻辑叠在一起没法用。
///
/// ## 数据来源
///
/// 全部复用 `store.instances`（当前周的实例），再按 `calendarID` 过滤出
/// 这张课程表日历的课。不需要任何新接口。
struct CourseTableView: View {

    /// 要显示的课程表日历（`kind == "course"`）
    let calendar: CalendarDTO

    @Environment(SessionStore.self) private var store

    @State private var periods: [CoursePeriod] = CourseDefaults.periods
    @State private var weekStart: Date = Date.now.startOfWeekMonday
    @State private var loading = true

    /// 点某节课 → 打开详情
    @State private var detail: ScheduleInstance?

    /// 这张表上的课
    private var courses: [ScheduleInstance] {
        store.instances.filter { $0.calendarID == calendar.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            weekBar

            if loading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if courses.isEmpty {
                emptyState
            } else {
                CourseGridView(
                    instances: courses,
                    periods: periods,
                    weekStart: weekStart,
                    colorHex: calendar.displayColor
                ) { item in
                    detail = item
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(calendar.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 节次表是全局配置，服务端 PUT 要求管理员；非管理员不显示入口，
            // 免得点了才在服务端吃 403。
            if store.user?.isAdmin ?? false {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CoursePeriodsEditorView()
                    } label: {
                        Image(systemName: "clock.badge.checkmark")
                    }
                    .accessibilityLabel("编辑节次时间")
                }
            }
        }
        .sheet(item: $detail) { item in
            EventDetailSheet(item: item, calendar: calendar)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            periods = await store.loadCoursePeriods()
            loading = false
        }
    }

    // MARK: - 周切换

    private var weekBar: some View {
        HStack(spacing: 10) {
            Button {
                weekStart = weekStart.addingDays(-7)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 1) {
                Text(weekLabel)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)

            Button {
                weekStart = Date.now.startOfWeekMonday
            } label: {
                Text("本周")
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceAlt)
                    .foregroundStyle(Theme.textSecondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                weekStart = weekStart.addingDays(7)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 「10月20日 – 10月26日」
    private var weekLabel: String {
        let end = weekStart.addingDays(6)
        return weekStart.monthDay + " – " + end.monthDay
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("这周还没有课")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("在「日程」页点右上角 + 新建，日历选「\(calendar.name)」，就会自动落到课表格子里。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
