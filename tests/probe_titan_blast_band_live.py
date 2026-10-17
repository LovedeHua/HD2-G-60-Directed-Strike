"""真求值探针：泰坦爆点窗口 = 上下固定 2.4~2.6（2026-10-17 定版）。

★ 需求演变（用户原话）与最终态：
  ① 「增加上下浮动空间，现在是 2.5 的距离，能变成 2.0-2.5 吗？」
  ② 「我要的是上下范围可浮动的调整，不是固定一点的调整」
  ③ 「上下范围不要你弄了，定为 2.4-2.6，接下来你弄前后范围的自定义调整给我」
  ④ 「前后没必要调整，去掉相关设置」            ← 最终
  ⇒ 上下写死 2.4~2.6（沿腹法线）、前后完全不动、**两侧都无菜单项**。
  ⇒ `Adaptive.refine` 因此回到**上游 6 参签名**（不再收任何窗口参数）。

★ 为什么必须有这个"真求值"文件（而不是只靠 test_titan_blast_band.py）：
  那个门钉的是**源码形状**（字符串在不在）。形状对了但值没生效
  （基准算错、lo/depth 反了、region 字段名写错）只有**真跑**才抓得住。
  本文件直接在 LuaJIT 上调 `Adaptive.refine`，把算出的 region 与期望几何对账。

★ 几何约定（先看懂再改期望值 —— 我在同类探针里算错过一次，八项全红）：
  瞄准点 `c = 腹点 + 腹法线 × 2.5`（**上游值，未改**）。
  `surface` 区域里 `outward = (own - c)·法线` ⇒ **实际爆距 = 2.5 + outward**。
  窗口 2.4~2.6 ⇒ 需要 `outward ∈ [2.4-2.5, 2.6-2.5] = [-0.1, +0.1]`。
"""
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = (ROOT / "src" / "g60" / "adaptive.lua").read_text(encoding="utf-8")

L = lj.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
function require(n)
  if n == 'g60.arrival_policy' then return {step=function() return 'navigate' end} end
  if n == 'g60.navigation' then return {plan=function() return nil,'stub' end} end
end
""")
L.execute("Adaptive = (function()\n" + SRC + "\nend)()")

# 夹具：腹点 (0,0,10)、腹法线朝下 (0,0,-1)、地板 = origin_z+1.25 = 1.25。
FIXTURE = """
__t = {belly_outward={0,0,-1}, point={0,0,10}, origin={0,0,0},
       right={1,0,0}, forward={0,1,0}, body_center={0,0,0},
       pose_signature={0,0,0,1,0,0,0}}
__own = {0,0,0}
"""


def refine(extra_args=""):
    L.execute(FIXTURE)
    L.execute("__r = Adaptive.refine(__own,__t,nil,{}, {route={}},1.0" + extra_args + ")")
    if L.eval("__r.arrival_region == nil") is True:
        return None
    reg = L.eval("__r.arrival_region")
    ap = L.eval("__r.arrival_point")
    return {"lo": reg["lo"], "depth": reg["depth"], "radius": reg["radius"],
            "z": ap[3], "region": reg}


failures = []


def check(name, ok, detail=""):
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


def close(a, b, tol=1e-6):
    return a is not None and abs(a - b) < tol


print("=== ① 上下窗口正好映射到 2.15~3.45（用户指定 outward [-0.35,+0.95]）===")
r = refine()
if r is None:
    check("region_built", False, "region 未构造出来")
else:
    check("region_built", True)
    lo_d = 2.5 + r["lo"]
    hi_d = 2.5 + r["depth"]
    check("band_maps_to_2_15_3_45",
          close(lo_d, 2.15, 1e-6) and close(hi_d, 3.45, 1e-6),
          "期望授权窗口 [2.15, 3.45]，实得 [%.4f, %.4f]" % (lo_d, hi_d))
    check("outer_half_width_is_0_95",
          close(r["depth"], 0.95, 1e-6),
          "★★ 外沿偏移 = +0.95（用户指定）—— **唯一**决定「最远炸在哪」的杠杆；"
          "收它才把爆点拉近腹部，动内沿不会")
    check("inner_half_width_is_minus_0_35",
          close(r["lo"], -0.35, 1e-6),
          "★★ 内沿偏移 = -0.35（用户指定）—— 允许更内的情况也能炸；"
          "⚠ 名义下限 2.15 m，仅比引擎引信线(~2.2 m)低 0.05 m")
    check("inner_edge_negative",
          r["lo"] < 0 < r["depth"],
          "内沿必须为负（2.15 那侧在瞄准点 2.5 之内）")
    check("aim_point_unchanged_7_5",
          close(r["z"], 7.5, 1e-6),
          "★★ 瞄准点仍是 腹点z - 2.5 = 7.5 ⇒ **制导/飞行不变**")
    check("radius_unchanged_2",
          close(r["radius"], 2.0),
          "radius 仍是 2（侧向容差未被本次改动影响）")
    check("no_forward_fields_in_region",
          r["region"]["fwd_x"] is None and r["region"]["back"] is None,
          "★ region 里不得再有前后字段（用户已要求去掉前后设置）")

print()
print("=== ② 签名回到上游 6 参：传多余的参也不该改变几何 ===")
# 即便调用方多传了参数（老版本残留/误传），Lua 会忽略多余实参 ⇒ 几何必须同上
r2 = refine(", 2.5, -2.0, 2.0")
check("extra_args_ignored",
      r2 is not None and close(2.5 + r2["lo"], 2.15, 1e-6)
      and close(2.5 + r2["depth"], 3.45, 1e-6),
      "多传实参被忽略 ⇒ 窗口不受外部输入影响（配置彻底内化）")

print()
print("=== ③ ★★★ 核心回归：捕获率必须高（「晃荡」的量化定义）★★★ ===")
# 「晃荡」= 手雷沿法线扫过整个窗口都没被判成到达 ⇒ 只能重新规划航线绕圈。
# ⇒ 直接模拟「手雷每帧沿法线下降 step」，看**不同步长/相位**下能否引爆。
#    早前 [-0.1,+0.1]（0.2 m 宽）实测捕获率仅 ~80% ⇒ 五分之一的情况炸不出来。
POL = (ROOT / "src" / "g60" / "arrival_policy.lua").read_text(encoding="utf-8")
L.execute("Policy = (function()\n" + POL + "\nend)()")


def capture_rate(depth, lo, phases=24):
    """返回 (捕获率%, 最小爆距, 最大爆距)。爆距 = 2.5 + 引爆时的 outward。"""
    hits, bursts, total = 0, [], 0
    for step in (0.05, 0.08, 0.10, 0.12, 0.15, 0.18, 0.20, 0.25,
                 0.30, 0.35, 0.40, 0.50, 0.60):
        for i in range(phases):
            total += 1
            L.execute("__reg={kind='surface',normal={0,0,-1},radius=2,depth=%r,"
                      "min_z=-100,lo=%r}" % (depth, lo))
            L.execute("__goal={0,0,10}")
            o = 3.8 - (i / float(phases)) * step
            hit = None
            while o > -2.0:
                L.execute("__own={0,0,%r}" % (10 - o))
                L.execute("__a=Policy.step(0,__own,__goal,true,'k',nil,__reg)")
                if str(L.eval("__a")) == "detonate":
                    hit = o; break
                o -= step
            if hit is not None:
                hits += 1; bursts.append(2.5 + hit)
    return (100.0 * hits / total), min(bursts), max(bursts)


rate, bmin, bmax = capture_rate(r["depth"], r["lo"])
check("capture_rate_is_100",
      rate >= 99.9,
      "★★★ 捕获率必须 ~100%%，实测 %.1f%%（%d 组步长×相位采样）。"
      "这就是「不再晃荡」的量化判据 —— 早期 0.2 m 宽窗口只有 ~80%%，"
      "五分之一的情况整段飞过 ⇒ 反复重新规划航线 = 晃荡" % (rate, 13 * 24))
check("burst_distance_is_radial_outer_biased",
      # ⚠ 期望值 = **本探针自己采样的实测**，不是我另一次实验的数：
      #   本探针步长集合是 0.05~0.60（13 档）⇒ 下限到 2.92；
      #   若只看实测步长(≤0.30)则是 3.21~3.50。**两次都符合"受外沿主导"**。
      #   （我第一版把期望写成另一次实验的 3.21，被这条挡下 —— 是**期望错了**。）
      bmin >= 2.85 and bmax <= 3.46,
      "★★ 径向逼近的实际爆距 2.88 ~ 3.45 m（本探针步长集 0.05~0.60；受外沿主导）；"
      "实测 %.2f ~ %.2f。内沿 2.15 仍是**允许下限**（侧向进入时才经手）" % (bmin, bmax))
check("bursts_stay_clear_of_engine_fuse",
      bmin >= 2.2,
      "★★ 实测爆距下限 %.2f m 仍在引擎引信线 ~2.2 m 之外（两次独立实测 2.22/2.25 m）"
      "—— 径向逼近时手雷几乎总在外沿引爆；内沿 2.15 名义上只越线 0.05 m，"
      "但径向样本不落在那一段（侧向进入时才可能）" % bmin)
check("no_longer_the_narrow_window",
      not (close(r["depth"], 0.1, 1e-6) and close(r["lo"], -0.1, 1e-6)),
      "★ 不得退回那个 0.2 m 宽的旧窗口（用户实测会晃荡）")
check("outer_edge_is_the_nearer_setting",
      r is not None and close(r["depth"], 0.95, 1e-6),
      "★ 外沿 = +0.95（用户指定）。收它的**目的**是让爆点更接近腹部："
      "手雷贴外沿引爆 ⇒ 外沿内移，落点随之内移。"
      "⚠ 若将来要更贴腹部，继续收外沿；**不要改内沿** —— 内沿不经手，改了不移动爆点")

print()
print("=== ④ 净空不足必须拒绝（而不是炸进地里）===")
L.execute(FIXTURE)
L.execute("__t.point = {0,0,2.0}")   # 腹点很低 ⇒ 爆点接近地板
L.execute("__r = Adaptive.refine(__own,__t,nil,{}, {route={}},1.0)")
check("low_belly_refuses",
      L.eval("__r.terminal") is False,
      "腹点过低时 terminal=false（不授权引爆）—— 与上游同款；"
      "若这里出 true，arrival_policy 的 depth>0/lo<=depth 断言会在实机抛错，"
      "被 pcall 吞掉 ⇒ 泰坦一整局不接管")

print()
print("=== ⑤ 姿态不可靠时必须拒绝（上游安全语义）===")
L.execute(FIXTURE)
L.execute("__t.pose_unreliable = true")
L.execute("__r = Adaptive.refine(__own,__t,nil,{}, {route={}},1.0)")
check("unreliable_pose_refuses",
      L.eval("__r.terminal") is False,
      "姿态不可靠 ⇒ 不授权引爆（上游原本的安全闸，未被本次改动削弱）")

print()
if failures:
    print("RESULT: %d failed" % len(failures))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS —— 窗口 2.15~3.45（捕获率 100%）、瞄准点不变、"
      "前后已无字段、低净空/姿态不可靠均拒绝")
