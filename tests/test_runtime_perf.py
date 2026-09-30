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
    for fld in (";ready=", ";observe=", ";layout_reads=", ";layout_bytes="):
        check("perf_has" + fld.replace(";", "_").rstrip("="), fld in text,
              f"perf 行含 {fld[1:]}")
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
    _i_idle = text.index("P.idle_skip=(#observed.matches>0) and 0 or 3")
    check("idle_state_set_from_observation", _i_lc2 < _i_idle < _i_lc2 + 400,
          "★ 降频状态由**真实观测**决定（有 G-60 ⇒ 0 恢复每帧；没有 ⇒ 隔 3 帧）")

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
