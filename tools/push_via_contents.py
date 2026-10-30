#!/usr/bin/env python3
"""用 Contents API 把本地改动推到 GitHub。

## 为什么需要这个（而不用 push_via_api.py）

`push_via_api.py` 走的是底层 git 对象 API：
建 blob → 建 tree → 建 commit → PATCH ref。

实测在这台机器 + 这个 fine-grained token 上，前三步全成功
（blob 201、tree 201、commit 201），只有最后 PATCH ref 一直 404，
连 `POST /git/refs` 新建一个临时分支也 404。
但同一个 token 用 `PUT /contents/{path}` 写文件是 **200**。

也就是说：**对象写入和 ref 写入被区别对待**，ref 这条路走不通。
Contents API 是官方给"一次改一批文件"用的接口，它内部会把
"改文件 + 移动分支"打包成一个事务，权限检查走的是另一条路径。

## 代价

每调一次 PUT 就是一个 commit —— 5 个文件就是 5 个 commit，
而不是本地那 3 个。提交历史会碎一点，但内容一致。
真要整齐，得等 ref 权限修好再用 push_via_api.py。

## 用法

    python tools/push_via_contents.py            # 推 56ac0d6..HEAD 的全部改动
    python tools/push_via_contents.py --dry-run  # 只列出要改哪些文件
"""
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "JDQ-tim/threee-assistant-ios"
# 远端的 31b403b（内容等于本地 56ac0d6）—— 从这里开始算差异
LOCAL_BASE = "56ac0d6"


def token() -> str:
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True).strip()
    return url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]


TOK = token()


def call(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    r = urllib.request.Request(
        "https://api.github.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOK,
                 "User-Agent": "threee-push",
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json"})
    try:
        with opener.open(r, timeout=120) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf8", "replace")[:600]


def changed_files() -> list:
    """本地相对 LOCAL_BASE 改动的文件（只取新增/修改，不处理删除）。"""
    out = subprocess.check_output(
        ["git", "diff", "--name-status", LOCAL_BASE, "HEAD"],
        text=True).strip()
    files = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[-1]
        if status.startswith("D"):
            print(f"  !! 跳过删除 {path}（Contents API 删除要单独调 DELETE）")
            continue
        files.append(path)
    return files


def file_sha(path: str):
    """远端当前该文件的 blob sha；不存在返回 None。"""
    s, d = call("GET", f"/repos/{REPO}/contents/{path}")
    if s == 200 and isinstance(d, dict):
        return d.get("sha")
    return None


def push_one(path: str, message: str) -> str:
    local = subprocess.check_output(["git", "show", f"HEAD:{path}"])
    b64 = base64.b64encode(local).decode()
    sha = file_sha(path)
    body = {"message": message, "content": b64}
    if sha:
        body["sha"] = sha
    s, d = call("PUT", f"/repos/{REPO}/contents/{path}", body)
    if s not in (200, 201):
        raise SystemExit(f"❌ {path} 写入失败 HTTP {s}\n{d}")
    commit = (d.get("commit") or {}).get("sha", "")[:12]
    print(f"  ✅ {path}  -> {commit}")
    return commit


# 每个文件各自的提交说明。比"一个笼统的大提交"更容易回溯 ——
# 本来就是三个不相干的改动，硬压成一句话反而是损失。
MESSAGES = {
    ".github/workflows/ios-build.yml":
        "ci: 编译错误以前从没被完整看见过 —— 三段抓取 + 明文回传 + 对账\n\n"
        "连续两次 run 的 annotation 都是 3 errors，但 problems.txt 只有 2 条。\n"
        "第 3 条不是没报，是被 grep 的格式要求漏掉了：Swift 有一大类诊断\n"
        "不带行列号（cannot find X in scope、type X has no member y），\n"
        "而原正则只收 file.swift:12:34: error:。\n\n"
        "于是每轮都在修那两条看得见的，第三条从来没进过视野。\n\n"
        "1. problems.txt 分三段合：带行列号的 + 不带行列号但含 error: 的\n"
        "2. 另存 failed-commands.txt 记 xcodebuild 自己认的失败单元\n"
        "3. 判定步骤做对账，条数不一致就把差额喊出来\n"
        "4. 关键：用 ::error:: 把每条错误打到 stdout —— 之前整段被重定向\n"
        "   进 SUMMARY.md，页面上只剩计数",

    "ThreeeAssistant/Features/Settings/InboxView.swift":
        "fix(inbox): 收件箱作为 Tab 根页却没自带 NavigationStack\n\n"
        "四 Tab 重构时把 InboxView 提成了一级 Tab 的根视图，但 body 直接\n"
        "返回 Group，所有 .navigationTitle / .toolbar 都挂在 Group 上。\n\n"
        "后果（编译完全不报错，纯运行期故障）：\n"
        "  - 没有栈 → .navigationTitle 无处可挂，顶部没标题\n"
        "  - 没有栈 → 「看已处理的记录」那个 NavigationLink 点了没反应\n\n"
        "重新包一层 NavigationStack。InboxArchiveView 保持无栈（它被推入）。",

    "tools/check_swift.py":
        "tools: check_swift 补两类 CI 真报过的错，并压掉五类误报\n\n"
        "A. ?. 链之后调用 String 扩展\n"
        "   必须区分 extension String 和\n"
        "   extension Optional where Wrapped == String —— 后者合法，不能报。\n"
        "   （踩过：nonEmpty 就定义在后者上，误判了整整一轮）\n"
        "B. View 必填参数没传\n"
        "   判必填要同时排除：Optional、有默认值、属性包装器、\n"
        "   嵌套类型字段、尾随闭包 —— 少排除一个就是一片误报。\n\n"
        "第一版误报 7 个，逐个修到 0，并用故意造的坏文件验证能抓到。\n"
        "误报比不检查更糟：会让人不敢信这个工具。",

    "tools/ci.py":
        "tools: 加 ci.py —— 本机没 gh，CI 操作只能走 REST API\n\n"
        "github.com:443 被代理挡着，只有 api.github.com 通。\n"
        "而且 urllib 默认读 HTTP_PROXY，不显式绕开会 502。\n\n"
        "    python tools/ci.py dispatch      # 触发 main 上的构建\n"
        "    python tools/ci.py list          # 最近几次运行\n"
        "    python tools/ci.py watch <id>    # 轮询到结束\n"
        "    python tools/ci.py log <id>      # 失败步骤 + 关键行",

    "tools/refresh_token.py":
        "tools: 加 refresh_token.py，换 token 后一条命令推送\n\n"
        "推送靠 push_via_api.py（它从 remote URL 里读 token），\n"
        "token 一过期那个 URL 里就是死凭据，必须先换。\n\n"
        "三件事：换 origin 里的 token（只写本地 .git/config，不落文件）、\n"
        "打一次 /user 确认真能用、自己查远端 sha 再调推送。\n"
        "免得推五分钟才在 401 上撞墙。",
}


def main() -> None:
    dry = "--dry-run" in sys.argv
    files = changed_files()
    if not files:
        print("没有改动，不用推")
        return
    print(f"要写 {len(files)} 个文件：")
    for f in files:
        print("  -", f)
    if dry:
        return
    print()
    for f in files:
        msg = MESSAGES.get(f, f"chore: 更新 {f}")
        if f not in MESSAGES:
            print(f"  ⚠️ {f} 没有专属提交说明，用默认的")
        push_one(f, msg)
    print("\n✅ 全部写入完成")
    s, d = call("GET", f"/repos/{REPO}/commits/main")
    if s == 200 and isinstance(d, dict):
        print("远端 main 现在指向:", d["sha"][:12],
              d["commit"]["message"].splitlines()[0][:50])


if __name__ == "__main__":
    main()
