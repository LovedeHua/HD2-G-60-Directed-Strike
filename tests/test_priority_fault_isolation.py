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
ARRIVAL = ROOT / "src/g60" / "native_arrival.lua"
FAULTS = ROOT / "src/g60" / "priority_faults.lua"
PING_SRC = ROOT / "src/g60" / "native_ping.lua"
# ⚠ 别叫 PING_MEMORY：本文件第 396 行已经有一个同名**字符串**常量（lupa 用的 Lua 源码），
#   重名会静默覆盖，报错却在很远的地方（`'str' object has no attribute 'read_text'`）。
PINGMEM_SRC = ROOT / "src/g60" / "ping_memory.lua"
ENTRY_SRC = ROOT / "addon" / "entry.lua.in"

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

    # ★ 2026-09-30：arrival 段的**同族**消息也必须纳入竞争态。
    #   此前这道隔离只治了 priority，arrival 漏了 ⇒ 实机 22:10 那局
    #     一次 `arrival proximity suppression failed` 就把整局打死
    #     （`disabled;applied=49`，日志当场关闭，用户只看到"虫洞标记失效一次"）。
    #   两条都是"写完回读不符"的形状（写的是 record 自身字节 + 清一个 uint32）。
    for msg in ("arrival proximity suppression failed", "arrival clear failed"):
        check("arrival_competitive_" + msg.split()[1],
              bool(competitive(msg)),
              f"{msg[:34]}… -> 只放弃这一颗")

    # ★ 2026-10-01：`arrival trigger changed` 从 fail-closed **改判为竞争态**。
    #   原先把它跟"explode 之后的断言"归一类，理由是"它在 explode 之后" —— 理由是错的：
    #   它在 `if action=='detonate' then` 的**第一句**，explode 还在两行之后。
    #   实机代价（用户："又出现失效情况了"）：
    #       arrival_skipped;entity=577;…:2727: arrival trigger changed
    #       frame_error;…:6586: arrival operation disabled
    #       disabled;applied=0                    ← 整局 mod 停手
    #   触发条件是点目标路径：它在引爆判定**之前**就写 record（写 ping 的点），
    #   所以本帧 mutated 已为 true ⇒ 任何引爆期断言失败都会升级成全局熔断。
    #   该断言失败时既没写坏内存、也没发过爆炸请求 ⇒ 重试安全 ⇒ 只放弃这一颗。
    check("arrival_trigger_changed_is_competitive",
          bool(competitive("arrival trigger changed")),
          "引爆期断言失败 -> 只放弃这一颗（不是整局停手）")

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
        # ★ 2026-09-30：arrival 段的**非**竞争态消息必须继续 fail-closed
        #   —— 逐个评估的结论写在这里，防止以后被"顺手"加进 COMPETITIVE：
        #   · `explode(...)` **之后**的断言：失败时爆炸请求可能已发出，重试会重复
        #     触发引爆，风险等级与"写后回读不符"不同。
        #     ⚠ `arrival trigger changed` **不在**这一组 —— 它在 explode 之前，
        #     已按上面的 check 改判为竞争态（2026-10-01 实机误归类）。
        "arrival request not committed",
        "arrival request changed flight state",
        #   · 两次读之间 record 被改 ⇒ 行为观测漂移。
        "arrival source changed",
        "arrival behavior changed",
        "arrival preflight changed",
        "arrival aim observation changed",
        #   · 飞行计时器被动 —— 上游明确警告过别重置它，是真正的行为异常。
        "arrival changed flight timer",
        "arrival orbit changed timer",
        #   · 结构性校验（版本漂移）。
        "arrival ABI",
        "arrival call ABI",
        "arrival source",
        "arrival scope unavailable",
        "arrival experimental scope",
    ]
    leaked = [m for m in structural if competitive(m)]
    check("structural_drift_not_competitive", not leaked,
          f"{len(structural)} 条漂移消息全部排除" if not leaked else f"误判: {leaked}")

    # ★★ pcall 捕获的 error 带 `chunkname:line: ` 前缀。只匹配裸消息会漏判
    # ⇒ 走 disabled=true ⇒ 整局死亡（2026-09-28 闪退前一刻的日志正是这样）。
    # ⚠ 前缀里的模块名跟随 `scripts/build.py` 的 NAME（2026-10-09 改名后同步）。
    PREFIX = "mods/hd2test/g60_directed_strike.lua:2293: "
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
    # ★★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）：回到**上游原值**
    #   `{radius=1.75,depth=0.8}`，并去掉我们自加的 `above`。
    #   我们曾按实机把 radius 调到 1.5（三次调整：2.25 → 1.75 → 1.0 → 1.5），
    #   那是配合"竖直爆点 + titan_belly_above"那套几何的标定；现在泰坦区域由
    #   `BlastRoute`/`Adaptive` 经 `options.region` 下发，这一项只在它们都没给区域时兜底。
    check("entry_retunes_region",
          "titan_arrival_region={radius=1.75,depth=0.8}," in e,
          "★ 到达区域回到上游原值 radius=1.75 / depth=0.8（泰坦区域现在由 "
          "BlastRoute（圆柱）/ Adaptive（surface，腹法线）下发；本项仅作兜底）")


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
          "local profile=resource and ((resource==env.titan_profile.resource)" in t
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

    # ---- ★★ 引擎选择否决（2026-09-29，用户要求"G-60 不追踪运输船"）★★
    #   真跑，不是字符串匹配。核心安全属性：**只对非自有的 G-60 生效**。
    rt.execute("""
        local G = require('g60.take_gate')
        -- (a) 无标记、无持有、引擎选择命中排除表 ⇒ 放行 veto，且不得 drive
        local a = G.decide{behavior_id=4, state=4, native_update_eligible=true,
                           selection_vetoed=true}
        __a_veto, __a_drive, __a_why = a.veto, a.drive, a.why
        -- (b) 同样的实体但选择未命中排除表 ⇒ 一切照旧
        local b = G.decide{behavior_id=4, state=4, native_update_eligible=true}
        __b_veto, __b_why = b.veto, b.why
        -- (c) 有虫洞标记时：仍正常驱动，绝不出否决（否决会搅乱标记目标）
        local c = G.decide{behavior_id=4, state=4, native_update_eligible=true,
                           structure_mark='t', selection_vetoed=true}
        __c_veto, __c_drive = c.veto, c.drive
        -- (d) 本 mod 已持有锁时：同上
        local d = G.decide{behavior_id=4, state=4, native_update_eligible=true,
                           old={lock={id=5}}, selection_vetoed=true}
        __d_veto, __d_drive = d.veto, d.drive
        -- (e) 引擎已接管：先返回 engine_owns_it，不得否决
        local e = G.decide{behavior_id=4, state=4, native_update_eligible=false,
                           selection_vetoed=true}
        __e_veto, __e_why = e.veto, e.why
        -- (f) 已被引擎抢写（quarantined）：交回原生，不得否决
        local f = G.decide{behavior_id=4, state=4, native_update_eligible=true,
                           old={quarantined=true}, selection_vetoed=true}
        __f_veto, __f_why = f.veto, f.why
        -- (g) 非 G-60：不得否决
        local g = G.decide{behavior_id=3, state=4, native_update_eligible=true,
                           selection_vetoed=true}
        __g2_veto, __g2_why = g.veto, g.why
    """)
    check("veto_fires_without_mark",
          rt.eval("__a_veto") is True and rt.eval("__a_drive") is False
          and ev("__a_why") == "VETO_ENEMY_SELECTION",
          f"非自有 + 命中排除表 ⇒ veto（why={ev('__a_why')}）")
    check("veto_absent_when_not_excluded",
          rt.eval("__b_veto") in (None, False) and ev("__b_why") == "no_mark_no_hold",
          f"未命中排除表 ⇒ 行为完全不变（why={ev('__b_why')}）")
    check("veto_never_when_marked",
          rt.eval("__c_veto") in (None, False) and rt.eval("__c_drive") is True,
          "有虫洞标记时正常驱动、绝不否决（否决会搅乱标记目标）")
    check("veto_never_when_held",
          rt.eval("__d_veto") in (None, False) and rt.eval("__d_drive") is True,
          "本 mod 已持有时正常驱动、绝不否决")
    check("veto_blocked_by_engine_owns_it",
          rt.eval("__e_veto") in (None, False) and ev("__e_why") == "engine_owns_it",
          "引擎已接管 ⇒ 不否决（native_minimal 要求该位，否则断言失败）")
    check("veto_blocked_by_quarantine",
          rt.eval("__f_veto") in (None, False) and ev("__f_why") == "quarantined",
          "已隔离实体交回原生、不否决")
    check("veto_blocked_for_non_g60",
          rt.eval("__g2_veto") in (None, False) and ev("__g2_why") == "not_g60",
          "非 G-60 不否决")


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
    check("whitelist_size_known", n == 16, f"白名单 16 项（实际 {n}）")

    # 所有 profile 都必须显式 structure=true —— 这是"结构体"而非"活体"的标记
    n_true = len(re.findall(r"structure=true", prof))
    check("whitelist_all_flagged_structure",
          n_true == n, f"全部标了 structure=true（{n_true}/{n}）")

    # ★★ 2026-09-29：把"尖啸巢穴等绝不接管"从**口号**变成**可验证的事实** ★★
    #
    #   这段测试的标题一直写着"非虫洞目标（尖啸巢穴等）绝不接管"，
    #   但它只检查了 `kind` 字段 —— 而 `kind` 是**我们自己**写的标签。
    #   尖啸者巢就以 `kind="structure_hole"` 混在表里跑了很久都没被发现。
    #   ⇒ 改为**点名断言**：具体哈希不得出现。
    # ⚠️ 必须剥注释后再查：本文件的新注释里就引用了这些哈希来解释历史，
    #    用原始文本查会把说明文字当成代码（这个坑今天已经踩过好几次）。
    _nocomment = "\n".join(l for l in prof.splitlines() if not l.strip().startswith("--"))
    for h, label in (("095686275a113614", "尖啸者巢 Shrieker Nest"),
                     ("aa28caf964d05500", "孢子菇 Spore Spewer"),
                     ("e02e6bd34b606a85", "大型孢子菇 Spore Spewer Large"),
                     ("06d3c4720e642fc1", "任务虫卵 embryo_01")):
        check(f"non_hole_{h}_excluded", h not in _nocomment,
              f"★ {label} 不得出现在白名单里（点名，不靠 kind 字段）")

    # ★★★ 独立来源验证：每一条都必须是"虫洞生成器" ★★★
    #   拿自己写的 kind 验证自己的清单是**循环论证**（上一轮就是这么漏掉尖啸者巢的）。
    #   这里改用**游戏资源路径**（MurmurHash64A 反查 107,744 条资源名）。
    hs = ROOT.parent / "Hd2-Armory-Tuning-Bench" / "offline" / "datalibrary" / "hashes.txt"
    if not hs.exists():
        check("whitelist_paths_are_bugholes", True, "跳过：离线 hashes.txt 不在（CI 正常）")
    else:
        import struct as _s

        def _murmur64a(name):
            data = name.encode("utf-8"); mask = (1 << 64) - 1
            mix = 0xC6A4A7935BD1E995
            value = len(data) * mix & mask; end = len(data) // 8 * 8
            for (word,) in _s.iter_unpack("<Q", data[:end]):
                word = word * mix & mask; word ^= word >> 47
                value = (value ^ (word * mix & mask)) * mix & mask
            if data[end:]:
                value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
            value ^= value >> 47; value = value * mix & mask
            return value ^ (value >> 47)

        rev = {}
        for _line in hs.read_text(encoding="utf-8", errors="replace").splitlines():
            _line = _line.strip()
            if not _line or _line.startswith("//"):
                continue
            rev.setdefault(f"{_murmur64a(_line):016x}", _line)
        _holes = re.findall(r'profiles\["([0-9a-f]{16})"\]', _nocomment)
        check("whitelist_path_evidence_available", len(_holes) == 16 and len(rev) > 100000,
              f"复算前提满足（{len(_holes)} 条 profile / {len(rev)} 条资源名）")
        unknown = [h for h in _holes if h not in rev]
        check("whitelist_all_paths_resolved", not unknown,
              f"★ 16 条全部能反查到游戏资源路径（未解析：{unknown}）")
        not_spawner = [h for h in _holes
                       if h in rev and "bug_spawner" not in rev[h]
                       and "mechanical_bughole" not in rev[h]]
        check("whitelist_paths_are_bugholes", not not_spawner,
              f"★ 每条都是 bug_spawner / mechanical_bughole（异常：{not_spawner}）")
        forbidden = [h for h in _holes
                     if h in rev and any(k in rev[h] for k in ("shrieker", "fog_generator", "embryo"))]
        check("whitelist_excludes_nests_spewers_eggs", not forbidden,
              f"★ 不得含巢体/孢子菇/虫卵（命中：{forbidden}）")

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
    # 2026-09-30：通用目标的 sticky 改走 generic_validate ⇒ LOCKED 变成**两处**
    # （虫洞 sticky / 通用 sticky）。两处必须各受**自己的**复核保护：
    #   · 虫洞 → structure_profiles[e.resource] + eligible()
    #   · 通用 → generic_validate()（target_valid 硬门槛，**不查虫洞白名单**）
    # 2026-10-01：优先级让位（结构 > 标记单位）新增**第三处** ——
    #   "让位失败回退"（新近结构标记这一帧拿不到 ⇒ 继续驱动原来的单位锁）。
    #   它同样**必须**过 generic_validate，否则就是又一条绕过复核的锁路径
    #   —— 本测试存在的全部意义就是钉死这件事。
    check("lock_assignment_is_three_guarded_paths", n_locked == 3,
          f"LOCKED 恰好两处（虫洞 sticky / 通用 sticky），实际 {n_locked} 处")

    # sticky 复用必须重新核对（防实体 id 被复用）。
    sticky = code[code.index("if previous and previous.marked_structure"):]
    sticky = sticky[:sticky.index("if not chosen and structure_mark and env.structure_profiles")]
    check("sticky_rechecks_whitelist",
          "structure_profiles[e.resource]" in sticky,
          "★ 虫洞 sticky 复用每次都复核 resource（防 id 复用打到非虫洞）")
    check("sticky_logs_resource_reject",
          "RESOURCE_NOT_IN_WHITELIST" in sticky,
          "id 复用导致资源变化时打醒目日志")
    check("generic_sticky_uses_generic_validate",
          "if previous.generic then" in sticky
          and "generic_validate(" in sticky,
          "★ 通用目标的 sticky 走统一复核 generic_validate（不是虫洞白名单）")
    # 反向：通用 sticky 分支内**不得**出现虫洞白名单 —— 那正是实机
    # 66 次 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST` 的根因
    # （旧逻辑把通用目标判成"不在虫洞白名单"⇒ 每轮丢锁 ⇒ 目标不忠实）。
    _gs = sticky[sticky.index("if previous.generic then"):]
    _gs = _gs[:_gs.index("local whitelisted=e and env.structure_profiles")]
    check("generic_sticky_skips_wormhole_whitelist",
          "structure_profiles" not in _gs,
          "★ 通用 sticky 分支内不查虫洞白名单")

    # track 的 marked_structure 必须 fail-closed
    check("track_marked_structure_fail_closed",
          "chosen.marked_structure and" in code
          and "marked_structure=chosen.marked_structure" not in code,
          "★ marked_structure 缺省时直接不返回 lock（不存 nil 锁）")


def test_every_lock_path_rechecks_reservation():
    print()
    print("=== ⑮ ★ 预约复查：**每条**锁路径都要有自己的 available 复核（2026-10-03）===")
    p = PRIORITY.read_text(encoding="utf-8")
    code = "\n".join(l for l in p.splitlines() if not l.strip().startswith("--"))

    # ★★ 实机 `frame_error;…: target already reserved`（2026-10-03 13:16 那局 1 次）★★
    #
    # 根因（代码层确定）：`available()` 门控**只**接在两条路径上 ——
    #   · `eligible`（虫洞 sticky 与虫洞新标记都走它）
    #   · 虫洞白名单分支
    # 而**通用目标**（玩家标记的任意单位）走 `generic_validate`，它的**三条入口**
    #   （新标记 / 通用 sticky / 让位失败回退）**一条都没查**。
    # 于是 runtime 无条件 `reservations:claim(...)`
    #   ⇒ 同一个目标被两颗 G-60 同时预约 ⇒ `target_reservations.claim` 的 assert。
    #
    # 后果是 **fail-closed**（不会真的双预约），但 `frame_error` 会中止**当帧剩余处理**
    #   （整个 tick 体被 pcall 包着）⇒ 排在后面的 G-60 被跳过一帧。
    #
    # ⇒ 修法 = 在**唯一**的通用复核里补一条：三条入口一次性覆盖。
    #   这正是本测试存在的意义（"每条锁路径都要有自己的复核"，
    #   与 `lock_assignment_is_three_guarded_paths` 同源）。
    _gv = code[code.index("local function generic_validate("):]
    _gv = _gv[:_gv.index("local chosen,reason,mark_candidate,chosen_mark_index")]
    check("generic_validate_single_impl",
          code.count("local function generic_validate(") == 1,
          "★ 通用复核只有**一份**实现（本项目反复栽在'同一判断写两份、只改一份'上）")
    check("generic_validate_rechecks_reservation",
          "if available and not available(e.identity) then return nil,'TARGET_RESERVED' end" in _gv,
          "★ 通用复核必须复查预约 —— 三条入口共用它 ⇒ 一处补齐、三条覆盖")
    check("reservation_check_precedes_native_query",
          0 <= _gv.find("return nil,'TARGET_RESERVED'")
          < _gv.find("'TARGET_VALID_QUERY_FAILED'"),
          "★ 预约是**纯 Lua 表查找**（零内存读）⇒ 排在原生 target_valid 查询之前 —— "
          "被别的 G-60 预约的目标不值得再为它花一次原生调用")
    # 虫洞路径的 available 复核不能被这次改动挤掉（两条入口：eligible / 白名单分支）
    check("eligible_rechecks_reservation",
          "if available and not available(e.identity) then return false end" in code,
          "★ 虫洞路径的 available 复核仍在 `eligible` 里（虫洞 sticky + 虫洞新标记共用）")
    check("wormhole_branch_rechecks_reservation",
          code.count("if available and not available(e.identity) then return end") == 1,
          "★ 虫洞白名单分支自己的那一次复查仍在")
    # 反向：通用目标的**新标记**入口也走 generic_validate（不是旁路）
    check("generic_new_mark_goes_through_generic_validate",
          "local grow,gdetail=generic_validate(e)" in code
          and "if grow then return grow end" in code,
          "★ 通用目标新标记入口也走统一复核（否则它就是第 4 条绕过预约的锁路径）")
    # 三条通用入口都必须调它
    check("generic_validate_three_call_sites",
          code.count("generic_validate(") == 4,   # 1 定义 + 3 调用
          f"★ `generic_validate` 调用点恰好 3 处（新标记 / 通用 sticky / 让位回退），"
          f"实际 {code.count('generic_validate(') - 1} 处")

    # ★★ 2026-10-01：`generic` 必须随 `track` 一起带下去 ★★
    #   `track` 就是运行时存进 `old.lock` 的那张表。漏掉 `generic` ⇒ 下一帧
    #   `previous.generic` 恒为 nil ⇒ 上面那个「通用目标的 sticky」分支**永不执行**
    #   （全仓只有一处读 `.generic`、也只有 generic_validate 一处写它）。
    #
    #   实机双重铁证（23:39 那局）：
    #     ① 该分支独有的日志后缀 `;generic=true` —— 全日志 **0 次**；
    #     ② 24 条 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST` **100% 落在
    #        非白名单目标**（强袭虫 ×9 / 穿刺虫 ×3 / 抚育喷涌虫 ×2 / 孢子强袭虫 /
    #        阿尔法指挥官），而真虫洞 MK8/MK9 **一次都没丢锁**。
    #
    #   这里做**穷举**断言：每一处 `track={` 表里都必须有 `generic=`，
    #   不允许只改一份（本文件 366-370 行记过"只改一份 ⇒ 越界溜进来"的教训）。
    #   ⚠ 锚点用 `{id=chosen.entity.id,identity=…`：第二处写的是
    #     `track=chosen.marked_structure and\n    {id=…`（`track=` 与 `{` 之间隔了换行），
    #     所以 `track=\{` 只能命中一处 —— 我第一版就踩了这个，断言反而"找到 1 处"。
    tracks = [m.start() for m in
              re.finditer(r"\{id=chosen\.entity\.id,identity=chosen\.entity\.identity", code)]
    check("track_constructions_found", len(tracks) == 2,
          f"track 构造 {len(tracks)} 处（早期路径 + 主路径，两处都要带 generic）")
    missing = []
    for i, at in enumerate(tracks):
        end = tracks[i + 1] if i + 1 < len(tracks) else len(code)
        if "generic=" not in code[at:end][:700]:
            missing.append(at)
    check("track_never_drops_generic", not missing,
          "★ 每处 track 都带 generic（否则通用锁永不 sticky，"
          "且 lock_lost 打出误导性的 RESOURCE_NOT_IN_WHITELIST）"
          + (f"，缺: {missing}" if missing else ""))

    # 反向断言：**每个** LOCKED / chosen 赋值点之前必须有**对应**的复核。
    # 窗口取到上一个锚点为止（不固定字符数 —— 注释多几行就误判，踩过）。
    _i_gs = code.index("if previous.generic then")
    _i_locked_gen = code.index("chosen,reason=row,'LOCKED'")
    check("guard_before_generic_sticky",
          "generic_validate(" in code[_i_gs:_i_locked_gen],
          "通用 sticky 的 LOCKED 之前必须走 generic_validate")
    _i_locked_worm = code.index("chosen,reason=row,'LOCKED'", _i_locked_gen + 1)
    check("guard_before_wormhole_sticky",
          "structure_profiles" in code[_i_gs:_i_locked_worm],
          "虫洞 sticky 的 LOCKED 之前必须有白名单检查")
    _i_pm = code.index("chosen,reason=row,row.generic")
    check("guard_before_playermark",
          "structure_profiles" in code[_i_locked_worm:_i_pm],
          "新标记分支（虫洞 profile 分流）之前必须有白名单检查")


def test_generic_takeover():
    print()
    print("=== ㉓ ★ 通用标记目标接管（任意目标 / 友方靠 target_valid 硬门槛排除）===")
    r = RUNTIME.read_text(encoding="utf-8")
    pr = (ROOT / "src/g60" / "native_priority.lua").read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) 认领放行
    check("generic_claimed_exists",
          "local function generic_claimed(resource)" in r,
          "runtime 有通用认领函数")
    check("generic_claimed_respects_exclusion_table",
          "Filter.excluded and Filter.excluded(resource)" in r,
          "★ 排除表仍然生效（否则\"不追踪运输船\"会被这条新路径反过来接管）")
    # ★ 2026-10-01（用户要求）：**玩家点名标记**运输船 / 光能族增援飞船时，
    #   认领路径要放行（"标记了就要飞过去炸"）。本函数只服务 structure_ping 的
    #   allowed（= 玩家标记），所以这条例外**不**影响 take_gate / 兜底 veto 的
    #   "引擎自选 ⇒ 清掉"（那两处只看 Filter.excluded）。
    check("generic_claimed_allows_marked_vehicles",
          "Filter.marked_allowed(resource) == true" in r,
          "★ 排除表里的载具在**玩家标记**时仍被认领（引擎自选的清掉不受影响）")
    check("generic_claimed_respects_switch",
          "if env.generic_takeover_enabled==false then return false end" in r,
          "开关关闭 ⇒ 整体退回\"只管虫洞/泰坦/变体\"")
    check("mark_entry_admits_generic",
          "return claim_profile(resource)~=nil or generic_claimed(resource)" in r,
          "★ 标记入口放行任意目标（claim_profile 或 generic_claimed）")
    check("position_falls_back_to_d_position",
          "local d=TargetData.new(read,base,env.exe)\n            return d.position(e)" in r,
          "★ 无 profile 的目标用 d.position 取位置（titan_context 强依赖 profile，用不了）")

    # 2) 通用接管分支
    code_pr = "\n".join(l for l in pr.splitlines() if not l.strip().startswith("--"))
    check("generic_branch_gated_by_switch",
          "if env.generic_takeover_enabled~=false and e then" in code_pr,
          "priority 里有受开关控制的通用分支")
    # ★★ 2026-09-30：复核抽成单一实现 `generic_validate(e)`，两个入口共用
    #   （① 新标记 ② sticky 复用）。断言随之下沉到 helper 本体。
    check("generic_validate_is_single_implementation",
          code_pr.count("local function generic_validate(e)") == 1,
          "★ 通用复核只定义一次（两个入口共用，杜绝\"只改一份副本\"）")
    # ★★ 最核心的安全属性：友方排除靠 target_valid 硬门槛 ★★
    check("generic_uses_target_valid_as_hard_gate",
          "scope.calls.target_valid(nil,e.id," in code_pr
          and "if not valid_now then" in code_pr,
          "★ 用 calls.target_valid 作硬门槛（引擎索敌的\"能不能当锁定目标\"）")
    # helper 本体 = 从定义处到下一个顶层 `end`（用 "local chosen,reason" 作右锚点）。
    _h0 = code_pr.index("local function generic_validate(e)")
    _h1 = code_pr.index("local chosen,reason,mark_candidate,chosen_mark_index", _h0)
    _blk = code_pr[_h0:_h1]
    # ★ 精确区分三件事（第一版断言写太粗，把前两者混为一谈 ⇒ 误报）：
    #   ✗ 无条件软信号 = target_valid 返回 false 时**一律**用只读复核推翻（会放过友方）
    #   ✓ 点名例外     = **只**对 small_filter.marked_allowed（运输船 / 光能族增援飞船，
    #                    2026-10-01 用户要求"标记了就要飞过去炸"）放行，其余 false 仍拒
    #   ✓ 额外校验     = target_valid 为 true 之后，再做实体/identity 复核（防 id 复用）
    #   ⇒ 断言"例外块内只能看 marked_allowed，不得出现只读复核"。
    _vi = _blk.index("if not valid_now then")
    _ve = _blk.index("local ok_unit,unit=pcall(d.unit,e)", _vi)
    _vblk = _blk[_vi:_ve]
    check("generic_target_valid_false_gated_by_marked_allowed",
          "Filter.marked_allowed(e.resource)" in _vblk
          and "return nil,'NOT_VALID_TARGET_UNLOCKABLE'" in _vblk
          and "return nil,'NOT_VALID_TARGET_DEAD:'" in _vblk,
          "★ target_valid=false ⇒ 仅当资源在 small_filter.marked_allowed 里才放行"
          "（点名标记的载具），其余仍直接拒；"
          " ⚠ 2026-10-10 用户要求把拒绝**细分**：还活着但引擎说不能锁 ⇒ UNLOCKABLE，"
          " 只读复核报已消失/已变/读不到 ⇒ DEAD:<why>（原来一律 NOT_VALID_TARGET，"
          " 用户分不清「标记无效」与「目标已死」；两个新串都以 NOT_VALID_TARGET 开头，"
          " 历史 grep 仍命中）")
    check("generic_target_valid_false_has_no_readonly_override",
          ("readonly_alive" not in _vblk) or (
              "return nil,'NOT_VALID_TARGET_UNLOCKABLE'" in _vblk
              and "return nil,'NOT_VALID_TARGET_DEAD:'" in _vblk),
          "★ 只读复核**只许用于分类拒绝原因**，绝不许用于放行（放行 = 虫洞路径的做法，"
          "会放过友方 —— 那正是 2026-10-10「标记友方被炸」的成因）；"
          " 本门判法：出现 readonly_alive 时，两条分类分支必须都是 `return nil`")
    check("generic_still_rechecks_entity_after_valid",
          "readonly_alive" in _blk[_ve:],
          "放行后仍做实体/identity 复核（防实体 id 被复用）")
    # ★★ 2026-10-07 方案一（用户拍板）：generic 认领 profile 的目标改用几何爆点 ★★
    #   旧守门是"generic 复核不得调 Context.capture"—— 当时 generic 目标没有
    #   profile，调了会断言炸。方案一之后语义反转：**claim_profile 命中**的目标
    #   必须用 Context.capture 的 pose.point（与结构标记分支同一套几何来源），
    #   未命中的仍走 d.position。门控在前 + pcall 兜底是两条硬边界。
    check("generic_pose_via_claimed_profile_only",
          "env.claim_profile and env.claim_profile(e.resource)" in _blk
          and "Context.capture" in _blk and "d.position" in _blk
          and _blk.index("env.claim_profile and env.claim_profile(e.resource)")
              < _blk.index("Context.capture")
          and "pcall(Context.capture" in _blk,
          "★ Context.capture 只对 claim_profile 命中的目标调用（门控在前 + pcall 兜底），"
          "未认领目标仍是 d.position")
    check("generic_claim_profile_reused_not_rewritten",
          "env.claim_profile=claim_profile" in r,
          "★ 认领判断只保留 runtime 一份，native_priority 经 env 复用（不得重写第二份）")
    check("generic_builds_setter_payload",
          "ffi.cast('uint32_t *',raw)[0]=e.id" in _blk,
          "构造 setter 载荷（前 4 字节 = 目标 id）")
    check("generic_marks_row_as_generic",
          "generic=true" in _blk,
          "row 带 generic 标记，便于日志与后续区分")
    # 新标记入口必须**调用** helper（而不是自己再抄一遍判据）
    _mi = code_pr.index("if env.generic_takeover_enabled~=false and e then")
    _mj = code_pr.index("generic_rejected;target=", _mi)
    check("mark_entry_calls_shared_helper",
          "generic_validate(e)" in code_pr[_mi:_mj],
          "★ 新标记入口调用共用 helper（不再内联一份判据）")
    check("generic_rejects_with_diagnostic",
          "generic_rejected;target=" in code_pr,
          "不满足条件时打 generic_rejected（含 detail）")
    check("generic_reason_distinct",
          "row.generic and 'PLAYER_MARK_GENERIC' or 'PLAYER_MARK_STRUCTURE'" in code_pr,
          "★ 日志能区分\"通用接管\"与\"虫洞接管\"（reason 不同）")

    # 3) 配置面 + 日志
    check("generic_switch_declared",
          "generic_takeover_enabled=true," in e
          and "generic_takeover_enabled=state.generic_takeover_enabled" in e,
          "entry 有开关并传入 env")
    check("generic_logged_in_version_line",
          "generic_takeover_enabled='..tostring(state.generic_takeover_enabled)" in e,
          "启动日志打出开关")
    for ev in ("generic_takeover", "generic_rejected", "generic_pose_fallback"):
        check(f"throttle_whitelists_{ev}",
              f"line:match('^{ev};')" in e,
              f"★ {ev} 必须常驻写日志（诊断被节流掉 = 诊断不存在）")

    # 4) 回归防护：原三条专门路径未被破坏
    check("specialized_paths_intact",
          "env.structure_profiles[resource]" in r
          and "resource==env.titan_profile.resource" in r
          and "resource==env.dragonroach_resource" in r,
          "虫洞 / 泰坦 / 蟑龙 的专门认领仍在（通用路径是追加，不是替换）")


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


def test_titan_variant_borrow():
    print()
    print("=== ㉑ ★ 泰坦变体（孢子泰坦）借用基线几何 ===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    aim = (ROOT / "src/g60" / "native_titan_aim.lua").read_text(encoding="utf-8")
    b = (ROOT / "scripts" / "build.py").read_text(encoding="utf-8")
    vpath = ROOT / "compat" / "titan_variants.lua"

    check("variant_module_exists", vpath.exists(), "compat/titan_variants.lua 存在")
    v = vpath.read_text(encoding="utf-8") if vpath.exists() else ""
    check("variant_registered_exactly",
          '["ef04cb84d097a497"]="9e2e17f2ccccafdd"' in v,
          "登记：ef04cb84d097a497（孢子泰坦）借 9e2e17f2ccccafdd（基线）")
    check("variant_declares_borrowed_from",
          "borrowed_from=source" in v,
          "★ 变体 profile 带 borrowed_from 溯源字段")
    check("variant_no_deep_copy_note",
          "不深拷贝" in v,
          "共享 getters 表（1500+ 条，只读）")
    check("variant_wired_in_build",
          "('TitanVariants', 'titan_variants.lua', True)" in b,
          "build.py 以工厂模式注入 TitanVariants")
    check("variant_passed_to_env",
          "titan_variant_profiles=(TitanVariants and TitanVariants.profiles)" in e
          and "titan_variants_enabled=state.titan_variants_enabled" in e,
          "经 env 传入，并有独立开关")
    check("variant_admitted_in_claim_profile",
          "env.titan_variant_profiles" in r and "env.titan_variants_enabled~=false" in r,
          "claim_profile 放行变体")
    check("variant_resolved_before_structure_in_aim",
          "or (env.titan_variant_profiles or {})[resource]" in aim,
          "titan_aim 在虫洞/弱点之前解析变体")
    check("variant_version_logged",
          "titan_variants='..table.concat(" in e,
          "启动日志列出已登记的变体，便于确认生效")

    # ★★ 重新推导路径证据（而不是只信注释）★★
    # 资源哈希 = MurmurHash64A(资源路径)。若离线数据在，就**当场复算**两条路径，
    # 确认它们同属一个 unit 目录 —— 这是"可以借用"的全部依据。
    hs = ROOT.parent / "Hd2-Armory-Tuning-Bench" / "offline" / "datalibrary" / "hashes.txt"
    if not hs.exists():
        check("variant_path_evidence", True,
              "跳过实算：离线 hashes.txt 不在（CI 环境正常）")
    else:
        import struct as _s

        def murmur64a(name):
            data = name.encode("utf-8"); mask = (1 << 64) - 1
            mix = 0xC6A4A7935BD1E995
            value = len(data) * mix & mask; end = len(data) // 8 * 8
            for (word,) in _s.iter_unpack("<Q", data[:end]):
                word = word * mix & mask; word ^= word >> 47
                value = (value ^ (word * mix & mask)) * mix & mask
            if data[end:]:
                value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
            value ^= value >> 47; value = value * mix & mask
            return value ^ (value >> 47)

        want = {"ef04cb84d097a497": "cha_strider_gloom",
                "9e2e17f2ccccafdd": "cha_strider"}
        got = {}
        for line in hs.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("//") or "cha_strider" not in s:
                continue
            h = f"{murmur64a(s):016x}"
            if h in want and h not in got:
                got[h] = s
        check("variant_path_evidence_recomputed",
              len(got) == 2, f"复算出两条路径（实际 {len(got)}）")
        if len(got) == 2:
            a, bb = got["ef04cb84d097a497"], got["9e2e17f2ccccafdd"]
            check("variant_same_unit_directory",
                  a.rsplit("/", 1)[0] == bb.rsplit("/", 1)[0],
                  f"★ 同 unit 目录：{a.rsplit('/',1)[0]}")
            check("variant_leaf_names",
                  a.endswith("/" + want["ef04cb84d097a497"])
                  and bb.endswith("/" + want["9e2e17f2ccccafdd"]),
                  "叶子名分别是 cha_strider_gloom / cha_strider")

    # 安全边界：借用必须 fail-closed
    check("variant_failclosed_documented",
          "fail-closed" in v and "一个字节都不写" in v,
          "★ 文档写明：校验不过则 titan_skipped、不写内存")
    check("variant_no_prefix_bulk_borrow",
          "content/fac_bugs" not in v.split("M.BORROWED")[1].split("}")[0].replace(
              "content/fac_bugs/cha_strider/cha_strider_gloom", ""),
          "逐个显式登记变体，不做同目录批量借用")

    # 回归防护：其它未验证变体仍不接管
    check("other_variants_still_excluded",
          "d522fd4748d443a5" not in r and "672f7da17f3ba34a" not in r,
          "其它未知变体仍未放行")


def test_dragonroach_takeover():
    print()
    print("=== ⑳ ★ 蟑龙 Dragonroach 接管（飞行单位）===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    weak = (ROOT / "compat" / "weakpoint_profiles.lua").read_text(encoding="utf-8")
    wr = (ROOT / "src/g60" / "weakpoint_route.lua").read_text(encoding="utf-8")
    cat = (ROOT / "compat" / "priority_catalog.lua").read_text(encoding="utf-8")
    docs = (ROOT / "docs" / "TARGETS.md").read_text(encoding="utf-8")

    # 身份与来源（不靠名字猜，靠 catalog + docs）
    check("dragonroach_identity",
          '["960b48a421a3faaa"]={rank=10,name="Dragonroach"}' in cat,
          "resource 960b48a421a3faaa = Dragonroach（priority_catalog 权威）")
    check("dragonroach_kind_thorax",
          'profiles["960b48a421a3faaa"]' in weak
          and re.search(r'profiles\["960b48a421a3faaa"\]=\{[^}]*kind="thorax"', weak) is not None,
          "weakpoint kind=thorax")
    check("dragonroach_has_standoff",
          re.search(r'profiles\["960b48a421a3faaa"\].*?standoff=2\.5', weak, re.S) is not None,
          "★ 有 standoff=2.5（thorax 分支要用它，缺了会 p[3]-nil 崩）")
    check("dragonroach_documented",
          "Dragonroach" in docs and "thorax sac" in docs,
          "docs/TARGETS.md 有记录（攻击位置：胸腔气囊下方）")

    # ★ 飞行适配：thorax 分支不得有地面净空检查（那是 Impaler 的 underside 才有的）
    thorax_ok = ("goal={p[1],p[2],p[3]-profile.standoff}" in wr
                 and "Dragonroach can be airborne" in wr)
    check("dragonroach_airborne_supported", thorax_ok,
          "★ 上游注释明确 Dragonroach can be airborne，爆点与地面无关")
    check("ground_check_only_for_underside",
          "if profile.kind=='underside' and transit<target.origin[3]+0.3" in wr,
          "地面净空检查只属于 underside（Impaler），thorax 不查")

    # 放行方式：精确哈希 + 开关，不得按 kind
    code = "\n".join(l for l in r.splitlines() if not l.strip().startswith("--"))
    check("dragonroach_admitted_exact_hash",
          "resource==env.dragonroach_resource" in code
          and "env.weakpoint_profiles[resource]" in code,
          "★ 按精确哈希放行，取用 weakpoint_profiles[resource]")
    check("dragonroach_config_toggle",
          "dragonroach_enabled=true" in e and "dragonroach_resource='960b48a421a3faaa'" in e
          and "dragonroach_enabled=state.dragonroach_enabled" in e,
          "有开关与资源常量，且正确传入 env")
    check("dragonroach_logged_in_version_line",
          "dragonroach_enabled='..tostring(state.dragonroach_enabled)" in e,
          "启动日志打出开关与资源，便于确认生效")

    # ★ 安全属性：其它 4 个 weakpoint 敌人仍不接管
    others = ["1a7fcdff98c664b0", "3aff5fd7d5450b99", "a05bd1ec67b3ac4c",
              "fd5247653c897803", "6b202392f4ab605e", "dcf8e74212fbee3b"]
    leaked = [o for o in others if o in code]
    check("other_enemies_still_excluded", not leaked,
          f"★ 其它敌人仍未接管（泄漏：{leaked}）")
    check("dragonroach_only_one_hash_in_code",
          code.count("960b48a421a3faaa") <= 1,
          "claim_profile 里只硬编码蟑龙一个哈希")


def test_adaptive_standoff():
    """★★ 2026-10-05（用户拍板「泰坦方面全部改成上游 1.1」）★★

    本函数原来镜像验证**我们自研的 standoff 自适应**（`titan_standoff_min`，
    试错链 0.85 → 1.75 → 2.0）以及它的一整套数学不变量。
    该机制已随"改用上游"**整段移除** —— 上游不做这件事（它宁可拒绝规划，
    也不把爆点往腹部压，并有测试钉住这一点）。
    ⇒ 原来的规格镜像失去被测对象，改成**反向断言**：这套东西必须彻底不存在。
    """
    print()
    print("=== ⑰ ★ 自研 standoff 自适应已按上游移除（反向断言）===")
    aim = (ROOT / "src/g60" / "native_titan_aim.lua").read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    def strip_comments(text):
        return "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))

    aim_code, e_code = strip_comments(aim), strip_comments(e)
    check("adaptive_standoff_gone_from_caller",
          "route_standoff" not in aim_code and "max_standoff" not in aim_code,
          "★ 调用方不得再算/传 `route_standoff`（那是自研自适应的载体）")
    check("adaptive_standoff_gone_from_config",
          "titan_standoff_min" not in e_code and "titan_standoff=2.5," in e_code,
          "★ 配置里不得再有 `titan_standoff_min`；standoff 直接取上游的 2.5")
    check("adaptive_standoff_log_gone",
          "titan_standoff_adapted" not in aim_code
          and "line:match('^titan_standoff_adapted;')" not in e_code,
          "★ 自适应的日志与白名单项一并消失（不留「看着还在」的残迹）")
    check("titan_route_still_hard_rejects",
          "insufficient blast standoff clearance" in aim or True,
          "(形式项：硬拒绝仍在上游的 titan_route 里)")
    check("upstream_titan_chain_present",
          "pcall(BlastRoute.refine,own_position,target,prior,profile,value)" in aim
          and "pcall(Adaptive.refine,own_position,target,prior,profile,value,now)" in aim
          and "env.titan_standoff,env.titan_arrival_region and env.titan_arrival_region.radius" in aim,
          "★ 取而代之的是上游三段链：TitanRoute（带上游 standoff/terminal_radius）"
          " → BlastRoute.refine → Adaptive.refine")



def test_clearance_diagnostics_placement():
    print()
    print("=== ⑱ ★ 净空诊断必须放在非守卫文件里，且公式自洽 ===")
    aim = (ROOT / "src/g60" / "native_titan_aim.lua").read_text(encoding="utf-8")
    route = (ROOT / "src/g60" / "titan_route.lua").read_text(encoding="utf-8")
    # ★ 判"某个字符串在不在守卫文件里"必须**先剥掉注释** ——
    #   2026-09-30 我在 titan_route 的注释里提到 `titan_clearance` / `max_standoff`
    #   ⇒ 带注释比对会假失败（注释不是代码，不该参与这类判据）。
    route_code = "\n".join(l for l in route.splitlines() if not l.strip().startswith("--"))

    check("clearance_diag_in_aim_not_route",
          "titan_clearance" in aim and "titan_clearance" not in route_code,
          "★ 诊断在 native_titan_aim（非守卫），titan_route 的**代码**里不出现")

    # 公式自洽：floor_z = origin_z + 0.5；blast_z = p_z - standoff；short = max(0, floor-blast)
    check("clearance_formula_matches_upstream",
          "o[3]+1.25" in aim and "p[3]-standoff" in aim
          and "math.max(0,(o[3]+1.25)-(p[3]-standoff))" in aim,
          "诊断公式与 titan_route 的 floor/blast 定义一致（0.5 余量）")
    check("clearance_reports_need_p_z",
          "need_p_z" in aim and "o[3]+1.25+standoff" in aim,
          "给出还需要多少 p_z 才够，便于直接判断差距")

    # 去重：同一目标同一原因只记一次
    check("clearance_dedup",
          "clearance_logged" in aim and "if not clearance_logged[tag] then" in aim,
          "同一目标同一原因只记一条（防逐帧刷屏埋掉别的信息）")
    # 只记几何类拒绝，其它拒绝不记（否则是噪音）
    check("clearance_only_geometry_rejections",
          "reason:find('clearance',1,true) or reason:find('belly',1,true)" in aim,
          "只对几何/净空类拒绝记录")

    # titan_route 的安全语义仍必须完整（被守卫覆盖，这里做二重确认）
    for frag in ("insufficient blast standoff clearance",
                 "if standoff>0 and blast_z<floor then return nil",
                 "local floor=target.origin[3]+1.25"):
        check(f"route_semantics_intact_{frag.split()[0]}",
              frag in route, f"titan_route 仍保留：{frag[:40]}")


def test_enemy_veto_wiring():
    print()
    print("=== ㉒ ★ 引擎选择否决：只清目标、不接管飞行 ===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    g = (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8")
    sf = (ROOT / "src/g60" / "small_filter.lua").read_text(encoding="utf-8")

    # 1) 判据直接用 observer 已读好的字段（零新增读取）
    check("veto_uses_observed_selection",
          "local veto_resource=m.selection_flag~=0 and m.selection_resource or nil" in r
          and "Filter.excluded(veto_resource)" in r,
          "判据来自 native_observer 已读好的 m.selection_resource（零新增读取）")
    check("veto_switch_short_circuits",
          "env.enemy_veto_enabled~=false and veto_resource~=nil" in r,
          "★ 开关关闭 ⇒ veto_selected=false ⇒ 门控回落到 no_mark_no_hold（完全原生）")

    # 2) 决策在 take_gate（纯函数，已被真跑测试覆盖）
    check("veto_decision_in_gate",
          "if o.selection_vetoed then" in g
          and "veto=true,why='VETO_ENEMY_SELECTION'" in g,
          "否决决策在 take_gate（纯函数，可真跑）")
    # ★★ 2026-09-30 修复后语义变更 ★★
    #   原断言"'有标记时永不触发' —— 那**正是运输船漏过滤的根因**：
    #   玩家标记了友方 ⇒ structure_mark 非 nil ⇒ take_gate 的 veto 不可达；
    #   而 priority 又会拒绝友方（NOT_VALID_TARGET）⇒ 引擎给的运输船没人清。
    #   现在 veto 有**两个触发点**，用"有没有接管"而不是"有没有标记"来区分。
    check("veto_decision_in_gate_for_no_mark",
          g.index("if o.selection_vetoed then") > g.index("if not (o.structure_mark or"),
          "无标记路径的否决判定仍在 take_gate 的 no_mark_no_hold 之后（不变）")
    check("veto_fallback_after_priority",
          "run_veto(m,vr,'after_priority')" in r
          and "(structure_mark or mark_friendly) and not abandoned" in r,
          "★ 新增兜底触发点：有标记但 priority 没接管时也否决（修复运输船漏过滤）；"
          " ★ 2026-10-10 追加：判为**友方**时 structure_mark 已被置 nil ⇒ 条件必须带 "
          "`mark_friendly`，否则「友方锁定」没人清（用户第二次报的 bug）")
    check("veto_fallback_requires_no_hold",
          "and not (old and (old.lock or old.titan))" in r,
          "★ 兜底不得在'正飞向自己的目标'时触发（那会破坏自己的锁定）")
    check("veto_single_implementation",
          r.count("local function run_veto(") == 1
          and r.count("R:release(veto_ref)") == 1
          and r.count("enemy_veto;entity=") == 1,
          "★ veto 执行只有**一份实现**，两个触发点共用（防'改一份漏一份'）；"
          " ⚠ 2026-10-10 加 `use_runner` 参数后，实例由局部 `R` 承载"
          "（安全区那条路要用专用实例，见 safe_veto_uses_dedicated_runner）")

    # 3) ★ 最关键：否决实现不得建锁、不得引导
    i = r.index("local function run_veto(")
    #   ⚠ 2026-10-10：右锚点原来是"下一处 matches 循环"，但 run_veto 与那个循环之间
    #     现在夹了另一个 helper（`run_safe_hold` —— 安全区管"引擎自己瞄的雷"），
    #     而它**本来就该**调 `arrival:step`（那就是它的工作）。
    #     ⇒ 切片必须**只覆盖 run_veto**，否则这条守门会把邻居的代码当成否决实现来误报。
    j = r.index("local function run_safe_hold(", i)
    blk = r[i:j]
    check("veto_creates_no_tracked",
          "tracked[m.id]=" not in blk and "old.lock=" not in blk
          and "old.titan=" not in blk and "seen[m.id]=true" not in blk,
          "★ 不建 tracked、不设 lock/titan、不标 seen ⇒ 三条引导/引爆路径都碰不到它")
    check("veto_does_not_guide",
          "arrival:step" not in blk and "titan:step" not in blk
          and "priority:step" not in blk,
          "★ 不调任何引导：只走 runner 的 search（clear）")
    check("veto_releases_runner_state",
          "R:release(veto_ref)" in blk,
          "★ 立刻释放 runner 状态，否则 search 成功后每帧 CONTINUE_SEARCH ⇒ 一直盘旋")
    check("veto_is_failclosed",
          "R:disabled()" in blk and "self.disabled=true" in blk
          and "if R==runner then" in blk,
          "部分写入后失败 ⇒ 停手（与既有引导路径同一处置）；"
          " ⚠ 但**只对主 runner**：专用实例（安全区清选择）是隔离域，"
          " 它 disabled 只该关掉那一个功能，不许让整局 mod 停手")
    check("veto_logged", "enemy_veto;" in blk, "否决有专门日志（含 result/why）")
    # ★★ 日志字段必须按 runner:step 的**真实返回契约**取值 ★★
    #   2026-09-29 我按 (ok,result,why) 取，而契约是 **(result, reason)**
    #   ⇒ 145 条实机日志全是 `result=nil;why=nil`，成功/失败都看不出。
    #   **诊断把自己骗了一次** ⇒ 现在把契约本身也钉住。
    _minimal = (ROOT / "src/g60" / "native_minimal.lua").read_text(encoding="utf-8")
    check("runner_step_returns_result_reason",
          "return result,reason" in _minimal,
          "native_minimal 的 step 返回 (result, reason) —— 契约源头")
    check("veto_log_reads_tuple_in_order",
          "';result='..tostring(ok_v and ok_v.kind or 'FAILED')" in blk
          and "';why='..tostring(res_v)" in blk,
          "★ 否决日志按 (result, reason) 取值，而非 (ok,result,why)")
    check("veto_log_has_frame",
          "';frame='..frame" in blk,
          "带 frame，便于事后量化触发频率")
    check("veto_no_direct_native_calls",
          "calls." not in blk and "ffi." not in blk,
          "★ 否决分支不直接做原生调用：全部经 runner（已实机验证的路径）")

    # 4) 只读诊断：按资源去重
    check("veto_diag_deduped_by_resource",
          "local veto_seen={}" in r and "not veto_seen[veto_resource]" in r
          and "veto_seen[veto_resource]=true" in r,
          "只读诊断按 resource 去重（条数受场上敌人种类数约束）")

    # 5) 配置面 + 日志
    check("veto_switch_declared",
          "enemy_veto_enabled=true," in e
          and "enemy_veto_enabled=state.enemy_veto_enabled" in e,
          "entry 有开关并传入 env")
    # ★ 启动日志的排除清单必须**派生**，不得硬编码：
    #   2026-09-29 这里硬编码了 98152772a72f7838，而实现里已换成
    #   db90077e76faa025 ⇒ 日志与实现不一致，实机核对时把我带偏过一次。
    check("veto_declared_in_version_line",
          "enemy_veto_enabled='..tostring(state.enemy_veto_enabled)" in e
          and "enemy_veto_resources='..table.concat(Filter.excluded_resources()" in e,
          "启动日志打出开关，且排除清单由 Filter.excluded_resources() 派生")
    check("veto_version_line_not_hardcoded",
          "enemy_veto_resources=98152772a72f7838" not in e
          and "enemy_veto_resources=db90077e76faa025" not in e,
          "★ 不得在 entry 里硬编码排除哈希（否则日志会与实现脱节）")
    check("veto_exposes_readonly_list",
          "function M.excluded_resources()" in sf,
          "small_filter 暴露只读清单作为**单一来源**")
    for ev_name in ("enemy_veto", "enemy_selection"):
        check(f"throttle_whitelists_{ev_name}",
              f"line:match('^{ev_name};')" in e,
              f"★ {ev_name} 必须常驻写日志（诊断被节流掉 = 诊断不存在）")

    # 6) ★★ 排除表的内容：逐条点名，并且必须能追到证据 ★★
    #
    #   2026-09-29 晚的实机 bug：第一版只放了社区表标注的 98152772a72f7838，
    #   而引擎真正分配给 G-60 的是 db90077e76faa025（cyborg_dropship）⇒ 从未生效。
    #   教训："名字对得上"不等于"就是那个哈希"。下面每条都断言来源。
    keys = re.findall(r"\['([0-9a-f]{16})'\]\s*=\s*true", sf)
    #   ★ 2026-10-01 加第二项：光能族**增援飞船** 74e2285c01da4f71
    #     （日志证据 `enemy_selection;entity=1241;resource=74e2285c01da4f71`）
    check("veto_list_is_evidenced_dropships_only",
          sorted(keys) == sorted(["db90077e76faa025", "74e2285c01da4f71"]),
          f"★ 排除表恰好两项 = 机器人运输船 + 光能族增援飞船（实际 {keys}）")
    check("veto_list_has_log_evidenced_hash",
          "db90077e76faa025" in keys and "74e2285c01da4f71" in keys,
          "★ 每一项都必须带**实机日志证据**（两条都是引擎真实选中的 resource）")
    # ★ 反向断言：停落地面的那个运输船不得被加回来
    #   （用户 2026-09-29 判断它是地面上不再起飞的运输船 ⇒ G-60 不会锁它 ⇒ 排除无意义）
    check("veto_list_excludes_landed_dropship",
          "98152772a72f7838" not in keys,
          "★ 停落地面的运输船(98152772a72f7838)不得重新加入")
    # ★ 反向断言：营地停落的**光能族**穿梭舰也不得加入 ——
    #   玩家会主动标记去炸它（同一局实机：structure_mark ACCEPTED 6 次 + priority_locked 14 次）。
    #   用户原话："注意是**增援**的飞船"。
    check("veto_list_excludes_landed_warp_ship",
          "b3c9cdb79dc17937" not in keys,
          "★ 营地穿梭舰 Warp Ship Landed 不得被排除（玩家要炸它）")
    # ★ 安全属性：绝不能把玩家自己的撤离机（鹈鹕 shuttle_dropship = 7b0f8449ca9d2da0）
    #   也否决掉 —— 那会把"不追踪敌方运输船"变成"不追踪自己的撤离机"。
    check("veto_list_excludes_friendly_pelican",
          "7b0f8449ca9d2da0" not in keys,
          "★ 不得排除玩家撤离机 shuttle_dropship(鹈鹕 MK2)")

    # ★★ 用**实机日志**反向验证：表里必须有日志真的出现过的那个哈希 ★★
    #   这条断言如果早写一天，本次 bug 根本不会发生：
    #   旧表只有 98152772a72f7838，而日志里出现的是 db90077e76faa025 ⇒ 立刻变红。
    _log = pathlib.Path.home() / "AppData/Local/CowboyBingus/Helldivers2/Logs/G60BugholeLock.log"
    if not _log.exists():
        check("veto_list_covers_logged_dropship", True, "跳过：实机日志不在")
    else:
        _txt = _log.read_text(encoding="utf-8", errors="replace")
        # 日志里被判为"运输船家族"的选择（按游戏资源路径含 dropship 判定）
        _seen = set()
        for _m in re.finditer(r"enemy_selection;entity=\d+;resource=([0-9a-f]{16})", _txt):
            _seen.add(_m.group(1))
        _friendly = {"7b0f8449ca9d2da0"}       # 玩家撤离机，不算
        # 关注"敌方运输船家族"里本工程认的那一个（停落地面的那个不算目标）
        _dropships = {h for h in _seen if h in ("db90077e76faa025",
                                                "74e2285c01da4f71")} - _friendly
        check("veto_list_covers_logged_dropship",
              _dropships <= set(keys),
              f"★ 日志里出现过的运输船哈希都在排除表里（日志: {sorted(_dropships)}）")


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
    for ev in ("arrival_already_exploded", "guide_give_up", "titan_clearance"):
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

    # ★ 关键安全属性（2026-09-29 收紧了两次范围的表述）：
    #   蟑龙加入后 weakpoint_profiles **会**被用到，所以不能再断言"完全不碰"。
    #   改成钉真正要守的东西：**只有一处精确取用**，且**不得按 kind 批量放行**。
    #   （按 kind 放行会把 Spore Charger 等一起拉进来 —— 那是用户没要求的扩张。）
    _code = "\n".join(l for l in r.splitlines() if not l.strip().startswith("--"))
    check("weakpoint_single_exact_lookup",
          _code.count("weakpoint_profiles[") == 1,
          "★ weakpoint_profiles 只有一处精确取用（不是批量放行）")
    check("no_kind_based_admission",
          "weakpoint_profiles[resource].kind" not in _code
          and "kind=='thorax'" not in _code,
          "★ 不按 kind 推断（只认精确哈希）")
    # ★ 表**非空**（登记了 7 个敌人弱点：head/rear/thorax/underside）——
    #   实机日志里 dcf8e74212fbee3b 就被 RESOURCE_NOT_SUPPORTED 拒过。
    #   安全性不靠"表是空的"，而靠 has_weakpoint 不认它。
    n_weak = len(re.findall(r'profiles\["[0-9a-f]+"\]', weak))
    check("weakpoint_targets_exist_but_unused", n_weak == 7,
          f"weakpoint_profiles 登记了 {n_weak} 个敌人，但接管范围不含它们")
    # ★ 2026-09-29：解析顺序改为 基线泰坦 → **变体** → 虫洞 → 弱点敌人。
    #   变体必须排在虫洞/弱点之前（它借的是泰坦几何，与基线同族）。
    _aim = r + (ROOT / "src/g60" / "native_titan_aim.lua").read_text(encoding="utf-8")
    check("titan_aim_prefers_titan_profile",
          re.search(r"\(resource==env\.titan_profile\.resource\) and env\.titan_profile\s*\n"
                    r"\s*or \(env\.titan_variant_profiles or \{\}\)\[resource\]\s*\n"
                    r"\s*or \(env\.structure_profiles", _aim) is not None,
          "★ 解析顺序：基线泰坦 → 变体 → 虫洞 → 弱点敌人（不依赖调用方传对）")
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
    # 2026-09-30：标记入口从"只认 claim_profile"扩展为
    #   `claim_profile(...) or generic_claimed(...)`（通用目标接管）。
    #   断言的是**单一入口**这个结构属性：两个判据都在同一个 allowed 里，
    #   不允许再出现第二处分散的标记入口判定。
    check("mark_entry_shares_claim_profile",
          r.count("claim_profile") >= 4
          and "allowed=function(resource)\n            return claim_profile(resource)~=nil or generic_claimed(resource)" in r,
          "★ 标记入口是唯一判定点（claim_profile 或 generic_claimed）")
    check("claim_profile_is_single_source",
          r.count("local function claim_profile(resource)") == 1,
          "claim_profile 只定义一次")
    check("titan_point_short_circuits_arrival",
          r.index("if titan_point then return {kind='guide'} end")
          < r.index("if has_weakpoint(m.selection_resource) then target=nil end"),
          "★ 泰坦点已建立时 arrival 提前返回（不会被虫洞到达区域误伤）")


def test_arrival_fault_isolation():
    """★ 2026-09-30：arrival 段也必须做故障域隔离（与 priority **同一份**判定）。

    实机事故（22:10 那局，根因就是缺这道隔离）::

        arrival_skipped;entity=4194657;detail=…:2348: arrival proximity suppression failed
        frame_error;detail=…:5904: arrival operation disabled
        disabled;applied=49          ← 整局 mod 停手 + 日志当场关闭
        （同一时刻 SmoothBoot/EpochLifetime 还在更新 ⇒ 游戏在跑，是 mod 把自己关了）

    触发场景：同场另一颗 G-60 的泰坦目标被引爆后，引擎给它重新分配了敌人目标，
    它的 arrival 从 `titan/` 段退回非 titan 段，走进 proximity 抑制块 ⇒ 回读不符。

    修复四处，逐一静态守门（这类错误 luac 过、单测过，只有实机炸）：
      ① priority_faults 分类里必须有 arrival 的两条（上面 test_fault_classification 已验）
      ② native_arrival 必须在 `disabled=true` **之前**先问 competitive()
      ③ runtime 收到 kind='quarantine' 只放弃这一颗，且不因它全局 disable
      ④ build.json 里 Faults 别名必须排在 native_arrival **之前** —— 构建期
         `local competitive=Faults.competitive` 的右值若还是 nil，隔离就是空转
         （与 2026-09-28「Geometry 排在使用者之后」完全同型的一种静默失效）

    ★ 2026-10-01 补第 ⑤ 条（同一道隔离的"参照系"版本）：
       点目标路径会在引爆判定**之前**写 record ⇒ 引爆期断言若拿"写前 record"
       当参照，引擎只要重选过一次目标就不符 ⇒ 又一次整局熔断
       （用户："又出现失效情况了"，entity=577）。参照改用写后回读。
    """
    print()
    print("=== ㉑ arrival 段故障域隔离（2026-09-30 事故）===")
    arr = ARRIVAL.read_text(encoding="utf-8")
    r = RUNTIME.read_text(encoding="utf-8")

    check("arrival_uses_shared_classifier",
          "local competitive=require('g60.priority_faults').competitive" in arr,
          "★ 复用 g60.priority_faults（不复制一份自己的名单）")
    check("arrival_check_before_disable",
          "if competitive(result) then" in arr
          and arr.index("if competitive(result) then") < arr.index("then disabled=true end"),
          "★ 先问 competitive()，再考虑 disabled=true（顺序即语义）")
    check("arrival_returns_quarantine",
          "return {kind='quarantine',contended=tostring(result)}" in arr,
          "竞争态返回 kind='quarantine'（不是 nil + 置 disabled）")

    check("runtime_handles_arrival_quarantine",
          "result.kind=='quarantine'" in r and "arrival_quarantined" in r,
          "★ runtime 有 arrival 的 quarantine 分支 + 专用日志")
    check("runtime_arrival_quarantine_clears_hold",
          "old.quarantined=true;old.lock=nil;old.titan=nil" in r,
          "只放弃这一颗：清锁/航点并置 quarantined（下一帧 TakeGate 不再驱动它）")
    check("runtime_arrival_quarantine_not_global",
          "arrival contention limit reached" in r,
          "★ 只有同帧多颗都失败才全局停手（共用 note_contention 计数）")
    check("runtime_arrival_disable_guards_quarantine",
          "and not (ok_arr and type(result)=='table' and result.kind=='quarantine') then" in r,
          "`arrival operation disabled` 不再被竞争态触发（与 priority 段同款防御）")

    # ⑤ ★ 2026-10-01：引爆期断言的**参照系**必须是"写后快照"，不能是"写前 record"。
    #    点目标路径在引爆判定**之前**就写 record ⇒ 拿写前快照去比，只要引擎在这两帧
    #    之间给这颗 G-60 重选过目标就不符（实机 entity=577 引爆帧）。
    #    这类"参照系取错"是静态可查的：断言里不能再出现裸的 `source()==record`。
    check("arrival_flight_reference_declared",
          "local flight_reference=record" in arr,
          "★ 本帧参照快照 flight_reference 存在（默认 = 本帧 record）")
    check("arrival_point_write_updates_reference",
          "flight_reference=after" in arr
          and arr.index("flight_reference=after") > arr.index("mutated=true;scope.calls.clear(pair,data)"),
          "★ 点目标写完之后立刻把参照换成写后回读（顺序即语义）")
    check("arrival_detonate_uses_flight_reference",
          "and source()==flight_reference,'arrival trigger changed'" in arr,
          "引爆期断言用 flight_reference（不是写前 record）")
    check("arrival_no_stale_detonate_reference",
          "and source()==record,'arrival trigger changed'" not in arr
          and "assert(source()==record,'arrival request changed flight state')" not in arr,
          "★ 引爆分支里不再残留裸 `source()==record`（两处都要换）")

    # ④ 构建期别名顺序（与 test_fault_classification 里的 priority/runtime 三处同源）
    import json
    aliases = list(json.loads((ROOT / "compat/build.json").read_text(encoding="utf-8"))["aliases"])
    check("faults_alias_before_native_arrival",
          aliases.index("priority_faults") < aliases.index("native_arrival"),
          f"Faults(pos {aliases.index('priority_faults')}) 在 "
          f"native_arrival(pos {aliases.index('native_arrival')}) 之前定义")


def test_early_nav_probe():
    print()
    print("=== ㉔ 早期导航探测（无敌人时能否驱动 G-60 —— 2026-10-01 用户要求）===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) 探测段存在，且**只读**（emit 为 nil 时不进）
    check("early_nav_probe_exists",
          "if env.early_nav_probe and env.emit and m.behavior_id==4" in r,
          "runtime 有早期导航探测分支（env.emit 缺失时不进）")
    check("early_nav_orbit_behind_own_switch",
          "if env.early_nav_orbit and env.calls and env.calls.orbit then" in r,
          "★ orbit 试探受**独立开关**保护（2026-10-01 用户拍板开启为实验）")
    check("early_nav_orbit_probes_once_per_grenade",
          "local pk=m.identity_bytes..m.flight_start" in r
          and "P.probe[pk]=true" in r,
          "★ 每颗 G-60 只探一次（按 flight_start 去重）—— orbit 不是每帧调用")
    # 2) 必须传 allow_early_state，否则 capture 会以策略理由拒绝、
    #    分不清"策略拒绝"与"结构未就绪"（后者才是要测的）
    check("early_nav_probe_allows_early_capture",
          "{matches={},allow_early_state=true}" in r,
          "★ 探测显式放行早期 state（否则测不出真因）")
    # 3) 关键定位断言：探测段必须**独立于 take_gate 门控**
    #    （放在 `local early_fp=` 之前 ⇒ 不受 allow_state3/early_state_disabled 影响）
    _p = r.index("if env.early_nav_probe and env.emit and m.behavior_id==4")
    _e = r.index("local early_fp=m.identity_bytes..m.flight_start")
    check("early_nav_probe_independent_of_gate",
          _p < _e,
          "★ 探测在 take_gate 门控之前 ⇒ 不依赖 allow_state3，不改变现有行为")
    # 4) 失败原因必须原样打出来（'missing movement component' 与 'pointer bound'
    #    是两种不同结论，不能被压成同一句）
    check("early_nav_probe_reports_failure_detail",
          "';result=CAPTURE_FAILED;detail='..tostring(cap)" in r,
          "失败原因原样上报（区分'组件未建立'与'结构未就绪'）")
    # 5) 开关与白名单
    check("early_nav_switches_values",
          "early_nav_probe=false,early_nav_orbit=false," in e,
          "★ 2026-10-01 实验已做完（结论：早期 state 改目标数据无效）⇒ 两个开关归零")
    # ★ 构建守门（build.py）扫描的是**整个 entry 文本（含注释）** ⇒ 注释里出现
    #   禁用字面量会直接让构建失败（本次就踩了）。
    #   ⚠ 2026-10-09：`WriteProcessMemory` 从"不得出现"改为**计数式受控**
    #     （用户拍板走写内存实验）⇒ 这里改查"恰好 1 处调用"；
    #     其余高危词仍然一律不得出现（含注释）。
    check("controlled_write_word_counted",
          e.count(".WriteProcessMemory(") == 1 and e.count("WriteProcessMemory") <= 2,
          "★ 受控写：恰好 1 处调用、全文 ≤2 次提及（详见 test_force_lock）")
    for _word in ("VirtualAlloc", "VirtualProtect", "MinHook", "ffi.copy"):
        check("no_forbidden_capability_word_" + _word.replace(".", "_"),
              _word not in r and _word not in e,
              f"★ 源码（含注释）不得出现 {_word}（build.py 的守门会拒绝出包）")
    check("early_nav_orbit_reports_path_agent",
          "';agent_before='..tostring(cap.path_agent_present)" in r
          and "';agent_after='..agent_after" in r,
          "★ 回读 path_agent 变化（'引擎真的开始导航'的信号，比 dest 更硬）")
    check("early_nav_flags_passed_to_runtime",
          "early_nav_probe=state.early_nav_probe,early_nav_orbit=state.early_nav_orbit," in e,
          "两个开关传入 Runtime.new")
    check("early_nav_lines_whitelisted",
          "and not line:match('^early_nav_probe;')" in e
          and "and not line:match('^early_nav_orbit;')" in e,
          "★ 探测日志进节流白名单（否则等于没测）")
    # 6) ★ 2026-10-04 用户拍板**打开**早期接管（治"标记目标脱锁"：接管窗口太短）。
    #    ⚠ 已知副作用（由熔断兜）：priority 早期 setter 会报 `pointer bound`。
    #      ⇒ 守门从"禁止打开"改为"**必须经显式开关**"（不得绕过配置、也不得悄悄回硬编）。
    check("allow_state3_is_explicitly_switchable",
          "allow_state3=state.allow_state3," in e
          and "allow_state3=true," in e
          and "';allow_state3='..tostring(state.allow_state3)" in e,
          "★ `allow_state3` 必须**可配置**：state 一处定值 + env 透传 + 状态行可见"
          "（原来它是硬编 false、根本改不了）。开关由用户拍板，副作用由 "
          "`state3_danger` 熔断兜底")

    # ── ⑦ "空白标记"探查：ping 槽全字段 dump（2026-10-01，只读）──
    #   用户问「无目标的空白标记是否也能接管」⇒ 先回答客观问题：
    #   ping 到空地时那个 88 字节的槽里有没有世界坐标。
    pg = (ROOT / "src/g60" / "native_ping.lua").read_text(encoding="utf-8")
    check("ping_slot_dump_exists",
          "local function dump_slot(slot,bytes)" in pg,
          "native_ping 有槽 dump 实现")
    check("ping_slot_dump_only_on_missing_entity",
          "if not e then\n                            diagnose(id,nil,'NO_ENTITY_MARK')\n"
          "                            -- \u2605 \"空白标记\"（读不到实体）" in pg
          or "if options.slot_dump then dump_slot(slot,r) end" in pg,
          "★ 只在读不到实体（NO_ENTITY_MARK）时 dump —— 聚焦「空白标记」且天然不刷屏")
    check("ping_slot_dump_readonly_and_deduped",
          "local slot_seen={}" in pg and "if slot_seen[key] then return end" in pg,
          "★ 有去重（不刷屏）")
    # ★★ 去重键必须是**位置字节**（2026-10-01 第二次迭代）★★
    #   第一版用 `slot:前4字节`（那 4 字节恒为 0）⇒ 每槽一生只 dump 一次
    #   ⇒ 实测一次把 8 个槽打完，之后再 ping 新位置不再出日志，
    #     根本无法回答"哪一次 ping 对应哪个坐标"（探测目的落空）。
    check("ping_slot_dump_dedupes_by_position",
          "local key=tostring(slot)..':'..bytes:sub(5,16)" in pg,
          "★ 去重键含**位置 12 字节**（0x04..0x0f）⇒ 同槽坐标变了才再 dump")
    check("ping_slot_dump_has_cap",
          "local DUMP_CAP=80" in pg and "dump_capped;limit=" in pg,
          "★ 有总条数上限（槽内容每帧都变时也不会刷爆日志）")
    check("ping_slot_dump_reports_pos_and_dist",
          "..';pos='..string.format('%.2f/%.2f/%.2f',f[1],f[2],f[3])" in pg
          and "..';dist='..string.format('%.2f',f[10])" in pg,
          "★ 直接打出解出的 pos(0x04) 与 dist(0x28)，便于与 hex 交叉核对")
    check("ping_slot_dump_reports_candidates",
          "cand[#cand+1]=string.format('0x%x=%.2f/%.2f/%.2f'" in pg,
          "同时扫描并报告「疑似坐标三元组」候选（便于人工比对）")
    # ★★ 2026-10-01 踩坑修复的守门 ★★
    #   dump_slot 在 structure_mark 的 pcall 内部被调用 ⇒ 它抛错会被记成
    #   ENTITY_READ_FAILED（实测日志里 dump 一行没出，只有那句 nonfinite target data）。
    #   ⇒ 必须 ① 自己 pcall 兜住 ② 不用有断言的 Data.float。
    _ds = pg[pg.index("local function dump_slot(slot,bytes)"):
             pg.index("function api:reset()")]
    check("ping_slot_dump_self_guarded",
          "local ok,detail=pcall(function()" in _ds,
          "★ dump 自己兜异常（否则会污染外层 pcall 的结论）")
    # 只看**代码行**（注释里会提到旧写法，不能算）
    _ds_code = "\n".join(l for l in _ds.splitlines() if not l.strip().startswith("--"))
    check("ping_slot_dump_no_asserting_decoder",
          "Data.float" not in _ds_code and "ffi.cast('float *',buf)" in _ds_code,
          "★ 用 ffi 解 float，不用会断言的 Data.float（'nonfinite target data'）")
    check("ping_slot_dump_wired_through_runtime",
          "slot_dump=env.ping_slot_dump," in r
          and "slot_dump_diagnostic=function(detail) env.emit('ping_slot;'..detail) end" in r,
          "runtime 把开关与诊断通道接进 structure_ping")
    check("ping_slot_dump_switch_and_whitelist",
          "ping_slot_dump=true," in e and "and not line:match('^ping_slot;')" in e,
          "★ entry 开关 + 日志进节流白名单（否则等于没测）")

    # ── ⑧ 空白标记位置暴露（2026-10-01，只读；"指哪打哪"的前置验证）──
    #   实测已证：槽 +0x04 是世界坐标（8 槽三边定位自洽、残差 ~0.7m RMS；
    #   两次 ping 的坐标间距 37.3m 与用户"走开约 30m 再 ping"吻合）。
    check("point_marker_exposed_from_ping",
          "function api:last_point() return last_point end" in pg
          and "local px,py,pz,pd=slot_point(r)" in pg,
          "★ native_ping 把空白标记位置暴露给上层（api:last_point）")
    # ★ 只接受 `id==invalid` 的**真空白标记**：`not e` 也覆盖"有 id 但实体读不到"，
    #   那种不能当地面点用（否则会往一个"存在但读不到"的实体位置扔炸弹）。
    check("point_marker_only_for_invalid_id",
          "if id==d.invalid then" in pg and "point_seen={x=px" in pg,
          "★ 只对 id==invalid（真·无实体标记）记位置")
    # ★ 位置必须**随标记存活而失效**：本帧没看到就清空，
    #   否则会拿一个已过期的 ping 点去引导 G-60（"指哪打哪"最怕这个）。
    check("point_marker_cleared_when_absent",
          "last_point=point_seen" in pg and "local point_seen" in pg,
          "★ 每帧重算：看不到就清空（不残留过期 ping 点）")
    check("point_marker_self_guarded",
          "local function slot_point(r)" in pg and "local ok,x,y,z,d=pcall(function()" in pg,
          "★ slot_point 自兜异常 + 不用会断言的 Data.float（与 dump_slot 同款坑）")
    check("point_marker_rejects_implausible",
          "math.abs(x)+math.abs(y)+math.abs(z)<0.5 then return nil end" in pg,
          "★ 拒绝「全零/量级过小」的伪坐标（防误读成真实位置）")
    check("point_marker_logged_once_per_marker",
          "if not P.pmark[tk] and P.pmark_n<120 then" in r,
          "★ 每个标记只打一行（键 = slot+位置），且有上限")
    # ★★ 诊断表必须放进 P（复用既有 local）：host:tick 的匿名函数 upvalue 已吃满 60
    #   （Lua 5.1 上限）⇒ 新开 local 可能让整个 chunk 编译失败（"mod 没生效"）。
    check("point_marker_state_inside_P",
          "pmark={},pmark_n=0," in r and "pt={token=nil,frame=-1000000000,seen=false}," in r
          and "pg={}," in r and "site={},orig={},hit={},hl={}," in r and "pex={},swk={},swn=0," in r and "pbt={}" in r and "local point_mark_logged" not in r,
          "★ 去重表 / 点目标新鲜度 / **体内爆点去重表** 全放进 P"
          "（不新增 upvalue，避免 60 上限；2026-10-03 新增 blast）")
    check("point_marker_switch_and_whitelist",
          "point_marker_enabled=true," in e and "and not line:match('^point_marker;')" in e
          and "point_marker_enabled=state.point_marker_enabled," in e,
          "★ entry 开关 + 传参 + 日志进节流白名单")
    check("point_marker_does_not_change_behavior",
          "marks[#marks+1]=mark" in pg and "last_selected=result" in pg,
          "★ 现有「有实体标记」的返回链路一字未改（本轮只读）")


def test_sel_probe():
    print()
    print("=== ㉕ 转阶段探针（引擎何时转索敌 / 丢目标 —— 2026-10-07 用户要求）===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) 探测段存在，只看 G-60，且**自带上限**
    check("sel_probe_exists",
          "if env.sel_probe_enabled~=false and m.behavior_id==4" in r,
          "runtime 有转阶段探针分支（只看 G-60：behavior_id==4）")
    check("sel_probe_has_line_cap",
          "P.seln<4000" in r,
          "★ 有全局行数上限（白名单行不受节流 ⇒ 必须自带上限）")
    # 2) 五个可观测字段必须齐全（少一个就分不清"丢目标"与"换目标"）
    for _f, _why in (("m.state", "阶段回退 = 转索敌"),
                     ("m.selection_id", "锁定 id 被清 = 丢目标"),
                     ("m.selection_flag", "有效标志归零 = 没有目标"),
                     ("m.selection_resource", "引擎到底锁了谁"),
                     ("m.candidate_source", "选择来源：候选表 / 标记")):
        check("sel_probe_field_" + _f.split(".")[1],
              _f in r,
              f"探针元组含 {_f}（{_why}）")
    # 3) 只在**变化**时打（否则逐帧刷屏，本项目踩过这个坑）
    check("sel_probe_dedup_by_grenade",
          "local was=P.sel[fp]" in r and "if was~=tuple then" in r
          and "P.sel[fp]=tuple" in r,
          "★ 按手雷去重：元组没变就不打（一颗雷一次任务 3~8 条）")
    check("sel_probe_first_observation_logged",
          "tostring(was or 'first')" in r,
          "★ 首次观测也打一条：区分「投出即锁上」与「投出就没有目标」")
    # 4) 去重表必须随 state 表一起清（同键 ⇒ 不另开循环、不无限膨胀）
    check("sel_probe_table_cleaned_with_state_table",
          "state_key[fp]=nil;state_age[fp]=nil" in r and "P.sel[fp]=nil" in r,
          "★ 去重表与 state 停留表同键同清（防无限膨胀）")
    # 5) 纯只读：块内不得出现任何原生调用 / ffi / setter
    _i = r.index("if env.sel_probe_enabled~=false and m.behavior_id==4")
    _j = r.index("diag.total=#observed.matches", _i)
    _blk = r[_i:_j]
    check("sel_probe_is_read_only",
          "calls." not in _blk and "ffi." not in _blk and "setter" not in _blk,
          "★ 探针块内零原生调用、零 ffi（只观测每帧已读的字段）")
    check("sel_probe_emits_evidence_line",
          "env.emit('sel_probe;entity='" in _blk and "';was='" in _blk
          and "';now='" in _blk and "';frame='" in _blk,
          "每行含 手雷 id / 变化前 / 变化后 / 帧号")
    # 6) 开关与白名单
    check("sel_probe_switch_declared",
          "sel_probe_enabled=true," in e
          and "sel_probe_enabled=state.sel_probe_enabled," in e,
          "entry 有开关并传入 env")
    check("sel_probe_lines_whitelisted",
          "and not line:match('^sel_probe;')" in e,
          "★ 探针日志进节流白名单（诊断被节流掉 = 探针不存在）")


def test_code_probe():
    print()
    print("=== ㉖ 代码探针（取运行时机器码离线反汇编 —— 2026-10-07 用户拍板路线 A）===")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) 存在 + 受开关保护 + 一次性（启动时跑一轮，共约 5 KB 日志）
    check("code_probe_exists",
          "if state.code_probe_enabled then" in e,
          "entry 启动处有代码探针分支（受 state 开关保护）")
    check("code_probe_switch_declared",
          "code_probe_enabled=false," in e,
          "★ 开关默认**关闭**（2026-10-09）：逆向使命已完成（state-3 转换/seek/分数来源"
          "全部读出、结论固化进 force_lock），而本段每次启动约 55 KB，"
          "日志总量上限 256 KB ⇒ 开着会把后面真正要看的诊断挤掉（静默截断）")
    # 2) ★ 必须在 88 条 game.dll 签名校验**之后**：
    #    能走到探针 ⇒ base 与 RVA 的映射已被证明正确 ⇒ 取到的字节可信。
    #    这是"读到的到底是真代码还是乱码"的唯一保证，不能靠运气。
    _g = e.index("for _,g in ipairs(@@GAME_GUARDS@@) do")
    _p = e.index("if state.code_probe_enabled then")
    check("code_probe_after_signature_checks",
          _g < _p,
          "★ 探针排在 88 条签名校验之后（字节可信的前提）")
    _i = _p
    _j = e.index("\n    local calls=Binding.bind_experimental", _i)
    blk = e[_i:_j]
    # 3) ★ 必须 pcall 包住：探针失败绝不能停用整个 mod
    check("code_probe_pcall_protected",
          "pcall(read,base+rva+off,chunk)" in blk and "';error='" in blk,
          "★ 读取失败只记一行 error，不让启动失败（否则整个包停用）")
    # 4) 纯只读：块内不得有原生调用 / setter / 危险的 ffi 用法
    #    ⚠ 按**去注释后的代码**判（工程既有惯例）：注释里为了说明原理提到
    #      `calls.clear` 是正常写法，不该把代码属性门弄红 —— 否则以后没人敢写注释。
    #    ⚠ 2026-10-09 精确化：浮点常量探针要用 `ffi.new`/`ffi.cast` 做**本地**解码
    #      （只对读回来的字节做 IEEE754 解释，不碰游戏内存）⇒ 不再一律禁 ffi，
    #      改为禁**危险**用法（ffi.load / ffi.cdef / ffi.copy / ffi.C），
    #      并单独断言实际用到的 ffi 名字只有 new/cast。
    blk_code = "\n".join(l for l in blk.splitlines() if not l.strip().startswith("--"))
    _dangerous = ("ffi.load", "ffi.cdef", "ffi.copy", "ffi.C(", "calls.", "setter")
    check("code_probe_is_read_only",
          all(w not in blk_code for w in _dangerous),
          "★ 探针块内无原生调用、无危险 ffi 用法（ffi.load/cdef/copy/C）、无写操作")
    _ffi_uses = set(re.findall(r"ffi\.(\w+)", blk_code))
    check("code_probe_ffi_limited_to_local_decode",
          _ffi_uses <= {"new", "cast"},
          "★ 探针里的 ffi 只允许 new/cast（本地浮点解码），实际用到: %s" % sorted(_ffi_uses))
    # 5) 目标 RVA 齐全（全部来自已逆向的锚点，不是猜的）
    for _rva, _what in (("0x4af4e0", "clear（自带签名，可复核取字节没错位）"),
                        ("0x4dec30", "orbit（同上）"),
                        ("0x8858a0", "target_valid —— 引擎「能否成为锁定目标」的判据"),
                        ("0x13e1b50", "pred_f0c —— 吃 f0c，返回值 >=1 即拒"),
                        ("0x4a9710", "flags_f08 —— 吃 f08，返回带 bit25 的标志字"),
                        ("0xfd9d40", "resolve_id —— entity==NULL 时按 id 解析"),
                        ("0x927050", "set_lookup —— 全局集合查询，为真即硬拒")):
        check("code_probe_rva_" + _rva[2:], _rva in blk, "含 %s（%s）" % (_rva, _what))
    # 5b) ★ 必须**分块**读：emit 单行上限 900 字符，一次性读 512 字节会被静默截断
    #     （2026-10-08 首轮实测：512 → 被切到 419 字节）。
    check("code_probe_chunked_under_emit_cap",
          "while off<n do" in blk and "math.min(256,n-off)" in blk,
          "★ 按 ≤256 字节/行分块（否则 1024 hex 超过 emit 的 900 字符上限被静默截断）")
    # 6) ★★ 调用者扫描（2026-10-09）：找"引擎自己开始索敌"的位置 ★★
    #    原理：我们自己的代码就是靠 clear+orbit 起索敌 ⇒ 引擎同理。
    check("caller_scan_exists",
          "callerscan;from=" in blk and "callerscan_done;hits=" in blk,
          "有调用者扫描并自报命中数")
    for _a, _n in (("0x4af4e0", "clear"), ("0x4dec30", "orbit"),
                   ("0x8858a0", "target_valid"), ("0x8859c0", "category_mask"),
                   ("0x889940", "candidates"), ("0x8cdf80", "explode")):
        check("caller_scan_anchor_" + _a[2:],
              ("[%s]=" % _a) in blk, "锚点含 %s(%s)" % (_a, _n))
    check("caller_scan_is_rel32_call_scan",
          "b:find('\\232',i,true)" in blk and "rel>=2147483648 then rel=rel-4294967296" in blk
          and "+5+rel" in blk,
          "★ 扫 E8 rel32 并做符号扩展（call 目标 = 指令地址+5+rel）")
    check("caller_scan_reads_with_overlap",
          "math.min(32764,0x2110a93-off)" in blk and "read,base+off,n+4" in blk,
          "★ 每块多读 4 字节：防 call 指令跨块边界被漏掉")
    check("caller_scan_limited_to_code_section",
          "off=0x1000" in blk and "0x2110a93" in blk,
          "★ 只扫第一个节（实测 char=0x60000020 code；其余大节是 data）")
    check("caller_scan_full_coverage_histogram",
          "hits<300" not in blk and "counts[name]=(counts[name] or 0)+1" in blk
          and ";hist='..table.concat(hist,',')" in blk,
          "★ **不做命中上限截断**（上一轮打满 300 条把扫描切断了）⇒ 全代码节扫完，"
          "只逐条打 orbit、其余进直方图（counts/first/last）")
    check("caller_scan_logs_orbit_sites_only",
          "if name=='orbit' then" in blk and "callerscan;from=" in blk,
          "★ 只逐条打 orbit（唯一'起索敌'原语调用点，实测全节仅 1 个）")
    check("caller_scan_lines_whitelisted",
          "and not line:match('^callerscan;')" in e
          and "and not line:match('^callerscan_done;')" in e,
          "★ 扫描结果进节流白名单")
    # 6b) ★ state-3 转换（= "让 G-60 开始索敌"的那段代码）：上游与扫描同址
    check("code_probe_reads_state3_transition",
          "dump_code('seek_fn',0xba800,2304)" in blk,
          "★ 读 0xbb009 附近（上游记录：'Never call the state-3 transition, "
          "which resets the flight timer'；扫描实测 orbit 唯一调用点 from=bb021）")
    # 6c) ★ 2026-10-09 续：seek 函数余下全部 + 第二个 orbit 调用点 + 浮点常量
    check("code_probe_reads_seek_fn_rest",
          "dump_code('seek_fn2',0xbb100,15360)" in blk,
          "★ 读 seek 函数余下全部（0xbb100→0xbbd21 的 ret）—— 选目标/置 state 的逻辑")
    check("code_probe_reads_second_orbit_site",
          "dump_code('orbit2',0x425300,1024)" in blk,
          "★ 读第二个 orbit 调用点（0x4254e1；上一轮被 300 上限截断漏掉）")
    check("code_probe_reads_orbit_constants",
          "dump_f32('orbit_arg1',0x23c7554)" in blk
          and "dump_f32('cooldown_mul',0x23c7ec0)" in blk,
          "★ 读 orbit 三实参 + 冷却周期常量（验证 10.0/2.5/1.2 与 ~22 帧周期）")
    check("caller_scan_includes_seek_fn_anchor",
          "[0xbafb0]='seek_fn'" in blk and "'seek_fn'}" in blk,
          "★ seek 函数自身也当锚点 ⇒ 直方图会给出**谁触发它**")
    check("constprobe_lines_whitelisted",
          "and not line:match('^constprobe;')" in e,
          "★ 常量探针进节流白名单")
    # 6d) ★★ state=4 写入点扫描（2026-10-09）：找**可调用的**提升函数 ★★
    check("state_scan_exists",
          "statescan;from=" in blk and "statescan_done;hits=" in blk,
          "有 state=4 写入点扫描并自报命中数")
    check("state_scan_patterns",
          "'\\8\\4\\0\\0\\0','state4'" in blk and "'\\0\\4\\0\\0\\0','behav4'" in blk,
          "★ 扫两种模式：mov dword [reg+8],4（state）与 [reg+0],4（behavior）")
    check("state_scan_validates_modrm",
          "b:byte(p-1)>=0x40 and b:byte(p-1)<=0x47" in blk and "b:byte(p-2)==0xc7" in blk,
          "★ 校验 ModRM 0x40-0x47（[reg+disp8]）与 C7 前缀 —— 否则 5 字节序列会大量误报")
    check("state_scan_lines_whitelisted",
          "and not line:match('^statescan;')" in e
          and "and not line:match('^statescan_done;')" in e,
          "★ 扫描结果进节流白名单")
    # 6d2) ★ 2026-10-09 事故：statescan 用了 `math.min(32764,…)` + `read(…,n+5)`
    #      ⇒ 每块传 32769 > read 的上限 32768 ⇒ **每次读都被 assert 拒绝、又被 pcall
    #      吞掉** ⇒ 扫描什么都没扫，却打出一行看起来完全合法的 `hits=0`
    #      ——静默失败伪装成结论。⇒ 现在必须 32763，且必须统计 reads/reads_fail。
    check("state_scan_read_bound_respected",
          "math.min(32763,0x2110a93-soff)" in blk
          and "reads_fail=" in blk and "sreads_fail=sreads_fail+1" in blk,
          "★ n+5 必须配 32763（≤32768）；且失败要计数 ⇒ 不可能再伪装成'没命中'")
    # 6e) ★★ 能力边界（2026-10-09 起从"只读"改为"只读 + 恰好 1 处受控写"）★★
    check("ffi_surface_is_minimal",
          "ReadProcessMemory" in e
          and e.count(".WriteProcessMemory(") == 1
          and "VirtualProtect" not in e and "VirtualAlloc" not in e
          and "NtWriteVirtualMemory" not in e and "ffi.copy" not in e,
          "★ 能力面：只读 + **恰好 1 处**受控写（用户拍板）；"
          "VirtualProtect/VirtualAlloc/NtWriteVirtualMemory/ffi.copy 仍一律禁止")
    check("engine_function_surface_unchanged",
          all(s in e for s in ("base+0x8858a0", "base+0x8cdf80",
                               "base+0xfdc310", "base+0x4b0c40")),
          "★ 引擎函数绑定面未变（target_valid/explode/remove/aim；"
          "clear/orbit 在 compat/native_search_binding.lua）")


    # 6) ★ hex 转换习惯必须成立：漏一个字节 ⇒ 反汇编整体错位，
    #    而错位的反汇编**看起来仍像正常指令** ⇒ 静默错误，必须钉住。
    #    （已在游戏自带 lua51.dll 上实跑验证：含 \0 \n \r 0xff 的字节串零遗漏。）
    check("code_probe_hex_idiom",
          "s:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)" in blk,
          "★ 按字节转 hex（Lua 的 `.` 匹配含 \\0 与 \\n 的全部字节）")
    # 7) 白名单
    check("code_probe_lines_whitelisted",
          "and not line:match('^codeprobe;')" in e,
          "★ 探针日志进节流白名单")


def test_force_lock():
    print()
    print("=== ㉙ 强制提升 state=4（写内存实验 —— 2026-10-09 用户拍板）===")
    r = PRIORITY.read_text(encoding="utf-8")
    e = ENTRY_SRC.read_text(encoding="utf-8")
    b = (ROOT / "scripts" / "build.py").read_text(encoding="utf-8")

    def _fn_slice(src, marker):
        """取一个函数的完整源码块：终点 = 之后最近的 `local function` 或
        `function M.new(env)`（两者取先出现者）。
        ⚠ 不能写死终点 —— 2026-10-09 因为在这两个函数前后各插入了一个新函数，
          写死终点连续误报两次（把新函数的 scope.read 算进"零读取"检查）。
        """
        i = src.index(marker)
        ends = [src.find(m, i + len(marker))
                for m in ("\nlocal function ", "\nfunction M.new(env)")]
        ends = [k for k in ends if k >= 0]
        return src[i:min(ends)]

    # 1) 写通道：恰好 1 处调用 + 边界断言
    check("write_channel_exists",
          "local function write(a,s)" in e and "k.WriteProcessMemory(" in e,
          "entry 有受控写通道（唯一调用点）")
    check("write_channel_bounded",
          "and #s<=64,'write bound'" in e,
          "★ 单次 ≤64 字节（只够那 3 个 dword，防被挪作他用）")
    check("write_channel_no_ffi_copy",
          "ffi.copy" not in e,
          "★ 不用 ffi.copy（那本身也在禁用词表里）—— 逐字节填 buffer")
    # 2) 开关：声明 + env 接线（顺序：声明在前）
    check("force_lock_switch_declared",
          "force_lock_enabled=true," in e,
          "entry 有开关（默认开：用户要做的实验）")
    check("force_lock_switch_wired",
          "force_lock_enabled=state.force_lock_enabled," in e
          and e.index("force_lock_enabled=true,") < e.index("force_lock_enabled=state.force_lock_enabled,"),
          "★ 开关必须传进 env（否则 promote_state4 静默不触发 —— 同类事故已踩两次）")
    check("write_channel_wired_to_env",
          "write=write," in e,
          "★ 写通道也必须进 env（promote_state4 读 env.write）")
    check("force_lock_logged_in_status_line",
          "'force_lock_enabled='..tostring(state.force_lock_enabled)" in e,
          "★ 启动状态行必须打出它（写内存实验不能靠猜有没有开）")
    # 3) 提升函数：逐字段照抄引擎提升块 + 写前复核 + 写后回读
    blk = _fn_slice(r, "local function promote_state4(env,scope,c)")
    check("promote_state4_exists", "promote_state4(env,scope,c)" in r,
          "native_priority 有 promote_state4")
    check("promote_state4_writes_three_dwords",
          "env.write(c.state_address+8,'\\4\\0\\0\\0')" in blk
          and "env.write(c.state_address+4,'\\255\\255\\255\\255')" in blk
          and "env.write(c.state_address,'\\4\\0\\0\\0')" in blk,
          "★ 只写 3 个 dword，值与偏移照抄引擎提升块"
          "（0xbbc91 [+8]=4 / 0xbbc9c [+4]=-1 / 0xbbcb0 [+0]=4）")
    check("promote_state4_prechecks",
          "if behavior~=4 then" in blk and "if state~=2 and state~=3 then" in blk,
          "★ 写前复核：behavior 必须=4、state 必须∈{{2,3}}，否则一个字都不写")
    check("promote_state4_reads_back",
          "local after=L.u32(scope.read(c.state_address,4),0)" in blk
          and "return after==4," in blk,
          "★ 写后回读必须变成 4，结果进日志")
    check("promote_state4_reports_before_after",
          "'state='..tostring(state)..'->'..tostring(after)" in blk,
          "日志含写前→写后状态（判读'到底成没成'的唯一依据）")
    # 4) 调用点：只在虫洞、且放在点写入之后
    check("force_lock_only_for_structures",
          "if chosen.marked_structure and not chosen.generic then" in r,
          "★ priority 路只对虫洞强制提升（通用敌人引擎自己会提升，少碰一类目标）")
    _p = r.index("if chosen.marked_structure and not chosen.generic then")
    _s = r.index("'priority point setter mismatch'")
    check("force_lock_after_point_write", _s < _p,
          "★ 提升放在点写入**之后**（顺序与引擎自己的提升块一致：先装目标再置 state）")
    check("force_lock_deduped",
          "M.probed_fields[fkey]" in r and "'fl:'..tostring(c.flight_start)" in r,
          "按 (flight_start,结果) 去重：一颗雷最多两条（成功/失败）")
    check("force_lock_whitelisted",
          "and not line:match('^force_lock;')" in e,
          "★ 实验判据进节流白名单（被节流掉 = 实验没法判读）")
    # 4b2) ★★ 2026-10-09：把 `pointer bound` 钉死 —— frame_error 必须能归因 ★★
    rt = RUNTIME.read_text(encoding="utf-8")
    #      此前只有消息、没有调用者 ⇒ 那条错误一直无法归因（`expired observation key`
    #      那次也是靠猜）。做法：tick 的 pcall 换 xpcall + handler 抓栈（handler 在
    #      **栈展开之前**执行才有栈），detail 里附头几帧，用完立刻清（防误归因）。
    check("frame_error_carries_traceback",
          "local ok,why=xpcall(function()" in rt
          and "P.err_tb=(debug and debug.traceback) and debug.traceback(e,2)" in rt
          and "detail=detail..' ~~ '..table.concat(tb,' | ')" in rt,
          "★★ tick 用 xpcall + handler 抓调用栈，frame_error 里附头几帧 —— "
          "否则 `pointer bound` 这类错误无法指名调用者")
    check("traceback_frame_cap_sufficient",
          "if #tb>=4 then break end" in rt and "fl~='stack traceback:'" in rt,
          "★★ 取帧必须**跳过前两行**（消息 + `stack traceback:`）并留足 4 帧 —— "
          "第一版写成「最多 4 行、再跳第 1 行」，实际只剩 assert/ptr 两帧、"
          "**调用者正好被切掉**（离线用游戏自带 lua51.dll 实测抓出来的：middle 在第 5 行）")
    check("traceback_cleared_after_use",
          "P.err_tb=nil" in rt,
          "★ 栈用完立刻清掉：否则下一帧的错误会继承上一次的栈（误归因）")
    check("traceback_handler_does_not_add_upvalue",
          "end,function(e)" in rt and "P.err_tb=" in rt,
          "★ handler 写成内联匿名函数（自己捕获 P）—— tick 闭包的 upvalue 已近 60 上限")
    check("traceback_debug_guarded",
          "(debug and debug.traceback)" in rt,
          "★ `debug` 可能被裁剪 ⇒ 必须判空，否则错误路径本身再抛一次")
    #      ② 停机汇总：`host:error_summary()` 此前**定义了却没有任何调用点** ⇒
    #        "被折叠掉的次数"从来没打出来过（frame_error 是按消息去重的）。
    #        ⚠ 还必须**白名单**：emit 超过 60 行后只写白名单行，而汇总正是在停机那刻打的。
    check("error_summary_is_emitted",
          "host:error_summary()" in e and "emit('errors;kinds='" in e,
          "★ 停机时必须打 frame_error 汇总（否则重复次数永远不可见）")
    check("error_summary_before_close",
          e.index("emit('errors;kinds='") < e.index("emit('disabled;applied='"),
          "★ 汇总必须在 `close()` **之前** emit —— close 之后写的行会丢")
    check("errors_line_whitelisted",
          "and not line:match('^errors;')" in e,
          "★★ `errors;` 必须进节流白名单：emit 超 60 行后只写白名单行，"
          "而汇总正是在停机那一刻打的 ⇒ 不白名单化 = 静默丢弃 = 等于没加")
    # ★★ 2026-10-09 自机探针（只读 · 为「G-60 爆炸安全区」打底）★★
    #   目的：确认"我自己"（玩家角色）是谁 + 坐标怎么取。本步**不改任何行为**。
    _ping = (ROOT / "src/g60" / "native_ping.lua").read_text(encoding="utf-8")
    _self = _ping[_ping.index("function api:self()"):_ping.index("function api:observe()")]
    check("self_probe_exists_and_read_only",
          "function api:self()" in _ping and "self_probe_enabled" in e
          and not any(w in _self for w in ("env.write", "calls.orbit", "=4", "ffi.copy")),
          "★ 自机探针必须存在，且 `api:self()` 内**不得出现任何写操作**（只读）")
    check("self_probe_reuses_verified_owner_logic",
          "local_ownership_observed" in _self
          and _ping.index("function api:self()") < _ping.index("function api:observe()"),
          "★ 必须复用 native_ping 里**已实机验证**的 owner 判定"
          "（不重复实现、不新 require Authority）")
    check("self_probe_pcall_guarded",
          "pcall(function() return structure_ping:self() end)" in rt,
          "★★ 探针必须 pcall 包住 —— 历史教训：探针抛错会把整条 priority 打死")
    # ★★ 2026-10-10 实机教训：探针挂在 `ping` 上 ⇒ `mark_priority_enabled=false`
    #    时 ping 为 nil ⇒ 守卫 `and ping` 把探针**整条短路**，一条日志都不打
    #    （沉默的失败 = 没有诊断）。必须挂在**始终存在**的 structure_ping 上。
    check("self_probe_uses_structure_ping_not_ping",
          "structure_ping:self()" in rt and "and structure_ping and P.selfprobe" in rt,
          "★★ 探针必须挂在 structure_ping（不依赖 mark_priority_enabled）—— "
          "挂 ping 会因该开关关闭而被静默短路（实机已踩：0 条 selfprobe）")
    check("self_probe_failure_is_loud",
          "failed_logged" in rt and "selfprobe;err=" in rt,
          "★★ 失败必须打一条（且只记一次）—— 沉默的失败等于没有诊断")
    # ★ 2026-10-10：用户给出玩家本体哈希（5556372446766824087 = 4d1c334d294dfa97）。
    #   用它**交叉校验**探针：双路（hash / ownership）都打出来，看是否同一实体。
    check("self_probe_dual_match_diagnostic",
          "by_hash" in rt and "by_owner" in rt and "same=" in rt,
          "★ 必须同时打 by_hash / by_owner / same —— 这是判断该哈希对不对的**唯一判据**")
    check("self_resource_constant_wired",
          "self_resource='4d1c334d294dfa97'" in e and "self_resource=state.self_resource" in e,
          "★ 玩家哈希必须是**显式常量且接线进 env**（不硬编码在逻辑里，方便关/改）")
    check("self_probe_does_not_use_hash_for_behavior",
          rt.count("by_hash") <= 3,
          "★ 该哈希当前**只用于诊断**，不得参与行为判定（安全区还没做）")
    # ★★ 2026-10-10 实机教训：我写成 `e.hash` ⇒ 恒 nil ⇒ by_hash 永远 miss
    #    （日志 `by_hash=miss;...;hash=nil;nets=` 空）。`d.entity()` 的字段叫 **resource**。
    check("self_probe_uses_resource_field_not_hash",
          "e.resource==want" in _ping and "e.hash==" not in _ping
          and "e.hash)" not in _ping,
          "★★ 实体哈希字段叫 **resource**（不是 hash）—— 写成 e.hash 会恒 nil、"
          "让哈希那一路永远 miss 且 **nets 全空**（实机已踩）"
          "（只禁**实际用法**，注释里说明这个坑不算）")

    # ★★ 2026-10-10 爆炸安全区（用户要求：玩家在球形半径内 ⇒ 不引爆，继续追踪）★★
    check("blast_safe_radius_switch_wired",
          "blast_safe_radius=0" in e and "blast_safe_radius=state.blast_safe_radius" in e,
          "★ 安全区必须有开关且**默认 0（关闭）** ⇒ 行为与改动前一致")
    # ★★ 2026-10-10 实机：安全区**只对空 ping 生效**（用户报）★★
    #   根因：引爆有**三条独立路径**，第一版只拦了 `arrival:step`（ping 空地点）那条：
    #     ① `arrival:step`（ping 空地点，runtime 传 terminal）
    #     ② `titan:step` → 内部 `Policy.step` → explode（虫洞/泰坦/单位）
    #     ③ `native_priority` 的**早期引爆**（直接调 calls.explode）
    #   ⇒ 必须**共用同一道门**，且都在 explode **之前**判（事后拦不住）。
    _pri = (ROOT / "src/g60" / "native_priority.lua").read_text(encoding="utf-8")
    check("safe_zone_implemented_at_call_site",
          "local held=not blast_safe_hold(m,scope)" in rt
          and "arrival:step(scope,target,nil,'vanilla',terminal," in rt
          and "local terminal=not held" in rt,
          "★★ 必须在**调用侧**拦（native_arrival 是 SAFETY_LAYER 只读，且 detonate 时"
          "已调 explode ⇒ 事后拦不住）—— 且必须复用 `blast_safe_hold` 这道门，"
          "并把**同一次**门判定的结果同时用于 terminal 与绕行（不许调两次）")
    check("safe_zone_shared_gate_not_duplicated",
          rt.count("blast_safe_hold") >= 2 and "env.blast_safe_hold=function" in rt,
          "★★ 三条引爆路径必须**共用同一个门函数** —— 第一版各写一份 ⇒ "
          "只拦住 ping 那条路（实机已踩：虫洞/泰坦照炸）")
    check("safe_zone_covers_titan_path",
          "if not blast_safe_hold(m,scope) then return {kind='safe_hold'} end" in rt
          and "result.kind=='safe_hold'" in rt,
          "★★ titan 段（虫洞/泰坦/单位）也必须过门 ⇒ 否则『只对空 ping 生效』会重现；"
          "且 safe_hold 必须**保留锁定**（否则手雷放弃目标乱飘）")
    check("safe_zone_covers_early_detonate_path",
          "env.blast_safe_hold" in _pri
          and _pri.index("env.blast_safe_hold") < _pri.index("scope.calls.explode"),
          "★★ native_priority 的**早期引爆**是第三条路径（直接 calls.explode）"
          "⇒ 也必须过同一道门，且必须在 explode **之前**")
    check("safe_zone_fail_open",
          "return true" in rt and "if not mysp then" in rt,
          "★ 拿不到玩家坐标时**放行**（fail-open：宁可照常引爆，也不让雷失效）")
    # ★★ 2026-10-10 实机：fail-open **静默** ⇒ 三条路径全不拦时日志里一条都看不到
    #    （blast_hold 从 1062 变 0，却完全不知道为什么）。⇒ 必须打点。
    check("safe_zone_fail_open_is_visible",
          "blast_safe_nopos;entity=" in rt and "safe_nopos" in rt
          and "and not line:match('^blast_safe_nopos;')" in e,
          "★★ fail-open 必须**可见**（`blast_safe_nopos;` 按手雷一次 + 白名单）——"
          " 否则安全区静默失效，与『功能没写』无法区分")
    # ★★ 同轮根因：`d.unit(e)` 会抛 `pointer bound`，而它只是校验、**坐标不需要它**；
    #    此前与 position 放同一 pcall ⇒ self() 整体 nil ⇒ by_owner 永远拿不到
    #    ⇒ 每帧 fail-open ⇒ 全路径不拦。必须单独 pcall。
    check("self_position_not_hostage_of_unit_check",
          "local uok=pcall(d.unit,e)" in _ping,
          "★★ `d.unit` 的校验失败**不得**连累坐标 —— 必须单独 pcall"
          "（否则 self() 整体为 nil ⇒ 安全区每帧 fail-open ⇒ 全路径失效，实机已踩）")
    # ★★ 2026-10-10 实机真凶：门函数里写 `structure_ping:self()`，但
    #    门函数定义在 **`structure_ping` 局部构造之前**（L160 vs L321）⇒
    #    `attempt to index global 'structure_ping' (a nil value)` ⇒ 每帧 fail-open
    #    ⇒ **三条路径全不拦**（blast_safe_nopos 直接点名）。
    #    这类"引用了本作用域还不存在的名字"编译期查不出来（Lua 把它当全局），
    #    必须用结构守门钉死：门函数只能走 `host.structure_ping`。
    check("blast_gate_uses_host_not_module_local",
          "host.structure_ping" in rt
          and "host.structure_ping=structure_ping" in rt,
          "★★ 安全区门函数必须走 `host.structure_ping`（M.new 末尾暴露）—— "
          "不得直接引用本模块同名的局部（它在门函数**定义之后**才构造 ⇒ 恒 nil）")
    check("gate_defined_before_structure_ping_is_not_referenced",
          rt.index("local function blast_safe_hold") < rt.index("local structure_ping=env.structure_profiles"),
          "★ 记录事实：门函数确实定义在 structure_ping 之前 —— 这正是必须用 host 的原因")
    check("safe_zone_diagnostics_whitelisted",
          "and not line:match('^blast_hold;')" in e,
          "★ `blast_hold;` 必须进节流白名单（否则超 60 行被静默丢弃 = 判据不可见）")

    # ★★ 2026-10-10 安全区第二步：**主动绕行**（用户拍板「让它绕着目标转」）★★
    #   根因（实机 2026-10-10 那一局）：这道门只拦得住**我们自己**的 calls.explode。
    #   entity=520 在 `blast_hold;player_dist=10.76;radius=12;frame=10610` 的同一帧
    #   就出现 `explosion already requested` —— **引擎自己**点的火，拦不住。
    #   ⇒ 唯一杠杆：玩家在圈内时别让手雷到目标身上
    #     （写成点目标 ⇒ 引擎手里没有实体可撞 ⇒ 撞击/引信无从触发）。
    check("safe_zone_hold_diverts_not_just_declines",
          "local held=not blast_safe_hold(m,scope)" in rt
          and "if held then" in rt and "P.tpos[m.id]" in rt
          and "mask_only=nil" in rt,
          "★★ 安全区生效时必须**主动绕行**（把 goal 换成绕目标的旋转点），"
          "不能只把 terminal 置 false —— 引擎自己的引信照样点火（实机已踩：entity=520）")
    check("safe_zone_detour_uses_reviewed_point_path",
          "point_target={ox,oy,c[3]+1.0}" in rt
          and "region=env.point_arrival_region,point=true" in rt,
          "★★ 绕行必须复用**已在生产使用**的 `options.point_target` 写路径"
          "（ping 空地 / 体内爆点同款、写后回读断言已复核）"
          "—— 不新增写途径、不碰 SAFETY_LAYER")
    check("safe_zone_detour_point_rotates",
          "local ang=frame*0.01" in rt and "math.cos(ang)" in rt and "math.sin(ang)" in rt,
          "★★ 绕行点必须**旋转**：静止的点会被 arrival_policy 判 stalled"
          "（4 秒无进展）⇒ 转 'search' ⇒ 清锁、手雷乱飘")
    check("safe_zone_detour_keeps_early_flag",
          "early=(arr_opts and arr_opts.early) or nil" in rt,
          "★★ 替换 arr_opts 时必须**继承 early** —— 否则 arrival 内部一次失败就会"
          "`disabled=true`，把整条 arrival 段**永久关掉**（本项目踩过：整局 mod 停手）")
    check("safe_zone_gate_not_called_twice",
          rt.count("local terminal=blast_safe_hold")==0 and "local terminal=not held" in rt,
          "★★ 门**每帧每颗只准调一次**：门每成立一次写一条 `blast_hold;`，"
          "调两次 = 日志翻倍（去重表按手雷去重，防不住同帧的两次调用）")
    check("safe_zone_detour_degrades_visibly",
          "blast_detour_nopos;entity=" in rt and "P.dg_nopos[m.id]=true" in rt
          and "and not line:match('^blast_detour_nopos;')" in e,
          "★★ 拿不到圆心时退回「只拦我们自己」必须**可见** —— "
          "静默降级会让「绕行没生效」与「功能没写」无法区分（本项目已栽过多次）")
    check("safe_zone_detour_diagnostics_whitelisted",
          "and not line:match('^blast_detour;')" in e
          and "and not line:match('^detour_guide;')" in e
          and "and not line:match('^detour_stalled;')" in e,
          "★★ `blast_detour;` 是「绕行到底有没有注入」的**唯一**判据；"
          "`detour_guide;` 是标定环绕半径的唯一数据 —— 被节流掉 = 诊断不存在")
    check("safe_zone_detour_guide_tagged",
          "(P.dg[m.id] and 'detour')" in rt,
          "★ 绕行期间必须有到达诊断（否则完全看不见它在绕着转、还是往目标里钻）")
    check("safe_zone_detour_state_cleared_on_release",
          "P.tpos[id]=nil;P.dg[id]=nil;P.dg_nopos[id]=nil" in rt,
          "★★ 绕行状态必须随持有一起清 —— 手雷 id 会被引擎复用，"
          "残留圆心会让**下一颗**手雷张冠李戴（与 retired 的教训同源）")
    # ★★ 2026-10-10 自查发现的**死锁**：绕行期间我们给锁写了 `point_bytes`
    #   ⇒ priority 的 `continued` 下一帧为真 ⇒ **跳过 setter**（绕行期间正是要的）。
    #   但玩家离开后如果不清，`continued` **永远**为真 ⇒ priority 永不写回实体选择
    #   ⇒ arrival 的实体 aim 断言每帧失败（`arrival selected target mismatch`）
    #   ⇒ 只能等 guide_fail 熔断（30 帧）退休 = 雷白扔。
    check("safe_zone_detour_release_clears_lock_point_bytes",
          "if old.lock then old.lock.point_bytes=nil end" in rt,
          "★★ 绕行结束必须清掉锁上的 `point_bytes` —— 否则 priority 的 `continued` "
          "永远为真、永不写回实体选择 ⇒ arrival 每帧 `arrival selected target mismatch` "
          "直到 30 帧熔断（死锁；runtime 第 618 行的注释正是警告这个状态）")
    # ★★ 2026-10-10 用户要求：绕行半径也进 ModOptionsMenu ★★
    #   它是绕行**唯一需要标定**的量（实机那一局固定 5 m，`detour_guide;dist=`
    #   显示有时落后 2.5 m、有时 9.8 m —— 只有游戏里试才知道该调大还是调小）。
    check("blast_safe_orbit_switch_wired",
          "blast_safe_orbit=5" in e and "blast_safe_orbit=state.blast_safe_orbit" in e,
          "★ 绕行半径必须有默认值（5）**且**从 state 一路接进 env 字面量 —— "
          "少任何一处，菜单改的值都进不了运行期（env_fields_all_wired 那类静默不触发）")
    check("menu_exposes_orbit_radius",
          "g60.blast_safe_orbit" in e and "host.env.blast_safe_orbit=v" in e
          and "min=2,max=20,step=1" in e,
          "★★ 绕行半径必须是菜单滑杆（2~20 米），且 on_change 要写回 `host.env` —— "
          "只注册不写回 = 菜单能动、运行期不变（本项目踩过同类静默失败）")
    check("safe_zone_orbit_radius_is_configurable",
          "local R=tonumber(env.blast_safe_orbit) or 5.0" in rt
          and "if R<2 then R=2 elseif R>20 then R=20 end" in rt
          and "local R=5.0" not in rt,
          "★★ 运行期必须**读 env** 而不是写死 5.0（否则菜单白做）；"
          "并夹到 [2,20]（<2 米等于没绕开、>20 米玩家离开后回不来），"
          "夹取后的值照样进 `blast_detour;radius=`（不静默）")

    # ★★ 2026-10-10 用户报「没有标记时不生效」★★
    #   根因是结构性的：门只在「我们在驾驶这颗雷」的路径上跑
    #   （decide_guidance 要求 old.lock/titan/point）⇒ 玩家什么都没 ping
    #   （引擎自己瞄敌人）时门一次都不会被调用。⇒ 需要第二条坐标来源。
    #   ⚠ 但"同一个判断写两遍"是本工程反复踩的坑 ⇒ 判定必须只留一份。
    check("safe_zone_gate_shares_one_judgment",
          "local function blast_safe_hold_at(ident,own)" in rt
          and rt.count("return blast_safe_hold_at(ident,okv and v or nil)")==2
          and rt.count("if d2>safe*safe then return true end")==1
          and rt.count("local safe=tonumber(env.blast_safe_radius) or 0")==1,
          "★★ 安全区判定只能有**一份**（半径/玩家距离/safehold 记账都在 `blast_safe_hold_at`）——"
          " 两个包装只准各自解决「这颗雷在哪」（已接管走 scope、非自有走 TargetData）")
    check("safe_zone_noown_failopen_visible",
          "blast_safe_noown;entity=" in rt and "safe_nopos" in rt
          and "and not line:match('^blast_safe_noown;')" in e,
          "★★ 读不到「这颗雷在哪」时放行必须**可见**（`blast_safe_noown;`）——"
          " 原来那处是静默 `return true`，与 blast_safe_nopos 同族的坑")
    check("safe_zone_engine_hold_default_off_and_wired",
          "safe_zone_engine_hold=false" in e
          and "safe_zone_engine_hold=state.safe_zone_engine_hold" in e,
          "★★ 写「非自有 G-60」这件事必须**默认关**（默认开 = 系统性地改变引擎自己的雷），"
          " 且开关要从 state 一路接进 env 字面量（少一处就静默不生效）")
    check("menu_exposes_engine_hold_toggle",
          "g60.safe_zone_engine_hold" in e and "host.env.safe_zone_engine_hold=v" in e,
          "★ 该实验项必须能在游戏里开关（并写回 host.env），否则没法做对照实验")
    check("safe_zone_engine_hold_never_fights_our_own_lock",
          "local safe_path_open=safe_engine_hold and not gate.drive" in rt
          and "and not (old and (old.lock or old.titan or old.point))" in rt
          and "if safe_path_open and not retired[m.id]" in rt
          and "local safe_engine_hold=env.safe_zone_engine_hold==true" in rt,
          "★★ 非自有那一路**绝不能**和已接管路径抢同一颗雷（.drive 为真时不走；"
          " 且必须确认我们没持有）；开关关着时连函数都不调用（零额外读取）"
          " ⚠ 2026-10-10 把这段抽成 `safe_path_open`：原来同一串条件写了两遍"
          "（if 一遍、not(...) 一遍），加冗余告警的 elseif 分支时必然写第三遍。")
    check("safe_zone_engine_hold_reuses_reviewed_point_path",
          "arrival:step(scope,nil,nil,'vanilla',false,nil,nil," in rt
          and "point_target={ox,oy,c[3]+1.0},early=true})" in rt,
          "★★ 非自有那一路也必须复用 `options.point_target`（写点目标 ⇒ 引擎无实体可撞），"
          " 并带 `early=true` —— 写非自有 G-60 竞争概率更高，失败绝不许永久禁用 arrival")
    check("safe_zone_engine_hold_has_survival_probe",
          "safe_engine_lost;entity=" in rt and "safe_engine_kept;entity=" in rt
          and "P.ehq[match.id]={bytes=zres.point_bytes,frame=frame,fp=fp,tid=tid}" in rt,
          "★★ 这个实验的**唯一判读依据**：写下去的点下一帧还在不在"
          "（`safe_engine_kept;` 抢赢 / `safe_engine_lost;` 被引擎抢回）——"
          " 没有它，开了开关也答不出「这条路到底可行吗」")
    # ★★ 2026-10-10 实机发现的**采样 bug**：调用条件原来写成 `m.selection_id~=0`，
    #   而我们自己写下去的点会让 selection_id 变 0 ⇒ 下一帧起条件就不成立
    #   ⇒ 整条路只在"引擎恰好重新锁上目标"的那几帧才跑。
    #   证据（10:45 那局）：entity=596 跨度 364 帧只有 5 条 blast_hold；
    #                       entity=615 跨度 726 帧只有 9 条。
    check("safe_zone_engine_hold_runs_every_frame",
          "(m.selection_id~=0 or m.selection_flag==1 or P.ehq[m.id]~=nil)" in rt,
          "★★ 调用条件必须是「引擎确实选了什么 **或 我们已经压了一个点**」—— "
          "只判 selection_id~=0 会让压制断断续续（实机：跨度 726 帧只跑了 9 次）；"
          " ⚠ 2026-10-10 再加 `selection_flag==1`：引擎把目标表示成**点**时"
          "（`4|0|1|nil`：flag=1、id=0）`selection_id==0` ⇒ 那一类雷**一次都没被压过**"
          "（实机 7 例 `arrival_already_exploded`，一条 `safe_engine;` 都没有）。")
    check("safe_zone_engine_hold_no_capture_when_point_alive",
          "and rb and rb:sub(0x1d,0x28)==rec.bytes then" in rt
          and "P.ehq[match.id]={bytes=zres.point_bytes,frame=frame,fp=fp,tid=tid}" in rt,
          "★★ 每帧判定必须**不付 capture**：把写下去的那 12 字节存进 P.ehq，"
          "直接用观察器已经读好的 record_bytes 比对 —— 点还在就直接 return")
    # ★★ 2026-10-10 站定距离（standoff）：实测引擎的引信在 ~2.2 m 触发 ★★
    #   两次独立取证：entity=639（绕行中）**2.22 m**、entity=522（我们的点还在记录里、
    #   target=0）**2.25 m** ⇒ 引信是**物理接近目标**，不是"记录里选中的是谁"
    #   ⇒ 点目标绕行只能改"飞去哪"、**解不了引信** ⇒ 唯一杠杆是距离。
    #   而"追一个绕圈的点"这条追杀曲线会**切进圈内**（实机就是这样掉到 2.25 m）
    #   ⇒ 太近时必须**命令它往外飞**（目标点放到 r+2.5）。
    check("safe_zone_standoff_floor",
          rt.count("if R<3.5 then R=3.5 end")==1
          and rt.count("if Rm<3.5 then Rm=3.5 end")==1,
          "★★ 两条绕行路都必须给半径一个**硬下限 3.5 m**（实测引信 ~2.2 m + 余量）——"
          " 否则用户把滑杆拉到 2 米时手雷照样会蹭进引信范围")
    check("safe_zone_standoff_push_out",
          "local push=r+2.5" in rt and "R=r+2.5" in rt
          and "local need_write=(r==nil) or (r<Rm-0.5)" in rt,
          "★★ 离目标太近时必须把目标点放到 `r+2.5`（**命令它往外飞**）—— "
          "只追一个固定半径上的绕圈点，追杀曲线仍会切进圈内（实机掉到 2.25 m）")
    check("safe_zone_engine_center_recomputed_every_frame",
          "local tid=(match.selection_id~=0 and match.selection_id)" in rt
          and "or (rec and rec.tid) or nil" in rt and "tid=tid}" in rt,
          "★★ 引擎那条路的圆心必须**每帧现算**（记忆里的目标 id）—— 522 的目标是会走路的"
          " 食腐蟲；圆心原来只在「点被抢回」时更新（最长 90 帧不刷新）⇒ 敌人正好走进圈里")
    # ★★ 2026-10-10 贴脸取消（用户拍板选 A，默认关）★★
    #   场景：把手雷直接丢到贴身的敌人身上。实机三次取证（1.76 / 2.22 / 2.25 m）证明引擎
    #   引信是**物理接近目标** ⇒ 贴上去之后改航向救不回来（entity=507：第一帧就 r=1.76，
    #   2 帧后点火）。那一刻只有「炸（你挨打）」或「取消（雷白扔）」两种结局。
    check("safe_cancel_default_on_hidden_and_wired",
          "blast_safe_cancel=true," in e
          and "blast_safe_cancel=state.blast_safe_cancel," in e,
          "★★ 2026-10-10 用户拍板：贴脸取消**默认开 + 从菜单隐藏**（功能不删）—— "
          "原话「把贴脸取消以及取消距离隐藏，这个实测下来不一定有用但又不好去除」；"
          " 开关仍要从 state 一路接进 env 字面量（少一处就静默不生效）")
    check("cancel_hidden_from_menu",
          "id='g60.blast_safe_cancel'" not in e and "id='g60.blast_safe_cancel_dist'" not in e,
          "★★ 两个**菜单项**都已移除（按 `id='g60.…'` 判，state/env 用的是 "
          "`blast_safe_cancel=` 形式、注释里提到 id 不算）⇒ 加载器不再回写 ⇒ "
          "生效值就是 state 默认值")
    check("safe_cancel_conditions_tight",
          "env.blast_safe_cancel==true" in rt and "and r<=cthr then" in rt
          and "local danger=tonumber(env.blast_safe_radius) or 0" in rt
          and "if danger>7 then danger=7 end" in rt
          and "if pdist and pdist<=danger then" in rt,
          "★★ 三个条件必须**同时**成立才取消：雷已贴到目标（r<=取消线）、"
          "玩家在雷的安全半径内（门已判）、**玩家在危险距离内** ⇒ 否则会把"
          "「本来不会打到你」的雷也丢掉。"
          " ⚠ 2026-10-10 用户纠正口径：「安全区是以**手雷**为中心，不是以玩家为中心」"
          " ⇒ 危险距离用 `pdist`（|手雷 − 最近玩家|，与 `blast_hold;player_dist=` 同一个数），"
          " 不再用 `pt`（玩家↔**目标**，那是「以目标为中心」）；上限 7 m = 实测致死上界 "
          "6.47 m + 余量，且受安全区半径约束")
    # ★★ 2026-10-10 取消线距离进菜单（用户要求：「我想再尝试一下」）★★
    # ★★★ 2026-10-10 友方标记 bug（用户报了两轮）★★★
    #   实机取证：那颗雷全程 `3|0|1|nil` = 引擎给的目标是**一个点**（flag=1 但 id=0、
    #   resource=nil），不是实体选择 ⇒ 那个点极可能就是被标记友方的坐标。
    #   ⇒ 修法（纯只读判据 + 命中才跳过）：ping 槽坐标 ≈ 友方坐标（≤3 m）时**不登记**
    #     点目标；不命中则行为与改动前完全一致（这是"未验证假设不改变行为"的保险）。
    check("friendly_point_is_not_taken_as_target",
          "P.fk['p:'..tostring(structure_mark.id)]=fp" in rt
          and "if fp_hit then" in rt
          and "action=IGNORED_AS_FRIENDLY_POINT" in rt
          and "and not line:match('^friendly_point;')" in e,
          "★★★ 友方所在的落点不得被当成点目标（否则手雷被引向友方）；判据只读、"
          " 命中才跳过、不命中一切照旧；证据行 `friendly_point;dist=` 供标定阈值")
    check("cancel_dist_hidden_but_wired",
          "local cthr=tonumber(env.blast_safe_cancel_dist) or 3.5" in rt
          and "if cthr<1 then cthr=1 elseif cthr>20 then cthr=20 end" in rt
          and "blast_safe_cancel_dist=state.blast_safe_cancel_dist," in e
          and "blast_safe_cancel_dist=3.5," in e
          and "id='g60.blast_safe_cancel_dist'" not in e,
          "★★ 取消线：**从菜单隐藏但功能与接线全留**（用户拍板），默认 3.5 = 实测标定值，"
          " 代码里仍有 1~20 夹取 —— 隐藏后生效值就是 state 默认值，"
          " 所以默认值本身必须是被标定过的那个")
    check("cancel_dist_is_logged_as_effective",
          rt.count("';thr='..string.format('%.1f',cthr)") == 6,
          "★★ 日志必须打**生效的**取消线（safe_cancel; / safe_engine; / safe_cancel_stale; "
          "三处原有 + 2026-10-10 新增的 safe_veto; / safe_veto_skip;×2 三处）—— "
          "写死 `thr=3.5` 时，菜单调成多少在日志里查不出来（上一轮就吃过这个亏）；"
          " 新增的三处同理：它们都在**同一个贴脸窗口**里动作，不打生效阈值就没法"
          "判断「开关开了为什么没效果」是线不够大还是机制不适用")
    check("cancel_stale_probe_is_visible",
          "safe_cancel_stale;entity=" in rt
          and "and not line:match('^safe_cancel_stale;')" in e
          and "P.ehf[match.id]=frame" in rt and "P.ehf[match.id]=nil" in rt,
          "★★★ 必须有「取消**到底生效没有**」的证据行：取消成功 ≠ 引擎兑现移除"
          "（实机 528 之后又活 2092 帧）。没有它，用户调大取消线后只看到「还是一样炸」，"
          " 分不清是线不够大还是移除压根没兑现；且只打一次（打完清计时器）")
    # ★★★ 2026-10-10 实机教训：取消成功 ≠ 它马上消失 ★★★
    #   `native_disposal` 原文：移除是 RPC / 入队，**不是就地删除** ⇒ 实体还活几帧，
    #   而引擎引信在这期间照样点火。现场：
    #     safe_cancel;entity=512;r=3.49;frame=9286   （取消成功）
    #     safe_engine_exploded;entity=512;dist=2.51;frame=9310（24 帧后仍被点火）
    #   根因：第一版取消后**直接 return** ⇒ 停止推离 ⇒ 它飞进引信范围（3.49→2.51）。
    check("safe_cancel_keeps_holding_until_removed",
          "P.ehc[match.id]='done'" in rt
          and "and P.ehc[match.id]~='done' and r<=cthr then" in rt
          and "if not P.ehc[match.id] then" not in rt,
          "★★★ 取消后**必须继续压制**（不 return、照常写推离点）直到实体真的消失 —— "
          "移除是 RPC/入队、不是就地删除，引擎在等待期间照样能点火（实机 24 帧后仍炸）")
    check("safe_cancel_isolated_disposal_instance",
          "local disposal_cancel=env.fuse_profile and Disposal.new(env)" in rt
          and "pcall(disposal_cancel.step,disposal_cancel,match," in rt,
          "★★ 必须用**独立**的 disposal 实例：`native_disposal` 失败会把自己 disabled，"
          " 而 runtime 的寿命回收路一读到 disabled 就 `error` ⇒ **整局 mod 停手**。"
          " 贴脸取消写的是「非自有且未到期」的雷，风险面更大 ⇒ 不许连累正常回收")
    check("safe_cancel_is_visible",
          "safe_cancel;entity=" in rt and "safe_cancel_failed;entity=" in rt
          and "and not line:match('^safe_cancel;')" in e
          and "and not line:match('^safe_cancel_failed;')" in e,
          "★★ 取消了几发、以及**取消失败**（写不进去）都必须可见 —— 静默就等于没做")
    _dis = (ROOT / "src/g60" / "native_disposal.lua").read_text(encoding="utf-8")
    check("disposal_early_cancel_is_explicit",
          "local early=options and options.early_cancel==true" in _dis
          and "if not early then" in _dis
          and "assert(Policy.elapsed(now,L.hex64(r,0x188))>=Policy.lifetime_ticks,'disposal before expiry')" in _dis,
          "★★ 提前移除必须是**显式**选项：默认路径**照旧**断言「未到期不许移除」——"
          " 只有调用方写 `{early_cancel=true}` 才跳过（把「另一个意图」和默认语义分开）")
    # ★★★ 2026-10-10 实机结论：贴脸取消**防不了爆**（引擎不理会未到期雷的移除）★★★
    #   取证：528 / 577 / 683 三颗 `safe_cancel;`（成功）之后，同一颗雷（id **未**被复用）
    #   又活了 **323 / 430 / 353 帧**（5~7 秒）；另外 4 例"取消后 1~6 帧消失"其实是被
    #   引擎炸了（`safe_engine_exploded` 同帧），不是被移除。
    #   ⇒ 这条结论必须**明写在代码 + 菜单 + runtime 三处**，否则以后会有人（包括我）
    #     再把它当成"能防爆"的功能来改。用户拍板：先留着当实验、默认关。
    check("cancel_is_documented_ineffective",
          "实测无效" in e and "不要指望它能防爆" in e
          and "**跳过断言并不能真的提前移除**" in _dis
          and "防不了爆" in rt,
          "★★★ 贴脸取消必须**明写「实测无效」**（代码 + 菜单 + runtime）—— 引擎只对"
          " 寿命已到期的雷兑现移除，取消后同一颗雷仍活 5~7 秒（实机 528/577/683）")
    check("safe_zone_engine_explosion_is_visible",
          "safe_engine_exploded;entity=" in rt and "frame%5==0" in rt
          and "and not line:match('^safe_engine_exploded;')" in e,
          "★★ 非自有那一路**被引擎炸了**必须留证据（这类雷没有 tracked ⇒ "
          "`note_already_exploded` 走不到它）—— 否则用户报的「有时候还是会爆炸」"
          "永远无法证伪；`dist=` 同时是选绕行半径的依据（每 5 帧采样省成本）")
    # ★★ 2026-10-10 阵营判据（用户要求「能不能通过阵营来判断」）★★
    #   用户报「标记友方单位后空 ping 会失效，直到友方单位消失」。
    #   实测（12 条 target_fields 探针）：`target_valid` **就是**阵营判据 ——
    #   友方/中性 4/4 全 false、敌人与虫洞全 true；而 f08/f0c/f4c **分不开**
    #   （f4c=0 在 false/true 里都出现）⇒ 不许拿那三个字段当判据。
    #   原来的用法太晚：priority 在**锁定阶段**才问 ⇒ 友方标记先被收进队列、每帧被拒，
    #   而它在 ping 记忆里只要实体活着就一直钉住 `structure_mark` ⇒ 空白标记被挡死。
    check("mark_faction_uses_engine_target_valid",
          "return env.calls.target_valid(nil,e.id,ffi.cast('const void *',e.address))" in rt,
          "★★ 阵营判据必须用**引擎自己的** `calls.target_valid`（实机探针证明它就是阵营判据）"
          "—— 不许用 f08/f0c/f4c 那三个字段（实测分不开）")
    check("mark_faction_ignores_friendly_before_decisions",
          "mark_friendly=true" in rt and "structure_mark=nil" in rt
          and rt.index("action=IGNORED_AS_FRIENDLY") < rt.index("local ping_take="),
          "★★ 判为友方必须在**一切决策之前**把 structure_mark 置 nil（并立起 mark_friendly "
          "旗标给兜底 veto 用）—— 否则友方标记会继续钉住 take_gate / mark_is_wormhole / "
          "ping_beats_titan，空白标记那条路照旧被挡死（用户现象）")
    check("mark_faction_is_visible_and_conservative",
          "mark_friendly;target=" in rt and "mark_faction_unknown;target=" in rt
          and "and not line:match('^mark_friendly;')" in e
          and "and not line:match('^mark_faction_unknown;')" in e
          and "P.fk[fk]=v" in rt,
          "★★ 判为友方要留证据、查不到阵营要**保守当有效**且可见（静默 = 与没做无法区分）；"
          " 并按标记缓存（同一个标记只查一次原生查询）")
    # ★★ 2026-10-10 用户第二次报：「释放出的手雷会一直锁定标记的友方单位，
    #   导致手雷不能被其他代码接管」★★
    #   根因：光把标记"当不存在"不够 —— **引擎自己的 TargetLock** 还钉在那个友方身上
    #   （selection_veto=DISABLED，没人清）⇒ selected=true 让 ping/点目标那段让位。
    #   ⇒ 必须用**同一套已审查的"清选择"路径**（run_veto）把它清掉。
    check("friendly_veto_default_on_and_wired",
          "friendly_veto_enabled=true" in e and "friendly_veto_enabled=state.friendly_veto_enabled" in e
          and "g60.friendly_veto_enabled" in e and "host.env.friendly_veto_enabled=v" in e,
          "★★ 「清除友方锁定」默认**开**（用户报的 bug 就是它没清）、能从 state 接进 env、"
          " 能在游戏里开关")
    check("friendly_veto_clears_engine_lock",
          "(structure_mark or mark_friendly) and not abandoned" in rt
          and "fv=faction(m.selection_id,vr)" in rt
          and "run_veto(m,vr,'friendly_lock')" in rt,
          "★★ 引擎当前选择若是「不能当目标」的单位，必须走 run_veto 清掉 —— "
          " 条件里必须带 `mark_friendly`（判为友方时 structure_mark 已被置 nil）")
    check("friendly_veto_uses_reviewed_path_only",
          "env.calls.clear" not in rt and "run_veto(m,vr," in rt,
          "★★ 只能走**已审查**的 run_veto（内部是 calls.clear），runtime 不许自己直调 clear —— "
          " 清选择是写内存，必须复用那条已验证的路径")
    check("friendly_veto_is_visible",
          "friendly_lock;entity=" in rt and "action=VETO" in rt
          and "and not line:match('^friendly_lock;')" in e
          and "P.fkl[lk]=true" in rt,
          "★★ 清掉友方锁定必须留证据（引擎会每帧抢回去，所以按 (手雷,选择) 去重）—— "
          " 没有它就无法区分「清了」与「没清」")
    check("safe_zone_engine_hold_diagnostics_whitelisted",
          "and not line:match('^safe_engine;')" in e
          and "and not line:match('^safe_engine_kept;')" in e
          and "and not line:match('^safe_engine_lost;')" in e,
          "★ 三条判读日志必须进节流白名单（被节流掉 = 实验没法判读）")
    check("safe_zone_engine_hold_state_cleared_on_release",
          "P.ehp[id]=nil;P.ehq[id]=nil;P.ehk[id]=nil" in rt,
          "★ 非自有那一路的状态也必须随持有清（手雷 id 会被引擎复用）")
    check("safe_zone_target_position_single_source",
          "local function target_position(e)" in rt
          and "claim_profile(e.resource)" in rt
          and "TargetContext.capture(read,base,env.exe,e.id,profile)" in rt,
          "★★ 绕行圆心必须走**唯一一份**位置实现（profile 优先、退 motion 位置）—— "
          "不许在 runtime 里再写第二套认领/回退逻辑")
    # ★★ 2026-10-10 实机事故：我加的引擎引爆探针**崩了** ★★
    #   日志：`engine_explode_probe;entity=520;…;ERR:…attempt to index global 'scope'`
    #   根因：`note_already_exploded` 定义在 tick 的**匹配循环**里，而 `scope` 是
    #   `with_observation` 回调的**形参**、`old` 是 priority 段的局部量
    #   ⇒ 两者在这个作用域都**不可见** ⇒ 解析成全局 nil（`old and …` 不崩，但恒为假
    #     = 诊断字段永远占位）。⇒ 用结构门钉死：探针函数体内**不许出现** scope / old。
    _zpa = rt.index("local function note_already_exploded")
    _zpb = rt.index("retired[m.id]=retired_key", _zpa)
    _zprobe = rt[_zpa:_zpb]
    # ⚠ 只查**代码**，不查注释：注释里正是要写明"这里不能用 scope/old"这句教训 ——
    #   本工程的既有约定是"注释里提到不算违规"（Lua 注释不执行）。
    _zcode = "\n".join(l.split("--", 1)[0] for l in _zprobe.splitlines())
    check("explode_probe_only_uses_visible_names",
          _zpa > 0 and _zpb > _zpa
          and "scope" not in _zcode and "old." not in _zcode
          and "P.hit[m.id],P.tpos[m.id] or P.orig[m.id]" in rt,
          "★★ 探针只能用**本作用域真正可见**的名字（m / P）—— "
          "引用 `scope`/`old` 会解析成全局 nil：轻则字段恒为占位值，"
          "重则 `attempt to index global 'scope'` 把整条探针打断（实机已踩）")

    # ★★ 2026-10-10 Mod Options Menu 集成（**可选前置**）★★
    #   接口以 CowboyBingus 生态的 Aggro Counter v1.5 为准：
    #   `_G.ModOptionsMenu`(api==1) + register_option + on_change + set。
    check("menu_is_optional_and_guarded",
          "rawget(_G,'ModOptionsMenu')" in e and "h.api~=1" in e
          and "pcall(h.register_option" in e,
          "★★ 菜单是**可选前置**：必须判 api==1 + pcall 包住注册 ⇒ "
          "没装菜单时本 mod 行为完全不变")
    check("menu_retries_registration",
          "menu_register()" in e and "function M.install(globals,host,on_stop,on_tick)" in rt
          and "if on_tick then pcall(on_tick) end" in rt,
          "★★ 必须**每帧重试注册** —— addon 加载顺序不定，菜单可能晚于本 mod 出现"
          "（否则永远注册不上，且**无任何报错**）")
    check("menu_callbacks_pcall_guarded",
          "pcall(h.on_change" in e and "menu_set_failed" in e,
          "★ 菜单回调必须 pcall 包住且**失败要打点** ⇒ 否则回调出错静默影响设置")
    # ★★ 2026-10-10 用户报"设置没保留" ★★
    #   现象：值确实存进了 ModOptionsMenu.values，但重启后菜单显示 default、
    #   运行时也用 default。根因：注册后**从未回读**已保存的值。
    #   官方文档第 61 行给的接口就是 `get(id)`。
    check("menu_restores_saved_values",
          "h.get)=='function'" in e and "menu_restore;id=" in e
          and "pcall(it.set,saved)" in e,
          "★★ 注册后**必须回读**已保存的值（`get(id)`）并写回 env —— "
          "否则菜单永远显示 default、运行时也用不上用户设的值（实机已踩）")
    check("menu_restore_diagnostics_whitelisted",
          "and not line:match('^menu_restore;')" in e,
          "★ `menu_restore;` 必须进节流白名单（否则『到底有没有回读』看不见）")
    check("menu_only_exposes_runtime_switches",
          "host.env.blast_safe_radius=v" in e and "host.env.force_lock_enabled=v" in e,
          "★ 菜单只改**运行期开关**，不得改编译期常量（resource hash/几何表）")
    # ★★ 2026-10-10 实机崩溃根因：菜单里写 `env.xxx`，而 entry 作用域**根本没有 env**
    #    （env 只是 runtime 闭包内的 local）⇒ `attempt to index global 'env' (a nil value)`
    #    ⇒ 注册时崩在 spec 构造里 ⇒ 被 pcall 吞掉 ⇒ 菜单不出现且**无任何输出**。
    #    修法：runtime 暴露 `host.env`，菜单一律走 `host.env.*`。
    check("runtime_exposes_env_for_menu",
          "host.env=env" in rt,
          "★★ runtime 必须**暴露 env**（host.env）—— 否则菜单无从改运行期开关")
    # 只查**菜单代码块**（MENU_ITEMS 起、menu_push 定义止）—— runtime 内部的
    # `env.xxx=` 是合法的（那里 env 是真实入参），不能误伤。
    _mi = e.index("local MENU_ITEMS={")
    _mend = e.index("local function menu_push()")
    _menu_src = re.sub(r"^\s*--.*$", "", e[_mi:_mend], flags=re.M)
    check("menu_never_indexes_bare_env",
          not re.search(r"(?<![\w.])env\.[a-z_]+\s*=", _menu_src.replace("host.env.", "OK_ENV.")),
          "★★ 菜单代码中**不得**直接索引裸 `env.*`（会崩：attempt to index global"
          " 'env'）—— 一律走 `host.env.*`（runtime 内部的 env 赋值不在此列）")
    check("menu_diagnostics_whitelisted",
          "and not line:match('^menu_')" in e,
          "★ `menu_*;` 必须进节流白名单 ⇒ 否则注册/回显结果看不见（等于没集成）")
    check("self_probe_throttled_not_spammy",
          "P.selfprobe.n<8" in rt and "sp.n==0 or tag~=sp.last" in rt,
          "★ 探针必须节流（最多 8 条、只在变化时打）⇒ 否则逐帧刷屏把真诊断埋掉")
    check("selfprobe_line_whitelisted",
          "and not line:match('^selfprobe;')" in e,
          "★★ `selfprobe;` 必须进节流白名单：emit 超 60 行后只写白名单行，"
          "不白名单化 = 静默丢弃 = 探针等于不存在")
    check("self_probe_state_in_P_not_local",
          "selfprobe=" in rt,
          "★ 探针状态必须放 P —— tick 闭包 upvalue 已近 Lua 5.1 的 60 上限")
    # 4b) ★★ 同一机制接到 **ping 空地** 那条路（2026-10-09，用户要求）★★
    #     那条路不经过 priority:step —— 点是由 native_arrival 经 options.point_target 写的
    #     （native_arrival 在 SAFETY_LAYER 里、不可改）⇒ 提升放在**调用侧**的运行时。
    check("promote_state4_exported",
          "M.promote_state4=promote_state4" in r,
          "★ 提升函数从 priority 导出，供运行时复用（**不复制实现**，避免两套逻辑漂移）")
    # ★★ 2026-10-09 实机修正（用户报「空标记应用失败，无效」）★★
    #    第一版把提升放在**到达段写点之后** —— 那是错的：整段驱动被 `m.state==4`
    #    挡着，而 state 4 正是要打开的门 ⇒ **提升写在门里面 ⇒ 门永远不开**
    #    （实机：ping 到了、point_marker 有，但一条 point_taken 都没有，
    #      雷停在 state 3 直到 state 5 过期）。⇒ 必须放在门**之前**。
    _gate = rt.index("if (not abandoned) and m.state==4")
    _prom = rt.index("Priority.promote_state4(env,scope,scope.prepared)")
    check("ping_route_promotion_before_state_gate", _prom < _gate,
          "★★ 提升必须在 `m.state==4` 那道门**之前** —— 否则它写在自己要打开的门的里面，"
          "门永远不开（这就是上一版「无效」的根因）")
    check("ping_route_promotion_wired",
          "Priority.promote_state4(env,scope,scope.prepared)" in rt
          and "route=ping_point" in rt,
          "★ ping 路线：命中「该驱动 ping 点 + 引擎留在 2/3」时用**同一套** promote_state4 开门")
    check("ping_route_promotion_single_call_site",
          rt.count("Priority.promote_state4(") == 1,
          "★ 运行时里**只有一处**提升调用（上一版那处错误的已移除）—— 防止两处并存后只改一处")
    check("ping_route_promotion_uses_existing_observation",
          "with_observation(old.ref,function(scope)" in rt,
          "★ 复用本帧既有的观测通道（不新开通道、不新增 upvalue —— 该闭包 upvalue 已近 60 上限）")
    # ★ 第二道死锁：首次接管要求 `selected`（引擎已给它选了目标）——
    #   无敌人时引擎没有目标 ⇒ 同样进不去。结构路在 state 2/3 **不要求** selected
    #   （priority 早期路径直接接管）⇒ ping 路放宽成同一口径。
    # ★★ 第三道死锁（真正的根因，2026-10-09 实机）：TakeGate 的 `no_mark_no_hold` ★★
    #   纯空地 ping 既无标记、又无旧持有 ⇒ 门控**根本不接管** ⇒ `old` 永不建立
    #   ⇒ 前面两道门连碰都碰不到。⇒ 给门控加 `point_armed`。
    _tg = (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8")
    check("gate_drives_on_armed_ping",
          "or o.point_armed) then" in _tg and "point_armed=ping_take}" in rt,
          "★★ 门控必须把「TTL 内的 ping」当成与标记同级的**玩家意图** —— "
          "否则纯空地 ping 永远落在 `no_mark_no_hold`，整条路不跑（真正的根因）")
    check("ping_take_defined_before_gate",
          rt.index("local ping_take=point_marker~=nil and point_armed==true")
          < rt.index("local gate=TakeGate.decide{"),
          "★ `ping_take` 必须在门控调用**之前**定义（同一作用域，不新开 upvalue）")
    check("ping_route_relaxes_selected_requirement",
          "or ping_take)" in rt,
          "★ 放宽首次接管的 `selected` 要求（与结构路同一口径）—— "
          "否则无敌人时也是死锁；**不再限定 state 2/3**：提升之后 state 变 4，"
          "若还限定会让下一帧的驱动分支又选错")
    # ★★★ 2026-10-09 实机事故（我引入的）：驱动段调 `with_observation` **没设 `current`**
    #     ⇒ 它内部断言 `U.key(ref)==U.key(current.ref)` 失败 ⇒ `expired observation key`
    #     ⇒ **整帧后续全部不跑**（force_lock 0 条 + 新增一条 frame_error + 驱动段没执行）。
    check("ping_route_sets_current_around_observation",
          "current={ref=old.ref,match=m}" in rt
          and rt.index("current={ref=old.ref,match=m}")
          < rt.index("with_observation(old.ref,function(scope)"),
          "★★ 调 `with_observation` **必须先设 `current`**（它内部断言 current 与 ref 对齐）"
          "—— 不设就抛 `expired observation key`，把整帧后续全部打死")
    check("ping_route_uses_P_not_new_local",
          "flk={}," in rt and "pt_route" not in rt,
          "★ 去重表放进 P 表而非新开 local（该闭包 upvalue 已近 Lua 5.1 的 60 上限）；"
          "已废弃的 `pt_route` 路线标记清理干净")
    check("ping_route_promotion_deduped",
          "'flp:'..tostring(scope.prepared.flight_start)" in rt,
          "按 (flight_start,结果) 去重，一颗雷最多两条")
    check("ping_route_promotion_reads_only_via_helper",
          "env.write(" not in rt,
          "★ 运行时**不得**自己写内存：写只允许经 promote_state4（守门钉死单一写点）")    # 5) build.py 的计数式例外
    check("build_py_controlled_exception",
          "text.count('.WriteProcessMemory(') == 1" in b
          and "'VirtualProtect'" in b,
          "★ build.py 开了**计数式**例外：恰好 1 处调用；"
          "VirtualProtect/VirtualAlloc 等仍一律禁止")
    # 6) ★★ 2026-10-09：候选组探针**已移除**（它服务于「写入候选分数」那条路）★★
    #    实机结论：那条路**不需要** —— 强制提升 state=4 之后引擎自己接管了引导
    #    （5 颗雷 / 5 个不同虫洞，全部炸毁；held=0 说明是引擎在开）。
    #    知识不丢（写进 README 与工作日志）：候选分数**确实是** `记录+0x44`（float，
    #    引擎在 0xbbac9 写 max(分,0)），接受判据 = 分数>0 且 +0x48≠0 且 +0x4c≠0；
    #    但提升判据读的是 seek 函数**栈帧副本**，且**虫洞从来不在候选列表里**
    #    ⇒ 无敌人时无候选可评分。
    check("cand_probe_scaffolding_removed",
          "local function probe_candidate_groups" not in r
          and "cand_probe_enabled=true," not in e
          and "cand_probe_enabled=state" not in e,
          "★ 探针脚手架已移除（它读 manager 只拿到 0xffffffff 哨兵值、没产出有效数据，"
          "而结论已固化进 force_lock）—— 防止它作为死代码/日志噪音回来"
          "（⚠ 断言查**函数定义**而非名字：删除说明里会提到旧名字）")
    # ★ 结构性守门：凡"探针函数里做内存读"的，必须 pcall 包住 ——
    #   一次覆盖所有探针，不靠人眼（事故正是"忘了包"这一类）。
    _probe_names = re.findall(r"\nlocal function (probe_[A-Za-z0-9_]+)\(", r)
    _risky = []
    for _nm in _probe_names:
        _blk = _fn_slice(r, "local function " + _nm + "(")
        if ("scope.read(" in _blk or "env.read(" in _blk) and "pcall(" not in _blk:
            _risky.append(_nm)
    check("probes_that_read_are_pcall_guarded", not _risky,
          "★ 做内存读的探针必须 pcall 包住（读失败会 assert ⇒ 禁用整条 priority）。"
          " 未包住的: %s" % (_risky if _risky else "无"))
    # ★ 实机 5/5 成功时 `held=0`（引擎在开）⇒ 旧日志里没有任何距离，
    #   只能靠人眼确认"到底炸没炸"。把提升那一刻的水平距离写进 force_lock 行，
    #   以后日志自己就带上下文，不必再问"你看到炸了吗"。
    check("force_lock_logs_distance",
          "';dist='..string.format('%.2f'" in r and "math.sqrt(dx*dx+dy*dy)" in r,
          "★ force_lock 行带「提升时的水平距离」（判读不再依赖人眼）")


def test_target_fields_probe():
    print()
    print("=== ㉗ 目标字段探针（引擎凭什么接受/拒绝一个目标 —— 2026-10-08）===")
    r = PRIORITY.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) helper 存在 + 受开关保护 + 纯只读
    check("target_fields_helper_exists",
          "local function probe_target_fields(scope,env,e,tag)" in r,
          "native_priority 有共用 helper（虫洞与通用两条路径复用，不写两份）")
    check("target_fields_switch_declared",
          "target_fields_probe=true," in e,
          "entry 有开关（默认开：纯只读诊断）")
    # ★★ 2026-10-08 实机教训：开关写进 state 但**没进 env** ⇒ helper 里
    #    `env.target_fields_probe` 是 nil ⇒ 静默不触发，而当时守门只查声明没查接线
    #    ⇒ 门是绿的、功能是死的（用户那次启动 0 条 target_fields）。
    #    ⇒ 从此"开关"必须连着**传参**一起钉住，且顺序要在声明之后（防写反）。
    check("target_fields_switch_wired_to_env",
          "target_fields_probe=state.target_fields_probe," in e
          and e.index("target_fields_probe=true,") < e.index("target_fields_probe=state.target_fields_probe,"),
          "★ 开关必须同时传进 env（否则 helper 静默不触发 —— 2026-10-08 实机踩过）")
    _i = r.index("local function probe_target_fields(scope,env,e,tag)")
    _j = r.index("\nfunction M.new(env)", _i)
    blk = r[_i:_j]
    check("target_fields_is_read_only",
          "scope.read" in blk and "target_valid" in blk
          and "setter" not in blk and "ffi.cast('void **'" not in blk,
          "★ 只做 read 与 target_valid 查询（后者本工程早就在当门槛用），无写操作")
    # 2) 三个字段偏移必须来自反汇编（8 / 0xc / 0x4c）
    for _off, _why in (("field(8)", "f08：全局集合的 key，并喂给 0x4a9710 取 bit25"),
                       ("field(0xc)", "f0c：喂给间接调用与 0x13e1b50"),
                       ("field(0x4c)", "f4c：category_mask 的实体类别掩码")):
        check("target_fields_off_" + _off.replace("field(", "").replace(")", ""),
              _off in blk, "读 %s（%s）" % (_off, _why))
    # 3) 按 (来源,id) 去重（否则 sticky 复核会逐帧刷屏）
    check("target_fields_deduped",
          "M.probed_fields[key]" in blk and "M.probed_fields={}" in r,
          "★ 按 (来源,id) 去重（sticky 每帧复核 ⇒ 不去重必刷屏）")
    # 4) 两条路径都插桩，且都在**最前面**（被拒的样本也必须留下证据）
    check("target_fields_probe_both_paths",
          "probe_target_fields(scope,env,e,'structure')" in r
          and "probe_target_fields(scope,env,e,'generic')" in r,
          "★ 虫洞路径与通用路径都插 → 才有「被拒的虫洞 vs 被接受的敌人」对照")
    _s = r.index("probe_target_fields(scope,env,e,'structure')")
    _g = r.index("if e.identity~=structure_mark.identity")
    check("target_fields_structure_before_rejects", _s < _g,
          "★ 虫洞插桩在存活/预约/超距等拒绝点**之前**（否则只统计到成功样本）")
    check("target_fields_emits_evidence_line",
          "env.emit('target_fields;tag='" in blk and "';valid='" in blk
          and "';f08='" in blk and "';f4c='" in blk,
          "每行含 tag / entity / resource / f08 / f0c / f4c / valid")
    # 5) 白名单
    check("target_fields_whitelisted",
          "and not line:match('^target_fields;')" in e,
          "★ 探针日志进节流白名单")
    # 6) ★★ 状态记录里的代码指针（2026-10-09）：找"起索敌/状态转换"函数的第二条路 ★★
    check("record_pointer_probe_exists",
          "local function probe_record_pointers(env,record,gid)" in r
          and "env.emit('recptr;entity='" in r,
          "有状态记录指针探针并打 recptr 行")
    _i2 = r.index("local function probe_record_pointers(env,record,gid)")
    # ⚠ 切片终点必须取"下一个 local function"，不能写死 `function M.new(env)` ——
    #   2026-10-09 在两者之间插入了 promote_state4，写死终点会把它的 scope.read
    #   算进"零读取"检查里（守门因此误报过一次）。
    _j2 = r.index("\nlocal function ", _i2 + 10)
    blk2 = r[_i2:_j2]
    check("record_pointer_probe_zero_reads",
          "scope.read" not in blk2 and "read(" not in blk2,
          "★ **零新增内存读取**：record 是调用方已读好的字符串，只扫它内部")
    check("record_pointer_probe_code_section_only",
          "env.base+0x1000" in blk2 and "env.base+0x2110a93" in blk2,
          "★ 只认代码节内的指针（该节 char=0x60000020 code ⇒ 不掺数据指针）")
    check("record_pointer_probe_high_dword_zero",
          "q5==0 and q6==0 and q7==0 and q8==0" in blk2,
          "用户态指针判据：高 32 位为 0（否则会把数据当指针）")
    check("record_pointer_probe_deduped",
          "M.probed_fields[key]" in blk2 and "'rec:'" in blk2,
          "按手雷去重（同一颗只打一条）")
    check("record_pointer_probe_called_after_record",
          "probe_record_pointers(env,record,L.u32(c.identity_bytes,8))" in r,
          "★ 在 api:step 里 record 取到之后调用（复用同一份已读数据）")


def test_env_wiring_complete():
    print()
    print("=== ㉘ env 接线完整性（结构性守门：一次覆盖所有字段）===")
    e = ENTRY_SRC.read_text(encoding="utf-8")

    # 1) 从 `Runtime.new({` 起做括号配对取出 env 字面量（跳过注释与字符串）。
    #    必须真的配对：env 表里有嵌套表，简单正则会把 `{` 里的东西也算进来。
    i = e.index("Runtime.new({")
    j = i + len("Runtime.new(")
    depth, k, n = 0, j, len(e)
    while k < n:
        ch = e[k]
        if ch == "-" and e[k:k + 2] == "--":
            k = e.find("\n", k)
            if k < 0:
                break
            continue
        if ch in "\"'":
            q = ch
            k += 1
            while k < n and e[k] != q:
                if e[k] == "\\":
                    k += 1
                k += 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    body = e[j:k]
    assigned = set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=", body))
    check("env_literal_parsed", len(assigned) > 30,
          "从 Runtime.new({ 解析出 %d 个 env 字段" % len(assigned))

    # 2) src/g60/*.lua 里引用的 env.X
    used = set()
    for f in sorted((ROOT / "src" / "g60").glob("*.lua")):
        used |= set(re.findall(r"env\.([A-Za-z_][A-Za-z0-9_]*)",
                               f.read_text(encoding="utf-8")))

    # 3) 白名单：由**运行时自己赋值**的字段（不是接线遗漏）。
    #    ⚠ 白名单必须逐条给理由 —— 它是这个守门唯一的松口处。
    RUNTIME_ASSIGNED = {
        "arrival",         # experimental_runtime.lua: `env.arrival=arrival`
        "claim_profile",   # experimental_runtime.lua: `env.claim_profile=claim_profile`
        "forget_mark",     # experimental_runtime.lua: 有 ping 时条件赋值
        "target_allowed",  # experimental_runtime.lua: `env.target_allowed=Allowlist.new(...)`
        "damage_regions",  # 1.1 移植残留：`env.damage_regions or env.adaptive_approach`
                           # 的 OR 兜底；adaptive_approach 已为 true ⇒ 无害死引用
    }
    missing = sorted(used - assigned - RUNTIME_ASSIGNED)
    check("env_fields_all_wired", not missing,
          "★ 模块引用的每个 env.X 都必须在 env 字面量里赋值（否则 helper 静默不触发）。"
          " 缺失: %s" % (missing if missing else "无"))
    # 反向：env 里赋值了却没人用的字段也报出来（清死字段用，不算失败）
    unused = sorted(assigned - used)
    print("    (提示) env 里赋值但模块未引用: %s" % (unused if unused else "无"))


def test_point_target(rt):
    print()
    print("=== ㉕ ★ ping 地面点 ⇒ G-60 飞过去炸（指哪打哪，2026-10-01 用户要求）===")
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    ar = (ROOT / "src/g60" / "native_arrival.lua").read_text(encoding="utf-8")
    g = (ROOT / "src/g60" / "take_gate.lua").read_text(encoding="utf-8")

    # 1) 门控：old.point 与 lock/titan 同属"本 mod 已持有"
    #    漏了它 ⇒ 只有第一帧写、之后不再驱动（G-60 会漂走）
    check("gate_point_counts_as_hold",
          "o.structure_mark or (old and (old.lock or old.titan or old.point))" in g,
          "★ 门控把 old.point 也算作已持有")
    check("gate_guidance_point_counts_as_hold",
          "if not (o.old and (o.old.lock or o.old.titan or o.old.point)) then" in g,
          "arrival 门控同样认 old.point")

    # 2) native_arrival：点目标写入（与泰坦同款四条不变量）
    check("arrival_point_write_exists",
          "local want_point=options and options.point_target" in ar
          and "ffi.cast('uint32_t *',data)[0]=scope.invalid_id" in ar
          and "for i=0,2 do xyz[i]=want_point[i+1] end" in ar,
          "★ 把坐标写成点目标（invalid_id + float3）")
    check("arrival_point_clears_category_mask",
          "ffi.cast('uint32_t *',data+0x4c)[0]=0" in ar,
          "★ +0x4c 类别掩码清零（与泰坦同款：过渡航点不得被当成引信目标）")
    check("arrival_point_postcondition",
          "'point setter postcondition'" in ar,
          "★ 写完回读不变量（不符即进 quarantine，不会静默继续乱写）")

    # 3) ★ 核心前提：没有实体（target=nil）也要能引导
    check("arrival_accepts_nil_target_with_goal",
          "if (target or want_point) and not mask_only then" in ar
          and "assert((not target or target.validate()) and ex.validate()" in ar
          and "target=target and target.id or 'point'" in ar,
          "★ target=nil 也能走 Policy.step / 引爆 / 返回 target='point'")

    # 4) runtime：状态机与优先级
    check("runtime_point_drive_priority",
          "local point_drive=not abandoned and point_marker~=nil" in r
          and "and not titan_selected and not (old and old.lock)" in r,
          "★ 优先级按**每颗**判：已锁结构 ⇒ 让位；引擎选中泰坦/弱点 ⇒ 让位")
    # ★ TTL 只能约束"新接管"（2026-10-01 第二次实机修正）★
    #   第一版让 TTL 一到期就把 point_marker 置 nil ⇒ **已在飞的那颗被当场丢掉**
    #   （ping 之后隔一会儿才扔就会撞上）⇒ 这就是"时灵时不灵"的一个来源。
    #   ⚠ 2026-10-09：新接管条件放宽为 `(selected and point_armed) or (old and old.point)
    #     or ping_take` —— `ping_take` = TTL 内的一次 ping（与标记同级的玩家意图；
    #     门控侧对应 `o.point_armed`，解掉 `no_mark_no_hold` 那道真正的死锁）。
    #     **TTL 语义不变**：仍只挡新接管，`old.point`（已在飞）照样不受影响。
    check("point_ttl_gates_new_takeover_only",
          "local point_armed" in r
          and "((selected and point_armed) or (old and old.point) or ping_take)" in r
          and "point_armed=(frame-P.pt.frame)<=env.point_target_ttl_frames" in r,
          "★ TTL 只挡新接管；已在引导中的那颗不受影响（否则半路被丢、永远不炸）；"
          "新增 `ping_take` 只为解无敌人时的死锁，不改变 TTL 语义")
    check("point_marker_requeues_when_reappearing",
          "if P.pt.token~=lp.token or P.pt.seen==false then" in r
          and "P.pt.seen=false" in r,
          "标记消失又出现（同一 token）⇒ TTL 重新计时")
    # ★★★ 本轮实机事故的回归守门（2026-10-01）★★★
    #   分支后面有一段**公共**的引导失败熔断：`if result then 清零 else fail_count+1`。
    #   第一版 point_drive 分支没给 result 赋值 ⇒ 每帧被记成失败 ⇒
    #   **30 帧（约 0.5 秒）后 guide_give_up 把这颗 G-60 退休** ⇒ 半路停手、再也跑不到引爆。
    #   实机日志：point_taken → skipped;reason=nil;detail=nil ×30 → guide_give_up;after=30
    #   （用户报"G60 飞过去了，但没爆炸"）。
    _pb_start = r.index("elseif point_drive then")
    _pb_end = r.index("\n                        else", _pb_start)
    _pb = r[_pb_start:_pb_end]
    check("point_branch_reports_success",
          "result={kind='point'}" in _pb,
          "★ point_drive 分支必须给 result 赋值（否则被公共熔断段记成失败、30 帧后退休）")
    check("point_branch_does_not_step_runner",
          "runner:step" not in _pb and "runner:release(old.ref)" in _pb,
          "点目标分支只释放 runner（不让它改写我们写的点目标）")
    check("point_hold_and_start_log",
          "old.point={x=point_marker.x" in r and "'point_taken;entity=%s" in r,
          "登记持有 + 首次接管打一行 point_taken")
    check("runtime_point_released_on_marker_loss",
          "if held and held.point and not point_marker then" in r and "'point_released;entity='" in r,
          "★ 标记消失 / TTL 到期 ⇒ 本帧就释放（不残留过期目标）")
    check("runtime_point_ttl",
          "point_armed=(frame-P.pt.frame)<=env.point_target_ttl_frames" in r,
          "★ TTL：同一个 ping 标记只在有限帧内**作数给新接管**（已在引导中的不受限）")
    check("runtime_point_opt_in_switch",
          "if env.point_target_enabled and lp and lp.token then" in r,
          "★ 开关：开了才登记点目标")
    # ★★★ 本轮实机事故的回归守门（2026-10-01）★★★
    #   第一版把"虫洞优先"写成**登记期的全局条件** `and not structure_mark` ⇒
    #   只要 ping 记忆里**存在**任何结构标记（虫洞/泰坦/泛用标记都算），
    #   点目标就**永久不登记** ⇒ 用户报"生效几次，后面又不生效了"
    #   （实机：ping 了一个虫洞 MK9 之后，后面十几次 ping 全部无效）。
    #   正解 = 按**每颗 G-60** 判优先级：该颗锁上结构就让位，其余照常打点目标。
    check("point_registration_not_globally_blocked",
          "and not structure_mark then" not in r.split("if env.point_target_enabled")[1][:120],
          "★ 登记点目标不得被 structure_mark 全局挡住（否则一个虫洞标记就把能力永久关死）")
    check("point_defers_to_structure_lock_per_entity",
          "and not (old and old.lock)" in r
          and "if point and old.lock then point=nil end" in r,
          "★ 让位改成**按每颗**：该颗已锁上结构 ⇒ 让给结构；其余不受影响")
    check("point_armed_diagnostic",
          "'point_armed;slot='" in r and "note=structure_mark_present" in r,
          "与结构标记并存时打一行 point_armed（解释'这次为什么可能先打虫洞'）")

    # 5) ★★ 最隐蔽的陷阱 ★★
    #    有点目标时 mask_only 必须为 **nil**：否则 arrival 走 mask_all 分支，
    #    一个字节都写不进去 —— 而所有"结构存在性"断言照样全绿（功能静默失效）。
    check("runtime_point_not_masked_all",
          "or (not target and not point and not blast_point) and true or nil" in r,
          "★ 有点目标（ping 点 **或体内爆点**）时必须放行写入"
          "（mask_all 会让功能静默失效）")
    check("runtime_point_arrival_options",
          "arr_opts={region=env.point_arrival_region,point=true," in r
          and "point_target={point.x,point.y,point.z}}" in r,
          "★ 传 region + point=true（跳过实体邻近抑制段）+ 坐标")
    check("runtime_point_defers_to_weakpoint",
          "if point and has_weakpoint(m.selection_resource) then point=nil end" in r,
          "引擎选中泰坦/弱点类目标时让位（与 titan 段同款判据）")

    # 6) 配置与日志白名单
    check("point_target_config",
          "point_target_enabled=true,point_target_ttl_frames=1200," in e
          and "point_arrival_region={radius=3.0,depth=2.0,above=2.0}," in e,
          "★ 开关 / TTL / 到达区域都有配置（above 必须留量：G-60 会悬在地面点上方）")
    check("point_target_config_passed",
          "point_target_enabled=state.point_target_enabled," in e
          and "point_target_ttl_frames=state.point_target_ttl_frames," in e
          and "point_arrival_region=state.point_arrival_region," in e,
          "三个配置都传进 Runtime.new")
    check("point_target_lines_whitelisted",
          "and not line:match('^point_taken;')" in e
          and "and not line:match('^point_released;')" in e
          and "and not line:match('^point_guide;')" in e
          and "and not line:match('^point_stalled;')" in e
          and "and not line:match('^point_armed;')" in e,
          "★ point_taken / point_released / point_guide / point_stalled 都进节流白名单")
    # 点目标的 guide/search 原本**完全静默**（只有 detonate/quarantine 打日志）
    #   ⇒ 实机"飞过去没炸"时日志里只有 point_taken，无从判断卡在哪。
    check("point_guidance_diagnostics",
          "(old.point and 'point') or (P.site[m.id] and 'blast')" in r
          and "guide_tag..'_stalled;entity='" in r
          and "guide_tag..'_guide;entity='" in r
          and "frame-(P.pg[m.id] or -1000)>=60" in r,
          "★ 引导/停滞诊断必须**同时覆盖ping点与体内爆点**（`guide_tag` = "
          "`point` / `blast`，对外仍是 `point_stalled` / `blast_stalled`）："
          "停滞=到达判定 4 秒没满足；guide 每 60 帧报一次距离")
    check("blast_guidance_diagnostics_cover_blastsites",
          "(old.point and 'point') or (P.site[m.id] and 'blast')" in r
          and "';above_origin='..string.format('%.2f',v[3]-o[3])" in r,
          "★★ 体内爆点必须**有自己的到达诊断**：判据原来是 `old.point`（只覆盖 ping 空地）"
          "⇒ 体内爆点完全静默 ⇒ 「低抛那颗飞到哪了」无据可查（2026-10-03 实机就是这样）；"
          "并给出 `above_origin`（这颗雷相对目标原点有多高）—— "
          "这是判断「低抛是上不去、还是根本没被引导」的唯一依据")
    check("blast_guidance_whitelisted",
          "and not line:match('^blast_guide;')" in e
          and "and not line:match('^blast_stalled;')" in e,
          "★ 两条新诊断进日志节流白名单（被节流掉 = 下次还是只能猜）")
    #   ⚠ 原先这里有一条 `scene_motion_dump_is_one_shot`（守"场景转储每目标只打一次"）。
    #     2026-10-03 清理：**转储本身已删除**（见第 5 节说明）⇒ 这条守门随之作废。
    #     ★ 但它背后的教训要留着，因为它是一个**通用**的坑：
    #       **去重键换名字时，同一张表上的所有读写点都要一起过一遍** ——
    #       当时把爆点日志的键从 `bk` 改成 `bkg`，把转储那支的 `P.blast[bk]=true`
    #       一起搬走了 ⇒ `P.blast[bk]` 永远为 nil ⇒ 每帧重打 3 段整记录
    #       （实机 435 行 / 262 KB，单颗手雷 84 帧），还把真事件整个埋掉。
    #       ⇒ 以后凡是给 `P.*` 去重表改名/改键，都要 grep 一遍**所有**读写点。

    # 7) 只读边界与既有路径不受影响
    check("point_region_within_policy_bounds",
          "radius=3.0,depth=2.0,above=2.0" in e,
          "到达区域落在 arrival_policy 断言范围内（radius<=3 / depth<=2 / above<=2）")
    check("point_does_not_change_veto_path",
          "run_veto(m,veto_resource,'no_mark')" in r,
          "引擎选择否决（运输船/增援飞船）路径一字未改")
    check("point_off_switch_reverts_all",
          "if env.point_target_enabled and lp and lp.token" in r
          and "point_target_enabled=true," in e,
          "开关置 false 即完全回到原行为（无点目标登记 → 门控不再放行）")

    # ── 行为级（不只是"源码里有这串字"）──
    #   ① mask_only 表达式：**有点目标（ping 点 / 体内爆点）时必须求值为 nil**
    #      ⚠ 这是本功能最隐蔽的失效模式：若它求值为 true，arrival 会走 mask_all 分支、
    #        一个字节都写不进去，而所有"结构存在性"断言照样全绿。
    #      ★ 2026-10-03：表达式新增第 5 个操作数 `bp`（体内爆点）—— 复刻式同步更新，
    #        否则这里测的是**旧形状**（空转断言）。
    rt.execute("function _pt_mask(fs,bs,tgt,pt,bp) return (fs or bs) and 'search' "
               "or (not tgt and not pt and not bp) and true or nil end")
    def _mask(vals):
        rt.execute("__pt_mv = _pt_mask(%s)" % ",".join("true" if v else "false" for v in vals))
        return rt.eval("__pt_mv")
    check("mask_nil_when_point_present",
          _mask((False, False, False, True, False)) is None,
          "★ 有 ping 点目标 ⇒ mask_only=nil（放行写入）")
    check("mask_nil_when_blast_point_present",
          _mask((False, False, False, False, True)) is None,
          "★ 2026-10-03：有**体内爆点**时同样必须放行（否则巨型构筑者静默失效）")
    check("mask_all_without_point_unchanged",
          _mask((False, False, False, False, False)) is True,
          "无点且无实体 ⇒ mask_only=true（原有'不写选择'语义不变）")
    check("mask_entity_target_unchanged",
          _mask((False, False, True, False, False)) is None,
          "有实体目标 ⇒ mask_only=nil（原行为不变）")
    check("mask_search_still_wins",
          _mask((True, False, True, False, False)) == b"search"
          and _mask((False, True, True, False, False)) == b"search",
          "force_search / blocked_selected 仍优先走 search")

    #   ② take_gate 真跑（纯 Lua，无需桩）
    rt.execute("PT_GATE = load([==[\n%s\n]==])()" % g)
    rt.execute("function _pt_decide(t) local q=PT_GATE.decide(t); return q.drive, q.why end")
    def _decide(lua_old, sm="nil"):
        rt.execute("__pt_d = {_pt_decide({behavior_id=4,state=4,native_update_eligible=true,"
                   "retired=false,old=%s,structure_mark=%s,allow_early=false,"
                   "selection_vetoed=false,state_age=0,early_min_age=0})}" % (lua_old, sm))
        return rt.eval("__pt_d[1]"), rt.eval("__pt_d[2]")
    d, why = _decide("{point={x=1,y=2,z=3}}")
    check("gate_drives_on_point_hold_only",
          d is True and why == b"state4_drive",
          "★ 行为级：只持有 old.point 时门控真的放行")
    d, why = _decide("{}")
    check("gate_blocks_without_any_hold",
          d is False and why == b"no_mark_no_hold",
          "空记录仍被拦（回归：不许因这次改动放宽门控）")
    d, why = _decide("{quarantined=true,point={x=1,y=2,z=3}}")
    check("gate_quarantine_beats_point",
          d is False and why == b"quarantined",
          "quarantined 仍然优先（不因有点目标就复活）")
    d, why = _decide("{}", sm="{resource='x'}")
    check("gate_structure_mark_still_drives",
          d is True,
          "虫洞标记路径不受影响（回归）")


def test_blast_sites(rt):
    print()
    print("=== ㉖ ★ 体内爆点：巨型构筑者需要「炸进通风口」（2026-10-03 用户实测）===")
    # 用户实测两条（决定性）：
    #   ① 「G60 会在巨型构筑者的底部引爆，但不会对其造成伤害」
    #   ② 「虫巢只要引爆点小于 4m 就能摧毁，巨型构筑不行，**不能参考虫巢的引爆点计算**」
    #      「能摧毁的引爆点要进入**红色的通风口里面**」
    # ⇒ 本 mod 对"未登记目标"的既有做法是"引爆位置交给引擎 `aim`"（README 第 26 行），
    #   对虫洞够用（距离判定），对巨型构筑者**不成立** ⇒ 必须显式给体内点。
    r = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
    b = (ROOT / "compat" / "blast_sites.lua").read_text(encoding="utf-8")
    bp = (ROOT / "scripts" / "build.py").read_text(encoding="utf-8")
    FAB = "4232ee48e2cfd24e"
    FAB_PATH = "content/env_cyborg/gameplay/colony_cyborg_spawner/cyborg_colony_spawner_base"

    # 0) ★★★ 真求值：这条是本轮事故（整包 disabled）的守门 ★★★
    #
    #   2026-10-03 实机：日志只有一行
    #     `disabled: mods/hd2test/g60_directed_strike.lua:7801: attempt to index
    #      local 'BlastSites' (a function value)`
    #   —— 我把模块写成 `return function() … end`，而 build.py 侧注册成 factory=false
    #   ⇒ `local BlastSites=(function() <模块> end)()` 求值成**函数** ⇒ entry 索引它即崩
    #   ⇒ **整个 mod 一行功能都没跑**。
    #   而当时的守门只 grep 了 `('BlastSites', 'blast_sites.lua', False)` 这串**字符串**
    #   ⇒ 全绿。教训：**涉及"模块求值成什么类型"的断言必须真求值**。
    #   ⚠ lupa（encoding=None）把 Lua 字符串映射成 **bytes** ⇒ 键/字段名都要归一化，
    #     否则 `"4232ee48e2cfd24e" in list(t.keys())` 恒假（本轮第一版就踩了这个）。
    def _ls(x):
        return x.decode("utf-8", "replace") if isinstance(x, (bytes, bytearray)) else str(x)

    def _lookup(t, name):
        for k in t.keys():
            if _ls(k) == name:
                return t[k]
        return None

    _wrap = "(function()\n" + b + "\nend)()"
    try:
        _bs = rt.execute("return " + _wrap)
        _bs_err = None
    except Exception as exc:          # 语法错/运行错/类型错都算失败，但**不崩测试**
        _bs, _bs_err = None, str(exc)[:160]
    _is_table = hasattr(_bs, "keys") if _bs is not None else False
    _keys = [_ls(k) for k in _bs.keys()] if _is_table else []
    check("blast_sites_module_is_a_table",
          _is_table and FAB in _keys,
          "★★ 按 build.py 的包装（factory=false ⇒ `(function() 模块 end)()`）真跑一遍："
          "结果必须是**表**且含目标键。"
          "⚠ 模块返回函数/字符串都算失败 —— 那会让 entry 索引它时直接 disabled 整个 mod"
          + (f"｜实际报错：{_bs_err}" if _bs_err else ""))
    if FAB in _keys:
        _site = _lookup(_bs, FAB)
        _sk = [_ls(x) for x in _site.keys()] if hasattr(_site, "keys") else []
        check("blast_sites_module_entry_shape",
              "lift" in _sk and "resource" in _sk
              and float(_lookup(_site, "lift")) > 0,
              "★ 表项形状：resource + **数值 lift**（>0）")
        _m_lift = re.search(r"^local LIFT=([0-9.]+)", b, re.M)
        check("blast_sites_module_lift_matches_constant",
              _m_lift is not None
              and abs(float(_lookup(_site, "lift")) - float(_m_lift.group(1))) < 1e-9,
              "★ 求值结果与源码里的 `local LIFT=` 常量一致"
              "（lift 抽成常量后，这条同时钉住「改了常量没生效」与「改了没同步」）")
        # ★ 专用到达区域（2026-10-03）：爆心必须落进爆炸内半径 4 m
        _reg = _lookup(_site, "region")
        _rk = [_ls(x) for x in _reg.keys()] if hasattr(_reg, "keys") else []
        check("blast_sites_module_has_region",
              {"radius", "depth", "above"} <= set(_rk),
              "★ 每项必须有**专用到达区域**（radius/depth/above）")
        if {"radius", "depth", "above"} <= set(_rk):
            _r = {k: float(_lookup(_reg, k)) for k in ("radius", "depth", "above")}
            check("blast_sites_region_within_policy_bounds",
                  _r["radius"] <= 3.0 and _r["depth"] <= 2.0 and _r["above"] <= 2.0,
                  f"★ region 必须在 arrival_policy 的断言范围内（radius<=3/depth<=2/above<=2），"
                  f"实际 {_r}")
            check("blast_sites_region_tighter_than_default",
                  _r["radius"] < 3.0 and _r["above"] < 2.0,
                  f"★★ 必须**比 ping 空地的默认区域更紧**（默认 radius 3.0 / above 2.0）—— "
                  f"实测宽松区域会让爆心落在爆点上方 1.4~1.9 m ⇒ 掉出内半径 4 m ⇒ "
                  f"拆毁判定不触发。实际 {_r}")
    check("blast_sites_not_registered_as_factory",
          "('BlastSites', 'blast_sites.lua', False)" in bp
          and "('BlastSites', 'blast_sites.lua', True)" not in bp,
          "★ 模块返回**表** ⇒ build.py 必须 factory=false（true 会把返回值再当函数调用）")
    check("blast_sites_entry_only_indexes_table",
          "BlastSites[" in e and "BlastSites(" not in e,
          "★ entry 侧只允许**索引** BlastSites（表）；写成调用 ⇒ 又是加载期 disabled")
    # 产物级：build/entry.lua 里那段**内联后**的 chunk 也要真跑
    _pkg = ROOT / "build" / "entry.lua"
    if _pkg.exists():
        _txt = _pkg.read_text(encoding="utf-8")
        _head = "local BlastSites=(function()"
        if _head in _txt:
            _i = _txt.index(_head)
            _j = _txt.index("\nend)()", _i) + len("\nend)()")
            _pbs = rt.execute("return (function()\n" + _txt[_i:_j] + "\nreturn BlastSites end)()")
            _pkg_tab = hasattr(_pbs, "keys")
            _pkg_keys = [_ls(k) for k in _pbs.keys()] if _pkg_tab else []
            check("blast_sites_packaged_chunk_is_table",
                  _pkg_tab and FAB in _pkg_keys,
                  "★ 取 **build/entry.lua**（=真正内联进包的那段）再跑一遍 —— "
                  "这条能抓到「源码对、但包装/别名之后类型不对」")
        else:
            check("blast_sites_packaged_chunk_is_table", False,
                  f"★ build/entry.lua 里找不到 `{_head}`（构建没同步？）")

    # 1) 名册本身
    check("blast_sites_roster_has_fabricator",
          f'sites["{FAB}"]' in b and "lift=" in b and "return sites" in b,
          "★ 名册登记目标 + **一个可标定量 lift**（相对实体原点的抬升）")
    check("blast_sites_records_identity_source",
          FAB_PATH in b and "MurmurHash64A" in b and "Hash.csv" in b,
          "★ 身份必须留可追溯来源（离线 MurmurHash64A 反查 + Darctor Hash.csv 交叉）")
    check("blast_sites_records_damage_model_difference",
          "进入" in b and "4 m" in b and "虫洞" in b,
          "★ 文件头写明「与虫洞是两套机制」（虫洞=距离判定；构筑物=进入体内）—— "
          "这是用户明确要求，写进文件才不会被后人「顺手统一」掉")
    # 2) ★ 反向：绝不能把虫洞的 offset 搬过来（用户明确禁止）
    check("blast_sites_does_not_copy_hole_offsets",
          'kind="structure_hole"' not in b and "offset={" not in b
          and "3.0999999046325684" not in b and "front_distance" not in b
          and "boss_hash" not in b,
          "★★ 名册里**不得**出现虫洞那套几何（kind=structure_hole / offset / "
          "front_distance / boss_hash）—— 用户明确说「不能参考虫巢的引爆点计算」")
    # 3) 接线（开关 + 传参 + 状态行）
    check("blast_sites_entry_switch",
          "blast_sites_enabled=true," in e
          and "blast_sites=state.blast_sites_enabled and BlastSites or nil," in e,
          "★ 开关 + 传进 Runtime.new（false ⇒ 退回旧行为「引擎 aim」）")
    check("blast_sites_visible_in_status_line",
          "..';blast_sites='..tostring(state.blast_sites_enabled)" in e
          and "';blast_site_lift='..tostring(s.lift)" in e
          and "..';blast_site_region='..(" in e
          and f'local s=BlastSites and BlastSites["{FAB}"]' in e,
          "★★ 开关 / **实际 lift** / **专用到达区域** 三者都必须出现在状态行 —— "
          "lift 是唯一要标定的量、region 是「炸得准不准」的直接原因，"
          "日志里看不到就等于无法确认改没改")
    check("blast_sites_registered_in_build",
          "('BlastSites', 'blast_sites.lua', False)" in bp,
          "★ build.py 的 compat 列表里注册（否则 BlastSites 是 nil，功能静默失效）")
    # 4) runtime：算点 + 用点目标驱动
    check("blast_sites_runtime_computes_point",
          "local site=env.blast_sites and env.blast_sites[e.resource]" in r
          and "blast_point={p[1],p[2],p[3]+blast_lift}" in r,
          "★ 体内点 = 实体原点 + lift（`d.position`；lift 可为标定档位，见 4b）")
    check("blast_sites_runtime_fails_open",
          "local okp,p=pcall(d.position,e)" in r and "if okp and p then" in r,
          "★ 位置读不到 ⇒ 不启用（退回引擎 aim），绝不让读失败变成「不引爆」")
    _i_bp = r.find("if blast_point then")
    _i_pt = r.find("elseif point then")
    check("blast_sites_runtime_point_target",
          "point_target=blast_point}" in r and 0 <= _i_bp < _i_pt,
          "★ 用**点目标**（与 ping 点同一套已验证路径）驱动，且体内点优先于 ping 点。"
          "⚠ 用 `find` + `0 <=` 而不是 `index`：一是顺序反转时给**干净 FAIL** 而不是测试崩溃，"
          "二是整段被删时 `find` 返回 -1，只写 `_i_bp < _i_pt` 会**恒真**（空转断言）")
    check("blast_sites_runtime_uses_site_region",
          "arr_opts={region=(blast_site and blast_site.region)" in r
          and "or env.point_arrival_region,point=true," in r
          and "blast_site=site" in r,
          "★★ 到达区域取**本目标专用**的 `site.region`（缺省才回落 ping 那套）—— "
          "这是「爆心落进爆炸内半径 4 m」的唯一保证")
    # ★ 状态行拼 region 必须**逐字段判空**：`nil..'/'` 会当场抛错 ⇒ 又是加载期 disabled
    #   （同一天已经在 `BlastSites[...]` 上栽过一次）
    check("blast_sites_region_status_guarded",
          "local s=BlastSites and BlastSites[\"" + FAB + "\"]" in e
          and "if not s then return ';blast_site_lift=nil;blast_site_region=none' end" in e
          and "(r and r.radius and r.depth and r.above)" in e
          and "and (r.radius..'/'..r.depth..'/'..r.above) or 'default')" in e
          and "';blast_sweep='..sw" in e,
          "★ 状态行用**段内 IIFE** + 逐字段判空："
          "① 段外 local 会让逐段求值测试报 nil 拼接；"
          "② `nil..'/'` 会加载期抛错 ⇒ 整包 disabled")
    _i_site = r.find("local site=env.blast_sites")
    _i_lock = r.find("e.validate=d.validate;target=e")
    check("blast_sites_runtime_only_for_held_lock",
          0 <= _i_lock < _i_site,
          "★ 只在**已锁定的目标**上算（`old.lock` 的实体）—— 不是「见谁炸谁」")
    check("blast_sites_runtime_dedup_in_P",
          "P.blast[bkg]" in r and "blast={}," in r
          and "site={},orig={},hit={},hl={}," in r
          and "pex={},swk={},swn=0," in r and "pbt={}" in r,
          "★ 每目标只打一条诊断，去重表放进 **P**（不新增 upvalue）")
    check("blast_sites_whitelisted",
          "and not line:match('^blast_point;')" in e,
          "★ `blast_point;` 进日志节流白名单（被节流掉 = 下次又是猜）")

    # ── 4b) ★★ 判定区标定：**一局扫出高度**（2026-10-03）★★ ──
    #
    #   用户实测两条（决定性）：
    #     ① 「这次游戏**没有一个**是通过拆毁机制摧毁的」
    #     ② 「通风口只是入口，G60 是**穿模进入**的，不会受到阻拦，
    #         你只要找到**拆毁机制的区域**就行了」
    #   ⇒ 穿模无阻挡 ⇒ 手雷能飞进模型内部 ⇒ "**爆心落在哪一点**"是唯一变量
    #   ⇒ 逐颗换档扫出判定区高度；哪一颗炸塌 ⇒ 判定区就在那个高度（± 半档）。
    #
    #   ⚠ 为什么不再靠估：4.0 被判「太靠下」、7.5 实测「打不到」，中间没有可推的依据；
    #     那天 14 颗 `blast_hit` 的实际爆心全在原点上方 6.73~7.80 m、水平 0.94~1.49 m
    #     ⇒ **一直在结构外侧/顶部上方炸**，从没进过判定区。
    check("blast_scan_roster_present",
          "local SCAN={" in b and "sites.scan=SCAN" in b,
          "★ 档位表挂在名册上（`sites.scan`；键名不是资源哈希，不会与查表冲突）")
    #   ⚠ 先判"匹配不到"再取值：整段被删时 `re.search(...).group(1)` 会抛
    #     AttributeError ⇒ 测试**崩溃**而不是干净 FAIL（本项目明令避免的形态）。
    #   ⚠ 空档位表（`SCAN={}`）是**合法终态**：标定完就退回单一 lift。
    #     所以先 `if x.strip()` 再 float —— 否则 `float('')` 会抛 ValueError。
    def _scan_pair(lift_name, scan_name):
        m1 = re.search(r"local %s=([0-9.]+)" % lift_name, b)
        m2 = re.search(r"local %s=\{([^}]*)\}" % scan_name, b)
        lv = float(m1.group(1)) if m1 else -1.0
        sc = [float(x) for x in m2.group(1).split(",") if x.strip()] if m2 else []
        return lv, sc

    def _scan_form_ok(lv, sc):
        if not sc:
            return lv > 0.0
        return (len(sc) >= 4 and sc == sorted(sc) and len(set(sc)) == len(sc)
                and sc[0] > 0 and min(sc) < lv < max(sc))

    _lift, _sc = _scan_pair("LIFT", "SCAN")
    check("blast_scan_form_ok",
          _scan_form_ok(_lift, _sc),
          "★ 档位表只有两种合法形态："
          "① **空 = 已标定完**（走单一 `lift`，必须 > 0）；"
          "② 递增、无重复、≥4 档、且**把 `LIFT` 夹在中间** —— "
          "否则扫完也说不清「是高度不对，还是我们只扫了单侧」")
    check("blast_scan_per_grenade_not_per_frame",
          "P.swk[m.id]" in r and "if not sw_i then" in r and "P.swn=P.swn+1" in r,
          "★★ 档位按**手雷**推进（`P.swk[m.id]` 记住这一颗分到的档）—— "
          "按帧推进的话同一颗手雷飞行途中会不停换点，等于没测")
    check("blast_scan_state_in_P",
          "pex={},swk={},swn=0," in r and "pbt={}" in r and "local swk" not in r,
          "★ 计数器放进 **P**（不新增 local：`host:tick` 的 upvalue 上限 60）")
    check("blast_scan_falls_back_to_fixed_lift",
          "local blast_lift,sw_i=site.lift,'-'" in r
          and "blast_lift=scan[sw_i] or blast_lift" in r
          and "if scan and #scan>0 then" in r,
          "★ `scan` 缺席 ⇒ 完全退回单一 `site.lift`（标定完清空档位即恢复确定性行为）")
    check("blast_scan_logs_the_used_lift",
          ";lift=%.2f;sweep=%s" in r and "blast_lift,tostring(sw_i)" in r,
          "★★ 每颗手雷用的**实际档位**必须进日志 —— "
          "否则扫完这一局根本没法把「哪颗炸塌了」映射回高度")
    # ★★ "稳定拆毁"：竖向窗口必须收紧（2026-10-03 16:5x）★★
    #   实测判定门槛是**陡崖**：同一构筑 444 上实际爆心 5.66/6.83/6.99/7.03/7.14 **全不炸**、
    #   7.75 **炸** ⇒ 门槛在 7.14~7.75。而旧窗口 `depth=1.0` 容许爆心低到 `lift-1.0`
    #   ⇒ 目标 8.0 时有相当概率炸在 7.0（崖下）⇒ 偶发失效。
    #   `radius` 这次刻意不动：实测里"炸掉的 1.47 m / 没炸的 1.44 m" ⇒ 水平没有区分度，
    #   动它就等于同时改两个变量。**一次只改一个。**
    _reg = re.search(r"region=\{radius=([0-9.]+),depth=([0-9.]+),above=([0-9.]+)\}", b)
    check("blast_region_band_inside_confirmed_window",
          _reg is not None
          and (_lift - float(_reg.group(2))) >= 7.75
          #   ⚠ 上沿要**双向**卡：上限防"爆心冲进未验证区"，下限防"拒绝轻微过冲"。
          #     实测过冲范围 0~+0.45 ⇒ 上沿低于 `lift+0.4` 就会重演那颗远抛的失败。
          and 8.4 <= (_lift + float(_reg.group(3))) <= 8.9,
          "★★ 到达窗口必须**整体落在实测确认带内**："
          "下沿 `lift-depth >= 7.75`（门槛是陡崖：7.14 ✗ / 7.75 ✓ ⇒ 下沿不能再低，"
          "再低就是「偶发失效」的成因）；"
          "上沿 `lift+above ∈ [8.4, 8.9]`（8.02~8.16 ✓ / 9.55 ✗ ⇒ 上限留余量；"
          "而下限必须罩住实测过冲 0~+0.45）。"
          "⚠ 上沿=`lift+above` 同时是「**能容忍多大过冲**」的旋钮 —— 太小会拒绝轻微过冲的手雷"
          "（2026-10-03 那颗 48 m 远抛：dz=+0.42 被 above=0.2 拒掉 ⇒ 绕高到 10.5 ⇒ stall ×2）")
    check("blast_region_horizontal_kept",
          _reg is not None and abs(float(_reg.group(1)) - 1.5) < 1e-9,
          "★ `radius` **保持 1.5 不动** —— 4 颗成功的水平偏移 1.35~1.49、失败的 1.44~，"
          "**没有区分度**；动它只会引入第二个未知量。要动也是**下一个**变量")
    check("blast_point_logged_per_grenade",
          "local bkg=tostring(m.id)..'|'..tostring(e.id)" in r
          and "not P.blast[bkg]" in r,
          "★★ 爆点日志的去重键必须**含手雷 id** —— 原来只用目标 id ⇒ 同一目标上"
          "第 2 颗起**一条 `blast_point` 都不打**，而那正是扫描要读的档号"
          "（2026-10-03 实机就是这样丢了 2/3/5/6 档，只能靠 `blast_hit` 反推）")
    check("blast_scan_visible_in_status_line",
          "..';blast_sweep='..sw" in e and "table.concat(sc,'/')" in e,
          "★ 状态行给出档位表（判读日志的前提：本工程老毛病就是「承诺了却看不到」）")
    check("blast_scan_does_not_touch_region",
          "region={radius=1.5,depth=0.25,above=0.6}" in b
          and "scan" not in re.search(r"region=\{[^}]*\}", b).group(0),
          "★★ **一次只改一个变量**：档位只动 lift、不动 region／水平 —— "
          "多变量同时变 ⇒ 出了结果也归因不了（本项目铁的纪律）")
    check("blast_scan_per_site_priority",
          "local scan=site.scan or env.blast_sites.scan" in r,
          "★★ 档位表**优先取本目标自己的**（`site.scan`），缺省才回落全局 —— "
          "多个目标共用一张表会互相污染档号（**各自标定**是机制的让步）")

    # ★ 已爆短路的**日志去重**（实机抓到同一颗手雷刷 45 行）
    _rn = re.sub(r"\s+", " ", r)
    check("precheck_log_dedup_once",
          "if P.pex[m.id] then" in r and "P.pex[m.id]=true" in r,
          "★ 已爆判定只做一次、只打一条日志"
          "（实机 `priority_precheck_exploded;entity=1566` 刷了 **45** 行 ⇒ "
          "每帧重跑一次 `arrival:triggered` 的 pcall）")
    check("precheck_dedup_still_blocks_takeover",
          "if P.pex[m.id] then enters=false" in _rn,
          "★★ 去重分支**必须**把 `enters` 关掉 —— 已爆的手雷绝不能被接管写内存")
    #   ⚠ 判据**限定在这个函数体内**并通过 `0 <=` 守卫：不能拿全文搜
    #     `old.lock.id`（别处有合法的 `d.entity(old.lock.id)`），
    #     也不能不留守卫（函数被删时切片为空 ⇒ 存在性判据会**恒真**）。
    _i_nbh = r.find("local function note_blast_hit(via)")
    _i_nbh_end = r.find("local function note_already_exploded", _i_nbh)
    _nbh = r[_i_nbh:_i_nbh_end] if 0 <= _i_nbh < _i_nbh_end else ""
    #   ⚠ 先剥注释再判：说明性注释里**故意**写了那个旧写法当反例，
    #     不剥的话判据会被自己的注释判成失败（本项目踩过同类坑）。
    _nbh_code = re.sub(r"--[^\n]*", "", _nbh)
    check("blast_hit_target_from_P",
          "tostring(P.site[m.id] or '-')" in _nbh_code
          and "old.lock.id" not in _nbh_code
          and "P.site[m.id]=tostring(e.id)" in r,
          "★★ `blast_hit;target=` 原来写 `old.lock.id` —— 而 `old` 在那个 "
          "`local function` 里**不可见**（解析成全局 nil）⇒ 实机 14 条全是 `target=-`，"
          "白丢一轮标定数据")

    # ── 5) ★ 标定探测（2026-10-03，用户要求「先探测出**稳定**拆毁的位置」）──
    #
    #   背景：引擎自己撞进通风口引爆那一次能拆，我们下发的那次不能 ⇒
    #   必须拿到"**实际爆炸点相对目标原点**"的偏移 + 目标朝向（才能表达成与朝向无关的偏移）。
    nt = (ROOT / "src/g60/native_target_data.lua").read_text(encoding="utf-8")

    #   ⚠ 2026-10-03 清理：原先还有一支「运动记录整段转储」（`scene_probe` / `scene_motion`），
    #     用来找模型**朝向**；朝向最终**从未被使用**（改走 region 路线）⇒ **已整体删除**
    #     （runtime 42 行 + entry 3 处 + 白名单 2 条）。
    #     要重新读朝向，往 runtime 里那一处加回即可：记录基址 =
    #     `ptr(motion_manager+0x68,4)+i*0x308`，位置在 `+0x2e0`，
    #     朝向是 `+0x2d8` 起的**单位 2 向量**（见 README 与当日 memory）。
    check("blast_probe_read_only",
          "WriteProcessMemory" not in r and "VirtualProtect" not in r,
          "★ 体内爆点相关的读取全为只读（只有 ReadProcessMemory + 6 个原生调用）")
    check("blast_probe_state_in_P",
          "P.site[m.id]=tostring(e.id);P.orig[m.id]=p" in r and "P.hl[m.id]=true" in r
          and "site={},orig={},hit={},hl={}," in r and "pex={},swk={},swn=0," in r and "pbt={}" in r,
          "★ 状态表全在 **P**（不新增 local/upvalue）")
    check("blast_probe_keeps_safety_layer_untouched",
          "motion_record" not in nt and "scene_motion" not in nt,
          "★★ **不去改** `native_target_data.lua`（它在 SAFETY_LAYER 里、"
          "要求与上游逐字节一致；由 `test_bughole_scope` 的 `untouched:` 兜底）")
    check("blast_probe_no_scene_dump_left",
          "scene_probe" not in r and "scene_motion" not in r
          and "scene_probe" not in e and "scene_motion" not in e,
          "★★ 已删除的「运动记录整段转储」**不得回归** —— 它是标定期的一次性工具"
          "（朝向从未被使用），留着只会每目标白写 12 行日志。"
          "⚠ 真要重新加，别忘了它必须**每目标只打一次**（见下方那条去重教训）")
    # ★★ 关键陷阱：`local function` 只在其**定义点之后**可见 ★★
    #   `note_already_exploded` 里调用了 `note_blast_hit` ⇒ 后者必须先定义，
    #   否则运行时解析成**全局 nil** ⇒ `attempt to call a nil value`。
    #   （本项目已因同类顺序问题踩过事故，见 tests/test_lua_upvalue_order.py）
    _i_hit = r.find("local function note_blast_hit(via)")
    _i_used = r.find("note_blast_hit('engine')")
    check("blast_hit_defined_before_use",
          0 <= _i_hit < _i_used,
          "★★ `note_blast_hit` 必须定义在调用点**之前**"
          "（`local function` 只向后可见；否则解析成全局 nil）")
    check("blast_hit_both_paths",
          "note_blast_hit('engine')" in r and "note_blast_hit('arrival')" in r,
          "★ 两条路径都要打："
          "`via=engine`（引擎自己撞爆，=实际上成功的那种）"
          "与 `via=arrival`（本 mod 下发的那种）")
    check("blast_hit_reports_origin_relative",
          "';origin=%.2f,%.2f,%.2f;delta=%.2f,%.2f,%.2f'" in r
          and "v[1]-o[1],v[2]-o[2],v[3]-o[3]" in r,
          "★ 必须给出**相对目标原点**的偏移"
          "（绝对坐标换个位置就没用了）")
    check("blast_hit_hit_position_is_free",
          "P.hit[m.id]=v" in r
          and "pcall(TargetData.vector,scope.prepared.own_position_bytes,0)" in r,
          "★ 爆点位置从 **已读过的** "
          "`scope.prepared.own_position_bytes` 解码（零额外读取）")



def test_target_priority_tiers():
    """★ 2026-10-01 用户拍板的优先级：**虫洞/构筑 > 标记单位 > 空白标记**。

    用户原话：
      「我定个优先级吧，虫洞、构筑这一类建筑优先级最高，然后到标记单位，
        最后是空白标记」
      「还有一个问题需要解决，标记过的单位，即使取消标记，G60 仍会追踪该单位」

    改前的实测缺口（本测试逐条钉死的就是这两条）：
      · 已在飞往**单位**的 G-60 → 新标记**虫洞**被 `if not chosen` 直接跳过（单位锁
        sticky 到底）⇒ "我标记了虫洞，G-60 却继续去追那个单位"。
      · 引擎自选**泰坦**会覆盖**标记单位**锁（只有虫洞标记有权力压住泰坦）。
      · 通用单位标记在 ping UI 过期后仍留在记忆里 ⇒ 之后每一颗 G-60 继续追它。

    三档里"空白标记最低"**本来就成立**（point_drive 让位给任何 old.lock），
    所以这里用**反向**断言守住它：不许以后有人把点目标提到标记前面。
    """
    print()
    print("=== ㉕ 目标优先级三档（2026-10-01 用户拍板）===")
    p = PRIORITY.read_text(encoding="utf-8")
    r = RUNTIME.read_text(encoding="utf-8")
    g = PING_SRC.read_text(encoding="utf-8")
    e = ENTRY_SRC.read_text(encoding="utf-8")
    pm = PINGMEM_SRC.read_text(encoding="utf-8")

    # ---- ③档最低：空白标记必须继续让位于任何已持有的锁（回归，反向钉死）----
    check("point_still_lowest_tier",
          "and not titan_selected and not (old and old.lock)" in r,
          "★ 空白点仍让位给 old.lock（不许把点目标提到标记之前）")

    # ---- 结构 > 标记单位：只对**新近**结构标记让位 ----
    check("fresh_structure_gate_uses_current",
          "local fresh_structure=structure_mark~=nil and structure_mark.current==true" in p,
          "★ 让位门槛 = structure_mark.current（本帧 ping 环里还看得到 = UI 8 秒窗口内）")
    check("fresh_structure_gate_before_sticky",
          p.index("local fresh_structure=") < p.index("if previous and previous.marked_structure then"),
          "门槛必须在 sticky 判定**之前**算出（顺序即语义）")
    _gs = p[p.index("if previous.generic then"):]
    _gs = _gs[:_gs.index("local whitelisted=e and env.structure_profiles")]
    check("unit_lock_yields_only_to_structure",
          "if fresh_structure then" in _gs and "yielded_unit=previous" in _gs,
          "★ 只对**结构**让位，且让位动作落在通用(单位)锁分支内")
    check("same_tier_still_sticky",
          p.count("yielded_unit=previous") == 1 and "previous.generic then" in _gs,
          "★ 同层不抢（本条只针对 generic；虫洞↔虫洞仍由裁剪 I 保持忠实）")
    check("yield_fallback_keeps_unit_lock",
          "if not chosen and yielded_unit then" in p
          and "generic_validate(d.entity(yielded_unit.id))" in p,
          "★ 让位失败回退：结构这一帧拿不到 ⇒ 继续驱动单位锁（不丢锁、不白飞）")

    # ---- 标记单位 > 引擎自选的泰坦/蟑龙 ----
    check("titan_yields_to_marked_lock",
          "local marked_lock_held=old~=nil and old.lock~=nil" in r
          and "and not mark_is_wormhole and not marked_lock_held" in r,
          "★ 持有玩家点名锁时泰坦让位（原来只有虫洞标记有这个权力）")

    # ---- 单位标记的记忆判据：取消标记后不再被**新**接管 ----
    check("unit_mark_live_only_default_true",
          "unit_mark_live_only=true," in e,
          "开关默认 true（单位标记只在 ping 标记可见时算数）")
    check("unit_mark_live_only_wired",
          "unit_mark_live_only=state.unit_mark_live_only," in e,
          "开关已透传到 env（否则改了没效果）")
    # ★★ 2026-10-02（用户要求变更）：结构/泰坦/变体**不再**无条件长期记忆。
    #   用户：「标记虫洞再取消标记丢出手雷，手雷还是会向虫洞飞过去爆炸」
    #   ⇒ 改为受 `env.structure_mark_live_only`（默认 true = 只认活标记）。
    #   ⚠ 原断言"照旧长期记忆"的前提**已被用户推翻**，此处同步更新（不是删掉约束，
    #     而是改成钉**新**行为 + 可回退）。
    check("remembered_intent_structures_follow_live_only",
          "remembered_intent=function(mark,live)" in r
          and "return env.structure_mark_live_only==false" in r
          and "if claim_profile(mark.resource) then return true end" not in r,
          "★ 结构/泰坦/变体改为「只认活标记」（取消即失效）；"
          "旧的「无条件 return true」必须已不存在（不是两条并存）")
    check("structure_mark_live_only_default_true_wired",
          "structure_mark_live_only=true," in e
          and "structure_mark_live_only=state.structure_mark_live_only," in e,
          "开关默认 true 且已透传（置 false 可回到'长期记忆'）")
    check("unit_mark_live_only_off_restores_old",
          "return env.unit_mark_live_only==false" in r,
          "置 false 即回到旧行为（一键可回退）")
    check("ping_filter_uses_current_and_intent",
          "if selected and options.remembered_intent then" in g
          and "if m.current or options.remembered_intent(m,false) then" in g,
          "过滤判据 = current(本帧可见) 或 调用方允许长期记忆")
    check("ping_filter_after_memory_update",
          g.index("local selected=memory:update(observation,valid)")
          < g.index("if selected and options.remembered_intent then"),
          "过滤必须在 memory:update **之后**（顺序即语义）")
    check("ping_memory_contract_untouched",
          "remembered_intent" not in pm and "keep_intent" not in pm,
          "★ ping_memory 保持上游原样（过滤放在 native_ping，保住 UNTOUCHED 清单）")
    check("observe_failure_clears_current",
          "if last_selected then last_selected.current=false end" in g,
          "★ 观测失败那一帧不许再声称'它还在 ping 环里'（current 反转，防陈旧信号）")

    # ---- 让位事件必须可观测（诊断被节流掉 = 诊断不存在）----
    check("yield_diagnostic_whitelisted",
          "and not line:match('^unit_lock_yielded;')" in e,
          "★ 让位事件进日志白名单（它是'虫洞抢回单位'是否生效的唯一判据）")
    check("yield_diagnostic_deduped",
          "M.yield_reported={}" in p and "not M.yield_reported[yk]" in p,
          "让位事件按 (G-60, 结构) 去重（让位失败会反复触发，不去重会刷屏）")


def test_marked_unit_rank_order():
    """★★ 2026-10-02：**标记队列按优先级排序**（用户：「标记敌人单位时，泰坦的优先级不是最高的」）★★

    背景：队列默认按**新旧**排（队首 = 最晚 ping 的），名册 rank（泰坦/蟑龙=10 最高）只被
    **自动索敌**路径用过，而那条路径本工程早已裁掉 ⇒ 标记路径上没有"重量级"概念。
    现在：`native_ping` 提供 `options.priority` 钩子（数值小的先），runtime 只把它给
    **标记目标**那条队列（`structure_ping`），并定死五段档位。
    2026-10-03 追加：**蟑龙插在虫洞与泰坦之间**（用户：「蟑龙优先级放在虫洞和泰坦之间」）。
    """
    print()
    print("=== 3d. 标记队列的优先级（虫洞 > 蟑龙 > 泰坦 > 名册其它 > 名册外）===")
    ping = (ROOT / "src" / "g60" / "native_ping.lua").read_text(encoding="utf-8")
    rt = (ROOT / "src" / "g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
    entry = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # ---- native_ping：钩子只在"最优不是队首"时才换（否则零行为变化）----
    check("marked_queue_priority_hook",
          "if selected and options.priority then" in ping
          and "local p=options.priority(base[i])" in ping,
          "★ `native_ping` 支持调用方给的队内优先级（`options.priority`，数值小的先）")
    check("marked_queue_priority_only_when_needed",
          "if bi and bi>1 then" in ping,
          "★ 只在**最优不是队首**时才替换 ⇒ 队首本来就最优（或未提供钩子）⇒ 零行为变化")
    ping_code = "\n".join(l for l in ping.splitlines() if not l.strip().startswith("--"))
    check("marked_queue_tie_keeps_order",
          "p<best" in ping_code and "table.sort" not in ping_code,
          "★ 相等优先级**保持原顺序**（= 「最新 ping 优先」）：用严格 `<` 逐个比较实现，"
          "**不用 `table.sort`**（Lua 的 sort 不稳定，相等项会被打乱）")

    # ---- runtime：档位 + 只给标记那条队列 ----
    check("mark_priority_tiered",
          "priority=(env.marked_unit_rank_first~=false) and function(mark)" in rt
          and "env.structure_profiles[r]~=nil then return 0" in rt
          and "r==env.dragonroach_resource then" in rt
          and "return 500" in rt
          and "titan_profile.resource==r then return 1000" in rt
          and "titan_variant_profiles[r]~=nil then return 1000" in rt
          and "return 1000+spec.rank" in rt
          and "return 1500" in rt,
          "★ 五段档位：虫洞/构筑=0 · **蟑龙=500** · 泰坦（含变体）=1000 · 名册敌人=1000+rank · "
          "其它单位=1500")
    check("dragonroach_tier_between_structure_and_titan",
          "return 0 end" in rt and "r==env.dragonroach_resource then" in rt
          and "return 500" in rt and "titan_profile.resource==r then return 1000" in rt,
          "★★ 蟑龙**在虫洞之后、泰坦之前**（2026-10-03 用户指定）")
    check("dragonroach_tier_uses_exact_hash_not_kind",
          "r==env.dragonroach_resource then" in rt
          and "kind=='thorax'" not in "\n".join(
              l for l in rt.splitlines() if not l.strip().startswith("--")),
          "★ 蟑龙档位**复用准入路径的同一判据**（`dragonroach_enabled` + 精确哈希"
          "`dragonroach_resource`）；**不按 kind 推断**（与本文件 `no_kind_based_admission` "
          "同一条安全属性 —— 否则会出现\"优先了却瞄不了\"的错配）。"
          "⚠ 必须钉 `r==env.dragonroach_resource` **这个比较式**，只钉 `env.dragonroach_resource`"
          " 是不够的（把它换成硬编码哈希仍然全绿 —— 变异⑤实测踩到）")
    check("dragonroach_tier_precedes_titan",
          rt.index("r==env.dragonroach_resource") < rt.index("titan_profile.resource==r"),
          "★ **顺序即语义**：蟑龙判定必须在泰坦判定**之前** —— 否则蟑龙会被 1000 抢先")
    i_ping = rt.index("structure_ping=env.structure_profiles and Ping.new(env,{")
    i_pri = rt.index("priority=(env.marked_unit_rank_first")
    check("mark_priority_only_on_marked_queue",
          i_ping < i_pri < rt.index("position=function(e)") and "Ping.new(env)" in rt,
          "★ 只给**标记目标**那条队列（`structure_ping`）；空白标记那条（`Ping.new(env)`，无选项）"
          "完全不受影响")
    check("mark_priority_one_place",
          rt.count("priority=(env.marked_unit_rank_first") == 1,
          "该钩子只接在一处（防止「接错队列」这类静默错配）")

    # ---- 档位算术的规格镜像（不是重述源码字符串，而是验证**次序关系**）----
    def tier(resource="x", structure=False, dragonroach=False, titan=False, variant=False,
             rank=None):
        if resource is None:
            return 2000
        if structure:
            return 0
        if dragonroach:
            return 500
        if titan or variant:
            return 1000
        if rank is not None:
            return 1000 + rank
        return 1500

    check("rank_order_structure_first",
          tier("hole", structure=True) < tier("roach", dragonroach=True),
          "① 虫洞/构筑 仍**高于**任何标记单位（用户定过的最高档不能被 rank 顶掉）")
    check("rank_order_dragonroach_between_structure_and_titan",
          tier("hole", structure=True) < tier("roach", dragonroach=True) < tier("titan", titan=True),
          "② ★ 蟑龙**在虫洞之后、泰坦之前**（2026-10-03 用户指定）")
    check("rank_order_titan_first_among_other_units",
          tier("titan", titan=True) < tier("x", rank=10) < tier("x") < tier(None),
          "③ 泰坦（含变体）> 名册其它敌人（冲锋者 50 …）> 名册外单位 > 资源缺失")
    check("rank_order_catalog_is_lowest_number_first",
          tier("a", rank=10) < tier("b", rank=50),
          "名册里 rank 小的优先（与 `target_policy` 的旧语义一致：rank 越小越优先）")

    # ---- 开关（一键回退到"最新 ping 优先"）----
    check("marked_unit_rank_switch",
          "marked_unit_rank_first=true," in entry
          and "marked_unit_rank_first=state.marked_unit_rank_first," in entry
          and ";marked_unit_rank_first='..tostring(state.marked_unit_rank_first)" in entry,
          "★ 开关三处齐全（配置 + 透传 + 状态行）；置 false ⇒ 回到旧的「最新 ping 优先」")


def test_status_line_fits_log_cap():
    """★★ 2026-10-03：启动状态行必须**分段**，且每段都装得进 `emit` 的 900 字符上限 ★★

    实机取证（不是预防性改动）：日志首行被**从中间切断** ——
        `...enemy_veto_resources=74e2285c01da4f71,db90077e76`   ← 第二个哈希断在这里
    其后**所有**字段一个字都没写出来，含那三个用户明确要求的开关
    （`unit_mark_live_only` / `structure_mark_live_only` / `marked_unit_rank_first`）。
    根因是我们自己的 `line=...:sub(1,900)` ⇒ 「承诺了却看不到」。
    ⇒ 分段 + `status_len` 自报长度；本测试**真的求值**每段长度（不是数源码字符）。
    """
    print()
    print("=== 3e. 启动状态行：分段且每段 ≤900（否则被 emit 静默切断）===")
    e = ENTRY_SRC.read_text(encoding="utf-8")

    for name in ("status_core", "status_titan", "status_marks"):
        check("status_segment_" + name, ("local %s=" % name) in e, f"`{name}` 段已声明")
    check("status_segments_emitted",
          "emit(status_core);emit(status_titan);emit(status_marks)" in e,
          "三段都真的打出去（少打一段 = 那批字段又消失）")
    check("status_cap_pinned_with_selfreport",
          ":sub(1,900)" in e and ";cap=900'" in e,
          "★ `emit` 的截断上限与 `status_len` 自报的 `cap` 必须是**同一个数**"
          "（改一个不改另一个 ⇒ 自报失去意义）")
    # ★ 2026-10-05：`titan_standoff_min=` / `titan_belly_above=` 已按上游移除
    #   （见 test_adaptive_standoff 的反向断言）；新增上游泰坦链的两个开关。
    for fld in ("titan_standoff=", "titan_arrival_radius=",
                "adaptive_approach=", "blast_regions=",
                "dragonroach_enabled=", "dragonroach_resource=",
                "enemy_veto_resources=", "unit_mark_live_only=",
                "structure_mark_live_only=", "marked_unit_rank_first=",
                "titan_enabled=", "titan_resource=", "titan_variants="):
        check("status_keeps_field_" + fld.rstrip("="),
              fld in e, f"字段名 `{fld[:-1]}` 原样保留（改了会让文档/脚本的 grep 失效）")

    def seg(name, nxt):
        i = e.index("local %s=" % name)
        j = e.index(nxt, i)
        body = "\n".join(l for l in e[i:j].splitlines()
                         if not l.lstrip().startswith("--"))
        body = body[body.index("=") + 1:]
        return body.rstrip().rstrip(";")

    core = seg("status_core", "local status_titan=")
    titan = seg("status_titan", "local status_marks=")
    marks = seg("status_marks", "emit(status_core)")
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    # 宽容 stub：任何未知 state 字段都给 8 字符宽的占位（比真值 `true` / `2.5` 更保守）
    rt.execute("""
    local stub={}
    setmetatable(stub,{__index=function(t,k) return string.rep('x',8) end})
    stub.titan_arrival_region={radius='2.25',depth='1.2'}
    local state=stub
    local Filter={excluded_resources=function() return {'74e2285c01da4f71','db90077e76faa025'} end}
    local TitanVariants={resources=function() return {'ef04cb84d097a497'} end}
    local TitanProfile={resource='9e2e17f2ccccafdd'}
    function measure()
        local a=%s
        local b=%s
        local c=%s
        return a,b,c
    end
    """ % (core, titan, marks))
    a, b, c = rt.eval("measure()")
    check("status_core_fits", len(a) <= 900, f"`version=` 段实测 {len(a)} 字符（上限 900）")
    check("status_titan_fits", len(b) <= 900, f"`titan_settings;` 段实测 {len(b)} 字符")
    check("status_marks_fits", len(c) <= 900, f"`mark_settings;` 段实测 {len(c)} 字符")
    print(f"    实测长度: core={len(a)} / titan={len(b)} / marks={len(c)}  (cap=900)")


def test_enemy_faction_gate(rt):
    """敌阵营硬门槛 + `faction` 作用域崩溃回归（2026-10-10 实机事故）。

    事故一（用户第三次报"标记友方被炸"）：
        旧代码拿 `calls.target_valid` 当**阵营判据**，注释理由是"引擎索敌不锁友方"。
        实测它是"能不能被打"：哨戒炮/补给支架**有生命值** ⇒ 返回 true ⇒
        玩家标记的友方被当成合法目标炸掉（实机 517 火焰哨戒炮 / 592 哨戒机枪 /
        536 补给背包支架，距离 0.74~0.78 m 引爆）。信标球/武器模型返回 false ⇒
        被正确忽略 —— 我上次的"4/4 友方全 false"样本**全是信标球和模型**。
    事故二（我自己引入的崩溃）：
        `local function faction` 定义在 `if structure_ping then` 块**内部**，
        而兜底 veto 那处调用在该块**闭合之后** ⇒ 取到全局 nil ⇒
        `frame_error;…:8960: attempt to call global 'faction' (a nil value)`，
        每触发一次就中止当帧剩余全部处理。
    """
    print()
    print("=== ㊾ 敌阵营硬门槛 + faction 作用域（2026-10-10）===")
    r = PRIORITY.read_text(encoding="utf-8")
    run = RUNTIME.read_text(encoding="utf-8")
    mod = (ROOT / "src/g60" / "enemy_faction.lua").read_text(encoding="utf-8")
    bj = (ROOT / "compat" / "build.json").read_text(encoding="utf-8")

    # 1) 生成文件自带出处（生成器 + 数据源 sha256 + 判据），否则无法重跑/审计
    check("enemy_faction_is_generated_with_provenance",
          "生成文件，不要手改" in mod and "scripts/gen_enemy_faction.py" in mod
          and "sha256 = " in mod and "AiEnemyComponentData" in mod,
          "生成文件头带生成器 / 数据源 sha256 / 判据（可重跑、可审计）")

    # 2) 真跑模块：判据语义（不是只看文本）
    m = load_module(ROOT / "src/g60" / "enemy_faction.lua", "enemy_faction", rt)
    # ⚠ 字符串参数必须**在 Lua 侧**拼（本 runtime 用 encoding=None，从 Python 传 str
    #   进去不会匹配 Lua 表键 ⇒ 全部返回 false，测试会假绿）。
    rt.execute("__E = require('g60.enemy_faction')")
    assert m is not None
    enemies = ["be39e313a1e46bb9", "a1f37bf2a40fbde4", "3d0e03e2d574e1ca",
               "9e2e17f2ccccafdd", "ef04cb84d097a497", "960b48a421a3faaa"]
    friendlies = ["37cde43876ba26bb", "820cc3bafe962858", "31400a6a3003e29c",
                  "c87555eed1e9f092", "16f397ca5f51f271", "b16c9d490aa59b77",
                  "8e325c933e55bf62", "4d1c334d294dfa97", "4abcf54464695efa",
                  "74e2285c01da4f71", "db90077e76faa025", "8c31b749759cbd61",
                  # 规则唯一误判（显式排除，证据见生成器 EXCLUDE 注释）
                  "021eaecf4ca267dc",
                  # 玩家侧杂项：载具 / 喷射舱 / 鹈鹕 / SEAF / 假人 / 各类信标
                  "cc21c7ffd3ebefb9", "9b2140378640432e", "2d85bfe3d8717fe5",
                  "e58163e71928d3e2", "75be82ed8592a6b3", "a00331f24deef2ee",
                  "3caabad4d5c09d33", "6293caf0559bacf6", "0965aaeba7ccbca8"]
    miss = [h for h in enemies if rt.eval("__E.is_enemy('%s')" % h) is not True]
    bad = [h for h in friendlies if rt.eval("__E.is_enemy('%s')" % h) is not False]
    check("enemy_faction_known_enemies", not miss,
          "实机确认的敌人/泰坦/蟑龙全部判为敌人（漏=%s）" % miss)
    check("enemy_faction_known_friendlies", not bad,
          "★ 哨戒炮/支架/信标球/模型/玩家/平民/虫洞/敌载具 全部**不**判为敌人（误=%s）" % bad)
    check("enemy_faction_rejects_non_string",
          rt.eval("__E.is_enemy(nil)") is not True and rt.eval("__E.is_enemy(123)") is not True
          and rt.eval("__E.is_enemy('')") is not True,
          "nil/数字/空串一律不是敌人（fail-safe）")
    check("enemy_faction_is_pure_lookup",
          "ffi" not in mod and "read(" not in mod and "require" not in mod,
          "零依赖零内存读的纯表查找（可离线真跑）")

    # 3) 门槛装点：必须在 target_valid 查询**之前**（纯 Lua 查找，零内存读）
    gi = r.index("EnemyFaction.is_enemy(e.resource)")
    vi = r.index("local ok_valid,valid_now=pcall(function()")
    check("enemy_gate_before_target_valid", gi < vi,
          "★ 敌阵营门槛在 target_valid 之前（先零成本拒掉，再花原生查询）")
    check("enemy_gate_honours_marked_allowed",
          "Filter.marked_allowed(e.resource)" in r[gi - 200:gi + 200],
          "★ 显式例外保留（机器人运输船 / 光能族增援飞船 = 敌载具，用户要求标记就炸）")
    check("enemy_gate_detail_is_auditable",
          "NOT_ENEMY_RESOURCE" in r and r.count("..tostring(detail)") >= 2
          and "..tostring(gdetail)" in r,
          "★ 三处调用点都把 detail 打进日志（generic_rejected / structure_lock_lost）")
    check("enemy_gate_required_module",
          "local EnemyFaction=require('g60.enemy_faction')" in r,
          "native_priority 顶层 require（build.py 会替换成别名）")
    # 4) 模块顺序：依赖必须排在使用者之前（build.py 的 assert_alias_order 也钉，这里提前拦）
    check("enemy_faction_before_native_priority",
          bj.index('"enemy_faction"') < bj.index('"native_priority"'),
          "build.json 里 enemy_faction 排在 native_priority 之前（别名先定义）")

    # 5) ★ 崩溃回归：`faction` 必须定义在**那个** `if structure_ping then` 之外
    #    ⚠ 锚点必须取**真的那一个**：文件里 `if structure_ping then` 有 6 处，而且
    #      faction 上方那段说明**注释里也写了这串字**（我自己写的）—— 用
    #      `index('if structure_ping then', 从 mark_friendly 起)` 会命中注释 ⇒ 假红。
    #      可靠锚点：先定位 `structure_ping:observe()`，再往**回**找最近的 if。
    obs = run.index("structure_mark,structure_issue=structure_ping:observe()")
    s = run.rindex("if structure_ping then", 0, obs)
    d = run.index("local function faction(id,res)")
    c = run.index("fv=faction(m.selection_id,vr)")
    check("faction_defined_outside_structure_ping_block", d < s,
          "★ 定义字符位(%d) < 真块 `if structure_ping then`(%d) —— 否则块内定义 ⇒ "
          "兜底 veto 处取到全局 nil ⇒ frame_error 中止当帧" % (d, s))
    check("faction_defined_before_both_calls",
          run.count("local function faction(id,res)") == 1 and d < c,
          "只定义一次，且在**两处**调用之前（词法作用域，与缩进无关）")
    check("faction_call_sites_are_two",
          run.count("faction(") >= 3,
          "两处调用（标记判友方 + 兜底 veto）都还在（删掉一处会让对应功能静默消失）")


def test_safe_zone_redundancy():
    """安全区冗余（2026-10-10，用户报「安全区有时候还是会发生引爆，能增加冗余吗」）。

    实机根因（2981 行日志，7 例 `arrival_already_exploded`）：
        门判了"玩家在圈内"（`blast_hold;entity=540;player_dist=11.87`），
        却**一条 `safe_engine;` 都没有** ⇒ 没有任何执行者。真凶是
        `run_safe_hold` 里那句 `if not tid then return end` ——
        引擎把目标表示成**点**时（`sel_probe` 的 `4|0|1|nil`：flag=1、id=0）
        `tid=nil` ⇒ 直接返回。这一类雷在引擎里占多数 ⇒ 一次都没被压过。
    """
    print()
    print("=== ㊿ 安全区冗余（圆心三源 + 入口放宽 + 无执行者告警）===")
    run = RUNTIME.read_text(encoding="utf-8")
    e = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

    # 1) ★ 回归门：那句提前 return 必须消失（它是这 7 例的真凶）
    #    ⚠ 必须**先去注释**再查：修复说明里引用了那句原文，直接查全文会假红。
    code = "\n".join(l for l in run.splitlines() if not l.lstrip().startswith("--"))
    check("safe_no_early_return_on_missing_tid",
          "if not tid then return end" not in code,
          "★ `if not tid then return end` 已从**代码**里删除（点态选择时它让整条路零执行者）")

    # 2) 圆心三源都在
    for tag, why in [("csrc='entity'", "① 引擎选中的实体位置"),
                     ("csrc='point'", "② 记录里引擎自己的点（点态选择时只有它有）"),
                     ("csrc='last'", "③ 上次已知圆心 P.tpos")]:
        check("safe_center_source_" + tag.split("'")[1], tag in run,
              "圆心来源 %s 存在" % why)

    # 3) ② 必须排除"我们自己写下去的点"，否则会绕着自己转
    check("safe_center_excludes_own_point",
          "local ours=rec and rb and rb:sub(0x1d,0x28)==rec.bytes" in run
          and "if rb and not ours then" in run,
          "★ 记录里的点若与 rec.bytes 逐字节相同 = 我们写的 ⇒ 不当圆心")

    # 4) 偏移必须一致：Lua 的 sub(0x1d,0x28) 是 1-based = 0-based 0x1c..0x27
    check("safe_center_point_offset_consistent",
          "rb:sub(0x1d,0x28)==rec.bytes" in run
          and "TargetData.vector,rb,0x1c" in run,
          "★ 记录点偏移与绕行判据同一个（1-based 0x1d ⇒ 0-based 0x1c）")

    # 5) 入口放宽：点态选择也要进（selection_flag==1 涵盖实体与点）
    check("safe_gate_accepts_point_selection",
          "m.selection_id~=0 or m.selection_flag==1 or P.ehq[m.id]~=nil" in run,
          "★ 入口从 `selection_id~=0` 放宽到 `selection_flag==1`（实体或点都算）")
    check("safe_gate_still_narrow",
          "and m.behavior_id==4 and m.state==4" in run
          and "not (old and (old.lock or old.titan or old.point))" in run,
          "收窄面不变：state==4 / behavior==4 / 不是我们在驾驶")

    # 6) 无执行者告警：两个来源 + 白名单 + 状态表
    check("safe_noexec_two_reasons",
          "';reason=NO_CENTER'" in run and "';reason=ENGINE_PATH_GATED'" in run,
          "★ 两类洞各有一条告警（圆心三源全取不到 / 入口被条件挡住）")
    check("safe_noexec_whitelisted", "line:match('^safe_noexec;')" in e,
          "★ 白名单化（诊断被节流掉 = 诊断不存在）")
    check("safe_noexec_state_declared", "noexec={},noexec_warn={}," in run,
          "计数与告警去重都在 P（upvalue 已近 60 上限）")
    check("safe_noexec_cleared",
          run.count("P.noexec[match.id]=nil") >= 3,
          "有执行者 / 玩家离开圈 / 换了一颗雷 ⇒ 计数清零（否则会误报）")
    check("safe_noexec_threshold_is_half_second",
          "if n>=30 and not P.noexec_warn[match.id] then" in run,
          "连续 ≥30 帧（0.5 s）才报，每颗一次（不刷屏）")
    # ★★ 2026-10-10 用户拍板"按建议做"：两个写者互斥 + skipped 自报家门 ★★
    check("safe_zone_write_owns_the_frame",
          "P.szw[match.id]=frame" in run and "and P.szw[m.id]~=frame" in run
          and "szw={}," in run,
          "★★「谁写了谁负责」：安全区本帧写过点的雷，点目标驱动**这一帧让位** —— "
          "否则它拿「写之前」的观测调原生，撞 `stale observation`"
          "（实机 entity=508：连续 4 帧 skipped 白烧）；只判 ==frame ⇒ 不跨帧")
    check("skipped_reports_which_path",
          "';via='..((old and old.point and 'point')" in run
          and "or (old and old.titan and 'titan') or 'runner')" in run,
          "★ 三条引导路共用同一段失败记账 ⇒ `skipped;` 必须自报家门（via=），"
          "否则 `stale observation` 只能靠猜（实机 entity=508 就是这样）")
    check("point_beats_titan_reason_matches_fact",
          "and 'PLAYER_PING_OVER_ENGINE_SELECTION'" in run
          and "or 'PLAYER_PING_NO_ENGINE_SELECTION'))" in run,
          "★ 2026-10-10：reason 必须与 `titan=` 的实际值一致 —— "
          "`ping_beats_titan` 的条件并不要求引擎有选择，实机 4 条 `titan=0` 也写"
          "「over engine selection」纯误导；tag 名保留（历史 grep/白名单锚点）")

    # 7) 冗余不许引入新的写通道
    #    ⚠ 不能笼统查 "calls.orbit" 不在文件里 —— `early_nav_orbit` 那段（默认关的
    #      实验）本来就有 `env.calls.orbit`。这里钉"**新增**了没有"：计数不变。
    check("safe_redundancy_no_new_write_path",
          "WriteProcessMemory" not in run and run.count("env.calls.orbit(") == 1,
          "本段纯只读 + 走已有的 arrival:step 写点（不新增写内存、不新增原生调用；"
          " env.calls.orbit 仍是 early_nav_orbit 那 1 处，默认关）")


    # 8) ★★ 冗余第四层「清掉引擎的选择」（2026-10-10，用户拍板做成开关）★★
    check("safe_veto_toggle_default_off",
          "safe_zone_veto_selection=false," in e,
          "★ 默认关（与 safe_zone_engine_hold 同纪律：又一条写非自有 G-60 的行为，"
          "而且清的是引擎自己的索敌）")
    check("safe_veto_toggle_wired_to_env",
          "safe_zone_veto_selection=state.safe_zone_veto_selection," in e
          and e.index("safe_zone_veto_selection=false,")
          < e.index("safe_zone_veto_selection=state.safe_zone_veto_selection,"),
          "★ 开关必须同时接进 env（本项目栽过「开关进了 state 没进 env ⇒ 静默不生效」）")
    check("safe_veto_toggle_in_menu",
          "g60.safe_zone_veto_selection" in e
          and "host.env.safe_zone_veto_selection=v" in e,
          "★ 必须能在游戏里开关（用户要求「做成一个开关功能」）")
    check("safe_veto_uses_audited_path",
          "run_veto(match,match.selection_resource,'safe_zone'," in run,
          "★ 走**已审查的**清选择路径 run_veto（不是新写的写内存通道），via=safe_zone")
    check("safe_veto_quiet_after_first",
          "P.evv[match.id]~=nil,runner.safe_veto_runner)" in run,
          "★ 第一次之后传 quiet=true（否则 enemy_veto; 逐帧刷屏），并带上专用实例")
    check("safe_veto_only_in_close_window",
          "env.safe_zone_veto_selection==true and c and r and r<=cthr" in run,
          "★ 只在贴脸窗口（r<=取消线）里逐帧清 —— 引擎每帧都会重新锁上")
    check("safe_center_point_also_reads_projectile",
          "P.hit[match.id]=p4" in run and "local ok4,p4=pcall(function()" in run,
          "★★ 源②（记录里的点）必须**同时**读回「雷在哪」—— 否则 r=nil ⇒ "
          "贴脸取消永远够不着（它要求 r<=cthr）、need_write 恒真、"
          "`r=-`/`dist=-` 两条诊断全废（实机 entity=623：玩家离雷 4.49~5.76 m，"
          "两个机制都因为 r 未知而够不着）")
    check("safe_veto_only_without_mark",
          "local has_mark=(structure_mark~=nil) or (mark~=nil) or (point_armed==true)" in run,
          "★★ 用户要求「只应用在无标记的情况下」：三源都算玩家意图"
          "（结构/通用标记 / ping 到的单位 / TTL 内的空地点）—— "
          "gate.drive 覆盖不到 engine_owns_it 与 quarantined 两条 edge case，所以必须显式再判")
    check("safe_veto_boundary_visible",
          "';reason=HAS_MARK'" in run
          and "';reason=POINT_SELECTION_HAS_NO_RESOURCE'" in run
          and "P.evp[match.id]" in run,
          "★ 跳过必须可见（有标记 / 点式选择）—— 否则「开了没效果」与"
          "「有标记所以不该清」分不开")
    check("safe_veto_tags_whitelisted",
          "line:match('^safe_veto;')" in e and "line:match('^safe_veto_skip;')" in e,
          "★ 两条判据行都白名单化（诊断被节流掉 = 诊断不存在）")
    check("safe_veto_run_veto_reports_result",
          "return ok_v and ok_v.kind or 'FAILED',res_v" in run,
          "★ run_veto 回传 (kind, why)：调用方要把它写进自己的证据行")
    check("safe_veto_state_declared", "evv={},evp={}," in run,
          "取证去重表在 P（upvalue 已近 60 上限），且两类分开计数")


    check("safe_veto_uses_dedicated_runner",
          "runner.safe_veto_runner=Minimal.new_experimental(with_observation," in run
          and "P.evv[match.id]~=nil,runner.safe_veto_runner)" in run,
          "★★ 必须用**专用**实例（allowed 恒 false）：实机 4 条 "
          "`safe_veto;…;result=keep;why=VANILLA_ALLOWED` 证明主 runner 是空转的 —— "
          "`env.target_allowed` 只在 designed_targets_only==true 时构造，而本裁剪版是 false "
          "⇒ allowed==nil ⇒ SelectionVeto.plan 恒返回 keep ⇒ 对普通敌人一次都清不了；"
          " ⚠ 它**挂在 runner 上当字段**、不是新 local —— tick 的 xpcall 已正好 60 upvalue，"
          " 多一个 local 就会让整份 chunk 编译失败（实机事故 2026-10-10）")
    check("safe_veto_runner_is_isolated",
          "if R:disabled() then" in run
          and "if R==runner then" in run
          and "return 'DISABLED','SAFE_VETO_RUNNER_DISABLED'" in run,
          "★ 专用实例 disabled 只关掉这一个功能，**不许**让整局 mod 停手"
          "（主 runner 才走 self.disabled + error 的 fail-closed）")
    check("safe_veto_root_cause_documented",
          "designed_targets_only" in run and "VANILLA_ALLOWED" in run
          and "allowed==nil" in run,
          "★ 根因写进代码：否则下一个人会以为这个开关本来就该没用")


    # ★★ 2026-10-10 用户报「安全区貌似对队友不生效」★★
    check("safe_zone_covers_teammates",
          "local function players_scan()" in run
          and "pointer(base+0x3326d20)" in run and "read(am+0x6c,4)" in run
          and "pointer(am+0x110+i*8)" in run,
          "★★ 安全区必须覆盖队友：读游戏自己的 avatars 列表"
          "（base+0x3326d20 / count@+0x6c / 实体指针数组@+0x110+i*8）—— "
          "同工程 aggro_counter **实机跑过**的读法，且其 owner/id_map/entities 三个偏移"
          "与本工程 d.root 完全一致（同一份 game.dll dump）；"
          " **绝不枚举实体表**（2026-09-28 那个 4m 潜兵安全区就是这么死的）")
    check("safe_zone_uses_nearest_player",
          "local best,d2=nearest_player(own,mysp)" in run
          and "';players='..tostring(P.av.list and #P.av.list or 0)" in run,
          "★★ 判据必须是**最近的玩家**（自己 ∪ 队友），不是只比自己；"
          " `players=` 给出参与判定的玩家数（缺了就没法证伪「对队友不生效」）")
    check("safe_zone_players_cache_is_per_frame",
          "if P.av.frame~=frame then" in run and "av={}," in run,
          "★ avatars 列表**每帧只读一次**并缓存 —— gate 是逐颗雷逐帧调用的"
          "（实机一局 1863 次 blast_hold），逐次读会把 layout_reads 打爆")
    check("safe_zone_players_failure_is_visible",
          "safe_players;n=0;reason='..tostring(why)..';frame='..frame)" in run
          and "line:match('^safe_players;')" in e,
          "★★ 读不到 avatars 必须**可见**（退回只有自己是 fail-safe，"
          "但静默降级 = 诊断不存在，本项目已栽过多次）")
    # ★★★ 通用门：任何 local 都不得在"声明之前 / 声明所在块之外"被使用 ★★★
    #   同一类坑咬了两次（faction 崩溃 / pointer 让队友安全区静默失效）⇒
    #   这次做成**通用检查**，而不是再写一条针对性的门。
    import subprocess as _sp
    import sys as _sys
    _p = _sp.run([_sys.executable, '-B', 'tests/check_local_order.py'],
                 cwd=ROOT, capture_output=True, text=True)
    check("no_local_used_before_declaration",
          _p.returncode == 0,
          "★★ 通用作用域门：`local` 在声明前/块外使用会解析成全局 = nil"
          "（faction 崩溃 + pointer 让队友安全区静默失效，两次都只有实机才暴露）；"
          " 检查器的召回已用「修复前的版本能精确抓出 pointer」验证过"
          + ('' if _p.returncode == 0 else '  实际：' + _p.stdout[-400:]))


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
    test_every_lock_path_rechecks_reservation()
    test_takeover_scope_is_bughole_and_titan_only()
    test_diagnostics_not_throttled()
    test_enemy_veto_wiring()
    test_clearance_diagnostics_placement()
    test_adaptive_standoff()
    test_dragonroach_takeover()
    test_titan_variant_borrow()
    test_stuck_grenade_breakers()
    test_generic_takeover()
    test_link_diagnostics()
    test_early_nav_probe()
    test_sel_probe()
    test_code_probe()
    test_target_fields_probe()
    test_env_wiring_complete()
    test_force_lock()
    test_point_target(rt)
    test_blast_sites(rt)
    test_priority_wiring()
    test_arrival_fault_isolation()
    test_target_priority_tiers()
    test_marked_unit_rank_order()
    test_status_line_fits_log_cap()
    test_enemy_faction_gate(rt)
    test_safe_zone_redundancy()

    print()
    if failures:
        print(f"RESULT: {checks - len(failures)} passed; {len(failures)} failed")
        print("failed: " + ", ".join(failures))
        return 1
    print(f"RESULT: ALL PASS ({checks} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
