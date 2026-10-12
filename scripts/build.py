"""Reproducible public build. Python stdlib only; no game installation required."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import struct
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'compat/build.json').read_text())

# ★★ 发布版本的**唯一来源**（2026-10-01）★★
#   发新版**只改这一行**，下面三处自动跟随：
#     manifest.json 的 Name / Options[0].Name  -> TITLE
#     dist/ 下的成品包文件名                    -> ZIP_NAME
#     BUILD-INFO.json 的 version                -> VERSION
#
#   为什么不放 compat/build.json：
#     · 它的顶层 key 被 tests/test_bughole_scope.py 的 `build_json_no_new_top_key` 钉死
#       （只允许 `aliases` 增加条目）⇒ 加不了我们自己的键；
#     · 它的 `public_version` 是**上游基线**版本，被 `build_json_pinned:*` 钉死
#       （必须与上游 0.1-beta.1 逐值相同）⇒ 不能拿它当我们的版本号。
#
#   事故背景：发 Release v0.1.2 时成品包还叫 `G60-BugHole-Lock-0.1.0.zip`
#   —— 因为 TITLE / ZIP_NAME 把 '0.1.0' 硬编码在代码里，与 Release 标签完全脱节。
RELEASE_VERSION = '0.1.22'
# ★ v0.1.22（2026-10-10，用户报）：**标记的泰坦不该输给空白 ping**（行为修复）。
#   用户原话：「现在标记的泰坦单位的优先级比空 ping 的优先级低，泰坦的优先级理论上
#   应该只比虫洞低」。
#   根因：`ping_beats_titan` 的排除项 `mark_is_this_unit` 只判
#     「引擎选中的那个正好是**队列首**那个标记」（`m.selection_id==structure_mark.id`）
#     ⇒ 两种情况下**玩家点名的泰坦仍会输给空白 ping**：
#       ① 队列首不是它（队列里还有别的标记）② **引擎还没选它**（`m.selection_id`=0/invalid）
#   修复：改成**按档位比较** —— 空白 ping 视为比**任何实体标记**都低：
#     · `env.point_mark_rank`（entry 默认 **1600**）⇒ 连"名册外的其它单位"(1500) 也压得住它，
#       与文档原则「虫洞/构筑 > 标记单位 > 空白标记」一致
#     · 判据：队列里存在 `current==true` 且 `env.mark_tier(resource) < point_rank` 的标记
#       ⇒ `better_live_mark` ⇒ ping 不许抢
#     · 档位一律走 `env.mark_tier`（**唯一实现**），本处不另写第二份
#   ⚠ **保留 2026-10-10 的原意**：**引擎自己挑的**泰坦（玩家没点名 ⇒ 不在队列里）
#     依旧让位给 ping —— "玩家意图 > 引擎自动选择" 与 "玩家点名 > 空白 ping" 是两件事。
#   ⚠ 仍要求 `not (old and old.titan)`（已在跑泰坦航路的不半路改向）。

# ★ v0.1.21（2026-10-10，用户「直接改」）：**「已在飞的锁 = 玩家意图」**（行为修复）。
#   症状（用户）：「标记泰坦后（无其他标记敌人）投掷手雷，手雷会飞向泰坦附近的敌人引爆」。
#   实机证据（v0.1.20 日志，10 条 `engine_explode_probe` 里的两条）：
#     `engine_explode_probe;entity=1227;age=3987552;…;intended=1187;engine_sel=1051;stage=around;
#      guided=true;mark=-`
#   共同特征 **`mark=-`**（标记已离开 UI 的 8 秒窗口）+ `engine_sel ≠ intended` + `stage=around`
#   ⇒ 机制：`remembered_intent` 把过期标记从队列丢掉 ⇒ **没有任何路径再每帧重申目标**
#     （泰坦链写的是**绕行点**，不是选择；priority 那条路要求队列里有标记）
#     ⇒ 引擎中途改选旁边那个敌人 ⇒ 雷在旁侧敌人身上引爆。
#   修复：**只要还有在飞的 G-60 锁着该目标，该标记就不算过期**（锁就是意图）。
#     · `P.locked_ids[目标 id] = 帧号`，在 `structure_ping:observe()` **之前**刷新
#       （`remembered_intent` 在 observe 内部被调）
#     · `remembered_intent` 里 `if P.locked_ids[mark.id] then return true end`
#     · 帧号 TTL 6 帧 ⇒ 防实体 id 复用与表增长
#     · ⚠ 只延长**已被锁**的标记 ⇒ 不影响「取消标记后不再用」（`*_live_only`）的既有语义；
#       工程原本的注释只说"持有 old.lock 的那颗不受影响"，但漏了"它还需要标记留在队列里
#       才能继续重申目标"这一环。
#   ★ 其它 8 条 `engine_explode_probe` 是 `engine_sel == intended`（炸在目标本身）⇒ 属正常/另一类。

# ★ v0.1.20（2026-10-10，用户选「1」）：**标记队列审计**（纯诊断，零行为改动）。
#   背景：用户报「标的是泰坦却打了别的目标」。已查明的事实：
#     · 泰坦只有两个 resource：`9e2e17f2ccccafdd`（胆汁泰坦，compat/titan_profile.lua）
#       与变体 `ef04cb84d097a497`（compat/titan_variants.lua）
#     · 而审计到的那 8 颗雷锁的是 `a05bd1ec67b3ac4c` / `dcf8e74212fbee3b`
#       （在 priority_catalog + weakpoint_profiles ⇒ **名册重甲，不是泰坦**）
#       / `bc2af8548c6d5e06`（structure_profiles ⇒ 结构）/ `cc7022fdd172089b`（未知）
#   ⇒ 两种可能必须分清：
#     (a) 标的就是名册重甲 ⇒ 行为按设计走（问题在通用路径）
#     (b) 标了泰坦却没被选中 ⇒ **标记选择 bug**（泰坦档位 1000 本该压过名册 1000+rank）
#   本版加一行 `mark_queue;`：**投掷那一刻的队列全貌**
#     `entity=…;n=…;ids=…;resources=…;tiers=…;current=…;picked=…;engine_sel=…;frame=…`
#     · `tiers` 用 `env.mark_tier`（唯一实现）⇒ 与选择逻辑同一把尺子
#     · `picked` = 我们实际挑的（多标记分流的产物）/ `engine_sel` = 引擎选的
#     · 按 (手雷, 队列签名) 去重（`P.mq_logged`，与 `P.explprobe` 同款规模可控）
#   ⚠ 只读：不改任何选择/判定；已进 emit 白名单。

# ★ v0.1.19（2026-10-10，用户要求「加上诊断呗」）：**引擎引爆审计**（纯诊断，零行为改动）。
#   用户报：「标记泰坦后（无其他标记敌人）投掷手雷，手雷会飞向泰坦附近的敌人引爆」。
#   已有的 `engine_explode_probe;` 答不了这个问题（它只存安全区/绕行时的位置 ⇒ dist/gp 常为 `-`）。
#   在**同一处**（`note_already_exploded`，引擎已引爆的判定）追加审计字段：
#     `intended=`（我们锁的 id）/ `engine_sel=`（引擎当前选的 id）/ `stage=`（泰坦路线阶段）/
#     `guided=`（那一帧到底在不在引导）/ `mark=`（当时的标记 id）
#   ⇒ 一次分清三种可能：
#     ① guided=true 且 intended=泰坦 ⇒ **引擎引信在旁侧小怪上提前炸**（抑制没覆盖那帧）
#     ② engine_sel ≠ intended ⇒ **引擎改选了旁边的敌人**（标记没压过引擎选择）
#     ③ guided=false ⇒ **接管断档**
#   ⚠ 与已有探针**分开 pcall**：审计若引用了该作用域不可见的名字（`scope`/`old` 就是不可见的，
#     本文件记录过那次实机崩溃），只丢审计字段，**不能**把已有 dist/own 一起丢掉。
#   ⚠ 只读：不改任何状态；字段缺了就是 `-`。

# ★ v0.1.18 的内容（2026-10-10，用户要求「先做第 1 步」）：**(c) 让位的候选取证（纯诊断）**。
#   背景：用户要 (b)/(c) —— 新标记了**更高档**的单位时，已在飞的雷是否该转火。
#   现行规则**只对"新近结构标记"让位**（`native_priority.lua` 的 `fresh_structure`），
#   单位→单位不抢（同层保持忠实）。本步**只测量不动作**，把"如果放开会怎样"变成数据。
#   1) **五档档位抽成唯一实现** `env.mark_tier`（runtime 里定义，env 字段而非 local
#      —— tick 的 xpcall 正好 60 upvalue，多一个被捕获的 local 会让整份 chunk 编译失败）。
#      `structure_ping` 的 `options.priority` 只做转发；`native_priority` 里**不得**再写
#      第二份档位链（门 `mark_tier_single_implementation` 钉着）。
#   2) `native_priority` 在"单位锁 + 队列里存在 current==true 且档位更优的标记"时，
#      产出候选取证 `mark_yield_candidate={id,locked_tier,new_id,new_tier,slot,dist}`：
#        · **零行为改动**：不设 `yielded_unit`、不动 `chosen`、不释放锁
#          （门 `yield_candidate_is_read_only` 断言候选块代码里没有这两者）
#        · 距离（"还没飞太远"的门槛要用它）只在该 (雷, 新标记) 组合**首次**出现时
#          读一次 `d.position`（≈6 次读）—— 不去重会把纯诊断变成新的开销源
#        · 同时挂在 `lock` 与 `keep` 两种结果上（只挂 lock 会在 `chosen` 为空那一路丢掉证据）
#   3) runtime 打 `mark_yield_candidate;entity=…;locked=…;locked_tier=…;new=…;new_tier=…;
#      dist=…;would_yield=…;frame=…`（已进 emit 白名单）；`would_yield` 用提议门槛
#      `env.mark_yield_distance`（entry 默认 **30 m**）**只作判读**。
#   ⚠ `env.mark_tier` / `env.mark_yield_distance` 已加进 entry 的 env 字面量 ——
#     门 `env_fields_all_wired` 要求模块会读的每个 env.X 都在字面量里声明。
# ★ v0.1.17 的内容（2026-10-10）：**修 v0.1.16 的空转事故**（自我纠正）。
#   ⚠⚠ v0.1.16 的 bug：分流/让位/claim 读的是 `mark.queue`，但 `mark_priority_enabled=false`
#      （entry 默认）⇒ `ping` 为 nil ⇒ **`mark` 恒为 nil** ⇒ `if reservations and mark
#      and mark.queue` 从来没进去过 ⇒ **整个分流逻辑空转，实际没修任何东西**。
#      实机铁证：日志里 `ping_queue;` **0 条**（它只在 `mark` 非空时才可能打），
#      而 `structure_mark;` 35 条 ⇒ 标记走的是 **`structure_ping`**。
#   修复：队列来源改成 **`structure_mark or mark`**（后者只为将来打开
#      `mark_priority_enabled` 时兜底），并在门里**禁止**回退到只读 `mark`。
#   ★ 同时查清一个关键机制：`priority:step` 的 **`mark` 参数只用于日志元数据**
#     （`native_priority.lua:928/932`），**从不用于选目标** —— 选目标只走
#     **`structure_mark`（第 6 个参数）** 那条路（`claim_profile` 目标：结构/泰坦/蟑龙/变体）。
#     ⇒ 挑中的标记必须**同时**传进 `my_structure`，否则分流对结构/泰坦不生效。
#   ★ 本轮实际生效的范围（诚实边界）：
#     · **泰坦链**：`claim` + 让位门（`my_mark` 现在非空 ⇒ 真正生效）
#     · **结构/泰坦等 `claim_profile` 目标**：2 个标记 + 2 颗雷 ⇒ 经 `my_structure`
#       各打一个
#     · **无 profile 的通用单位**：本 mod **无法**改派（选目标不走 `mark` 参数，
#       而 `structure_mark` 分支要求 `claim_profile`）⇒ 那类目标由**引擎**决定，
#       我们只能靠 sticky 保持忠实。要改派得写引擎的选择（更大的一块，未做）。
# ★ v0.1.16 的内容（2026-10-10，用户要求「直接修复」）：**多标记分流**。
#   用户原话：「目前存在多个标记敌人在场时如果有 2 颗 G60，这 2 颗 G60 会向优先级最高的
#   标记敌人飞去，容易造成伤害溢出」；规则：「如果只有 1 个标记，那么可以接受多个手雷的锁定」。
#   根因（已核实）：预留系统（`target_reservations`）**只接在 `native_priority` 的 3 处**
#   （`:276` generic_validate / `:353` 另一处校验 / `:647` 虫洞路径），而**泰坦链
#   `native_titan_aim.lua` 一次都不查**（`available`/`reservations`/`claim` 出现 0 次），
#   且泰坦链由 `titan:step` **单独驱动**（不走 `priority:step`，拿不到 `available` 闭包）
#   ⇒ **两颗 G-60 各自独立接管同一个标记泰坦**。
#   修复三件（都在 runtime，**一处实现**）：
#     ① **每颗雷选"第一个没被别人预留"的标记**（`mark.queue` 已是档位顺序），
#        再交给 `priority:step` ⇒ 2 个标记 + 2 颗雷各打一个；
#     ② **泰坦链接管成功后 `claim`**（先 `available` 再 `claim` —— 后者对"别人已占"是
#        断言失败，不能直接调）；
#     ③ **让位**：若"我该打的标记 ≠ 引擎本帧给我选的"且"它还没被别人占" ⇒ 本帧不进泰坦链，
#        交给 priority 那条路把选择写到备选标记上（下一帧引擎选中它 ⇒ 泰坦链自然转过去）。
#   ⚠ 用户拍板：**全都占了（例如场上只有 1 个标记）⇒ 允许共享** —— 挑不到空闲标记时
#     保持档位最高者，**不拒绝接管**（否则会变成"一颗都不打"）。
#   ⚠ **不动**之前拍板的五档次序（虫洞 0 / 蟑龙 500 / 泰坦 1000 / 名册 1000+rank / 其它 1500）
#     —— 本次只动"同档内选谁"。有门 `mark_tier_order_unchanged` 钉着。
#   ★ 取证行：`mark_alloc;entity=…;path=titan;state=yield;engine_target=…;my_mark=…;queue=…`
#     （每颗雷一条）⇒ 判读"2 个标记 + 2 颗雷有没有各打一个"的唯一依据。
# ★ v0.1.15 的内容（2026-10-10，用户要求"先做 1"）：**纯诊断，不改玩法**。
#   背景（v0.1.14 实测，战斗帧每执行帧）：总 532.8 读 —— 观察者 236.8（44%）、
#   Search 108.2（20%）、ping 81.3（15%）、安全区 37.7、prio 28.3、verify 24.4、
#   readiness 16.0，`other_reads` **0**（10 路已覆盖全部读）。
#   新增**通道 10 = guard 复读**（"证明同帧内引擎没改写这块内存"的那一遍重读）：
#     · `Search.capture` 的复读循环（`native_search_context.lua:186`）——
#       本模块拿不到 env ⇒ 由 runtime **经 opts 传 `counters`**（`opts` 现在总是建表；
#       模块里对 options 的用法全是 `options and options.X` ⇒ 语义不变）。
#     · `ping.observe` 末尾的 `d.validate()`（`native_ping.lua`）。
#   `perf;` 新增 `guard_reread=`，`other_reads` 改成"总数减去 1..10"。
#   ⚠ 目的：把**安全纪律的开销**变成可读数字（实测约占战斗帧 17%），
#     再由用户决定"保留 / 只对小锚点复读 / 同帧去重"—— 这不是我能单方面裁的。
#   ⚠ 同时记下两条已被实测否掉的方向（免得重走）：
#     · 「观察者扫描收窄到 active」—— `obs_beyond;index=160;active=2;count=161`
#       ⇒ 会漏雷，彻底作废；
#     · 「ping 环扫描改批量读」—— 实测环段只有 **7.3 读/执行帧**（actor 段 13.0、
#       两段之外 61.0）⇒ 环不是主体，批量读最多省 7 读/帧，不值。
# ★ v0.1.14 的内容（2026-10-10，用户要求"1+2"）：**纯诊断，不改玩法**。
#   1) **修仪器**：通道改成**保存/恢复**（原来读完置 nil）——
#      `priority:step` 内部会调 `scope.validate`（通道 4），置 nil 会把外层通道抹掉 ⇒
#      v0.1.13 实测 `prio_reads` **恒为 0**，那些读全掉进 `other_reads`（战斗窗口里虚高到 168/帧）。
#      新增门 `perf_channel_nesting_saves_and_restores`（同时禁止 `env.counters.ch=nil` 再出现）。
#   2) **把 `ping.observe` 再拆两段**（实测它占总读量 27% = 74.3 读/执行帧）：
#        通道 8 = actor 扫描段（Data.new + 逐 actor 读 + Authority.inspect）
#        通道 9 = **ping 环扫描段**（每个存活槽位一次 0x58 读）
#      `perf;` 新增 `ping_actor_reads=` / `ping_ring_reads=` / `ping_slots=` / `ping_actors=`
#      （后两个由 `observe()` 作为第 3/4 个返回值回报，窗口累计）。
#      ⇒ 若环段是主体，就能把**连续的槽位一次读一大块**（字节不变、调用数 N→1~2，
#        纯收益、零行为改动）。
#   ⚠ 同时记下另一条**实测判死**的结论：`obs_beyond;index=160;active=2;count=161` ⇒
#     有 G-60 落在活跃前缀之外（战斗窗口 `obs_beyond=133`）⇒
#     "把观察者扫描收窄到 active"不仅省不了，**还会漏雷** ⇒ 彻底作废。
# ★ v0.1.13 的内容（2026-10-10，用户要求"先做 1"）：**纯诊断，不改玩法**。
#   背景（v0.1.12 实测，每执行帧）：总 355.7 读，观察者 187.4（53%）、
#   **其它 147.5（41%，完全没归属）**、search 14、safe 3.5、verify 3.3。
#   ⇒ 再加 3 路通道把"其它"拆开：
#       5 = readiness（jobs_ready 里的 Readiness.capture，注释写明每次约 16 读）
#       6 = ping.observe（structure_ping / ping 的 actor 扫描，逐帧）
#       7 = priority:step（候选扫描 / 各类校验 / 原生查询）
#   `perf;` 新增 `readiness_reads=` / `ping_reads=` / `prio_reads=`，
#   并把 `other_reads` 改成"总数减去 1..7"。
#   ⚠ 只包住各自那一段：通道 7 只包 `priority:step`（`with_observation` 里的
#     `Search.capture` 是通道 2，在它内部设置 ⇒ 不重叠）。
#   ⚠ 同时记录一个**已被证伪**的结论（免得下一个人重走）：
#     v0.1.12 实测 `active == count` 在 **368/368 个窗口**成立 ⇒
#     "把观察者扫描收窄到 active"**一点都省不了**（此前估的"省 26%"作废）。
#     `obs_beyond` 因此恒为 0（那条证据行一次都没触发），下版可删。
# ★ v0.1.12 的内容（2026-10-10，用户要求"先做 1+2"）：**纯诊断，不改玩法**。
#   背景：v0.1.11 的实测把口径修准了（旧日志漏报 43%），并暴露真正的开销在观察者
#   ——实测任务局 **172 读/执行帧**，其中 `Layout.capture` 占 100（58%）。
#   1) **按调用方分路计数**（`perf;` 新增）：
#        obs_reads=    观察者 Layout.capture
#        search_reads= Search.capture
#        safe_reads=   安全区门（self() + 队友坐标）
#        verify_reads= scope.validate 复核
#        other_reads=  总数减去上面四路
#      通道在 entry 的 `read` 里按 `rdcount.ch`（**数字键**，每次读只多一次表索引）
#      归属，由 runtime 在 4 个高层边界设置 ⇒ **单项优化从此可单独验收**。
#   2) **收窄观察者扫描的前置证据**（`perf;` + 首次一条 `obs_beyond;`）：
#        观察者对**全部 count 个槽位**逐个读 24 B identity（实测 count≈49~56
#        ⇒ 约 50 读/执行帧 ≈ 总读量的 29%），而代码里已有 `active`（活跃前缀，1~9）。
#        新增 `obs_slots=` / `obs_active=` / `obs_beyond=`（窗口汇总）与
#        `obs_beyond;index=…;active=…;count=…;id=…`（首次出现）。
#        ⇒ **obs_beyond 一直是 0，才谈得上把扫描收窄到 active**（潜在省 ~26% 总读量）。
#   ⚠ 只统计、不改行为：没有任何判定、门控或写入被改动。
# ★ v0.1.11 的内容（2026-10-10，性能审查后按用户「按你的建议做」实施前 4 项）：
#   全部**只降开销、不改玩法**，且每条都配了构建期门防回退。
#   · **先修度量（审查项 #16）**：`perf;` 原来只累计 `Layout.capture` 的读，
#     而 `Search.capture` / `TargetData` / 所有 `validate()` 复验读都不计
#     （且 layout_bytes 只算第一遍）⇒ 真实读量约为它的 2 倍，优化无法验收。
#     现在在**最底层 read 包装**里计数（一处覆盖全部模块），`perf;` 新增
#     `all_reads=` / `all_bytes=`（**窗口增量**；拿不到计数器时打 -1，不静默）。
#   · **`structure_ping:self()` 按帧缓存（#1）**：原来每颗雷每帧一次完整 actor 扫描
#     （每 actor 2 次读 + entity 哈希探测 + Authority.inspect + unit(pcall) + position，
#     且每次新建一个 Data.new）。同帧内所有雷答案相同。顺带去掉那个 pcall 闭包。
#   · **avatars 列表改 ttl=3 帧缓存（#3）**：原来每帧重扫 ⇒ 新建 TargetData ⇒
#     实体缓存每帧失效 ⇒ 约 40~50 次读/帧 + ~50 张小表。精度代价 ~0.35 m
#     （玩家 ~7 m/s），半径 6~30 m 量级；`safe_players;` 新增 `ttl=` 让新鲜度可见。
#   · **帧内恒定的槽指针每帧只读一次（#2）**：root/clock/manager/records/invalid
#     原来在 with_observation（每颗每帧）、scope.validate、Search.capture、
#     TargetData.new、到达段各读一遍。⚠ `scope.validate()` 里那句**重读复核**
#     （指针是否仍等于观测时的值）**刻意保留原样** —— 缓存只用在取值处，不用在复核处。
#   ⚠ 三处**刻意没做**（都需用户拍板或有更好的理由）：
#     · `link;` 去重键里的 `state_age`（每帧 +1 ⇒ 去重恒不生效、每 tick 全量拼 400 B
#       后被白名单丢掉）—— 修了会改变 `link;` 行密度，与旧日志不可直接对比；
#     · `blast_hold;` 降频 —— 它是「玩家在圈内却零执行者」这个洞的**唯一判据**
#       （旧版「364 帧只有 5 条」正是缺陷证据，test_priority_fault_isolation.py 记着）；
#     · 每行一次 `log:flush()` —— 它是**崩溃后日志还在**的保证，本工程就是靠日志查案的，
#       代价（每行一次 write 系统调用）远小于收益。
# ★ v0.1.10 的内容（2026-10-10，用户要求）：
#   **Mod 设置的语言跟随游戏语言** —— 原话：「mod设置的语言要能跟随游戏语言变化，
#   比如说游戏语言是英语，mod设置显示的也是英语」。
#   · 新增 `src/g60/menu_text.lua`：读**游戏自己的 Text Language 设置**（game.dll 设置表）
#     → BCP 47 tag → 取对应文案；读不到就显示**英语**（fail-safe）。
#   · 菜单 API `version>=2` 时 label/description/mod 传**函数**（菜单每次打开都调用）
#     ⇒ **运行期改语言也能跟上**，不用重开游戏（实机 `menu_probe;…;version=3`）。
#   · MENU_ITEMS 里**不再有任何文案字面量**：9 项的 label/desc 全部来自 menu_text.lua
#     （`en` + `zh-Hans` 两套，`en` 必须覆盖每个键 —— 有守门钉着）。
#   · 新增取证行 `menu_lang;tag=…;src=game|default;functions=…`（判"菜单到底用了哪套文案"）。
#   · ⚠ 刻意**不查 Steam 语言**：那需要动态符号解析，而本工程构建器把它列为高危面一律禁止。
#   · 新增守门 `tests/test_menu_language.py`（15 项，含"未翻译语言必须显示英语"）。
# ★ v0.1.9 的内容（2026-10-10，全部来自用户实机反馈 + 日志判读）：
#   · **标记友方不再被炸**：旧判据 `calls.target_valid` 被证伪（它是"能不能被打"，
#     哨戒炮/补给支架有生命值 ⇒ 返回 true ⇒ 被当合法目标）。改为**敌阵营硬门槛**：
#     只有"可证明是敌人"才允许被当目标（数据源 = 游戏自己的 archetype 组件表，
#     生成器 scripts/gen_enemy_faction.py 带抽查）。虫洞/泰坦/空 ping 三条路不受影响。
#   · **安全区大幅加固**：圆心三源（实体/记录点/上次已知）、入口放宽到点式选择、
#     两个写者互斥（谁写了谁负责）、"无执行者"告警 `safe_noexec;`、
#     贴脸取消的危险距离独立成口径且**以手雷为中心**、
#     **覆盖队友**（读游戏 avatars 列表；实机 `safe_players;n=4` 验证）。
#   · **贴脸取消与取消距离从菜单隐藏**（功能保留、默认开）。
#   · 修两个**只有实机才暴露**的词法作用域 bug（`faction` 崩溃 / `pointer` 让队友
#     安全区静默失效）⇒ 新增通用门 `tests/check_local_order.py`，并接进构建期。
#   · 修一条**早就死掉的门**（test_runtime_perf 的锚点停留在 `pcall`，源码早已 `xpcall`）。
# ★ v0.1.8 的内容（2026-10-09）：**诊断**，不改玩法。
#   `frame_error` 带**出错处的调用栈** + 停机时 `errors;` 汇总 ⇒
#   那条 `pointer bound`（启动期引擎根指针未初始化，非故障）终于能归因、能计数。
# ★ v0.1.7 的内容（2026-10-09，全部实机验证）：
#   · **无敌人时也能炸毁标记虫洞** —— 强制提升 state=4（`force_lock_enabled`，
#     本工程唯一的受控写通道；实机 5 颗雷 / 5 个虫洞全部炸毁）。
#   · **ping 空地路同样支持无敌人** —— 同一套提升 + 门控把"TTL 内的 ping"
#     当成与标记同级的玩家意图（实机生效）。
#   · 改名 G-60 Bug Hole Lock → G-60 Directed Strike；清理研究脚手架。
#   ⚠ v0.1.7 是本工程第一次绕过引擎 API 直接写游戏状态；`force_lock_enabled=false` 一键回退。
VERSION = RELEASE_VERSION
# ★ 裁剪版身份：独立 GUID + 独立资源名 + 独立标题，与上游官方包互不覆盖(管理器槽位二选一)。
# ★ 2026-10-09 改名（用户拍板）：**G-60 Bug Hole Lock → G-60 Directed Strike**。
#   旧名（Bug Hole Lock）是 v0.1.6 之前的能力写照；v0.1.7 之后它不只打虫洞，而是
#   「**只打玩家点的目标**」（虫洞 / 构筑 / 泰坦 / ping 空地）—— 这也正是它与上游
#   `Smart Targeting` 的本质区别。三处名字（资源名 / 显示名 / 包名）一起改，
#   归档槽位 `ARCHIVE` 与 `GUID` **不动** ⇒ 加载器那边是原地升级，不是新 mod。
NAME = 'mods/hd2test/g60_directed_strike'
GUID = '9c1d4e77-2b83-4f6a-91e5-0d7b3a6c8f42'
TITLE = f'G-60 Directed Strike {VERSION}'
# ★ ZIP_NAME / TITLE 都从 `release_version` 派生（见文件头注释）。
#   `derived_from` 里的 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1' 指的是**上游基线**，
#   与我们的版本号无关，**不要**跟着改。
ZIP_NAME = f'G60-Directed-Strike-{VERSION}.zip'
ARCHIVE = 'Addon/9ba626afa44a3aa3.patch_0'


def resource_hash(name):
    """MurmurHash64A —— 换资源名后必须重算 archive 里的 nameHash。
    已对上游校验：resource_hash('mods/etxp/g60_small_filter') == tested-payload.resource_id。"""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def assert_alias_order(aliases):
    """★ 校验每个模块的依赖都排在自己之前。

    build.py 把每个模块包成 (function() ... end)()，并把 require('g60.X')
    替换成对应的 chunk 别名。别名在使用者**之后**定义时，模块顶层
    `local Y=require('g60.y')` 替换后就是 `local Y=Y` —— 右值取外层 nil，
    于是整条依赖链在运行期静默失效。

    真实事故（2026-09-28 11:08）：
        link;mark=531;matched=1;...;entered=0;locked=0
        structure_unavailable;...: attempt to index upvalue 'Geometry' (a nil value)
    新加的 geometry 被我排在 native_priority **之后**，而 native_priority
    顶层就 require 它 ⇒ Geometry 恒 nil ⇒ 标记读到了却永远锁不上。

    这类错误肉眼极难发现（构建通过、语法通过、单测通过），只能自动校验。
    """
    order = {name: i for i, name in enumerate(aliases)}
    for name in aliases:
        source = (ROOT / 'src/g60' / (name + '.lua')).read_text()
        for dep in re.findall(r"require\('g60\.([a-z_0-9]+)'\)", source):
            if dep not in order:
                raise AssertionError(
                    f"module '{name}' requires unknown module 'g60.{dep}'")
            if order[dep] >= order[name]:
                raise AssertionError(
                    f"module order: 'g60.{name}' (pos {order[name]}) requires "
                    f"'g60.{dep}' (pos {order[dep]}) but is defined LATER. "
                    f"build.py inlines modules as local chunk aliases, so the "
                    f"dependency would be nil at run time. Move 'geometry'/etc "
                    f"before its users in compat/build.json aliases.")


def assert_local_order():
    """★ 校验没有任何 `local` 在"声明之前 / 声明所在块之外"被使用（2026-10-10）。

    事故（同一类坑咬了两次，都只有实机才暴露）：
      ① `local function faction` 定义在 `if structure_ping then` 块**内部**，
         而兜底 veto 那处调用在该块**闭合之后** ⇒ 取到全局 = nil ⇒
         `frame_error;…:8960: attempt to call global 'faction' (a nil value)`，
         每触发一次就中止当帧剩余全部处理。
      ② `local function pointer` 在第 683 行，而 players_scan 在第 242 行就用它 ⇒
         `safe_players;n=0;reason=…:7297: attempt to call global 'pointer' (a nil value)`
         ⇒ **队友安全区整段静默失效**。

    与 assert_alias_order / assert_field_refs 同类：luac 通过、单测通过、只有实机炸。
    三者一起构成"构建期必须拦住的语义错误"关卡。
    """
    proc = subprocess.run(
        [sys.executable, '-B', 'tests/check_local_order.py'],
        cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AssertionError(
            'local scope order check failed:\n' + proc.stdout + proc.stderr)


def assert_field_refs():
    """★ 校验跨模块字段引用真实存在（2026-09-28 11:40 实机事故的直接修复）。

    事故：native_priority.lua 的 takeover_probe 里写
        local life=math.max(0,1-spent/Policy.lifetime_ticks)
    而该文件的 `Policy` 是 g60.target_policy（第 6 行），
    `lifetime_ticks` 属于 g60.arrival_policy（第 8 行才 require）。
    Lua 对 nil 做算术 ⇒
        attempt to perform arithmetic on field 'lifetime_ticks' (a nil value)
    **每一帧**都抛错，被 runtime 的 pcall 吞成 structure_unavailable，
    于是「标记读到、G-60 到 state 4，却一次都锁不上」。

    与 assert_alias_order 同类：这类错误 luac 通过、单测通过、只有实机炸。
    两者一起构成"构建期必须拦住的语义错误"关卡。
    """
    proc = subprocess.run(
        [sys.executable, '-B', 'tests/check_field_refs.py'],
        cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AssertionError(
            'cross-module field check failed:\n' + proc.stdout + proc.stderr)


def assemble():
    aliases = CONFIG['aliases']
    assert_alias_order(aliases)
    assert_local_order()
    assert_field_refs()
    modules = []
    for name, alias in aliases.items():
        source = (ROOT / 'src/g60' / (name + '.lua')).read_text()
        for key, value in aliases.items():
            source = source.replace("require('g60." + key + "')", value)
        modules.append('local ' + alias + '=(function()\n' + source + '\nend)()')
    for alias, filename, factory in [
        ('Binding', 'native_search_binding.lua', False),
        ('TitanProfile', 'titan_profile.lua', False),
        ('WeakpointProfiles', 'weakpoint_profiles.lua', True),
        ('StructureProfiles', 'structure_profiles.lua', True),
        # ★ 变体 profile（2026-09-29）：工厂函数，拿 TitanProfile 作为基线。
        #   与 structure_profiles 复用 common.getters 是同一机制。
        ('TitanVariants', 'titan_variants.lua', True),
        # ★ 体内爆点名册（2026-10-03）：与虫洞的"距离<4m"机制**分开**，
        #   见 compat/blast_sites.lua 文件头。无需工厂参数。
        ('BlastSites', 'blast_sites.lua', False),
        ('PriorityCatalog', 'priority_catalog.lua', False),
        ('FuseProfile', 'fuse_profile.lua', False),
    ]:
        source = (ROOT / 'compat' / filename).read_text()
        modules.insert(-1, 'local ' + alias + '=(function()\n' + source + '\nend)()'
                       + ('(TitanProfile)' if factory else ''))
    text = (ROOT / 'addon/entry.lua.in').read_text().replace('@@MODULES@@', '\n'.join(modules))
    text = text.replace('@@VERSION@@', VERSION)
    # ★ 两个占位符语义不同，别混（2026-10-01）：
    #   @@VERSION@@          = **本裁剪版的发布版本**（RELEASE_VERSION）—— "这是哪一版 mod"
    #   @@RUNTIME_BASELINE@@ = **上游运行时基线**（build.json 的 runtime_version，0.5.20）
    #                          —— "基于哪一版上游运行时"
    #   以前 @@VERSION@@ 填的是 runtime_version，日志写 `version=0.5.20-bughole`，
    #   与本 mod 的版本（当时已到 0.1.2）完全不是一回事，排查时容易误判。
    text = text.replace('@@RUNTIME_BASELINE@@', CONFIG['runtime_version'])
    text = text.replace('@@GAME_GUARDS@@', CONFIG['game_guards_lua'])
    text = text.replace('@@ENGINE_CODE@@', CONFIG['engine_code'])
    # ★★ 2026-10-09 受控例外（用户明确拍板"走写内存这条路"）★★
    #   `WriteProcessMemory` 从"一律禁止"改为**计数式允许**：
    #     · 恰好 1 处调用（`.WriteProcessMemory(`）—— 防被顺手复制到别处；
    #     · 全文提及 ≤ 2 次（cdef 声明 + 那唯一一处调用）。
    #   配套硬边界写在 addon/entry.lua.in 的 write() 与 src/g60/native_priority.lua
    #   的 promote_state4 里，并有守门钉着：单次 ≤64 字节、写前复核 + 写后回读、
    #   只允许用于状态记录的 3 个 dword（state/behavior/mid）。
    #   其余高危能力（VirtualAlloc / VirtualProtect / LoadLibrary / GetProcAddress /
    #   MinHook / ffi.copy）**仍然一律禁止** —— 那些才是真正的高危面。
    assert text.count('.WriteProcessMemory(') == 1, (
        'WriteProcessMemory 必须恰好 1 处调用（受控例外），实际 '
        + str(text.count('.WriteProcessMemory(')) + ' 处')
    assert text.count('WriteProcessMemory') <= 2, (
        'WriteProcessMemory 全文提及不得超过 2 次（cdef + 调用点），实际 '
        + str(text.count('WriteProcessMemory')) + ' 次')
    for forbidden in ('VirtualAlloc', 'VirtualProtect', 'LoadLibrary',
                      'GetProcAddress', 'MinHook', 'ffi.copy', "require('g60.", '@@'):
        assert forbidden not in text, 'Unexpected runtime capability: ' + forbidden
    assert 'native_lifetime_verified=true' not in text
    return text.encode()


def archive(body):
    # ★ 不再从上游 evidence/tested-payload.json 取 resource_id —— 那个值属于上游资源名。
    #   这里按本工程的 NAME 现算，避免"换了名字却还用旧 hash"导致 loader 认不出资源。
    resource_id = resource_hash(NAME)
    lua_type = 0xA14E8DFA2CD117E2
    offset = 192
    payload = struct.pack('<II', len(body), 2) + body
    size = (offset + len(payload) + 15) & ~15
    result = bytearray(size)
    struct.pack_into('<III20sQQ24s', result, 0, 0xF0000011, 1, 1, b'', size, 0, b'')
    struct.pack_into('<IIQIIII', result, 72, 0, 0, lua_type, 1, 0, 16, 16)
    struct.pack_into('<7Q6I', result, 104, resource_id, lua_type, offset,
                     0, 0, 0, 0, len(payload), 0, 0, 16, 16, 0)
    result[offset:offset + len(payload)] = payload
    return bytes(result)


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode()


def package_files():
    entry = assemble()
    body = ('-- HD2-Addon: ' + NAME + '\n').encode() + entry
    files = {ARCHIVE: archive(body), ARCHIVE + '.stream': b'', ARCHIVE + '.gpu_resources': b''}
    title = TITLE
    description = ('Bughole-only build. When YOU mark one of the nine supported bug holes '
                   '(eight normal nests plus the large colony hole used by the Bile Titan nest), '
                   'the grenade is redirected to detonate there and interrupts whatever enemy '
                   'lock the game had chosen. With no bug-hole mark this addon does nothing and '
                   'G-60 keeps the game native targeting. Enemy priority, tuned weakpoints, '
                   'Shrieker Nest, Spore Spewer and objective eggs are all removed. '
                   'Experimental original native calls; requires Bingus Shared Loader API 1. '
                   'Mutually exclusive with the upstream HD2-G60-Smart-Targeting package '
                   '(enable one or the other, not both).')
    files['manifest.json'] = json_bytes({'Version': 1, 'Guid': GUID, 'Name': title,
        'Description': description, 'Options': [{'Name': title, 'Description': description, 'Include': ['Addon']}]})
    # ★ 只打"仍然成立"的文档。上游 README / docs / CHANGELOG 描述的是完整功能
    #   (自动敌人优先级、弱点、尖啸者巢、任务虫卵)，与本裁剪版不符，打进去会误导使用者。
    for pattern in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md'):
        for path in ROOT.glob(pattern):
            if path.is_file():
                files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    files['Source/' + NAME.rsplit('/', 1)[-1] + '.lua'] = body
    files['BUILD-INFO.json'] = json_bytes({'version': VERSION, 'runtime_baseline': CONFIG['runtime_version'],
        'derived_from': 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1',
        'entry_sha256': sha(entry), 'resource_name': NAME, 'resource_id': f'{resource_hash(NAME):016X}',
        'bughole_profiles': 9,
        'addon_sha256': {n: sha(b) for n, b in files.items() if n.startswith('Addon/')}})
    return files


def write_zip(path, files):
    path.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(path, 'w', compression=ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            info = ZipInfo(name, (2026, 9, 27, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, data)


def main():
    files = package_files()
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/entry.lua').write_bytes(assemble())
    # ★ 本工程基线：上游 check.py 那套"产物必须与 release 逐字节一致"的断言对裁剪版
    #   必然不成立（我们就是来改的）。这里记录本工程自己的 entry / addon 哈希，
    #   供 check.py 与之后的改动做回归比对。
    derived = {'derived_from': 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1',
               'resource_name': NAME, 'resource_id': f'{resource_hash(NAME):016X}',
               'entry_sha256': sha(assemble()),
               'addon_sha256': {n: sha(b) for n, b in files.items() if n.startswith('Addon/')}}
    (ROOT / 'evidence').mkdir(exist_ok=True)
    (ROOT / 'evidence/derived-payload.json').write_text(json.dumps(derived, indent=2) + '\n')
    target = ROOT / 'dist' / ZIP_NAME
    write_zip(target, files)
    print(json.dumps({'package': str(target.relative_to(ROOT)), 'sha256': sha(target.read_bytes()),
                      'entry_sha256': derived['entry_sha256'],
                      'resource_id': derived['resource_id'],
                      'resource_name': NAME, 'guid': GUID}, indent=2))


if __name__ == '__main__':
    main()
