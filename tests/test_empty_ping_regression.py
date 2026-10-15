"""空 ping 回归门（用户 2026-10-14 报「空 ping 功能貌似出问题了」）。

事故
----
ping 空地时**玩家就站在落点附近**（你 ping 哪就站哪扔）。上一轮把 ping 点也当成
"预期引爆点"传进了安全区门：

    门： held = not blast_safe_hold(m,scope, blast_point or (point and {…}) or P.tpos)
                                                          ^^^^^^^^^^^^^^^^^^^^^^^ 多余

⇒ 玩家几乎恒在 `safe_zone_target_radius`（默认 12 m）内 ⇒ 门恒判"圈内" ⇒
  下面的绕行块把 ping 点**整个覆盖**成一个 5 m 外的环绕点 ⇒ 手雷绕着落点转、
  **永不落点** = 空 ping 废掉。

为什么 0.1.22 没这个问题（所以它是**回归**，不是新 bug）
  0.1.22 的 `blast_safe_radius=0` 且**没有** `safe_zone_target_radius`
  ⇒ 门第一行 `if safe_target<=0 and safe_grenade<=0 then return true end` 直接放行
  ⇒ 绕行块从不执行。把安全区改成默认开启后，"多传了一个点"才暴露。

修法
  门只拿 `blast_point`（体内爆点）或 `P.tpos`（圆心缓存）—— 与**主支逐字一致**
  （用户最初的要求就是「安全区机制跟主支类似」）。
  ⚠ 绕行**圆心**那处仍允许用 ping 点（合法：它只决定"绕到哪"，不决定"拦不拦"）。

本文件钉什么
  1. 形状门：门那句必须与主支一致；绕行圆心那处的 `point` 必须保留。
  2. 行为仿真：忠实转写判据，验证"引爆点判不了 ⇒ 放行"（不被 ping 点劫持），
     且真 fail-safe 与"以引爆点为中心"的主判据**都没被放松**。
"""
import pathlib

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / 'src' / 'g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
MAIN = ROOT.parent / "g60-bughole-lock" / "src" / "g60" / "experimental_runtime.lua"

_CODE = '\n'.join(l.split('--')[0] for l in RT.splitlines())
_NORM = ' '.join(_CODE.split())

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


print('=== 1. 形状门：门的实参必须与主支一致（不含 ping 点）===')
check('gate_passes_only_blast_point_or_tpos',
      'held=not blast_safe_hold(m,scope,blast_point or P.tpos[m.id])' in _NORM,
      '门那句 = `blast_point or P.tpos[m.id]`')
check('gate_does_not_pass_the_ping_point',
      'held=not blast_safe_hold(m,scope, blast_point or (point and' not in _NORM,
      '★★ 门**不得**再拿 ping 点当引爆点 —— 这正是空 ping 回归的根因')
if MAIN.exists():
    # ⚠⚠ 不要拿主支的**整句**做逐字比较 —— 它会随主支自己演进（写这条门时
    #   主支那次是 3 个实参，之后主支加了第 4 个「目标实体位置」的来源）。
    #   逐字比较 = 断言写在一个**会动的靶子**上 ⇒ 主支一动就假红，
    #   而它与"本工程有没有犯空 ping 的错"其实无关。
    #   ⇒ 只比**不变量**：主支的门同样**不拿 ping 点**当引爆点。
    _M = ' '.join('\n'.join(l.split('--')[0] for l in
                            MAIN.read_text(encoding='utf-8').splitlines()).split())
    _m_gate = 'held=not blast_safe_hold(m,scope,blast_point or P.tpos[m.id]' in _M
    _m_noping = 'held=not blast_safe_hold(m,scope, blast_point or (point and' not in _M
    check('main_branch_gate_also_has_no_ping_point', _m_gate and _m_noping,
          '★ 主支的门同样只拿 `blast_point` / `P.tpos`（**不变量**：两边都不拿 ping 点）'
          '—— 本工程与主支的口径一致（用户要求「跟主支类似」）')
else:
    check('main_branch_gate_also_has_no_ping_point', True, '跳过：主支不在本机')
# 绕行**圆心**必须仍能用 ping 点（合法：决定"绕到哪"，不是判据）
check('detour_center_still_uses_point',
      'local c=blast_point or (point and {point.x,point.y,point.z})' in _NORM,
      '★ 绕行圆心仍允许用 ping 点 —— 别把这条一起删了（那会让绕行失去圆心）')
check('tpos_filled_unconditionally',
      'if not blast_point then' in _NORM and 'P.tpos_frame[m.id]' in _NORM,
      '★ `P.tpos` 必须**无条件**填（只在 held 时填会死锁：永远判不了 ⇒ 永远拦不住）')

print()
print('=== 2. 行为仿真：判据逐档验证 ===')
lua = lj.LuaRuntime(unpack_returned_tuples=True)
SIM = r"""
local M = {}
-- 忠实转写 blast_safe_hold_at 的**判据**部分（含 fail-safe 与两半径顺序）
function M.decide(env, gd2, td2)
    local safe_target = tonumber(env.safe_zone_target_radius) or 0
    local safe_grenade = tonumber(env.blast_safe_radius) or 0
    if safe_target <= 0 and safe_grenade <= 0 then return 'allow','off' end
    if gd2 == nil and td2 == nil then
        if env.safe_zone_failsafe ~= false then return 'hold','failsafe' end
        return 'allow','failopen'
    end
    local about
    if safe_grenade > 0 and gd2 and gd2 <= safe_grenade*safe_grenade then about='grenade' end
    if not about and safe_target > 0 and td2 and td2 <= safe_target*safe_target then
        about='target'
    end
    if not about then return 'allow','clear' end
    return 'hold',about
end
return M
"""
sim = lua.execute(SIM)


def decide(target_r, grenade_r, failsafe, gd2, td2):
    e = lua.table_from({'safe_zone_target_radius': target_r,
                        'blast_safe_radius': grenade_r,
                        'safe_zone_failsafe': failsafe})
    r = sim.decide(e, gd2, td2)
    return r[0], r[1]


# (a) ★ 修复的核心：空 ping 时"引爆点判不了"，但手雷坐标**可读**（不能拿 nil 建模，
#     那会走成 fail-safe，与真实情形不符）⇒ 手雷半径关 ⇒ **放行** ⇒ ping 不被覆盖。
r = decide(12, 0, True, 4.0, None)
print('    空 ping（引爆点判不了，手雷可读）  -> %s / %s' % r)
check('A_empty_ping_not_hijacked', r[0] == 'allow',
      '★ 引爆点判不了 + 手雷半径关 ⇒ **放行**（不按 ping 点拦）⇒ ping 不被绕行覆盖')

# (a2) 反例：传了 ping 点 ⇒ 玩家站落点上 ⇒ 判圈内（复现旧 bug 的机制）
r_bad = decide(12, 0, True, 4.0, 4.0)
print('    反例：传了 ping 点（玩家站落点上）-> %s / %s' % r_bad)
check('A2_passing_ping_point_would_hold', r_bad[0] == 'hold' and r_bad[1] == 'target',
      '★★ 若把 ping 点当判据 ⇒ 玩家恒在圈内 ⇒ 绕行覆盖 ping 点 ⇒ **永不落点**'
      '（= 旧 bug 的机制，这条门在防止它复活）')

# (b) 真·fail-safe（两个距离都读不到）仍按上游不引爆
r_fs = decide(12, 0, True, None, None)
print('    两个距离都读不到（真 fail-safe）  -> %s / %s' % r_fs)
check('B_failsafe_still_holds', r_fs[0] == 'hold' and r_fs[1] == 'failsafe',
      '★ 真 fail-safe 仍不引爆 —— 本次修复**没有**放松它')

# (c) 主判据（以引爆点为中心）仍然生效
r_c = decide(12, 0, True, None, 25.0)
print('    体内爆点 5 m 内有玩家            -> %s / %s' % r_c)
check('C_still_holds_near_blast_point', r_c[0] == 'hold' and r_c[1] == 'target',
      '★ 安全区主判据仍生效 —— 修复没有削弱安全区')

# (d) 超过半径 ⇒ 放行
r_d = decide(12, 0, True, None, 400.0)
check('D_allows_when_far', r_d[0] == 'allow' and r_d[1] == 'clear',
      '超过半径 ⇒ 放行')

# (e) 两个半径都关 ⇒ 整段不生效（= 0.1.22 的行为；也是绕行块从不执行的原因）
r_e = decide(0, 0, True, 4.0, 4.0)
print('    安全区全关（= 0.1.22 默认）      -> %s / %s' % r_e)
check('E_off_is_fully_inert', r_e[0] == 'allow' and r_e[1] == 'off',
      '★ 两个半径都为 0 ⇒ 第一行就放行 ⇒ **绕行块从不执行**（这就是 0.1.22 没这个 bug 的原因）')

# (f) 手雷半径单独生效（可选第二条仍在）
r_f = decide(0, 8, True, 9.0, None)   # 3 m < 8 m
check('F_grenade_radius_still_works', r_f[0] == 'hold' and r_f[1] == 'grenade',
      '手雷半径（可选第二条）仍然独立生效')

# (g) 顺序：先手雷后目标（与上游 PlayerProximity.hold 一致）
r_g = decide(12, 8, True, 9.0, 9.0)   # 两个都在圈内 ⇒ 应报 grenade
check('G_grenade_checked_first', r_g[1] == 'grenade',
      '★ 判据顺序照上游：先手雷后目标（`about=` 才能与上游语义逐字对上）')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
