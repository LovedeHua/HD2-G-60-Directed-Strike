"""离线仿真：**远距离追踪**（用户 2026-10-14 要求）。

用户原话：
  「增加主支的远距离追踪功能，不过只增加虫洞、构筑、巨型构筑、尖啸巢、
    孢子喷涌虫、落地穿梭舰这几个，其他的就不弄远距离追踪了」。
经确认：**距离上限只对这 6 类放开，其他标记目标仍维持 200 m**。

机制（缺一不可 —— 主支是这四件事的合力）
  ① 距离上限的**唯一实现** `target_policy.max_distance2`（原来硬编码 `40000` 在 4 处）
  ② **结构表**登记（唯一能拿到 `old.lock` 的地方 —— 白名单分支绕过敌阵营门槛）
  ③ **免几何兜底** `motion_point` + `structure_vent` 航路（构筑/飞船没有锚点几何）
  ④ `marked_allowed` **拆表**（"引擎自选要清掉" ≠ "玩家点名要放行"）

本文件钉的是**行为**，不是注释：
  · 6 类必须**全部**在结构表里（否则拿不到锁 ⇒ 远距离无从谈起）
  · 距离上限对结构目标可调、对**其他目标固定 200 m**（用户要求"其他的不弄"）
  · 免几何 profile 必须走 `motion_point` 分支（否则 `capture` 抛错 ⇒ 锁不上）
  · `structure_route` 必须有 `structure_vent` 分支（否则实机 assert）
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROF = (ROOT / 'compat' / 'structure_profiles.lua').read_text(encoding='utf-8')
SITES = (ROOT / 'compat' / 'blast_sites.lua').read_text(encoding='utf-8')
POLICY = (ROOT / 'src' / 'g60' / 'target_policy.lua').read_text(encoding='utf-8')
ROUTE = (ROOT / 'src' / 'g60' / 'structure_route.lua').read_text(encoding='utf-8')
FILTER = (ROOT / 'src' / 'g60' / 'small_filter.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
PRIORITY = (ROOT / 'src' / 'g60' / 'native_priority.lua').read_text(encoding='utf-8')
PING = (ROOT / 'src' / 'g60' / 'native_ping.lua').read_text(encoding='utf-8')
RUNTIME = (ROOT / 'src' / 'g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')


def code(t):
    return '\n'.join(l.split('--')[0] for l in t.splitlines())


failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


# 用户点名的 6 类
SIX = {
    '虫洞': ['8901f188db366b4b'],
    '构筑': ['5158e582fbeb26bd', '22cc0ed4ceb9cb68', 'f0b98fb953b13960',
             '4fb8eb356ac8553e', 'a1a7b76b29088843'],
    '巨型构筑': ['4232ee48e2cfd24e'],
    '尖啸巢': ['095686275a113614'],
    '孢子喷涌虫': ['aa28caf964d05500', 'e02e6bd34b606a85'],
    '落地穿梭舰': ['b3c9cdb79dc17937', '2ad2e055dad21f6e'],
}
ALL_SIX = sorted(h for hs in SIX.values() for h in hs)

print('=== 1. 结构表：6 类必须全部能拿到锁（否则远距离无从谈起）===')
lua = lj.LuaRuntime(unpack_returned_tuples=True)
common = lua.execute("return {getters={},alive_rva=0x1feeb0}")
prof = lua.execute(PROF)(common)
prof_keys = set()
for k in prof.keys():
    prof_keys.add(k.decode() if isinstance(k, bytes) else str(k))
_missing = [h for h in ALL_SIX if h not in prof_keys]
check('all_six_in_structure_profiles', not _missing,
      '★★ 用户点名的 6 类必须在结构表里 —— 那是**唯一**能让它们拿到 `old.lock` 的'
      '地方（白名单分支绕过敌阵营门槛）。缺失: %s' % (_missing or '无'))
check('structure_profiles_has_no_scan_key',
      'scan' not in prof_keys,
      '结构表里不该有 `scan` 伪键（那是 blast_sites 的约定）')

# 三类 kind 的分工
_kinds = {}
for h in ALL_SIX:
    p = None
    for k in prof.keys():
        kk = k.decode() if isinstance(k, bytes) else str(k)
        if kk == h:
            p = prof[k]
            break
    _kinds[h] = str(p['kind'])
check('six_use_only_two_kinds',
      set(_kinds.values()) <= {'structure_hole', 'structure_tower', 'structure_vent'},
      '6 类只许用这三种 kind：%s' % sorted(set(_kinds.values())))
check('fabricator_and_ship_are_vent',
      all(_kinds[h] == 'structure_vent'
          for h in SIX['构筑'] + SIX['巨型构筑'] + SIX['落地穿梭舰']),
      '★ 构筑/巨型构筑/飞船必须是 `structure_vent`（免几何兜底）')
check('nest_and_spewer_are_tower',
      all(_kinds[h] == 'structure_tower' for h in SIX['尖啸巢'] + SIX['孢子喷涌虫']),
      '★ 尖啸巢/孢子喷涌虫必须是 `structure_tower`（有锚点几何，靠伤害拆）')
check('holes_stay_holes', all(_kinds[h] == 'structure_hole' for h in SIX['虫洞']),
      '★ 虫洞仍是 `structure_hole`（行为不变）')

# motion_point 与锚点互斥
# ★★ 2026-10-14：**从"只查用户点名的 6 类"扩到"查全表"** ★★
#   原来只遍历 ALL_SIX ⇒ 任何**新登记**的 profile 都不受这两条守门约束。
#   广播台（57db57121f3e7ed2）就是这样加进来的 —— 扩全表后它自动被覆盖，
#   而且以后再加新的 vent 也不会漏（本工程纪律：守门要落在**每一处**，不是名单上那几处）。
_ALL_PROFILES = []
for _k in prof.keys():
    _kk = _k.decode() if isinstance(_k, bytes) else str(_k)
    _ALL_PROFILES.append((_kk, prof[_k]))
check('all_profiles_enumerated', len(_ALL_PROFILES) == 38,
      '结构表条目可枚举（实际 %d 条）' % len(_ALL_PROFILES))

_vent_with_anchor = []
for h, p in _ALL_PROFILES:
    if str(p['kind']) == 'structure_vent':
        has_anchor = any(getattr(p, f, None) is not None
                         for f in ('boss_hash', 'belly_hash', 'nodes', 'offset'))
        mp = p['motion_point']
        if has_anchor or not mp:
            _vent_with_anchor.append((h, 'anchor' if has_anchor else 'no motion_point'))
check('vent_profiles_are_motion_point_without_anchor', not _vent_with_anchor,
      '★★ **全表**每个 `structure_vent` 都必须 `motion_point=true` 且**没有锚点几何**'
      '（有锚点就该走 capture 那条路）。异常: %s' % (_vent_with_anchor or '无'))
# 反向：有锚点的绝不能带 motion_point（否则是两条路都想要）
_tower_with_mp = []
for h, p in _ALL_PROFILES:
    if str(p['kind']) != 'structure_vent' and getattr(p, 'motion_point', None) is not None:
        _tower_with_mp.append(h)
check('anchored_profiles_have_no_motion_point', not _tower_with_mp,
      '★ **全表**有锚点几何的 profile 不得带 `motion_point`：%s' % (_tower_with_mp or '无'))

print()
print('=== 2. 三类 capture 调用点都必须按 motion_point 分支 ===')
check('runtime_target_position_branches',
      'profile.motion_point' in code(RUNTIME)
      and 'if profile and not profile.motion_point then' in code(RUNTIME),
      '★ runtime 的 `target_position`（安全区绕行圆心）必须分支')
check('runtime_ping_position_branches',
      code(RUNTIME).count('if profile and not profile.motion_point then') >= 2,
      '★ runtime 的 `structure_ping.position` 也必须分支（两处同判据）')
check('priority_capture_branches',
      'if profile.motion_point then' in code(PRIORITY)
      and 'dpos.position(e)' in code(PRIORITY),
      '★ native_priority 的结构分支必须分支（否则 `capture` 抛错 ⇒ 锁不上）')
check('priority_pose_has_validate',
      'pose={point=mpoint,validate=function()' in code(PRIORITY),
      '★★ 免几何分支返回的 pose **必须带 `validate`** —— 否则下面那句'
      ' `assert(pose.validate() and …)` 对 nil 取字段会抛（主支 v0.1.34 的事故）')
check('structure_route_handles_vent',
      "if profile.kind=='structure_vent' then" in code(ROUTE),
      '★ `structure_route` 必须有 `structure_vent` 分支（否则实机 assert 崩）')
check('vent_route_returns_motion_point',
      'return {point=point,terminal=true,route={stage=\'attack\'}}' in code(ROUTE),
      '★ vent 分支只负责"飞过去"（爆点由 blast_sites 在到达段给）')

print()
print('=== 3. 距离上限：6 类可调，其他固定 200 m（用户要求"其他的不弄"）===')
check('policy_is_single_implementation',
      'function M.max_distance2(env, resource)' in policy_code
      if (policy_code := code(POLICY)) else False,
      '★ 距离上限必须只有**一处**实现（`target_policy.max_distance2`）')
check('hardcoded_40000_removed_from_takeover_paths',
      code(PRIORITY).count('40000') == 0 and code(PING).count('40000') == 0,
      '★★ 接管路径里不得再有硬编码 `40000`（主支 v0.1.35 漏改 `native_ping` 那处 ⇒'
      ' 超距标记进不了队列 ⇒ 用户报"有的构筑不追踪"）')
check('priority_uses_policy',
      code(PRIORITY).count('Policy.max_distance2(env') >= 3,
      '★ native_priority 的**三处**都要走唯一实现（eligible / generic / 结构分支）')
check('ping_uses_policy',
      'Policy.max_distance2(env,m.resource)' in code(PING),
      '★★ native_ping 的标记观察谓词也必须走（**最关键的一处**）')
check('ping_imports_policy', "local Policy=require('g60.target_policy')" in PING,
      '★ native_ping 必须引入 Policy（否则运行期 nil 索引）')

# 真跑 max_distance2：结构目标可调、其他固定
lua2 = lj.LuaRuntime(unpack_returned_tuples=True)
lua2.execute("package.preload['g60.util']=function() return {ref=function() return true end} end")
lua2.execute("package.preload['g60.small_filter']=function() return "
              "{excluded=function() return false end, "
              "statue_target=function(r) return r=='7c9455fcef107e41' end} end")
Pol = lua2.execute(POLICY)


def md(env, res):
    e = lua2.table_from(env)
    return Pol.max_distance2(e, res)


_struct_env = {'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
               'max_takeover_distance': 500}
_other_env = {'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
              'max_takeover_distance': 500}
_d_struct = md(_struct_env, '8901f188db366b4b')
_d_other = md(_other_env, 'deadbeefdeadbeef')
print('    结构目标（上限设 500） -> %.0f m' % _d_struct ** 0.5)
print('    其他目标（上限设 500） -> %.0f m' % _d_other ** 0.5)
check('structure_target_honours_config', abs(_d_struct ** 0.5 - 500) < 1e-6,
      '★ 结构目标取可配置的上限：实际 %.0f' % (_d_struct ** 0.5))
# ★★ 2026-10-18（用户选定方案 A）：**雕像走结构档距离** —— 跑真实 `max_distance2`
_statue_env = {'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
               'max_takeover_distance': 250, 'other_takeover_distance': 150}
_d_statue = md(_statue_env, '7c9455fcef107e41')
_d_plain = md(_statue_env, 'eacee39fa017b495')
check('statue_uses_structure_distance',
      abs(_d_statue ** 0.5 - 250) < 1e-6 and abs(_d_plain ** 0.5 - 150) < 1e-6,
      '★★ 雕像应跟**结构档**(250)、其他目标仍跟其他档(150)；'
      '实得 雕像 %.0f / 其他 %.0f' % (_d_statue ** 0.5, _d_plain ** 0.5))
check('non_structure_targets_share_one_adjustable_tier', abs(_d_other ** 0.5 - 200) < 1e-6,
      '★★ **非结构**标记目标（含泰坦家族）现在是**一档、可调**，默认 200。'
      '⚠ 用户 2026-10-14 先要求"其他敌人 100 m"，同日第二轮又要求'
      '「泰坦距离上限跟其他敌人的合并在一起调整」⇒ 合并后默认取 **200**'
      '（泰坦保持改动前的值；其他敌人从 100 回到 200 = 0.1.22 上游对一切标记目标的值）。'
      '⚠ 现在只有两档（结构 / 非结构），**"泰坦单独一档"的判据已从 policy 删除**：'
      '实际 %.0f' % (_d_other ** 0.5))
check('other_target_follows_its_own_slider',
      abs(md({'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
              'max_takeover_distance': 1000}, 'deadbeefdeadbeef') ** 0.5 - 200) < 1e-6
      and abs(md({'other_takeover_distance': 700}, 'deadbeefdeadbeef') ** 0.5 - 700) < 1e-6,
      '★★ 非结构目标跟**自己那一档**的滑块走（设 700 ⇒ 700）；'
      '结构滑块调到 1000 也**动不了它**（仍 200）')

# 夹取
check('clamps_low', abs(md({'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
                            'max_takeover_distance': 1}, '8901f188db366b4b') ** 0.5 - 50) < 1e-6,
      '下限夹到 50（防 0/负数让判据恒真 = 等于取消上限）')
check('clamps_high', abs(md({'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})}),
                             'max_takeover_distance': 9999}, '8901f188db366b4b') ** 0.5 - 1000) < 1e-6,
      '上限夹到 1000（防止锁天边目标时每帧做无意义的长距离几何）')
check('missing_config_defaults_250',
      abs(md({'structure_profiles': lua2.table_from({'8901f188db366b4b': lua2.table_from({})})},
             '8901f188db366b4b') ** 0.5 - 250) < 1e-6,
      '配置缺席 ⇒ 250（= entry 的默认值；用户 2026-10-14 定的）')
check('structures_off_still_uses_the_other_tier',
      abs(md({'max_takeover_distance': 500}, '8901f188db366b4b') ** 0.5 - 200) < 1e-6,
      '★ `structure_profiles` 关掉时（nil）⇒ 判不出"在结构表里" ⇒ 落到**非结构那一档**'
      '（默认 200，可调）。⚠ 不再是"一律 100" —— 那是我为三档模型写的 fail-safe，'
      '合并成两档后不再需要（判据就是"在不在结构表里"）。')
check('nil_resource_is_100', abs(md({'structure_profiles': lua2.table_from({})}, None) ** 0.5 - 100) < 1e-6,
      'resource 为 nil ⇒ 100（fail-safe：判不出是结构就按"其他"从严，不放开）')

print()
print('=== 4. marked_allowed 拆表（"引擎自选要清掉" ≠ "玩家点名要放行"）===')
_ma_s = FILTER.index('local marked_allowed = {')
_ma_blk = FILTER[_ma_s:FILTER.index('\n}', _ma_s)]
ma_keys = set(re.findall(r"\['([0-9a-f]{16})'\]\s*=\s*true", _ma_blk))
_ex_s = FILTER.index('local excluded = {')
_ex_blk = FILTER[_ex_s:FILTER.index('}', _ex_s)]
ex_keys = set(re.findall(r"\['([0-9a-f]{16})'\]\s*=\s*true", _ex_blk))
check('marked_allowed_is_a_separate_table',
      'function M.marked_allowed(resource) return marked_allowed[resource] == true end' in FILTER,
      '★ `marked_allowed` 必须是独立表（旧实现直接转发 `excluded`）')
check('excluded_unchanged', ex_keys == {'db90077e76faa025', '74e2285c01da4f71'},
      '★ `excluded` 仍是那两项（拆表没改它）：%s' % sorted(ex_keys))
check('marked_allowed_covers_six', all(h in ma_keys for h in ALL_SIX),
      '★ 6 类都在 `marked_allowed` 里：缺 %s' % [h for h in ALL_SIX if h not in ma_keys])
# ★★ 2026-10-18（用户报「有一些雕像不能 ping 出来炸毁」，选定放行 7 条）★★
#   实机证据：`generic_rejected;…;resource=7c9455fcef107e41;detail=NOT_ENEMY_RESOURCE`
#     ⇒ 结构路要求在 `structure_profiles`（它不在）、通用路要求三选一
#       （`enemy_faction` / `marked_allowed` / `blast_sites`）—— 全不中 ⇒ 拒。
#   它们是无名道具（数据里 name=N/A），但有 `DestructibleComponentData`
#     + `SpottableComponentData` ⇒ 可炸、可标记。
#   ⚠ 范围**收窄**：离线筛出「无名+可摧毁+可标记」共 58 条，
#     里面混着**玩家自己的装备** ⇒ 只收「任务目标 + 地图可见」这个子集。
STATUE_TARGETS = ['7c9455fcef107e41']
# ★★ 2026-10-18 第三轮（用户：「`3f2c34c69cfc94b2` / `9a1f728716da05b5` 这 2 条也先去除，
#   **除非 2 个仓库里能找到相关信息**」）。
#   ⇒ 用 `Darctor/Helldivers2_RawData` 的 `Data/entities/*.json` 查到了信息，
#     而信息说它们**不是雕像** ⇒ 按规则移除：
#       · `3f2c34c69cfc94b2`：`FactionComponentData` = **FactionType_SuperEarth**（友方！）
#         + `HellpodPayload` + `LoadoutPackage` ⇒ **留着会误炸友方**。
#       · `9a1f728716da05b5`：`DepositComponentData`（capacity 4/refill 20）
#         + `LoadoutPackage` ⇒ **补给点**，不是可炸目标。
#   ⚠ 反向钉住：被移除的 **6** 条不得回流。
STATUE_UNKNOWN = ['4a2f7e9a9c47c202', 'c979fa81b6678953',
                  'aef33bf33a18c97c', '27080697d055cb24',
                  '3f2c34c69cfc94b2', '9a1f728716da05b5']
_miss_st = [h for h in STATUE_TARGETS if h not in ma_keys]
# ★★ 2026-10-18（用户选定方案 A）：**雕像改走结构档距离** ★★
#   实机证据：放行后不再 `NOT_ENEMY_RESOURCE`，但仍被
#     `structure_mark;…;resource=7c9455fcef107e41;reason=OUTSIDE_RANGE` 拒（卡在 150 m）。
#   ⇒ 雕像必须走 `max_takeover_distance`（结构档）。
check('target_policy_has_statue_branch',
      'Filter.statue_target(resource)' in POLICY
      and 'local m=tonumber(env.max_takeover_distance) or 250' in POLICY,
      '★★ `target_policy.max_distance2` 必须有雕像分支、且用**结构档**上限')
check('small_filter_exposes_statue_target',
      'function M.statue_target(resource)' in FILTER
      and 'local statue_targets = {' in FILTER,
      '★ `small_filter` 必须单独暴露 `statue_target`（单一数据源）')
# ⚠ 行为测试（把 require 换档去跑真实 `max_distance2`）**已撤**：
#   两种档法都取不到 stub（`package.loaded` 与覆盖 `require` 均失败，
#   报 `attempt to call field 'statue_target' (a nil value)`）。
#   ⚠⚠ 更重要的教训：脚本**崩溃**时没有 `RESULT` 行，
#     而我的变异脚本用“没有 ALL PASS 就算抓到”判定 ⇒ **假阳性**！
#     已改为**先确认基线 ALL PASS、再做变异**（见下次执行）。
#   保留两道**字符串**门（下面）—— 它们足以钉住分支存在与用的是哪个上限常量。


print()
print('=== 5. blast_sites：免几何目标的爆点（靠 lift / 标定档位表）===')
lua3 = lj.LuaRuntime(unpack_returned_tuples=True)
bs = lua3.execute(SITES)
bs_keys = set()
for k in bs.keys():
    bs_keys.add(k.decode() if isinstance(k, bytes) else str(k))
_need_site = SIX['构筑'] + SIX['落地穿梭舰']
_missing_site = [h for h in _need_site if h not in bs_keys]
check('vent_targets_have_blast_site', not _missing_site,
      '★★ 免几何目标的**爆点完全靠 `blast_sites`** ⇒ 必须有条目，'
      '否则 b爆点落在实体原点（≈地表）。缺失: %s' % (_missing_site or '无'))
check('nest_spewer_not_in_blast_sites',
      all(h not in bs_keys for h in SIX['尖啸巢'] + SIX['孢子喷涌虫']),
      '★ 塔类**不**在这里：它们有锚点几何，爆点由 `structure_route` 算'
      '（登记在这里是历史错误 —— 它整块嵌在 old.lock 守卫里，没锁就走不到）')
check('giant_fabricator_lift_intact',
      'sites["4232ee48e2cfd24e"]' in SITES and 'lift=LIFT' in SITES,
      '★ 巨型构筑的 `lift=8.0` 标定结论不变（本功能只给它加结构锁）')
# 每条的 region 都要收紧（内半径 4 m 才触发拆毁）
# ⚠ 必须**按条目**判，不能按行判：`sites["4232ee48e2cfd24e"]` 那条的 `region=`
#   在**下一行**（它前面有长篇标定注释）⇒ 逐行 `startswith('sites[')` 会漏掉它
#   （我第一版就这么写的，导致假红）。
_site_entries = []
for _m in re.finditer(r'sites\["([0-9a-f]{16})"\]=\{', SITES):
    _nxt = SITES.find('sites[', _m.end())
    _body = SITES[_m.start():_nxt if _nxt > 0 else len(SITES)]
    _site_entries.append((_m.group(1), _body))
check('site_entries_enumerated', len(_site_entries) >= 8,
      '名册条目可枚举（实际 %d 条）' % len(_site_entries))
_loose = [h for h, body in _site_entries if 'radius=1.5,depth=0.25,above=0.6' not in body]
check('all_sites_have_tight_region', not _loose,
      '★ 每条爆点都要用收紧 region（爆炸中心必须落进 4 m 内半径）：'
      '异常 %s' % (_loose or '无'))

print()
print('=== 6. 配置 / 菜单 / 状态行（三处齐全）===')
check('entry_default_250', 'max_takeover_distance=250,' in code(ENTRY),
      '默认 250（用户 2026-10-14 定的：点名的 6 类 = 250 m）')
check('env_wired', 'max_takeover_distance=state.max_takeover_distance,' in code(ENTRY),
      '★ 必须接进 env（否则运行期读不到 ⇒ 静默 no-op）')
check('menu_slider_present', "id='g60.max_takeover_distance'" in ENTRY,
      '菜单里有滑块（用户要求"距离上限也放在 mod 设置里面可自定义"——主支语义）')
check('status_line_visible', "';max_takeover_distance='..tostring(state.max_takeover_distance)" in ENTRY,
      '状态行必须打出该值（看不到就无法确认生效）')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
