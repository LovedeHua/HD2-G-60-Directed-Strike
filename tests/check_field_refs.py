#!/usr/bin/env python
"""跨模块字段引用检查：凡 `Module.field` 引用，field 必须真实存在。

★ 为什么需要这个（2026-09-28 11:40 实机事故）★
    我在 native_priority.lua 的 takeover_probe 里写了一句
        local life=math.max(0,1-spent/Policy.lifetime_ticks)
    而那个文件里 `Policy` 是 `g60.target_policy`（第 6 行），
    `lifetime_ticks` 却属于 `g60.arrival_policy`（第 8 行才 require）。

    Lua 对 nil 做算术 ⇒
        attempt to perform arithmetic on field 'lifetime_ticks' (a nil value)
    **每一帧**都抛错，被 runtime 的 pcall 吞成 structure_unavailable，
    于是「标记读到了、G-60 也到 state 4，却一次都锁不上」。

    这一类错误：
      · luac 语法检查通过（字段是运行期解析的）
      · 单测通过（那 195 个测试跑 g60/core.lua，跑不到 native_priority）
      · 只有实机日志才暴露
    与「模块别名顺序错误」同类（2026-09-27 upvalue 事故、11:00 那次），
    两次都靠 build.py 的顺序校验治住了。字段名错必须同样自动化。

本检查是**保守**的：只断言高置信度的场景（模块 local 名 → 其 require 源）。
无法静态确定的引用会跳过并计数，不误报。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src/g60"

# 收集每个模块真实定义的顶层字段。
# 三种定义形态都要认：
#   M.x = ...            （赋值）
#   function M.x(...)    （函数）
#   local M={a=1, b=2}   （表构造字面量）
FIELD_PATTERNS = (
    # M.x = ...            （赋值；同一行可能有多个：M.u32=u32;M.pointer=ptr）
    re.compile(r"\bM\.(\w+)\s*="),
    # function M.x(...)    （函数）
    re.compile(r"function\s+M\.(\w+)"),
    # local M={a=1, b=2}   （表构造字面量，可能跨行）
    re.compile(r"\bM\s*=\s*\{(.*?)\}", re.S),
)


def defined_fields(text):
    out = set()
    for pat in FIELD_PATTERNS[:2]:
        out |= set(pat.findall(text))
    for body in FIELD_PATTERNS[2].findall(text):
        for key in re.findall(r"(\w+)\s*=", body):
            out.add(key)
    return out


def module_fields():
    fields = {}
    for path in sorted(SRC.glob("*.lua")):
        fields[path.stem] = defined_fields(path.read_text(encoding="utf-8"))
    return fields


def local_to_module(text):
    """local <Alias>=require('g60.<name>') → {Alias: name}"""
    out = {}
    for alias, name in re.findall(
            r"local\s+(\w+)\s*=\s*require\('g60\.([a-z_0-9]+)'\)", text):
        out[alias] = name
    # `local X=require('g60.y').field` 形式（project 记忆里记过要避免的写法）
    for alias, name, field in re.findall(
            r"local\s+(\w+)\s*=\s*require\('g60\.([a-z_0-9]+)'\)\.(\w+)", text):
        out[alias] = name
    return out


def main():
    fields = module_fields()
    problems, checked, skipped = [], 0, 0

    for path in sorted(SRC.glob("*.lua")):
        text = path.read_text(encoding="utf-8")
        # 去掉注释，避免注释里的示例代码误报
        code = "\n".join(
            ln for ln in text.splitlines() if not ln.strip().startswith("--"))
        code = re.sub(r"--\[\[.*?\]\]", "", code, flags=re.S)
        aliases = local_to_module(code)

        for ln_no, line in enumerate(code.splitlines(), 1):
            for alias, field in re.findall(r"\b([A-Z]\w*)\.(\w+)", line):
                if alias not in aliases:
                    continue          # 不是 require 来的模块，跳过
                mod = aliases[alias]
                if mod not in fields:
                    continue
                if field in fields[mod]:
                    checked += 1
                else:
                    problems.append(
                        f"{path.relative_to(ROOT)}:{ln_no}: {alias}.{field}"
                        f"  -> g60.{mod} does not define '{field}'"
                        f" (it has: {', '.join(sorted(fields[mod])) or 'none'})")

    print(f"checked {checked} cross-module field references "
          f"across {len(fields)} modules")
    if problems:
        print(f"\n{len(problems)} BAD FIELD REFERENCE(S):")
        for p in problems:
            print("  " + p)
        return 1
    print("RESULT: ALL PASS (no unknown cross-module field references)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
