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
# 被裁掉的三条 tower(Shrieker Nest / 2x Spore Spewer) 与一条 egg(embryo_01)
# 上游 13 条里**永久移除**的：2 个孢子菇(不是虫洞) + 1 个任务虫卵。
# 尖啸者巢 095686275a113614 原本也在这张表里（上游归为 structure_tower），
# 但 2026-09-27 裁剪 J 已按其上游原始参数(nodes=72)恢复为虫洞，故移出。
REMOVED_IDS = ('aa28caf964d05500', 'e02e6bd34b606a85', '06d3c4720e642fc1')

# 必须与上游逐字节一致的安全层（改动其中任何一个都要重新论证）
SAFETY_LAYER = (
    'compat/build.json',                    # 88 条 game.dll 签名 + exe 引擎签名
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
    'src/g60/target_reservations.lua',
    'src/g60/target_allowlist.lua',
)

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
    print('=== 1. structure_profiles: 虫洞清单（9 基线 + 8 变体 = 17）===')
    prof = (ROOT / 'compat/structure_profiles.lua').read_text(encoding='utf-8')
    code = strip_comments(prof)
    holes = re.findall(r'profiles\["([0-9a-f]{16})"\]=\{resource="[0-9a-f]{16}",kind="(structure_\w+)"', code)
    check('profiles_count_is_17', len(holes) == 17, f'found {len(holes)}')
    check('all_kind_is_structure_hole', all(k == 'structure_hole' for _, k in holes),
          ','.join(sorted({k for _, k in holes})))
    # 前 9 条必须与上游**逐条一致、顺序不变**（新增的变体一律追加在后面），
    # 这样"与上游的差异"永远只是追加，不会悄悄改动已标定过的条目。
    check('first_9_match_upstream_exactly',
          tuple(i for i, _ in holes[:9]) == UPSTREAM_HOLE_IDS,
          f'前 9 条 = 上游基线；新增 {len(holes) - 9} 条变体追加在后')
    # 上游原有 13 条里，只该删掉"孢子菇 x2 + 任务虫卵 x1"（不是虫洞）
    gone = [i for i in REMOVED_IDS if i in code]
    check('spore_spewer_and_egg_absent', not gone, f'still present: {gone}')
    # 尖啸者巢本轮按其上游原始参数恢复（kind 从 structure_tower 归入 structure_hole）
    check('shrieker_nest_restored',
          '095686275a113614' in code and 'nodes=72' in code,
          '尖啸者巢已恢复(用上游 structure_tower 的原始 nodes=72/offset z=13)')
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
    hw = re.search(r'local function has_weakpoint\(resource\)(.*?)end', rt, re.S)
    body = hw.group(1) if hw else ''
    check('has_weakpoint_structure_only',
          'structure_profiles' in body and 'titan_profile' not in body
          and 'weakpoint_profiles' not in body,
          body.strip()[:70])
    check('titan_selected_still_reachable',
          'titan_selected=titan and selected' in rt and 'has_weakpoint(m.selection_resource)' in rt,
          '虫洞必须仍走 titan:step() 才有瞄准点')

    print('=== 3. 安全层与上游逐字节一致 ===')
    for rel in SAFETY_LAYER:
        up = upstream_text(rel)
        cur = (ROOT / rel).read_text(encoding='utf-8') if (ROOT / rel).exists() else None
        check('untouched:' + rel, up is not None and cur == up,
              '' if up is not None else 'baseline missing')

    print('=== 4. 身份独立 ===')
    entry = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
    check('entry_global_is_new', "rawset(_G,'G60BugholeLock',state)" in entry)
    check('entry_log_is_new', "open_log,'G60BugholeLock.log'" in entry)
    check('entry_no_old_global', "rawset(_G,'G60SmartTargeting'" not in entry)
    check('entry_no_old_log', "open_log,'G60SmartTargeting.log'" not in entry)
    check('startup_declares_scope',
          'build=BUGHOLE_ONLY' in entry and 'bughole_profiles=17' in entry
          and 'enemy_priority=REMOVED' in entry and 'unmarked_behavior=VANILLA' in entry)
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
    # ★ 裁剪 E：small_filter.excluded 必须整表清空。它与 allowlist 是**两道独立闸门**——
    #   selection_veto.plan() 第 23 行 `not Filter.excluded(r) and (not allowed or allowed(r))`
    #   里两个条件是"与"关系，只关掉 allowlist(裁剪 D) 仍会被这张表 veto 掉
    #   8 种小虫 + Impaler 触手 + Hive Guard —— 正是"打不了中小型敌人"的原因。
    sf = strip_comments((ROOT / 'src/g60' / 'small_filter.lua').read_text(encoding='utf-8'))
    body = sf[sf.index('local excluded = {'):sf.index('}', sf.index('local excluded = {')) + 1]
    check('small_filter_excluded_is_empty',
          not re.search(r"\['[0-9a-f]{16}'\]\s*=\s*true", body),
          f'仍排除: {re.findall(chr(91) + chr(39) + r"[0-9a-f]{16}" + chr(39) + chr(93), body)}')
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
    check('F_priority_gated_on_structure',
          'if priority and (structure_mark or (old and (old.lock or old.titan))) then' in rt,
          'priority 段只在有虫洞标记/已有锁定时进入')
    check('F_arrival_gated_on_held_lock',
          'if arrival and old and (old.lock or old.titan) and not retired[m.id] then' in rt,
          'arrival 段只在真正持有锁定/航点时进入')
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
    # 这 8 个实体的 SpottableComponent.markerType 都是 EnemyMassive(3) 且可标记
    # ⇒ 玩家能正常 ping 它们，但上游 9 条 profile 没收录 ⇒ mod 报 RESOURCE_NOT_SUPPORTED。
    prof_txt = (ROOT / 'compat/structure_profiles.lua').read_text(encoding='utf-8')
    HOLE_VARIANTS = {
        '7e4c6b45bcc45c3f': 'bug_spawner_warrior_captive',
        'b6a181adcf547aeb': 'bug_spawner_warrior_ceiling',
        '9d8632a79c2d9789': 'bug_spawner_warrior_tutorial',
        'd666aa61d804d311': 'bug_spawner_scavenger_captive',
        '095686275a113614': 'bug_spawner_shrieker(尖啸者巢)',
        '688949109126ece4': 'mechanical_bughole(机械虫洞)',
        '5cf84155e60c6e4d': 'mechanical_bughole_scavenger',
        '0df874e208040d2f': 'bug_spawner_base',
    }
    missing = [f'{h}({n})' for h, n in HOLE_VARIANTS.items()
               if f'profiles["{h}"]={{resource="{h}"' not in prof_txt]
    check('J_all_markable_hole_variants_covered', not missing,
          f'未收录: {missing}' if missing else f'{len(HOLE_VARIANTS)} 个变体全部收录')
    n_hole = prof_txt.count('kind="structure_hole"')
    check('J_profile_count_matches_declaration', n_hole == 17,
          f'文件里 {n_hole} 条 structure_hole，启动自述声明 17')
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
          'marked_structure=true}' in pri,
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

    # 三处门控必须真的存在（防止有人"优化"掉）
    for _tag, _frag in (('priority', 'if priority and (structure_mark'),
                        ('arrival', 'if arrival and old and (old.lock or old.titan)'),
                        ('disposal', 'if disposal and held and m.behavior_id==4')):
        check(f'gate_present_{_tag}', _frag in rt, f'{_tag} 门控片段存在')

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
