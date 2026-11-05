#!/usr/bin/env python3
"""日历色板离线自检。

## 为什么需要它

色板是"看着挺好看"最容易出问题的地方 —— 而且坏了**不报错**：

  · 两个色块的 light 值写成一样的  → 用户选不出两张不同颜色的日历，
    但界面上只是"点了没变化"，看起来像按钮坏了
  · 深色档提得不够亮              → 深色背景上色条几乎看不见，
    这只有真机在深色下才暴露
  · 深色档提得太亮 / 没提          → 亮黄块上写白字，字糊成一片

这三件事的共同点：**CI 编得过、契约对得上、功能"有"**，只有人眼能发现。
所以把判定标准写成数，在这台没有 Mac 的机器上也能跑。

## 检查项

  1. light 值互不相同（16 个）
  2. 每个 light 在浅色表面 #FFFFFF 上对比度 ≥ 3:1（WCAG 对图形的要求）
  3. 每个 dark 在深色表面 #1E1F23 上对比度 ≥ 3:1
  4. 块内文字色：按 readableInk 的阈值算出来跟白/黑哪个更清楚，
     取到的那个必须 ≥ 4.5:1（块里是 9.5~10.5pt 小字）

## ⚠️ 它读的是 Swift 源文件，不是编译产物

`CalendarPalette.swift` 里 `swatches` 是一串 `.init(name:light:dark:)`。
按 `light:` / `dark:` 两个标签抽出来，不跑 Swift ——
这台机器没有 Swift 工具链（和 `check_next_class.py` 同一个思路）。
所以**改了源文件的写法就要跟着改这里的正则**；
下面的 `_selftest()` 会先验证解析器本身没坏，再拿去判色板。
"""

from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "ThreeeAssistant", "Design", "CalendarPalette.swift")

LIGHT_SURFACE = "#FFFFFF"
DARK_SURFACE = "#1E1F23"


# ---------------------------------------------------------------- 颜色数学

def _srgb_to_lin(c: float) -> float:
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def hex_to_rgb(h: str) -> tuple:
    s = h.strip().lstrip("#")
    if len(s) != 6:
        raise ValueError(f"不是 #RRGGBB: {h!r}")
    return tuple(int(s[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def luminance(h: str) -> float:
    r, g, b = hex_to_rgb(h)
    return 0.2126 * _srgb_to_lin(r) + 0.7152 * _srgb_to_lin(g) + 0.0722 * _srgb_to_lin(b)


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def ink_for(bg: str) -> str:
    """复刻 Swift 里 readableInk 的判据。

    ⚠️ 判据是「白/黑各算一次对比度，取高的那个」，不是单阈值。
       单阈值（第一版用 0.55）在明亮色块上会判反 —— 见 Swift 那边的注释。
       这里的 0.1791 就是两个对比度相等的那点亮度，
       用它可以写成一句话，算式和"比两次"完全等价。
    """
    return "#1A1A18" if luminance(bg) > 0.1791 else "#FFFFFF"


# ---------------------------------------------------------------- 解析

SWATCH_RE = re.compile(
    r'\.init\(\s*name:\s*"([^"]*)"\s*,\s*light:\s*"(#[0-9A-Fa-f]{6})"\s*,\s*dark:\s*"(#[0-9A-Fa-f]{6})"'
)


def parse_swatches(text: str) -> list:
    return SWATCH_RE.findall(text)


# ---------------------------------------------------------------- 自检

def run(verbose: bool = True) -> int:
    if not os.path.exists(SRC):
        print(f"[失败] 找不到源文件：{SRC}")
        return 1

    with open(SRC, "r", encoding="utf-8") as f:
        text = f.read()

    swatches = parse_swatches(text)

    # ★ 检查器自身先验一遍。踩过：检查器出错的表现和"代码有问题"一模一样。
    _selftest()
    # 再验一次「解析器真的从这份文件里读到了东西」
    if len(swatches) < 8:
        print(f"[失败] 只解析出 {len(swatches)} 个色块（至少应有 8 个）—— "
              f"可能是源文件写法变了，正则没跟上。")
        return 1

    failures = []

    # 1. light 互不相同
    lights = [s[1].upper() for s in swatches]
    dup = {h for h in lights if lights.count(h) > 1}
    if dup:
        failures.append(f"light 值重复：{', '.join(sorted(dup))}")

    # 2/3. 对比度
    for name, light, dark in swatches:
        cl = contrast(light, LIGHT_SURFACE)
        cd = contrast(dark, DARK_SURFACE)
        if cl < 3.0:
            failures.append(f"{name}({light}) 在浅色底上对比度 {cl:.2f}:1 < 3:1")
        if cd < 3.0:
            failures.append(f"{name}({light}/{dark}) 在深色底上对比度 {cd:.2f}:1 < 3:1")

        # 4. 深色块里的字
        ink = ink_for(dark)
        cb = contrast(dark, ink)
        if cb < 4.5:
            failures.append(f"{name} 深色块 {dark} 配 {ink} 字对比度 {cb:.2f}:1 < 4.5:1")
        # 浅色块里的字也要过 —— 课程表块在浅色模式下用的是 light 色
        ink_l = ink_for(light)
        cb_l = contrast(light, ink_l)
        if cb_l < 4.5:
            failures.append(f"{name} 浅色块 {light} 配 {ink_l} 字对比度 {cb_l:.2f}:1 < 4.5:1")

    if verbose:
        print("=" * 52)
        print("日历色板自检")
        print("=" * 52)
        print(f"色块数           : {len(swatches)}")
        for name, light, dark in swatches:
            print(f"  {name:<4} {light} 浅底 {contrast(light, LIGHT_SURFACE):5.2f}:1"
                  f"   {dark} 深底 {contrast(dark, DARK_SURFACE):5.2f}:1"
                  f"  块内字 {contrast(dark, ink_for(dark)):5.2f}:1")
        print("-" * 52)

    if failures:
        for f in failures:
            print(f"[失败] {f}")
        print(f"色板自检：0 通过 / {len(failures)} 失败")
        return 1

    print(f"色板自检：{len(swatches)} 项通过 / 0 失败")
    return 0


def _selftest() -> None:
    """检查器自检：拿手算过的样本验证解析和对比度公式。"""
    sample = '''
        .init(name: "蓝",   light: "#185FA5", dark: "#85B7EB"),
        .init(name: "灰",   light: "#5F5E5A", dark: "#B4B2A9"),
    '''
    got = parse_swatches(sample)
    assert len(got) == 2, f"解析器坏了：只认出 {len(got)} 个"
    assert got[0] == ("蓝", "#185FA5", "#85B7EB"), f"解析结果不对：{got[0]}"

    # 白对黑的对比度必须正好是 21:1 —— 公式写错的话这里立刻炸
    ratio = contrast("#FFFFFF", "#000000")
    assert abs(ratio - 21.0) < 0.01, f"对比度公式坏了：白/黑 = {ratio}"
    # 同一个颜色对自身 = 1:1
    assert abs(contrast("#185FA5", "#185FA5") - 1.0) < 0.001
    # 亮度阈值：纯白走深色字，纯黑走白字
    assert ink_for("#FFFFFF") == "#1A1A18"
    assert ink_for("#000000") == "#FFFFFF"


if __name__ == "__main__":
    sys.exit(run())
