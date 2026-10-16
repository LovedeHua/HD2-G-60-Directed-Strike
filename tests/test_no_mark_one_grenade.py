"""守门：**无标记时每个敌人只能接受一颗手雷**（2026-10-16 用户要求）。

用户原话：「无标记时投掷多颗手雷，多颗手雷大概率会锁定同一个目标，
优化成无标记时每个敌人只能接受一颗手雷」。

根因（已核实）：`reservations:set_cap` 原本只在"有标记队列"的块里调用
⇒ 无标记时 cap 一直是构造时的值（= `max_grenades_per_target`，用户日志里是 2）
⇒ 两颗雷压在同一个敌人身上是**合法**的。

⇒ cap 现在每帧只算一次、三档：无标记 **1** / 单标记 `max_grenades_per_target`
   / 多标记 `multi_mark_grenades_per_target`。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


print('=== ① 结构：cap 只算一处 + 无标记硬性 1 + 诊断可见 ===')
check('cap_computed_once',
      RT.count('reservations:set_cap(') == 1,
      '★★★ `set_cap` 全文件只出现 **1** 次（%d）—— "同一个判断不许出现两处"'
      % RT.count('reservations:set_cap('))
check('no_mark_forces_one',
      "if c<1 then c=1 end" in RT and "local c=1" in RT
      and "local n=0" in RT
      and "if q and P.usable(q,q.current,true) then n=n+1 end" in RT,
      '★★ 无标记（n=0）⇒ c 保持初值 **1**（硬性一颗），不读用户的单/多标记设置。★ 且 n **只数可用标记**（`P.usable(q,q.current,true)`）—— 队列是 ping 记忆的**历史**，已取消/过期的仍在里面 ⇒ 数历史长度会让「无标记」这条规则从未生效（用户 2026-10-16 实机铁证：`marks=0` 从未出现）')
check('mark_branches_kept',
      "c=tonumber(env.multi_mark_grenades_per_target) or 1" in RT
      and "c=tonumber(env.max_grenades_per_target) or 1" in RT,
      '★ 单标记/多标记两档仍按用户设置（行为不变）')
check('cap_visible',
      "env.emit('alloc_cap;marks='" in RT and "src='..(n==0 and 'NO_MARK_ONE_PER_ENEMY' or 'MARK_SETTING')" in RT,
      '★★ 诊断必须可见（看不到 = 无法确认）：`alloc_cap;marks=0;cap=1;src=NO_MARK_ONE_PER_ENEMY`')
check('diag_only_on_change',
      'if P.alloc_cap~=c or P.alloc_n~=n then' in RT,
      '★ 只在变化时打（否则每帧一条会埋掉真错误）')
check('mark_block_no_longer_sets_cap',
      'local marks=#spread.queue' in RT and 'local multi=marks>1' in RT,
      '★ 标记块仍只读 `multi`（不再自己 set_cap）⇒ 判定与登记同源')

print()
print('=== ② 真求值：把 cap 计算块抠出来跑（三档 + 夹取 + 边界）===')
# ★ 2026-10-16：cap 块已**上移到改派块之前**（否则 pick 读到上一帧的 cap ⇒ 多颗雷
#   共享同一目标）。这里用新的锚点抠取；锚点本身也由下面的顺序断言守住。
_a = RT.index('-- ★★★ 2026-10-16 二次修正：**cap 必须在改派块之前算好**')
_a = RT.index('if reservations then', _a)
_b = RT.index('do\n                        -- 只在"完全无标记"', _a)
block = RT[_a:_b]
check('cap_block_before_pick',
      _a < RT.index('do\n                        -- 只在"完全无标记"'),
      '★★★ cap 必须在**改派块之前** —— 否则 pick 用上一帧的 cap（首帧是构造值）'
      ' ⇒ 多颗手雷仍共享同一个目标（用户 2026-10-16 报的现象）')
# ★★★ 2026-10-16：cap 块**不许引用 `spread`** ★★★
#   把 cap 上移之后，它落在 `local spread=structure_mark or mark`（更靠下）**之前**
#   ⇒ 引用 spread 会被 Lua 解析成**全局 nil** ⇒ n 恒 0 ⇒ 「无标记 ⇒ cap=1」规则
#     以及"单/多标记两档"全部空转，而 `check_local_order` **抓不到**
#     （它只登记 `local function NAME`，不收 `local NAME=`）。
#   这是我在本轮**真踩过**的 bug（两个门禁全绿、行为静默错）。
#   ⇒ 用**真求值**兜住：在只有 `spread`、没有 `mk` 的环境里跑 cap 块，n 必须是 0
#     而不是崩，且**真正的取值必须来自 `mk`**（源码层面钉住）。
check('cap_block_uses_mk_not_forward_spread',
      'if mk and mk.queue then' in block and 'spread.queue' not in block,
      '★★★ cap 块必须用 `mk`（= `structure_mark or mark`）而**不是** `spread` —— '
      '`spread` 在同函数内更晚才声明，前向引用会解析成全局 nil（check_local_order 抓不到）')
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
__cap = nil
__logs = {}
P = {usable=function(q,c,a) return (q ~= nil) and (q.usable ~= false) end}
env = {max_grenades_per_target=2, multi_mark_grenades_per_target=1,
       emit=function(s) __logs[#__logs+1]=s end}
reservations = {set_cap=function(self,c) __cap=c end}
frame = 1
function probe(n, mn, mm, stale)
    env.max_grenades_per_target = mn
    env.multi_mark_grenades_per_target = mm
    -- ★ 2026-10-16：cap 块现在**不能**引用 `spread` —— 它在同函数内**更晚**才
    --   声明（`local spread=structure_mark or mark`）⇒ 前向引用会被解析成全局 nil。
    --   故 cap 块改用 `mk`（与 spread **同一定义**：`structure_mark or mark`）。
    --   ⚠ 这个改名正是"cap 必须在 pick 之前"带来的副作用；改锚点时别忘同步这里。
    local mk = nil
    if n > 0 then
        mk = {queue={}}
        for i=1,n do mk.queue[i] = {identity='id'..i, usable=(stale ~= 1)} end
    end
""" + block + """
    return __cap
end
function lastlog() return __logs[#__logs] end
function clearlogs() __logs = {} end
""")


def probe(n, mn=2, mm=1, stale=0):
    return lua.eval('probe(%d, %d, %d, %d)' % (n, mn, mm, stale))


check('no_mark_cap_is_one', probe(0) == 1,
      '★★★ **无标记 ⇒ cap=1**（用户本次要求的核心）')
check('no_mark_cap_is_one_even_if_user_set_two', probe(0, 2, 2) == 1,
      '★★★ 即使"单标记/多标记：每目标手雷数"都设成 2，无标记时仍**只能是 1**')
check('stale_queue_counts_as_no_mark', probe(3, 2, 2, stale=1) == 1
      and probe(1, 2, 2, stale=1) == 1 and probe(5, 2, 3, stale=1) == 1,
      '★★★ **队列里全是历史残留（已取消/过期）⇒ 等同无标记 ⇒ cap=1**'
      '（用户 2026-10-16 实机：`marks=3/2/1` 全走了标记档、`marks=0` 从未出现 ⇒ 规则空转）')
check('one_mark_uses_single_setting', probe(1, 3, 1) == 3 and probe(1, 1, 9) == 1,
      '★ 单个标记 ⇒ 用 `max_grenades_per_target`（值随设置走）')
check('many_marks_uses_multi_setting', probe(2, 3, 2) == 2 and probe(5, 1, 4) == 4,
      '★ 2+ 标记 ⇒ 用 `multi_mark_grenades_per_target`')
check('zero_setting_clamped_to_one', probe(1, 0, 0) == 1 and probe(3, 0, 0) == 1,
      '★ 0/负数 ⇒ 夹到 1（否则"可预约"恒假 ⇒ 一颗都不派）')
check('logs_no_mark_source', probe(0) == 1 and 'marks=0' in lua.eval('lastlog()')
      and 'cap=1' in lua.eval('lastlog()'),
      '★ 无标记那条日志带 `marks=0;cap=1` ⇒ 上机可核对')
check('logs_mark_source', probe(2, 1, 2) == 2 and 'marks=2' in lua.eval('lastlog()'),
      '★ 有标记那条带 `marks=2;cap=2`')
check('log_deduped', (lambda: (lua.eval('clearlogs()'), probe(0) == 1, probe(0) == 1,
                               lua.eval('__logs') and len(list(lua.eval('__logs').values())) == 1)[-1])(),
      '★ 连续同值只打一条（变化才打）')

print()
print('=== ③ 无标记那条路确实会走预留门（不然 cap 改了也没用）===')
NP = (ROOT / 'src/g60' / 'native_priority.lua').read_text(encoding='utf-8')
check('generic_path_checks_available',
      NP.count('if available and not available(e.identity) then') >= 2,
      '★★ `native_priority` 的通用/sticky 路径都查 `available()`（实测 %d 处）'
      % NP.count('if available and not available(e.identity) then'))
check('reserved_reason_visible',
      "'TARGET_RESERVED'" in NP,
      '★ 被预约而跳过有明确原因串（可归因，不静默）')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
