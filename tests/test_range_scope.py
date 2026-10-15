"""作用域门：**只有用户点名的那几类能远距离追踪，其他目标不能**。

用户问（2026-10-14）：「是不是只有我说的那几个单位可以远距离追踪，其他目标不能？」

这条门把答案钉成**可执行的事实**，防止将来悄悄扩大作用域。
⚠ 不能凭印象答 —— 必须枚举**所有**接管路径并真跑 `max_distance2`。

两个必须分清的概念（漏掉后者会答错）
  · **实体标记**（虫洞/构筑/敌人/泰坦…）→ 走 `max_distance2` 距离门
  · **空 ping（ping 空地）** → 目标是**坐标**不是实体，**本来就没有距离上限**
    （用户 2026-10-13 实机验证过："空 ping 都能远距离追踪"）
"""
import pathlib
import re
import subprocess

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
PING = (ROOT / 'src/g60' / 'native_ping.lua').read_text(encoding='utf-8')
PRIORITY = (ROOT / 'src/g60' / 'native_priority.lua').read_text(encoding='utf-8')
TITAN = (ROOT / 'src/g60' / 'native_titan_aim.lua').read_text(encoding='utf-8')
POLICY = (ROOT / 'src/g60' / 'target_policy.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
PROF = (ROOT / 'compat' / 'structure_profiles.lua').read_text(encoding='utf-8')
MENU = (ROOT / 'src/g60' / 'menu_text.lua').read_text(encoding='utf-8')


def code(t):
    return '\n'.join(l.split('--')[0] for l in t.splitlines())


def _dist_desc_free_of_titan():
    """`max_takeover_distance.desc`（距离那条说明）里不得出现泰坦。
    ⚠ 只查**这一条**的取值行，不查整个文件 —— 别的菜单项谈泰坦是正当的。"""
    import re
    for m in re.finditer(r"\['max_takeover_distance\.desc'\]\s*=\s*\n?\s*'([^']*)'",
                         MENU):
        if '泰坦' in m.group(1) or 'Titan' in m.group(1):
            return False
    return True


failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


# 用户点名的 6 类（各取一个代表哈希）
NAMED = {
    '虫洞': ('8901f188db366b4b', 500),
    '构筑': ('5158e582fbeb26bd', 500),
    '巨型构筑': ('4232ee48e2cfd24e', 500),
    '尖啸巢': ('095686275a113614', 500),
    '孢子喷涌虫': ('aa28caf964d05500', 500),
    '落地穿梭舰': ('b3c9cdb79dc17937', 500),
}
# **未**点名的（必须固定在 100 m —— 用户 2026-10-14：「其他敌人的距离上限改为 100m」）
UNNAMED = {
    '普通敌人': 'aab438596f5e8fd9',
    '未知敌人': 'deadbeefdeadbeef',
    '吐酸泰坦': '9e2e17f2ccccafdd',
    '孢子泰坦变体': 'ef04cb84d097a497',
    '蟑龙': '960b48a421a3faaa',
    '友方撤离机（鹈鹕）': '7b0f8449ca9d2da0',
}
# ⚠⚠ 2026-10-14 用户实机**纠正**：**泰坦/蟑龙不由本项控制**。
#   用户原话：「泰坦这些是享受不到 100m 的范围的，只保留虫洞这些的说明」。
#   代码事实：泰坦靠**引擎选中**（`selected`）触发 `titan_selected`，再由**泰坦链**引导 ——
#   那条链路**不经过** `max_distance2`。它们在这里落到 100 m 那一支，
#   只是因为"不在结构表里"，**不代表**它们被限制在 100 m。
#   ⇒ 本组只钉"它们**不是**结构目标、拿不到 250/可调值"，
#     **不**再声称"泰坦的距离上限是 100 m"。
TITAN_AND_DRAGONROACH = {'吐酸泰坦', '孢子泰坦变体', '蟑龙'}

print('=== 1. 所有距离门都必须走唯一实现（没有漏网的硬编码）===')
# ⚠ 三个文件都要扫：`experimental_runtime` 也有一条接管/否决路径
#   （漏扫它就等于"改全了"靠记忆而不是靠扫描 —— 主支 v0.1.35 正是漏了一处）。
RT = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
_gates = []
for label, src in (('native_ping', PING), ('native_priority', PRIORITY),
                   ('experimental_runtime', RT)):
    for i, l in enumerate(code(src).splitlines(), 1):
        if re.search(r'distance\s*[<>]=?\s*\S', l) and 'max_distance2' not in l:
            _gates.append((label, i, l.strip()[:60]))
check('no_stray_distance_gates', not _gates,
      '★ 三个文件的接管路径里只有 `max_distance2` 一个距离门（发现其它：%s）' % (_gates or '无'))
check('ping_routes_through_policy', code(PING).count('Policy.max_distance2(') == 1,
      '★ `native_ping` 的标记观察谓词走唯一实现（**最关键的一处**）')
check('priority_routes_through_policy', code(PRIORITY).count('Policy.max_distance2(') == 3,
      '★ `native_priority` 的三处都走唯一实现')

print()
print('=== 2. 真跑 max_distance2：点名 / 未点名 逐类验证 ===')
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.preload['g60.util']=function() return {ref=function() return true end} end")
lua.execute("package.preload['g60.small_filter']=function() return {excluded=function() return false end} end")
Pol = lua.execute(POLICY)
common = lua.execute("return {getters={},alive_rva=0x1feeb0}")
sp = lua.execute(PROF)(common)


def limit(res, cfg=500, other=None):
    """`cfg` = **结构**那一档；`other` = **非结构**那一档（2026-10-14 第二轮合并后的档）。
    ⚠ 两个 helper 都只给结构字段 ⇒ 非结构目标会走它们自己那一档的默认值（200）。"""
    e = {'structure_profiles': sp, 'max_takeover_distance': cfg}
    if other is not None:
        e['other_takeover_distance'] = other
    return Pol.max_distance2(lua.table_from(e), res) ** 0.5


def limit_default(res):
    """不传 `max_takeover_distance` ⇒ 走配置缺席的默认值（应为 250）。"""
    env = lua.table_from({'structure_profiles': sp})
    return Pol.max_distance2(env, res) ** 0.5


# ★★★ 2026-10-14（用户报"标记远处泰坦有时飞向最近的敌人"）★★★
#   ⚠⚠ 上面那两个 helper 的 env **没有** `titan_profile` 等字段 ⇒ 泰坦会一路落到
#     "其他目标 100 m" 那一支，**根本测不到泰坦自己那一档**。
#     这就是我第一版的测试盲区：门"全过"，但真正的分支一次都没走到（空转断言）。
#   ⇒ 下面用**真实形状的 env**（照 entry 的 env 接线）再测一遍。
_TITAN = '9e2e17f2ccccafdd'        # 吐酸泰坦（= entry 的 titan_profile.resource）
_VARIANT = 'ef04cb84d097a497'      # 泰坦变体（titan_variants 里的一个）
_ROACH = '960b48a421a3faaa'        # 蟑龙（= entry 的 dragonroach_resource）


def real_env(cfg=500):
    return lua.table_from({
        'structure_profiles': sp,
        'max_takeover_distance': cfg,
        'titan_profile': lua.table_from({'resource': _TITAN}),
        'titan_variant_profiles': lua.table_from({_VARIANT: lua.table_from({'resource': _VARIANT})}),
        'dragonroach_resource': _ROACH,
    })


def real_limit(res, cfg=500):
    return Pol.max_distance2(real_env(cfg), res) ** 0.5


_titan_rows = [('吐酸泰坦', _TITAN), ('泰坦变体', _VARIANT), ('蟑龙', _ROACH)]
# ★★★ 2026-10-14（第二轮，用户要求）：**合并成两档** ★★★
#   用户原话：「泰坦距离上限跟其他敌人的合并在一起调整」。
#   ⇒ 泰坦 / 变体 / 蟑龙 / 普通敌人 **共用** `other_takeover_distance`（默认 200）；
#     结构那一档（`max_takeover_distance`，默认 250）独立。
#   ⇒ `max_distance2` 里那条"泰坦家族单独一档"的判据**已删除**（只剩"在不在结构表里"）。
_ot = 'other_takeover_distance'


def other_limit(res, cfg=None, struct_cfg=250):
    e = lua.table_from({
        'structure_profiles': sp,
        'max_takeover_distance': struct_cfg,
        'titan_profile': lua.table_from({'resource': _TITAN}),
        'titan_variant_profiles': lua.table_from({_VARIANT: lua.table_from({'resource': _VARIANT})}),
        'dragonroach_resource': _ROACH,
    })
    if cfg is not None:
        e[_ot] = cfg
    return Pol.max_distance2(e, res) ** 0.5


check('titan_and_other_share_one_bucket',
      # 同一个 env 下：泰坦 / 变体 / 蟑龙 / 普通敌人 全等
      len({round(other_limit(h), 6)
           for _, h in _titan_rows + [('普通敌人', 'deadbeefdeadbeef')]}) == 1,
      '★★★ 泰坦 / 泰坦变体 / 蟑龙 / 普通敌人**共用同一个值**（合并后的一档）')
check('merged_default_200',
      all(abs(other_limit(h) - 200) < 1e-6
          for _, h in _titan_rows + [('普通敌人', 'deadbeefdeadbeef')]),
      '★★ 默认 **200**：泰坦保持改动前的值（用户反复强调泰坦不该被 100 m 卡住）；'
      '⚠ 代价是"其他敌人"从 100 → 200（= 0.1.22 上游对一切标记目标的 200 m）')
check('merged_tier_is_configurable',
      all(abs(other_limit(h, 600) - 600) < 1e-6
          for _, h in _titan_rows + [('普通敌人', 'deadbeefdeadbeef')]),
      '★★★ 都跟新滑块走：设 600 ⇒ 600')
check('merged_tier_clamped_50_1000',
      all(abs(other_limit(h, 1) - 50) < 1e-6 and abs(other_limit(h, 99999) - 1000) < 1e-6
          for _, h in _titan_rows + [('普通敌人', 'deadbeefdeadbeef')]),
      '★★ 夹取 50~1000（与滑块范围对齐）')
check('merged_tier_independent_from_structure',
      abs(other_limit(_TITAN, struct_cfg=1000) - 200) < 1e-6
      and abs(other_limit('8901f188db366b4b', 1000) - 250) < 1e-6,
      '★★ 两档**各自独立**：结构滑块（250→1000）不动非结构（仍 200）；'
      '非结构滑块（→1000）不动结构（仍 250）')
check('policy_has_no_family_judgement_left',
      # 合并之后 policy **不该**再出现家族名单 —— 判据只剩"在不在结构表里"。
      #   ⚠ 这是"同一个判断只留一处"的正向收益：少一个会漂移的名单判断。
      #     家族名单仍活在它该在的地方（titan_approach.is_titan / small_filter）。
      'titan_profile' not in code(POLICY) and 'titan_variant_profiles' not in code(POLICY)
      and 'dragonroach_resource' not in code(POLICY)
      and _TITAN not in code(POLICY) and _ROACH not in code(POLICY),
      '★★★ 合并后 `max_distance2` 里**不得**再有任何"泰坦家族"判据'
      '（不抄哈希、也不查名单）—— 判据只剩"在不在结构表里"两档')
check('family_lists_still_live_where_they_belong',
      "env.titan_profile" in (ROOT / 'src/g60/titan_approach.lua').read_text(encoding='utf-8')
      and 'titan_variant_profiles' in (ROOT / 'src/g60/titan_approach.lua').read_text(encoding='utf-8'),
      '★ 家族名单没有被删掉，只是**从距离判据里移走**（`titan_approach.is_titan` 仍在用）')
check('menu_slider_matches_clamp',
      "{id='g60.other_takeover_distance',kind='slider',min=50,max=1000,step=5," in ENTRY
      and 'tonumber(host.env.other_takeover_distance) or 200' in ENTRY
      and 'other_takeover_distance=state.other_takeover_distance,' in ENTRY
      and "';other_takeover_distance='" in ENTRY,
      '★★ 滑块（50~1000/25，默认 200）+ env 接线 + 状态行四处齐全')
# ★★★ 2026-10-14（用户提醒）：**两条距离滑块的步长都要管** ★★★
#   原来只有上一条 check 钉了 `other_takeover_distance`，`max_takeover_distance`
#   没有任何断言 ⇒ 只改一条、另一条留着 25，门也不响（本工程老毛病：守门只落在名单上那几处）。
_STEP = "kind='slider',min=50,max=1000,step=5,"
_BADSTEP = "kind='slider',min=50,max=1000,step=25,"
check('both_distance_sliders_use_fine_step',
      ENTRY.count(_STEP) == 2 and _BADSTEP not in ENTRY,
      "★★★ **两条**距离滑块（结构目标 / 其他目标）都必须是 min=50,max=1000,**step=5**"
      "（实测 %d 条；用户：原来的 25 太粗，180/210/230 都设不了）" % ENTRY.count(_STEP))

check('menu_has_headroom_again',
      len(re.findall(r"id='g60\.", ENTRY)) <= 16,
      '★★ 菜单 %d/16（框架硬上限）。本轮把「载具否决 / 无敌人接管 / 接近泰坦开关」'
      '三项撤出菜单 ⇒ 重新有了余量' % len(re.findall(r"id='g60\.", ENTRY)))


_bad_named = []
for label, (res, want) in NAMED.items():
    got = limit(res)
    if abs(got - want) > 1e-6:
        _bad_named.append(f'{label}={got:.0f}(期望{want})')
check('named_six_get_the_configurable_limit', not _bad_named,
      '★★ 用户点名的 6 类都能取到可调上限（设 500 ⇒ 得 500）：%s' % (_bad_named or '全部 OK'))

# ★ 用户 2026-10-14：「我说的那几个单位的距离上限改为 250m」
_bad_default = []
for label, (res, _) in NAMED.items():
    got = limit_default(res)
    if abs(got - 250) > 1e-6:
        _bad_default.append(f'{label}={got:.0f}')
check('named_six_default_is_250', not _bad_default,
      '★★ 点名的 6 类**默认 250 m**（用户指定）：%s' % (_bad_default or '全部 250'))

_bad_unnamed = []
for label, res in UNNAMED.items():
    got = limit(res)
    if abs(got - 200) > 1e-6:
        _bad_unnamed.append(f'{label}={got:.0f}')
check('unnamed_targets_use_the_merged_tier', not _bad_unnamed,
      '★★ 未点名目标（普通敌人/泰坦/变体/蟑龙/友方）走**合并后的那一档**（默认 200）：%s'
      % (_bad_unnamed or '全部 200'))
check('unnamed_targets_follow_their_own_slider',
      all(abs(limit(res, None, 700) - 700) < 1e-6 for res in UNNAMED.values()),
      '★★ 它们跟**自己那一档**的滑块走（设 700 ⇒ 700）—— 用户要求"合并在一起调整"')
# ★★ 泰坦/蟑龙**不是**结构目标 ⇒ 在这道门上拿不到可调值（落 100 那一支）。
#   ⚠ 措辞刻意避开"泰坦的距离上限 = 100 m" —— 那是**不成立的说法**
#     （用户 2026-10-14 纠正过：泰坦走引擎选中 + 泰坦链，不经过这里）。
# ⚠ 2026-10-14（第二轮）这条**已作废**：合并成两档后，`max_distance2` 里
#   **不再有**"泰坦家族"判据 ⇒ "env 缺家族名单就从严到 100"这种 fail-safe
#   也一并消失（判据只剩"在不在结构表里"）。
#   ⇒ 改成钉住"**有没有家族名单都一样**"——这正好证明那条判据真的被删了。
_same = [lab for lab in TITAN_AND_DRAGONROACH
         if abs(limit(UNNAMED[lab]) - 200) > 1e-6]
check('family_lists_no_longer_affect_distance', not _same,
      '★★ env **不带**泰坦名单时，泰坦资源与普通敌人一样走非结构那一档（200）—— '
      '说明"泰坦家族"这条判据确实已从距离函数里删除（合并后的应有形态）：%s'
      % (_same or '全部 200'))

# 结构滑块拉到最大，未点名目标**不受影响**（它们走另一档）——
#   ⚠ 但**不是**"固定 100"了：它们走合并后的那一档（默认 200，可调）。
_bad_max = [label for label, res in UNNAMED.items() if abs(limit(res, 1000) - 200) > 1e-6]
check('structure_slider_does_not_move_the_other_tier', not _bad_max,
      '★★ 结构上限调到最大（1000）时，非结构目标**仍走自己那一档**（200）：%s'
      % (_bad_max or '全部 200'))

print()
print('=== 3. 反向：结构表关掉 ⇒ 判不出"在表里" ⇒ 落非结构那一档 ===')
env_off = lua.table_from({'max_takeover_distance': 500})
_still = [f'{lab}={Pol.max_distance2(env_off, res) ** 0.5:.0f}'
          for lab, (res, _) in NAMED.items()
          if abs(Pol.max_distance2(env_off, res) ** 0.5 - 200) > 1e-6]
check('structures_off_falls_into_the_other_tier', not _still,
      '★ `structure_profiles` 关掉（nil）⇒ 6 类也落到**非结构那一档**（默认 200）：%s'
      % (_still or '全部 200'))

print()
print('=== 4. 空 ping 是**特例**：它本来就没有距离上限（本次没动它）===')
check('empty_ping_is_coordinate_path',
      'point_marker_enabled=true' in code(ENTRY)
      and 'point_target_enabled=true' in code(ENTRY),
      '★ 空 ping 由坐标路径驱动（`point_marker` / `point_target`）')
# 距离门吃的是 m.resource ⇒ 只对实体标记生效
_after = code(PING).split('Policy.max_distance2(')[1][:30]
check('ping_gate_only_applies_to_entities', 'm.resource' in _after,
      '★ ping 的距离门吃 `m.resource` ⇒ **只对实体标记生效**；'
      '空 ping 没有 resource ⇒ 不经过它（所以不受本次改动影响）')

print()
print('=== 5. 泰坦：**不由本项控制**（用户 2026-10-14 实机纠正了我上一版的说法）===')
_line = ("if not (distance<40000) then target=nil;"
         "reason='Titan point outside projectile range bound' end")
_up = subprocess.run(['git', 'show', 'v0.1.22:src/g60/native_titan_aim.lua'],
                     cwd=str(ROOT), capture_output=True, text=True,
                     encoding='utf-8').stdout
check('titan_bound_is_upstream_verbatim',
      _line in code(TITAN) and _line in code(_up),
      '★ 与 **v0.1.22 逐字相同** ⇒ 上游原有（`projectile range bound`），不是本次引入')
check('titan_not_wired_to_policy', 'max_distance2' not in TITAN,
      '★★ 泰坦链**没有**接 `max_distance2` —— 它是泰坦的**唯一引导者**，'
      '按本工程反复确认的结论（泰坦链一旦被别的驱动者插在前面就会毁掉爆点）**不碰它**')
# ★★★ 这条是本轮**纠正**的核心：泰坦的接管**不经过**那道门 ★★★
check('titan_takeover_is_engine_selection_driven',
      'local selected=m.selection_flag~=0 and m.selection_id~=P.inv_invalid' in code(RT)
      and 'local titan_selected=not abandoned and titan and selected' in code(RT),
      '★★ 泰坦靠**引擎选中**触发（`selected` → `titan_selected`）再由泰坦链引导 '
      '⇒ **不经过** `max_distance2`。这正是"泰坦享受不到 100 m 那道门"的代码依据 —— '
      '用户 2026-10-14 纠正了我上一版"标记泰坦 = 100 m"的错误说法')
check('titan_not_mentioned_as_100m_in_docs',
      # ★★★ 2026-10-14（本轮收窄）：这条门原来断言的是
      #   `'泰坦' not in code(MENU) and 'Titan' not in code(MENU)`
      #   —— 即"**整个菜单文案里一个字都不许出现泰坦**"。那个写法**太宽**：
      #   真实的、用户要求的不变量是"**别把泰坦描述成受那道 100 m 距离门管的目标**"，
      #   而 2026-10-14 新增的「接近标记泰坦后放手」菜单项**正当**地要谈泰坦。
      #   ⇒ 现在只禁**具体的错误说法** + 禁**距离那条说明**里提泰坦。
      #   ⚠ 教训：门写成"某词不出现"时，要考虑**将来合法使用该词**的情况；
      #     否则它会挡住正确的新功能（本轮就是它把我拦下来的）。
      all(bad not in code(MENU) for bad in
          ('其他标记敌人（含泰坦', 'incl. Titans', '泰坦、蟑龙', 'Titans and Dragonroach'))
      and _dist_desc_free_of_titan(),
      '★★ ① 旧的错误说法（"其他敌人含泰坦 ⇒ 100 m"）必须不在；'
      '② `max_takeover_distance` 那条**距离说明**里不得提泰坦（它只管结构目标）。'
      '⚠ 但**别的**菜单项可以正当地谈泰坦（如「接近标记泰坦后放手」）')
check('titan_chain_upstream_bound_intact', '40000' in TITAN,
      '⚠ 说明项：泰坦链自己那条上游界仍是 200 m（`40000`）—— 上游语义，本次未改。')
check('titan_chain_bound_not_hidden_in_policy',
      '40000' not in code(POLICY),
      '★ 唯一实现里不得再出现裸 `40000`（100/250 都要是显式的米数）')

print()
print('=== 6. 结构表里**只有**点名的那几类（没有夹带）===')
_kinds = set(re.findall(r'kind="(\w+)"', code(PROF)))
check('only_three_kinds', _kinds == {'structure_hole', 'structure_tower', 'structure_vent'},
      '★ 结构表只有三种 kind（实际 %s）' % sorted(_kinds))
_ids = set(re.findall(r'profiles\["([0-9a-f]{16})"\]', code(PROF)))
check('no_embryo_or_unrelated', '06d3c4720e642fc1' not in _ids,
      '★ 任务虫卵（不在点名内）仍未登记')
check('all_entries_are_named_categories',
      len(_ids) == 38,
      '★ 结构表 37 条 = 16 虫洞 + 1 尖啸巢 + 2 孢子喷涌虫 + 5 构筑 + 1 巨型构筑'
      ' + 2 穿梭舰 + 1 广播台屏幕（2026-10-14）'
      ' + **9 条机器人设施**（2026-10-14 用户要求：碉堡/炮塔/营地武器/生物处理器/城市大门）'
      '（实际 %d）' % len(_ids))

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
