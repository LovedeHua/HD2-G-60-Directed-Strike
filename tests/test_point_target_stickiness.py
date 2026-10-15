"""空 ping 的"承诺后飞到底"（用户 2026-10-14 报告的 bug）。

用户原话：「有个问题，空 ping 没有跟虫洞一样能远距离追踪」。

根因（实机日志已证）
  `point_marker` 是**每帧**从 ping 槽重读的（`local point_marker`），
  而 ping 标记在引擎里会过期/轮转 ⇒ 只要某一帧读不到，原实现就把
  `held.point=nil`（并打 `point_released`）⇒ **飞行中途丢目标**。
  飞得越远越久越容易撞上 ⇒ 空 ping 实际上"跑不远"。
  虫洞是**实体**标记（有 `mark_retain_seconds` 保留时长）⇒ 不受影响。
  实机：6 次 `point_taken` 全部在 3~25 m；129/127/205/438 m 的 ping 一次都没成；
  另有 2 条 `point_released`（接管后 184 / 250 帧被释放）。

本门分三层（照本工程纪律：**涉及判据的断言必须真求值**）
  ① 把 shipped 判据抠出来，**编译后逐组求值**（不是 grep 字符串）；
  ② 反例矩阵：新扔的雷**不许**被陈旧点劫持（"顺手 ping 一下长期劫持"那条顾虑仍须成立）；
  ③ 变异测试：把判据改回 `point_marker~=nil` 必须让 sticky 那一格翻成 false。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT_SRC = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


def code(t):
    return '\n'.join(l.split('--')[0] for l in t.splitlines())


print('=== ① 抠出 shipped 的 `point_drive` 判据并**真求值** ===')
m = re.search(r'local point_drive=(.*?ping_take\))\n', RT_SRC, re.S)
check('point_drive_condition_extracted', m is not None, '从源码抠出 point_drive 判据')
cond = ' '.join(m.group(1).split()) if m else ''
print('    判据 = %s' % cond[:150])

lua = lj.LuaRuntime(unpack_returned_tuples=True)
_chunk = ("local abandoned,point_marker,old,P,m,frame,titan_selected,selected,"
          "point_armed,ping_take=...\nreturn (" + cond + ")\n")
lua.execute("__FN=assert(load([==[\n" + _chunk + "]==]))")


def args_for(fn, **kw):
    g = dict(abandoned=False, point_marker=None, old=None, titan_selected=False,
             selected=False, point_armed=None, ping_take=False, frame=5)
    g.update(kw)
    old = g['old']
    return fn(*[g['abandoned'], g['point_marker'],
                lua.table_from(old) if isinstance(old, dict) else old,
                lua.table_from({'szw': lua.table_from({})}), lua.table_from({'id': 1}),
                g['frame'], g['titan_selected'], g['selected'],
                g['point_armed'], g['ping_take']])


def evaluate(**kw):
    return bool(args_for(lua.eval('__FN'), **kw))


# ── ② 行为矩阵 ──
print()
print('=== ② 行为矩阵（真求值）===')
CASES = [
    # ⚠ 新接管那一支要求 `selected and point_armed`（引擎有目标）**或** `ping_take`。
    #   我给第一版矩阵写的是"marker + armed 但 selected=false"，那**本来**就该是 false
    #   —— 是**测试写错**，不是代码错（这种"期望值拍脑袋"最容易把门写成空转）。
    ('引擎有目标 + 新 ping 在 TTL 内（selected + armed）',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}, selected=True, point_armed=True), True),
    ('live ping + ping_take（无敌人 / 引擎没选目标时）',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}, ping_take=True), True),
    ('live ping 但**没有** selected 也没有 ping_take ⇒ 不接管',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}, point_armed=True), False),
    ('★ ping 标记消失 + 已承诺 old.point ⇒ 继续飞（本次修复）',
     dict(point_marker=None, old={'point': {'x': 1, 'y': 2, 'z': 3}}), True),
    ('★ ping 标记消失 + 无承诺 ⇒ **不驱动**（新雷不许被陈旧点劫持）',
     dict(point_marker=None, old=None), False),
    ('ping 标记消失 + old 存在但**没有** point ⇒ 不驱动',
     dict(point_marker=None, old={'lock': None}), False),
    ('已承诺点 + 结构拿到锁 ⇒ 让给结构（不驱动点）',
     dict(point_marker=None, old={'point': {'x': 1, 'y': 2, 'z': 3},
                                  'lock': {'id': 9}}), False),
    ('已承诺点 + 引擎选中泰坦 ⇒ 让给泰坦',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}, old={'point': {'x': 1, 'y': 2, 'z': 3}},
          titan_selected=True), False),
    ('已放弃（abandoned）⇒ 不驱动',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}, old={'point': {'x': 1, 'y': 2, 'z': 3}},
          abandoned=True), False),
    ('TTL 过期（armed=nil）且无承诺 ⇒ 不驱动',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3}), False),
    ('TTL 过期但有承诺 ⇒ **仍驱动**（承诺不受 TTL 影响，与注释一致）',
     dict(point_marker={'x': 1, 'y': 2, 'z': 3},
          old={'point': {'x': 1, 'y': 2, 'z': 3}}), True),
]
_bad = []
for label, kw, want in CASES:
    got = evaluate(**kw)
    ok = (got == want)
    print('    %-52s => %-5s (期望 %s)' % (label, got, want))
    if not ok:
        _bad.append(f'{label}: {got}!={want}')
check('point_drive_behaviour_matrix', not _bad, '判据真求值全部符合预期：%s' % (_bad or '无'))

print()
print('=== ③ 核心不变量：承诺后飞到底 + 新雷不被劫持 ===')
check('committed_point_survives_marker_loss',
      evaluate(point_marker=None, old={'point': {'x': 1, 'y': 2, 'z': 3}}) is True,
      '★★ ping 标记消失后，**已承诺的点**继续驱动（这正是"跟虫洞一样飞到底"）')
check('fresh_grenade_still_needs_live_ping',
      evaluate(point_marker=None, old=None) is False
      and evaluate(point_marker=None, old={'lock': None}) is False,
      '★★ 新扔的雷仍需 live ping ⇒ "顺手 ping 一下长期劫持 G-60"那条顾虑**仍然成立**')

print()
print('=== ④ 变异测试：改回旧写法必须让 sticky 那一格翻红 ===')
mutated = cond.replace('(point_marker~=nil or (old and old.point))', 'point_marker~=nil')
check('mutation_actually_changes_condition', mutated != cond,
      '变异确实把"live ping 或已承诺点"改回了 `point_marker~=nil`')
lua.execute("__MUT=assert(load([==[\nlocal abandoned,point_marker,old,P,m,frame,"
            "titan_selected,selected,point_armed,ping_take=...\nreturn (" + mutated + ")\n]==]))")
check('mutation_kills_the_sticky_case',
      bool(args_for(lua.eval('__MUT'),
                    point_marker=None, old={'point': {'x': 1, 'y': 2, 'z': 3}})) is False,
      '★★ 变异后"标记消失 + 已承诺点"变成 **false** ⇒ 这条门真的抓住了回归'
      '（否则它就是空转断言）')

print()
print('=== ⑤ 释放点：不许再因 ping 消失而丢弃已承诺的点 ===')
_rt = code(RT_SRC)
check('no_release_on_marker_loss',
      'held.point=nil' not in _rt,
      '★★ 原来那句 `held.point=nil`（在 `not point_marker` 下）必须消失 —— '
      '它就是"飞行中途丢目标"的直接实现')
check('no_point_released_event',
      'point_released' not in _rt,
      '★ `point_released` 事件随释放逻辑一起去掉（否则日志会继续误导）')
check('point_held_is_visible',
      "env.emit('point_held;" in RT_SRC and 'ping_gone_keep_flying' in RT_SRC,
      '★★ 新行为必须**可见**：ping 标记没了却继续飞，是本改动的核心行为，'
      '没有一行日志就无法在实机上确认它生效（"诊断被节流掉 = 诊断不存在"）')
check('point_held_is_once_per_grenade',
      'not held.point_sticky then' in RT_SRC and 'held.point_sticky=true' in RT_SRC,
      '★ 按雷只打一次（否则每帧一行、会被 emit 的 60 行节流丢掉）')

print()
print('=== ⑥ 取值必须 nil-safe（否则修反方向）===')
check('point_branch_uses_nil_safe_src',
      'local src=point_marker or old.point' in _rt,
      '★★ 点分支必须用 `src=point_marker or old.point` —— '
      '直接写 `point_marker.x` 会在 nil 上索引 ⇒ 抛错被 pcall 吞掉')
check('no_bare_point_marker_index_in_point_branch',
      'point_marker.x' not in _rt and 'point_marker.token' not in _rt,
      '★ 点分支里不得再有裸 `point_marker.<field>`')
check('point_held_target_uses_src',
      'tostring(src.slot)' in _rt,
      '★ `point_taken` 的 slot 走 `src`（沿用旧点时没有 slot ⇒ 允许 nil）')

print()
print('=== ⑦ 所有权互斥：结构 / 泰坦 拿到就必须丢弃已承诺的点 ===')
check('structure_lock_clears_point',
      re.search(r'old\.lock=result\.track\n(?:.*\n){0,6}?\s*old\.point=nil', RT_SRC) is not None,
      '★★ 结构拿到锁时 `old.point=nil` —— 否则锁以后失效时陈旧点会"复活"、'
      '把雷拉回早已作废的落点')
check('titan_lock_clears_point',
      re.search(r'old\.titan=result\.track\n(?:.*\n){0,4}?\s*old\.point=nil', RT_SRC) is not None,
      '★★ 泰坦链接管时 `old.point=nil`（同上）')

print()
print('=== ⑧ 状态行不许再写死 bughole_profiles ===')
# ⚠ 必须**剥注释**再查：我自己的新注释里就引用了 `bughole_profiles=16` 来解释历史，
#   直接查原文会把说明文字当成代码（本工程踩过好几次的老坑）。
_ENTRY_CODE = '\n'.join(l.split('--')[0] for l in ENTRY.splitlines())
check('status_line_profile_count_is_derived',
      'bughole_profiles=16' not in _ENTRY_CODE
      and "'bughole_profiles='..tostring(profile_count)" in _ENTRY_CODE,
      '★★ 原来写死 `bughole_profiles=16`（实际 28）⇒ 状态行在骗人；'
      '用户正是拿它核对候选项是否生效（实机日志里就写着 16）')
check('profile_count_guarded',
      "if type(StructureProfiles)=='table' then" in _ENTRY_CODE,
      '★ 逐层判空：状态行在加载期拼，抛错会让整个包 disabled')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
