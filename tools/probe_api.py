#!/usr/bin/env python3
"""对着真实服务端抓响应，喂给 check_dto_contract.py 做类型比对。

用法：
    python tools/probe_api.py <base_url> <token> [输出文件]

base_url 例：https://127.0.0.1:8443
只依赖标准库，不装 requests（本机没网也能跑）。

为什么要走真实服务端而不是看源码：源码里 `json:"xxx"` 的 tag 和客户端
`CodingKeys` 里的字符串是**两处独立维护**的，只读源码发现不了谁写错。
真打一次，返回什么类型是硬事实。
"""
import json
import ssl
import sys
import urllib.error
import urllib.request

# Swift 结构体名 -> (方法, 路径)
#
# 路径里可以带 query（服务端会按 hours/days 裁剪天气）。
# 端口写在路径前用 "|" 分隔：主机沿用 base_url，只换端口。
#   背词同步是**独立的 8446**，主服务 8443 上没有 /api/wordbook/*。
TARGETS = [
    ("HealthDTO", "GET", "/api/health"),
    ("BootstrapResponse", "GET", "/api/bootstrap"),
    ("CalendarsResponse", "GET", "/api/calendars"),
    ("SyncSnapshotResponse", "GET", "/api/sync/snapshot"),
    ("TierInfoDTO", "GET", "/api/tier"),
    ("UsersResponse", "GET", "/api/users"),
    ("SiteInviteDTO", "GET", "/api/invite"),
    ("ModerationMetaDTO", "GET", "/api/moderation/meta"),
    ("WeatherLocationDTO", "GET", "/api/weather/location"),
    ("CoursePeriodsResponse", "GET", "/api/course/periods"),
    # ---- 新补的功能，逐个验 ----
    ("WeatherDocDTO", "GET", "/api/weather?hours=24&days=7"),
    ("WordbookHealthDTO", "GET", "8446|/api/wordbook/health"),
    ("WordbookPullResponse", "GET", "8446|/api/wordbook/pull"),
    # ---- 需要真实 ID 的接口。占位符从快照里取（见 resolve_ids）----
    ("InboxListResponse", "GET", "/api/inbox"),
    ("TeamsResponse", "GET", "/api/teams"),
    ("TeamDetailResponse", "GET", "/api/teams/$TEAM"),
    ("TeamInvitesResponse", "GET", "/api/teams/$TEAM/invites"),
    ("CalendarInvitesResponse", "GET", "/api/calendars/$CAL/invites"),
    ("CalendarTeamSharesResponse", "GET", "/api/calendars/$CAL/teams"),
]


def fetch(base, path, token, method="GET", body=None):
    # 端口覆盖：`8446|/api/wordbook/health`
    if "|" in path:
        port, real_path = path.split("|", 1)
        scheme, _, host = base.partition("://")
        host = host.split(":")[0]
        base = f"{scheme}://{host}:{port}"
        path = real_path

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx)
    )
    try:
        with opener.open(req, timeout=25) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, {"__error__": e.read().decode(errors="replace")[:200]}
    except Exception as e:
        return 0, {"__error__": f"{type(e).__name__}: {e}"}


def resolve_ids(base, token):
    """从快照里取真实 ID，供 $CAL / $TEAM / $EVENT 占位符替换。

    不这么做的话，带 ID 的接口（邀请列表、团队详情、日历↔团队）只能跳过，
    而它们恰恰是嵌套 DTO 最容易写错的地方。
    """
    ids = {}
    st, snap = fetch(base, "/api/sync/snapshot", token)
    if st == 200 and isinstance(snap, dict):
        for key, ph in (("calendars", "$CAL"), ("events", "$EVENT"), ("instances", "$INSTANCE")):
            arr = snap.get(key) or []
            if arr and isinstance(arr[0], dict):
                ids[ph] = arr[0].get("id", "")
    st, teams = fetch(base, "/api/teams", token)
    if st == 200 and isinstance(teams, dict):
        arr = teams.get("teams") or []
        if arr and isinstance(arr[0], dict):
            ids["$TEAM"] = arr[0].get("id", "")
    return {k: v for k, v in ids.items() if v}


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("用法: probe_api.py <base_url> <token> [out.json]")
    base = sys.argv[1].rstrip("/")
    token = sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else "responses.json"

    ids = resolve_ids(base, token)
    if ids:
        print("解析到 ID：", ", ".join(f"{k}={v[:12]}" for k, v in ids.items()))
        print()

    collected = {}
    for dto, method, path in TARGETS:
        real = path
        for ph, val in ids.items():
            real = real.replace(ph, val)
        if "$" in real:
            print(f"—  {dto:24s} 跳过（缺占位符 ID）")
            continue
        status, payload = fetch(base, real, token, method)
        shown = path.replace("|", " 端口:")
        flag = "✅" if status == 200 and "__error__" not in payload else "❌"
        print(f"{flag} {dto:24s} {method} {shown:34s} HTTP:{status}")
        if status == 200 and "__error__" not in payload:
            collected[dto] = payload
        elif "__error__" in payload:
            print(f"     {payload['__error__'][:160]}")

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(collected, f, ensure_ascii=False, indent=2)
    print(f"\n已写入 {out_path}（{len(collected)} 个响应）")


if __name__ == "__main__":
    main()
