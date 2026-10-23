#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
无 Swift 编译器时的源码粗检。
不做类型检查（做不到），只查那些「一定会让编译器报错」的机械性错误。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "ThreeeAssistant")

errors = []
warns = []
files = []

for dirpath, dirnames, filenames in os.walk(SRC):
    dirnames.sort()
    for fn in sorted(filenames):
        if fn.endswith(".swift"):
            files.append(os.path.join(dirpath, fn))
files.sort()


def strip_noise(s):
    """去掉字符串字面量、注释、多行字符串，避免误判括号。"""
    out = []
    i = 0
    n = len(s)
    in_line_comment = False
    in_block_comment = 0
    in_string = False
    in_multiline = False
    while i < n:
        ch = s[i]
        nxt = s[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append("\n")
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment -= 1
                i += 2
                continue
            if ch == "/" and nxt == "*":
                in_block_comment += 1
                i += 2
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue

        if in_multiline:
            if s.startswith('"""', i):
                in_multiline = False
                i += 3
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue

        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue

        if s.startswith("//", i):
            in_line_comment = True
            i += 2
            continue
        if s.startswith("/*", i):
            in_block_comment = 1
            i += 2
            continue
        if s.startswith('"""', i):
            in_multiline = True
            i += 3
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


for path in files:
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    raw = open(path, encoding="utf-8").read()
    clean = strip_noise(raw)

    # 1. 括号配平
    for open_ch, close_ch, name in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        d = 0
        bad = False
        for ch in clean:
            if ch == open_ch:
                d += 1
            elif ch == close_ch:
                d -= 1
                if d < 0:
                    bad = True
                    break
        if bad or d != 0:
            errors.append("%s: %s不配平（最终深度 %d）" % (rel, name, d))

    # 2. 行尾多余分号（Swift 允许，但通常是笔误）
    # 3. `if let x {` 这种 Swift 5.7+ 简写 —— 工程 SWIFT_VERSION=5.0，属于风险
    for idx, line in enumerate(raw.splitlines(), 1):
        stripped = line.strip()
        if re.match(r"^(if|guard)\s+let\s+(\w+)\s*\{", stripped) or \
           re.search(r",\s*let\s+(\w+)\s*\{", stripped):
            warns.append("%s:%d 用了 `if/guard let x {` 简写（需 Swift 5.7+）: %s"
                         % (rel, idx, stripped[:70]))
        if re.match(r"^if\s+(let\s+)?\w+(\?|\.isEmpty)?\s*\{", stripped) is None and \
           re.search(r"\bif\s+let\s+\w+\s*\}", stripped):
            pass

        # ⚠️ `guard ... else { someCall() }` 单行写法 —— 编译错误。
        #    guard 的 else 块必须以 return / throw / break / continue / fatalError 结尾，
        #    否则编译器报 "`guard` body must not fall through"。
        #    这个坑真的踩过：`guard !p.isEmpty else { dismiss() }` 编译失败。
        m = re.match(r"^guard\b.*?\belse\s*\{(.*)\}\s*$", stripped)
        if m:
            tail = m.group(1).strip().rstrip(";").strip()
            last = re.split(r"[;\s]+", tail)[-1] if tail else ""
            if last not in ("return", "throw", "break", "continue") and \
               not last.startswith("fatalError") and \
               not re.match(r"^(return|throw)\b", tail):
                errors.append("%s:%d guard 的 else 块没有以 return/throw 结尾"
                              "（会报 body must not fall through）: %s"
                              % (rel, idx, stripped[:70]))

    # 4. 明显的未使用 import 不查（没意义），改查 import UIKit 必须在 iOS 上
    # 5. 检查文件非空
    if len(raw.strip()) == 0:
        errors.append("%s: 空文件" % rel)

# 6. @main 只能有一个
main_count = 0
for path in files:
    if re.search(r"^@main\b", open(path, encoding="utf-8").read(), re.M):
        main_count += 1
if main_count != 1:
    errors.append("`@main` 出现 %d 次，必须正好 1 次" % main_count)


# ============================================================
#  7. 跨文件符号引用检查
#  ------------------------------------------------------------
#  云端 macOS runner 经常排不上队（公开仓库 + 新账号优先级低），
#  本地又装不了 Swift 编译器，所以这里手工补几条「一定能编译过」的检查。
#
#  这些检查针对的都是**真实踩过的坑**：Theme 里不存在的成员、
#  改了签名忘了改调用点、手写 init(from:) 忘了 encode(to:)。
# ============================================================

ALL_SRC = {}
for path in files:
    ALL_SRC[os.path.relpath(path, ROOT).replace("\\", "/")] = open(path, encoding="utf-8").read()

ALL_TEXT = "\n".join(ALL_SRC.values())


def _norm(rel_path):
    """把 rel 路径变成显示用（截断到文件名）"""
    return rel_path


# 7a. `Theme.xxx` 引用必须在 Theme.swift 里定义过
theme_path = [p for p in ALL_SRC if p.endswith("Design/Theme.swift")]
if theme_path:
    theme_src = ALL_SRC[theme_path[0]]
    defined = set(re.findall(r"static\s+(?:let|var)\s+(\w+)", theme_src))
    defined |= set(re.findall(r"static\s+func\s+(\w+)", theme_src))
    for rel, src in ALL_SRC.items():
        # ⚠️ 必须先剥掉注释再匹配 —— 注释里出现 `Theme.kt` 这种文件名
        #    会被误判成「引用了不存在的成员」。第一版就踩了这个。
        for m in re.finditer(r"\bTheme\.(\w+)", strip_noise(src)):
            name = m.group(1)
            if name not in defined:
                line = strip_noise(src)[: m.start()].count("\n") + 1
                errors.append("%s:%d 引用了不存在的 Theme.%s" % (rel, line, name))


# 7b. 手写了 init(from:) 的 Codable 类型，必须也有 encode(to:)
for rel, src in ALL_SRC.items():
    if "init(from decoder:" not in src:
        continue
    # 按 struct 切段，逐段判断
    for m in re.finditer(r"struct\s+(\w+)[^{]*\{", src):
        name = m.group(1)
        start = m.end()
        # 粗略取到下一个 struct 开头
        nxt = src.find("\nstruct ", start)
        body = src[start: nxt if nxt != -1 else len(src)]
        # 只关心声明了 Codable / Decodable 的
        decl = src[m.start(): m.end()]
        if "Codable" not in decl and "Decodable" not in decl and "Decodable" not in body[:200]:
            continue
        if "init(from decoder:" in body and "func encode(to encoder:" not in body:
            errors.append("%s: struct %s 手写了 init(from:) 但没有 encode(to:)"
                          "（编译器不再自动合成，Codable 要求两个都有）" % (rel, name))


# 7c. SessionStore 方法调用点的**参数标签**校验
#
# 改了签名忘了改调用点，编译器会报 "extra argument"/"missing argument"，
# 但云端 runner 经常排不上队，所以这里提前拦住。
#
# ⚠️ 必须先 strip_noise 再匹配：调用点里常有跨行注释
#    （比如 createEvent 调用中间夹了三行说明），
#    直接对原文扫描会把标签和注释搅在一起，产生假报。
store_path = [p for p in ALL_SRC if p.endswith("Core/SessionStore.swift")]
if store_path:
    store_clean = strip_noise(ALL_SRC[store_path[0]])

    def _split_top(s, sep=","):
        parts = []
        depth = 0
        cur = ""
        for ch in s:
            if ch in "([<{":
                depth += 1
            elif ch in ")]>}":
                depth -= 1
            if ch == sep and depth == 0:
                parts.append(cur)
                cur = ""
                continue
            cur += ch
        if cur.strip():
            parts.append(cur)
        return parts

    def _params(tail):
        """返回 [(外部标签 or None, 是否有默认值)]"""
        out = []
        for p in _split_top(tail):
            if ":" not in p:
                continue
            head, rest = p.split(":", 1)
            head = re.sub(r"@\w+\s*", "", head).replace("inout ", "").strip()
            toks = head.split()
            if not toks:
                continue
            # Swift 规则：写了两个词，第一个是外部标签；
            # 只写一个词，外部标签就等于内部名。
            ext = toks[0] if len(toks) >= 2 else toks[0]
            out.append((None if ext == "_" else ext, "=" in rest))
        return out

    sig2 = {}
    for m in re.finditer(
        r"func\s+(\w+)\s*\((.*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->[^{]+)?\{",
        store_clean, re.S,
    ):
        sig2[m.group(1)] = _params(m.group(2))

    for rel, raw in ALL_SRC.items():
        clean = strip_noise(raw)
        for m in re.finditer(r"\bstore\.(\w+)\(", clean):
            fname = m.group(1)
            if fname not in sig2:
                continue
            i = m.end() - 1
            depth = 0
            body = ""
            while i < len(clean):
                ch = clean[i]
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        break
                if depth >= 1:
                    body += ch
                i += 1

            used = set()
            for t in _split_top(body[1:]):
                mm = re.match(r"\s*(\w+)\s*:", t)
                if mm:
                    used.add(mm.group(1))

            allowed = set(lb for lb, _ in sig2[fname] if lb)
            required = set(lb for lb, hd in sig2[fname] if lb and not hd)
            line = clean[: m.start()].count("\n") + 1

            extra = used - allowed
            miss = required - used
            if extra:
                errors.append("%s:%d store.%s 传了不存在的参数 %s"
                              % (rel, line, fname, sorted(extra)))
            if miss:
                errors.append("%s:%d store.%s 少传必填参数 %s"
                              % (rel, line, fname, sorted(miss)))


print("=" * 60)
print("Swift 源码粗检（无类型检查）")
print("=" * 60)
print("文件数: %d" % len(files))
print("-" * 60)
for e in errors:
    print("[错误] " + e)
for w in warns:
    print("[提示] " + w)
if not errors:
    print("结果: 未发现机械性错误")
print("=" * 60)
sys.exit(1 if errors else 0)
