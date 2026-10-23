#!/usr/bin/env python3
"""通过 GitHub Data API 推送本地提交（github.com:443 不通时用）。

原理：git 协议走 github.com:443（本机被代理挡住，CONNECT 502），
但 api.github.com:443 可以直连。所以把每个提交的 tree 递归建成远端对象，
再用 POST /git/commits 串起来，最后 PATCH /git/refs/heads/main。

用法：python tools/push_via_api.py <远端已有的 sha>
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO = "JDQ-tim/threee-assistant-ios"
BRANCH = "main"


def token() -> str:
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True
    ).strip()
    cred = url.split("://", 1)[1].split("@", 1)[0]  # user:TOKEN
    return cred.split(":", 1)[1]


def req(method: str, path: str, tok: str, payload=None, tries: int = 4):
    data = json.dumps(payload).encode() if payload is not None else None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    last = None
    for attempt in range(tries):
        r = urllib.request.Request(API + path, data=data, method=method)
        r.add_header("Authorization", "Bearer " + tok)
        r.add_header("Accept", "application/vnd.github+json")
        if data:
            r.add_header("Content-Type", "application/json")
        try:
            with opener.open(r, timeout=90) as resp:
                body = resp.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:600]
            # 4xx 是确定性的，重试没意义；5xx 和 429 值得再试
            if e.code < 500 and e.code != 429:
                raise SystemExit(f"HTTP {e.code} {method} {path}\n{detail}")
            last = f"HTTP {e.code}: {detail}"
        except Exception as e:  # SSL EOF / 连接重置 / 超时 —— 直连 github 时很常见
            last = f"{type(e).__name__}: {e}"
        if attempt < tries - 1:
            time.sleep(1.5 * (attempt + 1))
    raise SystemExit(f"重试 {tries} 次仍失败: {method} {path}\n{last}")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git"] + list(args))


class Pusher:
    def __init__(self, tok: str) -> None:
        self.tok = tok
        self.tree_cache: dict = {}
        self.blob_cache: dict = {}

    def blob(self, sha: str) -> str:
        if sha in self.blob_cache:
            return self.blob_cache[sha]
        raw = git("cat-file", "-p", sha)
        try:
            text = raw.decode("utf-8")
            payload = {"content": text, "encoding": "utf-8"}
        except UnicodeDecodeError:
            import base64
            payload = {"content": base64.b64encode(raw).decode(), "encoding": "base64"}
        out = req("POST", f"/repos/{REPO}/git/blobs", self.tok, payload)
        self.blob_cache[sha] = out["sha"]
        return out["sha"]

    def tree(self, sha: str) -> str:
        if sha in self.tree_cache:
            return self.tree_cache[sha]
        # `git cat-file -p <tree>` 输出的是 ls-tree 文本格式（每行一条，
        # 字段用 TAB 分隔）：
        #   100644 blob <sha>\t<name>
        #   040000 tree <sha>\t<name>
        # 不是 JSON —— 早先这里用 json.loads 会挂在 "Extra data"。
        listing = []
        raw = git("cat-file", "-p", sha)
        for line in raw.split(b"\n"):
            if not line.strip():
                continue
            meta, name = line.split(b"\t", 1)
            mode, typ, obj = meta.decode().split()
            listing.append({
                "name": name.decode(),
                "mode": mode,
                "type": typ,
                "sha": obj,
            })
        items = []
        for it in listing:
            if it["type"] == "tree":
                items.append({
                    "path": it["name"], "mode": "040000", "type": "tree",
                    "sha": self.tree(it["sha"]),
                })
            elif it["type"] == "blob":
                items.append({
                    "path": it["name"], "mode": it["mode"], "type": "blob",
                    "sha": self.blob(it["sha"]),
                })
            else:  # commit（submodule）
                items.append({
                    "path": it["name"], "mode": "160000", "type": "commit",
                    "sha": it["sha"],
                })
        out = req("POST", f"/repos/{REPO}/git/trees", self.tok, {"tree": items})
        self.tree_cache[sha] = out["sha"]
        return out["sha"]


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("用法: push_via_api.py <远端已有的 sha> [<本地 git 起始 sha>]")
    base = sys.argv[1]
    # 第二参数：本地用哪个 sha 的**内容**当分界。缺省时如果 base 在本地存在就用它。
    #
    # 为什么要这个：API 推送会重建提交对象，远端 sha 在本地仓库里根本不存在。
    # 所以第二次推送时，远端 sha（b7532464…）不能传给 `git rev-list`。
    # 但它的**内容**等于本地某个提交，用那个提交当分界就对了。
    local_base = sys.argv[2] if len(sys.argv) > 2 else None

    tok = token()
    p = Pusher(tok)

    head = req("GET", f"/repos/{REPO}/commits/{base}", tok)
    base_sha = head["sha"]
    print("远端起点:", base_sha[:10], "tree", head["commit"]["tree"]["sha"][:10])

    if local_base is None:
        local_base = base_sha
    if subprocess.call(["git", "cat-file", "-e", local_base + "^{commit}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        raise SystemExit(
            f"本地没有 {local_base[:10]} 这个提交。\n"
            "API 推送会重建提交对象，远端 sha 本地不存在 —— "
            "请把「内容相同的那个本地提交」作为第二个参数传进来。"
        )

    shas = subprocess.check_output(
        ["git", "rev-list", "--reverse", f"{local_base}..HEAD"], text=True
    ).split()
    print("待推提交:", len(shas), "个")
    if not shas:
        print("没有要推的提交")
        return

    parent = base_sha
    for sha in shas:
        parts = git("show", "-s", "--format=%T%x00%an%x00%ae%x00%aI%x00%B", sha
                    ).decode().split("\0")
        tree_sha, author, email, date, message = parts[0], parts[1], parts[2], parts[3], parts[4]
        remote_tree = p.tree(tree_sha.strip())
        body = {
            "message": message,
            "tree": remote_tree,
            "parents": [parent],
            "author": {"name": author, "email": email, "date": date},
            "committer": {"name": author, "email": email, "date": date},
        }
        out = req("POST", f"/repos/{REPO}/git/commits", tok, body)
        parent = out["sha"]
        print("  ", parent[:10], message.split("\n")[0][:64])

    req("PATCH", f"/repos/{REPO}/git/refs/heads/{BRANCH}", tok, {"sha": parent})
    print("PUSHED", BRANCH, "->", parent[:10])


if __name__ == "__main__":
    main()
