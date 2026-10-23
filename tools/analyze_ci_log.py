#!/usr/bin/env python3
"""离线分析 xcodebuild 日志（从 CI artifact 里下回来的 full.log）。

## 为什么要有这个

CI 的 job 会被墙钟截断（GitHub 免费 macOS runner 单 job 上限 6 小时，
但实测这个仓库的 job 每次都在 **902 秒**被取消 —— 见下方「902 秒」一节）。
截断的那份日志里只有**一部分**编译错误 —— 因为 Swift 是并行编译的，
被砍掉一半的日志会缺掉一半的文件。

于是很容易犯一个错：把「日志里有 7 个错误」当成「一共有 7 个错误」。
实际上下一次跑可能会冒出另外 5 个。

这个脚本干两件事：

1. **判断日志是不是被截断的**
   看结尾有没有 `** BUILD SUCCEEDED **` / `** BUILD FAILED **`。
   两个都没有 = 这次构建没有结论，日志里看到的错误只是"已知的一部分"。

2. **判断是不是增量构建**
   一份全量构建日志里一定有 `SwiftCompile` / `CompileSwiftSources` 这样的行。
   如果整份日志一条都没有，却出现了 `lipo` / `Validate` / `Touch`，
   说明 DerivedData 被复用了 —— 什么都没重新编译，`BUILD SUCCEEDED`
   是拿旧产物拼出来的**假成功**。

   这一点踩过一次：那份 502 行的"成功日志"里 0 条 Swift 编译记录，
   而当时工作区里有 7 个真错误。

## 902 秒

观察到 4 次运行都是 `started -> completed` 恰好 902 秒，结论 `cancelled`。
连 39998822449 这次 push 触发的也是 902。这说明有外部东西在 902 秒时
掐掉 job（不是 concurrency —— 那个已经改成带 run_id 了），
最可能是仓库的 Actions 用量策略或某个组织的 timeout 覆盖。

在搞清楚之前，**不要相信任何一次 CI 的结果**，用本地的
`check_swift.py` + `find_isolation_issues.py` 顶住。

用法：
    python tools/analyze_ci_log.py <full.log> [<full.log> ...]
"""
import re
import sys

# xcodebuild 的错误行：  /path/File.swift:12:34: error: message
ERR_RE = re.compile(r":(\d+):(\d+): (error|warning|note): (.+)$")
# 把 runner 上的绝对路径裁成仓库内相对路径
PATH_RE = re.compile(r"(?:^|[\s(])((?:/[^:\s]+)*/(ThreeeAssistant/[^:\s]+)):\d+:\d+:")


def strip_path(line: str) -> str:
    m = PATH_RE.search(line)
    if m:
        return line.replace(m.group(1), m.group(2))
    return line


def analyze(path: str, verbose: bool = True) -> int:
    """返回真实错误数。截断/增量那种日志的错误数会再单独标出来。"""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"读不了 {path}: {e}")
        return 0

    lines = text.splitlines()

    # ---- 1. 有没有结论 ----
    if "** BUILD SUCCEEDED **" in text:
        verdict = "SUCCEEDED"
    elif "** BUILD FAILED **" in text:
        verdict = "FAILED"
    else:
        verdict = "NO VERDICT（被截断）"

    # ---- 2. 是不是增量构建 ----
    swift_compile_hits = len(
        re.findall(r"^(SwiftCompile|CompileSwiftSources|SwiftDriver|CompileSwift)\b",
                   text, re.M)
    )
    # 也可能是 "SwiftDriver Compilation" / "CompileC" 这种 target 层级写法
    swift_compile_hits += len(re.findall(r"SwiftCompile normal", text))
    incremental = swift_compile_hits == 0 and "lipo " in text

    # ---- 3. 错误/警告 ----
    errors, warnings = [], []
    for ln in lines:
        m = ERR_RE.search(ln)
        if not m:
            continue
        line_no, col, kind, msg = m.groups()
        clean = strip_path(ln).strip()
        if kind == "error":
            errors.append(clean)
        elif kind == "warning":
            warnings.append(clean)

    # 去重（同一个错误在 note 行里会重复出现）
    errors = sorted(set(errors))
    warnings = sorted(set(warnings))

    print("=" * 70)
    print(f"日志: {path}")
    print("=" * 70)
    print(f"行数          : {len(lines)}")
    print(f"Swift 编译记录: {swift_compile_hits} 条")
    print(f"结论          : {verdict}")
    if incremental:
        print("⚠️  **增量构建**：日志里没有任何 Swift 编译记录，"
              "却有链接/校验步骤。")
        print("   这表示 DerivedData 被复用，什么都没重编 —— "
              "此时的 BUILD SUCCEEDED 不能当数。")
    if verdict == "NO VERDICT":
        print("⚠️  **日志被截断**：没有 SUCCEEDED/FAILED 结尾。")
        print("   下面列出的错误只是「截断前已经报出来的那部分」，")
        print("   修完之后很可能还有别的。不要以为修完就干净了。")

    print(f"错误          : {len(errors)} 条")
    print(f"警告          : {len(warnings)} 条")

    if errors:
        print("-" * 70)
        print("错误清单：")
        for e in errors:
            print("  " + e)

    if verbose and warnings:
        # 警告默认只报个数。SwiftUI 的警告动辄几十条，
        # 全打出来会把真正的错误挤出屏幕
        print("-" * 70)
        print(f"（{len(warnings)} 条警告已省略，加 --warn 可查看）")
        if "--warn" in sys.argv:
            for w in warnings:
                print("  " + w)

    print()
    return len(errors)


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 1

    total = 0
    truncated = []
    incremental = []
    for p in args:
        total += analyze(p)
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                t = f.read()
        except OSError:
            continue
        if "** BUILD SUCCEEDED **" not in t and "** BUILD FAILED **" not in t:
            truncated.append(p)
        if not re.search(r"^(SwiftCompile|CompileSwiftSources|SwiftDriver|CompileSwift)\b",
                         t, re.M) and "lipo " in t:
            incremental.append(p)

    print("=" * 70)
    print(f"合计错误: {total} 条")
    if truncated:
        print(f"⚠️  被截断的日志 {len(truncated)} 份：")
        for p in truncated:
            print("   " + p)
        print("   → 这些日志里的错误数是下界，不是实数。")
    if incremental:
        print(f"⚠️  增量构建日志 {len(incremental)} 份（结论不可信）：")
        for p in incremental:
            print("   " + p)
    print("=" * 70)
    # 退出码按「有没有错误」定，方便脚本里串起来用
    return 0 if total == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
