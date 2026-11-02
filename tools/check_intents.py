#!/usr/bin/env python3
"""核对 App Intents 的 Siri 短语是否真的注册进产物了。

## 判据是什么（这里踩过一个大坑）

**不是**在可执行文件里 grep 短语字符串。

2026-11-02 我用「grep 二进制」的办法判断 `用\\(.applicationName)记一件事`
没被注册，因为它确实搜不到。据此改了短语、写了一大段解释、还提交推送了。
**结论是错的。** App Intents 的短语是编进
`<App>.app/Metadata.appintents/root.ssu.yaml` 的，
压根不进 Mach-O 的字符串区。别的短语能 grep 到纯属巧合
（它们恰好也被别的地方引用）。

真正的注册表长这样：

    nlu:
      shortcuts:
        bundleIdentifier: cn.threees.assistant.ios
        intents:
        - metadata:
            name: TodayEventsIntent_0
            title: 今天有什么安排
          corpuses:
            training:
            - locale: zh_CN
              utterances:
              - 用${+applicationName}看看今天有什么安排

所以本脚本做三件事：

1. 从源码里解析出「期望存在的短语」（`phrases: [...]` 里的字面量，
   插值 `\\(...)` 换成 SSU 的 `${...}` 占位）
2. 从 `root.ssu.yaml` 里解析出「实际注册的短语」
3. 两边做集合比较，缺什么、多什么，直接列出来

## 顺带检查的东西

- `Metadata.appintents` 是否存在（App Intents 压根没编进去时会缺）
- 每个 Intent 是否都在注册表里出现了

用法：
    python tools/check_intents.py ../dist/_x/ThreeeAssistant.app
    python tools/check_intents.py <解压后的 .app 目录>
"""
import os
import re
import sys

SRC = "ThreeeAssistant/Intents/ScheduleIntents.swift"


def expected_phrases(src_path: str = SRC):
    """从源码里解析 (intent_name, [短语]) 列表。

    `phrases: [` 之后、`]` 之前的部分。注释行（`//`）要剔掉，
    因为注释里可能写明了反例，会把匹配带偏 —— 这个文件里就写了。
    """
    src = open(src_path, encoding="utf-8").read()
    out = []
    # 逐个 AppShortcut(...) 块解析
    for m in re.finditer(r"AppShortcut\((.*?)\n        \)", src, re.S):
        chunk = m.group(1)
        intent = re.search(r"intent:\s*(\w+)\(\)", chunk)
        ph = re.search(r"phrases:\s*\[(.*?)\]", chunk, re.S)
        if not intent or not ph:
            continue
        # 去掉整行注释，避免注释里的示例被当成真短语
        body = "\n".join(
            ln for ln in ph.group(1).splitlines()
            if not ln.strip().startswith("//")
        )
        # 行尾注释也去掉
        body = re.sub(r"//[^\n]*", "", body)
        phrases = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
        out.append((intent.group(1), phrases))
    return out


def to_ssu(phrase: str) -> str:
    """Swift 插值 → SSU 占位。

    Swift 源的 `\\(.applicationName)` 在编译后是 `${+applicationName}`。
    ⚠️ 注意那个 `+`：SSU 里系统变量写作 `${+name}`，漏了它就会
    全部误判为「没注册」—— 第一版就是这么错的，7 条全报 ❌。
    """
    s = phrase
    # 参数槽位 `\\(\\.$title)` → ${+title}
    s = s.replace("\\(\\\\.$", "${+")
    # 系统变量 `\\(.applicationName)` → ${+applicationName}
    s = s.replace("\\(.", "${+")
    # 剩下的 `\(` 兜底
    s = s.replace("\\(", "${+")
    # 收尾：把「对应的那个右括号」换成 `}`。
    #
    # ⚠️ 这里**不能用正则**。第一版写了
    #     re.sub(r"\$\{\+([A-Za-z_.$]+)\)", r"${\1}", s)
    # 结果 `${+applicationName)` 里的 `+` 被分组吃掉了，输出变成
    # `${applicationName}`，于是与注册表里的 `${+applicationName}` 全不相等，
    # 7 条短语全报 ❌ —— 又是一次「检查器自己错，却指着代码说有问题」。
    # 改成手工扫描配对括号，不涉及任何转义。
    while True:
        i = s.find("${+")
        if i < 0:
            break
        j = s.find(")", i)
        if j < 0:
            break
        s = s[:j] + "}" + s[j + 1:]
    return s


def registered(app: str):
    p = os.path.join(app, "Metadata.appintents", "root.ssu.yaml")
    if not os.path.exists(p):
        return None
    txt = open(p, encoding="utf-8").read()
    return txt


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    app = sys.argv[1]
    if not app.endswith(".app"):
        print("请传 .app 目录（不是 .ipa）")
        return 1

    yaml = registered(app)
    if yaml is None:
        print(f"❌ {app} 里没有 Metadata.appintents/root.ssu.yaml")
        print("   说明 App Intents 根本没参与编译 —— 检查文件是否在 target 里。")
        return 1

    print(f"产物: {app}\n注册表: Metadata.appintents/root.ssu.yaml\n")

    # 实际注册的 utterance（去掉 ${...} 占位后变形，比较时还原）
    reg = re.findall(r"-\s*(.*\$\{\+applicationName\}.*|.*\$\{\+title\}.*)", yaml)
    reg = [r.strip() for r in reg]

    total = ok = 0
    for intent_name, phrases in expected_phrases():
        in_reg = f"name: {intent_name}_" in yaml or f"name: {intent_name}\n" in yaml
        print(f"{'✅' if in_reg else '❌'} {intent_name}"
              f"{'' if in_reg else '  ← 注册表里没有这个 Intent'}")
        for p in phrases:
            want = to_ssu(p)
            total += 1
            hit = want in reg or want.replace("${+title}", "${+title}") in reg
            if hit:
                ok += 1
                print(f"     ✅ {p}")
            else:
                print(f"     ❌ {p}")
                print(f"        期望 {want}")
                near = [r for r in reg if any(t in r for t in
                        re.findall(r"[\u4e00-\u9fa5]{2,}", p))]
                print(f"        实际同片段: {near}")
    print(f"\n短语 {total} 条，注册 {ok} 条")
    if ok < total:
        print("\n注意：注册表里的 utterance 用 ${+...} 表示插值。"
              "若上面 ❌ 的原因是格式对不上而不是真缺，"
              "直接看 root.ssu.yaml 里那段 utterances 最可靠。")
        return 1
    print("结论：全部短语都已注册。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
