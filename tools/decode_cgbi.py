"""解码 Apple CgBI 变体 PNG，肉眼确认包里的图标。

CgBI 与标准 PNG 的差别：
  1. IHDR 之后多一个私有 chunk `CgBI`（内容 4 字节：0x50 0x0B 0x00 0x00）
  2. IDAT 里是 raw deflate（无 zlib 头/尾），要 zlib.decompress(data, -15)
  3. 解出来的像素通道顺序是 BGRA，且每通道已按 alpha 预乘
  4. 部分文件还有 3 字节的 BRGA 预乘残留（Xcode 老版本），靠是否带 iPhone 优化头判断

用法：python tools/decode_cgbi.py <in.png> <out.png>
"""
import struct
import sys
import zlib

from PIL import Image


def _chunks(data):
    pos = 8
    while pos + 8 <= len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        yield typ, body


def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG")

    width = height = None
    bitdepth = colortype = None
    idat = b""
    has_cgbi = False

    for typ, body in _chunks(data):
        if typ == b"CgBI":
            has_cgbi = True
            continue
        if typ == b"IHDR":
            width, height, bitdepth, colortype = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break

    if width is None:
        raise ValueError("没有 IHDR")
    if bitdepth != 8:
        raise ValueError(f"bitdepth={bitdepth} 不支持")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colortype)
    if channels is None:
        raise ValueError(f"colortype={colortype} 不支持")

    raw = zlib.decompress(idat, -15) if has_cgbi else zlib.decompress(idat)

    stride = width * channels
    expected = (stride + 1) * height
    if len(raw) != expected:
        raise ValueError(f"解压后长度 {len(raw)}，期望 {expected}")

    # 逐行反滤波（与标准 PNG 相同）
    out = bytearray(stride * height)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 0:
            pass
        elif ft == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ValueError(f"第 {y} 行滤波类型 {ft} 未知")
        out[y * stride:(y + 1) * stride] = line
        prev = line

    # BGRA -> RGBA，并反预乘
    if channels == 4:
        for i in range(0, len(out), 4):
            b, g, r, a = out[i], out[i + 1], out[i + 2], out[i + 3]
            if a not in (0, 255):
                r = min(255, (r * 255 + a // 2) // a)
                g = min(255, (g * 255 + a // 2) // a)
                b = min(255, (b * 255 + a // 2) // a)
            out[i], out[i + 1], out[i + 2] = r, g, b

    mode = {1: "L", 2: "LA", 3: "RGB", 4: "RGBA"}[channels]
    return Image.frombytes(mode, (width, height), bytes(out))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    img = decode(sys.argv[1])
    img.save(sys.argv[2])
    print(f"{sys.argv[1]} -> {img.size} {img.mode} -> {sys.argv[2]}")
    # 采样四角与中心，判断是不是全绿（说明解出来是图标本体）
    w, h = img.size
    px = img.load()
    for name, (x, y) in {
        "左上": (2, 2), "右上": (w - 3, 2),
        "中心": (w // 2, h // 2),
        "左下": (2, h - 3), "右下": (w - 3, h - 3),
    }.items():
        print(f"  {name}: {px[x, y]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
