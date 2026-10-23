#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
专查「@MainActor 隔离」引发的编译错误。

## 为什么单独写一个脚本

云端 runner 用的是 **Xcode 15.4 + iOS 17.5 SDK**。这个组合下
SwiftUI 的 `View.body` 闭包被当作**非隔离上下文**，于是

    struct Foo: View {
        @Environment(SessionStore.self) private var store
        var body: some View {
            if store.isLoading { ... }        // ❌ 报错
        }
    }

会报 `main actor-isolated property 'isLoading' can not be referenced
from a non-isolated context`。

Xcode 16 起 SDK 给 `View.body` 加了 `@MainActor`，同样写法编得过。
所以这类错误**只在云端暴露**，本地静态检查必须单独把它们捞出来。

## 判据（近似但足够用）

1. `@MainActor` 类里的存储属性、方法 → 隔离集合
2. **没标 `@MainActor` 的 `View`** 的 `body` / `some View` 计算属性 / 按钮闭包
   → 非隔离上下文；里面出现 `store.<隔离成员>` 就报错
3. 标了 `@MainActor` 的 `View` → 整个类型都在主线程域，跳过

## 为什么判据要「看 View 自己标没标」

`View.body` 是非隔离上下文是**协议要求**，不是某个 View 的偶然现象。
所以正确的做法不是让每个 View 都去跟协议掰，而是给每个 View 标 `@MainActor`
—— 类型进主线程域后，它所有的成员（含 body）一起进，
body 就变成了「主线程域里的 body」，满足协议，也不再隔离冲突。

所以这个脚本现在的职责很明确：**守住「每个 View 都标了 @MainActor」这条线**。
漏标一个，这里就报一串。

## 例外（不算错）

- 在 `Task { }` / `await` 里：那些表达式本身就是 async 的，合法
- `.task { }` 修饰符：闭包已是 async
- `#Preview` 块：宏展开在主线程
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "ThreeeAssistant")


def read_sources():
    out = {}
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".swift"):
                p = os.path.join(dirpath, fn)
                out[os.path.relpath(p, ROOT).replace("\\", "/")] = open(
                    p, encoding="utf-8").read()
    return out


def strip_strings_and_comments(s):
    """去注释和字符串，保留行号（换行全部保留）。"""
    out = []
    i, n = 0, len(s)
    in_line = False
    block = 0
    in_str = False
    in_multi = False
    while i < n:
        ch = s[i]
        nxt = s[i + 1] if i + 1 < n else ""

        if in_line:
            if ch == "\n":
                in_line = False
                out.append("\n")
            i += 1
            continue
        if block:
            if ch == "*" and nxt == "/":
                block -= 1
                i += 2
                continue
            if ch == "/" and nxt == "*":
                block += 1
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_multi:
            if s.startswith('"""', i):
                in_multi = False
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
            out.append(" ")
            i += 1
            continue
        if s.startswith("//", i):
            in_line = True
            i += 2
            continue
        if s.startswith("/*", i):
            block = 1
            i += 2
            continue
        if s.startswith('"""', i):
            in_multi = True
            i += 3
            continue
        if ch == '"':
            in_str = True
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def collect_isolated(src_clean):
    """@MainActor 类型里的成员名。"""
    attrs, funcs = set(), set()

    # @MainActor 标注出现在 class 之前的块
    for m in re.finditer(r"@MainActor\b[^\n]*\n(?:[^\n]*\n)?\s*(?:final\s+)?class\s+(\w+)", src_clean):
        name = m.group(1)
        start = m.end()
        # 找到类体结束（按花括号配平）
        i = src_clean.find("{", start)
        if i < 0:
            continue
        depth = 0
        end = len(src_clean)
        while i < len(src_clean):
            if src_clean[i] == "{":
                depth += 1
            elif src_clean[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        body = src_clean[start:end]
        for am in re.finditer(
            r"^\s{4}(?:@\w+\s+)?(?:private\(set\)\s+|private\s+|internal\s+|public\s+)?(?:static\s+)?(?:let|var)\s+(\w+)",
            body, re.M):
            attrs.add(am.group(1))
        for fm in re.finditer(r"^\s{4}(?:@\w+\s+)?(?:private\s+|internal\s+|public\s+)?func\s+(\w+)",
                              body, re.M):
            funcs.add(fm.group(1))
    return attrs, funcs


def enclosing_is_main_actor(lines, idx):
    """第 idx 行所在的类型声明有没有 `@MainActor`。

    ## 为什么要往上找，而且一路找到文件顶

    我们是从引用点往上追溯「这条引用被包在哪个类型里」。
    最近的类型声明行是**内层**，但内层可能是 View 内部定义的小结构体
    （比如 `private struct Report { ... }`），它自己没有 `@MainActor`，
    而外层的 `SyncStatusView` 标了。

    Swift 的隔离规则是分层的，但嵌套类型不会继承外层的 `@MainActor` ——
    严谨说，内层没标就该单独标。可这些内层小结构体大多是纯数据，
    根本碰不到 store；真正碰 store 的是外层 View 的 body。

    所以这里做的是：**一路往上找，只要有任何一层标了 @MainActor 就放行**。
    这样既不误报，也不会漏掉「整个文件一个 @MainActor 都没有」的情况。
    """
    for back in range(idx, -1, -1):
        bl = lines[back]
        if not re.search(r"^\s*(?:private\s+|internal\s+|public\s+)?(?:final\s+)?(?:struct|class|enum|extension)\s+\w+", bl):
            continue
        # 看这一行本身，以及之前 3 行内有没有 @MainActor
        for k in range(back, max(-1, back - 4), -1):
            if re.search(r"@MainActor\b", lines[k]):
                return True
        # 内层没标 → 继续往上找外层，而不是直接判负
    return False


def main():
    sources = read_sources()
    cleaned = {k: strip_strings_and_comments(v) for k, v in sources.items()}

    attrs, funcs = set(), set()
    for rel, c in cleaned.items():
        if rel.endswith("SessionStore.swift"):
            a, f = collect_isolated(c)
            attrs |= a
            funcs |= f

    problems = []
    unmarked = []

    # 只关心 UI 层：Features/ 和 Design/ 下的 View。
    # Core/ 里没有 store 引用，App/ 只有一个 @main。
    for rel, c in cleaned.items():
        if "/Features/" not in rel and "/Design/" not in rel and "/App/" not in rel:
            continue

        lines = c.split("\n")
        # 找到每个「非隔离」区域：body 计算属性、some View 属性、Button 闭包
        for idx, line in enumerate(lines):
            for m in re.finditer(r"\bstore\.(\w+)", line):
                name = m.group(1)
                if name not in attrs and name not in funcs:
                    continue

                # 所在类型标了 @MainActor 吗？（往上找最近一个 struct/class 声明）
                if enclosing_is_main_actor(lines, idx):
                    continue

                # 判断是否在 async 安全区：往上找最近的 Task { 或 .task
                safe = False
                for back in range(idx, max(-1, idx - 25), -1):
                    bl = lines[back]
                    if re.search(r"\bTask\s*(?:<[^>]*>)?\s*\{", bl) or ".task {" in bl or ".task{" in bl:
                        safe = True
                        break
                    # 遇到函数/属性边界就停
                    if re.match(r"^\s*(?:private\s+)?(?:func|var|@ViewBuilder)\s", bl) and back != idx:
                        break
                if safe:
                    continue

                problems.append("%s:%d store.%s" % (rel, idx + 1, name))

        # 声明了 View 但整个类型没标 @MainActor 的，单独列出来
        for idx, line in enumerate(lines):
            if not re.search(r"^\s*(?:private\s+|internal\s+)?(?:struct|class)\s+\w+[^\{]*:\s*[^{]*\bView\b", line):
                continue
            if enclosing_is_main_actor(lines, idx):
                continue
            unmarked.append("%s:%d %s" % (rel, idx + 1, line.strip()))

    print("=" * 62)
    print("并发隔离检查（模拟 Xcode 15.4 / iOS 17.5 SDK）")
    print("=" * 62)
    print("隔离属性 %d 个：%s" % (len(attrs), ", ".join(sorted(attrs))[:200]))
    print("隔离方法 %d 个" % len(funcs))
    print("-" * 62)
    if unmarked:
        print("以下 View 没标 @MainActor（body 会变成非隔离上下文）：")
        for p in unmarked:
            print("  [漏标] " + p)
    if problems:
        for p in problems:
            print("[错误] " + p)
    if not problems and not unmarked:
        print("未发现非隔离上下文中读取隔离成员")
    print("=" * 62)
    return 1 if (problems or unmarked) else 0


if __name__ == "__main__":
    sys.exit(main())
