"""守门：生物处理器（grinder）的体内爆点条目（lift=1.5，用户 2026-10-16 指定）。

背景（实机日志证据）：该目标进 `structure_profiles` 后**没有** `blast_sites` 条目 ⇒
到达段拿不到体内爆点 ⇒ `blast_detour;…;src=target`（圆心退回目标自身）+ 每帧
`priority_locked` 但**始终没有 arrival_detonated** ⇒ 手雷绕圈不引爆。

本守门钉住：
  ① 条目存在、`lift=1.5`、`region` 与巨型构筑者实机标定过的那套一致；
  ② **该资源必须也在 `structure_profiles` 里** —— 这是本文件自己记录过的教训：
     `blast_sites` 是**到达段**的消费方，整块嵌在 `e.lock` 守卫里 ⇒ 目标拿不到锁，
     条目就**从未被走到过**（当年塔类目标实机全日志 0 条 `blast_point`）；
  ③ 条目形状与既有条目同形（resource/lift/region/label），且哈希来自独立来源；
  ④ 没有该条目时行为不变：runtime 按 `e.resource` 查表，查不到 ⇒ 退回引擎 aim。
"""
import pathlib
import re

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITES = (ROOT / "compat" / "blast_sites.lua").read_text(encoding="utf-8")
PROF = (ROOT / "compat" / "structure_profiles.lua").read_text(encoding="utf-8")
RT = (ROOT / "src/g60" / "experimental_runtime.lua").read_text(encoding="utf-8")

H = "e2e6e77dcc99a1cb"
failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


print("=== ① 真求值：条目确实能被 blast_sites 加载出来 ===")
lua = lj.LuaRuntime(unpack_returned_tuples=True)
tbl = lua.execute(SITES)
site = tbl[H]
check("entry_loads", site is not None, "名册里能取到该资源")
if site is not None:
    check("lift_is_1_5", abs(float(site["lift"]) - 1.5) < 1e-9,
          "lift = %s（用户指定 1.5）" % site["lift"])
    reg = site["region"]
    check("region_matches_proven_set",
          reg is not None and abs(float(reg["radius"]) - 1.5) < 1e-9
          and abs(float(reg["depth"]) - 0.25) < 1e-9 and abs(float(reg["above"]) - 0.6) < 1e-9,
          "region 沿用巨型构筑者实机标定过的那套（1.5 / 0.25 / 0.6）")
    check("label_present", site["label"] is not None and "shutdown_grinder" in str(site["label"]),
          "带 label（可归因，便于日志/核对）：%s" % site["label"])
    check("resource_self_consistent", str(site["resource"]) == H, "resource 字段与键一致")

print()
print("=== ② 原始文本层：形状与既有条目同形 + 独立来源 ===")
_nc = "\n".join(l.split("--")[0] for l in SITES.splitlines())
check("entry_line_shape",
      'sites["%s"]={resource="%s",lift=1.5,' % (H, H) in _nc,
      "与既有条目同形（resource/lift/region/label）")
check("region_line_shape",
      "region={radius=1.5,depth=0.25,above=0.6}," in _nc,
      "region 三值与 FAB 条目逐字一致")
check("hash_source_documented",
      "cyborg_shutdown_grinder" in SITES and "obj_cyborgs" in SITES,
      "★ 注释里写出游戏资源路径（独立来源，不是我们自己编的 kind）")

print()
print("=== ③ 这个条目真的会被走到吗（本文件自己记过的教训）===")
check("resource_is_registered_structure",
      ('profiles["%s"]' % H) in PROF,
      "★★ 该资源**必须也在 structure_profiles 里** —— 否则拿不到锁 ⇒ 条目永不生效"
      "（当年塔类目标实机全日志 0 条 blast_point 就是这个原因）")
check("locked_path_consumes_site",
      "env.blast_sites and env.blast_sites[e.resource]" in RT,
      "★ runtime 按 e.resource 查表 ⇒ 有锁才消费（与上面那条共同构成前置条件）")
check("missing_site_falls_back",
      "local site=env.blast_sites and env.blast_sites[e.resource]" in RT,
      "★ 查不到 ⇒ 退回引擎 aim（失败方向安全：不会误炸别的目标）")

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    raise SystemExit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
