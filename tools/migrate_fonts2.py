#!/usr/bin/env python3
"""第二批：处理带 weight 的字号。

与第一批（migrate_fonts.py）的区别：
- 匹配 `font(.system(size: N, weight: .xxx))` 这种两参形式
- **排除网格文件**：月视图和课程表的格子尺寸固定，
  字号一放大就会溢出格线，那里必须保持固定 pt。
- 三元 weight（`isToday ? .bold : .medium`）保留三元，只换字号基准
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ThreeeAssistant"

# 网格 / 图标专属文件：字号必须固定，不参与语义化
SKIP_FILES = {
    "MonthGrid.swift",
    "CourseGridView.swift",
    "CourseTableView.swift",
}

BASE = {
    8.5: "caption2",
    8: "caption2",
    9: "caption2",
    10: "caption2",
    10.5: "caption2",
    11: "caption",
    11.5: "caption",
    12: "caption",
    12.5: "footnote",
    13: "footnote",
    13.5: "subheadline",
    14: "subheadline",
    14.5: "subheadline",
    15: "body",
    16: "body",
    17: "headline",
    20: "title3",
    22: "title2",
    26: "title",
    30: "largeTitle",
}

# font(.system(size: 15, weight: .medium))
TWO_ARG = re.compile(r"font\(\.system\(size:\s*([0-9.]+),\s*weight:\s*(\.[A-Za-z]+)\)\)")
# font(.system(size: 14, weight: cond ? .a : .b))
COND_ARG = re.compile(
    r"font\(\.system\(size:\s*([0-9.]+),\s*weight:\s*([^)]+?\s\?\s[^:]+:\s[^)]+?)\)\)"
)


def main() -> int:
    total = 0
    for path in sorted(SRC.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        text = path.read_text(encoding="utf-8")
        original = text

        def two(m: re.Match) -> str:
            size = float(m.group(1))
            if size not in BASE:
                return m.group(0)
            return f"font(.{BASE[size]}.weight({m.group(2).lstrip('.')}))"

        def cond(m: re.Match) -> str:
            size = float(m.group(1))
            if size not in BASE:
                return m.group(0)
            # 三元表达式原样保留在中括号里
            return f"font(.{BASE[size]}.weight({m.group(2).strip()}))"

        text = COND_ARG.sub(cond, text)
        text = TWO_ARG.sub(two, text)

        if text != original:
            n = len(TWO_ARG.findall(original)) + len(COND_ARG.findall(original))
            total += n
            path.write_text(text, encoding="utf-8")
            print(f"  {n:3d} 处  {path.relative_to(ROOT)}")

    rest = 0
    for path in sorted(SRC.rglob("*.swift")):
        rest += len(re.findall(r"font\(\.system\(size:", path.read_text(encoding="utf-8")))
    print(f"\n本轮替换 {total} 处，剩余 {rest} 处（网格 + 展示图标）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
