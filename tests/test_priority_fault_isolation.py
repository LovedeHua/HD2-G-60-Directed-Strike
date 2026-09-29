"""故障域隔离回归 —— 2026-09-27 实机事故。

事故：一次 setter 回读不符就把**整个 mod** 永久停手。

实机日志（Logs/G60BugholeLock.log 第 131-133 行）::

    arrival_detonated;entity=834;target=520;distance=1.5079670643937
    frame_error;detail=…: priority native operation disabled: …: priority setter target mismatch
    disabled;applied=0

前 5 次引爆全部成功，第 6 颗 G-60 的一次回读不符就让整局剩下所有标记全部失效
（`disabled` 后 `host:tick` 直接 return，applied 永远 0）。

根因链有两处，都不是内存布局漂移：
  1. native_priority 收尾 `if mutated then disabled=true end` —— 无差别永久停手
  2. experimental_runtime `if priority:disabled() then self.disabled=true; error(...)` —— 传染到全局

治本还有第三条：引爆/退役时只写了 `retired` 却没清 tracked 里的 lock/titan，
虫洞实体 id 被引擎复用后，残留锁会把选择写到**另一个**实体上，写后回读必然不符。

本测试分两层：
  ① 真跑 lupa 验证两个纯 Lua 模块的语义（priority_faults / target_reservations）
  ② 静态检查三个接线点，确保修复没有被后续改动悄悄删掉
"""
import pathlib
import re

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRIORITY = ROOT / "src/g60" / "native_priority.lua"
RUNTIME = ROOT / "src/g60" / "experimental_runtime.lua"
RESERVATIONS = ROOT / "src/g60" / "target_reservations.lua"
GEOMETRY = ROOT / "src/g60" / "geometry.lua"
TITAN = ROOT / "src/g60" / "native_titan_aim.lua"
FAULTS = ROOT / "src/g60" / "priority_faults.lua"

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    if ok:
        print(f"  PASS {name:52} [{detail}]")
    else:
        failures.append(name)
        print(f"  FAIL {name:52} [{detail}]")


def load_module(path, name, rt):
    """在 lupa 里按 g60.<name> 注册并 require 回来（纯 Lua 模块，无 ffi）。"""
    src = path.read_text(encoding="utf-8")
    rt.execute(f"__SRC = [==[\n{src}\n]==]")
    rt.execute(f"__M = load(__SRC)()")
    rt.execute(f"package.loaded['g60.{name}'] = __M")
    return rt.eval(f"require('g60.{name}')")


def test_fault_classification(rt):
    print("=== ① 真跑 priority_faults：竞争态 vs 版本漂移 ===")
    F = load_module(FAULTS, "priority_faults", rt)
    competitive = F.competitive

    # 竞争态：这两条来自 native_priority.lua 的写后回读断言
    check("setter_target_mismatch_is_competitive",
          bool(competitive("priority setter target mismatch")),
          "回读不符 -> 局部放弃")
    check("setter_metadata_mismatch_is_competitive",
          bool(competitive("priority setter metadata mismatch")),
          "元数据不符 -> 局部放弃")

    # 版本漂移：这些继续乱写会让游戏崩，必须保持全局 fail-closed
    structural = [
        "priority scope changed",
        "priority source changed",
        "priority behavior or flight timer changed",
        "priority scope unavailable",
        "priority source mismatch",
        "priority ABI mismatch",
        "experimental priority scope required",
        "priority target observation changed",
        "priority target changed during validation",
        "marked structure changed",
        "pointer bound",
        "snapshot budget",
        "entity hash capacity",
    ]
    leaked = [m for m in structural if competitive(m)]
    check("structural_drift_not_competitive", not leaked,
          f"{len(structural)} 条漂移消息全部排除" if not leaked else f"误判: {leaked}")

    # ★★ pcall 捕获的 error 带 `chunkname:line: ` 前缀。只匹配裸消息会漏判
    # ⇒ 走 disabled=true ⇒ 整局死亡（2026-09-28 闪退前一刻的日志正是这样）。
    PREFIX = "mods/hd2test/g60_bughole_lock.lua:2293: "
    for msg in ("priority setter target mismatch",
                "priority setter metadata mismatch"):
        check("prefixed_competitive_" + msg.split()[-1],
              bool(competitive(PREFIX + msg)),
              f"带位置前缀仍识别为竞争态: {msg}")
    # 反过来：结构性漂移即使带前缀也不能被误判成竞争态
    for msg in ("priority scope changed", "priority source mismatch",
                "pointer bound", "snapshot budget"):
        check("prefixed_drift_not_competitive_" + msg.split()[0],
              not competitive(PREFIX + msg),
              f"带前缀的漂移仍排除: {msg}")

    limit = F.CONTENTION_LIMIT
    check("contention_limit_sane", isinstance(limit, int) and 2 <= limit <= 8,
          f"熔断阈值={limit}（同场最多 2 颗在飞）")

    # 判定必须经由 tostring，非字符串输入不能崩
    rt.execute("__OK = require('g60.priority_faults').competitive(12345)")
    check("competitive_tolerates_non_string", rt.eval("__OK") is False,
          "数字入参返回 false 而不是抛错")


def test_reservation_release(rt):
    print()
    print("=== ② 真跑 target_reservations：放弃一颗 G-60 要归还预约 ===")
    # 在 Lua 侧跑完整场景：lupa 从 Python 调 Lua table 的方法时不会按 `:` 语义
    # 注入 self（踩过：api.claim(a,b) 会把 a 当 owner、b 当 target，
    # 于是 identity 断言炸在"reservation identity required"，看起来像模块坏了）。
    src = RESERVATIONS.read_text(encoding="utf-8")
    rt.execute(f"__SRC = [==[\n{src}\n]==]")
    rt.execute(f"package.loaded['g60.target_reservations'] = load(__SRC)()")
    rt.execute("""
    local R = require('g60.target_reservations')
    -- Reservations.identity 要求 24 字符且只用前 20 字符做 key（活动位会变）
    local a, b   = string.rep('aa',12), string.rep('bb',12)
    local o1, o2 = string.rep('11',12), string.rep('22',12)
    local api = R.new()

    api:claim(o1, a)
    __blocks_other  = not api:available(o2, a)   -- 预约后其他 owner 拿不到
    __allows_self   = api:available(o1, a)       -- 同一 owner 幂等

    -- ★ 本次修复引入的能力：放弃一颗 G-60 后必须归还预约，否则那个虫洞对所有
    --   其他 owner 永远 available=false —— 表现为"这洞再也接管不了"。
    api:release_owner(o1)
    __frees_target  = api:available(o2, a)

    -- 别人的预约不受影响
    api:claim(o1, a)
    api:claim(o2, b)
    api:release_owner(o1)
    __scoped = api:available(o2, a) and not api:available(o1, b)

    -- 重复释放必须安全（quarantine 路径可能反复走到）
    local ok = pcall(function() api:release_owner(o1) api:release_owner('missing') end)
    __idempotent = ok
    """)
    g = lambda k: rt.eval(k)  # noqa: E731
    check("claimed_blocks_other_owner", bool(g("__blocks_other")),
          "预约后其他 owner 拿不到")
    check("claimed_allows_same_owner", bool(g("__allows_self")),
          "同一 owner 幂等")
    check("release_owner_frees_target", bool(g("__frees_target")),
          "释放后其他 owner 可接管")
    check("release_owner_scoped", bool(g("__scoped")),
          "只还自己名下的")
    check("release_owner_idempotent", bool(g("__idempotent")),
          "重复释放/释放不存在的 owner 不抛错")


def test_priority_wiring():
    print()
    print("=== ③ 静态检查：修复的三个接线点 ===")
    p = PRIORITY.read_text(encoding="utf-8")
    r = RUNTIME.read_text(encoding="utf-8")

    # (1) 竞争态分支必须在 disabled=true 之前 return
    m = re.search(
        r"if competitive\(result\) then(.*?)if mutated then disabled=true end",
        p, re.S)
    check("priority_quarantine_before_disable", m is not None,
          "竞争态分支在 disabled 赋值之前")
    if m:
        seg = m.group(1)
        check("quarantine_returns_kind", "kind='quarantine'" in seg,
              "返回 kind='quarantine'")
        check("quarantine_does_not_disable", "disabled=true" not in seg,
              "竞争态路径不置 disabled")

    # 上游的写法必须已经不在了
    check("upstream_blanket_disable_gone",
          "if not ok then if mutated then disabled=true end" not in p,
          "无差别永久停手已移除")

    # (2) runtime 侧：quarantine 只放弃单颗
    check("runtime_handles_quarantine", "result.kind=='quarantine'" in r,
          "runtime 识别 kind='quarantine'")
    for field in ("old.quarantined=true", "old.lock=nil", "old.titan=nil",
                  "old.blocked=nil"):
        check(f"quarantine_clears_{field.split('=')[0][4:]}",
              re.search(r"if result\.kind=='quarantine' then(?:(?!elseif).)*?"
                        + re.escape(field), r, re.S) is not None,
              f"隔离分支里清 {field}")
    check("quarantine_releases_reservation",
          re.search(r"if result\.kind=='quarantine' then(?:(?!elseif).)*?"
                    r"reservations:release_owner", r, re.S) is not None,
          "归还预约，否则该虫洞对其他 G-60 永久不可用")
    check("contention_limit_wired", "CONTENTION_LIMIT=require('g60.priority_faults').CONTENTION_LIMIT" in r,
          "同帧熔断阈值来自模块常量")

    # (3) 治本：所有写 retired 的地方都要清持有
    writes = len(re.findall(r"retired\[m\.id\]=retired_key", r))
    clears = len(re.findall(r"release_hold\(m\.id\)", r))
    check("every_retired_clears_hold", writes == clears and writes >= 3,
          f"{writes} 处写 retired / {clears} 处 release_hold")
    check("release_hold_clears_lock_and_titan",
          re.search(r"function release_hold\(id\)(?:(?!end).)*t\.lock=nil"
                    r"(?:(?!end).)*t\.titan=nil", r, re.S) is not None,
          "release_hold 同时清 lock 与 titan")

    # 放弃当帧不得再被 titan 段写回去
    check("abandoned_blocks_titan",
          "local titan_selected=not abandoned and titan and selected" in r,
          "abandoned 挡住 titan 段入口")

    # frame_error 逐条刷屏会把致命错误埋掉
    check("frame_error_deduped",
          "if seen_before==0 then env.emit('frame_error;detail='..detail) end" in r,
          "同 detail 只打首条，余量计入汇总")

    # 竞争态判定必须来自模块（可测），不能是就地硬编码
    check("faults_module_required",
          "require('g60.priority_faults')" in p and "Faults.competitive" in p
          and "require('g60.priority_faults').CONTENTION_LIMIT" in r,
          "native_priority / runtime 走模块判定")

    # 构建期：Faults 别名必须排在 Priority 与 Runtime 之前。
    # build.py 把每个模块包成 (function() ... end)()，并把 require 替换成 chunk 别名；
    # 顺序错 ⇒ 运行期该别名还是 nil ⇒ 与 2026-09-27 那次 upvalue 事故同类。
    import json
    aliases = list(json.loads((ROOT / "compat/build.json").read_text(encoding="utf-8"))["aliases"])
    check("faults_alias_present", "priority_faults" in aliases,
          "build.json 已登记 priority_faults")
    if "priority_faults" in aliases:
        at_f = aliases.index("priority_faults")
        for later in ("native_priority", "experimental_runtime"):
            if later in aliases:
                check(f"faults_alias_before_{later}", at_f < aliases.index(later),
                      f"Faults 在 {later} 之前定义")


# 2026-09-27 第二轮：我自己引入的回归。把关卡条件写成
#   `priority and not old.quarantined and (structure_mark or (old and ...))`
# 而 `old` 在首次遇到这颗 G-60 时是 **nil** ⇒ `attempt to index a nil value`，
# 整帧被 pcall 吞掉。实机症状：structure_mark 正常 ACCEPTED，
# 但 priority_locked 一次都不出现（全链路静默死亡，且 frame_error 也看不到）。
NIL_GUARD = r"""
-- 两种写法：A = 直接索引（错），B = 先判 old（对）。
-- 用两个独立的 Lua state 分别跑，避免互相污染。
local function compile(mode, has_old)
  local body = (mode == 'A')
      and [==[
          local ok = (priority and not old.quarantined
                      and (structure_mark or (old and (old.lock or old.titan))))
          return tostring(ok ~= nil and ok ~= false)
      ]==]
      or  [==[
          local ok = (priority and not (old and old.quarantined)
                      and (structure_mark or (old and (old.lock or old.titan))))
          return tostring(ok ~= nil and ok ~= false)
      ]==]
  -- 注意：[==[ ]==] 里 \n 不会被转义（踩过：'\n' 变成字面两字符，
  -- 于是 'local old=nil\n' 字符串未闭合 -> unfinished string）。
  -- Lua 语句之间不强制换行，直接拼空格即可。
  local pre = (has_old and 'local old={quarantined=false,lock=nil,titan=nil} ')
              or 'local old=nil '
  local src = 'local priority=true local structure_mark={id=1} ' .. pre .. body
  return (load(src))()
end
local function probe(mode, has_old)
  local ok, ret = pcall(compile, mode, has_old)
  return tostring(ok) .. '||' .. tostring(ret)
end
__A_NIL  = probe('A', false)   -- 错写法 + old 为 nil  -> 必须崩
__A_OLD  = probe('A', true)    -- 错写法 + old 存在    -> 正常
__B_NIL  = probe('B', false)   -- 对写法 + old 为 nil  -> 必须正常
__B_OLD  = probe('B', true)    -- 对写法 + old 存在    -> 正常
"""


def test_nil_guard(rt):
    print()
    print("=== ③ 真跑复现：old 为 nil 时两种写法的差别 ===")
    rt.execute(NIL_GUARD)

    def g(k):
        v = rt.eval(k)
        s = v.decode() if isinstance(v, bytes) else str(v)
        ok, _, ret = s.partition("||")
        return ok, ret

    ok_a, ret_a = g("__A_NIL")
    check("unguarded_index_crashes", ok_a == "false" and "nil value" in ret_a,
          f"直接 old.quarantined 在 old=nil 时崩: {ret_a[:48]}")
    ok_b, ret_b = g("__B_NIL")
    check("guarded_form_survives", ok_b == "true" and ret_b == "true",
          f"not (old and old.quarantined) 正常求值  [ok={ok_b!r} ret={ret_b!r}]")
    ok_a2, _ = g("__A_OLD")
    ok_b2, ret_b2 = g("__B_OLD")
    check("guarded_form_same_when_old_exists",
          ok_a2 == "true" and ok_b2 == "true" and ret_b2 == "true",
          "old 存在时两种写法等价（守卫不改变语义）")

    # 源码必须用的是 B，且所有 old. 引用都要有守卫
    r = RUNTIME.read_text(encoding="utf-8")
    g = (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8")
    check("source_uses_guarded_form",
          "if old and old.quarantined then" in g
          and "not old.quarantined" not in r,
          "nil 守卫在 take_gate（纯函数）里，runtime 不再内联该判断")
    # 凡是 old. 的引用，要么同行有 `old and` 守卫，要么出现在
    # `tracked[m.id]=old`（保证 old 非 nil）之后。
    ensure_line = next((i for i, ln in enumerate(r.split("\n"), 1)
                        if "tracked[m.id]=old" in ln), 0)
    bad = []
    for i, ln in enumerate(r.split("\n"), 1):
        if "old." in ln and "old and" not in ln and "--" not in ln.split("old.")[0]:
            if i < ensure_line:
                bad.append((i, ln.strip()[:60]))
    check("no_unguarded_old_index", not bad,
          f"无守卫的 old. 引用: {bad}" if bad else "所有 old. 引用都有守卫或在其后")
    # take_gate 里的 old 来自函数参数，可能为 nil —— 必须**先赋给局部变量再判空**，
    # 不得直接 old.field。这正是 2026-09-27 那次 attempt to index nil 的形态。
    check("gate_localises_old_before_use",
          "local old=o.old" in g,
          "take_gate 先把 o.old 收进局部变量，再统一判空")
    gate_bad = [ln.strip()[:60] for ln in g.split("\n")
                if re.search(r"(?<!local )(?<!o\.)\bold\.[a-z]", ln)
                and "old and" not in ln and not ln.strip().startswith("--")]
    check("gate_no_unguarded_old_field", not gate_bad,
          f"take_gate 里 old.<field> 都在判空之后: {gate_bad}" if gate_bad
          else "take_gate 的 old 访问全部先判空")


# 2026-09-27 第二轮：**"标记虫洞后时灵时不灵"的真正根因**（不是竞争态，是我上一轮找错了）。
# native_ping:observe() 的收尾曾是无条件的 `if not ok then memory:reset() end`：
# 任何一次读取失败都把全部标记记忆清空。而 `local Ping creator unavailable`
# 在实机里是几百帧连续失败 —— 节奏变成"记住 → 下一帧抹掉 → 再记住 → 再抹掉"，
# G-60 永远等不到一个稳定的 structure_mark。
PING_MEMORY = r"""
-- 模拟 Memory 的最小行为：只在 update 时记住 mark，reset 时全清
local function new_memory()
    local history = {}
    return {
        reset = function() history = {} end,
        update = function(observation, valid)
            for _, m in ipairs(observation.marks) do
                if valid(m) then history[m.id] = m end
            end
            for id, m in pairs(history) do if not valid(m) then history[id] = nil end end
            local top
            for _, m in pairs(history) do top = m end
            return top
        end,
        count = function() local n = 0 for _ in pairs(history) do n = n + 1 end return n end,
    }
end
-- 上游写法：失败即清空
local function upstream(mem, last)
    local ok = false            -- 这一帧读取失败（Ping creator 读不到）
    if not ok then mem.reset(); return nil end
    return last
end
-- 现在写法：失败保留，连续失败到上限才真正清空
local function fixed(mem, last)
    local failed_frames = 0
    return function()
        local ok = false
        if not ok then
            failed_frames = failed_frames + 1
            if failed_frames >= 240 then mem.reset(); last = nil end
            return last
        end
        failed_frames = 0
        return last
    end
end

local mark = {id = 528, identity = 'abc'}
local function run(mode)
    local mem = new_memory()
    mem.update({marks = {mark}}, function() return true end)   -- 成功帧：记住了
    local after_ok = mem.count()
    local last = mark
    if mode == 'upstream' then
        upstream(mem, last)                                     -- 1 帧瞬时失败
        return after_ok, mem.count()
    end
    local step = fixed(mem, mark)
    for _ = 1, 239 do step() end                                -- 239 帧瞬时失败
    local at_239 = mem.count()
    step()                                                      -- 第 240 帧 -> 才清空
    return after_ok, mem.count(), at_239
end
__UP_OK, __UP_AFTER = run('upstream')
__FX_OK, __FX_AFTER, __FX_239 = run('fixed')
"""


def test_ping_memory_persistence(rt):
    print()
    print("=== ④ 真跑复现：瞬时读取失败不该清空标记记忆 ===")
    rt.execute(PING_MEMORY)
    up_ok, up_after = rt.eval("__UP_OK"), rt.eval("__UP_AFTER")
    check("upstream_wipes_memory_on_transient_failure",
          up_ok == 1 and up_after == 0,
          f"上游：记住 {up_ok} 个 -> 一帧瞬时失败后剩 {up_after} 个（记忆被抹掉）")
    fx_ok, fx_239, fx_after = rt.eval("__FX_OK"), rt.eval("__FX_239"), rt.eval("__FX_AFTER")
    check("fixed_keeps_memory_through_transient_failure",
          fx_ok == 1 and fx_239 == 1,
          f"修复后：239 帧连续失败仍保留 {fx_239} 个标记")
    check("fixed_resets_only_after_limit", fx_after == 0,
          "连续失败到上限(240帧)才真正清空 —— 真漂移不会永久喂残值")

    p = (ROOT / "src/g60" / "native_ping.lua").read_text(encoding="utf-8")
    check("ping_no_unconditional_reset",
          "if not ok then memory:reset();return nil,tostring(result) end" not in p,
          "上游那句无条件清空已移除")
    check("ping_reset_limit_present", "FAILURE_RESET_LIMIT" in p,
          "有连续失败上限")
    # 直接赋值（不是 `if result then`）：观察成功却没有标记时也必须同步清掉，
    # 否则会把上个场景的虫洞当当前标记继续喂给 priority。
    check("ping_keeps_last_selected",
          "last_selected" in p and "last_selected=result" in p
          and "if result then last_selected=result end" not in p,
          "失败帧返回上一次成功选中的标记；无标记时同步清空")
    check("ping_forget_clears_stale",
          "if last_selected and last_selected.identity==identity then last_selected=nil end" in p,
          "forget 掉的实体不再从 stale 引用里复活")
    r = RUNTIME.read_text(encoding="utf-8")
    check("ping_issue_deduped", "structure_issue_counts" in r,
          "structure_ping_unavailable 不再逐帧刷屏（实机几百条）")


# 连续两轮事故的共同点：**日志里看不出卡在哪一步**。
# 标记读到了却没接管时，日志只有 structure_mark ACCEPTED，之后一片空白 ——
# 既不知道有没有 G-60、也不知道 priority 段进没进。所以必须有链路诊断。
def test_link_diagnostics():
    print()
    print("=== ⑤ 链路诊断：静默失败必须可见 ===")
    r = RUNTIME.read_text(encoding="utf-8")
    check("link_diag_collected", "diag.state4=diag.state4+1" in r
          and "diag.eligible=diag.eligible+1" in r,
          "统计场上的 G-60（state4 / 可驱动）")
    check("link_diag_counts_gate", "diag.entered=diag.entered+1" in r
          and "diag.locked=diag.locked+1" in r,
          "统计 priority 段进入次数与锁定次数")
    check("link_diag_emitted_on_change",
          "if status~=last_link_status then" in r and "env.emit(status)" in r,
          "只在状态变化时打一行（不逐帧刷屏）")
    for field in ("mark=", "g60=", "eligible=", "entered=", "locked=",
                  "held=", "quarantined="):
        check("link_diag_field_" + field.rstrip("="), field in r, f"输出 {field}")
    # state 停留帧数 + 是否见过 state-4：用来区分"刚扔还在起飞"和"长期卡在 state-3"
    check("link_diag_state_age", "state_age[fp]" in r and "state_key[fp]" in r,
          "记录每个 G-60 在当前 state 停留的帧数")
    check("link_diag_saw_state4", "saw_state4" in r and ";saw4=" in r,
          "记录是否曾见过 state-4（可接管状态）")


# ★★ 2026-09-28 真正的根因（前几轮全找错了地方）★★
# 到达判定 `arrived = 水平<=radius 且 dz<=0 且 dz>=-depth` 是给**泰坦**标定的：
# 泰坦是高目标，seeker 俯冲到它身下才攻击。虫洞在地上，G-60 绕飞时**一直在洞口上方**
# ⇒ dz 恒为正 ⇒ `dz<=0` 永远不成立 ⇒ G-60 在洞口绕 250 帧也从不引爆。
#
# 实机日志（target=529）5 个采样点，两个条件互斥：
#   水平 1.393 / dz +1.078   水平够，但在上方  ✗
#   水平 1.445 / dz +1.016   水平够，但在上方  ✗
#   水平 1.790 / dz -0.034   高度够，水平超 1.75 ✗
#   水平 2.221 / dz -0.478   两项都超        ✗
#   水平 1.816 / dz +0.501   在上方          ✗
ARRIVAL_SAMPLES = [
    (-62.738689422607, -264.93948364258, 4.6258335113525),
    (-61.762714385986, -264.54791259766, 4.5633344650269),
    (-62.910301208496, -267.41494750977, 3.5133049488068),
    (-59.618507385254, -265.74850463867, 3.0695669651031),
    (-63.502605438232, -265.29373168945, 4.0489649772644),
]
ARRIVAL_GOAL = (-61.82581111719, -265.99110013574, 3.5474852725013)

ARRIVAL_LUA = r"""
-- 与 src/g60/arrival_policy.lua 的 region 分支同构
local function arrived(own, goal, region)
    local dx, dy, dz = own[1]-goal[1], own[2]-goal[2], own[3]-goal[3]
    local above = region.above or 0
    return dx*dx+dy*dy <= region.radius*region.radius and dz <= above and dz >= -region.depth
end
local function count(samples, goal, region)
    local n = 0
    for _, own in ipairs(samples) do
        if arrived(own, goal, region) then n = n + 1 end
    end
    return n
end
__OLD = count(SAMPLES, GOAL, {radius=1.75, depth=0.8})                 -- 上游(above 缺省 0)
__NEW = count(SAMPLES, GOAL, {radius=2.0,  depth=1.2, above=1.2})      -- 本工程
__UPSTREAM_UNCHANGED = count(SAMPLES, GOAL, {radius=1.75, depth=0.8})
"""


def test_arrival_region_geometry(rt):
    print()
    print("=== ⑥ 实机几何反推：虫洞不能沿用泰坦的到达判定 ===")
    rt.execute("SAMPLES = " + lua_table(ARRIVAL_SAMPLES))
    # GOAL 是**单层**数组（三点坐标），SAMPLES 是数组的数组
    rt.execute("GOAL = {" + ", ".join(repr(v) for v in ARRIVAL_GOAL) + "}")
    rt.execute(ARRIVAL_LUA)
    old = rt.eval("__OLD")
    new = rt.eval("__NEW")
    check("upstream_region_never_fires", old == 0,
          f"上游判定在 {len(ARRIVAL_SAMPLES)} 个实机采样点上 0 次引爆 —— 这就是'绕圈不打'")
    check("retuned_region_fires", new >= 4,
          f"重新标定后 {new}/{len(ARRIVAL_SAMPLES)} 次可引爆")

    # above 缺省时必须与上游完全一致（不能影响泰坦）
    check("above_defaults_to_upstream", old == rt.eval("__UPSTREAM_UNCHANGED"),
          "不配 above 时行为与上游相同")

    p = (ROOT / "src/g60" / "arrival_policy.lua").read_text(encoding="utf-8")
    check("policy_has_above", "region.above or 0" in p and "dz<=above" in p,
          "到达判定支持在洞口上方引爆")
    check("upstream_dz_rule_gone",
          "arrived=dx*dx+dy*dy<=region.radius^2 and dz<=0 and dz>=-region.depth" not in p,
          "上游那句必须已在")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    check("entry_retunes_region",
          "titan_arrival_region={radius=2.0,depth=1.2,above=1.2}" in e,
          "到达区域按虫洞重新标定")


def lua_table(rows):
    return "{" + ", ".join(
        "{" + ", ".join(f"({v!r})" if v < 0 else repr(v) for v in row) + "}"
        for row in rows) + "}"


def test_diag_fields_initialized():
    """★ 2026-09-28 实机崩溃：
    frame_error;...: attempt to perform arithmetic on field 'state3' (a nil value)

    我加了 `diag.state3=diag.state3+1` 却没在 `local diag={...}` 里初始化 ⇒
    nil+1 ⇒ 每帧崩在 tick 开头，整帧作废。静态断言抓不到运行时 nil，
    所以这里直接**比对两侧**：凡被累加的字段，必须在初始化表里出现。
    """
    print()
    print("=== ⑥ 诊断计数器：累加字段必须在初始化表里 ===")
    r = RUNTIME.read_text(encoding="utf-8")
    m = re.search(r"local diag=\{([^}]*)\}", r)
    check("diag_init_found", m is not None, "找到 diag 初始化表")
    if not m:
        return
    inited = set(re.findall(r"(\w+)=0", m.group(1)))
    # 先剥掉行注释再扫 —— 否则会匹配到注释里举例用的 `diag.X=diag.X+1`（踩过）
    code = "\n".join(ln.split("--")[0] for ln in r.split("\n"))
    incremented = set(re.findall(r"diag\.(\w+)=diag\.\w+\+1", code))
    missing = sorted(incremented - inited)
    check("no_uninitialized_diag_field", not missing,
          f"累加 {sorted(incremented)}；初始化 {sorted(inited)}"
          if not missing else f"漏初始化: {missing}")
    # 反向：初始化了却没人用只是冗余，不算错，但列出来便于清理
    unused = sorted(inited - incremented)
    check("diag_fields_all_used", not unused,
          "全部字段都被用到" if not unused else f"未被累加: {unused}")


def test_state3_experiment():
    print()
    print("=== ⑦ state-3 接管实验：只设目标、绝不引爆、会自动退回 ===")
    p = PRIORITY.read_text(encoding="utf-8")
    r = RUNTIME.read_text(encoding="utf-8")
    f = (ROOT / "src/g60" / "priority_faults.lua").read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    a = (ROOT / "src/g60" / "native_arrival.lua").read_text(encoding="utf-8")
    t = TITAN.read_text(encoding="utf-8")

    # (1) 开关默认关：不配 allow_state3 时行为与原来完全一致
    check("state3_default_off", "M.ALLOW_STATE3=false" in f,
          "模块默认关闭，必须显式打开")
    # ★ 早期接管两轮实验均失败（v1 实体模式 / v2 点目标模式），已关闭：
    #   v2 点目标写入完全成功（回读坐标一致、零 danger），但 G-60 依然停在
    #   state 3 长达 1200+ 帧 ⇒ 引擎在 state 3 的导航不读任何目标数据，
    #   state 3→4 由内部起飞流程触发。突破只能写内存（伪造 state 或逆向转移）。
    # ★ 开关必须关闭 —— 2026-09-28 11:00 实机回归的直接教训。
    #
    #   我上一轮加了"开关必须打开"的断言，理由是"改了逻辑忘开开关 = 交付死代码"。
    #   结果这条断言反过来逼我把一个**未经完整验证**的路径推上线：
    #   实机日志第 2 行 frame_error;pointer bound，随后 300+ 帧
    #   `entered=1; locked=0`，priority_locked / takeover_probe 一次都没出现
    #   ⇒ **完全无法接管**。
    #
    #   根因：early 路径在 state 2/3 就走 Search.capture，其内部 hash_index
    #   依赖 state-4 才就绪的结构，指针解引用失败。
    #
    #   ⇒ 教训：**"配置与实现同步"不等于"路径可用"。**
    #     断言不能用来强制启用未验证的功能，只能用来记录它的已知状态。
    check("early_takeover_disabled_after_pointer_bound",
          "allow_state3=false" in e,
          "早期接管已关闭（pointer bound 导致完全无法接管）")
    check("pointer_bound_incident_recorded",
          "pointer bound" in e and "locked=0" in e,
          "把这次回归的证据写进注释（防重蹈覆辙）")
    check("dead_code_incident_recorded",
          "死代码" in e and "entered=0" in e,
          "把'改了逻辑忘开开关'这次事故写进注释（防重蹈覆辙）")
    # ★ 观测侧的早期放宽必须与写入侧同源：只放宽 priority 而不观测，或反之，
    #   都会让链路在无人验证的 state 上运行。
    check("early_observation_gated_by_same_switch",
          "if env.allow_state3 then opts.allow_early_state=true end" in r,
          "Search.capture 的早期放宽与写入侧共用同一个开关")

    # ★ 观测失败熔断 —— 2026-09-28 11:00 实机回归的直接修复
    check("observe_fail_counter_declared",
          "local OBSERVE_FAIL_LIMIT=" in r and "local observe_fail={}" in r,
          "有独立的观测失败计数（不与 frame_errors 混用）")
    # 上限本身也要钉住：改成 999 等于关掉熔断（实测验证过断言有效性）
    m = re.search(r"local OBSERVE_FAIL_LIMIT=(\d+)", r)
    check("observe_fail_limit_is_sane",
          m is not None and 2 <= int(m.group(1)) <= 30,
          f"熔断上限={m.group(1) if m else '缺失'}（2~30 帧内放弃，"
          f"过大等于没有熔断）")
    check("observe_fail_counts_consecutive",
          "observe_fail[key]=(observe_fail[key] or 0)+1" in r,
          "仅在 good==false 时累加（成功即清零）")
    check("observe_fail_resets_on_success",
          "observe_fail[m.id]=nil" in r,
          "成功一次即清零，避免偶发失败累积")
    check("observe_give_up_logged",
          "observe_give_up;entity=" in r,
          "放弃时必须打醒目日志（不能静默）")
    check("observe_failed_first_logged",
          "observe_failed;entity=" in r,
          "首次失败即打一行（含 detail），不再被去重埋掉")
    check("observe_give_up_releases_ref",
          re.search(r"observe_give_up;entity=.*?runner:release", r, re.S) is not None,
          "放弃时释放 observation 引用（防引用泄漏）")
    check("observe_fail_is_local_not_global",
          re.search(r"observe_give_up;entity=[^\n]*\n(?:[^\n]*\n){0,8}?[^\n]*self\.disabled", r) is None,
          "只放弃该实体，不得牵连全局停手")

    # ★ selection_resource 降级 —— 2026-09-28 11:08 实机事故
    #   11 次 priority_skipped;detail=selected resource unavailable;state=4
    #   ⇒ 标记 ACCEPTED 了、G-60 也到 state 4，却一次都锁不上。
    check("selection_resource_not_assert",
          re.search(r"^\s*assert\(current\.match\.selection_resource", r, re.M) is None,
          "不得用 assert 让只读元数据缺失阻断整个接管（行首调用，注释不算）")
    check("selection_resource_soft_flag",
          "resource_unknown=sel_res==nil" in r,
          "标记为 resource_unknown（下游据此保守处理）")
    check("selection_resource_warned_once",
          "selection_resource_unknown;entity=" in r
          and "selection_resource_warned" in r,
          "首次出现打一行日志，不逐帧刷屏")
    # 下游必须真的把它当"不可信"，而不是当普通资源继续用
    # 2026-09-29：profile 查找顺序已改为"泰坦优先"（原为 weakpoint 第一），
    # 所以这里只钉**真正的不变量** —— profile 为 nil 时必须 fail-closed。
    check("titan_treats_unknown_resource_as_untrusted",
          "local profile=resource and (resource==env.titan_profile.resource" in t
          and "assert(fresh or (previous and (owned_point or c.selection.cleared))"
          in t,
          "resource=nil → fresh=false → 仍要求 owned_point/cleared 才继续（安全属性不变）")
    # 早期几何不再臆测：必须先打实测距离
    check("no_guessed_orbit_geometry",
          "环绕半径" not in p.split("early_state=")[1][:3000] or "臆测" in p,
          "早期几何不得凭 orbit 参数猜测，须以 early_probe 实测为准")
    check("early_probe_emitted",
          "early_probe;entity=" in p and "probe_bucket" in p,
          "打出去重后的真实距离，供下一轮标定")

    # (2) priority 的 state-4 断言放宽到 2/3（state 1 不碰），但只在开关打开时
    check("priority_allows_early_when_enabled",
          "(L.u32(record,8)==2 or L.u32(record,8)==3)" in p,
          "早期 state(2/3) 只在开关打开时放行")
    check("state4_still_required_normally",
          "L.u32(record,8)==4 or (env.allow_state3" in p,
          "state==4 仍是默认路径")
    # ★ 实机教训：只认 state==3 是无效的 —— G-60 是 1→2→4 一闪而过，采不到 3
    check("early_covers_state2",
          re.search(r"\(m\.state==2 or m\.state==3\)", r) is not None,
          "覆盖 state 2（否则实验没机会跑）")
    check("early_has_min_age", "EARLY_MIN_AGE" in r
          and "(state_age[early_fp] or 0)>=EARLY_MIN_AGE" in r,
          "至少飞够一定帧数才碰（刚出膛风险最高）")

    # (3) titan 航点仍要求 state 4（movement 结构风险）；
    #     arrival 放宽到 early_drive —— 这是"无敌人也能炸"的核心通道
    check("state3_no_titan_waypoint",
          "if (not abandoned) and m.state==4" in r,
          "titan 航点仍要求 state 4")
    check("arrival_allows_early_drive",
          "can_guide=(m.state==4 or early_drive),early=early_drive}" in r
          and "if not o.can_guide then" in
          (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8"),
          "arrival 门控走 TakeGate.decide_guidance，且早期驱动在其 can_guide 内放行")
    check("arrival_early_uses_titan_region",
          "region=env.titan_arrival_region,early=true" in r,
          "早期引爆用与 titan 相同的到达区域（vanilla 的 0.8m 对虫洞太小）")
    check("arrival_early_no_permanent_disable",
          "if mutated and not (options and options.early) then disabled=true end" in a,
          "早期失败不计入 arrival 永久禁用（熔断归 state3_danger 管）")

    # (4) 自毁保护：flight timer 被动就永久退回，不杀整个 mod
    check("state3_danger_set", "'priority behavior or flight timer changed'" in f,
          "计时器变化列为 state-3 危险信号")
    check("state3_self_disable", "state3_blocked=true" in r,
          "观测到危险就永久禁用 state-3 路径")
    check("state3_disable_is_not_global",
          re.search(r"state3_blocked=true\s*\n\s*env\.emit", r) is not None,
          "只退回 state-4-only，不让整个 mod 停手")
    # ★ 分水岭证据：我们从不直接改 state，所以"设目标后 G-60 出现在 state 4"
    #   就证明引擎确实被我们的 selection 推进了。没有这条 = 引擎不理我们。
    check("early_promotion_evidence", "state3_driven[m.id]=true" in r
          and "'early_promoted;entity='" in r,
          "记录早期设目标后是否真的推进到 state 4（分水岭证据）")
    # 自毁要连续几次才触发，避免单次抖动误关
    check("state3_danger_needs_repeats", "STATE3_DANGER_LIMIT" in r
          and "state3_danger=state3_danger+1" in r,
          "连续 N 次危险信号才退回（单次抖动不误关）")


def test_geometry_probe(rt):
    print()
    print("=== ⑧ 真跑 geometry：接管时机距离计算（诊断的基础）===")
    G = load_module(GEOMETRY, "geometry", rt)
    check("geometry_loads", G is not None, "模块可加载（零 ffi，可在测试环境跑）")

    # 12 字节 float buffer → Lua string.char 表达式。
    # ★ 不要用 hex 字面量：字节值 0x5c（反斜杠）会被 Lua 当成转义起始符，
    #   实测 entity 892 的坐标恰好含 0x5c，解出来的长度对了但内容全错。
    def buf(x, y, z):
        import struct
        return "string.char(" + ",".join(str(b) for b in struct.pack("<fff", x, y, z)) + ")"

    # 1) 正常解码：实机日志里的真实坐标（entity 892 titan_started 时刻）
    own = buf(-151.36169433594, -9.1316967010498, 5.8255758285522)
    rt.execute("OWN = " + own)
    rt.execute("""
        local G = require('g60.geometry')
        __o = G.decode(OWN)
        __ox, __oy, __oz = __o[1], __o[2], __o[3]
        __g = G.gap({__ox, __oy, __oz}, {-143.01410490977, 4.4104935868948, 3.8936372995377})
        __gh, __gdz, __gf = __g.horiz, __g.dz, __g.flat
        __s = G.describe(__g)
    """)
    o = (rt.eval("__ox"), rt.eval("__oy"), rt.eval("__oz"))
    check("decode_x", abs(o[0] - (-151.36169433594)) < 1e-3, f"x={o[0]}")
    check("decode_y", abs(o[1] - (-9.1316967010498)) < 1e-3, f"y={o[1]}")
    check("decode_z", abs(o[2] - 5.8255758285522) < 1e-3, f"z={o[2]}")

    g = (rt.eval("__gh"), rt.eval("__gdz"), rt.eval("__gf"))
    # 实机算得 horiz=15.91, dz=+1.93
    check("gap_horiz", abs(g[0] - 15.91) < 0.05, f"水平距离={g[0]:.2f}m（实机 15.91）")
    check("gap_dz", abs(g[1] - 1.93) < 0.05, f"高度差={g[1]:+.2f}m（实机 +1.93）")
    check("gap_flat_ge_horiz", g[2] >= g[0], "直线距离 >= 水平距离")

    # 2) 非法输入必须返回 nil（诊断代码绝不能影响主流程）
    rt.execute("""
        local G = require('g60.geometry')
        __nil_short = G.decode('abc')
        __nil_nan   = G.decode(OWN) ~= nil and G.gap(nil, {1,2,3}) or 'ok'
        __nil_gap   = G.gap(nil, {1,2,3})
        __nil_desc  = G.describe(nil)
    """)
    check("decode_rejects_short", rt.eval("__nil_short") is None, "短 buffer → nil")
    check("gap_rejects_nil", rt.eval("__nil_gap") is None, "缺坐标 → nil")
    # lupa 把 Lua 字符串映射成 Python bytes/str（取决于版本），空值有多种表示
    empty = rt.eval("__nil_desc")
    check("describe_nil_is_empty", empty in ("", b"", None),
          f"nil → 空串（得到 {empty!r}）")

    # 3) describe 输出必须含三个字段
    s = rt.eval("__s")
    if isinstance(s, bytes):
        s = s.decode("utf-8", "replace")
    for field in ("horiz=", "dz=", "flat="):
        check("describe_has_" + field.rstrip("="), field in s, f"输出 {field}")

    # 4) ★ 覆盖盲区声明必须在文件里（防止有人误以为这被 195 个测试覆盖）
    gsrc = GEOMETRY.read_text(encoding="utf-8")
    check("geometry_declares_coverage_gap",
          "覆盖盲区" in gsrc and "lupa" in gsrc,
          "自述覆盖边界：不谎称被全量测试覆盖")
    # 5) 不得自己读内存（避免复制 hash_index 那种易错逻辑）
    check("geometry_never_reads_memory",
          "require('ffi')" not in gsrc and "0x3326508" not in gsrc,
          "不自己读内存：坐标由 Search.capture 提供，避免重算哈希索引出错")


TAKE_GATE = ROOT / "src/g60" / "take_gate.lua"


def test_take_gate_pure_logic(rt):
    print()
    print("=== ⑩ 真跑 take_gate：接管门控判定（重构的核心收益）===")
    G = load_module(TAKE_GATE, "take_gate", rt)
    check("gate_loads", G is not None, "纯 Lua 模块可在测试环境加载（无 ffi）")

    def ev(name):
        """lupa 把 Lua 字符串映射成 bytes，统一解成 str。"""
        v = rt.eval(name)
        if isinstance(v, bytes):
            return v.decode("utf-8", "replace")
        return v

    def call(**kw):
        """在 Lua 内构造 options 表并调 decide/decide_guidance，返回 why 字段。"""
        parts = []
        for k, v in kw.items():
            if isinstance(v, bool):
                parts.append(f"{k}={'true' if v else 'false'}")
            elif isinstance(v, (int, float)):
                parts.append(f"{k}={v}")
            elif isinstance(v, str):
                parts.append(f"{k}='{v}'")
            elif v is None:
                parts.append(f"{k}=nil")
        expr = "{" + ",".join(parts) + "}"
        rt.execute("OPTS = " + expr)
        rt.execute("""
            local G = require('g60.take_gate')
            __r = G.decide(OPTS)
            __why = __r.why
            __drive = __r.drive
            __can_guide = __r.can_guide
            __can_detonate = __r.can_detonate
            __early = __r.early
        """)
        return (ev("__why"), rt.eval("__drive"), rt.eval("__can_guide"),
                rt.eval("__can_detonate"), rt.eval("__early"))

    # ---- 基线：state 4 + 有标记 ⇒ 全放行
    why, drive, can_guide, can_det, early = call(
        behavior_id=4, state=4, native_update_eligible=True, structure_mark="t")
    check("gate_state4_full_pass", drive is True and can_guide is True
          and can_det is True and early is False, f"state4 有标记 → 全放行（why={why}）")

    # ---- ★ 事故形态 1：old 为 nil（2026-09-27 attempt to index local 'old'）
    #   首次遇到这颗 G-60 时 old 就是 nil。必须用 pcall 断言"不抛错" ——
    #   只检查返回值的话，守卫被破坏时这条测试仍会 PASS（我第一版就犯了这个）。
    rt.execute("""
        local G = require('g60.take_gate')
        __ok,__r = pcall(G.decide, {behavior_id=4, state=4,
                                    native_update_eligible=true, structure_mark='t'})
    """)
    check("gate_old_nil_no_crash", rt.eval("__ok") is True,
          "★ old 为 nil 时 decide 不得抛错"
          "（否则整帧被 pcall 吞掉，表现为标记 ACCEPTED 却零接管）")
    if rt.eval("__ok") is True:
        check("gate_old_nil_still_drives", rt.eval("__r").drive is True,
              "old 为 nil 但有标记时仍应正常驱动（首次遇到就走正常路径）")

    # ---- ★ 事故形态 2：quarantined 实体必须交回原生
    #   options.old 传一个 quarantined=true 的表（Lua 侧构造）
    rt.execute("""
        local G = require('g60.take_gate')
        __r = G.decide{behavior_id=4, state=4, native_update_eligible=true,
                       structure_mark='t', old={quarantined=true, lock={id=1}}}
        __why = __r.why
    """)
    check("gate_quarantined_hands_back", ev("__why") == "quarantined",
          f"quarantined 实体交回原生（why={ev("__why")}）")

    # ---- ★ 事故形态 3：state 3 必须被早期开关挡住
    #   打开早期接管曾导致 Search.capture `pointer bound` ⇒ 每帧失败
    why, drive, can_guide, can_det, _ = call(
        behavior_id=4, state=3, native_update_eligible=True, structure_mark="t")
    check("gate_state3_blocked_by_default",
          drive is False and why == "early_state_disabled",
          f"state 3 默认不驱动（why={why}）")

    # ---- ★ 安全属性：早期路径即使打开，也绝不允许 detonate
    rt.execute("""
        local G = require('g60.take_gate')
        __r = G.decide{behavior_id=4, state=3, native_update_eligible=true,
                       structure_mark='t', allow_early=true,
                       state_age=100, early_min_age=15}
        __drive = __r.drive
        __early = __r.early
        __can_guide = __r.can_guide
        __can_detonate = __r.can_detonate
    """)
    check("gate_early_never_detonates",
          rt.eval("__drive") is True and rt.eval("__early") is True
          and rt.eval("__can_detonate") is False,
          "★ 早期路径只准设目标，can_detonate 必须为 false"
          "（movement 结构在 state 2/3 可能未初始化）")
    check("gate_early_never_guides", rt.eval("__can_guide") is False,
          "★ 早期路径 can_guide 也为 false（航点写入同属高风险）")

    # ---- 飞稳门槛
    rt.execute("""
        local G = require('g60.take_gate')
        __r = G.decide{behavior_id=4, state=2, native_update_eligible=true,
                       structure_mark='t', allow_early=true,
                       state_age=5, early_min_age=15}
        __why = __r.why
    """)
    check("gate_respects_early_min_age", ev("__why") == "too_early_in_flight",
          f"刚出膛 5 帧(<15)不碰（why={ev("__why")}）")

    # ---- 无标记且无持有 ⇒ 完全不碰（裁剪 F：不影响敌人 G-60）
    why, drive, _, _, _ = call(behavior_id=4, state=4, native_update_eligible=True)
    check("gate_untouched_when_no_mark", drive is False
          and why == "no_mark_no_hold", f"无标记无持有 → 不碰（why={why}）")

    # ---- retired / 引擎接管
    why, drive, _, _, _ = call(behavior_id=4, state=4, native_update_eligible=True,
                               retired=True)
    check("gate_skips_retired", drive is False, f"已 retired → 不碰（why={why}）")
    why, drive, _, _, _ = call(behavior_id=4, state=4, native_update_eligible=False,
                               structure_mark="t")
    check("gate_skips_engine_owned", drive is False and why == "engine_owns_it",
          f"引擎已接管 → 不写（why={why}）")
    why, drive, _, _, _ = call(behavior_id=3, state=4, native_update_eligible=True)
    check("gate_skips_non_g60", drive is False and why == "not_g60",
          f"非 G-60 → 不碰（why={why}）")

    # ---- guidance 门控：必须真正持有
    rt.execute("""
        local G = require('g60.take_gate')
        local old = {lock={id=5}}
        __ok  = G.decide_guidance{drive=true, old=old, retired=false,
                                   can_guide=true, early=false}.run
        __nob = G.decide_guidance{drive=true, old={}, retired=false,
                                   can_guide=true, early=false}.why
        __g   = G.decide_guidance{drive=true, old=old, retired=false,
                                   can_guide=false, early=true}.why
    """)
    check("gate_guidance_needs_hold", rt.eval("__ok") is True,
          "持有锁定时 guidance 放行")
    check("gate_guidance_blocks_empty_hold", ev("__nob") == "holding_nothing",
          f"无持有时 guidance 拒绝（why={ev("__nob")}）")
    check("gate_guidance_needs_can_guide", ev("__g") == "state_not_guidable",
          f"非 can_guide 时 guidance 拒绝（why={ev("__g")}）")
def test_structure_whitelist(rt):
    print()
    print("=== ⑫ 白名单：非虫洞目标（尖啸巢穴等）绝不接管 ===")
    p = PRIORITY.read_text(encoding="utf-8")
    prof = (ROOT / "compat" / "structure_profiles.lua").read_text(encoding="utf-8")

    # ★ 用户要求（2026-09-28）：有生命值的尖啸巢穴这一类**不要接管，
    #   直接用游戏原生行为**。安全属性：profile 表 = 白名单，表外一律不碰。
    check("whitelist_is_explicit",
          "NOT_IN_WHITELIST" in p and "structure_not_taken_over" in p,
          "白名单拒绝是可观测的（不再静默 return）")
    check("whitelist_rejection_deduped",
          "M.rejected_targets=" in p and "not M.rejected_targets[structure_mark.id]" in p,
          "去重：同一 target 只打首条（逐帧刷屏会埋掉真错误）")
    # profile 为 nil 时必须在写任何内存之前 return
    check("whitelist_check_precedes_capture",
          p.index("NOT_IN_WHITELIST") < p.index("Context.capture"),
          "白名单检查在 Context.capture / 任何原生调用**之前**")

    # 表里必须只有虫洞 —— 混入任何其他 kind 都可能让 mod 去接管不该碰的东西
    kinds = set(re.findall(r'kind="(\w+)"', prof))
    check("whitelist_only_holes", kinds == {"structure_hole"},
          f"白名单仅含 structure_hole（实际：{sorted(kinds)}）")
    n = len(re.findall(r'profiles\["', prof))
    check("whitelist_size_known", n == 17, f"白名单 17 项（实际 {n}）")

    # 所有 profile 都必须显式 structure=true —— 这是"结构体"而非"活体"的标记
    n_true = len(re.findall(r"structure=true", prof))
    check("whitelist_all_flagged_structure",
          n_true == n, f"全部标了 structure=true（{n_true}/{n}）")

    # ★ 门控层也必须有同一道白名单（take_gate 是决策入口）
    gate = (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8")
    check("gate_requires_mark_but_not_target_kind",
          "o.structure_mark" in gate,
          "门控只要求\"有标记\"，具体接不接管由白名单在 priority 里裁决")


def test_no_lock_path_bypasses_whitelist():
    print()
    print("=== ⑭ ★ 越权修复：任何锁路径都不得绕过白名单 ===")
    p = PRIORITY.read_text(encoding="utf-8")
    code = "\n".join(l for l in p.splitlines() if not l.strip().startswith("--"))

    # ★★ 用户报"mod 还接管了除标记虫洞外的行为"（2026-09-29 实机）★★
    #
    # 根因：native_priority 里有第二个 sticky 分支
    #     if not chosen and previous and not previous.marked_structure then
    #         local row=e and {entity=e,raw=previous.raw,score=previous.score}
    #         if eligible(row,previous) then chosen,reason=row,'LOCKED' end
    #     end
    # 三重缺陷：
    #   1. **不查白名单** —— 其它路径都要过 structure_profiles[e.resource]，唯独它没有
    #   2. **自我永续**   —— row 没有 marked_structure 字段 → 存进 track 后是 nil
    #                        → 下一帧又落回本分支 → 无限期锁住
    #   3. 注释的前提"本 mod 从不保留敌人锁"是错的（第 376 行正是写 nil 的地方）
    check("enemy_lock_branch_removed",
          "previous and not previous.marked_structure" not in code,
          "★ 敌人锁分支已删除（它是唯一绕过白名单的锁路径）")
    n_locked = code.count("chosen,reason=row,'LOCKED'")
    check("single_lock_assignment", n_locked == 1,
          f"只有一处能产出 LOCKED（实际 {n_locked} 处）")

    # sticky 复用必须重新核对 resource（防实体 id 被复用）
    sticky = p[p.index("if previous and previous.marked_structure"):][:1600]
    check("sticky_rechecks_whitelist",
          "structure_profiles[e.resource]" in sticky,
          "★ sticky 复用每次都复核 resource（防 id 复用打到非虫洞）")
    check("sticky_logs_resource_reject",
          "RESOURCE_NOT_IN_WHITELIST" in sticky,
          "id 复用导致资源变化时打醒目日志")

    # track 的 marked_structure 必须 fail-closed
    check("track_marked_structure_fail_closed",
          "chosen.marked_structure and" in code
          and "marked_structure=chosen.marked_structure" not in code,
          "★ marked_structure 缺省时直接不返回 lock（不存 nil 锁）")

    # 反向断言：每个 chosen 赋值点之前必须有白名单检查。
    # 窗口取到**上一个 chosen 赋值点**为止（而不是固定字符数）——
    # 固定窗口会因代码里多几行注释就误判（我第一版取 2500 就误报了一次）。
    spots = [("sticky", "chosen,reason=row,'LOCKED'"),
             ("playermark", "chosen,reason=row,'PLAYER_MARK_STRUCTURE'")]
    for idx, (tag, spot) in enumerate(spots):
        i = code.index(spot)
        start = code.index(spots[idx - 1][1]) if idx else 0
        window = code[start:i]
        check(f"whitelist_before_{tag}",
              "structure_profiles" in window,
              f"{tag} 锁路径之前必须有白名单检查（窗口 {len(window)} 字符）")


def test_stuck_grenade_breakers():
    print()
    print("=== ⑯ ★ 卡住的 G-60 必须能退出（治'长时间盘旋'）===")
    r = RUNTIME.read_text(encoding="utf-8")
    ec = (ROOT / "src/g60" / "explosive_context.lua").read_text(encoding="utf-8")

    # ★★ 用户报"标记吐酸泰坦，G-60 长时间盘旋在泰坦底下"（2026-09-29 实机）★★
    #
    # 实机 entity=1257（target=1246，已被 entity=1256 炸掉）：
    #   titan_started;stage=around
    #   skipped;reason=: Titan selection changed     ← titan:step 失败
    #   arrival_skipped;detail=: explosion already requested
    #
    # 两条独立病根，都会让 G-60 挂到 30 秒寿命耗尽：
    #   1. titan:step 失败后 old.titan **保留** ⇒ 下帧再试 ⇒ 无限循环，且不写目标
    #   2. explosive「已触发」被 assert 当错误 ⇒ 永不标记 retired
    #      （语义其实是"这颗已经炸了"，是**完成**不是失败）
    check("guide_fail_breaker_exists",
          "GUIDE_FAIL_LIMIT" in r and "guide_fail[m.id]" in r
          and "guide_give_up" in r,
          "★ 引导失败熔断：同一 G-60 连续失败即放弃，不再逐帧重试")
    check("guide_fail_counter_resets_on_success",
          "if result then\n                            guide_fail[m.id]=nil" in r,
          "成功即清零（只对**连续**失败计数，不误伤偶发竞争）")
    # 只看熔断块本身（从 GUIDE_FAIL_LIMIT 的**使用处**到 guide_give_up），
    # 不要从声明处切 —— 那会跨进别的段落（我第一版就这么误判了一次）。
    _i = r.index("local n=(guide_fail[m.id] or 0)+1")
    _j = r.index("guide_give_up")
    block = r[_i:_j]
    check("guide_fail_is_per_entity",
          "self.disabled" not in block and "error(" not in block,
          "★ 只放弃该实体，不做全局禁用（2026-09-28 的教训）")

    # 第 2 条：爆炸已触发 = 完成
    check("arrival_already_exploded_handled",
          "arrival_already_exploded" in r
          and "EXPLOSIVE_ALREADY_TRIGGERED" in r,
          "★ 爆炸已触发 ⇒ 标记 retired，停止处理（不是错误，是完成）")
    # 字符串匹配的**安全性依赖**：被匹配的字面量必须真的在 explosive_context 里。
    # 若有人改了那边的文案，这条测试会先红，而不是等到实机才发现配对失效。
    for lit in ("explosion already requested", "secondary explosion pending"):
        check(f"explosive_literal_present_{lit.split()[0]}",
              lit in ec,
              f"被匹配的字面量 '{lit}' 确实存在于 explosive_context.lua")
        check(f"explosive_literal_matched_{lit.split()[0]}",
              lit in r,
              f"runtime 匹配了 '{lit}'")

    # ★★ 最关键的一条：arrival_skipped 有**两个**发射点，两处都必须收尾 ★★
    #   我第一版只改了 arrival 段（727 行），漏了 disposal 段（328 行）。
    #   实机 entity=1205 走的正是后者 ⇒ 修复完全没生效
    #   （日志里 arrival_already_exploded 计数为 0，而 arrival_skipped 有它）。
    #   ⇒ 断言"每个 arrival_skipped 发射点之后都必须出现 note_already_exploded"，
    #     这样以后新增发射点也会被强制要求处理。
    _emits = [i for i in range(len(r)) if r.startswith("env.emit('arrival_skipped;", i)]
    check("two_arrival_skipped_paths", len(_emits) == 2,
          f"arrival_skipped 恰好两个发射点（实际 {len(_emits)}）")
    for _k, _pos in enumerate(_emits):
        _follow = r[_pos:_pos + 700]
        check(f"arrival_skipped_{_k}_calls_helper",
              "note_already_exploded(why)" in _follow,
              f"第 {_k+1} 个 arrival_skipped 发射点之后必须收尾（★ 我第一版漏了一个）")
    check("helper_is_single_definition",
          r.count("local function note_already_exploded") == 1,
          "helper 只定义一次（两处共用，不再有重复判断）")

    # 回归防护：熔断不能误伤正常路径
    check("breaker_does_not_touch_retired_success_path",
          "if result.kind=='detonate' then\n                                    retired[m.id]=retired_key" in r
          or "retired[m.id]=retired_key" in r,
          "正常引爆仍然标记 retired（熔断是额外的收尾口，不是替代）")


def test_diagnostics_not_throttled():
    print()
    print("=== ⑰ ★ 关键诊断不得被日志节流丢掉 ===")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # ★ 实机教训（2026-09-29）：emit 在超过 60 行后会节流，只写"白名单"里的行。
    #   `arrival_already_exploded` 与 `guide_give_up` **不在白名单** ⇒ 被静默丢弃。
    #   我看到 arrival_skipped 出现、arrival_already_exploded 一条没有，
    #   据此判断"收尾逻辑没生效"，又白查一轮。
    #   **诊断被节流掉 = 诊断不存在。**
    #
    #   规则：凡是用来判断"某机制是否生效"的事件，都必须进白名单。
    for ev in ("arrival_already_exploded", "guide_give_up"):
        check(f"throttle_whitelists_{ev}",
              f"line:match('^{ev};')" in e,
              f"★ {ev} 必须常驻写日志（不得被节流）")
    # 已有的关键事件也不能被误删
    for ev in ("arrival_detonated", "arrival_retired", "titan_started",
               "titan_stage", "priority_locked", "structure_mark",
               "titan_released"):
        check(f"throttle_keeps_{ev}",
              f"line:match('^{ev};')" in e,
              f"{ev} 仍在白名单")

    # 反过来：节流本身必须仍然存在（否则日志会被刷爆）
    check("throttle_still_present",
          "lines>60 and lines%120~=0" in e and "then return end" in e,
          "节流机制本身保留（只是白名单补全）")


def test_takeover_scope_is_bughole_and_titan_only():
    print()
    print("=== ⑮ 接管范围：只有虫洞 + 吐酸泰坦 ===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    prof = (ROOT / "compat" / "titan_profile.lua").read_text(encoding="utf-8")
    weak = (ROOT / "compat" / "weakpoint_profiles.lua").read_text(encoding="utf-8")

    # ★ 2026-09-29 用户要求：接管虫洞 + 吐酸泰坦，其他交还游戏原生。
    #   根因：2026-09-27 的"裁剪 C"把 has_weakpoint 收窄成只认 structure_profiles，
    #   导致 titan_profile（resource=9e2e17f2ccccafdd）永远进不了接管路径。
    check("titan_profile_present",
          'resource="9e2e17f2ccccafdd"' in prof,
          "泰坦 profile 在位（实机日志里它被 RESOURCE_NOT_SUPPORTED 拒绝过，就是这个）")
    check("has_weakpoint_admits_titan",
          "resource==env.titan_profile.resource" in r,
          "★ has_weakpoint 已放行泰坦")
    check("has_weakpoint_has_toggle",
          "env.titan_enabled~=false" in r and "titan_enabled=state.titan_enabled" in e,
          "泰坦可一键关闭（titan_enabled=false 退回只打虫洞）")
    check("titan_toggle_default_on",
          re.search(r"titan_enabled=true", e) is not None,
          "默认开启")

    # ★ 关键安全属性：仍然**不认** weakpoint_profiles（穿刺者/龙蟑螂等其它敌人）
    check("weakpoint_profiles_still_excluded",
          "weakpoint_profiles[resource]" not in
          "\n".join(l for l in r.splitlines() if not l.strip().startswith("--")),
          "★ 不接管其它敌人（weakpoint_profiles 仍不在 has_weakpoint 里）")
    # ★ 表**非空**（登记了 7 个敌人弱点：head/rear/thorax/underside）——
    #   实机日志里 dcf8e74212fbee3b 就被 RESOURCE_NOT_SUPPORTED 拒过。
    #   安全性不靠"表是空的"，而靠 has_weakpoint 不认它。
    n_weak = len(re.findall(r'profiles\["[0-9a-f]+"\]', weak))
    check("weakpoint_targets_exist_but_unused", n_weak == 7,
          f"weakpoint_profiles 登记了 {n_weak} 个敌人，但接管范围不含它们")
    check("titan_aim_prefers_titan_profile",
          re.search(r"resource==env\.titan_profile\.resource and env\.titan_profile\s*\n"
                    r"\s*or \(env\.structure_profiles", r + (ROOT / "src/g60" / "native_titan_aim.lua").read_text(encoding="utf-8"))
          is not None,
          "★ titan_aim 的 profile 查找把泰坦放第一位（不依赖调用方传对）")
    check("designed_targets_only_off",
          "designed_targets_only=false" in e,
          "不按 rank 自动挑敌人（交还引擎）")
    check("enemy_priority_removed",
          "enemy_priority=REMOVED" in e,
          "敌人优先级功能已移除")
    check("unmarked_behavior_vanilla",
          "unmarked_behavior=VANILLA" in e,
          "未标记目标完全原生")

    # 泰坦段与 arrival 的关系：泰坦航点建立后 arrival 提前返回，
    # 所以 has_weakpoint 放行泰坦**不会**让泰坦掉进虫洞的到达区域。
    # ★ 虫洞优先（用户 2026-09-29 明确要求）
    # ★ 2026-09-29 修正：原为 `not structure_mark`，但那会**连带挡住泰坦自己的标记**
    #   （标记入口放行泰坦后 structure_mark 非 nil ⇒ 泰坦段永不运行）。
    #   改成只对**虫洞**标记让位。
    check("bughole_beats_titan",
          re.search(r"local mark_is_wormhole=structure_mark~=nil", r) is not None
          and re.search(r"and not retry_search and not mark_is_wormhole", r) is not None,
          "★ 虫洞标记优先于泰坦，但泰坦标记不阻止泰坦接管")
    # ★ 标记入口必须与 has_weakpoint 共用同一判定（这是本轮 bug 的根因）
    check("mark_entry_shares_claim_profile",
          r.count("claim_profile") >= 4
          and "allowed=function(resource) return claim_profile(resource)~=nil end" in r,
          "★ 标记入口用 claim_profile（收敛成唯一判定点）")
    check("claim_profile_is_single_source",
          r.count("local function claim_profile(resource)") == 1,
          "claim_profile 只定义一次")
    check("titan_point_short_circuits_arrival",
          r.index("if titan_point then return {kind='guide'} end")
          < r.index("if has_weakpoint(m.selection_resource) then target=nil end"),
          "★ 泰坦点已建立时 arrival 提前返回（不会被虫洞到达区域误伤）")


def main():
    rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    test_fault_classification(rt)
    test_reservation_release(rt)
    test_nil_guard(rt)
    test_ping_memory_persistence(rt)
    test_arrival_region_geometry(rt)
    test_diag_fields_initialized()
    test_state3_experiment()
    test_geometry_probe(rt)
    test_take_gate_pure_logic(rt)
    test_structure_whitelist(rt)
    test_no_lock_path_bypasses_whitelist()
    test_takeover_scope_is_bughole_and_titan_only()
    test_diagnostics_not_throttled()
    test_stuck_grenade_breakers()
    test_link_diagnostics()
    test_priority_wiring()

    print()
    if failures:
        print(f"RESULT: {checks - len(failures)} passed; {len(failures)} failed")
        print("failed: " + ", ".join(failures))
        return 1
    print(f"RESULT: ALL PASS ({checks} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
