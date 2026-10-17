"""离线仿真：标记可用性 + 多标记分配（跑**真实**的 target_reservations 模块）。

为什么需要它
------------
这个区域的两个 bug 都**只在游戏里**才被发现，而且都是逻辑错，读代码读不出来：
  ① "load>0 就跳过"那条规则把每次分配限制在**一帧**内生效 ⇒ 手雷不飞；
  ② 挑选循环**从来不问**"这个标记还算不算数" ⇒ 已取消的标记照样被选中。
本套件在 LuaJIT 上、用**真实的** `target_reservations`，离线复现 runtime 的决策，
让下一个这类 bug 在出货前就被抓住。

它模型化的东西（移自主支 `g60-bughole-lock` 的同名测试）
  * `P.usable(mark, live, assigning)` —— 标记可用性的**唯一判据**
    （活标记 / 已取消 / 自然过期 / 在飞的锁）
  * 挑选循环            —— 可用性 + 名额 + **按时间顺序**选择
  * 预约生命周期        —— claim / keep_only / reconcile 缺席宽限 / 退役释放

怎么保证它没说谎
  转写与真实源码**逐字对齐**：下面先断言关键源码片段仍在，源码改了形状而本文件没改
  ⇒ 测试失败，而不是安静地仿真一个旧设计。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = (ROOT / 'src' / 'g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
RESERVATIONS = (ROOT / 'src' / 'g60' / 'target_reservations.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')

# ---------------------------------------------------------------- 源码形状断言
# 只去掉**行注释**（不碰字符串），避免注释里的说明文字被当代码。
_CODE = '\n'.join(l.split('--')[0] for l in RUNTIME.splitlines())

SHAPE = [
    ('usable_is_the_single_implementation',
     'P.usable=function(mark,live,assigning)' in _CODE
     and 'remembered_intent=function(mark,live) return P.usable(mark,live) end' in _CODE,
     'P.usable 不再是唯一实现，或 remembered_intent 不再转发给它'),
    ('pick_loop_consults_usable',
     'and P.usable(q,q.current,true)' in _CODE,
     '挑选循环不再问 P.usable —— 已取消的标记会被选中'),
    ('pick_loop_is_time_ordered',
     'local at=tonumber(q.marked_at) or 0' in _CODE
     and 'if not best or at<best_at' in _CODE,
     '挑选不再按 marked_at 时间序'),
    # ★★ 2026-10-18（用户要求）：**两个上限合并成一个**，多标记自定义已移除；
    #   能突破它的只有**白名单单位**（按目标资源）。
    ('caps_read_from_env',
     'if n>=1 then c=tonumber(env.max_grenades_per_target) or 1 end' in _CODE
     and 'multi_mark_grenades_per_target' not in _CODE,
     '上限口径：基础从 env 取、且不再有第二个设置'),
    ('whitelist_is_wired',
     'GRENADE_CAP_WHITELIST' in _CODE
     and 'Reservations.new(tonumber(env.max_grenades_per_target) or 1, GRENADE_CAP_WHITELIST)' in _CODE,
     '白名单表必须传给预留系统（否则按资源取上限不生效）'),
    ('keep_only_is_called',
     'reservations:keep_only(owner,best.identity)' in _CODE,
     '缺 keep_only ⇒ 一颗雷会囤积预约（主支仿真 S10）'),
]

# ---------------------------------------------------------------- runtime 转写
SIM = r"""
local M = {}

-- P.usable 的忠实转写（src/g60/experimental_runtime.lua）
function M.usable(P, env, frame, claim_profile, mark, live, assigning)
    if live or (mark and mark.current) then return true end
    if not mark then return false end
    if not assigning and P.locked_ids[mark.id] then return true end
    if claim_profile(mark.resource) then
        if env.structure_mark_live_only == false then return true end
    elseif env.unit_mark_live_only == false then
        return true
    end
    return false
end

-- 挑选循环的忠实转写。
-- engageable(resource) 代表 runtime 里的可交战判据（结构 profile / 敌阵营 / marked_allowed）。
function M.pick(api, P, env, frame, claim_profile, engageable, queue, owner, single_setting, multi_setting)
    local marks = #queue
    api:set_cap(marks > 1 and (tonumber(multi_setting) or 1) or (tonumber(single_setting) or 1))
    local multi = marks > 1
    local best, best_at, best_order
    for i = 1, marks do
        local q = queue[i]
        if engageable(q.resource) and M.usable(P, env, frame, claim_profile, q, q.current, true)
            and api:available(owner, q.identity) then
            local at = tonumber(q.marked_at) or 0
            local ord = tonumber(q.order) or 0
            if not best or at < best_at or (at == best_at and ord < best_order) then
                best, best_at, best_order = q, at, ord
            end
        end
    end
    if best then
        api:claim(owner, best.identity)
        api:keep_only(owner, best.identity)
        return best.id
    end
    return nil
end
return M
"""

lua = lj.LuaRuntime(unpack_returned_tuples=True)
SIM_M = lua.execute(SIM)
RES_M = lua.execute(RESERVATIONS)

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    if ok:
        print(f'  PASS {name}')
    else:
        print(f'  FAIL {name}  [{detail}]')
        failures.append(name)

# ★★★ 2026-10-18（用户要求）：**白名单单位可突破每目标手雷上限** ★★★
#   用户：「移动工厂2颗，坦克及其变体2颗，噪轰引擎4颗，猎杀器/证真者2颗」，
#     且「对无标记的情况下也起作用」。
#   ⚠ 从运行时源码里**抽取真实的白名单表**（不在测试里重写一份）——
#     否则表改了而测试还绿，就是假的。
_WL_M = re.search(r"GRENADE_CAP_WHITELIST=\{(.*?)\n    \}", RUNTIME, re.S)
check('whitelist_table_exists_in_runtime', _WL_M is not None,
      '★ 运行时里必须有 `GRENADE_CAP_WHITELIST` 表')
_WL_BODY = re.sub(r'--[^\n]*', '', _WL_M.group(1)) if _WL_M else ''
#   ⚠ 必须**先剥注释再压平换行** ——
#     `--` 注释在压平后会把**后面所有条目全吞掉**（实踩）。
_WL_LUA = 'return {' + _WL_BODY + '}'
lua.execute("WL = (function() %s end)()" % _WL_LUA.replace('\n', ' '))
# 把**真实的** target_reservations 装成 Lua 全局 `RES`（行为守门用）
lua.execute("RES = (function()\n" + RESERVATIONS + "\nend)()")
lua.execute("""
function wl_tries(cap, resource)
    local R = RES.new(cap, WL)
    local T = 'tgt0123456789abcdefghijk'   -- identity 要求 24 字符
    local n = 0
    for i=1,12 do
        local owner = 'o'..i
        if R:available(owner, T, resource) then R:claim(owner, T, resource); n=n+1
        else break end
    end
    return n
end
""")

def wl_tries(cap, resource):
    return lua.eval('wl_tries(%d, %r)' % (cap, resource))

check('whitelist_vox_engine_allows_four', wl_tries(1, 'bc242702fb46b7e7') == 4,
      '★★ 噪轰引擎（bc242702fb46b7e7）应接受 **4** 颗（用户明确要求）')
check('whitelist_factory_strider_allows_two',
      wl_tries(1, 'd37e8d120d2836e3') == 2 and wl_tries(1, '30f2dee2333f227a') == 2,
      '★ 移动工厂与带干扰塔变体 ⇒ **2** 颗')
check('whitelist_tanks_allow_two',
      all(wl_tries(1, h) == 2 for h in ('53d8919d7b8abd67','31bae74d2f064d8d',
                                        'c6449ffd9ea3779c','63df3d07b7424588')),
      '★ 坦克及其变体（淋灭/MK2/碎裂/铁幕） ⇒ **2** 颗')
check('whitelist_harvester_and_veracitor_allow_two',
      all(wl_tries(1, h) == 2 for h in ('965eae5a51acdd4a','d63fcbff0851b7af',
                                        '20b9c7734daead65')),
      '★ 猎杀器/猎杀器 MK2/证真者 ⇒ **2** 颗')
# ★★ 2026-10-18（用户要求）：**泰坦及其变体、蟑龙也纳入白名单**（各 2 颗）★★
#   哈希来源均在 `compat/`（不是猜的）：
#     `9e2e17f2ccccafdd` 吐酸泰坦 / `ef04cb84d097a497` 孢子泰坦（变体）
#     / `960b48a421a3faaa` 蟑龙。
#   ⚠ 反向：`titan_variants.lua` 里的 3 个 **warrior 变体**不得进表
#     （它们是武斗虫，不在用户说的“泰坦及其变体”里）。
check('whitelist_titan_family_allows_two',
      all(wl_tries(1, h) == 2 for h in ('9e2e17f2ccccafdd', 'ef04cb84d097a497',
                                        '960b48a421a3faaa')),
      '★★ 泰坦/泰坦变体/蟑龙 ⇒ **2** 颗')
check('whitelist_excludes_titan_variant_warriors',
      all(wl_tries(1, h) == 1 for h in ('7e4c6b45bcc45c3f', '8c31b749759cbd61',
                                        'b6a181adcf547aeb')),
      '★ 那 3 个是 **warrior（武斗虫）变体**，不得进白名单')
check('whitelist_leaves_unlisted_at_base',
      wl_tries(1, 'eacee39fa017b495') == 1 and wl_tries(1, 'deadbeefdeadbeef') == 1,
      '★ 不在名单里的单位一律用**基础上限**（不能被白名单误伤）')
check('whitelist_absent_falls_back_to_base',
      lua.eval("(function() local R=RES.new(1) local T='tgt0123456789abcdefghijk' "
               "R:claim('a',T); local ok=R:available('b',T); return ok end)()") == False,
      '★ 不传白名单时行为与旧版**逐字一致**（cap=1 时第二颗被拒）')
check('whitelist_claim_assert_matches_available',
      lua.eval("(function() local R=RES.new(1,WL) local T='tgt0123456789abcdefghijk' "
               "for i=1,4 do R:claim('o'..i,T,'bc242702fb46b7e7') end "
               "local ok,err=pcall(function() R:claim('o5',T,'bc242702fb46b7e7') end) "
               "return ok end)()") == False,
      '★★ 第 5 颗必须被**断言拒绝**（名额断言是同一目标被两颗雷占的防线）')



def mark(i, at, ordv, resource='enemy', current=True, age=1.0, duration=8.0):
    ident = 'id-%017d-xxx' % i
    assert len(ident) == 24
    return lua.table_from({'id': i, 'identity': ident, 'resource': resource,
                           'marked_at': at, 'order': ordv, 'current': current,
                           'age': age, 'duration': duration})


def state():
    return {'mark_seen': lua.table_from({}), 'mark_age': lua.table_from({}),
            'mark_dur': lua.table_from({}), 'locked_ids': lua.table_from({}),
            'mark_dropped': lua.table_from({})}


def env_of(unit_live_only=True, structure_live_only=True):
    return lua.table_from({'unit_mark_live_only': unit_live_only,
                           'structure_mark_live_only': structure_live_only})


def claim_profile(resource):
    return resource == 'structure'


def engageable(resource):
    return resource in ('enemy', 'structure', 'friendly')


print('=== 源码形状：转写必须仍与 runtime 一致 ===')
for name, ok, detail in SHAPE:
    check(name, ok, detail)

print()
print('=== S1：3 个活标记 + 3 颗雷 ⇒ 稳定按时序 1:1 ===')
P, env = state(), env_of()
api = RES_M.new(1)
A, B, C = mark(101, 1000, 1), mark(102, 1005, 2), mark(103, 1010, 3)
queue = lua.table_from([C, B, A])          # ping_memory 按"最新在前"排
for f in (1, 2, 3):
    got = [SIM_M.pick(api, P, env, f, claim_profile, engageable, queue, 'g%d' % n, 1, 1)
           for n in (1, 2, 3)]
    check(f'S1_frame{f}_one_each', got == [101, 102, 103], f'got {got}')

print()
print('=== S2：多标记 + multi 上限 1 ⇒ 每个目标严格一颗，多余的拒绝 ===')
P, env = state(), env_of()
api = RES_M.new(1)
d1, d2 = mark(201, 1000, 1), mark(202, 1005, 2)
queue = lua.table_from([d2, d1])
got = [SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g%d' % n, 1, 1)
       for n in (1, 2, 3, 4)]
check('S2_multi_cap1_one_each_then_refuse', got == [201, 202, None, None], f'got {got}')

print()
print('=== S3：多标记 + multi 上限 2 ⇒ **先填最早的那个**，填满再到下一个 ===')
P, env = state(), env_of()
api = RES_M.new(1)
e1, e2 = mark(301, 1000, 1), mark(302, 1005, 2)
queue = lua.table_from([e2, e1])
got = [SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g%d' % n, 1, 2)
       for n in (1, 2, 3, 4)]
check('S3_multi_cap2_fills_earliest_first', got == [301, 301, 302, 302], f'got {got}')

print()
print('=== S4：单标记 + 上限 2 ⇒ 两颗雷追它，第三颗被拒 ===')
P, env = state(), env_of()
api = RES_M.new(1)
f1 = mark(401, 1000, 1)
queue = lua.table_from([f1])
got = [SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g%d' % n, 2, 1)
       for n in (1, 2, 3)]
check('S4_single_cap2_two_then_refuse', got == [401, 401, None], f'got {got}')

print()
print('=== S5：单标记 + 上限 1 ⇒ 只一颗（既有行为） ===')
P, env = state(), env_of()
api = RES_M.new(1)
g1 = mark(501, 1000, 1)
queue = lua.table_from([g1])
got = [SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g%d' % n, 1, 1)
       for n in (1, 2)]
check('S5_single_cap1_refuses_second', got == [501, None], f'got {got}')

print()
print('=== S6：已取消的标记**永不**被选中（新分配不继承在飞锁） ===')
P, env = state(), env_of()
api = RES_M.new(1)
x1, x2 = mark(601, 1000, 1, current=False), mark(602, 1005, 2)
queue = lua.table_from([x2, x1])
P['locked_ids'][x1.id] = True          # 就算有在飞的雷锁着它，新分配也不该拿
got = [SIM_M.pick(api, P, env, 2, claim_profile, engageable, queue, 'g%d' % n, 1, 1)
       for n in (1, 2)]
check('S6_cancelled_never_assigned', got == [602, None], f'got {got} (want 602,None)')

print()
print('=== S7：不可交战的标记（友方）永不被选中，且不占名额 ===')
P, env = state(), env_of()
api = RES_M.new(1)
y1 = mark(701, 1000, 1, resource='friendly')
def eng_without_friendly(r):
    return r in ('enemy', 'structure')
queue = lua.table_from([y1])
got = SIM_M.pick(api, P, env, 1, claim_profile, eng_without_friendly, queue, 'g1', 2, 2)
check('S7_unengageable_never_picked', got is None, f'got {got}')

print()
print('=== S8：一颗雷会不会**囤积预约**（跨帧占住两个标记）？ ===')
P, env = state(), env_of()
api = RES_M.new(1)
h1 = mark(801, 1000, 1)
h2 = mark(802, 1005, 2)
queue = lua.table_from([h2, h1])
first = SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g1', 1, 2)
loads1 = [api.load(api, h1.identity), api.load(api, h2.identity)]
# h1 暂时不可用（引擎本帧不认它）⇒ 同一颗雷去挑另一个
h1.current = False
second = SIM_M.pick(api, P, env, 2, claim_profile, engageable, queue, 'g1', 1, 2)
loads2 = [api.load(api, h1.identity), api.load(api, h2.identity)]
# h1 又可用 ⇒ 第二颗雷应该能拿到它
h1.current = True
g2 = SIM_M.pick(api, P, env, 3, claim_profile, engageable, queue, 'g2', 1, 2)
loads3 = [api.load(api, h1.identity), api.load(api, h2.identity)]
print(f'    g1 f1 -> {first}  loads={loads1}')
print(f'    g1 f2 -> {second}  loads={loads2}')
print(f'    g2 f3 -> {g2}  loads={loads3}')
check('S8_no_hoarding_of_reservations',
      loads2[0] == 0 and g2 is not None,
      f'g1 留着陈旧预约：loads={loads2}，g2 拿不到 h1（got {g2}）')

print()
print('=== S9：缺席宽限 —— 短暂没看到不释放名额，真离场才回收 ===')
api = RES_M.new(1)
k1 = mark(901, 1000, 1)
queue = lua.table_from([k1])
SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g1', 1, 1)
empty = lua.table_from([])
api.reconcile(api, empty, 3)
kept = api.load(api, k1.identity)
for _ in range(3):
    api.reconcile(api, empty, 3)
reclaimed = api.load(api, k1.identity)
check('S9_reconcile_grace_then_reclaim', kept == 1 and reclaimed == 0,
      f'缺席 1 次后={kept}（要 1），缺席 3 次后={reclaimed}（要 0）')

print()
print('=== S10：退役的雷释放名额，下一颗能接手 ===')
api = RES_M.new(1)
m1 = mark(1001, 1000, 1)
queue = lua.table_from([m1])
first = SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g1', 1, 1)
before = SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g2', 1, 1)
api.release_owner(api, 'g1')
after = SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g2', 1, 1)
check('S10_release_frees_the_slot',
      first == 1001 and before is None and after == 1001,
      f'got {first},{before},{after}')

print()
print('=== S11：cap 夹取 ≥1（0/负数不能让"可预约"恒假） ===')
api = RES_M.new(0)
n1 = mark(1101, 1000, 1)
queue = lua.table_from([n1])
check('S11_cap_clamped_to_one',
      api.available(api, 'gz', n1.identity) is True,
      'cap=0 被夹取成 1 后仍然可预约（否则谁都锁不上）')
got = SIM_M.pick(api, P, env, 1, claim_profile, engageable, queue, 'g1', 0, 0)
check('S11_zero_setting_still_assigns_one', got == 1101, f'got {got}')

print()
print('=== S12：菜单滑块与 env 接线必须在（改了菜单要能生效） ===')
# ★★ 2026-10-18（用户要求）：**多标记每目标手雷数的自定义已去除**，默认固定 1 ★★
check('S12_multi_mark_slider_removed',
      "id='g60.multi_mark_grenades_per_target'" not in ENTRY,
      '★ 多标记手雷数滑块已按用户要求移除（默认固定 1）')
for key in ('max_grenades_per_target',):
    check(f'S12_menu_slider_{key}', f"id='g60.{key}'" in ENTRY,
          '菜单里没有这个滑块 ⇒ 用户改不了')
    check(f'S12_menu_writes_env_{key}', f'host.env.{key}=v' in ENTRY,
          '滑块只注册不写回 host.env ⇒ 菜单能动、运行期不变')
    check(f'S12_env_wired_{key}', f'{key}=state.{key}' in ENTRY,
          'state 没有接进 env 字面量 ⇒ 运行期读不到')

print()
if failures:
    print(f'RESULT: {checks - len(failures)} passed; {len(failures)} failed')
    for f in failures:
        print(f'  failed: {f}')
    raise SystemExit(1)
print(f'RESULT: ALL PASS ({checks} checks)')
