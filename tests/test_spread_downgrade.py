"""守门：无标记改派的**降级**行为 —— 用真求值，而不是文本断言。

用户 2026-10-16 第二项需求：「场上最高档只有一个敌人、但有多颗手雷时，
另外的手雷应该降级追踪」。用户确认含义 = **在本手雷候选表内选下一个未被占的**。

为什么必须真求值：本项目已多次证明**文本断言把 bug 钉成"正确"**
（`"P.cap=ok_c and cap or nil" in src` 那次最关键）。这里把 runtime 里**真实的**
pick 块 + 真实的 `target_reservations` 抠出来真跑，断言的是**实际挑中了谁**。

⚠ 抠取本身依赖源码文本 ⇒ 同时断言锚点存在（否则整段静默空转 = 假绿灯）。
"""
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / "src/g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
RES = (ROOT / "src/g60" / "target_reservations.lua").read_text(encoding="utf-8")

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


print("=== ① 锚点（抠取失败会让整段静默空转 = 假绿灯）===")
PICK_ANCHOR = "                    do\n                        -- 只在\"完全无标记\""
CONS_ANCHOR = "if reservations and my_structure==nil and P.spread_pick_row then"
check("pick_block_anchor_present", PICK_ANCHOR in RT, "pick 块锚点在")
check("consume_block_anchor_present", CONS_ANCHOR in RT, "消费块锚点在")

PICK_START = RT.index(PICK_ANCHOR)
PICK_END = RT.index("                    end\n                    local gate=TakeGate.decide{",
                    PICK_START)
PICK = RT[PICK_START + len("                    do"):PICK_END]

CONS_START = RT.index(CONS_ANCHOR)
CONS_END = RT.index("P.spread_pick_row=nil", CONS_START)
CONS = RT[CONS_START:CONS_END]

check("pick_block_nonempty", len(PICK) > 300 and "spread_rank" in PICK,
      "pick 块非空且含 rank 判据（%d 字符）" % len(PICK))

print()
print("=== ② 真求值：多颗手雷分别挑谁 ===")
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("__RES = (function()\n" + RES + "\nend)()")
lua.execute("""
env = {}
P = {usable=function(q,c,a) return q~=nil end}
frame = 100
__ranks = {}
__cand = {}
-- ★ 2026-10-16 三次修正：pick 块现在会排除"本 mod 有专属链的目标"
--   （`has_weakpoint` = `claim_profile(res)~=nil` 的唯一包装 —— 泰坦/蟑龙/虫洞）。
--   本文件测的是**普通敌人**之间的降级，所以默认一张空表（= 没有专属链目标）。
--   ⚠ 用可注入的表而**不是**写成 `return false` 常量：常量会把
--     "排除逻辑根本没接线"这种情况也放过去（假绿灯）。
__chain = {}
function has_weakpoint(r) return r ~= nil and __chain[tostring(r)] == true end
env.spread_rank = function(r) return __ranks[tostring(r)] end
env.spread_candidates = {capture=function(d, ctx) return __cand end}
TargetData = {new=function(...) return {} end}
Reservations = __RES
read = function() return "" end
base = 0

function mk(id, rank)
    __ranks[tostring(id)] = rank
    local ident = string.rep(string.char(id % 200 + 1), 20) .. string.rep('\\0', 4)
    return {entity={id=id, identity=ident, resource=tostring(id)}, ordinal=id}
end

function simulate(cap, cand, n)
    local reservations = __RES.new(cap)
    reservations:set_cap(cap)
    local out = {}
    for g = 1, n do
        local m = {id=1000+g, index=g,
                   identity_bytes=string.rep(string.char(g), 20) .. string.rep('\\0', 4),
                   entity_address=0x100000 + g*0x1000}
        __cand = cand
        local owner = __RES.owner(m)
        P.spread_pick_row = nil
""" + "\n".join("        " + l for l in PICK.split("\n")) + """
        local my_mark, my_structure = nil, nil
""" + "\n".join("        " + l for l in CONS.split("\n")) + """
        out[g] = my_mark and my_mark.id or -1
    end
    return out
end
""")


def sim(cap, cands, n):
    lua.execute("__cand = {%s}" % ", ".join(
        "mk(%d, %d)" % c for c in cands))
    r = lua.eval("simulate(%d, __cand, %d)" % (cap, n))
    return [r[i] for i in range(1, n + 1)]


# 最高档只有一个（501），另有次档 502、再次 503
r = sim(1, [(501, 1), (502, 5), (503, 9)], 3)
check("grenades_downgrade_in_order", r == [501, 502, 503],
      "3 颗雷应依次 501→502→503（降级），实际 %s" % r)

# 只有最高档一个 ⇒ 第一颗拿到，其余放弃（交回引擎，不共享）
r = sim(1, [(501, 1)], 3)
check("only_one_candidate_first_wins", r[0] == 501, "第一颗拿到 501，实际 %s" % r)
check("rest_decline_not_share", r[1] == -1 and r[2] == -1,
      "候选用尽 ⇒ 其余放弃而非共享，实际 %s" % r)

# 两道档都要遵守 rank 次序：先给 rank 小的
r = sim(1, [(501, 9), (502, 1)], 1)
check("lowest_rank_wins", r[0] == 502,
      "应挑 rank 最小者 502，实际 %s" % r)

# cap>1 时才允许共享（"单标记"设置语义；无标记走 cap=1）
r = sim(2, [(501, 1), (502, 5)], 3)
check("cap2_allows_sharing", r[0] == 501 and r[1] == 501 and r[2] == 502,
      "cap=2 ⇒ 前两颗共享 501、第三颗 502，实际 %s" % r)

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
