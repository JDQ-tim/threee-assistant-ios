#!/usr/bin/env python3
"""把客户端会发的**写操作**真的打一遍，看哪个能用。

为什么不能只静态比对：静态只能证明"字段名对得上"，
证明不了"这个接口在这个状态下能成功"。比如权限不足、前置资源不存在、
服务端对某个值有额外校验 —— 只有真打才知道。

这只跑在**本地临时服务端**上，数据可以随便造、随便删。
⚠️ 最后一个用例是 `account/wipe`，会清空该账号数据，
   所以它用的是**专门注册的一次性账号**，不碰主账号。

用法：
    python tools/probe_writes.py <base_url> <服务端源码里的 invite_code>
"""
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
import uuid

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

results = []


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
            raw = r.read()
            try:
                return r.status, json.loads(raw or b"null")
            except json.JSONDecodeError:
                return r.status, {"__raw__": raw[:120].decode(errors="replace")}
    except urllib.error.HTTPError as e:
        return e.code, {"__err__": e.read().decode(errors="replace")[:160]}
    except Exception as e:
        return 0, {"__err__": f"{type(e).__name__}: {e}"}


def step(label, method, path, token, body=None, expect=200, note=""):
    st, payload = call(BASE, path, token, method, body)
    ok = st == expect
    results.append((ok, label, method, path, st, payload, note))
    mark = "✅" if ok else "❌"
    detail = ""
    if not ok:
        detail = "  ← " + str(payload)[:120]
    print(f"{mark} {label:22s} {method:6s} {path[:44]:46s} HTTP:{st}{detail}")
    return payload if ok else None


BASE = ""


def main() -> None:
    global BASE
    if len(sys.argv) < 3:
        raise SystemExit("用法: probe_writes.py <base_url> <invite_code>")
    BASE = sys.argv[1].rstrip("/")
    invite = sys.argv[2]
    tag = uuid.uuid4().hex[:6]

    print("=" * 78)
    print("写操作实测（本地临时服务端，数据可丢弃）")
    print("=" * 78)

    # ---------- 账号 ----------
    st, a = call(BASE, "/api/auth/register", None, "POST",
                 {"name": f"wa_{tag}", "pass": "test1234", "invite_code": invite})
    if st != 200:
        raise SystemExit(f"注册主账号失败 {st} {a}")
    tok = a["token"]
    print(f"主账号 wa_{tag} 注册成功")

    st, b = call(BASE, "/api/auth/register", None, "POST",
                 {"name": f"wb_{tag}", "pass": "test1234", "invite_code": invite})
    tok_b = b.get("token") if st == 200 else None
    uid_b = (b.get("user") or {}).get("id") if tok_b else None
    name_b = f"wb_{tag}"
    print(f"副账号 {name_b} 注册 {'成功' if tok_b else '失败'}")

    # 换一个 token 也算写操作，但 login 已在别处验过，这里只顺手过一遍
    st, _ = call(BASE, "/api/auth/login", None, "POST",
                 {"name": f"wa_{tag}", "pass": "test1234"})
    results.append((st == 200, "登录", "POST", "/api/auth/login", st, {}, ""))
    print(f"{'✅' if st == 200 else '❌'} 登录                     POST   /api/auth/login")

    # ---------- 日历 ----------
    cal = step("建日历", "POST", "/api/calendars", tok, {"name": f"日历{tag}"})
    cid = (cal or {}).get("calendar", {}).get("id")
    if not cid:
        raise SystemExit("拿不到日历 ID，后续没法继续")
    step("改日历", "PUT", f"/api/calendars/{cid}", tok, {"name": f"改名{tag}", "color": "#BA7517"})

    if uid_b:
        step("加成员", "POST", f"/api/calendars/{cid}/members", tok,
             {"user_id": uid_b, "role": "editor"})
        # ⚠️ 这里**没有**「改日历成员角色」这个用例：服务端只有
        #    DELETE /api/calendars/{id}/members/{uid}，没有 PUT。
        #    客户端也一致（SessionStore 里只有 delete），所以不是缺陷。
        #    改角色靠"移掉再加"。
        step("移除成员", "DELETE", f"/api/calendars/{cid}/members/{uid_b}", tok)

    step("设权限", "PUT", f"/api/calendars/{cid}/permissions", tok,
         {"default_role": "viewer"})

    # ---------- 日程 ----------
    ev = step("建日程", "POST", "/api/events", tok,
              {"calendar_id": cid, "title": f"日程{tag}",
               "dtstart_utc": int(time.time()) + 86400, "duration_sec": 3600})
    eid = (ev or {}).get("event", {}).get("id")

    # 举报要用**还活着**的日程，所以放在删日程之前。
    # 上一版把这条放在删除之后，服务端如实回「这条日程不存在」，不是缺陷。
    if eid:
        step("提交举报", "POST", "/api/reports", tok,
             {"target_kind": "event", "target_id": eid,
              "reason": "spam", "detail": "写操作探针"})

    if eid:
        step("改日程", "PUT", f"/api/events/{eid}", tok,
             {"calendar_id": cid, "title": f"改名{tag}", "dtstart_utc": int(time.time()) + 90000,
              "duration_sec": 1800})
        step("改这一次", "PUT", f"/api/events/{eid}/occurrence", tok,
             {"occurrence_key": int(time.time()) + 86400,
              "patch": {"title": f"单次{tag}"}})
        step("删这一次", "DELETE",
             f"/api/events/{eid}/occurrence?key={int(time.time()) + 86400}", tok)
        step("稍后提醒", "POST", f"/api/events/{eid}/snooze", tok,
             {"occurrence_key": int(time.time()) + 90000, "minutes": 10, "device_id": "dev_w"})
        step("取消稍后提醒", "DELETE", f"/api/events/{eid}/snooze?key={int(time.time()) + 90000}", tok)
        step("删日程", "DELETE", f"/api/events/{eid}", tok)

    # ---------- 收件箱 ----------
    ib = step("建收件箱", "POST", "/api/inbox", tok,
              {"kind": "capture", "source": "share", "title": f"条目{tag}",
               "dtstart_utc": int(time.time()) + 86400, "duration_sec": 1800})
    iid = (ib or {}).get("item", {}).get("id")
    if iid:
        # 服务端要的是 `action: accepted|dismissed`，不是 `decision: accept`。
        # 字段名是我第一版写错了 —— 客户端 InboxDecisionBody 里就是 action。
        step("收件箱决策", "POST", f"/api/inbox/{iid}/decision", tok,
             {"action": "dismissed", "event_id": ""})
    if iid:
        step("收件箱批量", "POST", "/api/inbox/batch", tok,
             {"ids": [iid], "action": "dismissed", "event_id": ""})

    # ---------- 团队 ----------
    tm = step("建团队", "POST", "/api/teams", tok, {"name": f"团队{tag}"})
    tid = (tm or {}).get("team", {}).get("id") or (tm or {}).get("id")
    if tid:
        ti = step("团队邀请", "POST", f"/api/teams/{tid}/invites", tok,
                  {"role": "member", "ttl_hours": 48, "max_uses": 3})
        code = ((ti or {}).get("invite") or {}).get("code")
        if code and tok_b:
            step("接受团队邀请", "POST", f"/api/team-invites/{code}/accept", tok_b, None, 200)
        if uid_b:
            step("改团队角色", "PUT", f"/api/teams/{tid}/members/{uid_b}", tok, {"role": "admin"})
        iid2 = ((ti or {}).get("invite") or {}).get("id")
        if iid2:
            step("撤销团队邀请", "DELETE", f"/api/team-invites/{iid2}", tok)
        step("日历分享给团队", "POST", f"/api/calendars/{cid}/teams", tok, {"team_id": tid})
        step("取消日历共享", "DELETE", f"/api/calendars/{cid}/teams/{tid}", tok)
        if tok_b:
            step("退出团队", "POST", f"/api/teams/{tid}/leave", tok_b, None)

    # ---------- 日历邀请 ----------
    ci = step("建日历邀请", "POST", f"/api/calendars/{cid}/invites", tok,
              {"role": "editor", "ttl_hours": 72, "max_uses": 5})
    ccode = ((ci or {}).get("invite") or {}).get("code")
    if ccode and tok_b:
        step("接受日历邀请", "POST", f"/api/invites/{ccode}/accept", tok_b, None)
    civid = ((ci or {}).get("invite") or {}).get("id")
    if civid:
        step("撤销日历邀请", "DELETE", f"/api/invites/{civid}", tok)

    # ---------- 其他 ----------
    step("改天气城市", "PUT", "/api/weather/location", tok, {"place": "厦门市"})
    step("同步推送", "POST", "/api/sync/push", tok, {"changes": []})
    # 背词同步在**独立端口 8446**，8443 上没有这组路由（会 404）。
    # 上一版打成 8443，是我的错。
    wb = BASE.rsplit(":", 1)[0] + ":8446"
    st, payload = call(wb, "/api/wordbook/push", tok, "POST", {"words": []})
    results.append((st == 200, "背词推送", "POST", ":8446/api/wordbook/push", st, payload, ""))
    print(f"{'✅' if st == 200 else '❌'} 背词推送                   POST   :8446/api/wordbook/push                 HTTP:{st}"
          + ("" if st == 200 else f"  ← {str(payload)[:110]}"))

    # 体检是 GET，不是 POST（客户端也是 get）
    step("数据体检", "GET", "/api/maintenance/scan", tok, None)
    step("去重", "POST", "/api/maintenance/dedupe", tok, {"dry": True})
    step("修复", "POST", "/api/maintenance/repair", tok, {})

    # ---------- 危险操作：只打一次性账号 ----------
    # account/wipe 会清空该账号的全部数据，所以必须用在 wb 这个一次性账号上，
    # 不能碰主账号，否则前面所有用例的产物都被清掉，后面没法复查。
    if tok_b:
        # 密码是 POST，不是 PUT
        step("改密码", "POST", "/api/password", tok_b,
             {"old_pass": "test1234", "new_pass": "test5678"})
        # confirm 要填**账号名原文**，不是布尔值。
        # 服务端刻意不做 trim：要能区分"我认真输了名字"和"我随手回车"。
        step("清空账号", "POST", "/api/account/wipe", tok_b, {"confirm": name_b})
        step("登出", "POST", "/api/auth/logout", tok_b, None)

    # ---------- 汇总 ----------
    ok = sum(1 for r in results if r[0])
    bad = len(results) - ok
    print("\n" + "=" * 78)
    print(f"共 {len(results)} 个写操作，通过 {ok}，失败 {bad}")
    if bad:
        print("\n失败清单：")
        for good, label, method, path, st, payload, _ in results:
            if not good:
                print(f"  ❌ {label:22s} {method:6s} {path}")
                print(f"     HTTP {st}  {str(payload)[:200]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
