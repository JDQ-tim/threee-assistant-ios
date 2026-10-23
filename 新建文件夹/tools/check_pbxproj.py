#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 project.pbxproj 的结构完整性（无 Xcode 环境下的静态检查）。"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, "ThreeeAssistant.xcodeproj", "project.pbxproj")
src = open(P, encoding="utf-8").read()

errors = []
warns = []

# 1. 括号配平（忽略字符串内的内容不完整处理，这里只做粗检）
depth = 0
in_str = False
esc = False
line_no = 1
for ch in src:
    if ch == "\n":
        line_no += 1
    if in_str:
        if esc:
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == '"':
            in_str = False
        continue
    if ch == '"':
        in_str = True
    elif ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth < 0:
            errors.append("第 %d 行出现多余的 }" % line_no)
            break
if depth != 0:
    errors.append("花括号不配平，最终深度 = %d" % depth)
if in_str:
    errors.append("存在未闭合的字符串")

# 2. 所有 24 位十六进制 ID 定义 vs 引用
defined = set(re.findall(r"^\t\t([0-9A-F]{24}) ", src, re.M))
referenced = set(re.findall(r"\b([0-9A-F]{24})\b", src))
# rootObject 也算引用
dangling = referenced - defined
if dangling:
    errors.append("悬空引用: %s" % ", ".join(sorted(dangling)))

unused = defined - referenced
# 定义处自身也会被算进 referenced，所以 unused 里不该有东西
if unused:
    warns.append("定义了但未被引用（可能是 normal）: %d 个" % len(unused))

# 3. rootObject 存在
m = re.search(r"rootObject = ([0-9A-F]{24})", src)
if not m:
    errors.append("缺少 rootObject")
elif m.group(1) not in defined:
    errors.append("rootObject 指向不存在的对象")

# 4. 每个 Swift 文件是否同时出现在 FileReference 和 Sources 阶段
swift_files = []
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "ThreeeAssistant")):
    for fn in filenames:
        if fn.endswith(".swift"):
            swift_files.append(fn)
for fn in swift_files:
    if src.count(fn) < 2:
        errors.append("Swift 文件 %s 未正确登记（出现次数 %d）" % (fn, src.count(fn)))
    if ("/* %s in Sources */" % fn) not in src:
        errors.append("Swift 文件 %s 未加入 Sources 编译阶段" % fn)

# 5. pbxproj 中出现的文件路径都真实存在
for rel in re.findall(r"path = ([^;]+);", src):
    rel = rel.strip().strip('"')
    if rel.startswith("$") or rel.endswith(".app"):
        continue
    if "/" in rel and not os.path.exists(os.path.join(ROOT, rel)):
        errors.append("path 指向不存在的文件: %s" % rel)

# 6. objectVersion / compatibilityVersion 一致性
if "objectVersion = 56" not in src:
    warns.append("objectVersion 不是 56")

# 7. Info.plist 与 Assets 是否存在
for need in ("Config/Info.plist", "ThreeeAssistant/Resources/Assets.xcassets"):
    if not os.path.exists(os.path.join(ROOT, need)):
        errors.append("缺少必需资源: %s" % need)

print("=" * 52)
print("pbxproj 静态校验")
print("=" * 52)
print("Swift 文件数     : %d" % len(swift_files))
print("定义对象数       : %d" % len(defined))
print("引用 ID 数       : %d" % len(referenced))
print("-" * 52)
for e in errors:
    print("[错误] " + e)
for w in warns:
    print("[提示] " + w)
if not errors:
    print("结果: 通过，未发现结构性问题")
print("=" * 52)
sys.exit(1 if errors else 0)
