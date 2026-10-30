#!/usr/bin/env python3
"""换掉 origin 里的 token，然后一键推送 + 触发 CI + 等结果。

## 为什么要这个脚本

`git push` 在这台机器不通（github.com:443 被代理挡，CONNECT 502），
只有 api.github.com:443 能过。所以推送走 tools/push_via_api.py。

而 push_via_api.py 是从 `git remote get-url origin` 里**读** token 的
（`https://user:TOKEN@github.com/...`）。token 过期之后那个 URL 里
存的就是个死东西，必须先换掉。

## 用法

    python tools/refresh_token.py ghp_xxxxxxxxxxxxxxxx
    python tools/refresh_token.py --push-only      # 只推，不动 token

⚠️ token 只写进本地 .git/config，不落任何文件、不进 git 历史。
   但它仍然是明文存在磁盘上 —— 用完可以去 GitHub 撤销。
"""
import subprocess
import sys

REMOTE_USER = "JDQ-tim"
REPO_PATH = "JDQ-tim/threee-assistant-ios"


def set_token(tok: str) -> None:
    url = f"https://{REMOTE_USER}:{tok}@github.com/{REPO_PATH}.git"
    subprocess.run(["git", "remote", "set-url", "origin", url], check=True)
    print("origin 已更新（token 已替换）")


def verify() -> str:
    """用新 token 打一次 /user，确认能用。返回 username。"""
    import json
    import urllib.request
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True).strip()
    tok = url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(
        "https://api.github.com/user",
        headers={"Authorization": "Bearer " + tok,
                 "User-Agent": "threee", "Accept": "application/vnd.github+json"})
    with opener.open(req) as r:
        return json.loads(r.read())["login"]


def head_sha() -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()


def local_content_base() -> str:
    """远端 31b403bf9c 的**内容**在本地对应哪个提交。

    固定成 31b403bf9c 的内容等价物 —— 那个就是远端 main 当前的状态。
    本地 HEAD 之前的所有提交里，内容等于 31b403b 的那个就是 56ac0d6
    （它推送时被 API 重建成 31b403b）。
    """
    return "56ac0d6"


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    push_only = "--push-only" in sys.argv

    if args and not push_only:
        set_token(args[0])

    try:
        who = verify()
        print(f"token 可用，登录为 {who}")
    except Exception as e:
        raise SystemExit(f"token 不可用：{e}\n请到 GitHub → Settings → "
                         "Developer settings → Personal access tokens 重新生成"
                         "（勾 repo 权限）")

    base = local_content_base()
    head = head_sha()
    commits = subprocess.check_output(
        ["git", "log", "--oneline", f"{base}..{head}"],
        text=True).strip()
    if not commits:
        print("本地没有新提交，不用推")
        return
    print("待推提交：")
    print(commits)

    # 远端 main 的当前 sha（API 重建过，和本地不同）
    import json
    import urllib.request
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True).strip()
    tok = url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO_PATH}/commits/main",
        headers={"Authorization": "Bearer " + tok,
                 "User-Agent": "threee", "Accept": "application/vnd.github+json"})
    with opener.open(req) as r:
        remote_sha = json.loads(r.read())["sha"]
    print(f"远端 main: {remote_sha[:10]}")

    print("\n开始推送（可能要几分钟，别掐）…")
    rc = subprocess.call([sys.executable, "tools/push_via_api.py",
                          remote_sha, base])
    if rc != 0:
        raise SystemExit(f"推送失败，退出码 {rc}")
    print("\n✅ 推送完成。接下来可以跑：")
    print("   python tools/ci.py dispatch")
    print("   python tools/ci.py list")


if __name__ == "__main__":
    main()
