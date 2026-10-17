"""守门：无标记分散用的分阵营优先级名册 compat/spread_priority.lua

名册由脚本从《绝地潜兵2哈希整合表.xlsx》生成（用户 2026-10-16 逐条审过）。
本守门把当时那 6 条自检**固化成断言**，并额外要求每条哈希能在 xlsx 里复核到 —— 否则
以后没人能验证名册对不对（本工程纪律：看不到 = 无法确认）。
"""
import pathlib

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
LUA = ROOT / "src" / "g60" / "spread_priority.lua"
SRC = LUA.read_text(encoding="utf-8")
BUILD = (ROOT / "compat" / "build.json").read_text(encoding="utf-8")

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    print(("  PASS " if ok else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not ok:
        failures.append(name)


rt = lj.LuaRuntime(unpack_returned_tuples=True)
tbl = rt.execute(SRC)
FACS = ("终结族", "机器人", "光能族")

rows = {}
per = {}
for fac in FACS:
    d = tbl[fac]
    if d is None:
        continue
    for h, v in d.items():
        hs = str(h)
        rows[hs] = {"fac": fac, "rank": int(v["rank"]), "zh": str(v["zh"]), "en": str(v["en"])}
        per.setdefault((fac, int(v["rank"])), 0)
        per[(fac, int(v["rank"]))] += 1

print("=== ① 基本形状 ===")
check("three_factions", all(tbl[f] is not None for f in FACS), "三个阵营都要在")
check("hash_is_hex16",
      all(len(h) == 16 and all(c in "0123456789abcdef" for c in h) for h in rows),
      "每条哈希都是 16 位小写十六进制（与仓库既有名册同格式）")
check("no_duplicate_hash", len(rows) == sum(per.values()),
      "同一哈希不许出现在两个阵营/两档（%d 条 / %d 唯一）" % (sum(per.values()), len(rows)))
check("source_and_review_recorded",
      "绝地潜兵2哈希整合表" in SRC and "reviewed_by_user" in SRC,
      "★ 名册里必须写明来源表与审阅标记（可追溯）")
check("registered_in_build",
      '"spread_priority": "SpreadPriority"' in BUILD or '"spread_priority":"SpreadPriority"' in BUILD,
      "★★ 必须按 **build.py 确认过的机制**登记：文件放 `src/g60/spread_priority.lua`、在 `aliases` "
      "里用**裸键** `spread_priority -> SpreadPriority`（带 `g60.` 前缀会让 build.py 去找 "
      "`src/g60/g60.spread_priority.lua` 而崩；放 `compat/` 则永远进不了包 —— 两个坑我都踩过）")
check("module_file_in_src",
      (ROOT / "src/g60" / "spread_priority.lua").exists(),
      "★ 模块文件必须在 `src/g60/` 下（build.py 只在 `ROOT/'src/g60'/(name+'.lua')` 找）")
check("no_duplicate_registry",
      not (ROOT / "compat" / "spread_priority.lua").exists(),
      "★ `compat/spread_priority.lua` 不许残留 —— 同一份名册两份拷贝 = 迟早不一致")

print()
print("=== ② 用户点名的必须收录项 ===")
MUST = {"炮艇": "282eb766c1ffa6a1", "碎裂坦克": "c6449ffd9ea3779c", "铁幕坦克": "63df3d07b7424588",
        "钻地喷涌虫": "a381a11c07d3eb94", "掠食追踪虫": "d1e990baf22d5a52"}
for zh, h in MUST.items():
    check("must_keep_%s" % zh, h in rows and zh in rows[h]["zh"],
          "%s(%s) 必须在册：%s" % (zh, h, rows.get(h, {}).get("zh", "缺失")))
check("must_keep_by_name",
      any("燃烧机枪蹂躏者" in v["zh"] for v in rows.values())
      and any("惑乱者（女）" in v["zh"] for v in rows.values()),
      "★ 「燃烧机枪蹂躏者」「惑乱者（女）」必须在册（这两条曾因组件词/英文拼写错误被漏收）")

print()
print("=== ③ 必须剔除的一律不在册 ===")
bad = [v["zh"] for v in rows.values()
       if ("反坦克" in v["zh"] or "Anti-Tank" in v["en"] or "Anti-tank" in v["en"]
           or "迫击炮" in v["zh"] or "投掷物" in v["zh"] or "干扰器" in v["zh"]
           or "(Model)" in v["en"] or "(Projectile)" in v["en"] or "洞" in v["zh"])]
check("excluded_absent", not bad, "反坦克/迫击炮/投掷物/干扰器/(Model)/洞 都不得在册：%s" % (bad or "无"))
check("no_at_tier_leak",
      "30f2dee2333f227a" in rows and "d37e8d120d2836e3" in rows,
      "★ 移动工厂本体与其「带干扰塔」变体都要在（曾被空格规则误杀）")

print()
print("=== ④ 档位与归属断言（这几轮踩过的坑全部固化）===")


def rank_of(pred):
    """返回满足 pred 的条目的 rank 集合（空集 = 没收录）。"""
    return {v["rank"] for v in rows.values() if pred(v)}


def ordered(*groups):
    """断言各组 rank 严格递增（组内可同档、可多值）。返回 (ok, detail)。"""
    seen = []
    for label, ranks in groups:
        if not ranks:
            return False, "「%s」一条都没收录" % label
        seen.append((label, sorted(ranks)))
    for i in range(len(seen) - 1):
        if not (max(seen[i][1]) < min(seen[i + 1][1])):
            return False, "%s 未严格高于 %s（实际 %s）" % (seen[i][0], seen[i + 1][0], seen)
    return True, " < ".join("%s%s" % (l, r) for l, r in seen)


# —— 机器人 —
# 巨型者档细分（2026-10-16 用户要求）：4 个点名者 > 其他巨型者及其变体
hulk_high = rank_of(lambda v: v["en"] in ("Hulk Obliterator", "Hulk Bruiser",
                                          "Hulk Firebomber", "Jet Brigade Hulk Bruiser"))
hulk_rest = rank_of(lambda v: "Hulk" in v["en"] and v["en"] not in (
    "Hulk Obliterator", "Hulk Bruiser", "Hulk Firebomber", "Jet Brigade Hulk Bruiser"))
ok, d = ordered(("巨型者-高", hulk_high), ("巨型者-其他", hulk_rest))
check("hulk_subtier_order", ok,
      "★ 巨型抹煞者/碾压者/烈焰轰炸者/喷气旅碾压者 必须高于其他巨型者及其变体：%s" % d)

# 惑乱者 > 激进先锋；强化侦察纵步者与惑乱者**同档**（用户 2026-10-16 确认）
agi = rank_of(lambda v: "Agitator" in v["en"] or "Agiator" in v["en"])
scout = rank_of(lambda v: v["en"].strip() == "Reinforced Scout Strider")
rad = rank_of(lambda v: "Radical" in v["en"])
ok, d = ordered(("惑乱者", agi), ("激进先锋", rad))
check("agitator_above_radical", ok, "★ 惑乱者必须高于激进先锋：%s" % d)

# ★★★ 2026-10-18（用户要求）：**草案档位必须逐档等于名册** ★★★
#   用户原话：「重新修正草案，目前草案的档次分级跟实际代码不符」「**具体优先级以代码为准**」。
#   实踩：草案原本是 v3 审阅的中间态 —— 终结族只到 7 档（名册 13）、
#     机器人档位错位（拿巨型者当第 3 档，名册里它是第 4 档）、
#     光能族章节**顺序乱掉**（3,2,3,4,5,6,6,7,8,8）。现已按名册重生成。
#   ⚠ 这道门逐档比对：阵营、档号、成员哈希集合。以后改代码不同步 ⇒ 直接变红。
_DRAFT = (ROOT / "SPREAD_PRIORITY_DRAFT.md").read_text(encoding="utf-8")


def _draft_tiers():
    """从草案里读出 {(阵营,档号): {哈希,…}}。
    ⚠ 不用正则（本文件未导入 `re`）：按 `|` 切列、取第 4 列当哈希。
    ⚠ 不要用 `find(name)` 定位 —— 头部说明也提到这些名字，会误命中（实踩）。
    """
    out = {}
    fac = None
    cur = None
    for line in _DRAFT.splitlines():
        if line.startswith("## "):
            nm = line[3:].strip()
            fac = nm if nm in FACS else None
            cur = None
            continue
        if fac and line.startswith("### 第 "):
            cur = int(line.split("第 ")[1].split(" 档")[0])
            out[(fac, cur)] = set()
            continue
        if fac and cur is not None and line.startswith("|"):
            cols = [c.strip() for c in line.split("|")]
            if len(cols) >= 4:
                h = cols[3].strip("`")
                if len(h) == 16 and all(ch in "0123456789abcdef" for ch in h):
                    out[(fac, cur)].add(h)
    return out

# 名册侧直接用本文件已解析好的 `rows`（fac/rank 都在）—— 不重复解析、不会漂移。
_ROS = {}
for _h, _v in rows.items():
    _ROS.setdefault((_v["fac"], _v["rank"]), set()).add(_h)
_DT = _draft_tiers()
_missing = sorted("%s 第%d档" % k for k in _ROS if k not in _DT)
_extra = sorted("%s 第%d档" % k for k in _DT if k not in _ROS)
_mismatch = sorted("%s 第%d档" % k for k in _ROS
                   if k in _DT and _DT[k] != _ROS[k])
check("draft_tiers_match_roster",
      not _missing and not _extra and not _mismatch,
      "★★ 草案档位必须逐档等于名册（缺%s / 多%s / 成员不符%s）"
      % (_missing[:3], _extra[:3], _mismatch[:3]))

# 蹂躏者档细分：重型(含变体)+烈火 > 火箭(含变体) > 其他蹂躏者 > 狂暴者
dev_heavy = rank_of(lambda v: "Heavy Devastator" in v["en"]
                    or v["en"] == "Conflagration Devastator")
dev_rocket = rank_of(lambda v: "Rocket Devastator" in v["en"])
dev_rest = rank_of(lambda v: "Devastator" in v["en"]
                   and "Heavy Devastator" not in v["en"]
                   and v["en"] != "Conflagration Devastator"
                   and "Rocket Devastator" not in v["en"])
dev_all = dev_heavy | dev_rocket | dev_rest
berserk = rank_of(lambda v: "Berserker" in v["en"])
ok, d = ordered(("重型+烈火", dev_heavy), ("火箭", dev_rocket),
                ("其他蹂躏者", dev_rest), ("狂暴者", berserk))
check("devastator_subtier_order", ok,
      "★ 重型蹂躏者(含变体)+烈火 > 火箭蹂躏者(含变体) > 其他蹂躏者 > 狂暴者：%s" % d)
check("devastator_family_in_robot_only",
      dev_all and all(v["fac"] == "机器人" for v in rows.values()
                      if "Devastator" in v["en"]),
      "★ 凡 `Devastator*` 只能落机器人阵营 —— 防「蹂躏者 MK2 移动工厂生产」被移动工厂档劫持")
spawn = [h for h, v in rows.items() if v["en"] == "Devastator MK2 Spawn"]
check("spawn_variant_in_devastator_tier",
      spawn and all(rows[h]["rank"] == 10 for h in spawn),
      "★ 「蹂躏者 MK2 移动工厂生产」必须在**其他蹂躏者**那一档（用户 2026-10-16 指出）")

# 机枪奇袭者 = 机器人最低档（rank 最大），且必须高于狂暴者
mg = rank_of(lambda v: v["en"] in ("MG Raider", "Incendiary MG Raider",
                                   "Jet Brigade MG Raider", "Trooper MK2 MG"))
check("mg_raider_lowest_robot_tier",
      bool(mg) and berserk and min(mg) > max(berserk),
      "★ 机枪奇袭者必须是机器人**最低**档（低于狂暴者）：mg=%s berserk=%s"
      % (sorted(mg), sorted(berserk)))
check("mg_raider_four_named",
      len(mg) == 1
      and all(rows[h]["en"] in ("MG Raider", "Incendiary MG Raider", "Jet Brigade MG Raider",
                                "Trooper MK2 MG")
              for h, v in rows.items()
              if v["fac"] == "机器人" and v["rank"] in mg),
      "★ 机枪奇袭者档恰为用户点名的 4 个：机枪奇袭者 / （炽灼部队）/ 喷气 / 装甲兵 MK2（机枪奇袭者）")

# —— 终结族 —
# 强袭虫档细分：孢子 > 巨兽级(含 MK2) > 钻地 > 普通
ch_spore = rank_of(lambda v: v["en"] == "Spore Charger")
ch_beh = rank_of(lambda v: "Charger Behemoth" in v["en"])
ch_rupt = rank_of(lambda v: v["en"] == "Rupture Charger")
ch_plain = rank_of(lambda v: v["en"].strip() == "Charger")
ok, d = ordered(("孢子强袭虫", ch_spore), ("巨兽级强袭虫", ch_beh),
                ("钻地强袭虫", ch_rupt), ("强袭虫", ch_plain))
check("charger_subtier_order", ok,
      "★ 孢子强袭虫 > 巨兽级强袭虫(含 MK2) > 钻地强袭虫(用户口语「爆裂」，已确认) > 强袭虫：%s" % d)

# 新增最低档：虫窝护卫 > 狂暴武斗虫 > 其他武斗虫（含孢子武斗虫）
hive = rank_of(lambda v: v["en"] == "Hive Guard")
w_spawn = rank_of(lambda v: v["en"] == "Warrior (Spawned)")
w_rest = rank_of(lambda v: "Warrior" in v["en"] and v["en"] != "Warrior (Spawned)")
ok, d = ordered(("虫窝护卫", hive), ("狂暴武斗虫", w_spawn), ("其他武斗虫", w_rest))
check("warrior_subtier_order", ok,
      "★ 虫窝护卫 > 狂暴武斗虫 > 其他武斗虫：%s" % d)
check("spore_warrior_with_other_warriors",
      rank_of(lambda v: v["en"] == "Spore Burst Warrior") == w_rest,
      "★ 孢子武斗虫与**其他武斗虫同档**（用户确认，不单独升级）")

ov = [v for v in rows.values() if "Elevated Overseer" in v["en"] or "Crescent Overseer" in v["en"]]
# ★★ 2026-10-18（用户要求）：**崇高监视者 > 新月监视者 / 肉瘤体** ★★
#   用户原话：「崇高监视者大于新月监视者 / 肉瘤体」。
#   ⚠ 这**推翻了本门原先的断言**（它本来要求崇高/新月**同档**）。
#   原因：当初那道门要防的是「Overseer 关键词把同一个单位重复收进两档」，
#   而不是「两者必须同档」—— 现在用户要求它们**分开**，故改为断言严格大小关系。
_el = [v for v in rows.values() if v["en"].strip() == "Elevated Overseer"]
_cr = [v for v in rows.values() if v["en"].strip() == "Crescent Overseer"]
_fl = [v for v in rows.values() if v["en"].strip() == "Fleshmob"]
check("elevated_overseer_above_crescent_and_fleshmob",
      _el and _cr and _fl
      and all(e["rank"] < c["rank"] for e in _el for c in _cr)
      and all(e["rank"] < f["rank"] for e in _el for f in _fl),
      "★★ 崇高监视者必须**严格高于**新月监视者与肉瘤体"
      "（用户 2026-10-18 要求；推翻了原先的同档断言）")
# ★★ 2026-10-18（用户要求）：**光能族 御门者 > 证真者** ★★
#   用户原话：「光能族的御门者大于证真者」。
#   用户选方案 B：御门者单独一档（**仅低于猎杀器**），
#   证真者+粉碎者 ⇒ 同档在它下面。
#   ⚠ rank 必须是**整数**（本文件 `int(v["rank"])`）⇒ 无法用 1.5 表达中间档。
_gk = [v for v in rows.values() if v["en"].strip() == "Gatekeeper"]
_zj = [v for v in rows.values() if v["en"].strip() == "Veracitor"]
_hr = [v for v in rows.values() if v["en"].strip().startswith("Harvester")]
check("gatekeeper_strictly_above_veracitor",
      _gk and _zj and all(g["rank"] < z["rank"] for g in _gk for z in _zj),
      "★★ 御门者必须**严格高于**证真者（rank 更小）—— 用户 2026-10-18 明确要求")
check("gatekeeper_own_tier_below_harvester",
      _gk and _hr and all(g["rank"] > h["rank"] for g in _gk for h in _hr)
      and all(g["rank"] == _gk[0]["rank"] for g in _gk),
      "★ 御门者单独一档，且**仅低于猎杀器**（用户选方案 B）")
# ★★ 2026-10-18（用户要求）：**守望者位于粉碎者之后、崇高监视者之前** ★★
#   用户原话：「新加入守望者，把守望者放在崇高监视者之前，粉碎者之后」。
_wa = [v for v in rows.values() if v["en"].strip() == "Watcher"]
_cs = [v for v in rows.values() if v["en"].strip() == "Crusher"]
check("watcher_between_crusher_and_elevated_overseer",
      _wa and _cs and _el
      and all(c["rank"] < w["rank"] for c in _cs for w in _wa)
      and all(w["rank"] < e["rank"] for w in _wa for e in _el),
      "★★ 守望者必须严格位于粉碎者之后、崇高监视者之前")
check("watcher_is_registered_as_enemy",
      "ac60e78435098c9d" in (ROOT / "src" / "g60" / "enemy_faction.lua").read_text(encoding="utf-8"),
      "★ 守望者必须在敌人表里，否则永远不会被接管（fail-safe 判据）")
sm = [v for v in rows.values() if v["en"].strip() == "Overseer"]
check("plain_overseer_rank7", sm and all(v["rank"] == 7 for v in sm),
      "★ 普通「监视者/Overseer」只能在第 7 档（2026-10-18 第二次重编号后）")
spewer = [v for v in rows.values()
          if any(k in v["en"] for k in ("Bile Spewer", "Nursing Spewer", "Rupture Spewer"))]
check("spewer_family_one_tier",
      spewer and all(v["fac"] == "终结族" and v["rank"] == 9 for v in spewer),
      "★ 喷涌虫家族（胆汁/抚育/钻地）必须同档")
stalk = [v for v in rows.values() if "Stalker" in v["en"]]
check("stalker_and_predator_same_tier",
      stalk and len({v["rank"] for v in stalk}) == 1,
      "★ 追踪虫与掠食追踪虫同档（用户指出我拆成 8/9 是错的）")
for fac in FACS:
    ranks = sorted({r for (f, r) in per if f == fac})
    check("ranks_start_at_1_%s" % fac, ranks and ranks[0] == 1,
          "%s 档位从 1 开始（实际 %s）" % (fac, ranks))
check("gap_documented",
      "档位间隙" in SRC or "rank 跳号" in SRC,
      "★ 用户标的「》」档位间隙必须在文件里说明（喷涌虫 → 追踪虫）")

print()
print("=== ⑤ 每条哈希都能在 xlsx 里复核到（复核源）===")
xlsx = pathlib.Path(r"D:\桌面\绝地潜兵2哈希整合表.xlsx")
if not xlsx.exists():
    check("xlsx_cross_check", True, "跳过：xlsx 不在（CI/别的机器正常）")
else:
    try:
        from openpyxl import load_workbook
        ws = load_workbook(xlsx, read_only=True, data_only=True)[wb_name] if False else \
            load_workbook(xlsx, read_only=True, data_only=True)["哈希表-整合"]
        found = set()
        for row in ws.iter_rows(values_only=True):
            for c in row:
                s = str(c).strip().strip('="') if c is not None else ""
                if s.isdigit():
                    found.add("%016x" % int(s))
        miss = [h for h in rows if h not in found]
        check("xlsx_cross_check", not miss, "★ 名册每条哈希都能在源表里找到（缺 %s）" % (miss[:5] or "无"))
    except Exception as e:
        check("xlsx_cross_check", False, "读 xlsx 失败：%s" % e)

print()

print("=== 7. 无标记改派：行为层（真求值）+ 接线/红线断言 ===")
_RT = (ROOT / "src/g60" / "experimental_runtime.lua").read_text(encoding="utf-8")

# --- 接线 + 红线 + 行为钉（文本级）---
# ★★★ 2026-10-16 二次修正的守门（原两条断言**把 bug 钉成了正确**）★★★
#   旧断言 `"P.cap=ok_c and cap or nil" in _RT` 是**纯子串匹配**、不校验顺序，
#   而那一行恰恰写在 `local ok_c,cap=…` **之前** ⇒ 读到全局恒 nil ⇒ 门永远为假。
#   实机铁证：包内有该逻辑、加载器 `loaded`，而日志 `spread_pick;` **0 条**。
#   ⇒ 现在改为断言**顺序**与**可达性**，不再用裸子串。
_spread_i = _RT.find("local no_mark=(structure_mark==nil)")
_gate_i = _RT.find("local gate=TakeGate.decide{")
_consume_i = _RT.find("if reservations and my_structure==nil and P.spread_pick_row then")
check("spread_gated_on_no_mark_only",
      _spread_i != -1 and "point_marker==nil" in _RT[_spread_i:_spread_i + 500]
      and _consume_i != -1,
      "★★ 改派必须在**完全无标记**（无 structure_mark / 无 ping 点 / 无旧持有）"
      "且消费点也没有分配时才生效")
check("spread_computed_before_gate",
      _spread_i != -1 and _gate_i != -1 and _spread_i < _gate_i,
      "★★★ 可达性红线：候选计算必须在 `TakeGate.decide{` **之前** —— 无标记时门控返回 "
      "`no_mark_no_hold`（gate.drive=false），写在 `if enters then` 内会**结构性不可达**"
      "（这正是 v0.1.25 `spread_pick` 0 条的真根因）")
check("spread_reuses_priority_drive",
      "my_mark=P.spread_pick_row;my_structure=my_mark" in _RT
      and "reservations:claim(owner,my_mark.identity,my_mark.resource)" in _RT
      and "reservations:keep_only(owner,my_mark.identity)" in _RT,
      "★★ 驱动复用既有 priority:step 通道（claim/keep_only + my_structure），不新增写途径")
check("spread_no_new_outer_locals",
      "local SpreadPriority=" not in _RT and "local Candidates=" not in _RT,
      "★★★ 红线：tick 闭包已用满 60 个 upvalue ⇒ 绝不许新增被它引用的外层局部"
      "（引用未声明的全局名同样危险：既不占 upvalue、又恒为 nil —— 我为此返工两轮）")
check("spread_modules_come_from_env",
      "env.spread_priority" in _RT and "env.spread_candidates" in _RT,
      "★★ 名册与候选模块必须经 `env` 取（env 已是 upvalue ⇒ 零新增），且 entry 里要用"
      "**构建别名**（SpreadPriority / Candidates）接线")
check("spread_context_from_observed_row",
      "identity_bytes=m.identity_bytes" in _RT and "entity_address=m.entity_address" in _RT
      and "P.cap=ok_c and cap or nil" not in _RT,
      "★ 候选上下文由**本帧观测行**构造（`m.identity_bytes`/`m.entity_address`），"
      "不额外付一次 Search.capture；且旧的 `P.cap=ok_c and cap or nil`（先读后声明、恒 nil）"
      "必须已删除")
check("spread_arm_is_what_opens_gate",
      "spread_armed=P.spread_pick_row~=nil" in _RT
      and "o.spread_armed" in (ROOT / "src/g60/take_gate.lua").read_text(encoding="utf-8"),
      "★★★ 无标记时门控必须由 `spread_armed` 放行（否则仍恒不可达），"
      "且 take_gate 里要有对应的 `o.spread_armed` 判据")
check("spread_log_visible",
      "spread_pick;entity=" in _RT and ";why=PRIORITY" in _RT,
      "★★ 可归因：`spread_pick;entity=…;target=…;rank=…;why=PRIORITY;candidates=…`")

if failures:
    print("RESULT: %d passed; %d failed" % (checks - len(failures), len(failures)))
    for f in failures:
        print("  failed: " + f)
    raise SystemExit(1)
print("RESULT: ALL PASS (%d checks)" % checks)


print()
