#!/usr/bin/env python3
"""触发 / 查询 GitHub Actions 的 ios-build 工作流。

为什么单独写一个：这台机器没有 `gh`（Git Bash 里 not found），
而 `github.com:443` 被代理挡着（CONNECT 502），只有 `api.github.com:443` 通。
所以一切 GitHub 操作都得走 REST API，并且**绕开系统代理**
（urllib 默认会读 HTTP_PROXY，然后 502）。

用法：
    python tools/ci.py dispatch            # 触发 main 上的构建（macos-14）
    python tools/ci.py dispatch macos-15   # 指定镜像
    python tools/ci.py list [n]            # 最近 n 次运行
    python tools/ci.py watch <run_id>      # 轮询到结束，打印结论
    python tools/ci.py log <run_id>        # 步骤状态 + 关键行
    python tools/ci.py errors <run_id>     # 只打编译错误明细 + 步骤状态
    python tools/ci.py logs <run_id>       # 把日志 zip 解到 .ci-tmp/<run_id>/

## 为什么有 `errors` 子命令

`log` 打的是「关键行」，一条宽正则会把脚本自己的
`grep -c ': error:'` 和注释里的示例一起抓进来，真错误反被淹没。
`errors` 只认 `.swift:行:列: error:`，并额外打印每个步骤的成败 ——
因为真正的问题经常是「跑都没跑起来」（queued 卡满 15 分钟被判 cancelled），
这时候一条日志都没有，光看错误行会误判成「编译过了」。
"""
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

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
    with opener.open(r, timeout=120) as resp:
        body = resp.read()
        if raw:
            return body
        return json.loads(body) if body else {}


def dispatch(image: str = "macos-14") -> None:
    # inputs 必须和 workflow 里 `workflow_dispatch.inputs` 声明的名字完全一致，
    # 否则 422。镜像名写错不会立刻报错，而是排队到时候才判 cancelled。
    req("POST", f"/repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
        {"ref": "main", "inputs": {"builds-on": image}})
    print("已触发", WORKFLOW, "@main，镜像", image)


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


def _print_steps(run_id: str) -> None:
    jobs = req("GET", f"/repos/{REPO}/actions/runs/{run_id}/jobs")["jobs"]
    for j in jobs:
        print(f'== job: {j["name"]}  {j["conclusion"]}')
        if not j["steps"]:
            # 这种情况多半是排队超时：GitHub 连步骤容器都没起来
            print("    （没有任何步骤记录 —— 全程在排队，没拿到机器）")
        for s in j["steps"]:
            mark = {"success": "ok  ", "failure": "FAIL",
                    "skipped": "skip", "cancelled": "CANC"}.get(
                s["conclusion"] or "", "?   ")
            print(f'   {mark} {s["number"]:>2}. {s["name"]}')


def _log_zip(run_id: str) -> zipfile.ZipFile:
    data = req("GET", f"/repos/{REPO}/actions/runs/{run_id}/logs", raw=True)
    # 日志是 zip（每个步骤一个 .txt）。直接 decode 会把 zip 头当文本，
    # 结果什么都搜不到 —— 第一次做的时候就踩过一次。
    return zipfile.ZipFile(io.BytesIO(data))


def log(run_id: str) -> None:
    """步骤状态 + 一条宽正则挑出来的关键行。"""
    _print_steps(run_id)
    zf = _log_zip(run_id)
    pat = re.compile(r"(error:|BUILD FAILED|BUILD SUCCEEDED|解码|断言|失败)")
    keep = []
    for name in zf.namelist():
        if not name.endswith(".txt"):
            continue
        for ln in zf.read(name).decode("utf-8", "replace").splitlines():
            ln = re.sub(r"^\S+Z ", "", ln)  # 去掉 GitHub 加的时间戳前缀
            if pat.search(ln):
                keep.append(ln)
    print("\n== 关键行 ==")
    for ln in keep[-80:]:
        print(ln)


def errors(run_id: str) -> None:
    """只打「为什么失败」：步骤状态 + 编译错误明细。"""
    _print_steps(run_id)
    zf = _log_zip(run_id)
    hits = []
    for name in zf.namelist():
        if not name.endswith(".txt"):
            continue
        for ln in zf.read(name).decode("utf-8", "replace").splitlines():
            ln = re.sub(r"^\S+Z ", "", ln)
            if re.search(r":\s*error:|BUILD FAILED|BUILD SUCCEEDED", ln):
                hits.append((name, ln))

    # 只认真正的诊断：`.swift:行:列: error:`。
    # 还要排掉脚本自己的说明行（以 # 开头、或正文里带「格式：」的示例），
    # 否则 `# Swift 编译错误格式： /path/File.swift:12:34: error:` 会被当成真错误。
    diag = re.compile(r"\.swift:\d+:\d+: (error|warning):")

    def is_real(line: str) -> bool:
        if not diag.search(line):
            return False
        if line.lstrip().startswith("#") or "格式：" in line:
            return False
        return True

    print("\n== 编译/构建错误 ==")
    real = [(n, l) for n, l in hits if is_real(l)]
    seen = set()
    for name, ln in real:
        if ln in seen:
            continue
        seen.add(ln)
        print(f"[{name}] {ln}")
    if not real:
        # 没有带行列号的诊断，但确实 BUILD FAILED —— 这时才退回看结论行
        for name, ln in hits:
            if "BUILD FAILED" in ln or "BUILD SUCCEEDED" in ln:
                print(f"[{name}] {ln}")
    noise = len(hits) - sum(1 for _ in seen)
    if noise > 0:
        print(f"（另有 {noise} 行是脚本自身的 grep 模式/BUILD 结论行，已滤掉）")


def dump_logs(run_id: str) -> None:
    """把整个日志 zip 解到 .ci-tmp/<run_id>/，方便直接翻。"""
    out = os.path.join(".ci-tmp", str(run_id))
    os.makedirs(out, exist_ok=True)
    _log_zip(run_id).extractall(out)
    print("已解到", out)
    for n in os.listdir(out):
        print("  ", n)


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "dispatch":
        dispatch(sys.argv[2] if len(sys.argv) > 2 else "macos-14")
    elif cmd == "list":
        list_runs(int(sys.argv[2]) if len(sys.argv) > 2 else 5)
    elif cmd == "watch":
        sys.exit(watch(sys.argv[2]))
    elif cmd == "log":
        log(sys.argv[2])
    elif cmd == "errors":
        errors(sys.argv[2])
    elif cmd == "logs":
        dump_logs(sys.argv[2])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
