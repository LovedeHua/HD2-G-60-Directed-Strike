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

NAME = 'mods/hd2test/g60_bughole_lock'
GUID = '9c1d4e77-2b83-4f6a-91e5-0d7b3a6c8f42'
UPSTREAM_GUID = '58a16a67-a72b-474a-ad05-adbaaa99da78'
ZIP = ROOT / 'dist' / 'G60-BugHole-Lock-0.1.0.zip'

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
ROUTE_REQUIRED = (
    "profile.direct_entrance",          # 必须是显式开关，不得无条件放宽
    "along>0 and flat<=approach",       # 只在入口侧且已在进场半径内
    "M.on_direct_entrance",             # 纯函数保持：不直接依赖 env
)
SAFETY_ANCHORS = {
    'src/g60/native_ping.lua': PING_ANCHORS,
    'src/g60/arrival_policy.lua': ARRIVAL_ANCHORS,
    'src/g60/native_search_context.lua': SEARCH_CTX_ANCHORS,
    'src/g60/native_arrival.lua': ARR_EARLY_ANCHORS,
    'src/g60/structure_route.lua': ROUTE_ANCHORS,
}
SAFETY_REQUIRED = {
    'src/g60/native_ping.lua': PING_REQUIRED,
    'src/g60/arrival_policy.lua': ARRIVAL_REQUIRED,
    'src/g60/native_search_context.lua': SEARCH_CTX_REQUIRED,
    'src/g60/native_arrival.lua': ARR_EARLY_REQUIRED,
    'src/g60/structure_route.lua': ROUTE_REQUIRED,
}
SAFETY_FORBIDDEN = {
    'src/g60/native_ping.lua': PING_FORBIDDEN,
    'src/g60/arrival_policy.lua': ARRIVAL_FORBIDDEN,
}
SAFETY_REQUIRED = {
    'src/g60/native_ping.lua': PING_REQUIRED,
    'src/g60/arrival_policy.lua': ARRIVAL_REQUIRED,
    'src/g60/native_search_context.lua': SEARCH_CTX_REQUIRED,
    'src/g60/native_arrival.lua': ARR_EARLY_REQUIRED,
}

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
    check('runtime_excluded_not_computed',
          'Filter.excluded(m.selection_resource)' not in rt,
          '小怪/非白名单敌人不再触发接管')
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
               'arrival_gated=HELD_LOCK_ONLY', 'disposal_gated=HELD_LOCK_ONLY',
               'target_valid=SOFT_SIGNAL'):
        check('startup_declares_' + _k.split('=')[0], _k in entry, _k)
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
    check('small_filter_excludes_cyborg_dropship_only',
          entries == ['db90077e76faa025'],
          f'恰好排除机器人运输船一项（实际 {entries}）')
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
          and 'if not (o.structure_mark or (old and (old.lock or old.titan))) then' in gate,
          'priority 门控：只有虫洞标记/已有锁定才驱动；quarantined 交回原生')
    check('F_arrival_gated_on_held_lock',
          'if not (o.old and (o.old.lock or o.old.titan)) then' in gate
          and 'if not o.can_guide then' in gate,
          'arrival 门控：必须真正持有锁定/航点，且仅 can_guide（state 4）可做')
    # 三处门控必须真的存在（防止有人"优化"掉）
    for _tag, _frag in (('disposal', 'if disposal and held and m.behavior_id==4'),):
        check(f'gate_present_{_tag}', _frag in rt, f'{_tag} 门控片段存在')
    for _tag, _frag in (('priority', "o.structure_mark or (old and (old.lock or old.titan))"),
                        ('guidance', 'o.old.lock or o.old.titan'),
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
        patch = z.read('Addon/9ba626afa44a3aa3.patch_0')

    check('manifest_guid', manifest['Guid'] == GUID, manifest['Guid'])
    check('manifest_guid_differs_from_upstream', manifest['Guid'] != UPSTREAM_GUID)
    check('manifest_include_addon', manifest['Options'][0]['Include'] == ['Addon'])
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
    check('payload_has_no_forbidden_api',
          not any(w in text for w in ('VirtualAlloc', 'WriteProcessMemory', 'GetProcAddress')))

    print()
    if failures:
        print(f'RESULT {len(failures)} FAILED: ' + ', '.join(failures))
        return 1
    print('RESULT: ALL PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
