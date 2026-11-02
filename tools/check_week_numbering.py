"""
验证 WeekNumbering 的推算逻辑。

Swift 那套没法在 Windows 上跑，所以这里用 Python 复刻同一套算法，
喂**人工核对过**的样本，确认算法本身对。复刻的东西必须和 Swift 逐行对应，
否则测的是"我以为的算法"而不是"实际的算法"。

算法（与 WeekNumbering.swift 一致）：
    weekIndex = round((週一_b - 週一_a) 的秒数 / 86400 / 7) + 1
    parity    = |weekIndex| % 2 == 1 ? 单 : 双
"""
from datetime import date, timedelta


def week_index(d, anchor):
    """d 落在第几周。anchor 是第 1 周的任意一天，内部归一到周一。"""
    a = anchor - timedelta(days=anchor.weekday())          # weekday(): 周一=0
    b = d - timedelta(days=d.weekday())
    return round((b - a).days / 7) + 1


def parity(i):
    return "单" if abs(i) % 2 == 1 else "双"


CASES = [
    # (说明, 锚点, 被算的日期, 期望周次, 期望单双)
    # —— 基本情况 ——
    ("锚点当天就是第1周",            date(2026, 9, 7),  date(2026, 9, 7),   1,  "单"),
    ("锚点同周的周日仍是第1周",       date(2026, 9, 7),  date(2026, 9, 13),  1,  "单"),
    ("下一周的周一 = 第2周",          date(2026, 9, 7),  date(2026, 9, 14),  2,  "双"),
    ("第3周",                       date(2026, 9, 7),  date(2026, 9, 21),  3,  "单"),
    ("第18周（学期末）",              date(2026, 9, 7),  date(2027, 1, 4),   18, "双"),

    # —— 用户选周三当锚点（学校按上课日算）——
    # 关键：周三和第 1 周的周一必须同属第 1 周，不能差一天变成"第0周"
    ("锚点选周三，当天是第1周",       date(2026, 9, 9),  date(2026, 9, 9),   1,  "单"),
    ("锚点选周三，那周周一也是第1周",  date(2026, 9, 9),  date(2026, 9, 7),   1,  "单"),
    ("锚点选周三，下周一是第2周",      date(2026, 9, 9),  date(2026, 9, 14),  2,  "双"),

    # —— 跨年：这是最容易错的地方 ——
    # 若用 ISO 周编号(weekOfYear)，第 53 周之后会回绕到 1，算出负数或跳变。
    # 按天数算则应当连续。
    ("跨年不跳：1月1日",             date(2026, 9, 7),  date(2027, 1, 1),   17, "单"),
    ("跨年后仍是连续周次",            date(2026, 9, 7),  date(2027, 2, 22),  25, "单"),
    # ISO 周在此处会发生 52->1 的回绕，若算法错，这里必崩

    # —— 锚点之前（开学前翻日历）——
    ("锚点前一周 = 第0周",            date(2026, 9, 7),  date(2026, 8, 31),  0,  "双"),
    ("锚点前两周 = -1（单周）",       date(2026, 9, 7),  date(2026, 8, 24),  -1, "单"),
    ("锚点前四周 = -3（单周）",       date(2026, 9, 7),  date(2026, 8, 10),  -3, "单"),
    # 负数奇偶：-3 是单，-2 是双。Swift 的 -3 % 2 == -1，
    # 所以 Swift 那边必须先取绝对值 —— 这条就是在守这个。

    # —— 锚点本身落在周日（用户随手选）——
    ("锚点选周日，归到同一周",        date(2026, 9, 13), date(2026, 9, 13),  1,  "单"),
    ("锚点选周日，次日是第2周",       date(2026, 9, 13), date(2026, 9, 14),  2,  "双"),
]


def main():
    bad = 0
    for note, anchor, d, want_idx, want_par in CASES:
        got_idx = week_index(d, anchor)
        got_par = parity(got_idx)
        ok = got_idx == want_idx and got_par == want_par
        if not ok:
            bad += 1
        print("%s %-26s 锚点 %s  算 %s -> 第 %+d 周 %s周   期望 第 %+d 周 %s周"
              % ("OK  " if ok else "FAIL", note,
                 anchor.isoformat(), d.isoformat(),
                 got_idx, got_par, want_idx, want_par))

    # 交叉验算：第 N 周的周一再反算回去必须是 N（monday(ofWeek:) 的逆）
    anchor = date(2026, 9, 7)
    for n in (-3, -1, 1, 2, 8, 18, 25):
        monday = anchor - timedelta(days=anchor.weekday()) + timedelta(weeks=n - 1)
        back = week_index(monday, anchor)
        if back != n:
            bad += 1
            print("FAIL 往返: 第 %d 周的周一 %s 反算得第 %d 周" % (n, monday, back))

    print("=" * 70)
    print("失败 %d 条 / 共 %d 条（含 %d 条往返验算）"
          % (bad, len(CASES) + 7, 7))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
