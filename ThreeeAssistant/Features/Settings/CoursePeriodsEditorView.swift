import SwiftUI

/// 编辑课程表的节次表。
///
/// ## 为什么这是一个「全局」设置，而不是每张课表一份
///
/// 服务端把节次表存在 `app_settings.course_periods` 里（见 `course.go`），
/// **全体客户端共享**：不管是学生还是老师，看到的第 3 节都必须是同一个时间段，
/// 否则两个人对「周三第 3 节」的理解会不一样。
///
/// 所以这里没有「这张课表的节次」，只有「这套节次」，一次改动影响所有人。
/// 也正因为如此，`PUT /api/course/periods` 在 2026-10-16 补了 `requireAdmin`
/// —— 普通成员进不来这个页面，UI 上也只对管理员露出入口。
///
/// ## 时间为什么用文本框而不是 DatePicker
///
/// 节次只关心钟点，不关心日期。`DatePicker` 会带出年月日，
/// 而且要拆出 "HH:MM" 还得过一次 formatter，反而更容易在时区上出错。
/// 直接让用户填 `08:00`，存什么发什么，最好核对。
/// 服务端校验 `time.Parse("15:04")`，所以必须是两位补零的 24 小时制。
@MainActor
struct CoursePeriodsEditorView: View {

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [CoursePeriod] = []
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?

    /// 服务端限制 1~20 节
    private static let maxPeriods = 20

    var body: some View {
        Form {
            if loading {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在读取节次表…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Section {
                    ForEach($rows) { $row in
                        periodRow($row)
                    }
                    .onDelete { offsets in
                        rows.remove(atOffsets: offsets)
                        renumber()
                    }
                } header: {
                    Text("节次")
                } footer: {
                    Text("时间按 24 小时制填，比如 08:00。结束时间要晚于开始时间。改这里的行布局，所有用课程表的人都跟着变。")
                }

                Section {
                    Button {
                        addRow()
                    } label: {
                        Label("增加一节", systemImage: "plus.circle")
                    }
                    .disabled(rows.count >= Self.maxPeriods)

                    Button {
                        rows = CourseDefaults.periods
                    } label: {
                        Label("恢复默认的 10 节", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("最多 \(Self.maxPeriods) 节。默认是常见的大学作息：上午 4 节、下午 4 节、晚上 2 节。")
                }

                if let message = failure {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving {
                                ProgressView()
                            } else {
                                Text("保存")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(saving || rows.isEmpty)
                }
            }
        }
        .navigationTitle("节次时间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 行

    @ViewBuilder
    private func periodRow(_ row: Binding<CoursePeriod>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("第 \(row.wrappedValue.index) 节")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 56, alignment: .leading)

                TextField("名称", text: row.label)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("时间")
                    .font(.appFootnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 56, alignment: .leading)

                TextField("08:00", text: row.start)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 88)

                Text("–")
                    .foregroundStyle(Theme.textTertiary)

                TextField("08:45", text: row.end)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 88)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数据

    private func load() async {
        rows = await store.loadCoursePeriods()
        loading = false
    }

    private func addRow() {
        guard rows.count < Self.maxPeriods else { return }

        // 下一节的开始时间 = 上一节结束 + 10 分钟课间，收尾兜在 21:00 以内。
        // 算不出来（上一节格式坏了）就留空，让用户自己填 —— 猜一个错的比留空更糟。
        var start = ""
        var end = ""
        if let last = rows.last, let endMinutes = Self.minutes(last.end) {
            let nextStart = min(endMinutes + 10, 23 * 60 + 30)
            start = Self.clock(nextStart)
            end = Self.clock(min(nextStart + 45, 23 * 60 + 59))
        }
        rows.append(CoursePeriod(
            index: rows.count + 1,
            label: "第 \(rows.count + 1) 节",
            start: start,
            end: end
        ))
    }

    /// 删掉中间一节之后把序号重排成 1..n，名称里还留着旧序号的顺手改掉。
    private func renumber() {
        for i in rows.indices {
            let old = rows[i].index
            let new = i + 1
            rows[i].index = new
            if rows[i].label == "第\(old)节" || rows[i].label == "第 \(old) 节" {
                rows[i].label = "第 \(new) 节"
            }
        }
    }

    private func save() async {
        failure = nil
        saving = true
        defer { saving = false }
        do {
            try await store.saveCoursePeriods(rows)
            dismiss()
        } catch {
            failure = store.message(for: error)
        }
    }

    // MARK: - 时间工具

    /// "08:00" → 480
    static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h < 24, m >= 0, m < 60 else {
            return nil
        }
        return h * 60 + m
    }

    /// 480 → "08:00"（必须补零，服务端按字符串比大小）
    static func clock(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%02d:%02d", h, m)
    }
}
