#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对比服务端 routes.go 与 iOS 客户端实际调用的接口。

## 为什么要有这个脚本

「服务端有 160 多个接口，客户端接了几条？」这个问题靠脑子记永远错。
每次要回答它，都得重新 grep 两遍、还要处理 Swift 的字符串插值
（`/api/events/<反斜杠>(eventID)`）和 Go 的路径参数（`/api/events/{id}`）写法不同 ——
手工比一次就够烦了，比第二次必然出错。

这个脚本把两边都规范化成 `/api/xxx/:id` 再比，输出三个桶：
  1. 已接线
  2. 未接线（需要判断该不该做）
  3. 客户端调了但服务端没有（**这个最要紧**：拼错路径、接口改名，
     都会表现成这样，而且运行时才 404）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_ROUTES = os.path.join(
    ROOT, "..", ".src", "3e-源码包", "server", "internal", "app", "routes.go")
CLIENT_DIR = os.path.join(ROOT, "ThreeeAssistant", "Core")


def norm(path):
    """把 `{id}` 和 Swift 的 `\\(x)` 统一成 `:id`，便于比较。"""
    path = re.sub(r"\\\([^)]*\)", ":id", path)
    path = re.sub(r"\{[^}]*\}", ":id", path)
    # 去掉尾部斜杠
    return path.rstrip("/")


def server_routes():
    """返回 [(method, path)]，path 已规范化。"""
    if not os.path.isfile(SERVER_ROUTES):
        print("找不到服务端路由表：%s" % SERVER_ROUTES, file=sys.stderr)
        return []
    src = open(SERVER_ROUTES, encoding="utf-8").read()
    out = []
    for m in re.finditer(r'"(GET|POST|PUT|DELETE|HEAD|PATCH)\s+(/api[^"]*)"', src):
        out.append((m.group(1), norm(m.group(2))))
    return out


def client_paths():
    """返回 {path: [出现的文件]}，path 已规范化。"""
    found = {}
    for fn in sorted(os.listdir(CLIENT_DIR)):
        if not fn.endswith(".swift"):
            continue
        src = open(os.path.join(CLIENT_DIR, fn), encoding="utf-8").read()
        # 去掉注释，避免把注释里提到的路径算成"已接线"
        src = re.sub(r"//[^\n]*", "", src)
        for m in re.finditer(r'"(/api/[^"]*)"', src):
            found.setdefault(norm(m.group(1)), []).append(fn)
    return found


def main():
    srv = server_routes()
    srv_paths = set(p for _, p in srv)
    cli = client_paths()
    cli_paths = set(cli.keys())

    covered = sorted(srv_paths & cli_paths)
    missing = sorted(srv_paths - cli_paths)
    phantom = sorted(cli_paths - srv_paths)

    print("=" * 66)
    print("接口覆盖度（服务端 routes.go vs iOS Core/*.swift）")
    print("=" * 66)
    print("服务端路由 %d 条（去重后 %d 个路径）" % (len(srv), len(srv_paths)))
    print("客户端调用 %d 个路径" % len(cli_paths))
    print("已接线     %d" % len(covered))
    print("未接线     %d" % len(missing))
    print("-" * 66)

    if phantom:
        print("⚠️ 客户端调用了服务端不存在的路径（多半是拼错或接口改名）：")
        for p in phantom:
            print("   %-52s %s" % (p, ", ".join(sorted(set(cli[p])))))
        print("-" * 66)

    print("未接线清单：")
    for p in missing:
        methods = sorted(set(m for m, pp in srv if pp == p))
        print("   %-8s %s" % ("/".join(methods), p))
    print("=" * 66)

    # 只有"客户端调了不存在的路径"算硬错误 —— 未接线是待决策，不是错
    return 1 if phantom else 0


if __name__ == "__main__":
    sys.exit(main())
