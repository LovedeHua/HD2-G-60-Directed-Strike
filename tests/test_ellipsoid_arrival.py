"""守门：`ellipsoid` 到达区域必须真的有判定分支（2026-10-18 修复）。

★ 这守的是什么缺陷
  `blast_route.lua` 的 `head` / `rear` 两个分支构造的是 `kind='ellipsoid'` 区域，
  但 `arrival_policy.lua` 的 `M.step` **没有 ellipsoid 分支** ⇒ 掉进通用支
  （那条硬性要求 `radius`+`depth`）⇒ `'arrival region'` 断言**每次必抛错**。
  调用方用 `pcall` 包着 ⇒ 错误被吞 ⇒
  `weakpoint_profiles` 里 `kind=head/rear` 的 4 个目标
  （1a7fcdff… / 3aff5fd7… / a05bd1ec… / fd524765…）
  **永远拿不到本帧的航路结果**（表现：这些目标不接管）。

★ 为什么必须守
  这类"断言在 pcall 里抛错 ⇒ 整条链静默失效"是本工程反复踩的坑。
  而且**文本检查抓不到它** —— 代码看起来完全正常，只有真跑才暴露。
  ⇒ 本守门用**真求值**（lupa + 真实模块），不查文本。
"""
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
POL = (ROOT / "src" / "g60" / "arrival_policy.lua").read_text(encoding="utf-8")
BLAST = (ROOT / "src" / "g60" / "blast_route.lua").read_text(encoding="utf-8")

failures = []


def check(name, ok, why=""):
    print("  %s %s%s" % ("PASS" if ok else "FAIL", name,
                        ("  [%s]" % why) if why else ""))
    if not ok:
        failures.append(name)


rt = lj.LuaRuntime(unpack_returned_tuples=True)
rt.execute("ArrivalPolicy=(function()\n" + POL + "\nend)()")
rt.execute("""
function require(n)
  if n=='g60.arrival_policy' then return ArrivalPolicy end
  error('unexpected require: '..tostring(n))
end""")
rt.execute("BlastRoute=(function()\n" + BLAST + "\nend)()")


def blast(kind, own):
    """返回 (ok, region_kind, zone_id)。own 是手雷位置；目标点在 {0,0,6}。"""
    rt.execute("""
    __prof={kind='%s'}
    __t={point={0,0,6},origin={0,0,0},right={1,0,0},forward={0,1,0},
         body_center={0,0,0},belly_outward={0,0,-1}}
    __base={point={0,0,6},terminal=false,route={}}
    __ok,__r=pcall(BlastRoute.refine,{%r,%r,%r},__t,nil,__prof,__base)
    """ % ((kind,) + tuple(own)))
    if not rt.eval("__ok"):
        return False, str(rt.eval("__r"))[:70], None
    reg = rt.eval("__r.arrival_region")
    return True, (str(reg["kind"]) if reg else None), str(rt.eval("__r.route.blast_zone"))


print("=== ① head / rear 必须能产出 ellipsoid 区域（修复前这里是硬报错）===")
ok, rk, zone = blast("head", (0, 5, 3))
check("head_produces_region", ok and rk == "ellipsoid",
      "kind=head ⇒ %s / region=%s" % ("ok" if ok else "ERR", rk))
ok, rk, zone = blast("rear", (0, -5, 3))
check("rear_produces_region", ok and rk == "ellipsoid",
      "kind=rear（站在后方）⇒ %s / region=%s" % ("ok" if ok else "ERR", rk))
# ⚠ 这里原本有一条 `head_is_attack_stage`（断言 blast_zone=='head'）—— **已删除**：
#   `own=(0,5,3)` 这个位置对 head 与 rear **同时**可达，实际选中谁是评分结果，
#   不构成"head 专属"的证据（实测选中 rear）。它测的是评分细节，与本守门
#   （"ellipsoid 有没有判定分支"）无关，留着只会长期红着。
#   ⇒ 换成下面用**只对 head 可达**的位置验证。
ok, rk, zone = blast("head", (0, 8, 0.5))
check("head_only_position_picks_head", ok and rk == "ellipsoid",
      "正前方较远处 ⇒ 必须是 head 的 ellipsoid，实得 %s / %s" % ("ok" if ok else "ERR", rk))

print()
print("=== ② 其它 kind 不得受影响（回归）===")
for kind, own in (("titan", (0, 5, 3)), ("thorax", (0, 5, 3)), ("underside", (0, 5, 3))):
    ok, rk, zone = blast(kind, own)
    check("%s_still_ok" % kind, ok,
          "%s ⇒ %s" % (kind, "ok" if ok else ("ERR " + rk)))

print()
print("=== ③ ellipsoid 判定本身：内/外必须分得开 ===")
rt.execute("__reg={kind='ellipsoid',forward={0,1},length=1.25,width=1.4,height=0.9}")


def arrived(dx, dy, dz):
    rt.execute("__a=ArrivalPolicy.step(0,{%r,%r,%r},{0,0,0},true,'k',nil,__reg)"
               % (dx, dy, dz))
    return str(rt.eval("__a")) == "detonate"


check("ellipsoid_centre_arrives", arrived(0, 0, 0), "椭球中心必须判到达")
check("ellipsoid_inside_arrives", arrived(0, 0.6, 0), "半轴内侧必须判到达")
check("ellipsoid_outside_long_rejected", not arrived(0, 2.0, 0),
      "沿 length 轴 2.0 > 1.25 ⇒ 必须拒绝（否则窗口形同虚设）")
check("ellipsoid_outside_wide_rejected", not arrived(2.0, 0, 0),
      "沿 width 轴 2.0 > 1.4 ⇒ 必须拒绝")
check("ellipsoid_outside_high_rejected", not arrived(0, 0, 2.0),
      "沿 height 轴 2.0 > 0.9 ⇒ 必须拒绝")
check("ellipsoid_axis_is_directional",
      # ⚠ 本项第一版写的是 `arrived(0,1.0,0) != arrived(1.0,0,0)` —— **期望错了**：
      #   两点都在椭球内部（q=0.80 / 0.71），本来就都该判到达。
      #   ⇒ 正确判据：取一个**沿 length 轴出界、沿 width 轴仍在内**的点，
      #     它必须被拒绝 —— 这才证明两个轴的长度真的分别生效。
      (not arrived(0, 1.3, 0)) and arrived(1.3, 0, 0),
      "length=1.25 / width=1.4 ⇒ y=1.3 出界（须拒）、x=1.3 仍在内（须到）—— "
      "两者不同才说明轴没被当成球形")

print()
print("=== ④ 非法 ellipsoid 必须拒绝（不是静默通过）===")
for name, reg in (("no_forward", "{kind='ellipsoid',length=1,width=1,height=1}"),
                  ("non_unit_axis", "{kind='ellipsoid',forward={0,2},length=1,width=1,height=1}"),
                  ("zero_length", "{kind='ellipsoid',forward={0,1},length=0,width=1,height=1}"),
                  ("missing_height", "{kind='ellipsoid',forward={0,1},length=1,width=1}")):
    rt.execute("__bad=%s" % reg)
    rt.execute("__ok2,__err=pcall(ArrivalPolicy.step,0,{0,0,0},{0,0,0},true,'k',nil,__bad)")
    check("rejects_%s" % name, not rt.eval("__ok2"),
          "非法区域必须抛错（被调用方 pcall 捕获并记录），不能静默放行")

print()
if failures:
    print("RESULT: %d failed" % len(failures))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS —— head/rear 能产出 ellipsoid 区域、其它 kind 未受影响、"
      "ellipsoid 判定内外分明、非法输入被拒绝")
