#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给所有 `struct Xxx: View` 前面补 `@MainActor`。

## 为什么要做这件事

云端 CI 跑在 Xcode 15.4 + iOS 17.5 SDK 上。那个 SDK 里 SwiftUI 的
`View.body` 是非隔离上下文，于是 body 里读 `@MainActor` 的 SessionStore
成员全部编译失败（一次报了 35 个错）。

Xcode 16 起 SDK 给 `body` 补了 `@MainActor`，同样的代码就编得过 ——
这就是「本地看着没问题、云端一编译就红」的原因。

给 View 显式标 `@MainActor` 是官方推荐的做法，语义上也正确：
SwiftUI 的 view 更新本来就只在主线程。

## 幂等

已经有 @MainActor 的跳过，重复跑不会叠加。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "ThreeeAssistant")

VIEW_LINE = re.compile(
    r"^(?P<indent>\s*)(?:(?:public|internal|fileprivate)\s+)?"
    r"(?P<decl>struct\s+\w+\s*:\s*View\b.*)$"
)


def main():
    changed = []
    skipped = 0

    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            lines = open(path, encoding="utf-8").read().split("\n")
            out = []
            local = 0

            for i, line in enumerate(lines):
                m = VIEW_LINE.match(line)
                if not m:
                    out.append(line)
                    continue

                # 往下看 3 行内有没有 @MainActor（可能是 @MainActor 写在 struct 后面一行）
                already = any("@MainActor" in (lines[j] or "")
                              for j in range(max(0, i - 2), min(len(lines), i + 3)))
                if already:
                    skipped += 1
                    out.append(line)
                    continue

                indent = m.group("indent")
                out.append(indent + "@MainActor")
                out.append(line)
                local += 1

            if local:
                rel = os.path.relpath(path, ROOT).replace("\\", "/")
                open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out))
                changed.append((rel, local))

    print("为 %d 个文件、共 %d 个 View 补了 @MainActor" % (len(changed), sum(c for _, c in changed)))
    for rel, n in changed:
        print("  %-64s +%d" % (rel, n))
    if skipped:
        print("跳过（已有）: %d" % skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
