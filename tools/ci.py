#!/usr/bin/env python3
"""触发 / 查询 GitHub Actions 的 ios-build 工作流。

为什么单独写一个：这台机器没有 `gh`（Git Bash 里 not found），
而 `github.com:443` 被代理挡着（CONNECT 502），只有 `api.github.com:443` 通。
所以一切 GitHub 操作都得走 REST API，并且**绕开系统代理**
（urllib 默认会读 HTTP_PROXY，然后 502）。

用法：
    python tools/ci.py dispatch            # 触发 main 上的构建
    python tools/ci.py list                # 最近 5 次运行
    python tools/ci.py watch <run_id>      # 轮询到结束，打印结论
    python tools/ci.py log <run_id>        # 拉失败步骤的日志尾部
"""
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = "JDQ-tim/threee-assistant-ios"
WORKFLOW = "ios-build.yml"


def token() -> str:
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True
    ).strip()
    cred = url.split("://", 1)[1].split("@", 1)[0]  # user:TOKEN
    return cred.split(":", 1)[1]


def req(method: str, path: str, payload=None, raw: bool = False):
    data = json.dumps(payload).encode() if payload is not None else None
    # ProxyHandler({}) = 显式不用代理。少了这一句，api.github.com 也会走代理然后 502。
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    r = urllib.request.Request(
        "https://api.github.com" + path,
        data=data,
        headers={
            "Authorization": "Bearer " + token(),
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "threee-ci",
        },
        method=method,
    )
    with opener.open(r) as resp:
        body = resp.read()
        if raw:
            return body
        return json.loads(body) if body else {}


def dispatch() -> None:
    req("POST", f"/repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
        {"ref": "main"})
    print("已触发", WORKFLOW, "@main")


def list_runs(n: int = 5) -> None:
    out = req("GET", f"/repos/{REPO}/actions/workflows/{WORKFLOW}/runs?per_page={n}")
    for r in out["workflow_runs"]:
        print(f'{r["id"]}  {r["status"]:<10} {r["conclusion"] or "-":<10} '
              f'{r["created_at"]}  {r["head_sha"][:10]}')


def watch(run_id: str) -> int:
    """等到 concluded。返回 0 = success，1 = 失败，2 = 还在跑（超时）。"""
    seen = ""
    for _ in range(180):  # 最多 30 分钟
        r = req("GET", f"/repos/{REPO}/actions/runs/{run_id}")
        line = f'{r["status"]} / {r["conclusion"] or "-"}'
        if line != seen:
            print(f'[{time.strftime("%H:%M:%S")}] {line}', flush=True)
            seen = line
        if r["status"] == "completed":
            return 0 if r["conclusion"] == "success" else 1
        time.sleep(10)
    print("超时，仍在运行")
    return 2


def log(run_id: str) -> None:
    """打印失败步骤的名字 + 关键行。日志太大，只挑有信息量的。"""
    jobs = req("GET", f"/repos/{REPO}/actions/runs/{run_id}/jobs")["jobs"]
    for j in jobs:
        print(f'== job: {j["name"]}  {j["conclusion"]}')
        for s in j["steps"]:
            mark = {"success": "ok  ", "failure": "FAIL", "skipped": "skip"}.get(
                s["conclusion"] or "", "?   ")
            print(f'   {mark} {s["number"]:>2}. {s["name"]}')

    data = req("GET", f"/repos/{REPO}/actions/runs/{run_id}/logs", raw=True)
    text = data.decode("utf-8", "replace")
    pat = re.compile(r"(error:|BUILD FAILED|BUILD SUCCEEDED|解码|失败|error ")
    keep = [ln for ln in text.splitlines() if pat.search(ln)]
    print("\n== 关键行 ==")
    for ln in keep[-80:]:
        print(ln)


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "dispatch":
        dispatch()
    elif cmd == "list":
        list_runs(int(sys.argv[2]) if len(sys.argv) > 2 else 5)
    elif cmd == "watch":
        sys.exit(watch(sys.argv[2]))
    elif cmd == "log":
        log(sys.argv[2])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
