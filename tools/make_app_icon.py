"""
生成 iOS App 图标：一个 1024 的主图，其余尺寸由 Xcode 从主图缩放。

## 为什么自己画而不是让 AI 生成

2026-11-03 试过一次 AI 生成，三个硬伤：
1. **自己加了圆角** —— iOS 会自动套 squircle 蒙版，预置圆角 = 双重圆角。
2. **右下角有水印**（"AI 生成 WORKBUDDY"）—— App Store 图标带水印直接被拒。
3. 书的主体太大，挤到画布边缘 —— 违反"关键元素在内 80%"。

这三条都不是"调提示词能解决"的，是生成模型的固有行为。
而图标恰恰是**像素级确定**的东西：边缘要锐、占比要准、颜色要是我们定的那个值。
所以用矢量代码画。

## 遵守的规则（来自 2026 的 iOS 图标设计惯例）

- 1024×1024，**无 alpha 通道**，**不带圆角**（iOS 自己加）
- 单一几何主体，占画布约 58~62%，全部落在内 80% 安全区
- **不放文字 / 字母** —— 60px 下会糊，且主屏图标下方本来就显示应用名
- 主屏图标不能有透明像素：PNG 必须是 RGB 不是 RGBA

## 用法

    python tools/make_app_icon.py            # 生成到 AppIcon.appiconset/
    python tools/make_app_icon.py --preview  # 额外在 .ci-tmp/icons 出一份 60px 预览
"""

from __future__ import annotations

import argparse
import math
import os
import sys

from PIL import Image, ImageDraw

# ============================================================
#  配色
# ------------------------------------------------------------
#  和 Theme.swift 的 teal600 / teal50 同源，这样图标和 App 内是同一个人做的。
#  选绿而不是蓝：iOS 教育/生产力类是蓝海，1Password、Notion、Things 都在蓝，
#  绿色在这片里更跳得出来；而且「学习」在中文语境里天然偏绿（成长、新芽）。
# ============================================================

BG_TOP = (15, 110, 86)      # #0F6E56  deep teal
BG_BOTTOM = (29, 158, 117)  # #1D9E75  brighter teal
INK = (255, 255, 255)       # 主体色
INK_SOFT = (225, 245, 238)  # 次级元素，几乎白但略暗，避免两个元素抢主导


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def mix_bg(t: float):
    """背景渐变在 t 处的颜色。用来给中缝取一个"透出背景"的颜色。"""
    return (lerp(BG_TOP[0], BG_BOTTOM[0], t),
            lerp(BG_TOP[1], BG_BOTTOM[1], t),
            lerp(BG_TOP[2], BG_BOTTOM[2], t))


def make_background(size: int) -> Image.Image:
    """竖直渐变。逐行填色 —— 行数就是高，1024 行很快。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = (lerp(BG_TOP[0], BG_BOTTOM[0], t),
             lerp(BG_TOP[1], BG_BOTTOM[1], t),
             lerp(BG_TOP[2], BG_BOTTOM[2], t))
        for x in range(size):
            px[x, y] = c
    return img


def draw_book(draw: ImageDraw.ImageDraw, size: int) -> None:
    """
    画一本「翻开的书」。

    ## 形状的关键：上缘是 V 形，书脊处最低

    第一版画反了 —— 把书脊画成了最高点、外侧往下溜，
    结果两个白色块中间收窄，看起来像**蝴蝶结**或沙漏，完全不像书。
    这个错误只有把图渲染出来看才发现，光读代码看不出来。

    真实的书摊在桌上：书脊在中间，两侧书页**向外翻起**，
    所以页面上缘在书脊处最低、往外逐渐升高（像一个很扁的 V）。
    底边基本是一条直线（书的下面是桌面）。

    方向定了，形状就成立了，60px 下也能一眼认出是书。
    """
    cx = size / 2

    half_w = size * 0.325
    spine_y = size * 0.618    # 书脊处上缘的谷底（最低点）
    outer_y = size * 0.492    # 外侧上缘的顶点（更高，y 更小）
    bottom_y = size * 0.745   # 书的下缘，直线

    def page(sign: int) -> list:
        """sign = -1 左页，+1 右页。"""
        xo = cx + sign * half_w
        pts = []

        # 上缘：书脊（低）→ 外侧（高）。
        # 控制点抬高一点，让曲线先缓后扬 —— 纸张翻起的手感。
        ctrl = (cx + sign * half_w * 0.52, spine_y - size * 0.082)
        for i in range(61):
            t = i / 60
            u = 1 - t
            x = u * u * cx + 2 * u * t * ctrl[0] + t * t * xo
            y = u * u * spine_y + 2 * u * t * ctrl[1] + t * t * outer_y
            pts.append((x, y))

        pts.append((xo, bottom_y))    # 外侧边，垂直到底
        pts.append((cx, bottom_y))    # 下缘，直线回书脊
        return pts

    draw.polygon(page(-1), fill=INK)
    draw.polygon(page(1), fill=INK)

    # 书脊中缝：一条细切口，把左右两页分开。
    # 没有它，两块白在书脊处连成一片，60px 下就只是一个白色梯形。
    # 缝做**等宽**的直缝，不要上宽下窄。
    # 末端收尖的话，缩到 60px 那条尖会断成一两个像素点，
    # 看起来像书脊中间有个洞。
    gap = size * 0.011
    draw.polygon(
        [
            (cx - gap, spine_y - size * 0.004),
            (cx + gap, spine_y - size * 0.004),
            (cx + gap, bottom_y),
            (cx - gap, bottom_y),
        ],
        fill=mix_bg(0.62),
    )



def draw_arc(draw: ImageDraw.ImageDraw, size: int) -> None:
    """
    书上方一道细弧 —— 表示"进度"，也是整个图标唯一的装饰。

    ## 为什么只留一道

    图标里每多一个元素，60px 下就多一份糊。书已经是主体，
    再加任何东西都是在跟它抢注意力。这道弧的价值是：
    让图标不是"书"的静态剪影，而带一点向上/在推进的意思。

    粗细按 1024 下 12px 算，缩到 60px 是 0.7px —— 刚好还在。
    再细就消失了，再粗就变成"帽子"。
    """
    cx = size / 2
    r = size * 0.208
    y = size * 0.392
    w = size * 0.0135

    # 只画上面 120 度那一段，两端留空
    draw.arc(
        [cx - r, y - r, cx + r, y + r],
        start=203, end=337,
        fill=INK_SOFT,
        width=int(round(w)),
    )


def build(size: int = 1024) -> Image.Image:
    img = make_background(size)
    d = ImageDraw.Draw(img)

    # 先画层级低的：弧在书后面
    draw_arc(d, size)
    draw_book(d, size)

    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None, help="输出目录，默认 AppIcon.appiconset")
    ap.add_argument("--preview", action="store_true", help="额外输出小尺寸预览")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    out_dir = args.out or os.path.join(
        root, "ThreeeAssistant", "Resources", "Assets.xcassets",
        "AppIcon.appiconset"
    )
    os.makedirs(out_dir, exist_ok=True)

    img = build(1024)

    # ⚠️ 必须转 RGB 再存：iOS 图标不能带 alpha。
    #    带 alpha 的 PNG 会被 App Store 直接拒，且本地不会有任何提示。
    img = img.convert("RGB")
    out_path = os.path.join(out_dir, "AppIcon.png")
    img.save(out_path, format="PNG", optimize=True)
    print(f"写出 {out_path}  {img.size[0]}x{img.size[1]}  {os.path.getsize(out_path)} 字节")

    if args.preview:
        prev_dir = os.path.join(root, ".ci-tmp", "icons")
        os.makedirs(prev_dir, exist_ok=True)
        for s in (180, 120, 60, 40, 29):
            p = img.resize((s, s), Image.LANCZOS)
            fp = os.path.join(prev_dir, f"preview-{s}.png")
            p.save(fp, format="PNG")
            print(f"  预览 {s}x{s} -> {fp}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
