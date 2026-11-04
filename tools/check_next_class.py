"""
验证实时活动「该挂哪一节」的选择逻辑（NextClassPlan.pick）。

Swift 那套在 Windows 上跑不了，所以这里用 Python 复刻同一套判断，
喂人造样本，确认**规则本身**对。复刻必须和 Swift 逐行对应，
否则测的是"我以为的规则"而不是"实际的规则"。

这是 tools/check_week_numbering.py 的同一路数：
本地先跑一遍，把明显写错的地方挡在推送之前；CI 里另有 Swift 原版
（Tests/NextClassCheck）跑真代码 —— 两边都要过才算数。

规则（与 NextClassPlan.swift 一致）：
  ① 正在上（start <= now < end），且开始至今 <= 3h  → 挂，取开始最早的
  ② 今天的课，距开始 <= 2h                          → 挂
  ③ 今天的课，距开始 >  2h                          → 不挂
  ④ 明天的课，且今天已经没有事了                    → 挂
  ⑤ 明天的课，但今天还有事                          → 不挂
  ⑥ 后天及以后                                      → 不挂

为什么要有这个文件：2026-11-04 的旧实现把 horizon(8h) 和 leadTime(30min)
用 && 串起来，于是"周六下午，下一节课在周一"这条永远返回 nil ——
而它只有在周末才会显形，真机上极难复现。
"""
from datetime import date, datetime, timedelta

LEAD_TIME = timedelta(hours=2)
ONGOING_LIMIT = timedelta(hours=3)


class Item:
    def __init__(self, eid, start, end):
        self.eid = eid
        self.start = start
        self.end = end

    def __repr__(self):
        return "Item(%s, %s-%s)" % (self.eid, self.start, self.end)


def pick(items, now):
    """返回选中的 Item，或 None。逐行对应 NextClassPlan.pick。"""
    def sday(d):
        return d.date()

    today = sday(now)
    tomorrow = today + timedelta(days=1)

    # ① 正在上的
    ongoing = [i for i in items if i.start <= now < i.end
               and now - i.start <= ONGOING_LIMIT]
    if ongoing:
        return min(ongoing, key=lambda i: i.start)

    # ② 还没开始的
    upcoming = sorted([i for i in items if i.start > now], key=lambda i: i.start)
    if not upcoming:
        return None
    nxt = upcoming[0]

    # ③ 今天的
    if sday(nxt.start) == today:
        return nxt if nxt.start - now <= LEAD_TIME else None

    # ④ 明天的：今天还有事就不挂
    if sday(nxt.start) == tomorrow:
        still_today = any(i.end > now and sday(i.start) == today for i in items)
        return None if still_today else nxt

    # ⑤ 后天及以后
    return None


# 2026-11-07 是周六
def D(month, day, hour, minute=0):
    return datetime(2026, month, day, hour, minute)


CASES = [
    # (备注, items, now, 期望命中的 eid 或 None)

    ("正在上的优先",
     [Item("a", D(11, 7, 8), D(11, 7, 10)),
      Item("b", D(11, 7, 10), D(11, 7, 12)),
      Item("c", D(11, 7, 14), D(11, 7, 16))],
     D(11, 7, 10, 30), "b"),

    ("上了 3h 以上的不再挂",
     [Item("long", D(11, 7, 8), D(11, 7, 18)),
      Item("next", D(11, 7, 14), D(11, 7, 16))],
     D(11, 7, 12, 30), "next"),

    ("正好 3h 仍算（边界含等号）",
     [Item("e", D(11, 7, 8), D(11, 7, 12))],
     D(11, 7, 11), "e"),

    ("2h 后的课要挂（含边界）",
     [Item("in2", D(11, 7, 12), D(11, 7, 14))],
     D(11, 7, 10), "in2"),

    ("2h09m 后的课还不该挂",
     [Item("in209", D(11, 7, 12, 9), D(11, 7, 14))],
     D(11, 7, 10), None),

    ("晚上 7 点的课，上午 9 点不挂",
     [Item("evening", D(11, 7, 19), D(11, 7, 21))],
     D(11, 7, 9), None),

    ("今天没课了 → 明天的课要挂",
     [Item("today", D(11, 8, 8), D(11, 8, 10)),
      Item("mon", D(11, 9, 8), D(11, 9, 9, 40))],
     D(11, 8, 21), "mon"),

    ("今天还有课 → 明天的不挂",
     [Item("today3", D(11, 8, 15), D(11, 8, 17)),
      Item("mon", D(11, 9, 8), D(11, 9, 9, 40))],
     D(11, 8, 8), None),

    ("空列表", [], D(11, 7, 10), None),

    ("今天的都上完了、明天没课",
     [Item("a", D(11, 7, 8), D(11, 7, 10))],
     D(11, 7, 22), None),

    ("周六看周一：差 40h+，不挂",
     [Item("mon", D(11, 9, 8), D(11, 9, 10))],
     D(11, 7, 10), None),

    ("凌晨不该把昨晚的课当成正在上",
     [Item("late", D(11, 7, 23), D(11, 7, 23, 50))],
     D(11, 8, 0, 30), None),

    ("跨零点且正在上 → 照挂",
     [Item("overnight", D(11, 7, 23), D(11, 8, 1))],
     D(11, 8, 0, 30), "overnight"),

    ("同一时刻两节 → 结果稳定",
     [Item("x", D(11, 7, 11), D(11, 7, 12)),
      Item("y", D(11, 7, 11), D(11, 7, 12))],
     D(11, 7, 10), "x"),
]


def main():
    bad = 0
    for note, items, now, want in CASES:
        got = pick(items, now)
        got_id = got.eid if got else None
        ok = got_id == want
        if not ok:
            bad += 1
        print("%s %-34s now=%s  算 %-8s 期望 %s"
              % ("OK  " if ok else "FAIL", note, now.strftime("%m-%d %H:%M"),
                 got_id, want))

    print("=" * 76)
    print("失败 %d 条 / 共 %d 条" % (bad, len(CASES)))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
