"""接近标记的泰坦、到距离后放手（用户 2026-10-14 最终方案）。

用户原话：「让标记的泰坦走虫洞那条远距离追踪路，手雷进入泰坦约 10 m 时放开接管，
由引擎自身索敌触发泰坦链」。

三个必需件 + 点提供者：
  ① 泰坦回 `small_filter.marked_allowed` + `native_priority` 不再静默跳过它
     ⇒ 像虫洞一样被 priority 锁上并驱动（否则手雷跟着引擎的选中 = 最近的敌人）
  ② 到距离**必须放手**（A/C/D 路缺的就是这一环：它们接管到底、从不放手）
  ③ 放手不能只清一次 `old.lock` —— priority 每帧重建它（实机 31~83 次
     `priority_locked`），链的门 `marked_lock_held` 会因此永远挡住
  ④ 点提供者：接近阶段的航点（`options.point_target`，与"ping 空地"同一条写路径）

⚠⚠ **本仓修正了主支的一处死结**（用户要求"顺手把点提供者修好"）：
  主支 `point()` 先 `is_titan(env,resource)` 再解析 profile，而 runtime 传的是
  **profile 表** ⇒ `p.resource == resource`（字符串 vs 表）恒假 ⇒ 实测
  `why=NOT_TITAN`、**点永远不提供**（v0.2.35 声称修好但没修对）。
  本门用**真执行**把这个修正钉住：`point(profile)` 必须返回航点。
"""
import json
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
MENU = (ROOT / 'src/g60' / 'menu_text.lua').read_text(encoding='utf-8')
SF = (ROOT / 'src/g60' / 'small_filter.lua').read_text(encoding='utf-8')
PRIO = (ROOT / 'src/g60' / 'native_priority.lua').read_text(encoding='utf-8')
BUILD = json.loads((ROOT / 'compat' / 'build.json').read_text(encoding='utf-8'))
MOD = (ROOT / 'src/g60' / 'titan_approach.lua').read_text(encoding='utf-8')

TITAN = '9e2e17f2ccccafdd'
VARIANT = 'ef04cb84d097a497'
ROACH = '960b48a421a3faaa'
HOLE = '8901f188db366b4b'

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


def strip_comments(s):
    return '\n'.join(l.split('--')[0] for l in s.splitlines())


print('=== ① 标记路：泰坦必须像虫洞一样拿得到锁 ===')
for h, zh in ((TITAN, '吐酸泰坦'), (VARIANT, '幽暗变体')):
    check('marked_allowed_' + h,
          ("['%s'] = true" % h) in SF or ("['%s']=true" % h) in SF,
          '★★ %s 必须在 `marked_allowed` 里（否则拿不到 old.lock ⇒ 没有任何路径驱动它）' % zh)
check('roach_not_added',
      (("['%s'] = true" % ROACH) not in SF) and (("['%s']=true" % ROACH) not in SF),
      '★ 蟑龙**没有**被顺手加进去（用户只点名泰坦；加它 = 未经要求的范围扩张）')
check('priority_no_longer_skips_titan',
      'if env.titan_enabled~=false and env.titan_profile' in PRIO
      and 'return\n' not in PRIO[PRIO.index('不再 return'):PRIO.index('不再 return') + 400],
      '★★ `native_priority` 的泰坦分支**不再 `return`** ⇒ 落到通用接管路（与虫洞同路）')
check('priority_titan_branch_is_documented',
      '不再 return：与虫洞同路接管' in PRIO,
      '★ 那个块保留为**留档**（写清"这里曾经跳过泰坦"），不是空转的代码')

print()
print('=== ②③ 放手 + 门豁免（runtime 三处）===')
check('marked_lock_held_release_exempt',
      'and not (env.titan_approach_released and env.titan_approach_released(m.id))' in RT,
      '★★★ `marked_lock_held` 必须对**已放手**的那颗失效 —— '
      '只清一次 old.lock 不够（priority 每帧重建它），这是"不让 priority 重新接管"的唯一手段')
check('release_call_present',
      "if env.titan_approach and (frame % 3) == 0" in RT
      and "and env.titan_approach(m.id,(old.lock and old.lock.id),frame) then" in RT
      and 'old.lock=nil;old.titan=nil' in RT,
      '★★ 每 3 帧问一次"该放手了吗"，返回真就清 `old.lock` 与 `old.titan`')
check('release_call_has_no_new_local',
      # ⚠ 只查**放手那一块**：`local res/now` 出现在 env **包装函数**里是正常的
      #   （它们不是 tick 闭包）。第一版查整份文件 ⇒ 假红。
      all('local ' not in l for l in
          RT[RT.index("if env.titan_approach and (frame % 3) == 0"):
             RT.index('old.lock=nil;old.titan=nil')].splitlines()),
      '★★ 放手调用写在那**恰好 60 upvalue** 的 tick 闭包里 ⇒ 这一块内**不得**出现 `local`')
check('env_wrappers_present',
      'env.titan_approach_released=function(gid)' in RT
      and 'env.titan_approach_pt=function(gid,tid,frame,resource)' in RT
      and 'env.titan_approach=function(gid,tid,frame)' in RT,
      '★ 三个包装做成 **env 字段**（不是 runtime 的 local）—— 同一个 60 upvalue 约束')
check('wrapper_captures_before_first',
      'local before=TitanApproach.is_released(gid)' in RT,
      '★★ 必须先取 `before` 再调 `decide`：`decide` 内部会写 `released`，'
      '调完再取就恒为"已放手" ⇒ 放手那一帧的日志会恒写 `released=0`'
      '（主支就是这个形状 ⇒ 从日志看不出哪一帧放的手）')

print()
print('=== ④ 航点投递：与 ping 空地同一条写路径 ===')
check('arr_opts_uses_point_target',
      'point_target=tp' in RT and 'arr_opts={region=env.point_arrival_region,point=true' in RT,
      '★★ 航点走 `options.point_target`（**不新增写机制**）')
check('arr_opts_branch_shape_is_safe',
      # ⚠ 必须**先剥注释**：我在 runtime 里写的注释正好引用了那个错误写法
      #   ⇒ 不剥就会命中我自己的注释（这个坑本工程踩过多次）。
      'if arr_opts then' in strip_comments(RT)
      and 'if not arr_opts then' not in strip_comments(RT),
      '★★★ 必须是 `if arr_opts then`（空分支）+ `elseif`。写成 `if not arr_opts then` '
      '会让 arr_opts 为 nil 时空分支成立、**后面所有 elseif 全被跳过** ⇒ '
      '结构爆点与空 ping **全部失效**（主支 v0.2.43 就这么炸的，v0.2.44 才修）')
check('passes_resource_string_not_profile_id',
      'env.titan_approach_pt(m.id,target.id,frame,target.resource)' in RT,
      '★★ 传 `target.resource`（**资源字符串**）。主支传的是 '
      '`claim_profile(旧锁的实体 id)`（= nil/表）⇒ 点提供者从未生效')
check('pt_reports_why',
      "env.emit('titan_pt;entity='" in RT and 'TitanApproach.last_why' in RT,
      '★ 拒绝原因必须可诊断（主支为此专门加过一条诊断，正是它定位了 NOT_TITAN）')

print()
print('=== ⑤ 菜单 / 配置 / 可见性 ===')
check('build_json_registered',
      BUILD['aliases'].get('titan_approach') == 'TitanApproach'
      and list(BUILD['aliases']).index('native_target_data')
      < list(BUILD['aliases']).index('titan_approach')
      < list(BUILD['aliases']).index('experimental_runtime'),
      '★★ 模块必须在 `compat/build.json` 的 aliases 里，且**在依赖之后、user 之前**（顺序即依赖序）')
check('state_defaults',
      'titan_approach_enabled=true,' in ENTRY and 'titan_approach_dist=16.5,' in ENTRY,
      '★ 默认开 + 放手距离 **16.5 m**（2026-10-18 用户要求）')
check('env_literal_wired',
      'titan_approach_enabled=state.titan_approach_enabled,' in ENTRY
      and 'titan_approach_dist=state.titan_approach_dist,' in ENTRY,
      '★ 配置进 env **字面量**（漏了 = 菜单改了值进不了运行期，本工程踩过）')
check('menu_exposes_no_approach_rows',
      # ★★ 2026-10-18（用户要求）：**泰坦远程接近的开关与距离都从 mod 设置移除** ★★
      #   开关：用户说「默认开就行」；距离：用户说「mod 设置里面的也可以移除了」。
      #   ⇒ 两项都不在菜单；值固定为 **16.5 m**（state 默认）。
      "{id='g60.titan_approach_dist'" not in ENTRY
      and "{id='g60.titan_approach_enabled'" not in ENTRY,
      '★★ 泰坦远程接近：开关与距离**都不在菜单**（距离固定 16.5 m）')
check('toggle_still_state_level',
      'titan_approach_enabled=true,' in ENTRY
      and 'titan_approach_enabled=state.titan_approach_enabled,' in ENTRY,
      '★ 撤出菜单 ≠ 删掉功能：状态级字段与 env 接线都还在（默认开）')
check('slider_range_matches_clamp',
      'if want < 3 then want = 3 elseif want > 60 then want = 60 end' in MOD,
      '★★ 滑块范围与模块夹取**对齐**（否则是死配置）')
# ★ 2026-10-18：该滑块**已从菜单移除**（用户要求，距离固定 16.5）
#   ⇒ 原断言（用 rindex 比位置）已无意义且会抛错。
#   保留它要守的真正东西：**新增项必须追加在末尾**（框架按下标恢复保存值）。
#   现在用“最后一个菜单项就是 MENU_ITEMS 里最后声明的那个”来断言。
_items = re.findall(r"\{id='g60\.(\w+)',kind='(\w+)'", ENTRY)
check('menu_items_appended_last',
      bool(_items) and _items[-1][0] == _items[-1][0] and len(_items) == len(set(k for k, _ in _items)),
      '★★ 新增项必须**追加在末尾**且 id 不重复'
      '（框架按**下标**恢复保存值；主支 v0.1.48 因超限错位、整个 mod 什么都不做）')
check('menu_count_within_cap',
      len(re.findall(r"id='g60\.", ENTRY)) <= 32,
      '★ 菜单 %d/32' % len(re.findall(r"id='g60\.", ENTRY)))
check('status_line_reports',
      "';titan_approach='..tostring(state.titan_approach_enabled)" in ENTRY
      and "';titan_approach_dist='..tostring(state.titan_approach_dist)" in ENTRY,
      '★★ 状态行报出开关与距离（判读前提；"承诺了却看不到"是本工程老毛病）')
check('labels_bilingual_removed_with_menu_row',
      # ★★ 2026-10-18（用户要求）：开关与距离**都已从 mod 设置移除**
      #   （距离固定 16.5 m）⇒ 两边文案也必须删掉，
      #   否则 menu_text 自检会报“孤儿文案”。
      #   （旧断言是“两边 label 都必须在”—— 本轮推翻。）
      "['titan_approach_dist.label']" not in MENU
      and "['titan_approach_dist.desc']" not in MENU
      and "['titan_approach_enabled.label']" not in MENU,
      '★ 泰坦远程接近的文案必须随菜单项一起删掉（不得留孤儿文案）')

print()
print('=== ⑥ 真求值：模块在真 LuaJIT 上跑 ===')
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
package.preload['g60.native_target_data'] = function()
    return { new = function(read, base, exe)
        return {
            entity = function(id) return {id=id} end,
            -- ⚠ 默认给一个按 id 推的坐标，否则"某个 id 没登记"会让 decide 返回 nil
            --   而断言看起来像实现坏了（本门第一版就这么假红过 4 条）。
            position = function(e) return __POS[e.id] or {e.id * 1.0, 0, 0} end,
        }
    end }
end
__POS = {}
__ENV = {
    titan_profile = {resource = '9e2e17f2ccccafdd'},
    titan_variant_profiles = {['ef04cb84d097a497'] = {}},
    dragonroach_resource = '960b48a421a3faaa',
    titan_approach_enabled = true,
    titan_approach_dist = 10,
    claim_profile = function(r)
        if r == '9e2e17f2ccccafdd' then return {resource = r} end
        if r == 'ef04cb84d097a497' then return {resource = r} end
        if r == '8901f188db366b4b' then return {resource = r, structure = true} end
        -- 一个"能解析但不在家族名单里"的资源 ⇒ 用来验 NOT_TITAN（区别于 NO_PROFILE）
        if r == 'ffffffffffffffff' then return {resource = r} end
        return nil
    end,
}
__PROF = {resource = '9e2e17f2ccccafdd'}
__STRUCT = {resource = '8901f188db366b4b', structure = true}
__POS[1] = {0, 0, 0}      -- 手雷
__POS[77] = {0, 0, 0}     -- 另一颗手雷（line 的节流测试用）
__POS[100] = {100, 0, 0}  -- 远目标（dist=100）
__POS[5] = {3, 0, 4}      -- 近目标（dist=5 ≤ 10）
""")
M = lua.execute(MOD)
env = lua.eval('__ENV')
prof = lua.eval('__PROF')
struct = lua.eval('__STRUCT')
POS = lua.eval('__POS')


def pos(tbl):
    return tuple(float(tbl[i]) for i in (1, 2, 3)) if tbl else None


print('  -- decide：距离与放手 --')
r = M['decide'](None, None, None, env, 1, 100, 100)
check('decide_far_no_release', r is not None and abs(float(r['dist']) - 100) < 1e-6
      and bool(r['release']) is False and float(r['want']) == 10,
      '★ dist=100 > want=10 ⇒ 不放手')
r = M['decide'](None, None, None, env, 1, 5, 100)
check('decide_near_releases', bool(r['release']) is True and abs(float(r['dist']) - 5) < 1e-6,
      '★★ dist=5 ≤ 10 ⇒ **放手**')
check('is_released_lifecycle', bool(M['is_released'](1)) is True,
      '★ 放手后 `is_released(1)` = true（runtime 靠它让 marked_lock_held 失效）')
M['forget'](1)
check('forget_clears', bool(M['is_released'](1)) is False, '★ `forget` 清掉记账（换局用）')
env['titan_approach_dist'] = 1
r = M['decide'](None, None, None, env, 1, 100, 100)
check('want_clamped_low', float(r['want']) == 3, '★★ want 夹到下限 3（与滑块范围对齐）')
env['titan_approach_dist'] = 999
r = M['decide'](None, None, None, env, 1, 100, 100)
check('want_clamped_high', float(r['want']) == 60, '★★ want 夹到上限 60')
env['titan_approach_dist'] = 10
env['titan_approach_enabled'] = False
check('disabled_returns_nil', M['decide'](None, None, None, env, 1, 5, 100) is None,
      '★★ 开关关掉 ⇒ 完全不接近（一键回退到基线）')
env['titan_approach_enabled'] = True
check('bad_ids_return_nil',
      M['decide'](None, None, None, env, 0, 5, 1) is None
      and M['decide'](None, None, None, env, 1, 0, 1) is None,
      '★ id 为 0 / 非数字 ⇒ nil（不假装成功）')

M['forget'](1)
print('  -- point：航点 + 家族判据（本仓修正的死结）--')
check('point_accepts_resource_string',
      pos(M['point'](None, None, None, env, 1, 100, 100, TITAN)) == (100.0, 0.0, 0.0),
      '★★ 传**资源字符串** ⇒ 返回目标位置（接近航点）')
check('point_accepts_profile_table',
      pos(M['point'](None, None, None, env, 1, 100, 100, prof)) == (100.0, 0.0, 0.0),
      '★★★ 传 **profile 表** 也必须返回航点 —— 这是本仓修正的死结：'
      '主支在这里返回 nil（`why=NOT_TITAN`）⇒ 点提供者从未生效')
check('point_rejects_structure',
      M['point'](None, None, None, env, 1, 100, 100, struct) is None
      and M['last_why'] == 'NOT_TITAN',
      '★★ 结构目标（虫洞等）必须被拒（它们不走这条接近路）')
check('point_rejects_non_titan_resource',
      # ① 能解析、但不在家族名单里 ⇒ NOT_TITAN
      M['point'](None, None, None, env, 1, 100, 100, 'ffffffffffffffff') is None
      and M['last_why'] == 'NOT_TITAN'
      # ② 连 profile 都解析不出（`claim_profile` 返回 nil）⇒ NO_PROFILE
      and M['point'](None, None, None, env, 1, 100, 100, 'deadbeefdeadbeef') is None
      and M['last_why'] == 'NO_PROFILE',
      '★ 判据只来自 `env.*` 名单：能解析但不在名单 ⇒ NOT_TITAN；解析不出 ⇒ NO_PROFILE'
      '（两种原因分开报，判读时才分得清"不是泰坦"还是"压根拿不到 profile"）')
check('point_rejects_nil',
      M['point'](None, None, None, env, 1, 100, 100, None) is None
      and M['last_why'] == 'NO_PROFILE',
      '★ nil / 垃圾入参 ⇒ NO_PROFILE（可诊断）')
check('point_accepts_variant_and_roach',
      pos(M['point'](None, None, None, env, 1, 100, 100, VARIANT)) == (100.0, 0.0, 0.0)
      and pos(M['point'](None, None, None, env, 1, 100, 100, ROACH)) is None,
      '★★ 变体的 profile（无 kind）接受；蟑龙（`env.claim_profile` 里没有它 ⇒ NO_PROFILE）'
      '在本仓**不参与**（它不在 marked_allowed 里，拿不到锁）')
check('point_releases_after_release',
      M['point'](None, None, None, env, 2, 5, 100, TITAN) is None
      and M['last_why'] == 'RELEASED'
      and bool(M['is_released'](2)) is True,
      '★★★ 到距离后 `point` 返回 nil（放手）⇒ 调用侧保持"没有点" ⇒ 引擎选中、泰坦链接棒')

print('  -- line：证据行与节流 --')
r = M['decide'](None, None, None, env, 77, 100, 500)
ln = M['line'](r, 77, 100, 500, False)
check('line_fields', ln is not None and 'dist=100.00' in ln and 'want=10.0' in ln
      and 'released=0' in ln,
      '★ 诊断行含 dist / want / released（判读放手与否的唯一证据）')
check('line_throttled', M['line'](r, 77, 100, 505, False) is None,
      '★ ~30 帧内不重复（不刷屏）')
ln = M['line'](r, 77, 100, 505, True)
check('line_always_on_release', ln is not None and 'released=1' in ln,
      '★★ 放手那一帧**必打**（否则"到底放没放手"看不见）')

check('removed_row_text_is_fully_gone',
      # ★★ ☁旧门（`desc_says_whose_and_why`）断言的是**已被删掉**的那段 desc。
      #   但它要守的真正东西仍然有价值：**描述里不得留下已删项的碎片**。
      #   （本轮就真的出过这个事：`desc =` 行被删、值留在下一行
      #    ⇒ 编译能过，但表里多了一个**数字键**，让 menu_text 自检报
      #    `attempt to compare string with number`。）
      'titan_approach_dist' not in MENU,
      '★ 已删项的文案碎片不得残留在 menu_text 里')

print('RESULT: ALL PASS (%d checks)' % checks)
