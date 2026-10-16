"""守门：战争纵步者「引爆点固定 -1.4」（2026-10-16 用户拍板）。

用户先要求：「能否让战争纵步者的引爆点可以自行调整上下距离？」
目的（用户）：「引爆点偏高的话会打不死」⇒ 主要往**负方向**调。
上机调好后用户拍板：
  **「战争纵步者引爆点距离固定为 -1.4，移除 mod 设置里面的自定义」**

★ 本门的核心不是"文本里有这几个字"，而是**真求值**：
  把 `compat/blast_sites.lua` 真跑起来，断言那条目
  ① **真的**带 `aim_dz=-1.4`（数值，不是布尔开关）；
  ② **没有** `lift`
     （有 `lift` 会被结构爆点分支抢走 ⇒ 走成"相对原点的绝对高度" = 用户上次回退的那条路）；
  ③ 并且**整条自定义链路已删除**（state/env/菜单滑块/状态行字段都不许残留）。

⚠ 为什么"没有 lift"这条区别是本门存在的**全部理由**：
  2026-10-14「强袭虫抬高引爆点」做过一版并经用户整段回退，README 记的理由是
  `lift` 锚点 = 实体原点（地表），而原行为 = 引擎 aim + 0.25，
  **"两者差多少只能靠试"** ⇒ 用户判定「没啥收益」。
  ⇒ `aim_dz`（相对**引擎瞄点**）之所以成立，正因为 **0 就是已知答案**。
  若哪天有人把这条目改成 `lift=`，本门必须红 —— 那等于把回退过的做法又搬回来。

⚠ 为什么还要钉"自定义链路已删"：用户明确要求**移除**菜单里的自定义。只删菜单项
  而留着 `state.unit_blast_dz` / `env.unit_blast_dz`，就会出现"改菜单无效"或
  "两个来源打架"（值到底听谁的）—— 本工程老毛病"同一个判断两处"。要么全留、要么全删。
"""
import pathlib
import re
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / "src" / "g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
ENTRY = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
SITES_SRC = (ROOT / "compat" / "blast_sites.lua").read_text(encoding="utf-8")
MENU = (ROOT / "src" / "g60" / "menu_text.lua").read_text(encoding="utf-8")

STRIDER = "ef570293245a17c2"
FIXED_DZ = -1.4
failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


def code_only(src):
    """去掉 Lua 注释 —— 断言"没有 X"时必须只看**代码**，否则注释里的说明会误报。"""
    out = []
    for l in src.split("\n"):
        s = l.lstrip()
        if s.startswith("--"):
            continue
        if "--" in l:
            l = l[:l.index("--")]
        out.append(l)
    return "\n".join(out)


print("=== ① 真求值：条目形状（这一条是本门的全部理由）===")
lua = lj.LuaRuntime(unpack_returned_tuples=True)
sites = lua.execute(SITES_SRC)


def _ls(x):
    return x.decode("utf-8", "replace") if isinstance(x, (bytes, bytearray)) else str(x)


def _lookup(t, name):
    for k in t.keys():
        if _ls(k) == name:
            return t[k]
    return None


keys = [_ls(k) for k in sites.keys()]
check("strider_entry_present", STRIDER in keys,
      "战争纵步者在名册里（否则 runtime 查不到 ⇒ 功能静默不生效）")

site = _lookup(sites, STRIDER)
sk = [_ls(k) for k in site.keys()] if hasattr(site, "keys") else []
check("strider_has_aim_dz_flag", "aim_dz" in sk,
      "★ 必须带 `aim_dz`（「相对引擎瞄点」机制）")
_dz = _lookup(site, "aim_dz")
check("strider_aim_dz_is_the_fixed_number", isinstance(_dz, float) and abs(_dz - FIXED_DZ) < 1e-9,
      f"★★★ `aim_dz` 必须是**数值 {FIXED_DZ}**（用户拍板的定值），"
      f"不是布尔开关 —— 实际 {_dz!r}。开关形态就得再有第二个来源 ⇒ 又一处漂移")
check("strider_has_no_lift", "lift" not in sk,
      "★★★ 必须**没有** `lift` —— runtime 的结构爆点分支是 "
      "`if site and type(site.lift)=='number'`，有 lift 就会被它抢走 ⇒ "
      "走成「相对实体原点的高度」 = **2026-10-14 被用户整段回退过的那条路**")
check("strider_aim_dz_not_positive_zero_trap",
      isinstance(_dz, float) and _dz < 0,
      "★ 必须是**负值**（用户要的方向 = 往下）；若变成 0 就等于功能被静默改回"
      "「与改动前一样」，而用户已明确要求下移 1.4 m")
reg = _lookup(site, "region")
rk = [_ls(x) for x in reg.keys()] if hasattr(reg, "keys") else []
check("strider_has_region", {"radius", "depth", "above"} <= set(rk),
      "带专用到达区域（radius/depth/above）")
if {"radius", "depth", "above"} <= set(rk):
    r = {k: float(_lookup(reg, k)) for k in ("radius", "depth", "above")}
    check("strider_region_is_tight", r["radius"] < 3.0 and r["above"] < 2.0,
          f"★★ 区域必须**收紧**：宽松值实测会让爆心自己上浮 1.4~1.9 m，"
          f"而用户这次要的正是精确控制上下 ⇒ 自己会浮的区域等于把 dz 搅掉。实际 {r}")
    check("strider_region_within_policy_bounds",
          r["radius"] <= 3.0 and r["depth"] <= 2.0 and r["above"] <= 2.0,
          f"region 必须在 arrival_policy 断言范围内。实际 {r}")

print()
print("=== ② runtime：机制真的接上了（不是只加了配置）===")
check("rt_reads_aim_dz_roster", "usite.aim_dz" in RT,
      "runtime 判据读名册的 `aim_dz`（不是把哈希抄进代码）")
check("rt_calls_native_aim",
      "scope.calls.aim(out,pair,ownb)" in RT.replace(" ", ""),
      "★★ 用引擎**自己的** `aim` 拿锚点（与 native_arrival 实体路径同一个函数）"
      "—— 锚点必须是引擎瞄点，否则 0 就不等于「改动前的行为」")
check("rt_applies_dz_to_point", "off[3]+aim_base+dz" in RT.replace(" ", ""),
      "★ 偏移作用在**竖直**分量上（用户要的是上下）")
check("rt_offset_is_cached_per_grenade", "P.adz[m.id]=" in RT.replace(" ", ""),
      "★★ 偏移按**手雷**缓存（写点后引擎看不到实体 ⇒ aim 会间歇失效；"
      "只用「能算出来的那几帧」会变成断续驱动、收敛不了）")
check("rt_repoints_from_live_motion", "off[1],off[2]" in RT and "p2[1]+off[1]" in RT.replace(" ", ""),
      "★ 每帧用**实时** motion 位置 + 偏移重新落点（点跟着目标走，不是钉死的坐标）")
check("rt_reuses_existing_write_path", "blast_point=" in RT and "blast_site=usite" in RT,
      "复用既有的 `point_target` 写路径（不新增写内存途径）")
check("rt_covers_aim_dz_site_even_when_lift_absent",
      "local usite=site" in RT,
      "⚠ 新分支挂在 `local site=…` 之后 ⇒ 没有 lift 的条目也能被它取用")
check("rt_does_not_read_env_slider",
      "env.unit_blast_dz" not in code_only(RT),
      "★★★ runtime **不得**再读 `env.unit_blast_dz` —— 值只有一个来源（名册）；"
      "留着这个引用就等于还有第二个来源，改名册不生效 / 两者打架")

print()
print("=== ②b ★★★ 基线 0.25：`aim_dz=0` 必须**真的**等于改动前的行为 ★★★ ===")
# 为什么单独一组：锚点是「相对引擎瞄准点」，但**改动前的高度并不是 aim 本身** ——
#   `native_arrival:141` 那句 `goal[3]=goal[3]+0.25` 才是改动前用来引爆的点。
# ⚠ 第一版漏了它 ⇒ `dz=0` 会比起改动前低 0.25 m，而文案写着「0 = 与改动前完全一样」
#   ⇒ 用户会拿到一个自己没要求的静默改动。这类"文案与行为不一致"是本工程最忌讳的。
ARR = (ROOT / "src" / "g60" / "native_arrival.lua").read_text(encoding="utf-8")
check("arrival_entity_path_still_adds_025",
      "goal[3]=goal[3]+0.25" in ARR.replace(" ", ""),
      "★ 安全层里那句 `+0.25` 仍在上游原样（它是「改动前的高度」的定义）—— "
      "⚠ 它**不在** SAFETY_ANCHORS 里，所以没有别的门看着它；本门补上这一眼")
check("rt_adds_the_same_025_baseline",
      "local aim_base=0.25" in RT,
      "★★★ runtime 必须补上**同一个** 0.25 作为基线 ⇒ `aim_dz=0` 才精确等于改动前")
check("rt_point_uses_baseline_and_dz",
      "off[3]+aim_base+dz" in RT.replace(" ", ""),
      "★★ 落点 = 实时 motion + 偏移 + **0.25 基线** + dz（三项都必须在，缺一项就偏）")
check("rt_does_not_double_count_025",
      "goal={want_point[1],want_point[2],want_point[3]}" in ARR.replace(" ", ""),
      "★★ 点目标路径**不加** 0.25（`goal=want_point` 直接赋值）⇒ "
      "基线必须由我们补 —— 两边同时加就是双重叠加 0.5 m")
check("diag_reports_the_baseline", "';base=%.2f" in RT,
      "★ 取证行把 `base=` 也打出来 ⇒ 上机一眼能看出基线是多少（不靠猜）")
check("diag_reports_the_effective_dz", ";dz=%.2f" in RT.replace(" ", ""),
      "★★ 取证行必须打出**实际生效的 dz**（现在 = -1.40）⇒ 上机可核对"
      "「固定值真的被用上了」，而不是只看代码")

print()
print("=== ③ 用户要求：**移除 mod 设置里的自定义**（整条链路不许残留）===")
check("no_state_field", "unit_blast_dz=0," not in ENTRY,
      "★★ `state.unit_blast_dz` 已删除（值改由名册给）")
check("no_env_wiring", "unit_blast_dz=state.unit_blast_dz," not in ENTRY,
      "★★ `env.unit_blast_dz` 的接线已删除 —— 留着就是第二个来源")
check("no_menu_item", "id='g60.unit_blast_dz'" not in ENTRY,
      "★★★ 菜单滑块**必须移除**（用户原话：「移除 mod 设置里面的自定义」）")
no_menu_key = not re.search(r"{id='g60\.unit_blast_dz'", ENTRY)
check("menu_item_fully_gone", no_menu_key and "key='unit_blast_dz'" not in ENTRY,
      "★ 菜单项与它的 `key=` 都不许残留（只删一半会留下永远读不到的孤儿配置）")
check("no_status_line_field", "';unit_blast_dz='..tostring" not in ENTRY,
      "★ 状态行的 `;unit_blast_dz=` 已删除（它引用的 state 字段已不存在 ⇒ 会变成 nil）")
check("no_menu_text", "['unit_blast_dz.label']" not in MENU
      and "['unit_blast_dz.desc']" not in MENU,
      "★★ 中英文案都必须删干净（`test_menu_language.py` 要求文案只有一处来源；"
      "留下孤儿 key 会让将来的人以为还有这个设置）")
check("no_stale_env_reference_anywhere",
      "unit_blast_dz" not in code_only(ENTRY) and "unit_blast_dz" not in code_only(RT),
      "★★★ 整个代码路径里不许再出现 `unit_blast_dz`（任何一处残留都可能是"
      "「读一个不存在的值」⇒ 静默 nil）")
check("diag_whitelisted",
      "line:match('^unit_blast;')" in ENTRY and "line:match('^unit_aim_failed;')" in ENTRY,
      "★★ 两条取证行必须留在**节流白名单**：`unit_blast;`（偏移真生效）/ "
      "`unit_aim_failed;`（瞄点拿不到 —— 必须可见，否则功能静默）")
check("diag_line_per_grenade_once", "P.abz[m.id]" in RT,
      "★ 取证行按手雷**只打一次**（既不刷屏、也不静默）")

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
