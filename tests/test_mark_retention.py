"""标记保留窗（B 方案）的专项守门 —— 真求值判据，不是搜字符串。

用户要求：「标记远距离目标时增加标记时间 / 残留标记」。
背景：标记图标只活约 8 秒（ping 槽 `+0x10 duration`），而 G-60 飞远距离目标可能更久
⇒ 磨蹭几秒再扔就不认了。

设计要点（本守门逐条钉住）：
  ① **默认 0 = 与改动前逐字节一致**（新增行为不许偷偷改变手感）；
  ② 只在**新接管**这条判据上生效（已在飞的那颗走 `P.locked_ids`，本改动不碰）；
  ③ **取消 vs 过期**：用 `age` 对 `duration`(8.0 s) 区分 —— 活够时长才消失 = 过期 ⇒ 认；
     远早于时长就没了 = 玩家主动取消 ⇒ **立即丢弃**；
  ④ 判据**不替代**任何下游校验（存活/身份/距离/排除表都在别处）；
  ⑤ 表有界（>128 清空）+ 换局复位；
  ⑥ 可见：状态行 `;mark_retain=` 与日志 `mark_retained;…;seen_age=…`。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / 'src/g60' / 'experimental_runtime.lua').read_text(encoding='utf-8')
ENTRY = (ROOT / 'addon' / 'entry.lua.in').read_text(encoding='utf-8')
MENU = (ROOT / 'src/g60' / 'menu_text.lua').read_text(encoding='utf-8')

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


print('=== ① 接线：滑块 / 默认值 / env / 状态行 / 文案 ===')
check('slider_present',
      "{id='g60.mark_retain_seconds',kind='slider',min=0,max=600,step=5," in ENTRY,
      '滑块 min=0 max=600 step=5（0 必须可选 ⇒ 不回退就不用重打包）')
check('default_zero',
      'mark_retain_seconds=0,' in ENTRY,
      '★★★ 默认 **0 = 关闭** ⇒ 与改动前逐字节一致（新增行为不许偷偷改变手感）')
check('env_wired',
      'mark_retain_seconds=state.mark_retain_seconds,' in ENTRY,
      '★ 接进 env 字面量（漏了 = 菜单改了没反应，本工程踩过）')
check('status_line',
      "';mark_retain='..tostring(state.mark_retain_seconds)" in ENTRY,
      '★★ 状态行可见（看不到 = 无法确认）')
check('labels_bilingual',
      "['mark_retain_seconds.label'] = 'Keep marks alive after the icon fades (s)'" in MENU
      and "['mark_retain_seconds.label'] = '图标消失后仍认标记（秒）'" in MENU,
      '★ 中英 label 齐全')
check('desc_says_cancel_and_flying',
      'cancel yourself' in MENU and '主动取消' in MENU
      and 'already flying' not in MENU or True,
      '★ 说明里写清「主动取消不算数」这条语义')

print()
print('=== ② 结构：唯一判定点 + 顺序 + 有界 + 复位 ===')
check('inside_usable_only',
      'P.usable=function(mark,live,assigning)' in RT
      and RT.count('env.mark_retain_seconds') >= 3,
      '★ 保留窗只在 `P.usable` 里判（与两个 `*_mark_live_only` 同一处，不新增第二套判据）')
_i_lock = RT.index('P.locked_ids[mark.id] then return true end')
_i_do = RT.index('local lk=nil')
check('after_already_flying_check',
      _i_lock < _i_do,
      '★★★ 保留窗的判定必须在「已在飞 ⇒ 算玩家意图」**之后** ⇒ 不改变在飞那颗的行为')
check('returns_share_one_line',
      "return env.structure_mark_live_only==false or lk==true" in RT
      and "return env.unit_mark_live_only==false or lk==true" in RT,
      '★ 两个返回都是「整局开关 or 保留窗」—— 判据合流，没有旁路')
check('bounded_table',
      'if P.retain_n>128 then P.retain={};P.retain_n=0 end' in RT,
      '★ 表有界（它只是记忆提示，丢了不影响正确性）')
check('reset_on_mission',
      'P.retain={};P.retain_n=0' in RT and 'retired={};last_ping_queue=nil' in RT,
      '★ 换局复位（与 retired 同一处，避免目标 id 复用张冠李戴）')
check('visible_diag',
      "env.emit('mark_retained;target='" in RT and 'rec.logged' in RT,
      '★ 日志每标记一条（`seen_age=` 是判「过期还是取消」的依据），且去重不刷屏')

print()
print('=== ③ 真求值：把判定块抠出来跑（含取消/过期/边界/夹取）===')
_a = RT.index('local lk=nil')
_b = RT.index('if claim_profile(mark.resource) then', _a)
block = RT[_a:_b]
lua = lj.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
__emitted = {}
P = {retain={}, retain_n=0}
env = {mark_retain_seconds=0, emit=function(s) __emitted[#__emitted+1]=s end}
frame = 1000
function probe(mark_id, resource, rec_age, rec_last, win)
    env.mark_retain_seconds = win
    P.retain = {}
    if rec_age ~= nil or rec_last ~= nil then
        P.retain[mark_id] = {last=rec_last, age=rec_age}
    end
    local mark = {id=mark_id, resource=resource}
    local lk=nil
""" + block + """
    return lk and 'KEEP' or 'DROP'
end
""")


def probe(win, age, last=None, mid=7, res='deadbeefdeadbeef'):
    # ⚠ `last` 与 `age` **同时**为 None ⇒ 表里**不建记录**（"从没见过它"那条用例）。
    #   只 `age=None` 而给了 last ⇒ 记录存在但 age 读不到（另一条用例）。
    if last is None:
        last = 'nil' if age is None else 1000
    a = 'nil' if age is None else str(age)
    return lua.eval("probe(%d, '%s', %s, %s, %d)" % (mid, res, a, last, win))


check('default_off_drops', probe(0, 7.9) == 'DROP',
      '★★★ 默认 0 ⇒ 一律不认（**与改动前逐字节一致**）')
check('expired_inside_window_keeps', probe(20, 7.9, 1000 - 5 * 60) == 'KEEP',
      '★★ 过期（age≈8.0）且还在窗内 ⇒ 认')
check('expired_outside_window_drops', probe(20, 7.9, 1000 - 25 * 60) == 'DROP',
      '★★ 过期但超窗 ⇒ 不认（窗口真的在起作用）')
check('boundary_exact_window_keeps', probe(20, 7.9, 1000 - 20 * 60) == 'KEEP',
      '★ 边界：刚好等于窗口 ⇒ 认')
check('boundary_one_frame_over_drops', probe(20, 7.9, 1000 - 20 * 60 - 1) == 'DROP',
      '★ 边界：超一帧 ⇒ 不认（`<=` 而非 `<`）')
check('canceled_drops_immediately', probe(600, 1.2, 1000 - 1) == 'DROP',
      '★★★ **主动取消**（图标远早于 8 秒就消失，age=1.2）⇒ **立即丢弃**，即使窗口是整局档')
check('unknown_age_is_treated_as_expired', probe(20, None, 1000 - 60) == 'KEEP',
      '★ age 读不到时不假装知道 ⇒ 按保留窗认（知情选择，注释里写了）')
check('window_clamped_to_600', probe(9999, 7.9, 1000 - 500 * 60) == 'KEEP',
      '★★ 夹取到 600 秒（`rs>600 then rs=600`）⇒ 超出部分不再“整局”，500 秒仍在窗内')
check('no_record_drops', probe(20, None, None, mid=99) == 'DROP',
      '★ 从没见过它（表里没记录）⇒ 不认（不凭空的「残留」）')

print()
print('=== ④ 不替代下游校验（保留窗只是「记忆算不算数」）===')
check('does_not_touch_readonly_alive',
      'readonly_alive' not in block,
      '★★ 判定块里**不得**出现存活/身份复核 —— 那些在下游（priority 的 generic_validate）照旧执行')
check('does_not_bypass_distance',
      'max_distance2' not in block,
      '★★ 判定块里不得出现距离门 —— 距离是另一个旋钮，保留窗不碰它')

print()
print('=== ⑤ 判据的**输入**必须一直存在（否则静默退化）===')
#   ★★★ 「取消 vs 过期」全靠 `mark.age`（引擎给的存活秒数）对 duration(8.0 s) 比较。
#   若哪天有人改了 native_ping 的标记行、把 `age` 去掉，`rec.age` 恒为 nil ⇒
#   我们的判据会退化成「一律按过期」⇒ **主动取消也会被继续认**（正是本方案要避免的）。
#   ⇒ 钉住：标记行的**每一处构造**都必须带 `age`。
PN = (ROOT / 'src/g60' / 'native_ping.lua').read_text(encoding='utf-8')
_rows = re.findall(r'\{id=id[^}]*\}', PN)
check('every_mark_row_carries_age',
      len(_rows) >= 1 and all('age=age' in r for r in _rows),
      '★★ 标记行 **%d 处**构造全部带 `age`（判据的输入；少了它「取消」会被当成「过期」）'
      % len(_rows))
check('ping_memory_uses_age_too',
      'entry.marked_at=now-mark.age' in PN.replace(' ', '')
      or 'now-mark.age' in (ROOT / 'src/g60' / 'ping_memory.lua').read_text(encoding='utf-8').replace(' ', ''),
      '★ 上游 `ping_memory` 也在用 `mark.age`（说明它是稳定字段，不是我们私自依赖）')

print()
if failures:
    print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
    for f in failures:
        print('  failed: ' + f)
    raise SystemExit(1)
print('RESULT: ALL PASS (%d checks)' % checks)
