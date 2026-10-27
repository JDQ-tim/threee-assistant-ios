#!/usr/bin/env python3
"""比对「客户端会发出的 JSON 键」和「服务端会读取的 JSON 键」。

为什么需要这个：
    响应方向的问题（服务端发什么、客户端怎么解）一旦出错，Swift 会抛
    `keyNotFound` / `typeMismatch`，那是**响亮的**失败。

    请求方向恰好相反：客户端把 `minutes_before` 写成 `offset_sec`，
    服务端读到的是空值，于是按 0 处理 —— **没有报错、没有异常、HTTP 200**，
    只是功能悄悄失效。这种问题只有对着两边的字段名逐个比才看得见。

    `Models.swift` 里已经有一条血泪注释记着这件事：
    「写成 offset_sec 不会报错，只会静默失效」。

用法：
    # 有服务端源码时（最准，永远跟最新源码比）
    python tools/check_request_contract.py <服务端源码目录>

    # 没有源码时（比如 CI）：回落到仓库里的字段快照
    python tools/check_request_contract.py

    # 源码更新后，重新生成快照
    python tools/check_request_contract.py <源码目录> --dump

为什么要快照：CI 只 checkout 这个 iOS 仓库，拿不到服务端的 Go 源码。
把「服务端会读哪些键」冻结成 JSON 存进仓库，就能在 CI 里比对。
代价是服务端改字段时要记得重新 dump —— 所以 dump 时会打印提示。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIENT_FILES = sorted((ROOT / "ThreeeAssistant").rglob("*.swift"))
SNAPSHOT = ROOT / "Tests" / "server-request-keys.json"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
DUMP = "--dump" in sys.argv
SERVER_DIR = Path(
    args[0] if args
    else ROOT.parent / ".src" / "3e-源码包" / "server" / "internal" / "app"
)

# 客户端请求体 -> 服务端请求结构。
# 名字对不上是常态（NewEventBody → eventReq），只能人工登记。
# 只登记**确定是同一件事**的；拿不准的宁可不比，也不要给出假的"通过"。
PAIRS = [
    ("LoginBody", "loginReq"),
    ("RegisterBody", "registerReq"),
    ("NewEventBody", "eventReq"),
    ("UpdateEventBody", "eventReq"),
    ("SnoozeBody", "snoozeReq"),
    ("ResolveConflictBody", "resolveReq"),
    ("InboxDecisionBody", "inboxDecisionReq"),
    ("NewInboxItemBody", "inboxCreateReq"),
    ("CalendarBody", "calendarReq"),
    ("AddMemberBody", "memberReq"),
    ("OccurrenceBody", "occurrenceReq"),
    ("ReportBody", "reportReq"),
    ("WordbookPushRequest", "wordbookPushReq"),
    ("SyncPushRequest", "pushReq"),
    ("SetWeatherLocationBody", "weatherLocationReq"),
]

# 这些键服务端故意是可选的、或者客户端故意不发（"不传表示不管"）。
# 列出来是为了让报告不产生噪音，不是为了放过错误。
IGNORE_MISSING = {
    "eventReq": {"id", "device_id", "field_base_seqs"},
    "pushReq": {"device_id"},
    "snoozeReq": {"device_id"},
    "calendarReq": {"id", "device_id", "field_base_seqs", "member_ids"},
    "memberReq": {"add"},
    "occurrenceReq": {"cancelled", "device_id"},
    "inboxCreateReq": {"from_user_id"},
}

# 「客户端确实不发，但这是有意为之」——单独标注，不算失败但要看得见。
# 和 IGNORE_MISSING 的区别：IGNORE 是服务端可选/老客户端字段，
# NOTES 是**功能边界**，将来想补就有据可查。
NOTES = {
    "eventReq": {
        "rdate": "客户端暂不支持「额外加一次」，只有 RRULE",
        "exdate": "暂不支持「跳过某一次」；单次删除走 DELETE .../occurrence?key=",
    },
    "calendarReq": {
        "field_base_seqs": "日历字段没做冲突检测，更新一律后写覆盖",
        "member_ids": "建日历时不带初始成员，建完再逐个加",
    },
    "memberReq": {
        "add": "给老客户端的兼容字段；新客户端用 role 表达同样语义",
    },
    "occurrenceReq": {
        "cancelled": "取消单次走 DELETE /occurrence，不用这个字段",
    },
    "inboxCreateReq": {
        "from_user_id": "capture 类型由服务端从 token 推断，不必传",
    },
}

# 只对某一组成立的可选项（同一个服务端结构被多个客户端结构复用时不通用）。
# 例：新建日程当然不带 done_at，但更新日程就要带。
IGNORE_BY_PAIR = {
    ("NewEventBody", "eventReq"): {"done_at"},
}


def strip_comments(text: str) -> str:
    """把注释替换成等长空格，保留换行与偏移。

    为什么必须做：`SetWeatherLocationBody` 的注释里有一句
    「不能用 `if let lat {` 简写」—— 那个 `{` 在注释里，但它会让
    括号配平直接错乱，把整个文件剩下的内容都算进这个结构体，
    于是报出一个「发了 198 个键」的荒唐结果。

    不用"删掉"而是"替换成空格"，是为了让后续 re 匹配的偏移仍然对得上，
    报错行号才不会歪。
    """
    out = []
    i, n = 0, len(text)
    in_line = False
    in_block = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            else:
                out.append(" ")
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                out.append("  ")
                i += 2
                in_block = False
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            out.append("  ")
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def body_of(text: str, start: int) -> str:
    """从 `{` 开始配平括号，取出结构体体。"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start: i + 1]
    return text[start:]


def client_keys() -> dict:
    """返回 {结构体名: {JSON 键}}，即客户端编码后会发出的键。"""
    out = {}
    for f in CLIENT_FILES:
        txt = strip_comments(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"struct\s+(\w+)\s*:", txt):
            name = m.group(1)
            brace = txt.find("{", m.end())
            if brace < 0:
                continue
            body = body_of(txt, brace)
            keymap = {}
            for cm in re.finditer(r"case\s+(\w+)\s*=\s*\"([^\"]+)\"", body):
                keymap[cm.group(1)] = cm.group(2)
            props = set()
            for pm in re.finditer(r"^\s+(?:let|var)\s+(\w+)\s*:\s*([^\n=]+)$", body, re.M):
                # 计算属性不是编码字段。`var isEmpty: Bool { ... }` 这种
                # 会被当成"客户端要发的键"，造成假的「服务端不读 isEmpty」。
                if "{" in pm.group(2):
                    continue
                props.add(pm.group(1))
            if props:
                out[name] = {keymap.get(p, p) for p in props}
    return out


def server_keys() -> dict:
    """返回 {结构体名: {json 键}}，即服务端会读取的键。

    有源码就从源码读（永远最新）；没有就回落到仓库里的快照（CI 用）。
    """
    out = {}
    if SERVER_DIR.exists():
        for f in sorted(SERVER_DIR.glob("*.go")):
            txt = f.read_text(encoding="utf-8", errors="replace")
            for m in re.finditer(r"type\s+(\w+)\s+struct\s*\{", txt):
                name = m.group(1)
                brace = txt.find("{", m.end() - 1)
                body = body_of(txt, brace)
                keys = set(re.findall(r'json:"([^",]+)', body))
                if keys:
                    out[name] = keys
        return out

    if SNAPSHOT.exists():
        raw = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        print(f"（没找到服务端源码，用字段快照 {SNAPSHOT.name} 比对）")
        return {k: set(v) for k, v in raw.items()}

    raise SystemExit(
        f"既没有服务端源码目录（{SERVER_DIR}），也没有快照（{SNAPSHOT}）。\n"
        "在别的机器上跑时，请先 `--dump` 生成快照并提交。"
    )


def main() -> None:
    cli = client_keys()
    srv = server_keys()

    if DUMP:
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT.write_text(
            json.dumps({k: sorted(v) for k, v in srv.items()},
                       ensure_ascii=False, indent=1, sort_keys=True),
            encoding="utf-8",
        )
        print(f"已写入快照 {SNAPSHOT}（{len(srv)} 个服务端请求结构）")
        print("⚠️ 服务端改了请求字段，记得重新 dump 并把它一起提交。")
        return

    print(f"服务端请求结构 {len(srv)} 个，客户端请求体 {len(cli)} 个")
    print(f"登记了 {len(PAIRS)} 组对应关系")
    print("=" * 64)

    problems = 0
    for cname, sname in PAIRS:
        ck = cli.get(cname)
        sk = srv.get(sname)
        if ck is None:
            print(f"⚠️  {cname}: 客户端找不到这个结构体（改过名？）")
            continue
        if sk is None:
            print(f"⚠️  {sname}: 服务端找不到这个结构体（改过名？）")
            continue

        ignore = IGNORE_MISSING.get(sname, set()) | IGNORE_BY_PAIR.get((cname, sname), set())
        notes = NOTES.get(sname, {})
        # 客户端发了、服务端根本不读 —— 静默失效的典型形态
        ignored = sorted(ck - sk)
        # 服务端要读、客户端从不发 —— 会被当场 400 或被当没传。
        # 有 NOTE 的算「已登记的功能边界」，不算失败，但下面会打出来。
        missing = sorted(sk - ck - ignore - set(notes))
        known_gaps = sorted((sk - ck - ignore) & set(notes))

        status = "✅"
        if ignored or missing:
            status = "❌"
            problems += 1
        print(f"\n{status} {cname}  →  {sname}")
        print(f"    客户端发 {len(ck)} 键，服务端读 {len(sk)} 键")
        if ignored:
            print(f"    ⚠️ 服务端**不读**这些键（发了也没用，静默失效）：{', '.join(ignored)}")
        if missing:
            print(f"    ⚠️ 客户端**从不发**这些键（服务端会当没传）：{', '.join(missing)}")
        if not ignored and not missing:
            print("    字段名完全对齐")
        if known_gaps:
            print(f"    ℹ️ 已知功能边界（不算失败）：{', '.join(known_gaps)}")
        if notes:
            for k, why in notes.items():
                print(f"    ℹ️ {k}：{why}")

    print("\n" + "=" * 64)
    if problems:
        print(f"发现 {problems} 组不一致 —— 这些不会报错，只会让功能悄悄失效")
        sys.exit(1)
    print("全部对齐")


if __name__ == "__main__":
    main()
