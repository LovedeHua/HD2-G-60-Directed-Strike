"""守门：构建指纹（`entry_build;id=…` 启动日志行）—— 同版本多次构建必须能在日志里区分。

背景（2026-10-16 实机事故）：同一天把 0.1.25 改了两次都没发版，日志只有
`version=0.1.25` ⇒ **分不出跑的是哪个构建**，白排查一轮。

本守门钉住四件事：
  ① entry 里有 `entry_build;id=@@ENTRY_BUILD@@` 的独立 emit 行；
  ② build.py 在**模块级**定义 `_entry_build()`，并按**锚点自身缩进**做替换
     （上一轮插进函数体导致 IndentationError，正是这里要防的回归）；
  ③ **不塞进 status_core/status_titan/status_marks** —— 那三段有 900 字符预算
     （`status_len;…;cap=900` 与 `status_core_fits` 守门钉着），塞进去会顶爆；
  ④ 真跑一遍替换：结果里必须出现已解析的 `id=…`，且**不留任何 `@@…@@` 占位符**。
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = (ROOT / "addon/entry.lua.in").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts/build.py").read_text(encoding="utf-8")

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


print("=== ① entry：独立一行 emit ===")
check("emit_line_present",
      "emit('entry_build;id=@@ENTRY_BUILD@@;version=@@VERSION@@')" in ENTRY,
      "★ 独立成行（不是拼进 status_core）")
check("not_inside_status_segments",
      "entry_build" not in ENTRY[ENTRY.index("local status_core="):ENTRY.index("local status_titan=")],
      "★ 指纹**不在** version= 那一段（三段各有 900 字符预算，塞进去会顶爆）")

print()
print("=== ② build.py：模块级计算 + 缩进正确 ===")
check("helper_is_module_level",
      re.search(r"^def _entry_build\(\):", BUILD, re.M) is not None,
      "★ `def _entry_build():` 顶格（模块级）—— 上一轮插进函数体导致 IndentationError")
check("module_level_call",
      re.search(r"^ENTRY_BUILD = _entry_build\(\)", BUILD, re.M) is not None,
      "★ 模块级调用一次（不在函数里反复算）")
m = re.search(r"^([ \t]*)text = text\.replace\('@@ENTRY_BUILD@@', ENTRY_BUILD\)$", BUILD, re.M)
check("substitution_present", m is not None, "★ 真的替换 @@ENTRY_BUILD@@")
if m:
    a = re.search(r"^([ \t]*)text = text\.replace\('@@VERSION@@', VERSION\)$", BUILD, re.M)
    check("indentation_matches_anchor",
          a is not None and len(a.group(1)) == len(m.group(1)),
          "★ 替换行缩进与 `@@VERSION@@` 那行一致（防 IndentationError 复发）")
check("git_and_fallback",
      "rev-parse" in BUILD and "'+dirty'" in BUILD and "hashlib" in BUILD,
      "★ 有 git 取短哈希（脏树 +dirty）、无 git 退化源码哈希 —— 两条路都要有")

print()
print("=== ③ 真跑一遍替换（与 build.py 同序）===")
text = ENTRY.replace("@@VERSION@@", "9.9.9").replace("@@ENTRY_BUILD@@", "abc1234")
check("resolved_value_present",
      "emit('entry_build;id=abc1234;version=9.9.9')" in text,
      "★ 替换后出现已解析的 id 与 version")
left = sorted(set(re.findall(r"@@[A-Z_]+@@", text)))
check("no_placeholder_left", "@@ENTRY_BUILD@@" not in text,
      "★ 指纹占位符必须被替换掉（其余占位符由 build.py 另外几处替换，不在本条范围；"
      "实际残留：%s）" % (left or "无"))
check("status_segments_untouched",
      "version=9.9.9-bughole;runtime_baseline=" in text
      and "mark_settings;unit_mark_live_only=" in text,
      "★ 状态行三段结构未动（指纹是额外一行，不挤预算）")

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    raise SystemExit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
