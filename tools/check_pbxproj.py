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
defined_list = re.findall(r"^\t\t([0-9A-F]{24}) ", src, re.M)
defined = set(defined_list)
referenced = set(re.findall(r"\b([0-9A-F]{24})\b", src))

# 2b. ⚠️ 重复 ID 检测 —— 这是最容易漏、后果最诡异的一类错误。
#     两个不同对象用同一个 ID 时 Xcode 不报错，只会让路径解析错乱，
#     表现为「Assets.xcassets: No such file or directory」这种莫名其妙的失败。
from collections import Counter as _Counter
_dup = {i: n for i, n in _Counter(defined_list).items() if n > 1}
for i, n in _dup.items():
    errors.append("对象 ID 重复 %d 次: %s（Xcode 不会报错，但会解析错乱）" % (n, i))

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

# 5b. 每个文件引用能否**沿 PBXGroup 的 path 链解析到真实文件**
#
#     ⚠️ 2026-11-05 踩的坑：新增 Features/Home 时 group 对象没写进 pbxproj，
#        文件引用是 `path = HomeView.swift; sourceTree = "<group>"`，
#        而父链里没有 Home 这一层 —— Xcode 就去**仓库根目录**找 HomeView.swift，
#        报 `Build input files cannot be found: '/path/HomeView.swift'`。
#
#     上面第 5 条只检查"含 / 的路径"，恰好把这种裸文件名全跳过了 ——
#     所以需要一个真正的解析：从 mainGroup 往下走，把每层 path 拼起来。
# ⚠️ 不能用一条正则抓对象块：PBXFileReference 是**单行**的
#    （`ID /* x.swift */ = {isa = PBXFileReference; ...; };`），
#    而 PBXGroup 是多行的。按行扫 + 花括号配平，两种都能吃。
_objs = {}
_lines = src.split("\n")
_i = 0
while _i < len(_lines):
    _m = re.match(r"^\t\t([0-9A-F]{24})(?: /\* (.*?) \*/)? = \{(.*)$", _lines[_i])
    if not _m:
        _i += 1
        continue
    _id = _m.group(1)
    _head = _m.group(3)
    _i += 1
    if _head.rstrip().endswith("};"):
        # 单行对象
        _objs[_id] = _head
        continue
    _depth = 1 + _head.count("{") - _head.count("}")
    _buf = [_head]
    while _i < len(_lines) and _depth > 0:
        _buf.append(_lines[_i])
        _depth += _lines[_i].count("{") - _lines[_i].count("}")
        _i += 1
    _objs[_id] = "\n".join(_buf)

_groups = {}
_frefs = {}
for _id, _body in _objs.items():
    if "isa = PBXGroup" in _body:
        _m = re.search(r"children = \((.*?)\);", _body, re.S)
        _kids = re.findall(r"([0-9A-F]{24})", _m.group(1)) if _m else []
        _p = re.search(r"path = ([^;]+);", _body)
        _st = re.search(r"sourceTree = ([^;]+);", _body)
        _groups[_id] = {
            "children": _kids,
            "path": _p.group(1).strip().strip('"') if _p else None,
            "sourceTree": _st.group(1).strip().strip('"') if _st else "<group>",
        }
    elif "isa = PBXFileReference" in _body:
        _p = re.search(r"path = ([^;]+);", _body)
        _st = re.search(r"sourceTree = ([^;]+);", _body)
        _frefs[_id] = {
            "path": _p.group(1).strip().strip('"') if _p else None,
            "sourceTree": _st.group(1).strip().strip('"') if _st else "<group>",
        }

resolved_files = []
if _groups:
    _all_kids = set()
    for _g in _groups.values():
        _all_kids.update(_g["children"])
    _roots = [i for i in _groups if i not in _all_kids]

    def _walk(gid, prefix):
        g = _groups[gid]
        base = prefix
        if g["path"] and g["sourceTree"] == "<group>":
            base = os.path.join(prefix, g["path"]) if prefix else g["path"]
        for c in g["children"]:
            if c in _groups:
                _walk(c, base)
            elif c in _frefs:
                fr = _frefs[c]
                p = fr["path"]
                if not p:
                    continue
                st = fr["sourceTree"]
                if st == "SOURCE_ROOT":
                    full = p
                elif st in ("BUILT_PRODUCTS_DIR", "<absolute>"):
                    continue
                else:
                    full = os.path.join(base, p) if base else p
                resolved_files.append(full)
                if not os.path.exists(os.path.join(ROOT, full)):
                    errors.append(
                        "文件引用解析不到真实文件: %s"
                        "（Xcode 会报 Build input files cannot be found）" % full)

    for _r in _roots:
        _walk(_r, "")

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
print("解析到真实文件   : %d" % len(resolved_files))
print("-" * 52)
for e in errors:
    print("[错误] " + e)
for w in warns:
    print("[提示] " + w)
if not errors:
    print("结果: 通过，未发现结构性问题")
print("=" * 52)
sys.exit(1 if errors else 0)
