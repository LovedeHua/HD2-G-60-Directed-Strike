"""离线仿真：安全区判定（**以引爆点为中心** + 双半径 + fail-safe）。

为什么需要它
------------
用户 2026-10-14 的要求：「安全区机制也改成跟主支类似的获取到玩家的坐标不在安全区内
才能引爆，而不是现在的机制，然后安全区是以**引爆点**为中心，而不是手雷为中心」。

这套判据全是**几何 + 顺序**，读代码最容易看错的就是"哪一条先判"和"以谁为圆心"。
本套件在 LuaJIT 上忠实转写 `blast_safe_hold_at` 的判定部分，逐条验证：

  * 主判据 = 玩家离**引爆点**的距离（不是手雷）
  * 手雷半径是**可选**的第二条（默认关）
  * 顺序 = **先手雷、后目标**（本工程既定口径）
  * fail-safe = "**一个玩家坐标都读不到**"才不引爆（不是"读不到自己"）
  * fail-open 开关关掉 fail-safe 后照常引爆

怎么保证它没说谎
  转写与真实源码**逐字对齐**：先断言关键源码片段仍在（形状门），
  源码改了形状而本文件没改 ⇒ 测试失败，而不是安静地仿真一个旧设计。
"""
import pathlib

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = (ROOT / 'src' / 'g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
MENU = (ROOT / 'src' / 'g60' / 'menu_text.lua').read_text(encoding='utf-8')

_CODE = '\n'.join(l.split('--')[0] for l in RUNTIME.splitlines())
# 空白归一化：源码里的换行/缩进会随格式化变动，判据不该因此假红。
_NORM = ' '.join(_CODE.split())
# 门那一句的**期望形状**（空白归一化后）。
_GATE = 'held=not blast_safe_hold(m,scope,blast_point or P.tpos[m.id])'

SHAPE = [
    ('two_radii_read',
     'local safe_target=tonumber(env.safe_zone_target_radius) or 0' in _CODE
     and 'local safe_grenade=tonumber(env.blast_safe_radius) or 0' in _CODE,
     '两个半径不再由 env 提供'),
    ('gate_takes_a_target_point',
     'local function blast_safe_hold_at(ident,own,tgt)' in _CODE,
     '门派生的签名里没有引爆点 ⇒ 又回到以手雷为中心'),
    ('grenade_checked_first',
     "about,dist='grenade',gd2" in _CODE,
     '手雷那一条不再先判（顺序与上游不一致）'),
    ('target_is_the_main_check',
     "about,dist='target',td2" in _CODE
     and 'if not about and safe_target>0 and td2' in _CODE,
     '引爆点那一条不再是主判据'),
    ('failsafe_is_both_distances_nil',
     'if gd2==nil and td2==nil then' in _CODE,
     'fail-safe 判据不是"两个距离都为 nil"'),
    ('call_site_passes_blast_point',
     # ★★★ 2026-10-14 修复（用户报「空 ping 功能貌似出问题了」）★★★
     #   ⚠⚠ **门**只许拿 `blast_point` / `P.tpos` —— **不许**拿 ping 点 `point`：
     #   ping 空地时玩家就站在落点附近 ⇒ 把 ping 点当引爆点 ⇒ 玩家恒在半径内 ⇒
     #   门恒判"圈内" ⇒ 绕行块覆盖 ping 点 ⇒ 手雷绕圈、**永不落点**。
     #   ⚠ 断言必须**只看门那一句**：`or (point and {…})` 在**绕行圆心**的选取里
     #     是**合法**的（`local c=blast_point or (point and …) or P.tpos`）——
     #     第一版用整份源码找子串，被那一句误判成 FAIL。
     _GATE in _NORM
     and 'held=not blast_safe_hold(m,scope, blast_point or (point and' not in _NORM,
     '调用点没有把引爆点传进门（或误把 ping 点当成了引爆点 ⇒ 空 ping 回归）'),
    ('titan_passes_arrival_point',
     'blast_safe_hold(m,scope,tgt_pt)' in _CODE
     and 'old.titan.route.arrival_point or old.titan.route.point' in _CODE,
     '泰坦段没有把预期引爆点传进门'),
]

# ---------------------------------------------------------------- 转写（判定部分）
SIM = r"""
local M = {}

-- 忠实转写 blast_safe_hold_at 的**判定**部分。
-- dist2(player, point) 由调用方提供（代表 nearest_player 的结果）。
-- gd2 = 玩家↔手雷²；td2 = 玩家↔引爆点²（nil = 判不了）
function M.decide(env, gd2, td2)
    local safe_target = tonumber(env.safe_zone_target_radius) or 0
    local safe_grenade = tonumber(env.blast_safe_radius) or 0
    if safe_target <= 0 and safe_grenade <= 0 then return 'allow', 'off' end
    if gd2 == nil and td2 == nil then
        if env.safe_zone_failsafe ~= false then return 'hold', 'failsafe' end
        return 'allow', 'failopen'
    end
    local about = nil
    if safe_grenade > 0 and gd2 and gd2 <= safe_grenade * safe_grenade then
        about = 'grenade'
    end
    if not about and safe_target > 0 and td2 and td2 <= safe_target * safe_target then
        about = 'target'
    end
    if not about then return 'allow', 'clear' end
    return 'hold', about
end
return M
"""

lua = lj.LuaRuntime(unpack_returned_tuples=True)
SIM_M = lua.execute(SIM)

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    if ok:
        print('  PASS ' + name)
    else:
        print('  FAIL ' + name + '  [' + detail + ']')
        failures.append(name)


def env_of(target=12, grenade=0, failsafe=True):
    return lua.table_from({'safe_zone_target_radius': target,
                           'blast_safe_radius': grenade,
                           'safe_zone_failsafe': failsafe})


def sq(d):
    return float(d) * float(d)


def decide(target=12, grenade=0, failsafe=True, gdist=None, tdist=None):
    """gdist/tdist 单位米；None = 读不到。"""
    e = env_of(target, grenade, failsafe)
    g = None if gdist is None else sq(gdist)
    t = None if tdist is None else sq(tdist)
    got = SIM_M.decide(e, g, t)
    return (got[0], got[1])


print('=== 源码形状：转写必须仍与 runtime 一致 ===')
for name, ok, detail in SHAPE:
    check(name, ok, detail)

print()
print('=== S1：主判据 = 玩家离**引爆点**多远（以引爆点为中心）===')
# 引信 12 m：爆点在 10 m 外 ⇒ 拦；在 15 m 外 ⇒ 放行
check('S1_target_inside_12_holds', decide(tdist=10.0) == ('hold', 'target'),
      '引爆点 10 m ⇒ 应拦（got %s）' % (decide(tdist=10.0),))
check('S1_target_outside_12_allows', decide(tdist=15.0) == ('allow', 'clear'),
      '引爆点 15 m ⇒ 应放行（got %s）' % (decide(tdist=15.0),))
check('S1_target_exactly_12_holds', decide(tdist=12.0) == ('hold', 'target'),
      '正好 12 m ⇒ 拦（<= 边界，与上游一致）')
check('S1_target_just_over_12_allows', decide(tdist=12.01) == ('allow', 'clear'),
      '12.01 m ⇒ 放行')

print()
print('=== S2：**这就是"以引爆点为中心而非手雷"的区别** ===')
# 手雷贴着玩家（3 m）但引爆点在 20 m 外 ⇒ **放行** —— 旧机制（只看手雷）会拦。
got = decide(target=12, grenade=0, gdist=3.0, tdist=20.0)
check('S2_grenade_near_but_blastpoint_far_allows', got == ('allow', 'clear'),
      '手雷 3 m / 爆点 20 m ⇒ 应**放行**（旧机制会拦）；got %s' % (got,))
# 反过来：手雷很远（25 m）但引爆点就在玩家脚边（5 m）⇒ **拦**
got = decide(target=12, grenade=0, gdist=25.0, tdist=5.0)
check('S2_grenade_far_but_blastpoint_near_holds', got == ('hold', 'target'),
      '手雷 25 m / 爆点 5 m ⇒ 应**拦**；got %s' % (got,))

print()
print('=== S3：手雷半径是**可选**的第二条（默认 0 = 关）===')
check('S3_grenade_radius_off_by_default_ignores_grenade',
      decide(grenade=0, gdist=1.0, tdist=30.0) == ('allow', 'clear'),
      '手雷半径 0 ⇒ 手雷再近也不拦（只看爆点）')
check('S3_grenade_radius_on_holds',
      decide(grenade=8, gdist=3.0, tdist=30.0) == ('hold', 'grenade'),
      '开到手雷半径 8 m、手雷 3 m ⇒ 拦（依据 = grenade）')

print()
print('=== S4：判定顺序 = **先手雷、后目标**（跟上游）===')
# 两条同时成立时必须报 grenade（上游顺序）
got = decide(target=12, grenade=8, gdist=3.0, tdist=3.0)
check('S4_grenade_wins_when_both_apply', got == ('hold', 'grenade'),
      '两条都成立 ⇒ 报 grenade（上游顺序）；got %s' % (got,))

print()
print('=== S5：fail-safe —— **一个玩家坐标都读不到**才不引爆 ===')
check('S5_no_player_reads_holds', decide(gdist=None, tdist=None) == ('hold', 'failsafe'),
      '两个距离都 nil ⇒ 不引爆（跟上游）')
check('S5_own_unreadable_but_teammate_usable_still_judges',
      decide(gdist=None, tdist=10.0) == ('hold', 'target'),
      '手雷坐标读不到、但爆点可判 ⇒ 仍然按爆点判（**不是**直接放行）——'
      ' 这正是旧代码的 bug：它只判"读不到自己"就 fail-open')
check('S5_blastpoint_unreadable_but_grenade_known_judges_grenade',
      decide(grenade=8, gdist=3.0, tdist=None) == ('hold', 'grenade'),
      '爆点判不了、手雷可判 ⇒ 按手雷半径判')
check('S5_failsafe_off_falls_back_to_fail_open',
      decide(failsafe=False, gdist=None, tdist=None) == ('allow', 'failopen'),
      'fail-safe 关掉 ⇒ 退回旧 fail-open（照常引爆）')

print()
print('=== S6：两个半径都为 0 ⇒ 整段关闭（零行为）===')
check('S6_both_zero_is_off', decide(target=0, grenade=0, tdist=1.0) == ('allow', 'off'),
      '两个半径都 0 ⇒ 直接放行（功能关闭）')
check('S6_only_target_on_still_works',
      decide(target=12, grenade=0, tdist=1.0) == ('hold', 'target'),
      '只开目标半径也照常生效')

print()
print('=== S7：接线（默认值 / env / 菜单 / 状态行）===')
check('S7_default_target_radius_is_12', 'safe_zone_target_radius=12,' in ENTRY,
      '主判据默认必须是 12（跟用户在主线拍板的值）')
# ★★ 2026-10-18：两个半径**合并成一条**（用户要求）。
check('S7_grenade_radius_is_a_mirror', 'blast_safe_radius=state.safe_zone_target_radius,' in ENTRY,
      '合并后 `blast_safe_radius` 必须是 `safe_zone_target_radius` 的**镜像**'
      '（运行时的手雷判据与 danger 距离读的是它；镜像断了 = 菜单半开）')
check('S7_failsafe_default_on', 'safe_zone_failsafe=true,' in ENTRY,
      'fail-safe 默认开（跟上游）')
check('S7_env_wires_target_radius',
      'safe_zone_target_radius=state.safe_zone_target_radius,' in ENTRY,
      'state 必须接进 env 字面量，否则运行期读不到')
check('S7_env_wires_failsafe', 'safe_zone_failsafe=state.safe_zone_failsafe,' in ENTRY,
      'fail-safe 也要接进 env')
check('S7_menu_slider_target_radius',
      "id='g60.safe_zone_target_radius'" in ENTRY
      and 'host.env.safe_zone_target_radius=v' in ENTRY,
      '主判据必须有菜单滑杆并写回 host.env')
# ★★★ 2026-10-18（合并半径）：**`set` 必须同时写两个 env 字段** ★★★
#   运行时的手雷判据与 danger 距离读的是 `blast_safe_radius`。
#   只写 `safe_zone_target_radius` ⇒ 菜单能动、运行期**半开**
#   （本项目踩过同类静默失败：只注册不写回）。
check('S7_menu_set_writes_both_fields',
      'host.env.safe_zone_target_radius=v' in ENTRY
      and 'host.env.blast_safe_radius=v' in ENTRY,
      '★★ 合并后菜单 set 必须**同时**写两个 env 字段 —— '
      '只写一个 = 菜单看着生效、实际半开')
check('S7_status_line_shows_both',
      "';safe_zone_target_radius='..tostring(state.safe_zone_target_radius)" in ENTRY
      and "';blast_safe_radius='..tostring(state.safe_zone_target_radius)..'(mirror)'" in ENTRY
      and "';safe_zone_failsafe='..tostring(state.safe_zone_failsafe)" in ENTRY,
      '状态行必须打出半径（及其**镜像**）与 fail-safe 方向（看不到就无法确认生效）')
check('S7_menu_text_covers_both_languages',
      "['safe_zone_target_radius.label']" in MENU
      and MENU.count("['safe_zone_target_radius.label']") == 2
      and "['safe_zone_target_radius.desc']" in MENU
      and MENU.count("['safe_zone_target_radius.desc']") == 2,
      '两套文案都必须有目标半径的 label+desc（缺一个就是漏翻译）')

print()
print('=== S8：绕行圆心解不出来时**绝不退回实体 aim**（2026-10-14 实机修复）===')
# 背景（实机证据，2026-10-15 那局）：
#   绕行圆心 `c = blast_point or point or P.tpos[id]`。对**实体**目标前两个恒 nil
#   ⇒ 圆心只能来自 `P.tpos`，而它每 30 帧刷新、**读失败就置 nil**。
#   圆心为 nil ⇒ `arr_opts` 为 nil ⇒ arrival 退回**实体 aim** ⇒
#   而绕行期间写的是点、priority 已跳过写回引擎选择 ⇒ 每帧撞
#   `arrival selected target mismatch` ⇒ 每帧记一次引导失败 ⇒ 30 帧 `guide_give_up`
#   **把这颗雷报废**（entity=954 到 28/30；整局 36 条 mismatch vs 4 次引爆）。
_sz = RUNTIME[RUNTIME.index('if held then'):RUNTIME.index('else\n                                -- 离开安全区')]
# ★★★ 2026-10-18（用户要求）：**悬停高度可自定义** ★★★
#   原来是硬编码 `c[3]+2.0`。现在走菜单 `blast_safe_lift`。
#   ⚠⚠ 默认必须是 **2** —— 否则就是一次**静默的行为变化**（用户没要求改默认）。
#   ⚠ 两个写点都必须用同一个 `LIFT`（否则记住的点与写出的点不一致）。
check('S9_lift_default_is_2', 'blast_safe_lift=2,' in ENTRY,
      '★ 默认 2 = 与改动前逐字一致（不得静默改默认）')
check('S9_lift_env_wired', 'blast_safe_lift=state.blast_safe_lift,' in ENTRY,
      'env 字面量必须接线（env_fields_all_wired 会查）')
check('S9_lift_menu_writes_env', "id='g60.blast_safe_lift'" in ENTRY
      and 'host.env.blast_safe_lift=v' in ENTRY,
      '菜单必须存在且 set 写回 host.env')
check('S9_lift_status_line', "';blast_safe_lift='..tostring(state.blast_safe_lift)" in ENTRY,
      '状态行必须报（看不到 = 无法确认生效）')
_src = (ROOT / "src" / "g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
_code = "\n".join(l.split("--")[0] for l in _src.splitlines())
check('S9_lift_read_from_env_with_clamp',
      _code.count("local LIFT=tonumber(env.blast_safe_lift) or 2.0") == 2
      and _code.count("if LIFT<0 then LIFT=0 elseif LIFT>20 then LIFT=20 end") == 2,
      '★ 两个写点都必须读 env 并**夹取**（防恶意/脏值）')
check('S9_no_hardcoded_lift_left', "c[3]+2.0" not in _code,
      '★ 不得再有硬编码的 `c[3]+2.0` 残留（会与 LIFT 不一致）')
check('S9_remembers_the_computed_point',
      'P.lastpt[m.id]={ox,oy,c[3]+LIFT}' in _sz,
      '★★ 算出绕行点后必须**记住**它（含 +LIFT 抬升的整点；'
      'LIFT 来自菜单 `blast_safe_lift`，默认 2 —— R=0 时就是悬停在目标上方）')
check('S8_reuse_branch_exists_and_precedes_nopos',
      # 顺序即语义：复用分支必须在"打 nopos 日志"那条之前，
      # 否则圆心解不出来的那些帧会直接落空 ⇒ 退实体 aim ⇒ mismatch 风暴。
      'elseif P.lastpt[m.id] then' in _sz
      and _sz.index('elseif P.lastpt[m.id] then') < _sz.index('elseif not P.dg_nopos[m.id] then'),
      '★★★ 圆心解不出来时先**复用上一次的绕行点**，再考虑只打 nopos 日志')
check('S8_reuse_injects_verbatim',
      'local lp=P.lastpt[m.id]' in _sz and 'point_target=lp,' in _sz
      and 'point_target={ox,oy' not in _sz[_sz.index('elseif P.lastpt[m.id] then'):],
      '★★ 复用必须**原样注入**存好的点 —— 若在复用分支里重算，`+1.0` 会每帧累加漂移')
check('S8_reuse_keeps_point_writable',
      _sz[_sz.index('elseif P.lastpt[m.id] then'):].strip().startswith('elseif')
      and 'mask_only=nil' in _sz[_sz.index('elseif P.lastpt[m.id] then'):],
      '★ 复用分支同样要 `mask_only=nil`（点必须允许写入，否则这一帧等于没写）')
check('S8_reuse_inherits_early',
      _sz[_sz.index('elseif P.lastpt[m.id] then'):].count(
          'early=(arr_opts and arr_opts.early) or nil') >= 1,
      '★ `early` 必须像主分支那样**继承**（arrival 内部失败时不许永久禁用）')
check('S8_reuse_is_visible_in_log',
      'src=reuse' in _sz,
      '★★ 复用也要**可见**（`blast_detour;…;src=reuse`）—— 复用被节流掉 = 诊断不存在')
check('S8_cache_cleared_on_exit',
      'P.tpos[m.id]=nil;P.dg[m.id]=nil;P.dg_nopos[m.id]=nil;P.lastpt[m.id]=nil' in RUNTIME,
      '★★ 离开安全区必须清掉（手雷 id 会被引擎复用，残留点会让下一颗雷张冠李戴）')
check('S8_cache_cleared_on_id_reuse',
      'P.tpos[id]=nil;P.dg[id]=nil;P.dg_nopos[id]=nil;P.lastpt[id]=nil' in RUNTIME,
      '★ 手雷 id 回收时也要清（与 tpos/dg 同处）')
check('S8_cache_cleared_on_target_change',
      "P.lastpt[m.id]=nil" in RUNTIME[RUNTIME.index("elseif result.kind=='lock' then"):
                                 RUNTIME.index("elseif result.kind=='lock' then") + 900],
      '★★ **换目标**时必须丢弃旧目标的点，否则会拿旧位置把雷引偏')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
