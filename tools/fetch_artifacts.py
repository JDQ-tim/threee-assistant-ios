#!/usr/bin/env python3
"""把某次 CI run 的产物下载到 ../dist/。

## 为什么要单独写，直接 curl 不行吗

不行，有两个坑：

1. **`artifacts` 下载会 302 到 `blob.core.windows.net`，并带一个 SAS 签名。**
   如果我们照规矩把 `Authorization: Bearer <token>` 一起带过去，
   Azure 会因为「同时给了 SAS 和 Bearer」判 401。必须在跟随重定向时
   **把 Authorization 头丢掉**。urllib 默认的 `HTTPRedirectHandler`
   会把原请求头照抄，所以要自己写一个子类。

2. **产物 zip 有几 MB，走 `resp.read()` 一次性读完整容易在慢链路下超时。**
   上一次就是 200 秒到点被 SIGTERM 杀掉，文件写了一半。
   这里改成 1MB 分块流式写，并且边写边打进度。

用法：
    python tools/fetch_artifacts.py <run_id> [目标目录]
    python tools/fetch_artifacts.py <run_id> --list     # 只看有哪些产物
    python tools/fetch_artifacts.py cancel <run_id>     # 取消排队/运行中的 run
"""
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = "JDQ-tim/threee-assistant-ios"


def token() -> str:
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True
    ).strip()
    cred = url.split("://", 1)[1].split("@", 1)[0]  # user:TOKEN
    return cred.split(":", 1)[1]


class NoAuthRedir(urllib.request.HTTPRedirectHandler):
    """跟随重定向，但不把 Authorization 带过去。

    artifact 的下载地址是 302 到一个 Azure SAS URL，SAS 本身就是凭据。
    两个凭据同时出现 Azure 只认 Bearer 然后判 401 —— 报错信息是
    "Server failed to authenticate the request"，看不出是头冲突。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        n = urllib.request.Request(newurl)
        n.add_header("User-Agent", "threee-fetch")
        return n


def _opener():
    # ProxyHandler({}) = 不用系统代理。这台机器上的代理会把 github 挡成 502。
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoAuthRedir
    )


def api(method: str, path: str, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(
        "https://api.github.com" + path,
        data=data,
        headers={
            "Authorization": "Bearer " + token(),
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "threee-fetch",
        },
        method=method,
    )
    with _opener().open(r, timeout=60) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def list_artifacts(run_id: str):
    out = api("GET", f"/repos/{REPO}/actions/runs/{run_id}/artifacts")
    return out.get("artifacts", [])


def download(aid: int, name: str, dest_dir: str) -> str:
    out = os.path.join(dest_dir, name)
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/actions/artifacts/{aid}/zip",
        headers={
            "Authorization": "Bearer " + token(),
            "User-Agent": "threee-fetch",
        },
    )
    t0 = time.time()
    with _opener().open(req, timeout=120) as r, open(out, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = r.read(1 << 18)  # 256KB
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                pct = done * 100 // total
                print(f"\r  {name}: {done//1024}/{total//1024} KB  {pct}%",
                      end="", flush=True)
    print(f"\r  {name}: 完成 {os.path.getsize(out)//1024} KB "
          f"（{time.time()-t0:.1f}s）          ")
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    run_id = sys.argv[1]

    if run_id == "cancel":
        tid = sys.argv[2]
        api("POST", f"/repos/{REPO}/actions/runs/{tid}/cancel")
        print("已请求取消", tid)
        return 0

    arts = list_artifacts(run_id)
    if not arts:
        print("这次 run 没有任何产物。")
        return 1

    print(f"run {run_id} 共 {len(arts)} 个产物：")
    for a in arts:
        print(f'  {a["id"]:<12} {a["name"]:<32} '
              f'{a["size_in_bytes"]/1024:.0f} KB  expired={a["expired"]}')

    if "--list" in sys.argv:
        return 0

    dest = "../dist"
    for a in sys.argv[2:]:
        if not a.startswith("--") and a != run_id:
            dest = a
    os.makedirs(dest, exist_ok=True)

    for a in arts:
        if a["expired"]:
            print(f'  跳过 {a["name"]}（已过期）')
            continue
        try:
            download(a["id"], a["name"] + ".zip", dest)
        except Exception as e:  # noqa: BLE001
            print(f'  失败 {a["name"]}: {type(e).__name__}: {e}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
