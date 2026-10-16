"""守门：战争纵步者「引爆点上下可调」（2026-10-16 用户要求）。

用户原话：「能否让战争纵步者的引爆点可以自行调整上下距离？」
目的（用户）：「引爆点偏高的话会打不死」⇒ 主要往**负方向**调。

★ 本门的核心不是"文本里有这几个字"，而是**真求值**：
  把 `compat/blast_sites.lua` 真跑起来，断言那条目**真的**带 `aim_dz` 且**没有** `lift`
  （有 `lift` 会被结构爆点分支抢走 ⇒ 走成"相对原点的绝对高度" = 用户上次回退的那条路）。

⚠ 为什么这条区别是本门存在的**全部理由**：
  2026-10-14「强袭虫抬高引爆点」做过一版并经用户整段回退，README 记的理由是
  `lift` 锚点 = 实体原点（地表），而"现状高度" = 引擎 aim + 0.25，
  **"两者差多少只能靠试"** ⇒ 用户判定「没啥收益」。
  ⇒ `aim_dz`（相对**引擎瞄点**）之所以成立，正因为 **0 就是已知答案**。
  若哪天有人把这条目改成 `lift=`，本门必须红 —— 那等于把回退过的做法又搬回来。
"""
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RT = (ROOT / "src" / "g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
ENTRY = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
SITES_SRC = (ROOT / "compat" / "blast_sites.lua").read_text(encoding="utf-8")
MENU = (ROOT / "src" / "g60" / "menu_text.lua").read_text(encoding="utf-8")

STRIDER = "ef570293245a17c2"
failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


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
check("strider_has_aim_dz_flag", "aim_dz" in sk and _lookup(site, "aim_dz") is True,
      "★ 必须带 `aim_dz=true`（新的「相对引擎瞄点」机制）")
check("strider_has_no_lift", "lift" not in sk,
      "★★★ 必须**没有** `lift` —— runtime 的结构爆点分支是 "
      "`if site and type(site.lift)=='number'`，有 lift 就会被它抢走 ⇒ "
      "走成「相对实体原点的高度」 = **2026-10-14 被用户整段回退过的那条路**")
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
      "scope.calls.aim(out,pair,ownb)" in RT.replace(" ", "").replace("scope.calls.aim(out,pair,ownb)", "scope.calls.aim(out,pair,ownb)")
      or "calls.aim(out,pair" in RT.replace(" ", ""),
      "★★ 用引擎**自己的** `aim` 拿锚点（与 native_arrival 实体路径同一个函数）"
      "—— 锚点必须是引擎瞄点，否则 0 就不等于「今天的行为」")
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

print()
print("=== ②b ★★★ 基线 0.25：`dz=0` 必须**真的**等于今天的行为 ★★★ ===")
# 为什么单独一组：用户选的锚点是「相对引擎瞄准点」，但**今天的高度并不是 aim 本身** ——
#   `native_arrival:141` 那句 `goal[3]=goal[3]+0.25` 才是今天用来引爆的点。
# ⚠ 我第一版漏了它 ⇒ `dz=0` 会比现状低 0.25 m，而文案写着「0 = 与改动前完全一样」
#   ⇒ 用户会拿到一个自己没要求的静默改动。这类"文案与行为不一致"是本工程最忌讳的。
ARR = (ROOT / "src" / "g60" / "native_arrival.lua").read_text(encoding="utf-8")
check("arrival_entity_path_still_adds_025",
      "goal[3]=goal[3]+0.25" in ARR.replace(" ", ""),
      "★ 安全层里那句 `+0.25` 仍在上游原样（它是「今天的高度」的定义）—— "
      "⚠ 它**不在** SAFETY_ANCHORS 里，所以没有别的门看着它；本门补上这一眼")
check("rt_adds_the_same_025_baseline",
      "local aim_base=0.25" in RT,
      "★★★ runtime 必须补上**同一个** 0.25 作为基线 ⇒ `dz=0` 才精确等于今天的行为")
check("rt_point_uses_baseline_and_dz",
      "off[3]+aim_base+dz" in RT.replace(" ", ""),
      "★★ 落点 = 实时 motion + 偏移 + **0.25 基线** + dz（三项都必须在，缺一项就偏）")
check("rt_does_not_double_count_025",
      "goal={want_point[1],want_point[2],want_point[3]}" in ARR.replace(" ", ""),
      "★★ 点目标路径**不加** 0.25（`goal=want_point` 直接赋值）⇒ "
      "基线必须由我们补 —— 两边同时加就是双重叠加 0.5 m")
check("diag_reports_the_baseline", "';base=%.2f" in RT,
      "★ 取证行把 `base=` 也打出来 ⇒ 上机一眼能看出基线是多少（不靠猜）")

print()
print("=== ③ 三处齐全（配置 / 透传 / 菜单）+ 取证可见 ===")
check("state_default_is_zero", "unit_blast_dz=0," in ENTRY,
      "★ state 默认 **0 = 与改动前完全一致**（装上就能对照，不是「默认就改了行为」）")
check("env_wired", "unit_blast_dz=state.unit_blast_dz," in ENTRY,
      "★ 必须接进 env —— 本项目栽过「写进 state 却没进 env ⇒ 功能静默不生效、门却是绿的」")
check("menu_item_registered",
      "id='g60.unit_blast_dz'" in ENTRY and "kind='slider'" in ENTRY,
      "★ 注册成**滑块**（用户要「自行调整」）；本宿主实机证明接受 slider"
      "（`menu_restore` 14 项、其中 8 项滑块值都回读成功）")
check("menu_bounds_are_sane",
      "min=-3,max=3,step=0.1" in ENTRY,
      "★ 范围 ±3 m / 步长 0.1：够细且不超出 4 m 内半径的意义（再大就没意义了）")
check("status_line_visible", "';unit_blast_dz='..tostring(state.unit_blast_dz)" in ENTRY,
      "★★ 状态行必须能看到它 —— 这是用户要在游戏里反复试的量"
      "（「看不到 = 无法确认」，本工程老毛病）")
check("diag_whitelisted",
      "line:match('^unit_blast;')" in ENTRY and "line:match('^unit_aim_failed;')" in ENTRY,
      "★★ 两条取证行必须进**节流白名单**：`unit_blast;`（偏移真生效）/ "
      "`unit_aim_failed;`（瞄点拿不到 —— 必须可见，否则功能静默）")
check("diag_line_per_grenade_once", "P.abz[m.id]" in RT,
      "★ 取证行按手雷**只打一次**（既不刷屏、也不静默）")
check("menu_text_bilingual",
      MENU.count("['unit_blast_dz.label']") == 2 and MENU.count("['unit_blast_dz.desc']") == 2,
      "中英文案各一份（本项目要求菜单跟随游戏语言）")
check("menu_text_names_the_anchor",
      "引擎已经瞄的那个点" in MENU or "engine already aims" in MENU,
      "★★ 文案必须写清锚点是**引擎瞄点（+0.25）** —— 否则用户会以为 0 = 贴地"
      "（这正是上次回退的误解来源）")
check("menu_text_states_zero_is_unchanged",
      "0 = 与改动前完全一样" in MENU and "0 = unchanged" in MENU,
      "★★ 「0 = 不变」必须写进文案：用户是靠这句话判断「我什么都不改会不会改变现状」的")

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
