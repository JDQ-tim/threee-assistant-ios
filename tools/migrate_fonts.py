#!/usr/bin/env python3
"""把硬编码字号批量换成语义字号。

设计原则：
- 只替换 `font(.system(size: N))` 且 N 落在文本尺寸区间的
- 大于等于 26 的当作展示图标，不动（那是有意的固定尺寸）
- 带 weight/design 参数的复杂写法跳过，交给人工
- 输出改动清单，便于 review
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ThreeeAssistant"

# 字号 -> 语义名。依据是全工程的用法分布：
# 15 最多（25 次），13 次之（21 次），然后是 12.5 / 14 / 12
MAP = {
    8.5: "appCaption2",
    8: "appCaption2",
    9: "appCaption2",
    10: "appCaption2",
    10.5: "appCaption2",
    11: "appCaption",
    11.5: "appCaption",
    12: "appCaption",
    12.5: "appFootnote",
    13: "appFootnote",
    13.5: "appSubheadline",
    14: "appSubheadline",
    14.5: "appSubheadline",
    15: "appBody",
    16: "appBody",
    17: "appHeadline",
    20: "appTitle",
    22: "appTitle",
}

# 只匹配最简单的形式：font(.system(size: 15))
SIMPLE = re.compile(r"font\(\.system\(size:\s*([0-9.]+)\)\)")


def main() -> int:
    changed = []
    for path in sorted(SRC.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        original = text

        def repl(m: re.Match) -> str:
            size = float(m.group(1))
            if size not in MAP:
                return m.group(0)
            return f"font(.{MAP[size]})"

        text = SIMPLE.sub(repl, text)

        if text != original:
            n = len(SIMPLE.findall(original)) - len(SIMPLE.findall(text))
            changed.append((path.relative_to(ROOT), n))
            path.write_text(text, encoding="utf-8")

    remaining = 0
    for path in sorted(SRC.rglob("*.swift")):
        remaining += len(re.findall(r"font\(\.system\(size:", path.read_text(encoding="utf-8")))

    print(f"替换文件数: {len(changed)}")
    for p, n in changed:
        print(f"  {n:3d} 处  {p}")
    print(f"\n剩余 font(.system(size: 共 {remaining} 处（展示图标 / 网格数字 / 复数参数形式）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
