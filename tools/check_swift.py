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
