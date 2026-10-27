#!/usr/bin/env python3
"""把 Swift DTO 的**声明类型**和真实服务端响应做比对。

为什么需要这个：Swift 的 Codable 里 `Optional` 只表示"键缺失或为 null"，
**不表示"类型不对就给 nil"**。所以把一个对象字段声明成 `String?`，
解码时抛 `typeMismatch`，整个响应都解析失败 —— 而编译期毫无感觉。
`HealthDTO.modules` 就是这么躺了很久的（服务端发对象，客户端声明 String?）。

用法：
    python tools/check_dto_contract.py <responses.json>

responses.json 的格式（由 tools/probe_api.py 产出）：
    {"HealthDTO": {...}, "BootstrapDTO": {...}, ...}
键是 Swift 结构体名，值是真实的 JSON 响应。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "ThreeeAssistant" / "Core" / "Models.swift"
# DTO 不只在 Models.swift 里：SyncModels.swift 就放了一整套同步模型。
# 早先只读 Models.swift，导致 SyncSnapshotResponse 被当成"找不到"跳过了。
MODEL_FILES = sorted((ROOT / "ThreeeAssistant").rglob("*.swift"))

STRUCT_RE = re.compile(r"^(?:public\s+)?struct\s+(\w+)\s*:[^{]*\{", re.M)

# 已知的宽松解码（自定义 init(from:)），跳过类型检查
TOLERANT_MARK = "init(from decoder: Decoder)"

SWIFT_TO_JSON = {
    "String": (str,),
    "Int": (int,),
    "Int64": (int,),
    "Int32": (int,),
    "Int16": (int,),
    "Int8": (int,),
    "Double": (int, float),
    "Float": (int, float),
    "Bool": (bool,),
    "Date": (int, float, str),
}


def parse_structs(text: str) -> dict:
    """粗粒度解析：拿到每个 struct 的属性名 -> Swift 类型，以及 CodingKeys 映射。"""
    out = {}
    for m in STRUCT_RE.finditer(text):
        name = m.group(1)
        start = m.end() - 1
        depth = 0
        end = start
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        body = text[start:end]
        # 注意：这里**不跳过**带 init(from:) 的结构体。它们同样要从 JSON 解，
        # 只是错得"温和"一点（自定义解码可能用 try? 吞掉）。
        # 跳过就看不见 HealthDTO 那种字段类型写错的问题了。

        props = {}
        for pm in re.finditer(r"^\s+(?:let|var)\s+(\w+)\s*:\s*([^\n=]+)$", body, re.M):
            pname = pm.group(1)
            ptype_raw = pm.group(2).strip()
            # 计算属性不是解码字段，跳过。
            # 两种写法都要拦：多行的 `var x: String {` 和单行的
            # `var start: Date { Date(...) }`。早先只判了行尾 `{`，
            # 于是 start / isRecurring / hasSpan 这些被当成"字段缺失"误报。
            if "{" in ptype_raw:
                continue
            props[pname] = ptype_raw

        # CodingKeys：把 Swift 属性名映射到 JSON key
        keymap = {}
        for cm in re.finditer(r"case\s+(\w+)\s*=\s*\"([^\"]+)\"", body):
            keymap[cm.group(1)] = cm.group(2)
        out[name] = {
            "props": props,
            "keymap": keymap,
            # 有自定义 init(from:) 的，字段可能被宽容处理过，不能算硬失败
            "tolerant": TOLERANT_MARK in body,
        }
    return out


def json_type_ok(swift_type: str, value) -> tuple:
    """返回 (是否兼容, 说明)。"""
    t = swift_type.strip()
    was_optional = t.endswith("?") or t.startswith("Optional<")
    if t.endswith("?"):
        t = t[:-1].strip()
    elif t.startswith("Optional<") and t.endswith(">"):
        t = t[len("Optional<"):-1].strip()

    if value is None:
        return True, ""

    if t.startswith("["):
        if not isinstance(value, list):
            return False, f"声明为数组，实际是 {type(value).__name__}"
        return True, ""

    base = t.split("<")[0].strip()
    if base in SWIFT_TO_JSON:
        allowed = SWIFT_TO_JSON[base]
        # bool 是 int 的子类，别让 True 混过 Int 检查
        if isinstance(value, bool) and bool not in allowed:
            return False, f"声明 {base}，实际 bool"
        if not isinstance(value, allowed):
            return False, f"声明 {base}，实际 {type(value).__name__}"
        return True, ""

    # 自定义结构体 / 字典 / 其它：要求对象
    if isinstance(value, dict):
        return True, ""
    if isinstance(value, list):
        return False, f"声明 {base}，实际数组"
    return False, f"声明 {base}，实际 {type(value).__name__}"


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("用法: check_dto_contract.py <responses.json>")
    responses = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    structs = {}
    for f in MODEL_FILES:
        structs.update(parse_structs(f.read_text(encoding="utf-8")))

    total = bad = 0
    seen = set()

    def pick_richest(items):
        """从数组里挑「非空字段最多」的那条当样本。

        ⚠️ 不能只取 items[0]。快照里 events 的第一条恰好是没有提醒的待办，
        而 `reminders: [ReminderDTO]` 这个嵌套类型只在另一条事件里才有数据 ——
        取首元素就永远递归不到它，等于把最该验的地方跳过了。
        空数组/空对象也算"贫瘠"，一条有 3 条提醒的记录会赢过它。
        """
        best, best_score = None, -1
        for it in items[:30]:
            if not isinstance(it, dict):
                continue
            score = sum(1 for v in it.values() if v not in (None, "", [], {}))
            if score > best_score:
                best, best_score = it, score
        return best

    def check_struct(dto_name: str, payload, indent: str = "") -> None:
        nonlocal total, bad
        info = structs.get(dto_name)
        if not info or not isinstance(payload, dict):
            return

        print(f"\n{indent}=== {dto_name} ===")
        row_bad = 0
        hit = 0
        for prop, ptype in info["props"].items():
            json_key = info["keymap"].get(prop, prop)
            if json_key not in payload:
                if ptype.strip().endswith("?"):
                    continue
                total += 1
                bad += 1
                row_bad += 1
                print(f"{indent}  ❌ {json_key}: 服务端没有这个键，但客户端声明为非可选 {ptype}")
                continue
            value = payload[json_key]
            hit += 1
            total += 1
            ok, why = json_type_ok(ptype, value)
            if not ok:
                if info.get("tolerant"):
                    # 有自定义 init(from:)：字段可能被 try? 兜住了，不算硬失败，
                    # 但仍然要提示 —— 宽容解码只保证"不崩"，不保证"值对"。
                    print(f"{indent}  ⚠️  {json_key}: {why}（有自定义解码，请确认 init 里处理了）")
                else:
                    bad += 1
                    row_bad += 1
                    print(f"{indent}  ❌ {json_key}: {why}")
                    print(f"{indent}       值样例: {json.dumps(value, ensure_ascii=False)[:100]}")

            # ---- 递归到嵌套类型 ----
            # 历史上出过「一个 DTO 吃两种互补响应」的坑
            # （/calendars/{id}/teams 只给 team_id，/teams/{id} 只给 calendar_id），
            # 那种错只有在嵌套层才看得见。
            inner = ptype.strip().rstrip("?").strip()
            if inner.startswith("[") and inner.endswith("]"):
                inner = inner[1:-1].strip().rstrip("?").strip()
                items = value if isinstance(value, list) else []
                sample = pick_richest(items)
                if sample is not None and inner in structs and inner not in seen:
                    seen.add(inner)
                    check_struct(inner, sample, indent + "    ")
            elif inner in structs and isinstance(value, dict) and inner not in seen:
                seen.add(inner)
                check_struct(inner, value, indent + "    ")

        if row_bad == 0:
            print(f"{indent}  ✅ {hit} 个字段全部兼容")

    for dto_name, payload in responses.items():
        if dto_name not in structs:
            print(f"⚠️  找不到 struct {dto_name}（跳过）")
            continue
        if not isinstance(payload, dict):
            print(f"⚠️  {dto_name} 的响应不是对象，跳过")
            continue
        seen.add(dto_name)
        check_struct(dto_name, payload)

    print(f"\n{'='*56}")
    print(f"共检查 {total} 个字段，发现 {bad} 处不兼容")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
