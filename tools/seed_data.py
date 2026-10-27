#!/usr/bin/env python3
"""往真实服务端灌一批**结构复杂**的数据，用来把契约检查压到极限。

为什么要专门灌数据：空库里只有一条 rrule 日程，像
`reminders` / `rdate` / `exdate` / `done_at` / `conflicts` / `inbox`
这些嵌套数组全是空的 —— 空数组不管字段名写错成什么都能解码成功，
等于没验。必须让每条分支都真的有数据，才可能暴露问题。

用法：
    python tools/seed_data.py <base_url> <token>
"""
import json
import ssl
import sys
import time
import urllib.error
import urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(base, path, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=CTX)
    )
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, {"__err__": e.read().decode(errors="replace")[:200]}


def main() -> None:
    base = sys.argv[1].rstrip("/")
    token = sys.argv[2]
    now = int(time.time())
    day = 86400

    st, cal = call(base, "/api/calendars", token, "POST", {"name": "复杂数据日历"})
    if st != 200:
        raise SystemExit(f"建日历失败 {st} {cal}")
    cid = cal["calendar"]["id"]
    print("日历", cid)

    # 1) 带 3 条提醒 + 重复规则 + rdate/exdate 的日程
    #    这几条分支在空库里永远走不到
    st, ev1 = call(base, "/api/events", token, "POST", {
        "calendar_id": cid,
        "title": "带提醒的周会",
        "notes": "多行备注\n第二行",
        "location": "3 楼会议室",
        "dtstart_utc": now + day,
        "duration_sec": 3600,
        "tzid": "Asia/Shanghai",
        "rrule": "FREQ=WEEKLY;COUNT=8",
        "rdate": [now + day * 2, now + day * 3],
        "exdate": [now + day * 4],
        "reminders": [
            {"minutes_before": 15, "channel": "push"},
            {"minutes_before": 5, "channel": "push"},
            {"minutes_before": 0, "channel": "sound"},
        ],
        "strong": True,
    })
    print("带提醒日程", st, ev1.get("event", {}).get("id", ev1))
    eid = ev1.get("event", {}).get("id")

    # 2) 全天事件
    st, ev2 = call(base, "/api/events", token, "POST", {
        "calendar_id": cid, "title": "全天：出差", "all_day": True,
        "dtstart_utc": now + day * 5, "duration_sec": day,
    })
    print("全天事件", st, ev2.get("event", {}).get("id", ev2))

    # 3) 已完成待办（done_at 非 null，否则这个字段永远是 null，验不出类型）
    st, ev3 = call(base, "/api/events", token, "POST", {
        "calendar_id": cid, "title": "待办：交报告", "is_task": True,
        "dtstart_utc": now + day * 6, "duration_sec": 1800,
        "done_at": now - 3600,
    })
    print("已完成待办", st, ev3.get("event", {}).get("id", ev3))

    # 4) 收件箱条目（capture）
    st, ib = call(base, "/api/inbox", token, "POST", {
        "kind": "capture", "source": "share",
        "title": "收件箱里的草稿", "notes": "从别处分享进来",
        "location": "线上", "all_day": False,
        "dtstart_utc": now + day * 7, "duration_sec": 1800,
        "remind_minutes_before": [30, 10],
        "source_excerpt": "原文片段…", "confidence": "0.82",
    })
    print("收件箱", st, str(ib)[:120])

    # 5) 稍后提醒（snooze）
    if eid:
        st, sn = call(base, f"/api/events/{eid}/snooze", token, "POST", {
            "occurrence_key": now + day, "minutes": 10, "device_id": "dev_seed",
        })
        print("snooze", st, str(sn)[:100])

    # 6) 第二个用户 + 邀请，让 members / invites / 日历团队 都有真实数据
    st, u2 = call(base, "/api/auth/register", None, "POST", {
        "invite_code": "TESTINVITE", "name": "teammate", "pass": "test1234",
    })
    print("第二用户", st, u2.get("user", {}).get("name", str(u2)[:80]))

    st, inv = call(base, f"/api/calendars/{cid}/invites", token, "POST", {
        "role": "editor", "ttl_hours": 72, "max_uses": 5,
    })
    print("日历邀请", st, str(inv)[:140])

    st, team = call(base, "/api/teams", token, "POST", {"name": "测试团队"})
    print("团队", st, str(team.get("team", team))[:120])
    tid = team.get("team", {}).get("id")
    if tid:
        st, ti = call(base, f"/api/teams/{tid}/invites", token, "POST", {
            "role": "member", "ttl_hours": 48, "max_uses": 3,
        })
        print("团队邀请", st, str(ti)[:140])
        st, sh = call(base, f"/api/calendars/{cid}/teams", token, "POST", {"team_id": tid})
        print("日历分享给团队", st, str(sh)[:120])

    # 7) 课程表（periods 非空，否则那条 DTO 也是空验）
    st, cp = call(base, "/api/course/periods", token, "PUT", {
        "periods": [
            {"index": 1, "label": "第1节", "start": "08:00", "end": "08:45"},
            {"index": 2, "label": "第2节", "start": "08:55", "end": "09:40"},
        ]
    })
    print("课程表", st, str(cp)[:120])

    # 8) 设备上报（让 devices 表有数据）
    st, dv = call(base, "/api/device/report", token, "POST", {
        "id": "dev_seed", "name": "iPhone 15", "platform": "ios", "version": "0.1 (1)",
    })
    print("设备上报", st, str(dv)[:100])

    print("\n灌数据完成")


if __name__ == "__main__":
    main()
