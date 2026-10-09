"""Bughole-only fork: verify the trim points, the preserved safety layer, and the artifact.

Why this exists
---------------
scripts/run_tests.py has to skip 13 `*_windows` suites (they need a compiled C fixture
DLL plus Windows Lua, neither of which exists on this machine). Two of those skipped
suites -- `priority_windows` and `experimental_windows` -- are exactly the ones that
cover the two files this fork modifies. So the trim itself would otherwise be untested.

This suite compensates at the level that *is* checkable offline:
  1. the structure profile table really contains only the nine bug holes,
  2. the trim really removed the enemy-priority / weakpoint decision points,
  3. the safety layer (signatures, native bindings, arrival/explode) is byte-identical
     to the upstream import -- compared against the git baseline commit,
  4. the built artifact carries the right resource identity and payload framing.

Run: python -B tests/test_bughole_scope.py
"""
import json
import pathlib
import re
import struct
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
# 上游原样导入的基线 commit（git log 第一条）。安全层必须与它逐字节一致。
UPSTREAM_COMMIT = '2879ef7'

# ★ 包名 / 资源名 / 显示名**全部从 `scripts/build.py` 派生**，不再硬编码：
#   版本号只允许有一个来源，否则发版时这里会留在旧名字上，测试直接"找不到文件"
#   而不是报版本不一致。
#   ⚠ 注意区分：`public_version` 是**上游基线**（被 build_json_pinned:* 钉死），
#     `release_version` 才是本裁剪版的发布版本。
#   ★ 2026-10-09：改名（G-60 Bug Hole Lock → **G-60 Directed Strike**）时顺手把
#     NAME / ZIP_NAME 也改成派生 —— 否则"改一处名字要同步改测试"迟早漏一处。
_BUILD_PY = (ROOT / 'scripts' / 'build.py').read_text(encoding='utf-8')
GUID = '9c1d4e77-2b83-4f6a-91e5-0d7b3a6c8f42'
UPSTREAM_GUID = '58a16a67-a72b-474a-ad05-adbaaa99da78'


def _def(pattern, default='<missing>'):
    found = re.findall(pattern, _BUILD_PY, re.M)
    return found[0] if found else default


_release_defs = re.findall(r"^RELEASE_VERSION\s*=\s*'([^']+)'", _BUILD_PY, re.M)
_RELEASE_VERSION = _release_defs[0] if _release_defs else '<missing>'
NAME = _def(r"^NAME\s*=\s*'([^']+)'")
# 归档内的源文件名跟随资源名的末段（build.py 就是这么生成的）
SOURCE_IN_ARCHIVE = 'Source/' + NAME.rsplit('/', 1)[-1] + '.lua'
# ⚠ 正则要**整串**捕获（含 `.zip` 后缀），只在事后把 `{VERSION}` 换掉 ——
#   第一版写成 `f'([^']+)\{VERSION\}'` 就漏了后缀，ZIP 路径少个 .zip ⇒ zip_exists 直接失败。
ZIP_NAME = _def(r"^ZIP_NAME\s*=\s*f'([^']+)'").replace('{VERSION}', _RELEASE_VERSION)
# ⚠ `[^']+` 是贪婪的，会把 `{VERSION}` 前的空格一起吃进来 ⇒ 必须 strip，
#   否则拼出来的显示名会多一个空格（本次栽过：两条断言同时失败）。
TITLE_PREFIX = _def(r"^TITLE\s*=\s*f'([^']+)\{VERSION\}'").strip()
ZIP = ROOT / 'dist' / ZIP_NAME

# 上游 13 条里的 9 条 structure_hole（顺序即上游文件顺序）
UPSTREAM_HOLE_IDS = (
    '8901f188db366b4b', '9b58c95349d051f9', '8c31b749759cbd61', '36cc8ead2bb18d78',
    'bc2af8548c6d5e06', 'f78bf0ff5c62140d', '97dd3178e9f0ab70', '4776a1cf3f19a13b',
    '3a2cef12ed32a088',
)
# 上游 13 条里**永久移除**的 4 条 —— 都不是虫洞(bug hole)：
#   · 2 个孢子菇 Spore Spewer（aa28caf9… / e02e6bd3…）
#   · 1 个任务虫卵 embryo_01（06d3c472…）
#   · ★ 尖啸者巢 Shrieker Nest（095686275a113614）—— 2026-09-29 按**用户要求**移除：
#       "对于有生命值的尖啸巢穴这一类的不要接管，直接使用游戏原生行为"。
#       两个独立来源确认它是**巢体**而不是虫洞：
#         游戏路径 content/env_bugs/assets/gameplay/bug_spawner_shrieker
#         社区表《绝地潜兵2资源ID》→"尖啸虫巢穴 | Shrieker Nest"
#       ⚠️ 历史：裁剪 J 曾因它"可标记"就把它当虫洞恢复 —— 把"可标记"错当"是虫洞"，
#          且上游本来把它归为 structure_tower。可标记 ≠ 是虫洞。
REMOVED_IDS = ('aa28caf964d05500', 'e02e6bd34b606a85', '06d3c4720e642fc1',
               '095686275a113614')

# 必须与上游逐字节一致的安全层（改动其中任何一个都要重新论证）
SAFETY_LAYER = (
    'compat/native_search_binding.lua',    # clear / orbit 原生绑定 + 函数签名守卫
    'compat/titan_profile.lua',            # engine_guards(exe 签名) + Titan 数据
    'compat/weakpoint_profiles.lua',
    'compat/fuse_profile.lua',
    'compat/priority_catalog.lua',
    'src/g60/native_minimal.lua',          # state-4 白名单 / 计时器保护 / 身份复验
    'src/g60/native_arrival.lua',          # calls.aim + calls.explode
    'src/g60/native_disposal.lua',
    'src/g60/native_search_context.lua',   # movement/speed/behavior manager 定位
    'src/g60/native_observer.lua',
    'src/g60/native_readiness.lua',
    'src/g60/native_target_data.lua',
    'src/g60/native_authority.lua',
    'src/g60/native_ping.lua',
    'src/g60/ping_memory.lua',
    'src/g60/titan_context.lua',
    'src/g60/titan_route.lua',
    'src/g60/structure_route.lua',
    'src/g60/util.lua',
    'src/g60/arrival_policy.lua',
    'src/g60/selection_veto.lua',
    'src/g60/target_allowlist.lua',
)

# ★ target_reservations 已不再是"逐字节等于上游"：2026-09-27 给它加了
#   release_owner(owner) —— 放弃一颗 G-60 时必须把它名下**所有**预约还回去，
#   否则那个虫洞对所有其他 owner 的 available() 恒为 false（"这洞再也接管不了"）。
#   上游的 claim/available/reconcile/reset 语义必须仍与上游逐字节一致，
#   所以这里比对"去掉 release_owner 之后的剩余部分"。
SAFETY_LAYER_EXCEPTIONS = {
    'src/g60/target_reservations.lua': ('release_owner',),
}

# ★ arrival_policy 也不再逐字节等于上游：`dz<=0`（必须在目标**下方**才算到达）
#   是给泰坦标定的，虫洞在地上 ⇒ G-60 绕飞时始终在洞口上方 ⇒ 永不引爆。
#   实机 5 个采样点原判定 0/5 可引爆，加 `above` 后 4/5。
#   不配 above 时 `above=0`，行为与上游完全一致（下游断言保证）。
#   ★ 2026-09-30：球形判定试过一版（`dx²+dy²+dz²<=r²`），实机效果很差 ⇒ **已回滚为圆柱**。
#   改动是行内的，无法正则剥离 ⇒ 用锚点比对。
ARRIVAL_ANCHORS = (
    "assert(type(region.radius)=='number' and region.radius>0 and region.radius<=3",
    "and type(region.depth)=='number' and region.depth>0 and region.depth<=2,'arrival region')",
    "arrived=dx*dx+dy*dy<=region.radius^2",
    "and dz>=-region.depth",
    "if terminal and arrived then return 'detonate',nil,dist end",
    "if now-p.at>=M.stalled_seconds then return 'search',nil,dist end",
    "region.kind=='entrance'",
)
ARRIVAL_FORBIDDEN = (
    "arrived=dx*dx+dy*dy<=region.radius^2 and dz<=0 and dz>=-region.depth",  # 上游那句
    "dx*dx+dy*dy+dz*dz<=region.radius^2",   # ★ 球形那句（2026-09-30 试过，实机效果差，已回滚）
)
ARRIVAL_REQUIRED = (
    "region.above or 0",
    "dz<=above",
)

# ★ native_ping 的改动是散落多处的（注释/变量/失败分支），无法用正则"剥离后比对"，
#   改用**锚点比对**：上游每一条安全断言必须原样保留（安全网没被削弱），
#   且上游那句有害的"失败即清空记忆"必须已经不在。
#   背景：上游 `if not ok then memory:reset() end` 把每一次瞬时读取失败当成"场景变了"
#   清空全部标记记忆 —— 实机 `local Ping creator unavailable` 几百帧连续失败，
#   标记刚记住就被抹掉，是"标记虫洞后时灵时不灵"的真凶。
PING_ANCHORS = (
    'Ping actor count',              # assert(count<=16)
    'ambiguous local Ping creator',
    'Ping creator entity missing',
    'Ping creator changed',
    'local Ping creator unavailable',
    'Ping UI inactive',
    'Ping ring bounds',
    "assert(d.validate(),'Ping observation changed')",
    "memory:update(observation,valid)",
)
PING_FORBIDDEN = (
    'if not ok then memory:reset();return nil,tostring(result) end',   # 上游那句
)
PING_REQUIRED = (
    'FAILURE_RESET_LIMIT',
    'last_selected',
    'failed_frames',
)
# ★ search_context / arrival 的放宽都是为了"无敌人也能接管"（2026-09-28 用户需求）。
#   锚点 = 上游的安全断言全部保留；放宽必须经由 allow_early_state / allow_state3
#   两个显式开关，且只在 env.allow_state3=true 时生效。
SEARCH_CTX_ANCHORS = (
    "hex(identity,0)=='8e325c933e55bf62'",
    "u32(record,0)==4",
    "'not active state-4 G60'",
)
SEARCH_CTX_REQUIRED = ("options.allow_early_state",)
ARR_EARLY_ANCHORS = (
    "L.hex64(c.identity_bytes,0)=='8e325c933e55bf62'",
    "L.u32(record,0)==4",
    "'arrival source'",
    "scope.calls.explode",
    "assert(ex.validate() and source()==record,'arrival preflight changed')",
)
ARR_EARLY_REQUIRED = (
    "env.allow_state3 and (L.u32(record,8)==2 or L.u32(record,8)==3)",
)
# ★ structure_route 的改动：新增"寿命末期已在入口侧 ⇒ 直接 attack"（2026-09-28）。
#   上游的路线安全属性**一条都不能少**，所以这里按锚点 pin 死：
#   · 入口轴长度守卫（不进畸形数据）
#   · approach 边界断言（不放宽上游标定的 5~12m）
#   · attack 落点仍是洞口正面 1m + entrance 到达区（不改成"直奔洞心"）
#   · tower/egg 分支完全不动
ROUTE_ANCHORS = (
    "local length=math.sqrt(forward[1]^2+forward[2]^2)",
    "assert(length>0.25,'structure entrance axis')",
    "local approach=profile.front_distance or 5",
    "assert(type(approach)=='number' and approach>=5 and approach<=12,'structure approach bound')",
    "if stage=='front' and distance(own,front)<=1.5 then stage='attack' end",
    "local goal={point[1]+x,point[2]+y,point[3]+0.5}",
    "arrival_region={kind='entrance',forward={x,y},back=0.75,front=1.5,width=1.5,height=1.25}",
    "assert(profile.kind=='structure_tower' or profile.kind=='structure_egg','unknown structure route')",
)
# ★★ 2026-10-05：`ROUTE_REQUIRED` **已删除** —— 它是一条**从未生效**的僵尸守卫。
#   来历：`SAFETY_REQUIRED` 在本文件里被**重复定义**过，后一份把 `structure_route.lua`
#   那一项覆盖掉了 ⇒ 这三条要求从来没被检查过。合并重复定义后它第一次真正运行，
#   结果是**要求一个我们刻意不做的行为**：`profile.direct_entrance`（"直奔洞心"捷径），
#   而本文件上方 `ROUTE_ANCHORS` 的注释明确写着设计意图是
#   「attack 落点仍是洞口正面 1m + entrance 到达区（**不改成"直奔洞心"**）」。
#   ⇒ 两者互相矛盾，说明 ROUTE_REQUIRED 是从另一条分支遗留下来的，与当前设计不符。
#   ⚠ **这是一处需要用户知情的发现**：删掉它 ≠ 修好了什么，而是"这条守卫本来就不成立"。
#     若日后要恢复"直达洞口"能力，应连同 `structure_route.lua` 的实现一起加，再重写守卫。
# ★ titan_route 不再逐字节等于上游：**捷径②的高度门槛** `under+0.5` → `under+2.0`
#   （2026-09-30：实机 4 次接管 `titan_started` 的 stage 全是 `around` ⇒ 捷径②从未命中，
#   每次都要绕 12 m 外圈。计算：原 +0.5 在 standoff=2.5 时要求 G-60 低于腹部 3.0 m，
#   实战几乎不可能；放宽到 +2.0 后只需 1.5 m，净空受限（standoff→0.85）时与腹部同高即可。）
#   上游的路线几何断言与**捷径②的其余条件**（forward≤2.5 有意不动）一条都不能少 ⇒ 锚点 pin 死。
TITAN_ROUTE_ANCHORS = (
    "assert(finite(terminal_radius) and terminal_radius>0 and terminal_radius<=3,'invalid terminal radius')",
    "assert(finite(standoff) and standoff>=0 and standoff<=10,'invalid Titan standoff')",
    "assert(finite(rx) and finite(ry),'invalid route heading')",
    "assert(norm>0.5 and norm<2,'Titan body heading unavailable')",
    "assert(route.side==1 or route.side==-1,'invalid route side')",
    "assert(finite(route.cruise_offset),'invalid route cruise height')",
    "'Titan has insufficient blast standoff clearance'",
    "'Titan has insufficient observed belly clearance'",
    "'unknown Titan route stage'",
    # 捷径②：上游意图注释 + forward 条件
    # ★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）：锚点回到**上游原值** `forward<=2.5`。
    #   我们 2026-10-02 授权放宽成的 `forward<=RADIUS` 已撤回（见 REQUIRED/FORBIDDEN）。
    "Already below the belly and inside the side corridor: go inward,",
    "local forward=math.abs(-dx*ry+dy*rx)",
    "forward<=2.5",
)
TITAN_ROUTE_REQUIRED = (
    "target.origin[3]+1.25",      # 离地余量保持上游 1.25（未动）
    # ★★ 2026-10-05：捷径② 恢复上游原值（用户拍板"泰坦方面全部改成上游"）。
    #   上游只在"腿间侧带"（前后轴偏移 ≤2.5 m）+ 高度 ≤ `under+0.5` 时直接内收。
    "forward<=2.5",
    "own[3]<=under+0.5",
)
TITAN_ROUTE_FORBIDDEN = (
    # 我们曾用的两处偏离 —— 已按用户要求撤回；禁止它们悄悄回来
    # （两处都会改变 G-60 的接近姿态与引爆时机，是本工程历史上反复出问题的地方）。
    "forward<=RADIUS",            # 2026-10-02 授权放宽，2026-10-05 撤回
    "own[3]<=under+2.5",          # 2026-09-30 放宽的安全上限，2026-10-05 撤回
)

# ★★ 2026-10-04：泰坦模板整合（上游 1.1.0 的 `animated_belly`）★★
#   为什么两个文件从"逐字节等于上游"改成**锚点比对**：
#     整合必须动 `compat/titan_profile.lua`（补 3 个字段）与 `src/g60/titan_context.lua`
#     （加 belly 姿态读取 + 蜷曲判定）—— 这两个文件原本在 `SAFETY_LAYER` 里要求逐字节一致。
#   锚点保留的是**安全关键**那部分（身份 / exe 签名守卫 / 骨骼哈希 / accessor 白名单 /
#   全部校验断言），这些**一条都不能少**；新增的两条断言（法线单位性、蜷曲判定）
#   也一并成为锚点 —— 它们保证"爆炸不会被授权到一个脱离身体的点"。
TITAN_PROFILE_ANCHORS = (
    'resource="9e2e17f2ccccafdd"',        # 身份：泰坦单位 resource
    'boss_hash=0x9b115563',                # 主体骨骼
    'belly_hash=0x561d5e2e',               # 腹部骨骼
    'alive_rva=0x1feeb0',                  # Unit-alive 分派 RVA（下游断言用）
    'engine_guards={',                     # exe 签名守卫（5 条，一条都不能少）
    'getters={',                           # 场景图 accessor 白名单（1573 条）
    # 整合新增的三个字段：值必须与上游 1.1.0 **逐值一致**（抄错 = 爆点算错）
    'right_local={2.8311353636991863e-16,-1.0,1.2790338951424682e-17}',
    'forward_local={0.9994231462478638,2.833846133828196e-16,0.0339609794318676}',
    'animated_belly={normal_local=',
    'max_offset=3.0',
)
TITAN_CONTEXT_ANCHORS = (
    "assert(cap>0 and cap<=1048576 and id~=empty,'Titan entity hash bound')",
    "assert(L.u32(identity,8)==id and L.hex64(identity,0)==profile.resource,'Titan identity mismatch')",
    "assert(index<count and count<=0x400000,'Titan Unit index bound')",
    "assert(profile.getters[getter-exe],'unsupported Titan scenegraph accessor')",
    "assert(read(getter,#expected)==expected,'Titan accessor changed')",
    "assert(nodes>=(profile.structure and 1 or 95) and nodes<=512,'Titan scenegraph count')",
    "assert(boss and belly,'Titan bones unavailable')",
    "'Titan point outside body bound'",
    "assert(ptr(api+0x720)==exe+profile.alive_rva,'Titan Unit-alive dispatch mismatch')",
    "assert(validate(),'Titan observation changed')",
    # 整合新增的两条断言
    "assert(norm>0.5 and norm<2,'animated belly normal')",
    "pose_unreliable=delta>profile.animated_belly.max_offset^2 or belly_outward[3]>-0.25",
)

SAFETY_ANCHORS = {
    'src/g60/native_ping.lua': PING_ANCHORS,
    'src/g60/arrival_policy.lua': ARRIVAL_ANCHORS,
    'src/g60/native_search_context.lua': SEARCH_CTX_ANCHORS,
    'src/g60/native_arrival.lua': ARR_EARLY_ANCHORS,
    'src/g60/structure_route.lua': ROUTE_ANCHORS,
    'src/g60/titan_route.lua': TITAN_ROUTE_ANCHORS,
    # ★ 2026-10-04 泰坦模板整合：这两个文件改用锚点比对（理由见上方定义处）
    'compat/titan_profile.lua': TITAN_PROFILE_ANCHORS,
    'src/g60/titan_context.lua': TITAN_CONTEXT_ANCHORS,
}
SAFETY_FORBIDDEN = {
    'src/g60/native_ping.lua': PING_FORBIDDEN,
    'src/g60/arrival_policy.lua': ARRIVAL_FORBIDDEN,
    'src/g60/titan_route.lua': TITAN_ROUTE_FORBIDDEN,
}
SAFETY_REQUIRED = {
    'src/g60/native_ping.lua': PING_REQUIRED,
    'src/g60/arrival_policy.lua': ARRIVAL_REQUIRED,
    'src/g60/native_search_context.lua': SEARCH_CTX_REQUIRED,
    'src/g60/native_arrival.lua': ARR_EARLY_REQUIRED,
    'src/g60/titan_route.lua': TITAN_ROUTE_REQUIRED,
    # ⚠ 此处**不得**再放 `structure_route.lua: ROUTE_REQUIRED` —— 见 ROUTE_REQUIRED
    #   删除处的说明（它要求的 direct_entrance 与本工程的设计意图相反）。
}
# ★★ 2026-10-05：这里原本**重复定义**了一遍 `SAFETY_FORBIDDEN` / `SAFETY_REQUIRED`，
#   后一份把前一份**整体覆盖** ⇒ `titan_route.lua` 的禁令其实**从未被检查过**
#   （本次改泰坦时才发现：`own[3]<=under+2.0` 那条"禁止回退"是空转的）。
#   ⇒ 合并成上面这一份。教训：**同一份守卫表被定义两次时，后一份静默胜出** ——
#     这类"看着有、其实没跑"的守卫比没有守卫更危险（它会让人以为有保护）。

# ★ compat/build.json 里 88 条 game.dll 签名 + exe 引擎签名必须与上游**逐条**相同。
#   2026-09-27 为了让新模块 priority_faults 参与内联，aliases 多了一个 key，
#   所以整个文件不再逐字节相等 —— 改成按 key 逐条比：
#   上游的每一个顶层 key 必须在、且值一致；允许的唯一差异是"上游没有的新别名"。
def check_build_json(up, cur):
    try:
        up_d, cur_d = json.loads(up), json.loads(cur)
    except (TypeError, ValueError) as exc:
        check('build_json_parses', False, str(exc))
        return
    # 签名类顶层 key 必须逐字节相同（engine guards 在 titan_profile.lua 里，
    # 所以这里不写死 key 名单 —— 上游加 key 时本断言自动跟上）
    for key, value in up_d.items():
        if key == 'aliases':
            continue
        same = key in cur_d and cur_d[key] == value
        size = len(value) if isinstance(value, str) else '-'
        check('build_json_pinned:' + key, same, f'{size} 字符/值与上游逐字节相同')
    up_alias, cur_alias = up_d.get('aliases', {}), cur_d.get('aliases', {})
    check('build_json_upstream_aliases_intact',
          all(k in cur_alias and cur_alias[k] == v for k, v in up_alias.items()),
          f'上游 {len(up_alias)} 个模块别名全部保留且同名')
    added = [k for k in cur_alias if k not in up_alias]
    # 允许的新增别名必须逐个说明理由，不得出现未知模块。
    # ★ 2026-09-28：safe_zone / friendly_scan（4m 潜兵安全区）已按用户要求**整体删除**
    #   —— 枚举实体表始终没能稳定工作（两次静默失败），不做半成品。
    allowed_new = {
        'priority_faults',   # 竞争态 vs 结构漂移的分类（治"一颗 G-60 杀死整局"）
        'geometry',           # 只读几何诊断（零 ffi，可在测试里真跑）
        'take_gate',          # 接管门控纯函数（治"runtime 一行都测不到"）
        # ★ 2026-10-05：用户拍板"泰坦方面全部改成上游 1.1"⇒ 把上游泰坦链缺的三段补回来。
        #   三者都是**上游模块名**（不是我们的新发明），逐字移植：
        'navigation',         # 上游 2577-2753：泰坦专用可见性图导航
                              #   ⚠ 别名取 `Nav`（不是 `Navigation`）—— build.py 的 require 替换
                              #     会让 `local Navigation=require('g60.navigation')` 变成
                              #     `local Navigation=Navigation`（自引用、右值取外层 nil）。
        'adaptive',           # 上游 2943-3037：animated_belly 的**消费者**（爆点=腹法线×2.5）
        'blast_route',        # 上游 2470-2573：泰坦链第二段（圆柱爆区，随后被 Adaptive 覆盖）
    }
    check('build_json_only_known_additions', set(added) == allowed_new,
          f'新增别名={added}（允许：{sorted(allowed_new)}）')
    extra = [k for k in cur_d if k not in up_d]
    check('build_json_no_new_top_key', not extra, f'新增顶层 key={extra}')

failures = []


def check(name, ok, detail=''):
    print(('  PASS ' if ok else '  FAIL ') + name + (f'  [{detail}]' if detail else ''))
    if not ok:
        failures.append(name)


def upstream_text(path):
    p = subprocess.run(['git', 'show', f'{UPSTREAM_COMMIT}:{path}'],
                       cwd=ROOT, capture_output=True)
    return p.stdout.decode('utf-8') if p.returncode == 0 else None


def resource_hash(name):
    """MurmurHash64A, same as scripts/build.py."""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def strip_comments(text):
    """去掉 Lua 行注释，避免把说明文字当成代码。"""
    return '\n'.join(re.sub(r'--.*$', '', ln) for ln in text.splitlines())


def main():
    print('=== 1. structure_profiles: 虫洞清单（9 基线 + 7 变体 = 16）===')
    prof = (ROOT / 'compat/structure_profiles.lua').read_text(encoding='utf-8')
    code = strip_comments(prof)
    holes = re.findall(r'profiles\["([0-9a-f]{16})"\]=\{resource="[0-9a-f]{16}",kind="(structure_\w+)"', code)
    check('profiles_count_is_16', len(holes) == 16, f'found {len(holes)}')
    check('all_kind_is_structure_hole', all(k == 'structure_hole' for _, k in holes),
          ','.join(sorted({k for _, k in holes})))
    # 前 9 条必须与上游**逐条一致、顺序不变**（新增的变体一律追加在后面），
    # 这样"与上游的差异"永远只是追加，不会悄悄改动已标定过的条目。
    check('first_9_match_upstream_exactly',
          tuple(i for i, _ in holes[:9]) == UPSTREAM_HOLE_IDS,
          f'前 9 条 = 上游基线；新增 {len(holes) - 9} 条变体追加在后')
    # 上游原有 13 条里，只该删掉"孢子菇 x2 + 任务虫卵 x1"（不是虫洞）
    gone = [i for i in REMOVED_IDS if i in code]
    check('removed_ids_absent', not gone, f'still present: {gone}')
    # ★★ 2026-09-29 用户要求：有生命值的尖啸者巢**不接管** ⇒ 必须不在清单里 ★★
    #   这是本轮的方向反转。旧断言 `shrieker_nest_restored` 要求它**在**表里
    #   —— 那条需求（裁剪 J）来自"可标记就应该能炸"的推断，与用户后来的要求冲突，
    #   以用户要求为准。
    check('shrieker_nest_removed',
          '095686275a113614' not in code and 'nodes=72' not in code,
          '尖啸者巢已移除：不接管、不引导、不引爆，完全交还游戏原生')
    # 泰坦巢用的 colony 洞必须还在（3a2cef12… 是唯一带 front_distance 的那条）
    check('titan_colony_hole_kept',
          'front_distance=10.368875714477495' in code and '3a2cef12ed32a088' in code)

    print('=== 2. 裁剪点：敌人侧决策已移除 ===')
    pri = strip_comments((ROOT / 'src/g60/native_priority.lua').read_text(encoding='utf-8'))
    check('priority_no_candidate_scan', 'Candidates.capture(' not in pri,
          '仍有 Candidates.capture' if 'Candidates.capture(' in pri else '')
    check('priority_no_policy_choose', 'Policy.choose(' not in pri)
    check('priority_keeps_structure_mark_path',
          'structure_mark' in pri and 'PLAYER_MARK_STRUCTURE' in pri,
          '标记虫洞打断敌人锁的分支必须保留')
    check('priority_still_verifies_scope',
          'scope.validate()' in pri and 'target_valid' in pri,
          '持锁窗口与目标有效性校验不能丢')

    rt = strip_comments((ROOT / 'src/g60/experimental_runtime.lua').read_text(encoding='utf-8'))
    check('runtime_excluded_is_false', re.search(r'local excluded\s*=\s*false', rt) is not None)
    # ★ 2026-10-02：原来这里是**字面量禁令**（`'Filter.excluded(m.selection_resource)' not in rt`）。
    #   性能轮次引入了"空闲降频"的新判据 —— 其中一条是"引擎选中了**要否决**的目标"，
    #   而否决必须每帧重申，所以降频判定必须查**同一张**排除表 ⇒ 这个字面量必然出现。
    #   改为钉**语义**（原意是"小怪/非白名单敌人不触发接管"，而不是"这行字不许出现"）：
    #     ① 该查询全文只出现一次
    #     ② 它必须落在降频判据块内（`local busy,veto_must=` … `P.idle_skip=busy and (veto_must and 1 or rb) or ri`），
    #        也就是**不参与接管决策** —— 原来的约束原封不动地保住了。
    check('runtime_excluded_not_computed',
          rt.count('Filter.excluded(m.selection_resource)') == 1
          and rt.index('local busy,veto_must=')
          < rt.index('Filter.excluded(m.selection_resource)')
          < rt.index('P.idle_skip=busy and (veto_must and 1 or rb) or ri'),
          '小怪/非白名单敌人不再触发接管（唯一的 excluded 查询只在降频判据里）')
    # ★★★ 2026-10-05：移植上游的 `continued` —— 认出"这个点是我们自己写的"，
    #     不把实体选择重写回去（优先级 4383-4389 / runtime 6407-6416）。
    #   为什么必须钉：判据**横跨两个模块**且都在"什么都不做"的分支上 ——
    #     任何一侧单独改，表现只是"点目标偶尔被覆盖"，日志上完全看不出来。
    print('=== 2b. `continued`：认出自己写的点（跨 runtime / priority 两侧）===')
    check('runtime_guidance_observation_owned_point',
          'scope.guidance_observation=holder' in rt
          and '==holder.point_bytes' in rt
          and 'and not c.selection.has_target' in rt
          and 'Layout.u32(c.record_bytes,0x64)==0' in rt,
          '★ 只有**本帧的**记录能证明"此刻记录里那个点就是我们写的" ⇒ '
          '这个结论必须由观测者（with_observation）下；priority 手里只有上一帧的字节')
    check('runtime_guidance_observation_requires_point',
          re.search(r'if holder and holder\.point_bytes and c\.selection\.flag==1', rt) is not None,
          '⚠ `holder.point_bytes` 必须判空：普通**实体锁**没有点 —— '
          '不判空会把正常的选择写入也一起跳过 ⇒ 我们的锁再也写不进去')
    # ★★★ 2026-10-05（用户实测报）：ping 的落点必须压过**引擎自选**的泰坦 ★★★
    #   现象：「我没标记泰坦，标记了泰坦附近的空地，G60 却飞向泰坦」。
    #   根因：`titan_selected`（引擎自动选择）在优先级里压住了 ping 点。
    print('=== 2c. ping 落点 vs 引擎自选泰坦（2026-10-05 用户报）===')
    check('ping_point_beats_engine_selected_titan',
          'local ping_beats_titan=point_marker~=nil and point_armed==true' in rt
          and 'and not mark_is_wormhole and not mark_is_this_unit' in rt
          and 'and not (old and old.titan)' in rt
          and 'and not ping_beats_titan' in rt
          and 'and has_weakpoint(m.selection_resource)' in rt,
          '★ 玩家**明确 ping 了落点**时，引擎自选的泰坦必须让位'
          '（否则就是"标记空地却飞向泰坦"）。'
          '⚠ 三条排除缺一不可：`mark_is_this_unit`（玩家点名的是**这个**单位 ⇒ 打它）、'
          '虫洞优先、以及**已在跑泰坦航路**的那颗不改向')
    check('ping_beats_titan_uses_per_unit_test_not_presence',
          'local mark_is_this_unit=structure_mark~=nil and m.selection_id==structure_mark.id' in rt,
          '★★ 排除条件必须是"标记的**就是**这个单位"（比较 id），**不是**"存在任何结构标记" —— '
          '后者会把功能整片挡死（2026-10-01 那个长期存活标记的老坑）')
    check('ping_beats_titan_deduped_and_whitelisted',
          'not P.pbt[m.id]' in rt and 'pbt={}' in rt
          and "not line:match('^point_beats_titan;')"
          in (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8'),
          '★ 事件行按**手雷**去重（条件每帧成立，不去重会刷屏）+ 进白名单'
          '（被节流掉 = 诊断不存在）')
    check('priority_continued_gate',
          'local guidance=scope.guidance_observation' in pri
          and 'local continued=env.fuse_profile and previous and guidance' in pri
          and 'if not continued and (not same_selection or' in pri,
          '★ 与上游 4383-4389 同形 `not continued and (not same_selection or …)`；'
          '⚠ 少了 `not continued and` ⇒ 新机制形同不存在（点仍被实体选择覆盖）')
    check('priority_continued_requires_own_point',
          'and record:sub(0x1d,0x28)==guidance.point_bytes' in pri
          and 'and L.u32(record,0x64)==0' in pri,
          '★ 必须真比对"我们自己的 point_bytes"且掩码已清 —— '
          '只判 `not has_target` 会把"引擎自己的空选择"也当成我们的点')
    check('continued_cross_site_agreement',
          '==holder.point_bytes' in rt and '==guidance.point_bytes' in pri,
          '★ 两侧比的都必须是"持有者自己的 point_bytes"，而不是固定的目标 id 或长度 —— '
          '一侧改成别的判据 ⇒ 这条静默失效')
    # ★★ 2026-10-05：这条是"上游机制在本工程能否触发"的**唯一**保证 ★★
    #   上游靠 `track.titan.point_bytes` 承载结构航点；本工程的**体内爆点**是 runtime
    #   每帧现算的 ⇒ 必须由写入者（native_arrival）把写下的 12 字节交出去、
    #   再由 runtime 回记到锁上。任何一环缺失 ⇒ `continued` 永不触发（且完全静默）。
    _arr_src = (ROOT / 'src/g60/native_arrival.lua').read_text(encoding='utf-8')
    check('arrival_reports_written_point_bytes',
          'written_point=point_bytes' in _arr_src
          and 'point_bytes=written_point' in _arr_src,
          '★ native_arrival 必须把"本帧写进记录的那 12 字节"回报出来 —— '
          '它是 runtime 能认出"这个点是我们写的"的**唯一来源**（上游用 track.titan.point_bytes）')
    check('runtime_stamps_own_point_on_lock',
          'old.lock.point_bytes=result.point_bytes' in rt,
          '★ runtime 必须把它记到**锁**上（`with_observation` 下一帧才能比对）；'
          '⚠ 同一行还承担"走实体 aim 路径时清成 nil"的职责 —— '
          '不复位会把锁卡死在"永远不写实体选择"，比现在的抖动更糟')
    check('priority_continued_same_target_only',
          'and previous.identity==chosen.entity.identity and previous.unit==chosen.unit' in pri
          and 'guidance==previous or' in pri,
          '★ 只对**同一个目标**续点（上游要求 previous 与 guidance.target 两对都等于 chosen）。'
          '⚠ 少了这条：标记切到别的目标时也会跳过写选择 ⇒ 新标记永远不生效')
    check('priority_continued_whitelisted',
          "not line:match('^priority_continued;')"
          in (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8'),
          '★ 它是"新机制真的生效了吗"的**唯一**判据；被日志节流掉 = 诊断不存在')
    # 函数体有多行且含早退的 `if ... then ... end`，
    # 非贪婪匹配到第一个 `end` 会截断（我第一版就这么写，漏掉了后半段）。
    # 改为：从函数起点截到下一个 `local ` 定义为止。
    # 2026-09-29：判定已收敛到 claim_profile（原 has_weakpoint 与 ping.allowed
    # **各写一份**，我只改了一处 ⇒ 标记入口仍拒泰坦，实机 RESOURCE_NOT_SUPPORTED ×4）。
    _i = rt.index('local function claim_profile(resource)')
    _j = rt.find('\n    local ', _i + 10)
    body = rt[_i:_j] if _j > _i else rt[_i:_i + 900]
    # ★ 2026-09-29 范围两度扩展：虫洞 + 吐酸泰坦 + 蟑龙（Dragonroach）。
    #
    #   第一次扩展（+泰坦）时，断言从"只认 structure_profiles"放宽到含 titan_profile，
    #   但死守"不得出现 weakpoint_profiles"。
    #   第二次扩展（+蟑龙）后这条不再成立 —— 蟑龙**就是** weakpoint profile
    #   （kind="thorax"）。所以改成钉**更精确**的安全属性：
    #     · weakpoint_profiles 只能通过 `[resource]` 精确取用
    #     · **不得**按 kind 过滤/批量放行（那会把 Spore Charger 等一起拉进来）
    #     · 匹配用的必须是一个专门的资源常量，不是 kind 判断
    check('has_weakpoint_scope_is_bughole_titan_dragonroach',
          'structure_profiles' in body and 'titan_profile' in body
          and 'weakpoint_profiles' in body
          and 'env.weakpoint_profiles[resource]' in body
          and 'dragonroach_resource' in body,
          body.strip()[:70])
    # ★ 最关键的一条：不得按 kind 批量放行
    check('weakpoint_not_admitted_by_kind',
          '.kind' not in body and 'kind==' not in body,
          '★ 只按精确哈希放行蟑龙，不按 kind 推断（防 Spore Charger 等被顺带拉进来）')
    check('weakpoint_single_exact_lookup',
          body.count('weakpoint_profiles[') == 1,
          '★ weakpoint_profiles 在 claim_profile 里只有一处**精确**取用')
    check('titan_selected_still_reachable',
          re.search(r'titan_selected=not abandoned and titan and selected', rt) is not None
          and 'has_weakpoint(m.selection_resource)' in rt,
          '虫洞必须仍走 titan:step() 才有瞄准点（abandoned 只挡被放弃的那颗）')

    print('=== 3. 安全层与上游逐字节一致 ===')
    # build.json 单独按 key 比对（见 BUILD_JSON_SIGNATURE_KEYS 处的说明）
    check_build_json(upstream_text('compat/build.json'),
                     (ROOT / 'compat/build.json').read_text(encoding='utf-8'))

    for rel in SAFETY_LAYER:
        up = upstream_text(rel)
        cur = (ROOT / rel).read_text(encoding='utf-8') if (ROOT / rel).exists() else None
        if rel in SAFETY_ANCHORS and up is not None and cur is not None:
            # 锚点比对：上游的安全断言一条都不能少；上游那句有害写法必须已移除
            missing = [a for a in SAFETY_ANCHORS[rel] if a not in cur]
            check('anchors_intact:' + rel, not missing,
                  f'{len(SAFETY_ANCHORS[rel])} 条上游安全断言齐全' if not missing
                  else f'缺失: {missing}')
            leaked = [a for a in SAFETY_FORBIDDEN.get(rel, ()) if a in cur]
            check('harmful_removed:' + rel, not leaked, f'仍残留: {leaked}')
            absent = [a for a in SAFETY_REQUIRED.get(rel, ()) if a not in cur]
            check('fix_present:' + rel, not absent, f'修复片段缺失: {absent}')
            continue
        if rel in SAFETY_LAYER_EXCEPTIONS and up is not None and cur is not None:
            # 只允许出现声明过的例外片段，剥掉后必须与上游逐字节相同
            for frag in SAFETY_LAYER_EXCEPTIONS[rel]:
                cur = re.sub(r'[ \t]*--[^\n]*\n', '\n', cur)          # 去掉新增注释
                cur = re.sub(r'\n[ \t]*' + re.escape(frag) + r'.*?\n[ \t]*end\n',
                             '\n', cur, flags=re.S)
            check('untouched_except:' + rel, cur == up,
                  '剥离声明过的例外片段后与上游一致')
            continue
        check('untouched:' + rel, up is not None and cur == up,
              '' if up is not None else 'baseline missing')
    # 例外片段本身必须在（否则"剥离"会把功能一起剥掉）
    for rel, frags in SAFETY_LAYER_EXCEPTIONS.items():
        cur = (ROOT / rel).read_text(encoding='utf-8')
        for frag in frags:
            check('exception_present:' + rel + ':' + frag, frag in cur,
                  '声明过的例外片段仍在')

    print('=== 3b. 泰坦「腹部提前引爆」（2026-10-02，用户要求）===')
    # 背景：`below` 原为 `own[3] <= goal[3]`，而泰坦 goal 已是 `blast_z = 腹点 - standoff`
    #   ⇒ 有效窗口只剩 `dz ∈ [-depth, 0]`，G-60 够不到爆点就在腹部盘旋（用户实机）。
    #   ⇒ 允许在爆点上方 `options.titan_belly_above` 以内引爆，上限由 standoff 约束。
    # ⚠ 行为测试在 `tests/arrival_windows.lua`（需 Windows fixture DLL，本机 lupa 通道会 SKIP）；
    #   这里用**源码级断言**保证结构与安全属性，两条通道互不替代。
    arr_src = (ROOT / 'src/g60/native_arrival.lua').read_text(encoding='utf-8')
    aim_src = (ROOT / 'src/g60/native_titan_aim.lua').read_text(encoding='utf-8')
    entry_src = (ROOT / 'addon/entry.lua.in').read_text(encoding='utf-8')
    check('belly_above_defaults_to_zero_in_arrival',
          'local titan_above=0' in arr_src,
          '★ 缺省 0 ⇒ 不传时与上游行为等价（不是"默认就放宽"）')
    check('belly_above_read_only_for_titan_stage',
          "titan_stage and options and type(options.titan_belly_above)=='number'" in arr_src,
          '★ 只有 `titan/` 前缀的 stage 才读该余量（弱点/虫洞路径不受影响）')
    check('belly_above_applied_to_below',
          'own[3]<=goal[3]+titan_above' in arr_src,
          '★ 余量作用在 `below` 的**上界** ⇒ 只放宽高度，不动水平判定')
    check('belly_above_not_a_new_upvalue',
          arr_src.count('local titan_above=0') == 1 and arr_src.count('local titan_stage=') == 1,
          '★ 收成 pcall 内的 local（Lua 5.1 每函数 upvalue 上限 60）')
    # ★★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）★★
    #   我们自研的两项 —— `titan_standoff_min`（standoff 自适应 1.5~2.5）与
    #   `titan_belly_above`（腹部提前引爆余量）—— **已整段移除**：上游没有这两个量，
    #   而且它们只在"竖直爆点"（`blast_z = 腹点 - standoff`）几何下才有意义，
    #   现在泰坦爆点由 `Adaptive` 决定（腹法线×2.5 + `surface` 区域）。
    #   ⚠ 留着只会误导（"看着还有这个能力"）⇒ 断言之。
    _aim_code = strip_comments(aim_src)
    _entry_code = strip_comments(entry_src)
    check('titan_standoff_adaptation_removed',
          'titan_standoff_min' not in _aim_code
          and 'titan_standoff_adapted' not in _aim_code
          and 'route_standoff' not in _aim_code
          and 'titan_standoff_min' not in _entry_code,
          '★ 自研的 standoff 自适应（`titan_standoff_min` / `titan_standoff_adapted` / '
          '`route_standoff`）必须从泰坦路径与配置里**整段消失**')
    check('titan_belly_above_removed',
          'titan_belly_above' not in _aim_code and 'titan_belly_above' not in _entry_code,
          '★ 腹部提前引爆余量 `titan_belly_above` 已按上游移除（配置 / 透传 / 状态行三处都要没）')
    check('titan_upstream_switches_wired',
          'adaptive_approach=true,blast_regions=true,' in entry_src
          and 'adaptive_approach=state.adaptive_approach,blast_regions=state.blast_regions,' in entry_src
          # ⚠ 状态行那段的引号是**双引号**（拼接串里已有单引号）—— 按实际写法钉，
          #   不要按"看起来应该是单引号"去钉（我第一版就钉错引号，白白 FAIL 一次）。
          and '";adaptive_approach="..tostring(state.adaptive_approach)' in entry_src
          and '";blast_regions="..tostring(state.blast_regions)' in entry_src,
          '★ 上游泰坦链的两个开关（`adaptive_approach` / `blast_regions`）必须'
          '**配置 + 透传 + 状态行**三处齐全 —— 缺一处 = 开关看着生效但没接上')
    check('titan_chain_is_upstream_three_stages',
          "local BlastRoute=require('g60.blast_route')" in aim_src
          and "local Adaptive=require('g60.adaptive')" in aim_src
          and 'pcall(BlastRoute.refine,own_position,target,prior,profile,value)' in aim_src
          and 'pcall(Adaptive.refine,own_position,target,prior,profile,value,now)' in aim_src,
          '★ 泰坦链必须是上游的三段：`TitanRoute.step` → `BlastRoute.refine` → `Adaptive.refine`')
    check('titan_upstream_arrival_region',
          'titan_arrival_region={radius=1.75,depth=0.8},' in entry_src,
          '★ 到达区域回到上游原值 `{radius=1.75,depth=0.8}`（我们曾收到 1.5/1.2 并加 `above`）')
    check('titan_refine_failure_is_visible',
          "env.emit('titan_refine_failed;target='" in aim_src
          and "not line:match('^titan_refine_failed;')" in entry_src,
          '★ `Adaptive`/`BlastRoute` 的断言在实机抛错时，表现是"泰坦**一整局**都不接管" '
          '⇒ 必须有日志且必须进白名单（否则等于没测）')
    # ★★ 2026-10-04：泰坦模板整合（上游 1.1.0 的 `animated_belly`）★★
    #   为什么必须有守门：逻辑分布在 `titan_context`（锚点只管"安全断言齐全"，
    #   不管"这段还在不在跑"）+ `native_titan_aim` 的传参 —— 任一被删就**静默**退回旧行为，
    #   而日志里 `titan_animated_belly=true` 照样显示为真（本工程老毛病：承诺了却看不到）。
    titan_ctx_src = (ROOT / 'src/g60/titan_context.lua').read_text(encoding='utf-8')
    titan_profile_src = (ROOT / 'compat/titan_profile.lua').read_text(encoding='utf-8')
    check('animated_belly_configurable_and_visible',
          'titan_animated_belly=true,' in entry_src
          and 'titan_animated_belly=state.titan_animated_belly,' in entry_src
          and "';titan_animated_belly='..tostring(state.titan_animated_belly)" in entry_src,
          '★ 开关 + 透传 + 状态行**三处齐全**（缺一处 = 开关显示生效但实际没接上）')
    check('animated_belly_actually_wired',
          'env.titan_animated_belly)' in aim_src
          and 'follow_animation and profile.animated_belly' in titan_ctx_src
          and 'belly_outward=belly_outward' in titan_ctx_src,
          '★★ **接线必须真的在**：主路径传 `env.titan_animated_belly` + context 读 `belly_pose` '
          '+ 返回 `belly_outward`（只留开关不接线 ⇒ 测了等于没测）')
    check('animated_belly_follows_upstream_values',
          'right_local={2.8311353636991863e-16,-1.0,1.2790338951424682e-17}' in titan_profile_src
          and 'max_offset=3.0' in titan_profile_src,
          '★★ 三个新字段的值必须与上游 1.1.0 **逐值一致**（抄错 = 爆点算错；锚点只查了前缀）')
    check('animated_belly_really_was_the_fix',
          'pose_unreliable=delta>profile.animated_belly.max_offset^2' in titan_ctx_src
          and 'if pose_unreliable then point=predicted;' in titan_ctx_src,
          '★★ 蜷曲判定必须**真的在**：不可靠时要退回静态几何（`point=predicted`）—— '
          '少了它，脱离身体的腹部标记会被当成合法爆点')
    check('titan_probe_whitelisted',
          "line:match('^titan_probe;')" in entry_src,
          '★ 泰坦接近诊断必须放行 —— 被节流掉 = "盘旋多久/卡在哪"无法定位')
    check('titan_aim_reports_own_position',
          'own_position=own_position,' in aim_src,
          '★ 泰坦诊断必须带 own（原来只有 structure 才带）⇒ 否则看不到 G-60 在哪')
    # ★ 2026-10-02：用户实机观察「站在泰坦**正前方**丢，G-60 仍从侧面绕到腹部」。
    #   根因 = 捷径②的 `forward<=2.5`（"腿间侧带"），从前方来必然不命中。
    #   要判断"放宽到多少"，必须知道 `forward` 的**实际分布** ⇒ 诊断先落地。
    route_src = (ROOT / 'src/g60/titan_route.lua').read_text(encoding='utf-8')
    check('titan_route_exposes_forward_and_under',
          "under=under,forward=forward," in route_src and "distance=radius}" in route_src,
          '★ 捷径②的三个判据随返回值暴露（单一来源，调用方不重算公式）；'
          '`distance` = 到泰坦的距离（日志原来把"到目标点的距离"标成 radius，误导）')
    check('titan_route_forward_defined_once',
          route_src.count('local forward=math.abs(-dx*ry+dy*rx)') == 1,
          '★ `forward` 只定义一次（提到函数顶部）⇒ 不会有两个同名变量互相遮蔽')
    # ★★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）：捷径② 回到上游的
    #   **首帧评估**（写在下游 `else` 分支里）+ `forward<=2.5`。
    #   ⚠ 判据用 `strip_comments`：文件头的"历史"注释会描述旧写法，
    #     只有**代码**里不许再出现（`TITAN_ROUTE_FORBIDDEN` 走原文比对，
    #     所以那两处旧写法连注释都不敢写，见 titan_route.lua 头注释的措辞）。
    _route_code = strip_comments(route_src)
    check('titan_route_shortcut_is_first_frame_only',
          "own[3]<=under+0.5" in _route_code
          and "(route.stage=='out' or route.stage=='around')" not in _route_code,
          '★★ 捷径② 已回到上游：只在 `else`（接管首帧）里评估，**不再每帧重估** —— '
          '判据里不得出现 out/around 的每帧分支（那是我们 2026-10-02 的改法，已撤回）')
    _i_side_assert = _route_code.index("assert(route.side==1 or route.side==-1")
    _i_shortcut = _route_code.index("own[3]<=under+0.5")
    check('titan_route_shortcut_inside_init_branch',
          _i_shortcut < _i_side_assert,
          '★ 上游把捷径② 写在 `else`（初始化分支）**内** ⇒ 位置必须在 '
          '`assert(route.side==1 …)`（初始化分支结束之后）**之前**。'
          '⚠ 顺序即语义：挪到后面就变成"每帧评估"')
    check('titan_route_shortcut_is_upstream_forward',
          'forward<=2.5' in _route_code and 'forward<=RADIUS' not in _route_code,
          '★ 上游的 `forward<=2.5`（只在腿间侧带内收）；我们放宽过的写法必须**已不存在**')
    _rt_src = (ROOT / 'src/g60/experimental_runtime.lua').read_text(encoding='utf-8')
    check('detonate_logs_geometry_split',
          _rt_src.count("';horiz='..tostring(result.horizontal or -1)") == 2
          and _rt_src.count("';dz='..tostring(result.dz or -1)") == 2,
          '★ 引爆日志带 horiz/dz 分解，且**两处 emit（泰坦 + 点目标）都要有** —— '
          '三维 distance 分不清"偏侧"还是"贴脸"，而两者的修法相反。'
          '⚠ 用 `count==2` 而不是 `in`：只写 `in` 的话，漏掉其中一处仍然全绿（本次实测踩到）')

    check('titan_probe_logs_forward',
          'forward=%.2f;under_dz=%.2f' in aim_src and 'route.forward or -1' in aim_src
          and 'route.under and (own_position[3]-route.under)' in aim_src,
          '★ `titan_probe` 输出 forward / under_dz ⇒ 能直接看出"只差哪一条"')

    print('=== 3b-2. 「距离腹部极近时引爆」的判据与防护（2026-10-02，用户实测）===')
    # 用户两条反馈（同一根因）：
    #   ① 「还是偶尔会在距离腹部极近的情况下引爆」
    #   ② 「泰坦准备吐酸时腹部会降低，导致手雷引爆造成杀不死泰坦」
    #      「底部有大型敌人时手雷被迫抬升高度导致受伤部位不够」
    #   ⇒ 都指向"引爆点离腹部太近 ⇒ 受伤部位减少 ⇒ 炸不死"。
    #   ★ 判据只能是**腹点本身**：`dz` 是相对**目标点**的，而目标点会被地面净空抬高
    #     （`under=max(p_z-3.5,floor)`）⇒ 目标点 ≠ 腹部，看 `dz` 会得出相反结论。
    check('titan_probe_logs_belly_height',
          ';p_z=%.2f;belly_dz=%.2f' in aim_src
          and 'target.point[3],own_position[3]-target.point[3]' in aim_src,
          '★ `titan_probe` 必须给出**腹点高度 p_z** 与 `belly_dz = own_z - 腹点z` —— '
          '这是"离腹部多远"的唯一直接读数（目标点会被净空抬高，`dz` 判不出来）')
    check('titan_blast_logged',
          "value.kind=='detonate' and env.emit" in aim_src
          and "'titan_blast;target=%s;stage=%s;p_z=%.2f;own_z=%.2f;belly_dz=%.2f;standoff=%.2f'" in aim_src
          and 'own_position[3]-target.point[3]' in aim_src
          and aim_src.index('assert(value,why)')
              < aim_src.index("'titan_blast;target="),
          '★ 引爆瞬间打一条 `titan_blast`（含 belly_dz / standoff）⇒ 爆点离腹部多远可直接读。'
          '⚠ 连**条件**一起钉（`value.kind==\'detonate\'`）：只钉格式串的话，'
          '把条件改成恒假仍然全绿 —— 本次变异测试发现的空转')
    check('titan_blast_whitelisted',
          "not line:match('^titan_blast;')" in entry_src,
          '★ `titan_blast` 进日志节流白名单（被节流掉 = 下次又是猜）')
    check('titan_blast_deduped_no_new_upvalue',
          "standoff_logged['blast:'..tostring(target.id)]" in aim_src,
          '★ 复用已有的 `standoff_logged` 表（键加 `blast:` 前缀）—— 不给 `api:step` '
          '的 pcall 匿名函数新增 upvalue（余量已紧张，多一个就整 chunk 编译失败）')
    # ★★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）★★
    #   原 `standoff_min_is_200_not_085` / `standoff_no_shrink_below_floor` 两条
    #   钉的是**我们自研的 standoff 自适应**（0.85→1.75→2.0 的试错结论）。
    #   该机制已随"改用上游"**整段移除** ⇒ 这两条不变量不再适用；
    #   取而代之的是"它必须彻底不存在"（见上面的 `titan_standoff_adaptation_removed`），
    #   以及"爆点改由上游 Adaptive 决定"（见 `titan_chain_is_upstream_three_stages`）。
    check('standoff_adaptation_fully_gone',
          'titan_standoff_min' not in strip_comments(entry_src)
          and 'titan_standoff_min' not in strip_comments(aim_src)
          and 'max(lo,max_standoff)' not in strip_comments(aim_src)
          and 'titan_standoff=2.5,' in entry_src,
          '★ `titan_standoff_min`（含 0.85/1.75/2.0 那串试错值）必须**已不存在**；'
          'standoff 直接取上游的 `titan_standoff=2.5`')
    # 净空拒绝 = **等待**，不是引导失败（否则 0.5 秒就把手雷退休 ⇒ 白扔）
    check('clearance_refusal_is_wait_not_failure',
          "local waiting=type(status)=='string'" in _rt_src
          and "status:find('clearance',1,true)~=nil" in _rt_src
          and 'if waiting then' in _rt_src
          and 'detail=WAITING_FOR_SAFE_BLAST' in _rt_src
          and 'guide_fail[m.id]=0' in _rt_src,
          '★ 净空/腹部过低的拒绝被识别为**等待**（腹部抬起后照常引爆）。'
          '⚠ 逐项钉住（含 `if waiting then` 本身）：只钉两个字符串片段的话，'
          '把条件改成 `if false then` 仍然全绿 —— 本次变异测试发现的空转')
    # ★★ 2026-10-03：引导失败记账必须**先问**"是不是已经炸了" ★★
    #
    #   实机日志（2026-10-03 11:29）：实体 16778567 走**泰坦**段时
    #   `'explosion already requested'` 被当普通失败记 30 次 ⇒ `guide_give_up;after=30`
    #   —— 一条**假的失败**（那颗手雷**已经炸了**）。终态相同但多花 1 秒 + 30 条误导日志。
    #   根因：`note_already_exploded` 只接在 disposal / arrival 两段，本段没接。
    _rt_code = strip_comments((ROOT / 'src/g60/experimental_runtime.lua').read_text(encoding='utf-8'))
    _i_ae = _rt_code.find('note_already_exploded(tostring(status or detail))')
    _i_fail = _rt_code.find('local n=(guide_fail[m.id] or 0)+1')
    check('already_exploded_is_done_not_failure',
          _i_ae >= 0 and _i_fail > _i_ae
          and 'guide_fail[m.id]=nil' in _rt_code[_i_ae:_i_fail],
          '★ 引导失败分支先调 `note_already_exploded` 并清零计数 ⇒ 已爆=**完成**，'
          '不计 `fail_count`。⚠ 顺序即语义：放到计数之后就等于"已经记了一次失败"')
    check('already_exploded_single_helper',
          _rt_code.count('note_already_exploded(') == 5,
          '★★ 定义 1 处 + 调用 **4** 处（disposal / arrival / 引导记账 / 已爆短路）'
          '⇒ **同一个条件只用一个判定函数**。'
          '（本项目反复栽在"同一判断写两份、只改一份"上 —— 该 helper 自己的注释就这么写着）')
    check('already_exploded_check_is_before_clearance_wait',
          _i_ae >= 0 and _rt_code.find('elseif waiting then') > _i_ae,
          '★ 已爆（**终态**）判定排在净空等待（**瞬态**）之前 —— 终态优先，'
          '不必再等腹部抬起')
    check('clearance_wait_not_counted_as_failure',
          _rt_src.index("if waiting then") < _rt_src.index('guide_fail[m.id]=0')
          < _rt_src.index('local n=(guide_fail[m.id] or 0)+1'),
          '★ 等待分支**不累加** `guide_fail`（顺序即语义：必须在真正的失败计数之前 return 掉）')
    check('real_failure_still_retires',
          'if n>=GUIDE_FAIL_LIMIT then' in _rt_src and 'guide_give_up;entity=' in _rt_src,
          '★ **真正的**引导失败照旧计数并在 GUIDE_FAIL_LIMIT 后退休 —— '
          '等待分支不得绕过那条熔断（2026-09-29 为"无限循环挂住"加的）')

    print('=== 3b-3. 已爆手雷短路：写内存**之前**先只读探一次（2026-10-03）===')
    # 实机（2026-10-03 13:16 那局）12 次标记**全部**是"锁上即发现已爆"：
    #   引擎的撞击/引信在我们接管之前就炸了，实体还要留几帧；
    #   而我们照样收它 ⇒ 走完整 priority 路径（**含一次 setter 写内存**）
    #   + 打一条误导性的 `priority_locked`，之后才在 arrival 段被判成
    #   `explosion already requested`。
    # ⇒ 在写内存之前先只读探一次；已经炸了就按"完成"收尾。
    arr_src = (ROOT / 'src/g60/native_arrival.lua').read_text(encoding='utf-8')
    check('already_exploded_precheck_exists',
          'function api:triggered(read,identity)' in arr_src
          and "pcall(Explosive.capture,read,env.base,env.exe,identity,env.fuse_profile)" in arr_src,
          '★ 只读探测 = 跑一次 `Explosive.capture`（不写任何内存）')
    check('already_exploded_precheck_same_criteria',
          "'explosion already requested'" in arr_src
          and "'secondary explosion pending'" in arr_src,
          '★★ 判据与 arrival / disposal / 引导记账**逐字同源**（同一把尺子）⇒ '
          '不存在我们自造的假阳性 —— 假阳性会把一颗**健康**的手雷提前退休')
    check('already_exploded_precheck_requires_capture_failure',
          'if ok then return false end' in arr_src
          and 'return true,s' in arr_src,
          '★ 只有「捕获**失败**」且文案命中才判已爆 ⇒ 健康的 G-60（捕获成功）'
          '**永不**被误判，也不会被提前退休')
    check('already_exploded_precheck_before_priority_write',
          "env.emit('priority_precheck_exploded;entity='..m.id" in _rt_code
          and 'note_already_exploded(why)' in _rt_code
          and 'enters=false' in _rt_code,
          '★ 探测命中 ⇒ 打一条可验证的 `priority_precheck_exploded` + 共用 '
          '`note_already_exploded` 收尾 + 关掉本帧的 priority 段（**不写内存**）')
    _i_pre = _rt_code.find('priority_precheck_exploded')
    _i_ent = _rt_code.find('if enters then')
    check('already_exploded_precheck_ordered_before_enters',
          0 <= _i_pre < _i_ent,
          '⚠ 顺序即语义：短路必须排在 `if enters then` **之前**，否则 priority 已经跑完、'
          'setter 已经写过内存，探测就没有意义了。'
          '⚠ 钉 `0 <= _i_pre`：只钉 `_i_pre < _i_ent` 的话，'
          '整段被删（find 返回 -1）仍然全绿 —— 这是本次写测试时差点留下的空转')
    check('already_exploded_precheck_only_on_first_takeover',
          'if enters and not retired[m.id] and not (old and old.lock) then' in _rt_code,
          '★ 门控 `not (old and old.lock)`：只在**首次接管**那一帧探 —— 已锁定的生存实体'
          '每帧走粘性路径而那时 setter 本来就不写（`same_selection`），'
          '不该为它每帧多付一次捕获成本')
    check('already_exploded_precheck_no_new_upvalue',
          "local Explosive=require('g60.explosive_context')" not in _rt_code
          and 'arrival and arrival:triggered(read,m.identity_bytes)' in _rt_code,
          '★★ 复用已有的 `arrival` / `read`（**都已是 tick 的 upvalue**）—— '
          '不给那个 pcall 匿名函数新增 upvalue（余量已很紧，多一个整 chunk 编译失败）')
    check('already_exploded_precheck_prefers_existing_state',
          "not retired[m.id]" in _rt_code,
          '★ 已退休的实体不重复探测（避免重复打日志）')
    check('already_exploded_precheck_whitelisted',
          "not line:match('^priority_precheck_exploded;')" in entry_src,
          '★ 进日志节流白名单 —— 它是"短路真的生效了吗"的唯一判据'
          '（被节流掉 = 诊断不存在；同日 arrival_already_exploded 已栽过一次）')

    print('=== 3c. 多个空标记 ⇒ 取最新 ping 的那个（2026-10-02，用户要求）===')
    # 现状：玩家连 ping 多个点时，ping 环里会**并存**多个空白标记（实机日志
    #   `point_marker;slot=52/53/54`、`slot=75/76/79` 都出现过）。
    #   旧行为只按**扫描顺序**（head→tail 取最后扫到的槽）= "最后看到的"，
    #   而 ping 环是**环形复用**的 ⇒ 先 ping 的标记可能落在更靠后的槽位，优先级反了。
    ping_src = (ROOT / 'src/g60/native_ping.lua').read_text(encoding='utf-8')
    runtime_src2 = (ROOT / 'src/g60/experimental_runtime.lua').read_text(encoding='utf-8')
    check('point_seen_prefers_newest_age',
          'or age<=point_seen.age)' in ping_src,
          '★ 取 `age` 最小（= 存在时间最短 = 最近 ping 的），不再只看扫描顺序')
    check('point_seen_keeps_scan_order_fallback',
          'point_seen==nil or point_seen.age==nil or age==nil' in ping_src,
          '★ 取不到 age 时回退"扫描顺序最后" ⇒ 与旧行为一致（不是硬依赖 age）')
    check('point_seen_uses_le_not_lt',
          'age<=point_seen.age' in ping_src and 'age<point_seen.age' not in ping_src,
          '★ 用 `<=` 而非 `<`：同一帧（age 相同）时后扫到的槽胜出 = 旧行为兜底')
    check('point_seen_is_pure_selection',
          'point_seen={x=px,y=py,z=pz,dist=pd,slot=slot,age=age' in ping_src
          and 'slot_point(r)' in ping_src,
          '★ 只是选择逻辑 + 多带一个 age 字段（不多读字节、不改槽读写语义）')
    # ★★ 2026-10-02：结构标记也改"只认活标记"（用户：取消标记后手雷仍飞向虫洞）★★
    check('structure_mark_live_only_switch',
          "return env.structure_mark_live_only==false" in runtime_src2
          and "structure_mark_live_only=true," in entry_src
          and "structure_mark_live_only=state.structure_mark_live_only," in entry_src
          and ";structure_mark_live_only='..tostring(state.structure_mark_live_only)" in entry_src,
          '★★ 结构/泰坦/变体不再"无条件长期记忆"：改用 `env.structure_mark_live_only`'
          '（默认 true = 只认活标记 ⇒ **取消即失效**；置 false 回到旧行为）。'
          '原写法 `if claim_profile(mark.resource) then return true end` 必须已不存在')
    check('structure_mark_live_only_removed_old_grant',
          "if claim_profile(mark.resource) then return true end" not in runtime_src2,
          '★ 旧的"结构标记无条件放行"必须已删除（不是并存两条）')
    check('point_marker_logs_age',
          ';age=%.2f;source=ping_slot' in runtime_src2 and 'lp.age or -1' in runtime_src2,
          '★ 诊断带 age —— 否则无法在日志里验证"取到的确实是最新的那个"')

    print('=== 4. 身份独立 ===')
    entry = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
    check('entry_global_is_new', "rawset(_G,'G60BugholeLock',state)" in entry)
    check('entry_log_is_new', "open_log,'G60BugholeLock.log'" in entry)
    check('entry_no_old_global', "rawset(_G,'G60SmartTargeting'" not in entry)
    check('entry_no_old_log', "open_log,'G60SmartTargeting.log'" not in entry)
    # ★ 2026-09-29 范围扩展：虫洞 + 吐酸泰坦（build 标识随之改名）。
    #   仍然必须声明 enemy_priority=REMOVED / unmarked_behavior=VANILLA ——
    #   扩展的是"接哪些目标"，不是"接所有目标"。
    check('startup_declares_scope',
          'build=BUGHOLE_PLUS_TITAN' in entry and 'bughole_profiles=16' in entry
          and 'enemy_priority=REMOVED' in entry and 'unmarked_behavior=VANILLA' in entry
          and 'scope=marked_bughole_and_bile_titan' in entry
          and 'titan_enabled=' in entry and 'titan_resource=' in entry)
    # ★ 裁剪 D（修 bug 的关键）：designed_targets_only 必须为 false。
    #   它为 true 时 native_minimal/selection_veto.lua 第 23-24 行会把"不在 allowlist
    #   (泰坦+弱点)里"的选择清掉 selection + 强制搜索 —— 表现为"G-60 只锁大型敌人、
    #   打不了中小型"，而且虫洞同样不在名单里会被误清。
    check('designed_targets_only_is_false',
          'designed_targets_only=false' in entry and 'designed_targets_only=true' not in entry,
          'allowlist 存在即会 veto 非名单目标')
    check('startup_declares_veto_disabled', 'selection_veto=DISABLED' in entry)
    # 启动自述必须显式声明三处门控，否则实机日志无法判断"敌人侧是否已被完全交还"
    for _k in ('enemy_tracking=VANILLA_UNTOUCHED', 'priority_gated=STRUCTURE_ONLY',
               'disposal_gated=HELD_LOCK_ONLY',
               'target_valid=SOFT_SIGNAL'):
        check('startup_declares_' + _k.split('=')[0], _k in entry, _k)
    # ★ 2026-10-04：`arrival_gated` 改成**动态**（随 `allow_state3` 变）⇒ 单独查
    check('startup_declares_arrival_gated',
          ";arrival_gated='" in entry
          and "(state.allow_state3 and 'STATE3_ALLOWED' or 'HELD_LOCK_ONLY')" in entry
          and "';allow_state3='..tostring(state.allow_state3)" in entry,
          'arrival 门控陈述必须随开关变、且 `allow_state3` 可见 —— '
          '否则实机日志判不出"早期接管到底开没开"')
    # ★★ 2026-09-29：这张表**不再为空** —— 用户要求"G-60 不追踪运输船"。
    #   但只允许出现**用户点名的那一项**。上游那 9 项（8 种小虫 + Impaler 触手 +
    #   Hive Guard）**不得恢复** —— 它们的症状是"G-60 打不了中小型敌人"，
    #   正是本工程当初清空该表的原因。
    #   ⇒ 断言从"必须为空"收紧为"恰好一项，且是运输船；上游 9 项一个不许回来"。
    UPSTREAM_EXCLUDED = (
        '51eea86bf6997e4e', '9a8a3aae287b230c', 'aab438596f5e8fd9',
        '72a83e49ced6db3d', '3d0e03e2d574e1ca', '5ca832447445c0ba',
        'be39e313a1e46bb9', '672f7da17f3ba34a', 'a1f37bf2a40fbde4',
    )
    sf = strip_comments((ROOT / 'src/g60' / 'small_filter.lua').read_text(encoding='utf-8'))
    body = sf[sf.index('local excluded = {'):sf.index('}', sf.index('local excluded = {')) + 1]
    entries = re.findall(r"\[?'?([0-9a-f]{16})'?\]?\s*=\s*true", body)
    # ★ 2026-09-29 晚修正：第一版只放了 98152772a72f7838 —— **过滤错了哈希**。
    #   实机日志给出直接证据：`enemy_selection;entity=933;resource=db90077e76faa025`
    #   ⇒ 引擎真正分配给 G-60 的运输船是 db90077e76faa025（cyborg_dropship）。
    #   而 98152772a72f7838（社区表"运输船"）从未被选中过，用户判断它是
    #   **停落地面的运输船** ⇒ 已去掉，表里只剩前者。
    # ★ 2026-10-01：加第二项 —— 光能族的**增援飞船**
    #   illuminate_dropship / 增援穿梭舰，实机日志证据
    #   `enemy_selection;entity=1241;resource=74e2285c01da4f71;vetoed=false`
    #   （用户："光能族的飞船也要过滤 —— 注意是**增援**的飞船"）
    check('small_filter_excludes_evidenced_dropships_only',
          sorted(entries) == ['74e2285c01da4f71', 'db90077e76faa025'],
          f'恰好两项：机器人运输船 + 光能族增援飞船（实际 {entries}）')
    # 反向：**营地停落的**光能族穿梭舰不得被加进来 ——
    #   它是玩家会主动标记去炸的目标（同一局实机日志：structure_mark ACCEPTED 6 次、
    #   priority_locked 14 次）。用户补充："注意是增援的飞船"。
    check('small_filter_landed_warp_ship_not_excluded',
          'b3c9cdb79dc17937' not in entries,
          '★ 营地穿梭舰(Warp Ship Landed)不得被排除（玩家要炸它）')
    # 反向：无证据的两个也不得加（日志里从未被引擎选中过）
    check('small_filter_unevidenced_warp_ships_not_excluded',
          '2ad2e055dad21f6e' not in entries and '01fe503dcd17847b' not in entries,
          '★ 无实机证据的穿梭舰变体不得凭名字加进来')
    # ★★ 2026-10-01（用户要求）：同一张表的**反方向**函数 ★★
    #   `M.marked_allowed(r)` = 玩家**点名标记** r 时允许接管
    #     （运输船/增援飞船是载具 ⇒ 引擎索敌判 false ⇒ 原本标记了也不飞过去炸）。
    #   与 excluded **共用同一集合**（同一个 `excluded` 表），所以两者不可能漂移；
    #   若将来要解耦，必须拆成两张表 + 各配断言。
    check('small_filter_has_marked_allowed_reverse_semantics',
          'function M.marked_allowed(resource) return excluded[resource] == true end' in sf,
          '★ marked_allowed 与 excluded 共用同一集合（反方向语义，结构上无法漂移）')
    # 反向：友军撤离机（鹈鹕）绝不在"玩家可点名接管"的集合里 ——
    #   它虽然索敌也可能判 false，但把友军当炸弹目标是严重错误。
    check('marked_allowed_excludes_friendly_assets',
          '7b0f8449ca9d2da0' not in entries,
          '★ 友军撤离机（鹈鹕 MK2）不得进入排除/点名集合')
    # 反向：冗余的那个不得被加回来（除非日志真的出现它）
    check('small_filter_landed_dropship_not_readded',
          '98152772a72f7838' not in entries,
          '★ 停落地面的运输船(98152772a72f7838)不得重新加入排除表')
    # ★ 安全属性：**绝不能**把玩家自己的撤离机（鹈鹕 shuttle_dropship）也否决掉
    check('small_filter_excludes_no_friendly_pelican',
          '7b0f8449ca9d2da0' not in entries and 'e556fd38edafb3c0' not in entries,
          '★ 不得排除玩家撤离机 / 相关 shuttle 资源')
    check('small_filter_upstream_never_restored',
          not any(u in body for u in UPSTREAM_EXCLUDED),
          '★ 上游 9 项一个都不得恢复（那会重演"打不了中小型敌人"）')
    check('veto_has_no_gate_left',
          'Filter.excluded(selected.resource)' in
          strip_comments((ROOT / 'src/g60' / 'selection_veto.lua').read_text(encoding='utf-8')),
          'veto 判据仍在(由空表+nil allowed 保证永不触发)')

    # ★★ 裁剪 F/G/H（2026-09-27 实机第三轮反馈的三个真凶）★★
    # 前两轮我只关了 selection_veto / small_filter 两道"目标筛选"闸门，
    # 但 runtime 里还有三条**独立于那两道闸门**的干预路径会碰到敌人的 G-60：
    #   F  priority 段无条件进入 -> 为每个 state-4 G-60 建 tracked
    #   F  arrival 段只判 `old`   -> 敌人因此走 arrival:step(target=nil,...,'search')
    #                             -> 每帧 scope.calls.clear(pair,nil)+orbit
    #                             => 引擎刚选中的中小型敌人被反复清掉
    #   G  `result.released or reservations` 在裁剪后恒真 -> force_search 每帧被置 true
    #                             -> 标记虫洞时 titan_selected 被 `not retry_search` 压掉
    #   H  disposal 段只判 behavior_id/state/到期 -> 敌人 G-60 到期被本 mod 主动引爆
    rt = strip_comments((ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8'))
    check('G_force_search_not_forced_by_reservations',
          'result.released or reservations' not in rt and 'elseif result.released then' in rt,
          'force_search 只在真释放锁定时置位')
    check('H_disposal_gated_on_held_lock',
          'if disposal and held and m.behavior_id==4' in rt,
          'disposal(寿命回收)只作用于本 mod 持有的 G-60')
    check('no_unconditional_arrival_or_disposal',
          'if arrival and old and not retired[m.id]' not in rt
          and 'if disposal and m.behavior_id==4' not in rt,
          '不存在无门控的 arrival / disposal 入口')
    # ★★ 裁剪 J：补全"同一模型的摆放变体"（实机"有些虫洞标记后没反应"）★★
    # 这 7 个实体的 SpottableComponent.markerType 都是 EnemyMassive(3) 且可标记
    # ⇒ 玩家能正常 ping 它们，但上游 9 条 profile 没收录 ⇒ mod 报 RESOURCE_NOT_SUPPORTED。
    # ⚠️ 第 8 个（尖啸者巢 095686275a113614）已于 2026-09-29 按用户要求**移除** ——
    #    "可标记"不等于"是虫洞"，判定必须看游戏资源路径。
    prof_txt = (ROOT / 'compat/structure_profiles.lua').read_text(encoding='utf-8')
    HOLE_VARIANTS = {
        '7e4c6b45bcc45c3f': 'bug_spawner_warrior_captive',
        'b6a181adcf547aeb': 'bug_spawner_warrior_ceiling',
        '9d8632a79c2d9789': 'bug_spawner_warrior_tutorial',
        'd666aa61d804d311': 'bug_spawner_scavenger_captive',
        '688949109126ece4': 'mechanical_bughole(机械虫洞)',
        '5cf84155e60c6e4d': 'mechanical_bughole_scavenger',
        '0df874e208040d2f': 'bug_spawner_base',
    }
    missing = [f'{h}({n})' for h, n in HOLE_VARIANTS.items()
               if f'profiles["{h}"]={{resource="{h}"' not in prof_txt]
    check('J_all_markable_hole_variants_covered', not missing,
          f'未收录: {missing}' if missing else f'{len(HOLE_VARIANTS)} 个变体全部收录')
    # 必须**剥掉注释**再数：注释里也出现了 kind="structure_hole" 这个字符串
    # （解释历史时引用过），用原始文本数会把说明文字当成代码。
    n_hole = strip_comments(prof_txt).count('kind="structure_hole"')
    check('J_profile_count_matches_declaration', n_hole == 16,
          f'代码里 {n_hole} 条 structure_hole，启动自述声明 16')
    # 变体必须复用**同模型基线**的 nodes/offset，而不是各自编造
    def params(h):
        mm = re.search(r'profiles\["%s"\]=\{[^}]*?nodes=(\d+)[^}]*?offset=\{([^}]*)\}' % h,
                       prof_txt)
        return (mm.group(1), mm.group(2)) if mm else None
    check('J_warrior_variants_reuse_warrior_nodes',
          params('7e4c6b45bcc45c3f') == params('8c31b749759cbd61')
          and params('b6a181adcf547aeb') == params('8c31b749759cbd61')
          and params('9d8632a79c2d9789') == params('8c31b749759cbd61'),
          'warrior 的 3 个变体与 warrior 基线 nodes/offset 完全一致')
    check('J_scavenger_captive_reuses_scavenger',
          params('d666aa61d804d311') == params('8901f188db366b4b'),
          'scavenger_captive 复用 scavenger 基线')
    # 孢子菇与虫卵仍不接管(不是虫洞)
    check('J_spore_and_egg_still_removed',
          'aa28caf964d05500' not in prof_txt and 'e02e6bd34b606a85' not in prof_txt
          and '06d3c4720e642fc1' not in prof_txt,
          '孢子菇(2) 与任务虫卵(1) 不在清单内')

    # ★★ 裁剪 I（实机"有的虫洞标记后不会飞过去炸"的真凶）★★
    # 上游注释写 "An explicit structure mark may interrupt an existing enemy lock"，
    # 但代码**没有区分** previous 是敌人锁还是在飞中的虫洞锁 —— 只要来新标记就抢占。
    # 实机铁证(同一颗 G-60 服务多个 target)：#1083 锁定562->锁定559(562永久报废)、
    # #1107 锁定562->锁定564->炸564、#1116 锁定567->锁定561->炸561。
    pri = strip_comments((ROOT / 'src/g60' / 'native_priority.lua').read_text(encoding='utf-8'))
    i_sticky = pri.index('if previous and previous.marked_structure then')
    i_newmark = pri.index('if not chosen and structure_mark and env.structure_profiles then')
    check('I_sticky_before_new_mark', i_sticky < i_newmark,
          f"sticky 判定(位置 {i_sticky}) 必须在新标记抢占(位置 {i_newmark}) 之前")
    check('I_sticky_uses_eligible',
          'if row and eligible(row,previous) then chosen,reason=row,\'LOCKED\' end'
          in pri,
          'sticky 分支复用 eligible() 校验（实体在、unit 未变、target_valid、距离）')
    check('I_sticky_marks_structure_flag',
          'marked_structure=true,\n' in pri
          and 'marked_structure=true,\n                        point=' in pri,
          'sticky 构造的 row 必须带 marked_structure=true（否则 eligible 会走 allowlist 半边）')
    check('I_emits_lock_lost_diagnostic',
          "structure_lock_lost" in pri and "ENTITY_GONE" in pri,
          '丢失锁定时发诊断行，便于实机区分"实体消失"与"不再合格"')
    check('I_no_structure_preemption_left',
          pri.count('if not chosen and structure_mark and env.structure_profiles then') == 1,
          '新标记抢占分支只有一处，且已被 sticky 门控在前')

    # ★★ 裁剪 K：target_valid 只能当软信号（它是游戏索敌系统的函数）★★
    # 虫巢没有 HealthComponent —— 正是这一点让引擎原生索敌排除它们（09-24 证否过
    # "让虫巢成为合法目标"）。本 mod 的核心是绕过索敌，却拿索敌的函数否决虫洞 = 自相矛盾。
    # 实机证据：target=511（bug_spawner_stalker 追踪虫巢）ACCEPTED 后立刻 NATIVE_TARGET_INVALID，
    # 且它与刚被炸的 512 位置相距甚远（512 爆点 116,-183 / 513 爆点 -147,10）不是殉爆。
    check('K_has_readonly_fallback',
          'function readonly_alive' in pri and 'POSITION_UNREADABLE' in pri,
          '存在只读复核(实体可读/identity 未变/位置可读)')
    check('K_native_invalid_is_soft',
          pri.count('structure_target_soft_invalid') >= 2,
          '两处 target_valid 判定都改为软信号并留诊断')
    check('K_no_hard_native_reject_left',
          "detail=NATIVE_TARGET_INVALID" not in pri,
          '不再有"原生说无效就立刻放弃"的硬否决')
    check('K_hard_gate_is_readonly',
          all(x in pri for x in ('ENTITY_GONE', 'IDENTITY_CHANGED')),
          '硬门槛改成只读判据(ENTITY_GONE / IDENTITY_CHANGED)')
    # 只读校验本来就必须在 target_valid 之前跑（上游 79-87 行已有）
    i_ro = pri.index('local e=d.entity(structure_mark.id)')
    i_soft = pri.index('if not check_alive(e,\'NEW_MARK\') then return end')
    check('K_readonly_before_soft_check', i_ro < i_soft,
          f'只读校验(位置 {i_ro}) 先于软信号(位置 {i_soft})')

    # ★★ 裁剪 K 补漏：官方版在**三处**用 target_valid 硬否决，我只改了两处 ★★
    # 第三处 native_titan_aim.lua:70（上游原文）：
    #     if not alive then target=nil;reason='Titan no longer alive' end
    # 它**每个飞行帧**都跑 ⇒ target 每帧被置 nil ⇒ 永远算不出航点
    # ⇒ 症状正是"priority_locked 出现了、却没有 titan_aim"。
    # 我曾把 native_titan_aim.lua 列为"安全层逐字节未动"，那是错的。
    tit = (ROOT / 'src/g60' / 'native_titan_aim.lua').read_text(encoding='utf-8')
    check('K_titan_soft_signal',
          "structure_target_soft_invalid" in tit and "context=TITAN" in tit,
          'titan 阶段的 target_valid 也改为软信号')
    _tit_code = re.sub(r'--.*$', '', tit, flags=re.M)   # 去掉行注释后再查
    check('K_titan_no_hard_reject',
          "reason='Titan no longer alive'" not in _tit_code,
          '上游那句"目标不再活着就置 nil"的硬否决已从代码中移除')
    # 三处必须都在软信号路径上（漏一处就等于没改）
    n_soft = (pri.count('structure_target_soft_invalid')
              + tit.count('structure_target_soft_invalid'))
    check('K_all_three_sites_soft', n_soft >= 3,
          f'priority(2) + titan(1) 共 {n_soft} 处软信号判定')
    # titan 的只读复核必须复用已有的 Context.capture（不引入未声明的依赖）
    check('K_titan_reuses_context',
          'pcall(Context.capture' in tit,
          '复用 titan_context（不引入 TargetData 等新依赖）')
    # native_arrival 本身不用 target_valid（确认第 4 处不存在）
    arr = (ROOT / 'src/g60' / 'native_arrival.lua').read_text(encoding='utf-8')
    check('K_arrival_has_no_native_gate', 'target_valid' not in arr,
          'native_arrival 不含 target_valid（无第 4 处遗漏）')

    # ★ 2026-09-28 重构：priority / arrival 的门控判定已抽到 src/g60/take_gate.lua
    #   （纯函数，可真跑测试）。原因见该文件头：重构前这些判断内联在
    #   experimental_runtime 的 host:tick()（550 行、7 类职责）里，而仓库
    #   195 个测试跑的是 g60/core.lua，**一行 runtime 都跑不到** ——
    #   连续四轮实机事故全从这条缝隙溜过去。
    #   所以这里的"门控必须存在"断言改为同时守住两处：
    #     · take_gate 里有该判定（纯函数，可测）
    #     · runtime 真的调用了它（防止"抽出来就忘了用"）
    gate = (ROOT / 'src/g60' / 'take_gate.lua').read_text(encoding='utf-8')
    check('gate_is_pure_lua',
          "require('ffi')" not in gate,
          'take_gate 不依赖 ffi —— 这正是它能在测试里真跑的原因')
    check('gate_priority_call_sites',
          'TakeGate.decide{' in rt and 'local enters=priority~=nil and gate.drive' in rt,
          'runtime 的 priority 段确实走 TakeGate.decide')
    check('gate_guidance_call_sites',
          'TakeGate.decide_guidance{' in rt and 'if arrival and guide.run then' in rt,
          'runtime 的 arrival 段确实走 TakeGate.decide_guidance')
    check('F_priority_gated_on_structure',
          'if old and old.quarantined then' in gate
          and 'if not (o.structure_mark or (old and (old.lock or old.titan or old.point))' in gate
          and 'or o.point_armed) then' in gate,
          'priority 门控：虫洞标记 / 已有锁定 / **TTL 内的 ping（2026-10-09 加）** 才驱动；'
          'quarantined 交回原生')
    check('F_arrival_gated_on_held_lock',
          'if not (o.old and (o.old.lock or o.old.titan or o.old.point)) then' in gate
          and 'if not o.can_guide then' in gate,
          'arrival 门控：必须真正持有锁定/航点，且仅 can_guide（state 4）可做')
    # 三处门控必须真的存在（防止有人"优化"掉）
    for _tag, _frag in (('disposal', 'if disposal and held and m.behavior_id==4'),):
        check(f'gate_present_{_tag}', _frag in rt, f'{_tag} 门控片段存在')
    for _tag, _frag in (('priority', "o.structure_mark or (old and (old.lock or old.titan or old.point))"),
                        ('guidance', 'o.old.lock or o.old.titan or o.old.point'),
                        ('early_flight_age', 'too_early_in_flight')):
        check(f'gate_fragment_{_tag}', _frag in gate, f'{_tag} 判定存在于 take_gate')

    print('=== 5. 产物 ===')
    if not ZIP.exists():
        subprocess.run([sys.executable, '-B', 'scripts/build.py'], cwd=ROOT,
                       capture_output=True, check=True)
    check('zip_exists', ZIP.exists(), str(ZIP.name))
    if not ZIP.exists():
        return
    with zipfile.ZipFile(ZIP) as z:
        names = z.namelist()
        manifest = json.loads(z.read('manifest.json'))
        build_info = json.loads(z.read('BUILD-INFO.json'))
        packaged_source = z.read(SOURCE_IN_ARCHIVE).decode('utf-8', 'replace')
        patch = z.read('Addon/9ba626afa44a3aa3.patch_0')

    check('manifest_guid', manifest['Guid'] == GUID, manifest['Guid'])
    check('manifest_guid_differs_from_upstream', manifest['Guid'] != UPSTREAM_GUID)
    check('manifest_include_addon', manifest['Options'][0]['Include'] == ['Addon'])

    # ★★ 版本号单一来源（2026-10-01）★★
    #   事故：发 v0.1.2 时包还叫 G60-BugHole-Lock-0.1.0.zip（TITLE/ZIP_NAME 把 '0.1.0'
    #   写死在 build.py 里，而 public_version 又是上游基线 '0.1-beta.1'，Release 标签是 v0.1.2
    #   —— 三处互相脱节）。现在三者都必须从 `scripts/build.py` 的 **RELEASE_VERSION** 派生，
    #   这里把"只允许一处定义 + 只允许派生"钉住。
    #   ⚠ `public_version`（build.json）是上游基线，另被 build_json_pinned:* 钉死，
    #      **不能**拿它当我们的版本号；build.json 也不允许新增顶层 key。
    _bp = _BUILD_PY
    check('release_version_declared_exactly_once', len(_release_defs) == 1,
          f'★ 发布版本只允许一处定义（找到 {len(_release_defs)} 处：{_release_defs}）')
    check('release_version_format', re.fullmatch(r"\d+\.\d+\.\d+", _RELEASE_VERSION) is not None,
          f'RELEASE_VERSION={_RELEASE_VERSION}（应为 X.Y.Z）')
    check('build_py_derives_name_from_version',
          f"TITLE = f'{TITLE_PREFIX} {{VERSION}}'" in _bp
          and f"ZIP_NAME = f'{ZIP_NAME.replace(_RELEASE_VERSION, '{VERSION}')}'" in _bp,
          '★ TITLE / ZIP_NAME 必须从 VERSION 派生，不得再硬编码版本串')
    check('build_py_has_no_hardcoded_version',
          f"TITLE = '{TITLE_PREFIX} 0.1" not in _bp
          and f"ZIP_NAME = '{ZIP_NAME.replace(_RELEASE_VERSION, '0.1')}" not in _bp,
          '★ build.py 里不得出现硬编码的版本串')
    check('zip_name_matches_release_version',
          ZIP.name == ZIP_NAME,
          f'{ZIP.name} == build.py 的 ZIP_NAME（{ZIP_NAME}）')
    check('manifest_title_matches_release_version',
          manifest['Name'] == f'{TITLE_PREFIX} {_RELEASE_VERSION}'
          and manifest['Options'][0]['Name'] == manifest['Name'],
          f"显示名 {manifest['Name']}（含 release_version）")
    _bi = build_info
    check('build_info_version_matches',
          _bi['version'] == _RELEASE_VERSION,
          f"BUILD-INFO version {_bi['version']}")
    # 反向：**上游基线** key 必须原封不动（release_version 是新增的，不是替换）
    check('upstream_baseline_version_untouched',
          json.loads((ROOT / 'compat' / 'build.json').read_text(encoding='utf-8'))
          .get('public_version') == '0.1-beta.1',
          '★ public_version（上游基线）不得被当成我们的版本号改掉')
    # 反向：derived_from 记的是**上游基线**，不许跟着版本号一起改
    check('derived_from_still_references_upstream_baseline',
          '0.1-beta.1' in _bi.get('derived_from', ''),
          f"derived_from={_bi.get('derived_from')}")

    # ★ 日志首行必须**同时**给出两件事（2026-10-01）：
    #     version          = 本裁剪版的版本（以前错填成 runtime_version，写着 0.5.20 让人误判）
    #     runtime_baseline = 上游运行时基线
    _rt = json.loads((ROOT / 'compat' / 'build.json').read_text(encoding='utf-8'))['runtime_version']
    check('log_line_reports_release_version',
          f"version={_RELEASE_VERSION}-bughole" in packaged_source,
          f'日志首行 version={_RELEASE_VERSION}-bughole')
    check('log_line_reports_runtime_baseline',
          f'runtime_baseline={_rt}' in packaged_source,
          f'日志首行 runtime_baseline={_rt}（上游运行时基线）')
    check('no_unsubstituted_placeholder',
          '@@' not in packaged_source,
          '★ 产物里不得残留 @@ 占位符（build.py 也有同名断言）')

    check('manifest_mentions_bughole_only', 'bug hole' in manifest['Description'].lower())
    check('manifest_warns_mutually_exclusive',
          'Mutually exclusive' in manifest['Description'])

    # 上游那份 README/docs 描述的是"自动追敌人"的完整功能，不能出现在本包里
    leaked = [n for n in names if n.startswith('docs/')
              or n in ('README.upstream.md', 'README.zh-TW.md', 'CHANGELOG.md', 'README.upstream.zh-TW.md')]
    check('no_upstream_misleading_docs', not leaked, f'leaked: {leaked}')
    check('keeps_license_and_attribution',
          'LICENSE' in names and 'THIRD_PARTY_NOTICES.md' in names)

    magic, types, count = struct.unpack_from('<III', patch, 0)
    check('archive_magic', magic == 0xF0000011, hex(magic))
    name_hash, type_hash, offset, _, _, _, _, size = struct.unpack_from('<7Q6I', patch, 104)[:8]
    check('archive_namehash_matches_new_resource',
          name_hash == resource_hash(NAME), f'{name_hash:016X}')
    check('archive_namehash_differs_from_upstream',
          name_hash != resource_hash('mods/etxp/g60_small_filter'))
    check('archive_lua_type', type_hash == 0xA14E8DFA2CD117E2, hex(type_hash))
    check('archive_single_resource', types == 1 and count == 1, f'types={types} count={count}')
    body_len, body_ver = struct.unpack_from('<II', patch, offset)
    payload = patch[offset + 8:offset + size]
    check('payload_envelope', body_len == size - 8 and body_ver == 2,
          f'len={body_len} size={size} ver={body_ver}')
    text = payload.decode('utf-8')
    check('payload_declares_new_resource', f'-- HD2-Addon: {NAME}' in text)
    check('payload_carries_trimmed_code',
          'local excluded=false' in text and 'Candidates.capture(' not in text
          and 'structure_hole' in text)
    check('payload_keeps_native_explode', 'explode' in text and 'orbit' in text)
    # ⚠ 2026-10-09：`WriteProcessMemory` 从"不得出现"改为**计数式受控**
    #   （用户拍板走写内存实验）⇒ 这里改查"恰好 1 处调用、全文 ≤2 次提及"；
    #   其余高危 API 仍然一律不得出现在**载荷**里。
    check('payload_controlled_write_counted',
          text.count('.WriteProcessMemory(') == 1 and text.count('WriteProcessMemory') <= 2,
          f"call={text.count('.WriteProcessMemory(')} "
          f"mentions={text.count('WriteProcessMemory')}")
    check('payload_has_no_forbidden_api',
          not any(w in text for w in ('VirtualAlloc', 'VirtualProtect', 'GetProcAddress',
                                      'LoadLibrary', 'MinHook', 'ffi.copy')))

    print()
    if failures:
        print(f'RESULT {len(failures)} FAILED: ' + ', '.join(failures))
        return 1
    print('RESULT: ALL PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
