"""行为层真求值：TakeGate.decide 对"无标记改派"必须放行（且不得放宽其它面）。

这是 HANDOVER.md §5.3 想升级却崩掉的那类测试 —— 用**真求值**而不是文本抠取。
只读：不写仓库文件。
"""
import pathlib
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
src = (ROOT / "src/g60/take_gate.lua").read_text(encoding="utf-8")
rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
rt.execute("__TG = (function()\n" + src + "\nend)()")
TG = rt.eval("__TG")

failures = []
checks = 0


def get(tbl, key):
    return tbl[key.encode()] if isinstance(key, str) else tbl[key]


def decide(**kw):
    t = rt.table()
    for k, v in kw.items():
        if isinstance(v, bool):
            t[k.encode()] = v
        elif v is None:
            pass
        else:
            t[k.encode()] = v
    return TG.decide(t)


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(f"  {'PASS' if ok else 'FAIL'} {name:46} [{detail}]")
    if not ok:
        failures.append(name)


print("=== 无标记改派：门控必须放行（否则整条链结构性不可达）===")
r = decide(behavior_id=4, state=4, old=None, structure_mark=None, point_armed=False,
           spread_armed=True)
d, why = bool(get(r, "drive")), get(r, "why")
check("spread_armed_opens_gate", d, f"drive={d} why={why}")

print()
print("=== 收窄面：不设 spread_armed 时行为必须完全不变 ===")
r = decide(behavior_id=4, state=4, old=None, structure_mark=None, point_armed=False)
d, why = bool(get(r, "drive")), get(r, "why")
check("no_spread_still_vanilla_gate", (not d) and why == b"no_mark_no_hold",
      f"drive={d} why={why}")

print()
print("=== spread_armed 不得越过安全门（quarantined / engine_owns_it / retired）===")
r = decide(behavior_id=4, state=4, old=None, structure_mark=None, spread_armed=True,
           native_update_eligible=False)
check("spread_cannot_override_engine_owns_it",
      not bool(get(r, "drive")) and get(r, "why") == b"engine_owns_it",
      f"why={get(r,'why')}")

oldq = rt.table(); oldq[b"quarantined"] = True
r = decide(behavior_id=4, state=4, old=oldq, structure_mark=None, spread_armed=True)
check("spread_cannot_override_quarantine",
      not bool(get(r, "drive")) and get(r, "why") == b"quarantined",
      f"why={get(r,'why')}")

r = decide(behavior_id=4, state=4, old=None, structure_mark=None, spread_armed=True,
           retired=True)
check("spread_cannot_override_retired",
      not bool(get(r, "drive")) and get(r, "why") == b"already_retired",
      f"why={get(r,'why')}")

r = decide(behavior_id=2, state=4, old=None, structure_mark=None, spread_armed=True)
check("spread_only_for_g60", not bool(get(r, "drive")), f"why={get(r,'why')}")

print()
print("=== veto 仍然优先（语义不变）===")
r = decide(behavior_id=4, state=4, old=None, structure_mark=None, spread_armed=True,
           selection_vetoed=True)
check("veto_still_wins", get(r, "veto") is True, f"veto={get(r,'veto')}")

print()
print("=== 引导门：spread 只放行 state 4（不越过 can_guide 安全边界）===")
r = decide(behavior_id=4, state=4, old=None, structure_mark=None, spread_armed=True)
check("spread_can_guide_at_state4", bool(get(r, "can_guide")), f"can_guide={get(r,'can_guide')}")

print()
if failures:
    print(f"RESULT: {checks - len(failures)} passed; {len(failures)} failed")
    print("failed: " + ", ".join(failures))
    raise SystemExit(1)
print(f"RESULT: ALL PASS ({checks} checks)")
