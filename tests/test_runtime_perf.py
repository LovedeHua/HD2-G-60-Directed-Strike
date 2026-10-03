"""每帧读取开销回归 —— 2026-09-30 性能优化。

背景
----
实机反馈"性能开销有点大"。审计 `experimental_runtime.lua` 后发现最大的一项不是
`Layout.capture`（每帧一次、40 读），而是 **`jobs_ready()` 被同一帧反复调用**：

    jobs_ready() = Readiness.capture = 16 次内存读取
    调用点：① tick 开头 ② 每次 `with_observation` 开头
            ③ `scope.validate()` **每次**被 assert 时（priority.step 里出现多次）
            ④ disposal:step 的 ready 回调

实机一帧内**一颗**在飞的 G-60 就能触发 5~10 次 ⇒ 上百次读取/帧，而同时在飞的常有
数颗 ⇒ 成为帧读取总量的绝对大头。

修法：`jobs_ready()` 结果按**帧**缓存（`readiness_frame==frame`）。
等价性论证：`host:tick` 在引擎主线程里同步执行（这是我们所有读成立的前提），
引擎不会在回调期间推进 ⇒ 同帧内 Readiness 观测值不变 ⇒ 缓存与重读同值。
**只在成功时缓存**；capture 抛错时照常向上抛，绝不用"异常"覆盖上一次的"就绪"。

本测试做三件事：
  ① **真跑源码**：把 experimental_runtime.lua 里的 `jobs_ready` 分段抠出来，
     配 mock 环境在 lupa 里执行，数 capture 的真实调用次数（不是复刻逻辑）。
  ② 结构断言：缓存键是 frame、赋值在 capture 之后（成功才算）、`ready_reads` 在
     缓存 return 之后（只统计真实执行）、体
     内不得有 pcall（否则会吞掉异常并把失败缓存成成功）。
  ③ perf 诊断行的存在与字段，以及 entry 白名单必须放行 `perf;`。
"""
import pathlib

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "src" / "g60" / "experimental_runtime.lua"
ENTRY = ROOT / "addon" / "entry.lua.in"

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


def extract_jobs_ready(text):
    """抠出 `local function jobs_ready()` … `end`（到 release_all 定义前）。"""
    i = text.index("local function jobs_ready()")
    j = text.index("local function release_all()", i)
    seg = text[i:j].rstrip()
    assert seg.endswith("end"), "jobs_ready 段没有以 end 结尾"
    return seg


def strip_lua_comments(text):
    """去掉 `--` 到行尾的注释（只服务 ⑦ 段）。

    为什么必须去注释：文件头**故意**写了事故记录，里面**必然出现** `ffi.cdef` /
    `QueryPerformanceCounter` 这些词（后人要看到）。守门要判的是**代码层有没有
    真的调用它们** —— 按全文判会被自己的文档文本误伤（假红）。

    局限（本文件足够）：只处理行尾 `--`，不认字符串里的 `--`；runtime 代码中
    没有这样的字符串字面量。
    """
    return "\n".join(l.split("--", 1)[0] for l in text.splitlines())


# ★ mock 环境：Readiness.capture 可计数、可注入失败。
HARNESS = """
local capture_count=0
local read=function() return 'x' end
local base=0x140000000
local env={exe=0x1,thread=function() return 0x2 end}
local Readiness={capture=function()
    capture_count=capture_count+1
    return {engine_main_thread_observed=true,world_job_completion=1,
            context_job_busy=0,context_job_active=0}
end}
local frame=0
-- ★ 与源码一致：所有计数器收在一个 table 里（Lua 5.1 upvalue 上限 60）
local P={ready_frame=-1,ready_value=nil,ready_reads=0,
         idle_skip=0,observe=0,lreads=0,lbytes=0,wframe=0,window=600}
{seg}
-- ① 同一帧调 5 次
frame=1
for i=1,5 do assert(jobs_ready()==true,'ready expected') end
__same_frame=capture_count
__ready_reads_after_same=P.ready_reads
-- ② 换帧后再调 2 次
frame=2
jobs_ready();jobs_ready()
__next_frame=capture_count
-- ③ 失败不得被缓存成成功，也不得计数
Readiness.capture=function() error('boom') end
frame=3
__ready_before_fail=P.ready_reads
local ok=pcall(jobs_ready)
__fail_ok=tostring(ok)
__frame_after_fail=P.ready_frame
__ready_reads_after_fail=P.ready_reads
-- ④ 失败后再次调用仍会重新尝试（因为没被标记成该帧成功）
local ok2=pcall(jobs_ready)
__fail_ok2=tostring(ok2)
"""


def main():
    text = RUNTIME.read_text(encoding="utf-8")
    seg = extract_jobs_ready(text)

    print("=== ① 真跑源码：同帧只 capture 一次 ===")
    rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    rt.execute(HARNESS.replace("{seg}", seg))

    def g(k):
        v = rt.eval(k)
        return v.decode() if isinstance(v, bytes) else v

    same = g("__same_frame")
    check("same_frame_captures_once", same == 1,
          f"同帧 5 次 jobs_ready ⇒ Readiness.capture 只执行 {same} 次（优化前应为 5）")
    check("next_frame_captures_again", g("__next_frame") == 2,
          f"换帧后重新采样（累计 {g('__next_frame')} 次）")
    check("ready_reads_counts_real_runs", g("__ready_reads_after_same") == 1,
          f"ready_reads 只统计真实执行（同帧 5 次调用后 ={g('__ready_reads_after_same')}）")
    check("failure_not_cached", g("__fail_ok") == "false" and g("__frame_after_fail") == 2,
          f"capture 抛错照常向上抛（ok={g('__fail_ok')}），"
          f"且不把该帧标记为已就绪（frame 仍是 {g('__frame_after_fail')}）")
    check("failure_not_counted", g("__ready_reads_after_fail") == g("__ready_before_fail"),
          f"失败的 capture 不计入 ready_reads"
          f"（失败前 {g('__ready_before_fail')} → 失败后 {g('__ready_reads_after_fail')}）")
    check("retry_after_failure", g("__fail_ok2") == "false",
          "失败后再次调用仍会重新尝试（不缓存失败）")

    print()
    print("=== ② 结构断言（防将来被'顺手'改坏）===")
    check("cache_keyed_by_frame", "if P.ready_frame==frame then return P.ready_value end" in text,
          "★ 缓存键 = 当前帧")
    _i_cap = seg.index("Readiness.capture")
    _i_val = seg.index("P.ready_value=")
    _i_mark = seg.index("P.ready_frame=frame")
    check("value_assigned_after_capture", _i_cap < _i_val < _i_mark,
          "readiness_value / readiness_frame 都在 capture **之后**赋值 ⇒ 只有成功才缓存")
    _i_hit = seg.index("if P.ready_frame==frame then return P.ready_value end")
    _i_cnt = seg.index("P.ready_reads=P.ready_reads+1")
    check("counter_after_cache_return", _i_hit < _i_cnt,
          "ready_reads 自增在缓存命中 return 之后 ⇒ 只统计真实执行")
    check("no_pcall_swallows_errors", "pcall" not in seg,
          "★ jobs_ready 体内不得有 pcall（否则会把失败吞成'就绪'并缓存）")
    check("single_readiness_capture_call", seg.count("Readiness.capture") == 1,
          "只读一次 Readiness.capture")

    print()
    print("=== ③ perf 诊断行与其白名单 ===")
    check("perf_window_constant", "window=600" in text,
          "有窗口常量（600 帧 ≈ 10 秒一行，收在 P table 里）")
    check("perf_line_emitted", "env.emit('perf;frame='" in text,
          "tick 里按窗口打 perf 行")
    for fld in (";ready=", ";observe=", ";layout_reads=", ";layout_bytes=",
                ";active=", ";count=", ";idle=", ";frames_seen="):
        check("perf_has" + fld.replace(";", "_").rstrip("="), fld in text,
              f"perf 行含 {fld[1:]}")
    check("perf_count_is_behavior_length",
          "';count='..tostring(observed.behavior_count)" in text,
          "★ `count` 取 `observed.behavior_count`（数组总长 = 逐槽扫描圈数），"
          "**不是** `active_prefix` —— 两者差一个数量级，混了就看不出"
          "\"读花在空槽上\"（2026-10-03 加它就是为了验证这一点）")
    _i_lc = text.index("local observed=Layout.capture(read,base)")
    _i_acc = text.index("P.lreads=P.lreads+observed.read_calls")
    check("layout_accrued_right_after_capture", _i_lc < _i_acc < _i_lc + 200,
          "Layout.capture 的读数紧接其后累计（否则窗口统计漏算）")
    e = ENTRY.read_text(encoding="utf-8")
    check("perf_whitelisted_in_entry", "line:match('^perf;')" in e,
          "★ entry 白名单放行 perf 行 —— 被节流掉就等于没测")

    print()
    print("=== ④ 空闲降频（没有 G-60 时不要每帧扫 behavior 数组）===")
    # ★ 2026-09-30 事故后的写法：所有诊断/降频计数器收进**一个 table `P`**。
    #   原因：Lua 5.1 每函数 upvalue 上限 60，而 `host:tick` 的 pcall 匿名函数已吃满；
    #   此前 10 个独立 local 直接顶破 ⇒ 整个 chunk 编译失败（"mod 没生效"）。
    check("perf_state_is_single_table",
          "local P={ready_frame=-1" in text and "idle_skip=0" in text,
          "★ 诊断/降频状态收在**同一个 table** 里（upvalue 只占 1 个，见 check_lua51_compile.py）")
    check("idle_skip_guard", "if P.idle_skip>0 and (frame%P.idle_skip)~=0 then return end" in text,
          "★ 空闲时按 P.idle_skip 分频跳过整帧")
    _i_inc = text.index("frame=frame+1")
    _i_skip = text.index("if P.idle_skip>0 and (frame%P.idle_skip)~=0 then return end")
    _i_pcall = text.index("local ok,why=pcall(function()")
    check("skip_after_frame_increment", _i_inc < _i_skip,
          "★ 跳帧判断在 frame+1 **之后**（否则帧号会漏数，perf 窗口与状态追踪都会错）")
    check("skip_before_pcall", _i_skip < _i_pcall,
          "跳帧判断在 pcall **之前**（否则等于没省：读都做完了）")
    _i_lc2 = text.index("local observed=Layout.capture(read,base)")
    _i_busy2 = text.index("local busy,veto_must=(next(tracked)~=nil)")
    _i_idle = text.index("P.idle_skip=busy and (veto_must and 1 or rb) or ri")
    _i_pf2 = text.index("if frame-P.wframe>=P.window then")
    check("idle_state_set_from_observation", _i_lc2 < _i_busy2 < _i_idle < _i_pf2,
          "★ 降频判据在 capture **之后**、perf 打点**之前**（按本帧实际内容判）")

    print()
    print("=== ⑥ 降频判据 ='有事可做'（2026-10-02；旧判据在 state-3 空转时段白扫 600 帧）===")
    # 实机日志：`frame=36600/37200 ready=600 observe=0` —— 整窗口 600 帧**一次接管
    # 都没有**，却仍满速扫了 600 遍（141 读/帧）。原因是 G-60 停在 state 3 上千帧
    # （≈27 秒），而 state 3 我们**一个字节都不写**。旧判据 `#matches>0` 分不出这种。
    _i_busy = text.index("local busy,veto_must=(next(tracked)~=nil)")
    _i_setidle = text.index("P.idle_skip=busy and (veto_must and 1 or rb) or ri")
    busy_block = text[_i_busy:_i_setidle]
    check("idle_gate_is_busy_based",
          _i_busy < _i_setidle,
          "★ 降频由 `busy`（有没有事可做）决定，不再是 `#observed.matches>0`")
    check("idle_gate_covers_state4",
          "m.state==4" in busy_block,
          "① 有 state 4 的 G-60 ⇒ 每帧（可接管 / 可引导）")
    check("idle_gate_covers_state3_when_allowed",
          "env.allow_state3 and (m.state==2 or m.state==3)" in busy_block,
          "② allow_state3 打开时 state 2/3 也保满速（早期驱动路径要每帧）")
    check("idle_gate_covers_veto",
          "Filter.excluded(m.selection_resource)" in busy_block,
          "③ 引擎选中的目标在排除表里 ⇒ 否决必须每帧重申，不能被降频漏掉")
    check("idle_gate_covers_held",
          "next(tracked)~=nil" in busy_block and "current~=nil" in busy_block,
          "④ 本 mod 还持有某颗 ⇒ 每帧（disposal / arrival 靠每帧观测推进）")
    check("idle_gate_covers_early_probe",
          "env.early_nav_probe==true" in busy_block,
          "⑤ early_nav_probe 打开 ⇒ 每帧（该探测每颗只跑一次，不能被降频漏掉）")
    check("idle_gate_uses_captured_matches",
          "local ms=observed.matches" in busy_block and "for i=1,#ms do" in busy_block,
          "★ 遍历的是**本帧已捕获**的实体表 ⇒ 零新增内存读")
    check("idle_gate_no_new_reads",
          "read(" not in busy_block,
          "★ 判据里不得出现任何内存读（降频本身不能有成本）")
    check("idle_gate_covers_own_takeover",
          "m.state==4" in busy_block,
          "★ 我们刚接管的这颗必为 state 4（或 allow_state3 的 2/3）⇒ 判据天然覆盖，"
          "不会出现'接管后被降频跳过'的滞后")
    check("busy_frames_seen_counter",
          "P.wframes=0" in text and "P.wframes=P.wframes+1" in text,
          "perf 窗口统计'实际跑过 tick 体的帧数'（对比 frames 看省了多少）")
    # ★★★ 2026-10-03：两档节流（用户要求：忙 1→2、空转 3→6）★★★
    print()
    print("=== ⑥b. 两档节流：忙=2 / 空转=6；否决仍每帧；敌意输入回默认 ===")
    _code6 = strip_lua_comments(text)
    check("scan_rates_read_from_env",
          "tonumber(env.scan_every_busy)" in _code6 and "tonumber(env.scan_every_idle)" in _code6,
          "★ 两档周期取自 `env`（entry 的 `scan_every_busy` / `scan_every_idle`），可调。"
          "⚠ 必须按**去注释后的代码**判：注释里也写着这两个名字，按全文判时会**空转**"
          "（变异「写死 ri=6」实测踩到）")
    check("veto_stays_every_frame",
          "veto_must=true;break" in _code6 and "veto_must and 1 or rb" in _code6,
          "★★ **否决那一路仍每帧**（`veto_must and 1 or rb` ⇒ 取 1）—— 注释写明"
          "\"否决必须每帧重申\"，节流是最容易被顺手放宽的东西 ⇒ 单列一档，"
          "不跟着 busy 降到 2")
    check("scan_rates_clamped",
          "if rb<1 then rb=2 end" in text and "if ri<1 then ri=6 end" in text,
          "★ 非数 / 0 / 负数 ⇒ 回默认。**负数最危险**：会让 `frame%N` 恒为 0 ⇒ 每帧 return "
          "⇒ mod 永远不跑（静默整体失效）")
    # entry 侧的默认值也必须钉住（否则改了 entry 而 runtime 的兜底不变 ⇒ 静默不同步）
    check("scan_rate_defaults_in_entry_and_passthrough",
          "scan_every_busy=2,scan_every_idle=6," in e
          and "scan_every_busy=state.scan_every_busy,scan_every_idle=state.scan_every_idle," in e
          and ";scan_every_busy=" in e and ";scan_every_idle=" in e,
          "★ entry 默认 = 用户指定的 **2 / 6**，且**透传到 env**、**打进状态行**"
          "（三处齐全；看不到 = 无法确认，本工程老毛病）")

    # 真的求值：把这段源码抽出来，喂敌意输入
    _a = text.index("local rb=math.floor(tonumber(env.scan_every_busy)")
    _b = text.index("\n", text.index("P.idle_skip=", _a))
    _tail = text[_a:_b]
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
    local P={}
    function probe(busy,veto,eb,ei)
        local busy,veto_must=busy,veto
        local env={scan_every_busy=eb,scan_every_idle=ei}
    """ + _tail + """
        return P.idle_skip
    end
    """)

    def lua(x):
        if isinstance(x, bool):
            return "true" if x else "false"
        if isinstance(x, str):
            return "'%s'" % x
        return "nil" if x is None else str(x)

    cases = [
        ((False, False, None, None), 6, "缺省空转 ⇒ 6"),
        ((True, False, None, None), 2, "缺省忙时 ⇒ 2"),
        ((True, True, None, None), 1, "否决 ⇒ 1（**不**跟着降到 2）"),
        ((False, False, -5, 8), 8, "忙档负数 ⇒ 回默认（空转档仍按配置 8）"),
        ((False, False, 0, 0), 6, "0 ⇒ 回默认（0 本身安全：闸门 `>0` 会短路）"),
        ((False, False, 2.9, "abc"), 6, "非数/小数 ⇒ 回默认"),
        ((True, False, 3, None), 3, "忙档可配（读 env）"),
        ((False, False, None, 12), 12, "空转档可配（读 env）"),
    ]
    for _i, (args, want, why) in enumerate(cases):
        got = rt.eval("probe(%s)" % ",".join(lua(a) for a in args))
        check("scan_rate_case_%d" % _i,
              got == want and got >= 1,
              f"{why} —— 实测 {got}（且恒 ≥1 ⇒ 不会出现 `frame%N` 恒 0）")

    check("frames_seen_incremented_after_pcall",
          text.index("P.wframes=P.wframes+1") > text.index("if not ok then"),
          "★ 帧计数在 pcall **之后** ⇒ 提前 return / 抛错的帧也算'跑过了'")

    print()
    print("=== ⑦ ★★ 禁止进程内计时器（2026-10-02 实机崩溃：ffi.cdef 污染全局 C 命名空间）★★ ===")
    code = strip_lua_comments(text)
    check("runtime_never_cdefs",
          "ffi.cdef" not in code,
          "★ 代码层绝不许出现 `ffi.cdef` —— 它写的是**整个 Lua 状态共享**的 C 命名空间；"
          "与其他 mod 的签名冲突时会让**对方**在 lua51 里访问违例（本机两次转储 "
          "`AV @ lua51.dll+0x4a050`）")
    check("runtime_no_ffi_load",
          "ffi.load" not in code and "require('ffi')" not in code
          and 'require("ffi")' not in code,
          "★ 不加载新的 C 库（runtime 自身不 require ffi）")
    check("no_wall_clock_fields",
          "us_tick" not in code and "us_cap" not in code and "us_search" not in code
          and "QueryPerformanceCounter" not in code,
          "★ 不得残留任何进程内计时字段/调用（撤销要彻底，不能只停用）")
    check("crash_lesson_documented",
          "ffi.cdef" in text and "lua51" in text and "mod_lag_finder" in text,
          "★ 事故与**替代方案**（看第三方 mod_lag_finder.log）写进代码注释 —— 后人不要再试")
    check("ffi_consumers_are_not_definers",
          "ffi.new(" in code or "ffi.cast(" in code,
          "（知情）early_nav_probe 的只读探测用 ffi.new/cast **消费**内置类型、不做 cdef "
          "—— 与崩溃根因性质不同，保留（本断言只记录这一点，不强制它存在）")

    print()
    print("=== ⑤ 泰坦/弱点到达判定 = 圆柱（2026-09-30 球形试过一版，实机效果差 ⇒ 已回滚）===")
    arr = (ROOT / "src" / "g60" / "arrival_policy.lua").read_text(encoding="utf-8")
    check("arrival_is_cylinder",
          "arrived=dx*dx+dy*dy<=region.radius^2" in arr
          and "and dz>=-region.depth" in arr,
          "★ region 判定是上游的圆柱（水平圆 + 高度带）")
    check("arrival_sphere_reverted",
          "dx*dx+dy*dy+dz*dz<=region.radius^2" not in arr,
          "★ 球形那句必须已经不在（实测效果差 ⇒ 回滚，不是并存）")
    check("arrival_keeps_above_guard", "dz<=above" in arr,
          "`above` 仍是上方硬保护（不配时 = 上游的'必须在爆点下方或同高'）")
    ap = (ROOT / "tests" / "arrival_policy.lua").read_text(encoding="utf-8")
    check("arrival_test_covers_cylinder", "cylinder" in ap.lower() and "1.75,0,-0.8" in ap,
          "测试覆盖圆柱语义")

    print()
    if failures:
        print(f"RESULT: {checks - len(failures)} passed; {len(failures)} failed")
        print("failed: " + ", ".join(failures))
        return 1
    print(f"RESULT: ALL PASS ({checks} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
