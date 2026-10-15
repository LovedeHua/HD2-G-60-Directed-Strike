"""诊断日志开关（自机探针已合并进来）—— 用户 2026-10-14 要求。

用户原话：「自机探针开关能合并日志开关吗？」
⇒ 合并成一个 `diagnostics_enabled`，口径照主支 `g60-bughole-lock`
  （那边同一项就是这么合的）。开关管**两件事**：
    ① 关掉**自机探针**（`experimental_runtime` 的闸门）
    ② 过滤**高频诊断**日志（`entry` 的 `emit` 过滤器）

本门钉住三件最容易悄悄失效的事：
  ① 过滤器读的必须是 **`host.env`**（菜单写的那张表）—— 主支在这里栽过：
     它读了 `state.diagnostics_enabled`（另一张表）⇒ 过滤器永远看不到开关改动
     ⇒ **整个开关是空的**：探针确实关了（runtime 读 env）所以"看起来生效了"，
     但日志一条都没少。两张表**同名同形**，读代码看不出来 ⇒ 只能靠守门。
  ② **证据行绝不能进 DIAG_VERBOSE** ——「诊断被关掉 = 诊断不存在」：
     关错了就等于把判断成败的手段一起删掉。
  ③ 标签表必须按**本仓实际会打的标签**列 —— 照抄主支会混进
     `driver_audit` / `titan_probe` / `titan_clearance` / `titan_aim` 这类
     本仓根本不存在的**死项**（那种门是空转的）。

并且**真求值**：把 shipped 的过滤段抠出来编译，逐条喂样本行看它丢不丢。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
RT = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
MENU = (ROOT / 'src/g60' / 'menu_text.lua').read_text(encoding='utf-8')

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


# 关掉开关时**必须被丢弃**的（纯仪表：只描述"看到了什么"，不描述"做成了没有"）
INSTRUMENTATION = [
    'perf', 'sel_probe', 'link', 'mark_queue', 'takeover_probe', 'target_fields',
    'point_marker', 'ping_slot', 'obs_beyond', 'priority_continued', 'blast_hold',
    'engine_explode_probe', 'codeprobe', 'constprobe', 'recptr',
    'callerscan', 'callerscan_done', 'statescan', 'statescan_done', 'early_probe',
    'menu_probe', 'menu_restore', 'menu_tick_entered', 'menu_lang',
    'selfprobe', 'status_len',
]
# 关掉开关时**必须照样写**的（判断成败所需的证据）
EVIDENCE = [
    'frame_error', 'errors', 'skipped', 'disabled',
    'priority_locked', 'priority_skipped', 'priority_precheck_exploded',
    'priority_quarantined', 'priority_contended',
    'structure_mark', 'structure_unavailable', 'structure_not_taken_over',
    'structure_lock_lost', 'structure_stalled', 'structure_target_soft_invalid',
    'structure_ping_unavailable',
    'arrival_detonated', 'arrival_skipped', 'arrival_retired', 'arrival_quarantined',
    'arrival_already_exploded',
    'generic_rejected', 'generic_pose_fallback', 'force_lock',
    'safe_engine', 'safe_engine_exploded', 'safe_engine_lost', 'safe_engine_kept',
    'safe_players', 'safe_noexec', 'safe_cancel', 'safe_cancel_failed',
    'blast_safe_failsafe', 'blast_safe_nopos', 'blast_safe_noown',
    'blast_point', 'blast_hit',
    'mark_friendly', 'mark_faction_unknown', 'mark_alloc', 'friendly_lock',
    'enemy_selection', 'enemy_veto', 'safe_veto', 'safe_veto_skip',
    'titan_skipped', 'titan_refine_failed', 'titan_released',
    'observe_failed', 'observe_give_up', 'guide_give_up',
    'point_taken', 'point_held', 'point_armed', 'point_beats_titan',
    'target_locked', 'target_invalid', 'selection_resource_unknown',
    'early_detonated', 'early_promoted', 'early_nav_probe', 'early_nav_orbit',
    'reacquiring', 'search_applied', 'scene_reset', 'spawned', 'fallback',
    'state3_danger', 'state3_takeover_disabled', 'unit_lock_yielded',
    'friendly_point', 'candidate',
]

print('=== ① 结构：开关真的管两件事 ===')
check('probe_is_gated_by_diagnostics',
      'env.diagnostics_enabled~=false and structure_ping' in RT
      and 'self_probe_enabled' not in RT,
      '★ runtime 的探针闸门读 `env.diagnostics_enabled`（`self_probe_enabled` 已删除）')
check('log_filter_present', 'local DIAG_VERBOSE={' in ENTRY and 'local function emit(line)' in ENTRY,
      '★ entry 的 emit 里有过滤器（只关探针 = 日志照样刷屏 ⇒ 等于没合并）')
check('old_switch_fully_removed',
      'self_probe_enabled' not in ENTRY and 'self_probe_enabled' not in MENU,
      '★★ 合并后旧开关**不得残留**（否则界面上会出现两个语义重叠的开关）')
check('menu_item_reused_same_slot',
      "{id='g60.diagnostics_enabled'" in ENTRY and "{id='g60.self_probe_enabled'" not in ENTRY,
      '★ 新开关占用**原来那一格** ⇒ 菜单项数不变，框架按**下标**恢复保存值不会错位'
      '（主支 v0.1.48 就是因为下标错位把整个 mod 弄成什么都不做）')
check('menu_label_says_includes_probe',
      '含自机探针' in MENU and 'incl. self probe' in MENU,
      '★ 界面标签必须写明"含自机探针"，否则用户不知道自己关的是什么')

print()
print('=== ② 过滤器读的是 host.env（主支栽过的那个坑）===')
# ⚠ 只查过滤段本身，避免误伤别处对 state 的正常引用。
#   ⚠⚠ 边界必须用**过滤段自己的结束标记**（`-- Bounded diagnostic output`）——
#     我第一版拿 `local function emit(line)` 当结束点，而它在过滤段**之前**
#     ⇒ 切片为空 ⇒ 后面三条断言全部假红（"提取边界写错"本身就是一次空转断言）。
_FS = 'local he=host and host.env'
_FE = '-- Bounded diagnostic output must not stop filtering'
check('filter_block_bounds_found', ENTRY.index(_FS) < ENTRY.index(_FE),
      '过滤段起止标记存在且顺序正确')
_block = ENTRY[ENTRY.index(_FS):ENTRY.index(_FE)]
check('filter_reads_host_env', 'he.diagnostics_enabled==false' in _block,
      '★★★ 过滤判据必须是 `he.diagnostics_enabled==false`（he = host.env）')
check('filter_does_not_read_state',
      'state.diagnostics_enabled==false' not in _block and 'he=state' not in _block,
      '★★★ **绝不能**读 `state.diagnostics_enabled` —— 那是**另一张表**，'
      '菜单永远不会写它 ⇒ 过滤器永远看不到开关改动 ⇒ 整个开关是空的'
      '（主支实机踩过：探针关了、日志一条没少。两表同名同形，只能靠这条门钉住）')

print()
print('=== ③ 标签表：只收仪表，不收证据；且不含本仓没有的死项 ===')
_i = ENTRY.index('local DIAG_VERBOSE={')
_tbl = ENTRY[_i:ENTRY.index('}', _i)]
_tags = set(re.findall(r'([a-z_0-9]+)=true', _tbl))
_leaked = sorted(t for t in EVIDENCE if t in _tags)
check('no_evidence_tag_in_verbose', not _leaked,
      '★★ 证据行**绝不能**进 DIAG_VERBOSE（关错了 = 把排查手段删掉）：泄漏 %s'
      % (_leaked or '无'))
_missing = sorted(t for t in INSTRUMENTATION if t not in _tags)
check('all_instrumentation_listed', not _missing,
      '★ 本仓的高频仪表都该在表里（漏了它就压不住）：缺 %s' % (_missing or '无'))
_dead = sorted(t for t in ('driver_audit', 'titan_probe', 'titan_clearance', 'titan_aim')
               if t in _tags)
check('no_dead_tags_copied_from_main', not _dead,
      '★ 不得照抄主支的死项（本仓根本不打这些标签 ⇒ 那种门是空转的）：%s'
      % (_dead or '无'))
check('probe_produces_logs_that_are_filterable',
      "env.emit('selfprobe;" in RT and 'selfprobe' in _tags,
      '★ 探针的输出标签必须在表里 —— 否则"关掉诊断"压不住探针的日志')

print()
print('=== ④ 真求值：把 shipped 过滤段抠出来编译，逐条喂样本 ===')
_m = re.search(r'local DIAG_VERBOSE=\{.*?\n    \}\n', ENTRY, re.S)
check('verbose_table_extracted', _m is not None, '抠出 DIAG_VERBOSE 表')
_filter = ENTRY[ENTRY.index(_FS):ENTRY.index(_FE)]
# 把 shipped 的 `return`（= 跳过这一行）改成 `return true`，语义不变、便于断言
_filter = _filter.replace('DIAG_VERBOSE[tag] then return end',
                          'DIAG_VERBOSE[tag] then return true end')
check('filter_body_extracted', 'DIAG_VERBOSE[tag] then return true end' in _filter,
      '抠出过滤段并保留原语义')

lua = lj.LuaRuntime(unpack_returned_tuples=True)
_src = (_m.group(0) + """
local host
local function would_skip(line)
""" + _filter + """
    return false
end
function __SET(on) host={env={diagnostics_enabled=on}} end
function __SKIP(line) return would_skip(line) end
""")
lua.execute(_src)

lua.execute("__SET(false)")
OFF = {t: bool(lua.eval('__SKIP')(t + ';entity=1;detail=x')) for t in INSTRUMENTATION + EVIDENCE}
lua.execute("__SET(true)")
ON = {t: bool(lua.eval('__SKIP')(t + ';entity=1;detail=x')) for t in INSTRUMENTATION + EVIDENCE}

_bad_off = [t for t in INSTRUMENTATION if not OFF[t]]
check('off_drops_instrumentation', not _bad_off,
      '★★ 关掉开关 ⇒ 仪表行必须被丢弃：没丢的 %s' % (_bad_off or '无'))
_bad_ev = [t for t in EVIDENCE if OFF[t]]
check('off_keeps_every_evidence_line', not _bad_ev,
      '★★★ 关掉开关 ⇒ **证据行一条都不能少**（"诊断被关掉 = 诊断不存在"）：'
      '被误丢的 %s' % (_bad_ev or '无'))
_bad_on = [t for t in INSTRUMENTATION + EVIDENCE if ON[t]]
check('on_keeps_everything', not _bad_on,
      '★ 打开开关 ⇒ 一条都不许丢（默认状态 = 与合并前一致）：%s' % (_bad_on or '无'))
# ⚠ 这两条要在**开关关掉**的状态下测 —— 上面那段矩阵最后停在 ON，
#   不重置就会得到"没被丢"的假红（我第一版就踩了这个）。
lua.execute("__SET(false)")
check('untagged_lines_always_kept',
      not lua.eval('__SKIP')('no_tag_here just text'),
      '★ 没有标签的行**永远保留**（宁可多留，不可误删）')
check('colon_separator_also_matched',
      bool(lua.eval('__SKIP')('perf:frame=1')) is True,
      '★ 匹配用 `[;:]` 两种分隔符（与主支一致，避免漏掉 `tag:` 形式）')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
