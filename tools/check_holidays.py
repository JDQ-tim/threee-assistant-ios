"""验证 HolidayCalendar 的假日判定与补课映射。

Swift 那套在 Windows 上跑不了，这里用 Python 复刻同一套算法，
喂**人工核对过**的样本。复刻必须与 HolidayCalendar.swift 逐行对应，
否则测的是"我以为的算法"。

算法要点（与 Swift 一致）：
- 优先级：调休上班日 > 法定假日 > 普通
  （会出现「调休日落在假期区间内」的情况，此时按上班日算）
- 补课映射：把「这天当作周几」翻译成「同一教学周内那个星期几」
  from_monday 偏移：周一=0 周二=1 … 周日=6
  weekday 口径：周日=1 周一=2 … 周六=7，故 offset = (w + 5) % 7
- 源日子就是自己时不映射（否则自己复制自己）
"""
from datetime import date, timedelta

# ── 与 Swift 内置表保持一致的子集（只取测试要用的） ──
RULES = [
    # 2026
    ("2026-01-01", "2026-01-03", "元旦"),
    ("2026-02-15", "2026-02-22", "春节"),
    ("2026-04-04", "2026-04-06", "清明节"),
    ("2026-05-01", "2026-05-05", "劳动节"),
    ("2026-06-19", "2026-06-21", "端午节"),
    ("2026-09-25", "2026-09-27", "中秋节"),
    ("2026-10-01", "2026-10-07", "国庆节"),
    # 2027
    ("2027-01-01", "2027-01-03", "元旦"),
    ("2027-02-05", "2027-02-12", "春节"),
]

MAKEUPS = {
    # date: (name, workAs)
    "2026-01-04": ("元旦调休", None),
    "2026-02-14": ("春节调休", 6),
    "2026-02-28": ("春节调休", 6),
    "2026-05-09": ("劳动节调休", 6),
    "2026-09-20": ("中秋调休", 6),
    "2026-10-10": ("国庆调休", 4),
}


def kind(d):
    """返回 ('holiday', name) / ('makeup', name, workAs) / ('normal',)"""
    k = d.isoformat()
    if k in MAKEUPS:
        name, w = MAKEUPS[k]
        return ("makeup", name, w)
    for s, e, name in RULES:
        if s <= k <= e:
            return ("holiday", name)
    return ("normal",)


def source_day_with(d, w):
    """给定 workAs 直接算源日子，用来测边界。"""
    if w is None:
        return None
    monday = d - timedelta(days=d.weekday())
    for i in range(7):
        cand = monday + timedelta(days=i)
        cal_w = (cand.weekday() + 1) % 7 + 1
        if cal_w == w:
            return None if cand == d else cand
    return None


def source_day(d):
    """补课日要显示哪一天的日程。不补则 None。

    与 Swift 一致：在本教学周内**找 weekday == workAs 的那一天**，
    不用「从周一偏移几天」——那条路在 workAs=1（周日）时会算回周日自己。
    """
    k = d.isoformat()
    if k not in MAKEUPS:
        return None
    w = MAKEUPS[k][1]
    if w is None:
        return None
    monday = d - timedelta(days=d.weekday())      # weekday(): 周一=0
    for i in range(7):
        cand = monday + timedelta(days=i)
        # Python weekday(): 周一=0…周日=6；换算成 Calendar 口径 周日=1…周六=7
        cal_w = (cand.weekday() + 1) % 7 + 1
        if cal_w == w:
            return None if cand == d else cand
    return None


CASES = [
    # (说明, 日期, 期望 kind 首项, 期望名字)
    ("国庆当天",              date(2026, 10, 1),  "holiday", "国庆节"),
    ("国庆最后一天",           date(2026, 10, 7),  "holiday", "国庆节"),
    ("国庆前一天不是假",        date(2026, 9, 30),  "normal",  None),
    ("国庆后一天不是假",        date(2026, 10, 8),  "normal",  None),
    ("春节除夕",              date(2026, 2, 15),  "holiday", "春节"),
    ("春节最后一天",           date(2026, 2, 22),  "holiday", "春节"),
    ("普通周六",              date(2026, 3, 7),   "normal",  None),
    # —— 优先级：调休 > 假日 ——
    # 2026-02-14 在春节假期（2/15 起）之前一天，本身是调休上班日
    ("调休日优先于普通",        date(2026, 2, 14),  "makeup",  "春节调休"),
    # —— 跨年边界 ——
    ("元旦前一天",            date(2025, 12, 31), "normal",  None),
    ("元旦第一天",            date(2026, 1, 1),   "holiday", "元旦"),
    # —— 2027 ——
    ("2027 春节",            date(2027, 2, 5),   "holiday", "春节"),
    ("2027 春节后",           date(2027, 2, 13),  "normal",  None),
    # —— 表里没有的年份必须诚实返回 normal，不能瞎猜 ——
    ("2028 元旦（表里没有）",    date(2028, 1, 1),   "normal",  None),
]

MAKEUP_CASES = [
    # (说明, 补课日, 期望源日子)
    # 2026-10-10 是周六，上周三的课 → 应该是 10/7（那一周的周三）
    ("周六补周三的课", date(2026, 10, 10), date(2026, 10, 7)),
    # 2026-09-20 是周日，补周五的课（workAs=6 表示周五）
    ("周日补周五的课", date(2026, 9, 20), date(2026, 9, 18)),
    # 2026-02-14 是周六，workAs=6 = 周五 → 2/13
    ("周六补周五的课", date(2026, 2, 14), date(2026, 2, 13)),
    # 不补课的调休日 → None
    ("元旦调休不补课",  date(2026, 1, 4),  None),
    # 普通日 → None
    ("普通日无映射",    date(2026, 3, 7),  None),
]

# 边界：周日调休、而上周日的课 → 源日子就是自己，不该重复显示。
# 这条是「用哪套算法」的关键：最初写的 offset=(w+5)%7 在这里算出
# 周日自己，被"源日子就是自己"的判断吃掉，于是"周日补周五的课"
# 这种真实排法会静默失效。
SELF_MAP_CASES = [
    # (说明, 补课日, workAs, 期望)
    ("周日补周日 → 不映射", date(2026, 1, 4), 1, None),
    ("周日补周五",         date(2026, 1, 4), 6, date(2026, 1, 2)),
    ("周六补周六 → 不映射", date(2026, 1, 3), 7, None),
]


def main():
    bad = 0
    print("── 假日判定 ──")
    for note, d, want_kind, want_name in CASES:
        got = kind(d)
        ok = got[0] == want_kind and (want_name is None or (len(got) > 1 and got[1] == want_name))
        if not ok:
            bad += 1
        print("%s %-22s %s -> %s" % ("OK  " if ok else "FAIL", note,
                                     d.isoformat(), got))

    print("\n── 补课映射 ──")
    for note, d, want in MAKEUP_CASES:
        got = source_day(d)
        ok = got == want
        if not ok:
            bad += 1
        print("%s %-18s %s(%s) -> %s   期望 %s"
              % ("OK  " if ok else "FAIL", note, d.isoformat(),
                 "一二三四五六日"[d.weekday()],
                 got.isoformat() if got else None,
                 want.isoformat() if want else None))

    print("\n── 周日/周六边界（不套用内置表，直接给 workAs）──")
    for note, d, w, want in SELF_MAP_CASES:
        got = source_day_with(d, w)
        ok = got == want
        if not ok:
            bad += 1
        print("%s %-20s %s workAs=%d -> %s   期望 %s"
              % ("OK  " if ok else "FAIL", note, d.isoformat(), w,
                 got.isoformat() if got else None,
                 want.isoformat() if want else None))

    # 一致性：补课映射出的源日子必须是同一周内、且不晚于补课日
    print("\n── 映射一致性 ──")
    for d in [date(2026, 10, 10), date(2026, 9, 20), date(2026, 2, 14)]:
        src = source_day(d)
        same_week = bool(src) and (src - timedelta(days=src.weekday())) == (d - timedelta(days=d.weekday()))
        not_self = src != d
        ok = bool(same_week and not_self)
        if not ok:
            bad += 1
        print("%s %s 的源日子 %s 在同一周=%s 非自身=%s"
              % ("OK  " if ok else "FAIL", d, src, same_week, not_self))

    total = len(CASES) + len(MAKEUP_CASES) + len(SELF_MAP_CASES) + 3
    print("=" * 60)
    print("失败 %d 条 / 共 %d 条" % (bad, total))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
