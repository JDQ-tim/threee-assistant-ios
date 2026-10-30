#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
无 Swift 编译器时的源码粗检。
不做类型检查（做不到），只查那些「一定会让编译器报错」的机械性错误。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "ThreeeAssistant")

errors = []
warns = []
files = []

for dirpath, dirnames, filenames in os.walk(SRC):
    dirnames.sort()
    for fn in sorted(filenames):
        if fn.endswith(".swift"):
            files.append(os.path.join(dirpath, fn))
files.sort()


def strip_noise(s):
    """去掉字符串字面量、注释、多行字符串，避免误判括号。"""
    out = []
    i = 0
    n = len(s)
    in_line_comment = False
    in_block_comment = 0
    in_string = False
    in_multiline = False
    while i < n:
        ch = s[i]
        nxt = s[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append("\n")
            i += 1
            continue

        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment -= 1
                i += 2
                continue
            if ch == "/" and nxt == "*":
                in_block_comment += 1
                i += 2
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue

        if in_multiline:
            if s.startswith('"""', i):
                in_multiline = False
                i += 3
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue

        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue

        if s.startswith("//", i):
            in_line_comment = True
            i += 2
            continue
        if s.startswith("/*", i):
            in_block_comment = 1
            i += 2
            continue
        if s.startswith('"""', i):
            in_multiline = True
            i += 3
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


for path in files:
    rel = os.path.relpath(path, ROOT).replace("\\", "/")
    raw = open(path, encoding="utf-8").read()
    clean = strip_noise(raw)

    # 1. 括号配平
    for open_ch, close_ch, name in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        d = 0
        bad = False
        for ch in clean:
            if ch == open_ch:
                d += 1
            elif ch == close_ch:
                d -= 1
                if d < 0:
                    bad = True
                    break
        if bad or d != 0:
            errors.append("%s: %s不配平（最终深度 %d）" % (rel, name, d))

    # 2. 行尾多余分号（Swift 允许，但通常是笔误）
    # 3. `if let x {` 这种 Swift 5.7+ 简写
    #
    # ⚠️ 以前这里写的是「工程 SWIFT_VERSION=5.0，一律不能用」——**这是错的**。
    #    `if let x {` 是**编译器**特性（Swift 5.7 起），不是语言模式开关，
    #    跟 SWIFT_VERSION 填 5.0 还是 5.9 无关，照样能编。
    #    真正决定能不能用的是 Xcode 版本（本工程 iOS 17 最低版本已要求 Xcode 15）。
    #    所以这条降级成纯提示，且不阻塞；SWIFT_VERSION 也已改成 5.9。
    #    留着只是为了「一眼看到工程里用了哪些较新语法」。
    for idx, line in enumerate(raw.splitlines(), 1):
        stripped = line.strip()
        # 三种形式都要抓：单独的 `{`、逗号接条件的、逗号接 `,` 的。
        if re.match(r"^(if|guard)\s+let\s+(\w+)\s*\{", stripped) or \
           re.match(r"^(if|guard)\s+let\s+(\w+)\s*,", stripped):
            warns.append("%s:%d 用了 `if/guard let x {` 简写（Swift 5.7+ 语法，"
                         "需 Xcode 15+）: %s" % (rel, idx, stripped[:70]))
        if re.match(r"^if\s+(let\s+)?\w+(\?|\.isEmpty)?\s*\{", stripped) is None and \
           re.search(r"\bif\s+let\s+\w+\s*\}", stripped):
            pass

        # ⚠️ `guard ... else { someCall() }` 单行写法 —— 编译错误。
        #    guard 的 else 块必须以 return / throw / break / continue / fatalError 结尾，
        #    否则编译器报 "`guard` body must not fall through"。
        #    这个坑真的踩过：`guard !p.isEmpty else { dismiss() }` 编译失败。
        m = re.match(r"^guard\b.*?\belse\s*\{(.*)\}\s*$", stripped)
        if m:
            tail = m.group(1).strip().rstrip(";").strip()
            last = re.split(r"[;\s]+", tail)[-1] if tail else ""
            if last not in ("return", "throw", "break", "continue") and \
               not last.startswith("fatalError") and \
               not re.match(r"^(return|throw)\b", tail):
                errors.append("%s:%d guard 的 else 块没有以 return/throw 结尾"
                              "（会报 body must not fall through）: %s"
                              % (rel, idx, stripped[:70]))

    # 4. 明显的未使用 import 不查（没意义），改查 import UIKit 必须在 iOS 上
    # 5. 检查文件非空
    if len(raw.strip()) == 0:
        errors.append("%s: 空文件" % rel)

# 6. @main 只能有一个
main_count = 0
for path in files:
    if re.search(r"^@main\b", open(path, encoding="utf-8").read(), re.M):
        main_count += 1
if main_count != 1:
    errors.append("`@main` 出现 %d 次，必须正好 1 次" % main_count)


# ============================================================
#  7. 跨文件符号引用检查
#  ------------------------------------------------------------
#  云端 macOS runner 经常排不上队（公开仓库 + 新账号优先级低），
#  本地又装不了 Swift 编译器，所以这里手工补几条「一定能编译过」的检查。
#
#  这些检查针对的都是**真实踩过的坑**：Theme 里不存在的成员、
#  改了签名忘了改调用点、手写 init(from:) 忘了 encode(to:)。
# ============================================================

ALL_SRC = {}
for path in files:
    ALL_SRC[os.path.relpath(path, ROOT).replace("\\", "/")] = open(path, encoding="utf-8").read()

ALL_TEXT = "\n".join(ALL_SRC.values())


def _norm(rel_path):
    """把 rel 路径变成显示用（截断到文件名）"""
    return rel_path


# 7a. `Theme.xxx` 引用必须在 Theme.swift 里定义过
theme_path = [p for p in ALL_SRC if p.endswith("Design/Theme.swift")]
if theme_path:
    theme_src = ALL_SRC[theme_path[0]]
    defined = set(re.findall(r"static\s+(?:let|var)\s+(\w+)", theme_src))
    defined |= set(re.findall(r"static\s+func\s+(\w+)", theme_src))
    for rel, src in ALL_SRC.items():
        # ⚠️ 必须先剥掉注释再匹配 —— 注释里出现 `Theme.kt` 这种文件名
        #    会被误判成「引用了不存在的成员」。第一版就踩了这个。
        for m in re.finditer(r"\bTheme\.(\w+)", strip_noise(src)):
            name = m.group(1)
            if name not in defined:
                line = strip_noise(src)[: m.start()].count("\n") + 1
                errors.append("%s:%d 引用了不存在的 Theme.%s" % (rel, line, name))


# 7b. 手写了 init(from:) 的 **Codable** 类型，必须也有 encode(to:)
#
# ⚠️ 只对 `Codable` 成立，不能套到 `Decodable` 上。
#    `Codable = Encodable & Decodable`：一旦自己写了 init(from:)，
#    Swift 不再自动合成 encode(to:)，两边都得有。
#    但 `Decodable` 只有一个方向，写了 init(from:) 就完整了 ——
#    早先这里把 Decodable 也算进来，HealthDTO 因此被误报成编译错误。
for rel, src in ALL_SRC.items():
    if "init(from decoder:" not in src:
        continue
    # 按 struct 切段，逐段判断
    for m in re.finditer(r"struct\s+(\w+)[^{]*\{", src):
        name = m.group(1)
        start = m.end()
        # 粗略取到下一个 struct 开头
        nxt = src.find("\nstruct ", start)
        body = src[start: nxt if nxt != -1 else len(src)]
        decl = src[m.start(): m.end()]
        # 只关心真正要求双向的类型：Codable / Encodable
        needs_both = ("Codable" in decl) or ("Encodable" in decl)
        if not needs_both:
            continue
        if "init(from decoder:" in body and "func encode(to encoder:" not in body:
            errors.append("%s: struct %s 是 Codable 又手写了 init(from:)，"
                          "但没有 encode(to:)（编译器不再自动合成，两个都得有）"
                          % (rel, name))


# 7c. SessionStore 方法调用点的**参数标签**校验
#
# 改了签名忘了改调用点，编译器会报 "extra argument"/"missing argument"，
# 但云端 runner 经常排不上队，所以这里提前拦住。
#
# ⚠️ 必须先 strip_noise 再匹配：调用点里常有跨行注释
#    （比如 createEvent 调用中间夹了三行说明），
#    直接对原文扫描会把标签和注释搅在一起，产生假报。
store_path = [p for p in ALL_SRC if p.endswith("Core/SessionStore.swift")]
if store_path:
    store_clean = strip_noise(ALL_SRC[store_path[0]])

    def _split_top(s, sep=","):
        parts = []
        depth = 0
        cur = ""
        for ch in s:
            if ch in "([<{":
                depth += 1
            elif ch in ")]>}":
                depth -= 1
            if ch == sep and depth == 0:
                parts.append(cur)
                cur = ""
                continue
            cur += ch
        if cur.strip():
            parts.append(cur)
        return parts

    def _params(tail):
        """返回 [(外部标签 or None, 是否有默认值)]"""
        out = []
        for p in _split_top(tail):
            if ":" not in p:
                continue
            head, rest = p.split(":", 1)
            head = re.sub(r"@\w+\s*", "", head).replace("inout ", "").strip()
            toks = head.split()
            if not toks:
                continue
            # Swift 规则：写了两个词，第一个是外部标签；
            # 只写一个词，外部标签就等于内部名。
            ext = toks[0] if len(toks) >= 2 else toks[0]
            out.append((None if ext == "_" else ext, "=" in rest))
        return out

    sig2 = {}
    for m in re.finditer(
        r"func\s+(\w+)\s*\((.*?)\)\s*(?:async\s*)?(?:throws\s*)?(?:->[^{]+)?\{",
        store_clean, re.S,
    ):
        sig2[m.group(1)] = _params(m.group(2))

    for rel, raw in ALL_SRC.items():
        clean = strip_noise(raw)
        for m in re.finditer(r"\bstore\.(\w+)\(", clean):
            fname = m.group(1)
            if fname not in sig2:
                continue
            i = m.end() - 1
            depth = 0
            body = ""
            while i < len(clean):
                ch = clean[i]
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        break
                if depth >= 1:
                    body += ch
                i += 1

            used = set()
            for t in _split_top(body[1:]):
                mm = re.match(r"\s*(\w+)\s*:", t)
                if mm:
                    used.add(mm.group(1))

            allowed = set(lb for lb, _ in sig2[fname] if lb)
            required = set(lb for lb, hd in sig2[fname] if lb and not hd)
            line = clean[: m.start()].count("\n") + 1

            extra = used - allowed
            miss = required - used
            if extra:
                errors.append("%s:%d store.%s 传了不存在的参数 %s"
                              % (rel, line, fname, sorted(extra)))
            if miss:
                errors.append("%s:%d store.%s 少传必填参数 %s"
                              % (rel, line, fname, sorted(miss)))


# 7d. ===== SwiftUI View 必须显式 @MainActor =====
#
# 云端 runner 是 **Xcode 15.4 + iOS 17.5 SDK**。该 SDK 里 SwiftUI 的
# `View.body` 是**非隔离**上下文 —— 于是在 body（以及 body 里的按钮闭包）
# 读 `@MainActor` 的 SessionStore 成员会直接编译失败：
#
#   error: main actor-isolated property 'isLoading' can not be referenced
#          from a non-isolated context
#
# Xcode 16 起 SDK 给 body 补了 @MainActor，同样的代码就能过。
# 这解释了「本地静态检查全绿、云端 35 个错」。
#
# 修法：每个 `struct Xxx: View` 前面加 `@MainActor`。
# 这在语义上也是对的 —— SwiftUI 的 view 更新本来就只在主线程发生。
#
# 这个检查同时保证了「以后新加的 View 不会退化」。
VIEW_DECL = re.compile(r"^(\s*)(?:public\s+|internal\s+)?(?:struct\s+\w+[^\n]*:\s*View\b)", re.M)

for rel, src in ALL_SRC.items():
    clean = strip_noise(src)
    lines = clean.splitlines()
    for i, line in enumerate(lines):
        m = VIEW_DECL.match(line)
        if not m:
            continue
        # 往上找 3 行，看是否有 @MainActor
        has = any("@MainActor" in (lines[j] or "") for j in range(max(0, i - 3), i))
        if not has:
            errors.append("%s:%d 声明了 `: View` 但没标 @MainActor"
                          "（Xcode 15.4 的 iOS 17.5 SDK 下 body 是非隔离上下文，"
                          "读 store 会编译失败）: %s" % (rel, i + 1, line.strip()[:60]))

# 7e. `Task { }` 里捕获可变 `var` —— 编译错误
#     （"reference to captured var 'x' in concurrently-executing code"）
#
# 这个坑踩过：EditEventSheet 里
#     var occurrencePatch = p
#     occurrencePatch.strong = nil
#     Task { ... patch: occurrencePatch ... }
# 编译器拒绝。改法是造个新值再赋给 let。
for rel, src in ALL_SRC.items():
    clean = strip_noise(src)
    lines = clean.split("\n")
    for i, line in enumerate(lines):
        dm = re.match(r"\s*var\s+(\w+)\s*[:=]", line)
        if not dm:
            continue
        name = dm.group(1)
        # 往后 40 行内找 Task {，再在 Task 体内找这个名字
        for j in range(i + 1, min(i + 41, len(lines))):
            if re.match(r"\s*(?:private\s+)?func\s+", lines[j]):
                break
            if re.search(r"\bTask\s*(?:<[^>]*>)?\s*\{", lines[j]):
                body = "\n".join(lines[j: min(j + 60, len(lines))])
                if re.search(r"\b%s\b" % re.escape(name), body):
                    errors.append(
                        "%s:%d var %s 被后面的 Task 闭包捕获"
                        "（报 captured var in concurrently-executing code，需改成 let）"
                        % (rel, i + 1, name))
                break

# 7f. `some View` 的**计算属性**里有多个顶层表达式 —— 编译错误
#
# 踩过：WeatherLocationView 里
#     private var editSection: some View {
#         Section { ... }        // 第一个被丢掉
#         if isAdmin { Section { ... } }
#     }
# 报两条看起来毫无关系的错：
#   · result of 'Section<...>' initializer is unused
#   · function declares an opaque return type, but has no return statements
#
# 注意：`var body: some View` **不受影响**，因为 body 隐式带 @ViewBuilder。
# 所以这条只查「非 body 的、手写 some View 的属性」。
for rel, src in ALL_SRC.items():
    clean = strip_noise(src)
    lines = clean.split("\n")

    i = 0
    while i < len(lines):
        m = re.match(r"\s*(?:private\s+|internal\s+)?var\s+(\w+)\s*:\s*some\s+(\w+)\s*\{", lines[i])
        if not m or m.group(1) == "body":
            i += 1
            continue
        attr_name, proto = m.group(1), m.group(2)
        # ⚠️ `{` 后面可能还跟着内容（`var x: some View {   VStack {`）。
        #    要把它当成「属性体的第一行」，否则后面几行的深度会整体错位，
        #    把体里的内容全当成顶层语句，误报成「多个表达式」。
        tail = lines[i][m.end():].strip()
        # 找属性体的结束（花括号配平）
        depth = lines[i].count("{") - lines[i].count("}")
        body_lines = []
        if depth > 0 and tail:
            body_lines.append(tail)
        j = i + 1
        while j < len(lines) and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            if depth > 0:
                body_lines.append(lines[j])
            j += 1
        # 统计**深度为 0** 的语句起始行：直接写在属性体里的表达式
        d = 0
        top_stmts = []
        for bl in body_lines:
            stripped = bl.strip()
            if d == 0 and stripped and not stripped.startswith("//"):
                top_stmts.append(stripped)
            d += bl.count("{") - bl.count("}")
        # 顶层一条语句本来就是一个表达式时（如 `if` / `Group {`），没问题。
        # 顶层出现**多处**「大写类型名开头的构造调用」才是问题。
        exprs = [s for s in top_stmts
                 if re.match(r"^[A-Z]\w*\s*[\{\(]", s)]
        if len(exprs) > 1:
            errors.append(
                "%s:%d `var %s: some %s` 里有 %d 个顶层视图表达式"
                "（some 只允许一个返回值，会报 opaque return type / unused result；"
                "用 Group { } 包起来）"
                % (rel, i + 1, attr_name, proto, len(exprs)))
        i = max(j, i + 1)

# 7g. 把 `let` 属性当 Binding 传进 TextField / Toggle —— 编译错误
#
# 踩过：CoursePeriod 四个字段都是 `let`，而节次编辑页写
#     TextField("名称", text: row.label)     // row 是 Binding<CoursePeriod>
# 报 cannot assign to property: 'label' is a 'let' constant。
# 判据：全工程 `let X` 声明过的字段名 ∩ 出现在 Binding 位置。
#
# ⚠️ 只认**带缩进 4 格的成员声明**（`    let x: T`）。
#    不加这个限制的话，`guard let start = dtstartUTC` 这种**局部变量**
#    也会被收进来，于是无关文件里的 `xxx.start` 全部误报。
#
# ⚠️⚠️ 这条规则是**按名字**匹配的，天生会跨类型误报：
#      `FieldBox.label`（let）和 `CoursePeriod.label`（var）同名，
#      于是全工程任何 `TextField(text: x.label)` 都被判成错。
#      本来想再加一层「按类型名追溯」，但那要靠 Swift 语法树，静态文本做不到。
#
#      最后的选择：**这条规则降级成「提示」，不算错误**。
#      理由：它真正要挡的是「把模型字段定成 let 又想用 Binding 改」，
#      这种错误云端一定会报、而且报得很清楚（cannot assign to property），
#      本地漏掉它代价小；而误报会让整条检查线失去可信度 ——
#      一旦开始习惯性忽略红字，其它真错误也会被一起忽略。
let_fields = set()
for rel, src in ALL_SRC.items():
    for m in re.finditer(r"^\s{2,8}(?:private\s+|public\s+)?let\s+(\w+)\s*:\s*\S",
                         strip_noise(src), re.M):
        let_fields.add(m.group(1))

for rel, src in ALL_SRC.items():
    clean = strip_noise(src)
    for idx, line in enumerate(clean.split("\n"), 1):
        for m in re.finditer(
                r"\b(TextField|SecureField|Toggle|Picker|Slider|Stepper)\s*\([^\n]*?"
                r"\b(?:text|isOn|selection)\s*:\s*\w+\.(\w+)", line):
            field = m.group(2)
            if field in let_fields:
                warns.append(
                    "%s:%d `.%s` 可能是 let 属性，却又当 Binding 传进 %s"
                    "（若它是模型字段，需声明成 var）"
                    % (rel, idx, field, m.group(1)))

# 7h. `$store.xxx` 但作用域里没有 `@Bindable var store = store` —— 编译错误
#
# 踩过：RegisterView 写了 `@Environment(SessionStore.self) private var store`，
# 然后 `TextField("...", text: $store.serverText)`。
# 报 `cannot find '$store' in scope`。
#
# 原因：`@Environment` 注进来的是**只读**值，取不到投影（`$`）。
# 想拿 Binding，必须在 `var body` **里**再落一个局部变量：
#     @Bindable var store = store
#
# ⚠️ 不能写成属性 `@Bindable private var store = store`：
#    `@Bindable` 要从已有实例初始化，而属性初始化时环境还没注入。
#
# 这条规则查得很死：只要文件里出现 `$store.`，就要求同文件里有
# `@Bindable var store = store` 这一行。名字固定成 store 是刻意的 ——
# 工程里 Observable 环境对象就叫这个，换名字等于换约定，届时规则要同步改。
#
# ⚠️ 按**作用域**判，不是按文件判。
#
#    第一版是按文件判的（「文件里有 @Bindable 就放行」），结果漏报：
#    RegisterView 的 body 里有那一行，但 `$store` 出现在另外两个**计算属性**
#    （probeFailedBox / form）里 —— body 内声明的局部变量作用域不覆盖它们，
#    云端照样报 `cannot find '$store' in scope`。
#
#    所以现在改成：找出每个 `$store.` 所在的最内层声明块
#    （`var body` / `var form` / `func xxx ... {`），
#    再看那个块的**开头部分**有没有 `@Bindable var store = store`。
#    块怎么找：从 `$store.` 往上扫，遇到「缩进更浅且以 { 结尾或以 func/var 开头的行」
#    就认为是块头。

def _enclosing_scope_start(lines, idx):
    """从 idx 行往上找最内层**声明**块的头行号；找不到返回 0。

    只认声明块（`var body {` / `func xxx(...) -> some View {`），
    不认调用闭包（`FieldBox(label: "...") {` / `VStack {`）——
    闭包在 Swift 里是会捕获外层局部变量的，`@Bindable` 声明在外面就够了。
    第一版没区分，于是 `FieldBox { }` 里用 `$store` 全被误报。
    """
    cur = len(lines[idx]) - len(lines[idx].lstrip())
    decl = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"          # 可能带 @MainActor / @ViewBuilder
        r"(?:private\s+|public\s+|internal\s+|fileprivate\s+)?"
        r"(?:static\s+)?"
        r"(?:func|var|let|init|subscript)\b")
    for j in range(idx - 1, -1, -1):
        s = lines[j]
        if not s.strip():
            continue
        ind = len(s) - len(s.lstrip())
        if ind < cur and s.rstrip().endswith("{") and decl.match(s):
            return j
    return 0


for rel, src in ALL_SRC.items():
    clean = strip_noise(src)
    if "$store." not in clean:
        continue
    lines = clean.split("\n")

    # 先把所有 `@Bindable var store = store` 的行号记下来
    bindable_lines = {j for j, s in enumerate(lines)
                      if re.search(r"@Bindable\s+var\s+store\s*=\s*store\b", s)}

    reported = set()
    for idx, line in enumerate(lines):
        if "$store." not in line:
            continue
        head = _enclosing_scope_start(lines, idx)
        # 这个块的头到 `$store.` 之间有没有那条 @Bindable
        if any(head <= b < idx for b in bindable_lines):
            continue
        if head in reported:
            continue
        reported.add(head)
        # 块头第一行的简短描述，方便一眼认出是哪个属性
        head_text = lines[head].strip()[:60] if head < len(lines) else "（文件顶层）"
        errors.append(
            "%s:%d 用了 `$store.xxx`，但它所在的作用域「%s」里没有 "
            "`@Bindable var store = store`。\n"
            "         └ body 里声明的那份作用域只在 body 内；"
            "在这个属性/函数的第一行加 `@Bindable var store = store`"
            % (rel, idx + 1, head_text))

# ============================================================
#  检查 A：Optional 链式调用后再调 String 扩展
#  ------------------------------------------------------------
#  CI 报过：`store.user?.name.nonEmpty(or:)` →
#  "value of type 'String' has no member 'nonEmpty'"
#
#  根因：`?.` 的作用是"取到 nil 就停在这里"。`store.user?.name`
#  整体是 String?，但 `.nonEmpty` 是 **String 的扩展**，不是
#  Optional 的 —— 于是编译器在 String 上找 nonEmpty，找不到。
#
#  形状：a?.b.method(...)  其中 method 定义在 String 等非可选类型上
#  正确写法：(a?.b ?? "").method(...)  或把扩展定义在 Optional 上
#
#  这里不做完整类型推断，只抓最典型的「可空链 + 已知 String 扩展」组合。
# ============================================================

# 从源码里自动收集「定义在 String 扩展上的方法名」，
# 而不是硬编码一份清单 —— 硬编码的清单迟早和代码脱节。
#
# ⚠️ 关键的区分：
#   - `extension String { func f() }`           → 只能对非可选 String 调用
#   - `extension Optional where Wrapped == String
#      { func f() }`                            → 可以对 String? 直接调用
#   后者存在时，`a?.b.f()` 是**合法**的（f 就定义在 Optional 上）。
#   这个项目里 `nonEmpty(or:)` 正好属于后者，所以正确的代码不能报错。
_string_only_methods = set()
_optional_string_methods = set()
for _p in files:
    _src = open(_p, encoding="utf-8", errors="replace").read()

    for _m in re.finditer(
            r"extension\s+String\s*\{((?:[^{}]|\{[^{}]*\})*)", _src):
        for _mm in re.finditer(r"func\s+(\w+)\s*\(", _m.group(1)):
            _string_only_methods.add(_mm.group(1))

    for _m in re.finditer(
            r"extension\s+Optional\s+where\s+Wrapped\s*==\s*String\s*\{"
            r"((?:[^{}]|\{[^{}]*\})*)", _src):
        for _mm in re.finditer(r"func\s+(\w+)\s*\(", _m.group(1)):
            _optional_string_methods.add(_mm.group(1))

# 同一个名字可能两处都有（一般不会），那就当成可选版处理，宁可不报
_cannot_chain = _string_only_methods - _optional_string_methods

for p in files:
    rel = os.path.relpath(p, ROOT).replace("\\", "/")
    src = open(p, encoding="utf-8", errors="replace").read()
    for idx, line in enumerate(src.split("\n"), 1):
        # 形状： xxx?.yyy.zzz(   —— 即 `?.` 之后又跟了至少一层 `.`
        for m in re.finditer(r"\w+\?\.(?:\w+\.)+(\w+)\s*\(", line):
            name = m.group(1)
            if name in _cannot_chain:
                errors.append(
                    "%s:%d `?.` 链之后调用了 String 扩展 `%s`，"
                    "这里实际是 Optional，编译器会报 "
                    "\"value of type 'String' has no member '%s'\"。\n"
                    "         └ 改成 `(可空表达式 ?? \"\").%s(...)`，"
                    "或把方法定义在 `extension Optional where Wrapped == String` 上"
                    % (rel, idx, name, name, name))

# ============================================================
#  检查 B：View 的必填参数没传
#  ------------------------------------------------------------
#  CI 报过：`CalendarInvitesView()` → "missing argument for parameter 'calendarID'"
#
#  出现场景：把一个**需要上下文**的页面（比如按日历维度的邀请码管理）
#  当成全局页面挂上去。编译器会拦，但只有真编译时才知道；
#  这类错误在"重构导航层级"时几乎必然会冒出来，值得机械检查。
#
#  ⚠️ 判"必填"的三个条件缺一不可，否则就是误报：
#    1. 类型不是 Optional（`((() -> Void)?` 这种可以不传）
#    2. 没有默认值（`= nil`、`= []`、`= ""` 都不算必填）
#    3. 属于**这个** View 自己的属性，不是它内部嵌套类型的属性
#       （`SyncStatusView` 里面嵌套定义的那些 icon/detail/errors
#        是内层小 View 的字段，和它自己的初始化毫无关系）
# ============================================================


def _own_props_decl(src, body_start):
    """取 struct body 开头到第一个 body/init/func **之前**的声明区，
    并且按大括号深度跳过嵌套类型体内的内容。"""
    out = []
    depth = 1
    i = body_start
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == "{":
            depth += 1
            # 进入嵌套类型/属性观察器：整段跳过
            inner = 1
            j = i + 1
            while j < n and inner > 0:
                if src[j] == "{":
                    inner += 1
                elif src[j] == "}":
                    inner -= 1
                j += 1
            i = j
            continue
        if ch == "}":
            depth -= 1
            if depth == 0:
                break
            i += 1
            continue
        # 到第一个 var body 就停 —— 后面的都是实现，不是声明
        if src.startswith("var body", i) and (i == 0 or src[i - 1] in " \n"):
            break
        if src.startswith("init(", i):
            break
        out.append(ch)
        i += 1
    return "".join(out)


_required = {}
for p in files:
    src = open(p, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"struct\s+(\w+)\s*:\s*View\s*\{", src):
        name = m.group(1)
        decl = _own_props_decl(src, m.end())
        props = []
        for pm in re.finditer(
                r"^\s+(?:let|var)\s+(\w+)\s*:\s*([^\n]+?)\s*$", decl, re.M):
            pname, ptype = pm.group(1), pm.group(2).strip()
            # 属性包装器（@State/@Environment/@Bindable…）一律不算必填：
            # 它们由 SwiftUI 注入或自带初值
            line_start = decl.rfind("\n", 0, pm.start()) + 1
            if decl[line_start:pm.start()].strip().startswith("@"):
                continue
            # 有默认值 → 不必填
            if "=" in ptype:
                continue
            # Optional → 不必填
            if ptype.endswith("?"):
                continue
            props.append(pname)
        if props:
            _required[name] = props

for p in files:
    rel = os.path.relpath(p, ROOT).replace("\\", "/")
    src = open(p, encoding="utf-8", errors="replace").read()
    for name, params in _required.items():
        for m in re.finditer(r"\b%s\s*\(" % re.escape(name), src):
            head = src[max(0, m.start() - 30):m.start()]
            if re.search(r"struct\s+$", head):
                continue
            i = m.end()
            depth = 1
            while i < len(src) and depth > 0:
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                i += 1
            args = src[m.end():i - 1]

            # 尾随闭包：`Foo(a: 1) { ... }` 里的 `{...}` 会绑定到
            # 最后一个 **无默认值** 的闭包参数上（Swift 的规则）。
            # 不识别这个就会把 `CreateCalendarInviteSheet(calendarID: x) { ... }`
            # 误报成"缺 onCreated"。所以只看括号后面有没有紧跟 `{`。
            j = i
            while j < len(src) and src[j] in " \t\n":
                j += 1
            has_trailing_closure = j < len(src) and src[j] == "{"

            line = src[:m.start()].count("\n") + 1
            missing = [a for a in params
                       if not re.search(r"\b%s\s*:" % re.escape(a), args)]

            # 有尾随闭包时，可以"吃掉"一个缺失的闭包型参数
            if has_trailing_closure and missing:
                # 名字里带 on/Callback/Handler 的按闭包处理；
                # 更稳的做法是看声明里的类型，这里已在 _required 里
                # 只登记了无默认值的，闭包参数也在这份名单里
                closure_like = [a for a in missing
                                if re.search(r"^(on|did|will|handle)", a, re.I)]
                if closure_like:
                    missing = [a for a in missing if a != closure_like[-1]]

            if missing:
                errors.append(
                    "%s:%d `%s(...)` 缺必填参数 %s —— "
                    "这个页面需要外部传入上下文，不能当全局页面用。\n"
                    "         └ 要么补参数，要么换一个不需要上下文的汇总页"
                    % (rel, line, name, missing))

print("=" * 60)
print("Swift 源码粗检（无类型检查）")
print("文件数: %d" % len(files))
print("-" * 60)
for e in errors:
    print("[错误] " + e)
for w in warns:
    print("[提示] " + w)
if not errors:
    print("结果: 未发现机械性错误")
print("=" * 60)
sys.exit(1 if errors else 0)
