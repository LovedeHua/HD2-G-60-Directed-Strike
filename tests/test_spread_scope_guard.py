"""守门：无标记改派**不得越界**（2026-10-16 用户报的两个回归）。

用户原话：
  ① 「无标记目标下的优先级功能已经影响到标记虫洞炸毁功能了」
  ② 「无标记下投掷的手雷如果锁定到泰坦也不会走 mod 的泰坦链，导致不能颗秒泰坦」

两者都是 2026-10-16 我做的"无标记改派"引入的，**实机日志各有一条铁证**
（build `5f390d2+dirty`，包含当轮的 cap 修正）：

【② 泰坦】`spread_priority.lua` 给吐酸泰坦 rank=2（只有蟑龙更高）⇒ 无标记时
  改派**优先**挑中泰坦，把它当普通目标锁上 `old.lock` ⇒ `marked_lock_held` 为真
  ⇒ `titan_selected=false` ⇒ **泰坦链（腹点几何/standoff/弱点）整条不跑**
  ⇒ 雷撞泰坦本体 ⇒ 不能颗秒。

【① 虫洞】同一颗雷 851 的两行相邻证据：
     :446 mark_queue;entity=851;n=1;ids=581;current=0;loads=1;cap=2;
          picked=-;engine_sel=581;frame=33356   ← 标记**过期**了（玩家仍持有名额）
     :447 spread_pick;entity=851;target=812;…;frame=33368 ← 改派把雷劫到小怪身上
  根因：`no_mark` 判据用的是**瞬时** `held.lock`，而标记过期时 native_priority 的
  released 分支**正好把它清掉** ⇒ 判据恰在这一刻变真 ⇒ 雷被劫走。
  ⇒ 归属必须看**持久**印记（`old.spread`）。

修法（本文件逐条钉住）：
  · pick 候选**排除结构**（虫洞/构筑，`env.structure_profiles`）；
  · **专属链家族**（泰坦/变体/蟑龙）**纳入候选**并置于最高档 `rank=-1`
    —— 用户第四次修正：「泰坦的优先级很低，只有附近无其他敌人时才会追踪泰坦」；
  · 引擎本帧选中的若是**结构** ⇒ 改派整体让位（不挑候选 ⇒ 门控不放行 ⇒ 交还引擎）；
  · 改派出去的雷锁到**链家族**时不算"持有标记锁"（`marked_lock_held`）
    ⇒ 专属链照常接管、颗秒不回退；
  · `no_mark` 只对**我们自己改派出去的**雷成立（`old.spread`）。

⚠ 全部用**可注入的真求值**，不用"源码里有没有这句话"的文本断言 ——
  本项目已多次证明文本断言会把 bug 钉成"正确"（`P.cap=ok_c and cap or nil` 那次）。
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


# ---------------------------------------------------------------- 抠取真实代码
print("=== ① 锚点（抠取失败 = 整段静默空转 = 假绿灯）===")
# ⚠ 用**整个 `do … end` 块**做抠取边界：`local gate=…` 在这个 `do` 块**内部**，
#   若只截到 `local gate=` 就会把 `do` 的开头去掉、却留下它的 `end`
#   ⇒ 抠出的 Lua 块不配对（我第一版正是这么错的，lupa 报 '<eof>' expected near 'end'）。
DO_ANCHOR = '                    do\n                        -- 只在"完全无标记"'
DO_END_ANCHOR = "                    end\n                    local gate=TakeGate.decide{"
CONS_ANCHOR = "if reservations and my_structure==nil and P.spread_pick_row then"
CONS_END_ANCHOR = "P.spread_pick_row=nil"

for nm, a in [("do_block_anchor", DO_ANCHOR), ("gate_anchor", DO_END_ANCHOR),
              ("consume_anchor", CONS_ANCHOR)]:
    check("anchor_" + nm, a in RT, "锚点在：%s" % a.strip().split("\n")[0][:52])

do_start = RT.index(DO_ANCHOR)
# 去掉外层 `do` 与其配对 `end` ⇒ 剩下的是自平衡的块（内含 no_mark 判据 + pick）
PICK = RT[do_start + len("                    do"):RT.index(DO_END_ANCHOR, do_start)]
NOMARK = PICK                      # no_mark 判据与 pick 同在这一个块里
cons_start = RT.index(CONS_ANCHOR)
CONS = RT[cons_start:RT.index(CONS_END_ANCHOR, cons_start)]

# ★ `marked_lock_held`（改派锁到链家族时不算持有标记锁）在**别处**：
#   它是泰坦段前面的判据，**不在**上面那个 `do` 块里。
#   ⚠ 不抠它 ⇒ ③b 那三项只能对全文件做子串匹配 ⇒ 用 `NOMARK` 会恒假、
#     用 `RT` 又会让"注释里出现即通过"。这里单独抠出**赋值语句**这一段。
LOCK_ANCHOR = "                    local marked_lock_held="
LOCK_END_ANCHOR = "\n                    -- ★★★ 明确的\"ping 地面点\"压过"
check("marked_lock_anchor", LOCK_ANCHOR in RT and LOCK_END_ANCHOR in RT,
      "marked_lock_held 赋值段锚点在")
lock_start = RT.index(LOCK_ANCHOR)
NOMARK_LOCK = RT[lock_start:RT.index(LOCK_END_ANCHOR, lock_start)]

check("pick_block_nonempty", len(PICK) > 600 and "spread_rank" in PICK,
      "pick 块非空且含 rank 判据（%d 字符）" % len(PICK))
check("nomark_segment_nonempty", "local no_mark=" in NOMARK and "engine_on_chain" in NOMARK,
      "no_mark 判据段在（%d 字符）" % len(NOMARK))
check("marked_lock_segment_nonempty", len(NOMARK_LOCK) > 200
      and "titan_approach_released" in NOMARK_LOCK,
      "marked_lock_held 赋值段非空且含既有放手判据（%d 字符）" % len(NOMARK_LOCK))

# ---------------------------------------------------------------- 真求值
print()
print("=== ② 真求值：链家族目标被改派**优先**挑中；结构仍被排除 ===")
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("__RES = (function()\n" + RES + "\nend)()")
lua.execute("""
env = {}
P = {usable=function(q,c,a) return q~=nil end}
frame = 100
__ranks, __cand, __chain, __struct = {}, {}, {}, {}
Reservations = __RES
TargetData = {new=function(...) return {} end}
read = function() return "" end
base = 0

-- 可注入的专属链集合（对应 runtime 的 has_weakpoint = claim_profile(res)~=nil）
function has_weakpoint(r) return r ~= nil and __chain[tostring(r)] == true end

-- ⚠⚠ 结构表也必须接上：pick 块现在用 `env.structure_profiles[ent.resource]` 排除结构。
--   不给它 ⇒ `env.structure_profiles` 为 nil ⇒ `is_structure` 恒假 ⇒
--   "结构被排除"这条断言会**空转通过**（假绿灯）。
--   ⚠⚠ **必须原地清空/填充这张表**，不能 `__struct = struct` 重新绑定：
--     上面 `env.structure_profiles = __struct` 绑的是**当时的表值**，
--     重新绑定全局不会改到 `env` 看到的那张表 ⇒ `is_structure` 恒假
--     ⇒ `structure_target_never_picked` 误报失败（我第一版正是这么写的，
--     由这条断言当场抓出来）。
local function set_struct(t)
    for k in pairs(__struct) do __struct[k] = nil end
    for k, v in pairs(t or {}) do __struct[k] = v end
end
env.structure_profiles = __struct

-- ⚠ 候选来源必须真的接上（`env.spread_candidates.capture`）——
--   漏掉它会让整块静默挑不出（`-1`），看起来像"功能正常"，其实是 harness 没接线。
env.spread_candidates = {capture=function(d, ctx) return __cand end}

-- ⚠⚠ **档位函数也必须接上**：不接的话每个候选都拿默认 rank=9999
--   ⇒ "同 rank 取候选表更早的" ⇒ **永远挑第一个** ⇒
--   所有关于"档位最优"的断言都变成**空转**（我第一版就是这样：
--   对照组 `control_chain_target_wins_when_not_excluded` 当场把这个漏洞暴露出来）。
env.spread_rank = function(r) return __ranks[tostring(r)] end

-- ⚠⚠ `mk` 必须给出**互不相同**的 identity。
--   我第一版写成 `string.char(id % 200 + 1)` ⇒ 700 与 900 撞成同一个 identity
--   （`700%200 == 900%200`）⇒ 预约把两个候选当成**同一个目标** ⇒
--   去掉过滤后 `chain_target_never_picked` 仍然"通过" ⇒ 一条**没有牙**的门。
--   现在按 id 逐字节展开，保证任意两个 id 的 identity 都不同。
function mk(id, rank)
    __ranks[tostring(id)] = rank
    local b = {}
    for k = 0, 19 do b[#b+1] = string.char((id + k * 7) % 256) end
    return {entity={id=id, identity=table.concat(b) .. string.rep('\\0', 4),
                    resource=tostring(id)}, ordinal=id}
end

function pick_for(cap, cand, chain, struct)
    __cand, __chain = cand, chain or {}
    set_struct(struct)
    local reservations = __RES.new(cap)
    reservations:set_cap(cap)
    local m = {id=2001, index=1,
               identity_bytes=string.rep('\\1', 20) .. string.rep('\\0', 4),
               entity_address=0x200000}
    local owner = __RES.owner(m)
    -- 抠出的块会引用这些外层 local ⇒ harness 必须提供（值取"无标记"场景）
    local spread, structure_mark, point_marker, old = nil, nil, nil, nil
    P.spread_pick_row = nil
""" + "\n".join("    " + l for l in PICK.split("\n")) + """
    return P.spread_pick_row and P.spread_pick_row.id or -1
end
""")

lua.execute("__cand = {mk(1001, 5), mk(1002, 2), mk(1003, 8)}")
r = lua.eval("pick_for(1, __cand, {['1002']=true})")
check("chain_target_beats_ordinary_enemies", r == 1002,
      "候选 = 专属链目标(1002, rank=2) + 普通敌人(1001 rank5 / 1003 rank8) ⇒ "
      "必须挑 **1002**（链家族置顶 rank=-1）。实际挑中 %s。"
      "★ 这就是用户第四次修正：「泰坦的优先级很低，只有附近无其他敌人时才会追踪泰坦」"
      "—— 改成这样后，周围有多少小怪都不影响泰坦被追踪" % r)

# ★★★ 对照组（**必须有**）：链家族**不在**注入表里 ⇒ 它必须**不再**置顶，
#   而由名册 rank 决定胜负（1002 rank=2 仍最小 ⇒ 还是它赢）。
#   作用：证明"置顶"来自 `has_weakpoint` 这把尺子，而不是候选表顺序之类的巧合。
r = lua.eval("pick_for(1, __cand, {})")
check("control_rank_order_when_not_chain", r == 1002,
      "★ 对照：不标成链家族时由名册 rank 决定 —— 1002 rank=2 仍应赢（实际 %s）" % r)

# ★★★ 关键区分力：一个**名册未收录**的链目标（rank 会拿到默认 9999）
#   必须仍然压过名册里的普通敌人。若实现写成"靠名册 rank 取胜"，
#   这一项会失败（9999 > 5）—— 这正是 `rank=-1` 存在的理由。
lua.execute("__cand = {mk(1001, 5), mk(1004, 9999)}")
r = lua.eval("pick_for(1, __cand, {['1004']=true})")
check("unlisted_chain_target_still_wins", r == 1004,
      "候选 = 名册**未收录**的链目标(1004, rank=9999) + 普通敌人(1001 rank5) ⇒ "
      "必须挑 **1004**（链家族置顶，与名册无关）。实际 %s。"
      "★ 若挑中 1001 ⇒ 实现依赖了名册 rank，将来新增的链变体会被小怪压住" % r)

# ★★★ 结构（虫洞/构筑）**必须继续被排除** —— 用户报①「影响到标记虫洞炸毁」。
lua.execute("__cand = {mk(1005, 1), mk(1001, 5)}")
r = lua.eval("pick_for(1, __cand, {['1005']=true}, {['1005']=true})")
check("structure_target_never_picked", r == 1001,
      "候选 = 结构目标(1005, 同时也是 has_weakpoint) + 普通敌人(1001) ⇒ "
      "必须挑 **1001**（结构归结构路，改派碰不得）。实际 %s。"
      "★ 若挑中 1005 ⇒ 就是用户报①「优先级功能影响到标记虫洞炸毁」复发" % r)

lua.execute("__cand = {mk(1002, 2)}")
r = lua.eval("pick_for(1, __cand, {['1002']=true})")
check("all_chain_targets_still_picks_the_chain", r == 1002,
      "候选**全是**链目标 ⇒ 挑它（这正是本轮要的效果：无标记也主动追泰坦）；实际 %s" % r)

lua.execute("__cand = {mk(1001, 5), mk(1003, 8)}")
r = lua.eval("pick_for(1, __cand, {})")
check("ordinary_enemies_still_downgrade", r == 1001,
      "普通敌人之间仍按档位挑最优（1001 rank5）—— 本修正不得影响既有降级行为；实际 %s" % r)

# ---------------------------------------------------------------- 代码结构
print()
print("=== ③ 引擎已选中**结构** ⇒ 改派整体让位 ===")
check("engine_on_chain_guard_present",
      "engine_on_chain" in NOMARK and "has_weakpoint(m.selection_resource)" in NOMARK,
      "★★ 必须有「引擎本帧选中的是专属链目标 ⇒ 改派让位」这道判据 —— "
      "引擎已经选中结构时，改派若把它改成打小怪，照样给这颗雷安上 old.lock "
      "⇒ 结构路被搅乱（用户报①）")
check("engine_on_chain_uses_selection_flag",
      "m.selection_flag~=0" in NOMARK,
      "★ 必须用 `selection_flag~=0` 确认引擎选了**实体**"
      "（flag==1 且 id==0 是「点」不是实体；native_observer:110 也只在 flag~=0 时填 resource）")
check("engine_on_chain_forces_no_mark_false",
      "if engine_on_chain then no_mark=false end" in NOMARK,
      "★★ 让位方式 = 把 `no_mark` 置假 ⇒ 不挑候选 ⇒ 门控不放行 ⇒ 交还引擎（专属链归属唯一）")

print()
print("=== ③b 改派锁到链家族 ⇒ 不算持有标记锁（泰坦链照常接管）===")
check("spread_chain_lock_does_not_block_chain",
      "old.spread==true" in NOMARK_LOCK and "has_weakpoint(m.selection_resource)" in NOMARK_LOCK,
      "★★★ `marked_lock_held` 必须对「我们自己改派出去的雷 + 锁的是链家族」放宽 —— "
      "否则改派一旦挑中泰坦就把它锁死（marked_lock_held 为真 ⇒ titan_selected=false "
      "⇒ 泰坦链不跑 ⇒ 不能颗秒），等于退回用户报②")
check("spread_chain_lock_excludes_structures",
      "env.structure_profiles" in NOMARK_LOCK
      and "env.structure_profiles[m.selection_resource]~=nil" in NOMARK_LOCK,
      "★★★ 放宽判据必须**排除结构**（虫洞/构筑）—— `has_weakpoint` 同时也认结构，"
      "不排掉就会把玩家标记的虫洞判成「没有锁」⇒ 用户报①复发")
check("spread_chain_lock_uses_selection_resource",
      "old.lock.resource" not in NOMARK_LOCK,
      "★★ 用 `m.selection_resource` 而**不是** `old.lock.resource` —— "
      "native_priority 构造的 track 表**没有** resource 字段（见其 991/1007 行）"
      "⇒ 读 old.lock.resource 恒 nil ⇒ 这道放宽静默失效")

print()
print("=== ④ 归属看**持久**印记，不看瞬时锁（用户报①的根因）===")
check("no_mark_requires_persistent_ownership",
      "held.spread" in NOMARK and "not held.lock" in NOMARK,
      "★★★ `no_mark` 必须要求 `held.spread`（**我们改派出去的**那颗雷）—— "
      "旧判据只用瞬时的 `not held.lock`，而标记过期时 native_priority 的 released 分支"
      "**正好会清掉 old.lock** ⇒ 判据恰在这一刻变真 ⇒ 玩家标记过的雷被劫走"
      "（实机 :446/:447 两行铁证）")
check("no_mark_denies_never_spread_grenades",
      "held==nil" in NOMARK and "held.spread and not held.lock" in NOMARK,
      "★★ 语义：`held==nil`（首次见到，还没归属）**或** 已是改派雷且当前无锁 ⇒ 才允许改派；"
      "玩家标记过的雷（`held.spread` 空）**一辈子不许被改派碰**")
check("spread_mark_is_persisted",
      "if old then old.spread=true end" in CONS,
      "★★ 消费改派结果时必须同时**钉住归属印记**（`old.spread=true`）——"
      "否则上面那道判据永远为假 ⇒ 改派只能生效一帧（功能静默废掉）")
check("spread_mark_on_old_not_new_local",
      "old.spread=true" in CONS and "local spread_mark" not in RT,
      "★★ 印记挂在 `old`（= tracked[m.id]）上，**不新建被闭包捕获的 local** —— "
      "tick 的 xpcall 闭包恰好 60 upvalue = 上限，多一个整份 chunk 编译失败（实机事故）")

print()
print("=== ⑤ 两个回归的**共同前提**：改派不得新增 upvalue ===")


def code_only(src):
    """去掉 Lua 注释行 —— 断言"没有调用 X"时必须只看**代码**。
    ⚠ 我第一版没去注释 ⇒ 注释里出现的 `claim_profile(` 让这条门误报失败。"""
    out = []
    for l in src.split("\n"):
        s = l.lstrip()
        if s.startswith("--"):
            continue
        if "--" in l:
            l = l[:l.index("--")]
        out.append(l)
    return "\n".join(out)


PICK_CODE = code_only(PICK)
NOMARK_CODE = code_only(NOMARK)
NOMARK_LOCK_CODE = code_only(NOMARK_LOCK)
check("uses_has_weakpoint_not_claim_profile",
      "has_weakpoint(ent.resource)" in PICK_CODE
      and "claim_profile(" not in PICK_CODE
      and "has_weakpoint(m.selection_resource)" in NOMARK_CODE
      and "claim_profile(m.selection_resource)" not in NOMARK_CODE
      and "has_weakpoint(m.selection_resource)" in NOMARK_LOCK_CODE
      and "claim_profile(" not in NOMARK_LOCK_CODE,
      "★★★ 只能用 `has_weakpoint`（= `claim_profile(res)~=nil` 的**唯一包装**，"
      "它已是本闭包捕获的 upvalue）；直接调 `claim_profile` 会**多加一个 upvalue** "
      "⇒ 超过 Lua 5.1 的 60 上限 ⇒ 整份 chunk 编译失败"
      "（我第一版正是这么错的，被 check_lua51_compile 当场拦下）")

# ★★★ 结构排除必须走 `env.structure_profiles` 这一把尺子，**不许**另写一份
#   "是不是虫洞"的判断（本项目反复踩"同一个判断两处"）。
check("structure_exclusion_uses_structure_profiles",
      "env.structure_profiles[ent.resource]~=nil" in PICK_CODE,
      "★★ 排除结构只能用 `env.structure_profiles`（唯一实现）—— "
      "不接受另抄哈希表或在别处复制一份虫洞判据")

# ★★ 新增的放宽判据不得引入新的被闭包捕获的 local（upvalue 余量 = 0）。
check("no_new_captured_local_in_lock_guard",
      "local " not in NOMARK_LOCK_CODE.replace("local marked_lock_held=", ""),
      "★★ `marked_lock_held` 段里除它自己外不得再声明 local —— "
      "本闭包 upvalue 余量为 0，多一个被捕获的 local 会让整份 chunk 编译失败")

print()
if failures:
    print("RESULT: %d FAILED: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
