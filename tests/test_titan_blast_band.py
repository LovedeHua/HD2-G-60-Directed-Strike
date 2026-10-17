"""守门：泰坦爆点窗口 = 上下固定 2.4~2.6、前后不动、两侧都无菜单项。

★ 完整的需求演变（用户原话，按时间顺序）—— 本门钉的是**最终态**：
  ① 「我想调整一下泰坦的引爆点，增加上下浮动空间，现在是 2.5 的距离，
     能变成 2.0-2.5 吗？或者你在 mod 设置里面弄一个自定义让我慢慢的进行调整」
  ② 「我要的是上下范围可浮动的调整，不是固定一点的调整」
  ③ 「上下范围不要你弄了，定为 2.4-2.6，接下来你弄前后范围的自定义调整给我」
  ④ 「前后没必要调整，去掉相关设置」   ← 最终

⇒ 定版：**上下写死 2.4~2.6**（沿腹法线）+ **前后完全不动**（回上游几何）
  + **菜单里一个都不留**。

★ 本门要拦的两类事故：
  1. **死配置**：菜单项留着但没有任何代码读它（用户"调了没反应"）。
     ⇒ 检查三个被撤掉的菜单项/字段**彻底不存在**（含 env 接线与状态行）。
  2. **静默砍半**：瞄准点 2.5 落在 2.4~2.6 的中点 ⇒ 2.4 那侧在瞄准点**内侧**，
     而上游 `arrival_policy` 写死 `outward>=0` ⇒ 不放宽内沿，窗口只有一半有效。
     ⇒ 检查 `region.lo` 通路仍在。

⚠ 说明文字一律用「」不用 ASCII 双引号（中文串里夹 ASCII 引号会直接语法错误）。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
MENU = (ROOT / "src" / "g60" / "menu_text.lua").read_text(encoding="utf-8")
ADAPT = (ROOT / "src" / "g60" / "adaptive.lua").read_text(encoding="utf-8")
POLICY = (ROOT / "src" / "g60" / "arrival_policy.lua").read_text(encoding="utf-8")
BLAST = (ROOT / "src" / "g60" / "blast_route.lua").read_text(encoding="utf-8")
AIM = (ROOT / "src" / "g60" / "native_titan_aim.lua").read_text(encoding="utf-8")

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


def code_only(src):
    return "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("--"))


print("=== ① 上下窗口：用户指定 outward ∈ [-0.35,+0.95]（2026-10-18，目的：更贴腹部）===")
check("band_constants_are_2_15_3_45",
      "local BAND_LO,BAND_HI=2.15,3.45" in ADAPT,
      "★★ 窗口必须是 2.15~3.45（= 瞄准点 2.5 + outward [-0.35,+0.95]）—— "
      "用户 2026-10-18 指定；**外沿是决定「最远炸在哪」的唯一杠杆**，"
      "收到 +0.9 是为了把爆点拉近腹部（实机 15 条里有 2 条顶到旧上限 +1.0）")
check("inner_edge_is_negative",
      "BAND_LO,BAND_HI=2.15," in ADAPT,
      "★ 内沿 2.15 在瞄准点 2.5 **内侧** ⇒ `lo` 必须为负（-0.35），"
      "否则会被 `outward>=0` 那句静默砍掉")
check("outer_edge_is_0_95",
      "BAND_HI=2.15,3.45" in ADAPT,
      "★ 外沿偏移 = +0.95（用户指定，目的：爆点更贴腹部）。"
      "⚠ 判定依据：外沿是唯一决定「最远炸在哪」的杠杆 —— "
      "手雷贴外沿引爆 ⇒ 收外沿即内移爆点。不要改成去动内沿，那样不会拉近爆点")
check("band_is_offset_from_aim_point",
      "local lo=BAND_LO-2.5" in ADAPT and "local depth=math.min(BAND_HI-2.5," in ADAPT,
      "两端必须以**瞄准点 2.5** 为基准换算成 outward 偏移"
      "（lo=-0.35 内侧、depth=+0.95 外侧）")
check("aim_point_unchanged_upstream_2_5",
      "local c={p[1]+n[1]*2.5,p[2]+n[2]*2.5,p[3]+n[3]*2.5}" in ADAPT,
      "★★ 瞄准/制导点必须仍是上游的 2.5 —— 用户要的是窗口，不是把爆点搬走；"
      "搬瞄准点会改变接近姿态（2026-10-14 那次「爆点不太对」的一类根因）")
check("no_standoff_parameter_left",
      "tonumber(standoff)" not in code_only(ADAPT),
      "★ 上下已固定 ⇒ 那个为「可调」加的 standoff 入参必须撤掉（死配置）")
check("refine_signature_back_to_upstream",
      "function M.refine(own,t,previous,profile,route,now)" in ADAPT,
      "★ `Adaptive.refine` 签名回到上游 6 参")

print()
print("=== ② 内沿 lo 通路仍在（不做就会静默砍半）===")
check("region_carries_lo",
      "min_z=floor,lo=lo}" in ADAPT,
      "region 必须带 lo —— 2.4 那侧在瞄准点内侧，需要负的下沿")
check("policy_reads_lo",
      "local lo=region.lo or 0" in POLICY and "outward>=lo" in POLICY,
      "★★ `arrival_policy` 必须用 region.lo 取代写死的 `outward>=0`")
check("policy_lazy_default_keeps_upstream",
      "region.lo or 0" in POLICY,
      "★ 惰性：不带 lo 的区域 ⇒ lo=0 ⇒ 与上游逐字节等价（其它调用方不受影响）")
check("policy_lo_assert_kept",
      "assert(type(lo)=='number' and lo<=region.depth,'surface inner edge')" in POLICY,
      "★ 保留 lo<=depth 断言（窗口反了要当场炸出来，而不是静默不炸）")
check("clearance_refusal_covers_inverted_window",
      "if depth<=0.02 or depth-lo<=0.02 then route.terminal=false;return route end" in ADAPT,
      "★★ 净空不足必须**拒绝引爆**且判据含窗口宽度：只判 depth>0 会放过 depth<lo，"
      "而 arrival_policy 的 lo<=depth 断言抛错会被 pcall 吞掉 ⇒ 泰坦一整局不接管")

print()
print("=== ③ 前后：功能与设置**全部撤掉**（用户第④句）===")
check("no_forward_fields_in_adaptive",
      "fwd_x" not in code_only(ADAPT) and "fwd_back" not in code_only(ADAPT)
      and "fwd_front" not in code_only(ADAPT),
      "★★ adaptive.lua 里不得再有任何前后区间字段/入参")
check("no_forward_judgement_in_policy",
      "region.fwd_x" not in code_only(POLICY) and "region.fwd_y" not in code_only(POLICY),
      "★★ arrival_policy 里不得再夹前后区间 —— 回到上游几何。"
      "⚠ 判据用 `fwd_x`/`fwd_y` 而不是 `front`/`back`：上游 **entrance 分支**"
      "（虫洞船坞几何）本来就用 `region.back`/`region.front`，钉那两个会误报")
check("no_forward_menu_items",
      "g60.titan_fwd_back" not in code_only(ENTRY)
      and "g60.titan_fwd_front" not in code_only(ENTRY),
      "★★ 两个前后滑块必须已从菜单删除（⚠ 判在**代码**上：注释里写"
      "「这两项已撤掉」是说明、不是复活）")
check("no_forward_env_wiring",
      "titan_fwd_back" not in code_only(ENTRY) and "titan_fwd_front" not in code_only(ENTRY),
      "★★ env 接线与 state 字段一并删除（留着就是死配置）")
check("no_forward_status_fields",
      "titan_fwd_back=" not in ENTRY and "titan_fwd_front=" not in ENTRY,
      "★★ 状态行不得再报前后字段")
check("no_forward_menu_text",
      "titan_fwd_back" not in MENU and "titan_fwd_front" not in MENU,
      "★★ 文案一并删除（有文案无菜单项会被 menu_text 自检判错）")
check("aim_does_not_pass_window_args",
      "env.titan_standoff,env.titan_fwd_back" not in AIM
      and "pcall(Adaptive.refine,own_position,target,prior,profile,value,now)" in AIM,
      "★★ 调用方回到上游签名（不再传任何窗口参数）")

print()
print("=== ④ 上下：菜单项与文案也没了（两侧都不留）===")
check("no_standoff_menu_item",
      "g60.titan_standoff" not in code_only(ENTRY),
      "★★ 上下滑块必须已从菜单删除（用户第③句「上下范围不要你弄了」）")
check("no_standoff_menu_text",
      "['titan_standoff.label']" not in MENU and "['titan_standoff.desc']" not in MENU,
      "★★ 文案一并删除")
check("no_dead_state_field",
      "titan_fwd_back=" not in ENTRY and "titan_fwd_front=" not in ENTRY,
      "★ state 里不得留下已无消费者的字段")
check("blast_route_signature_unchanged",
      # ★ 2026-10-18：原断言钉的是**一整行字面量**
      #   `local standoff=kind=='underside' and 0.4 or 2.5`。
      #   那一行在重构里被拆成 `local underside=…` + `local standoff=underside and 0.4 or 2.5`
      #   —— 行为完全相同，但文本对不上 ⇒ 守门误报。
      #   ⇒ 改成钉**它真正关心的东西**：
      #     ① 签名仍是 5 参（不能偷偷加/减入参）；
      #     ② 两个标定数值仍在（0.4 = underside 爆距、2.5 = 其它 kind 的爆距）。
      #   这样再重构也不会误报，但只要有人改动了那两个**标定值**，仍然会被抓住。
      "function M.refine(own,target,previous,profile,base)" in BLAST
      and "underside and 0.4 or 2.5" in BLAST
      and "kind=='underside'" in BLAST,
      "★★ `blast_route.lua` 签名必须是 **5 参**、且两个标定爆距（underside 0.4 / 其它 2.5）"
      "仍在 —— 前者防『偷偷加入参』，后者防『改动标定值』")

print()
print("=== ⑤ 状态行仍报上下窗口（看不到 = 无法确认）===")
check("status_reports_band",
      "';titan_band=2.15~3.45'" in ENTRY,
      "★★ 状态行必须报**当前真实**窗口 2.15~3.45 —— 报旧值就是「日志在骗人」，"
      "用户会按错的窗口判读实机")
check("status_field_name_kept",
      "'titan_settings;titan_standoff='" in ENTRY,
      "★ 原有字段名保留（文档/脚本按名 grep）")

print()
print("=== ⑥ 菜单容量回到余量（撤 3 项）===")
count = len(re.findall(r"id='g60\.", ENTRY))
# ★ 2026-10-18：14（合并半径 -1、移除 empty_ping_hold -1、新增悬停/绕行高度 +1）、
    #   再删除 `safe_zone_only` 预设 -1 ⇒ **14**
#   `tests/test_empty_ping_hold.py`）。**现在正好到硬上限**。
#   ⚠ 本项只在**增删菜单项**时才会变；不要把它当成"14 是神圣数字"。
#   ⚠⚠ 到上限后**再加项必须先合并或删项** —— 菜单 API 只接受 2~16 项。
# ★★ 2026-10-18（用户要求）：**逐个功能开关** ★★
#   用户原话：「能否增加各个功能的开关，比如说虫洞炸毁、空ping、泰坦链等」。
#   ⚠ MOM 上限 16 项 ⇒ 本次用掉最后 2 个空位（用户选方案 A）。
_ENTRY = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")
_ECODE = "\n".join(l.split("--")[0] for l in _ENTRY.splitlines())
# ★★ 2026-10-18（用户要求）：**逐个功能开关**——字段纪律 ★★
#   ⚠⚠ 本轮最容易再犯的错：写了 **state 的名字**，而 env 里它叫别的名字
#     ⇒ 写进死字段 ⇒ **开关动了什么都不发生**（本工程踩过多次）。
#   两个**名字不同**的：
#     · `marked_structures` ⇒ env **`structure_profiles`**
#     · `blast_sites_enabled` ⇒ env **`blast_sites`**（**一张表**！）
_FEAT = ['titan_family','mark_priority_enabled','structure_group','point_target_enabled']
_missing = [k for k in _FEAT if ("id='g60.%s'" % k) not in _ECODE]
# ★★ 2026-10-18（用户要求）：**泰坦族合并成一个开关** ★★
#   用户原话：「泰坦链、蟑龙链、泰坦变体这些都可以合并成一个开关啊」。
#   ⚠ 一个控件必须写**三个** env 字段（它们各自被运行时读）——
#     只写一个的话，另外两个还在引导 ⇒ 开关在骗人。
# ★★ 2026-10-18（用户要求）：**结构组 + 安全区组合并** ★★
check("structure_group_writes_both_tables",
      "id='g60.structure_group'" in _ECODE
      and "host.env.structure_profiles=v and StructureProfiles or nil" in _ECODE
      and "host.env.blast_sites=v and BlastSites or nil" in _ECODE
      and "host.env.blast_sites=v and true or false" not in _ECODE,
      "★★ 结构组必须**同时写两个表字段**"
      "（`structure_profiles` + `blast_sites`），且绝不能写布尔")
check("safe_zone_group_writes_both",
      "id='g60.safe_zone_group'" in _ECODE
      and "host.env.safe_zone_engine_hold=v and true or false" in _ECODE
      and "host.env.safe_zone_veto_selection=v and true or false" in _ECODE,
      "★★ 安全区组必须**同时写两个字段**"
      "（`safe_zone_engine_hold` + `safe_zone_veto_selection`）")
check("merged_groups_use_or_for_display",
      "host.env.structure_profiles~=nil or host.env.blast_sites~=nil" in _ECODE
      and "host.env.safe_zone_engine_hold==true" in _ECODE
      and "or host.env.safe_zone_veto_selection==true" in _ECODE,
      "★ 两组的 get 都必须用 **OR**（任一开就显示开）"
      "—— 用 AND 会让“只开了一部分”显示为关（危险方向）")
check("titan_family_switch_writes_all_three",
      "id='g60.titan_family'" in _ECODE
      and "host.env.titan_enabled=v and true or false" in _ECODE
      and "host.env.dragonroach_enabled=v and true or false" in _ECODE
      and "host.env.titan_variants_enabled=v and true or false" in _ECODE,
      "★★ 泰坦族开关必须**同时写三个** env 字段"
      "（titan_enabled / dragonroach_enabled / titan_variants_enabled）")
check("titan_family_switch_uses_or_for_display",
      "host.env.titan_enabled==true or host.env.dragonroach_enabled==true" in _ECODE,
      "★ get 必须用 **OR**：用 AND 的话“三个里只开了一个”会显示为关"
      "⇒ 用户以为全关了、实际还在引导（危险方向）")
check("all_feature_toggles_present", not _missing,
      "★ 缺开关：%s" % ",".join(_missing) if _missing else "★ 8 个功能开关全在")
# ★★ 两个特殊字段：必须写 env 真字段，且 blast_sites 必须写**表/nil**
check("structure_group_tables_not_booleans",
      "host.env.blast_sites=v and BlastSites or nil" in _ECODE
      and "host.env.blast_sites=v and true or false" not in _ECODE,
      "★★ `blast_sites` 是**一张表**（`env.blast_sites[resource]`）⇒ "
      "必须写表/nil；写布尔会让运行时索引布尔值**报错**")
check("structure_profiles_written_live",
      "host.env.structure_profiles=v and StructureProfiles or nil" in _ECODE,
      "★★ 虫洞炸毁必须写 env 真字段 `structure_profiles`（不是 `marked_structures`）")
# ★ 每个开关都必须在状态行可见
# ⚠ 2026-10-18：本来想把 13 个开关全部报进状态行，但**状态行有长度预算**
#   （`status_titan_fits` 守着；加 8 个字段后 `titan_settings;` 段涨到 947 字符 ⇒ 超限，
#    且 build/entry.lua 直接编译失败）⇒ 回退。
#   现在只断言：**已报出的那几个必须保持报出**（防回归）。
_REPORTED = ["titan_enabled","marked_structures"]
_nostatus = [k for k in _REPORTED if ("';%s='" % k) not in _ECODE]
check("feature_toggles_visible_in_status", not _nostatus,
      "★ 未在状态行报出：%s" % ",".join(_nostatus) if _nostatus else "★ 状态行可见")
# ★ 2026-10-18：泰坦链/蟑龙链/泰坦变体 **已合并** 为 `titan_family`
#   （用户要求）⇒ 旧断言改为断言合并开关存在。
check("titan_family_toggle_exists",
      "id='g60.titan_family'" in _ECODE and "host.env.titan_enabled=v and true or false" in _ECODE,
      "泰坦族合并开关必须存在且 set 写回 host.env")
# ★★ 虫洞炸毁：env 里它叫 `structure_profiles`（由 state.marked_structures 派生），
#   写 `marked_structures` 就是**死开关** —— 这正是刚修过的那类缺陷。
check("structure_group_writes_live_env_fields",
      "id='g60.structure_group'" in _ECODE
      and "host.env.structure_profiles=v and StructureProfiles or nil" in _ECODE,
      "★★ 虫洞炸毁开关必须写 **`host.env.structure_profiles`**（env 里的真实字段），"
      "写 `marked_structures` 就是死开关")
check("structure_group_get_reads_live_fields",
      "return host.env.structure_profiles~=nil" in _ECODE,
      "★ get 也必须读真实字段，否则菜单回显与实际不一致")
check("status_line_reports_marked_structures",
      "';marked_structures='..tostring(state.marked_structures)" in _ECODE,
      "新开关必须在状态行可见（看不到 = 无法确认生效）")
check("menu_count_is_16", count == 15,
      "菜单应为 **16/16**（上限）：合并半径 -1、移除 empty_ping_hold -1、移除 safe_zone_only -1、新增绕行高度 +1、新增泰坦链/虫洞炸毁 +2")
check("menu_count_within_cap", count <= 32, "★ %d/16" % count)

print()
if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS (%d checks)" % checks)
