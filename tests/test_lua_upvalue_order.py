"""Lua 闭包定义顺序回归 —— 2026-09-27 实机事故。

事故：裁剪 K 我把 readonly_alive / check_alive 写在 eligible **之后**。
Lua 的 local 是词法作用域，upvalue **编译期**绑定 ⇒ eligible 体内引用
readonly_alive 时它还不是 local，解析成全局(nil) ⇒ eligible() 一被调用就
`attempt to call a nil value`，被外层 pcall 吞掉。
实机症状：priority_locked 一次都不出现（整条虫洞链路静默死掉），
日志里只有 structure_mark ... ACCEPTED，看不出任何错误。

本测试只做两件朴素但可靠的事：
  1. 真跑最小复现，证明"后定义 local 在前面函数里确实是 nil"
  2. 直接比较定义行号（不需要解析函数体 —— 那会踩到字符串里的花括号）
"""
import pathlib

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src/g60" / "native_priority.lua"

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    if ok:
        print(f"  PASS {name:50} [{detail}]")
    else:
        failures.append(name)
        print(f"  FAIL {name:50} [{detail}]")


# 用 load() 现场编译，避免本文件的 local 作用域影响结论
REPRO = """
-- ★ 用 [==[ ]==] 长字符串，避免 \\n 转义把换行吃掉（踩过：两种顺序都崩，
--   一度以为前提假设错了）。
local function compile(defs_first)
  local src = defs_first
      and [==[
local function callee() return 'REACHED' end
local function caller() return callee() end
return caller
]==]
      or [==[
local function caller() return callee() end
local function callee() return 'REACHED' end
return caller
]==]
  return (load(src))()
end
local function probe(d)
  local ok, ret = pcall(compile(d))
  return tostring(ok) .. '||' .. tostring(ret)
end
__BAD = probe(false)     -- callee 在 caller 之后 -> 解析为全局(nil) -> 崩
__GOOD = probe(true)     -- callee 在 caller 之前 -> 正常
"""


def line_of(text, needle, start=0):
    idx = text.index(needle, start)
    return text[:idx].count("\n") + 1


def main():
    print("=== ① 真跑最小复现：Lua upvalue 是编译期绑定的 ===")
    rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    rt.execute(REPRO)

    def g(k):
        v = rt.eval(k)
        s = v.decode() if isinstance(v, bytes) else str(v)
        ok, _, ret = s.partition("||")
        return ok, ret

    ok_b, ret_b = g("__BAD")
    ok_g, ret_g = g("__GOOD")
    check("forward_ref_crashes", ok_b == "false" and "nil value" in ret_b,
          f"后定义 local = nil: {ret_b[:52]}")
    check("correct_order_runs", ok_g == "true" and ret_g == "REACHED",
          f"定义在前则正常调用  [ok={ok_g!r} ret={ret_g!r}]")

    print()
    print("=== ② 真实源码：定义行号顺序 ===")
    text = SRC.read_text(encoding="utf-8")
    lines = {
        "readonly_alive": line_of(text, "local function readonly_alive"),
        "check_alive": line_of(text, "local function check_alive"),
        "eligible": line_of(text, "local function eligible"),
    }
    check("readonly_alive_before_eligible",
          lines["readonly_alive"] < lines["eligible"],
          f"readonly_alive=行{lines['readonly_alive']} < eligible=行{lines['eligible']}")
    check("check_alive_before_eligible",
          lines["check_alive"] < lines["eligible"],
          f"check_alive=行{lines['check_alive']} < eligible=行{lines['eligible']}")
    # 确认 eligible 体内确实用到了它们（否则顺序无所谓）
    e0 = lines["eligible"] - 1
    e1 = next((i for i in range(e0 + 1, len(text.split('\n')))
               if text.split('\n')[i].strip().startswith("end")
               and "row.unit=unit" in "\n".join(text.split('\n')[e0:i])), len(text.split('\n')))
    seg = "\n".join(text.split("\n")[e0:e1])
    check("eligible_uses_readonly_alive", "readonly_alive(" in seg,
          "eligible 体内调用 readonly_alive ⇒ 顺序真的要紧")
    check("structure_branch_uses_check_alive",
          "check_alive(e,'NEW_MARK')" in text, "structure 分支调用 check_alive")

    print()
    if failures:
        print(f"RESULT: {checks - len(failures)} passed; {len(failures)} failed")
        print("failed: " + ", ".join(failures))
        return 1
    print(f"RESULT: ALL PASS ({checks} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
