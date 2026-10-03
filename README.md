# G-60 Bug Hole Lock —— 标记虫洞 / 大型虫族 专用版

《绝地潜兵2》G-60 反坦克追踪者手雷的**目标专用**接管 mod：只接管**玩家标记的虫洞 / 构筑物**与
**吐酸泰坦 / 孢子泰坦 / 蟑龙**（外加"玩家点名的任意目标"），其余全部交还游戏原生。
唯一例外是"不让 G-60 追踪**运输船 / 光能族增援飞船**"（可一键关闭）。

> **当前版本 v0.1.6**。版本号的**唯一来源**是 `scripts/build.py` 的 `RELEASE_VERSION` ——
> `TITLE`（manifest 显示名）、成品包文件名、`BUILD-INFO.json`、日志里的 `version=` 全部由它派生。
> 发新版**只改那一个常量**。
> （`compat/build.json` 的 `public_version` 是**上游**的版本，与本裁剪版无关。）
>
> 派生自 [`etxp/HD2-G60-Smart-Targeting`](https://github.com/etxp/HD2-G60-Smart-Targeting) 0.1-beta.1
> （源码 MIT）。裁剪只动**决策层**；**签名守卫、持锁窗口、状态机白名单、身份复验等安全机制原样保留**。
> 上游原始说明见 `README.upstream.md` / `README.upstream.zh-TW.md`（**不打进包**）。

---

## 它做什么

**你标记什么，G-60 就去炸什么。**

| 情况 | 行为 |
|---|---|
| 你标记了 16 个虫洞之一 | **接管**：打断当前敌人锁定，改朝该虫洞飞，到达后引爆 |
| 你标记了**吐酸泰坦 / 孢子泰坦 / 蟑龙** | **接管**：各走为体型标定的航路，在标定位置引爆（几何**不由引擎算**） |
| 你标记了**巨型构筑者**（Bulk Fabricator，机器人大型构筑物） | **接管**：引擎 `aim` 落在它**底部（地表/地下）**炸不掉 ⇒ 改用**体内爆点**（实体原点 + `lift`），见下节 |
| 你标记了**任何其它目标**（敌人 / 建筑 / 运输船 / 增援飞船…） | **接管**：强制飞向它并引爆。**引爆位置由引擎决定**（`calls.aim`），本 mod 不算几何 |
| **你 ping 了一片空地** | **接管**：ping 槽里存着那点的**世界坐标**，写成"点目标"，G-60 飞过去炸 |
| 引擎自己选中了吐酸泰坦 / 蟑龙（你没标记） | 同上接管 |
| **你标记了友方目标**（信标球 / 撤离机 / 平民…） | **不接管**（见"友方如何排除"） |
| 引擎给 G-60 选了**运输船 / 光能族增援飞船**（你没标记） | 清掉该选择（`enemy_veto_enabled`） |
| 你 ping 的单位标记**从画面上消失**后 | **不再被新接管**；已在飞向它的那颗照旧炸完 |
| 你没标记任何东西 | **完全不插手**，G-60 按原生 TargetLock 打敌人 |

优先级：**虫洞/构筑 > 标记单位 > 空白标记**（见"目标优先级"）。同类之间**不互相抢**。

---

## ★ 体内爆点：巨型构筑者（2026-10-03）

**用户实测三条（决定性）**：①「G60 会在巨型构筑者的**底部**引爆，但**不会造成伤害**」；
②「虫巢只要引爆点小于 **4 m** 就能摧毁，**巨型构筑不行，不能参考虫巢的引爆点计算**」；
③「通风口只是**入口**，G60 是**穿模进入**的，不会受到阻拦，你只要找到**拆毁机制的区域**就行了」。

**根因**：本 mod 对"未登记目标"的既有做法是**把引爆位置交给引擎**（`calls.aim`）。
对**虫洞**够用（摧毁判定是**距离** <4 m，`aim` 落在洞口附近）；对**巨型构筑者不成立** ——
它要求爆炸**进入模型体内**，而 `aim` 落在**实体原点**（在地表/地下）⇒ 炸在底部、掉不了血。

**改法**：名册 `compat/blast_sites.lua`（**只登记"必须炸进体内"的目标**）。命中时用
**`实体原点 + lift`** 算体内点，按**点目标**交给 arrival —— 与"ping 空地"**同一条已验证路径**
（`invalid_id` + 三维坐标 + 自己的 `region`）。

| 项 | 值 / 说明 |
|---|---|
| 目标 | `4232ee48e2cfd24e` = `content/env_cyborg/gameplay/colony_cyborg_spawner/cyborg_colony_spawner_base`（机器人阵营的"虫巢"同族构筑物） |
| 身份来源 | 离线 MurmurHash64A 反查 10.7 万条名字库 + Darctor `Hash.csv`（机器人-杂项 / Bulk Fabricator / 巨型构筑者）**两处一致** |
| **`lift`** | 相对**实体原点**向上多少米。**定稿 8.0** |
| **`region`** | 本目标专用到达区域 = `radius 1.5 / depth 0.25 / above 0.6`（即窗口 **[7.75, 8.60]**）；ping 那套默认是 `3.0/2.0/2.0` |
| **`scan`** | 标定档位表，**当前为空 `{}`** = 标定完成、走单一 `lift`。要再扫就填一组**递增**数（≥4 档、把 `lift` 夹在中间），**每颗新的 G-60 换一档** |
| 开关 | `blast_sites_enabled`（默认 true；false ⇒ 退回引擎 aim） |
| 状态行 | `blast_sites=true;blast_site_lift=8;blast_site_region=1.5/0.25/0.6;blast_sweep=off` |
| 读不到位置时 | 不启用（退回引擎 aim）—— **绝不**让一次读失败变成"不引爆" |

### 为什么是这两个数（实测数据，不是估的）

**判定区高度 —— 扫出来的，不是猜的。** 逐颗换档扫高度，唯一一组单变量对照（同一个构筑 444）：
**6.5 ✗ / 8.0 ✓**；另有一次 **9.55 ✗** ⇒ 判定门槛落在 **(5.66, 7.75] m**，上界 <9.55。
定的 **8.0** 使实际爆心落在 **8.2~8.4**（4 次成功实测：8.20 / 8.41 / 8.22 / 8.27，离散 ≤0.21 m）。
> 试错链（**别再走**）：`4.0`「太靠下」→ `7.5`「打不到」—— 中间没有可推依据，
> 而 7.5 的实际爆心 6.73~7.80 **恰好卡在判定下沿之外**，这就是"两局一颗都拆不掉"的原因。

**竖向窗口为什么是 `depth 0.25 / above 0.6`**：
- **下沿紧**（`lift-depth` = 7.75 = 实测最低成功值）：门槛是**陡崖**，窗口放宽到 1.0 就会有相当概率炸在
  7.0（崖下）⇒ **偶发失效**。
- **上沿留余量**（`lift+above` = 8.60）：实测**过冲范围 0 ~ +0.45** ⇒ 上沿至少要高 0.5。
  曾把 `above` 收到 0.2，结果把"轻微过冲"这种**正常情况**也拒了：一颗 48 m 远抛冲到爆点上方
  **0.42 m** 被判"未到达"，之后绕高到 10.5 m 不返 ⇒ 4 秒 stall ⇒ 交回引擎（= 在底部引爆）。
  ⇒ **窗口的"紧"要双向度量，不是单向越小越好。**
- **`radius` 保持 1.5 不动**：成功的水平偏移 1.35~1.49、失败的 1.44~ ⇒ **无区分度**，
  动它就是同时改两个变量（本项目纪律：**一次只改一个变量**）。

**拆毁力数值天生够**：G-60 爆炸（离线表）`ExplosionType 351 → damageId 345`
= `damage 1800 / structDamage 1800 / **destroy(拆毁力) 40**`，内半径 4 m / 外半径 12 m；
用户实测"通风口附近有拆毁路径，**20 拆毁就够**" ⇒ 差的是"爆炸中心落进那 4 m 内半径"。

### 两条辅助事实（避免以后重复调查）

- ★★ **与虫洞是两套机制，不要互相套用**：虫洞 = **距离判定**（<4 m）；构筑物 = **进入体内**。
  名册里**不得**出现 `offset` / `front_distance` / `kind="structure_hole"` 那套几何
  （守门 `blast_sites_does_not_copy_hole_offsets`）。
- ★ **手雷会被"导上去"**：`blast_guide` 的 `above_origin` 随帧持续爬升（如 1.51→6.15、4.23→7.46）
  ⇒ 点目标确实在操舵，抛得平也能被拉上来；**但窗口必须先接得住它**。
- ★ **`dz` 判不出"离腹部/爆点多远"**：目标点会被地面净空抬高 ⇒ 只看 `above_origin` / `belly_dz`。

> **标定完已删的一次性工具**（留档，别再加回）：`scene_probe` / `scene_motion`（运动记录整段 hex 转储，
> 用来找模型朝向 —— 朝向**最终从未被使用**，改走 region 路线）、`scripts/probe_unit_size*.py`（离线读
> `unit_size`/血量 —— `generated_entities.dl_bin` 是**按资源的模板库**，不含实例状态，此路已弃）。
> 守门 `blast_probe_no_scene_dump_left` 禁止前者回归。
> **保留**的诊断：`blast_point`（每颗一条）· `blast_hit`（每颗一条，实际爆心）·
> `blast_guide` / `blast_stalled`（约每 60 帧一条）—— 这三组是"打没打准"的唯一量化依据。

---

## ★ ping 空地 ⇒ 指哪打哪（2026-10-01）

玩家 ping **空地**（标记不到实体）时，引擎把**那个位置的世界坐标**存在 ping 槽里（`+0x04` float3）。
开启 `point_target_enabled` 后，本 mod 把它写成**点目标选择**（`invalid_id` + 坐标，与泰坦路径同款写法），
G-60 就会飞过去、到点引爆。

| 前提 | 说明 |
|---|---|
| **附近必须有敌人** | G-60 得先被引擎驱动到 state 4（见"使用前提"）。**没敌人时它停在弹道模式，标什么都不飞** |
| 必须是"ping 到空地" | ping 到实体时走实体接管路径（更精确） |
| `point_target_ttl_frames`（默认 1200 帧 ≈ 20 秒） | ⚠ **只约束"新接管"**：已在飞向该点的那颗不受 TTL 影响，直到标记从 ping 环消失 |

> ★ **两个踩过的坑**（都已修）：① **不能把"虫洞优先"写成全局开关**（否则 ping 过一次虫洞之后，
> 后面所有 ping 全都不生效）；② **TTL 不能管"已经在飞的那颗"**（否则半路被丢掉、永远不炸 ——
> "时灵时不灵"的来源之一）。
> ★ **多个空标记并存 ⇒ 取 `age` 最小（= 最近 ping）的那个**：ping 环是**环形复用**的，
> "最后扫到的槽"≠"最后 ping 的"。取不到 `age` 时回退旧行为。纯**选择**逻辑，不多读一个字节。

日志：`point_marker;slot=…;pos=…;age=…` · `point_taken;entity=…;pos=…` · `point_guide;…;dist=…`（每 60 帧）·
`point_stalled;…`（4 秒没满足到达）· `point_armed;…` · `point_released;entity=…`。

---

## ★★ 目标优先级（2026-10-01 用户定，三档）★★

```
① 虫洞 / 构筑（你标记的建筑）    ← 最高
② 标记单位（你点名的任何其它目标）
③ 空白标记（ping 到空地的坐标点） ← 最低
```

**按"每颗 G-60"判**，不是全局开关。让位规则：

| 情况 | 行为 |
|---|---|
| 在飞往**单位**的 G-60，出现**新近**的结构标记 | **让位**（`unit_lock_yielded;…`）。⚠ 只在"让位这帧真的拿得到结构"时生效；拿不到（超距 / 已被别的 G-60 预约）就**继续驱动原锁**，不丢锁不白飞 |
| 在飞往**虫洞**的 G-60，出现单位标记 | 不让位（虫洞最高） |
| 在飞往**空白点**的 G-60，出现任何标记 | 立刻让位 |
| 引擎给这颗选中了泰坦/蟑龙，但这颗已锁定你点名的目标 | **标记优先**，泰坦让位 |
| 引擎给这颗选中了泰坦/蟑龙，这颗没有标记锁定 | 让泰坦接管（附加能力） |
| 同层之间（虫洞↔虫洞 / 单位↔单位） | **不互相抢**（飞行途中被劫持 ⇒ 前一个目标没人负责 ⇒ "时灵时不灵"） |

> ★ **"让位"只认新近标记**（本帧 ping 环里还看得到它）—— **记忆里的旧标记不参与让位**，
> 否则一个很久以前标记的虫洞会在记忆存续期内反复夺走之后每一颗 G-60。

## ★★ 标记队列的**内部排序**（2026-10-02 用户：「标记敌人单位时，泰坦的优先级不是最高的」）★★

**根因**：标记目标那条队列（`structure_ping`）默认**按新旧排**（队首 = 最晚 ping 的）⇒ 后 ping 的
小怪会盖住泰坦。名册 `compat/priority_catalog.lua` 里本来就有 rank，但**那条（自动索敌）路径本工程早已裁掉**
⇒ 标记路径上**根本没有"重量级"概念**。

**改法**：`native_ping` 新增可选钩子 `options.priority(mark) -> number`（**数值小的先**），
runtime 只把它给**标记目标**那条队列，并定死**五档**：

| 档 | 谁 | 值 |
|---|---|---|
| ① | **虫洞 / 构筑** | `0`（用户定的最高档，**不能被下面的 rank 顶掉**） |
| ② | **蟑龙** | `500` |
| ③ | **泰坦**（含变体） | `1000` |
| ④ | 名册里的其它敌人 | `1000+rank`（蟑龙 10 ⇒ 1010 … 冲锋者 50 ⇒ 1050） |
| ⑤ | 名册外的其它单位 | `1500` |
| — | 连 `resource` 都读不到 | `2000` |

- **相等优先级保持原顺序**（= "最新 ping 优先"）：用严格 `<` 逐个比较，**不用 `table.sort`**（不稳定）
- **只在"最优不是队首"时才替换** ⇒ 队首本来就最优 / 未提供钩子 ⇒ **零行为变化**
- ⚠ 只影响**玩家标记**那条队列；空白标记与引擎自选**完全不受影响**
- ⚠ 蟑龙**必须复用准入判据**（`dragonroach_enabled` + 精确资源哈希），**不许按 `kind` 推断** ——
  "能瞄准谁"与"谁优先"要同一把尺子，否则会"优先了却瞄不了"
- 开关 `marked_unit_rank_first`（默认 `true`；false = 回到纯"最新 ping 优先"）

## ★★ 标记取消即失效（单位 2026-10-01 · 结构/泰坦/变体 2026-10-02）★★

标记从画面消失后，记忆里那条**不再产生新的追踪**（否则就是"取消标记后 G-60 仍追它"）。
两个开关（默认 `true` = 只认活标记；false = 回到"长期记忆"旧行为）：
`unit_mark_live_only`（通用**单位**）· `structure_mark_live_only`（**结构 / 泰坦 / 变体**）。

- **新**接管受影响；**已在飞向它**的那颗**不受影响**（持有 `old.lock`，会继续炸完）。
- ⚠ **权衡（知情）**：ping 之后**超过标记存活时长**（UI 约 8 秒）才扔 ⇒ 结构标记已过期 ⇒ 不再接管。
  想保留"ping 完慢慢扔"的习惯，把 `structure_mark_live_only` 置 `false`。

---

## ★★ 使用前提：虫洞附近必须有**敌人**（引擎机制，不是 mod 故障）

本 mod **不创造** G-60 的追踪能力，只是"改写引擎已经分配给它的目标"。而 G-60 的原生追踪逻辑
**只在引擎已经给它分配了目标时才激活**：接管前必须通过 `native update excluded` 检查
（**硬断言**），日志里看 `link;…;g60=<n>;eligible=<n>` —— 只有 `eligible≥1` 的帧才出现 `entered=1`。

**⇒ 想炸虫洞，请确保虫洞附近（G-60 索敌范围内）有敌人。** 空地上扔不会有反应。

> ★ **2026-10-01 专项探查结论**：无敌人时 mod 侧**三条"绕过"路径全部不行** ——
> 原生 setter（写了但行为不变）· `orbit` 写导航目的地（11/11 调用成功、destination 确实变了，
> 但 `path_agent` 始终 false）· 裸写内存（本 mod **不具备**写内存能力）。
> **机制结论**：state 2/3 的 G-60 处于**弹道飞行模式**（没有寻路代理），**既不读 selection 也不读导航目的地**
> ⇒ 早期 state 改任何目标数据都无效。诊断开关 `early_nav_probe` / `early_nav_orbit`（默认**关**）。

## 友方如何排除（2026-09-30）

通用接管用 `calls.target_valid`（引擎索敌"能不能把它当锁定目标"）作**硬门槛** ⇒ 友方返回 false ⇒ 不接管。
⚠ 与**虫洞路径正好相反**：虫洞因为没有 `HealthComponent` 也被判 false，所以那边把它降级为**软信号**
（见"修复记录索引"第 2 条）。**通用目标不需要绕过索敌** ⇒ 正好用它当硬门槛。

- ★ **唯一例外**：玩家**点名标记**运输船 / 光能族增援飞船时放行（它们是**载具**，索敌同样判 false，
  但用户要求"标记了就要飞过去炸"）。例外只对 `small_filter.marked_allowed`（当前恰好那两项）生效 ⇒
  标记**信标球 / 鹈鹕撤离机 / 平民**照样被拒。
- 排除表（`small_filter`）**仍然生效** —— 但只针对**引擎自己选中**的场景。

### 引擎选择否决的排除表（**每一项都必须带实机日志证据**）

"名字对得上"**不等于**"就是那个哈希" —— 社区表说它是运输船、实体表里也存在，都不足以证明
"引擎会把 G-60 指向它"。**唯一判据是实机日志里真的出现过的哈希**。当前恰好两项：

| 资源 | 是什么 | 证据 |
|---|---|---|
| `db90077e76faa025` | 机器人运输船 `cyborg_dropship` | `enemy_selection;entity=933;resource=db90077e76faa025` |
| `74e2285c01da4f71` | **光能族增援飞船** `illuminate_dropship` | `enemy_selection;entity=1241;resource=74e2285c01da4f71` |

- ⚠ **只排除"增援"那一艘，不是"光能族飞船全排除"**：**营地穿梭舰** `b3c9cdb79dc17937`
  （Warp Ship Landed）**不在表里** —— 它是玩家会**主动标记去炸**的目标（实机同一局：`structure_mark ACCEPTED` 6 次
  + `priority_locked` 14 次）。用户特意强调过"**注意是增援的飞船**"。
- ⚠ **不得**排除 `7b0f8449ca9d2da0`（`shuttle_dropship` = 鹈鹕 MK2，**玩家自己的撤离机**）——
  守门 `veto_list_excludes_friendly_pelican` 钉住。
- 两个**无证据**的变体**没有加**：`2ad2e055dad21f6e`（入侵的穿梭舰）、`01fe503dcd17847b`
  （营地的穿梭舰另一个 id）—— 日志里从未被引擎选中过，加了可能误伤玩家想炸的那艘。
- **只清不接管**：不建 `tracked`、不设 `lock` ⇒ 三条引导与引爆路径都碰不到它；走 `runner` 的 search 动作
  （复用已实机验证的路径），**立刻 `runner:release`**（否则 `searching[key]` 恒真 ⇒ 每帧强行 `orbit`，
  把"不追踪"变成"一直盘旋"）。`enemy_veto_enabled=false` 一键回退。

## 开关一览

| 开关 | 默认 | 作用 |
|---|---|---|
| `titan_enabled` / `titan_variants_enabled` / `dragonroach_enabled` | true / true / true | 分别关泰坦 / 变体 / 蟑龙 |
| `generic_takeover_enabled` | true | 关掉 ⇒ 通用接管失效（退回"只打虫洞/泰坦/变体"） |
| `blast_sites_enabled` | true | 关掉 ⇒ 巨型构筑者退回引擎 aim |
| `point_target_enabled` | true | ping 空地 ⇒ 点目标接管 |
| `enemy_veto_enabled` | true | 不让 G-60 追运输船 / 光能族增援飞船 |
| `unit_mark_live_only` / `structure_mark_live_only` | true / true | 标记从画面消失后不再被新接管 |
| `marked_unit_rank_first` | true | 标记队列按"虫洞 < 蟑龙 < 泰坦 < 名册敌人 < 其它"排序 |
| `titan_standoff` / `titan_standoff_min` | 2.5 / 2.0 | 泰坦爆距与自适应下限（见"已知限制"） |
| `titan_belly_above` | 0 | 泰坦"腹部上方引爆"余量，**已关闭**（回上游标定窗口） |
| `titan_arrival_region` | `{radius=1.5, depth=1.2, above=1.2}` | 泰坦到达判定（圆柱） |
| `scan_every_busy` / `scan_every_idle` | 2 / 6 | 观测节流档位（见"性能"） |
| `allow_state3` | false | 是否对 state 2/3 的 G-60 写早期驱动 |
| `early_nav_probe` / `early_nav_orbit` | false / false | "无敌人时能否接管"的探查（后者是**写**操作，谨慎） |

> 上游那套「按固定顺位自动追打 Bile Titan / Impaler / …」与「按部位弱点瞄准」**已全部移除** ——
> 本 mod **不做顺位挑选、不做自动选择**，通用接管只处理**玩家明确标记**的目标。

---

## 支持的 16 个虫巢（9 基线 + 7 变体）

- **8 种普通虫洞**：scavenger / spitter / warrior / hiveguard / hunter / boomer / prowler / stalker
- **1 个大型 colony 洞** = `bug_spawner_bile_titan`（**泰坦巢**）使用的模型
- **7 个变体**：warrior_captive / warrior_ceiling / warrior_tutorial / scavenger_captive / bug_spawner_base
  （均复用对应基线）+ mechanical_bughole / mechanical_bughole_scavenger（⚠ 无同模型基线，用最保守通用爆点；
  若炸不塌删掉那两行即可，其余不受影响）

**不接管**：Shrieker Nest（尖啸者巢）· 普通/大型 Spore Spewer（孢子菇）· `embryo_01`（任务虫卵）
—— 它们不是虫洞。

> ★★ **判定"是不是虫洞"必须用独立来源**（游戏资源路径 / 社区表），**不能用自己的标签**：
> 尖啸者巢 `095686275a113614` 曾被误当成虫洞恢复（理由是"它能被 ping"= 把"可标记"错当成"是虫洞"），
> 而当时"核实"用的证据是"17 项都是我们标的 `kind="structure_hole"`" —— **循环论证**。
> 现由用户要求移除，测试里有两条防线（点名断言 + 用游戏路径反查"每条都是 `bug_spawner_*`/`mechanical_bughole`"）。

## 支持的敌人（3 种）

| 敌人 | resource | 航路 | 几何来源 |
|---|---|---|---|
| **吐酸泰坦** Bile Titan | `9e2e17f2ccccafdd` | `titan_route`（RADIUS=12 / standoff 2.5） | 自有 profile |
| **孢子泰坦** Spore Burst Bile Titan | `ef04cb84d097a497` | 同上（**借用**） | **借用**基线泰坦 |
| **蟑龙** Dragonroach | `960b48a421a3faaa` | `weakpoint_route` 的 **thorax** 分支（standoff 2.5） | 自有 profile |

**孢子泰坦为什么能"借用"** —— 资源路径哈希反查给出确凿证据（同一 `unit` 目录 = 同一模型）：

```
ef04cb84d097a497 → content/fac_bugs/cha_strider/cha_strider_gloom
9e2e17f2ccccafdd → content/fac_bugs/cha_strider/cha_strider
```

⇒ 借用基线的 `boss_hash` / `belly_hash` / `offset` / `alive_rva` / `engine_guards` /
`getters`。**失败是 fail-closed 的**：`titan_context` 在写任何字节之前校验身份 / 类 / 场景图锚点，
不符则记 `titan_skipped` 直接放弃 ⇒ **不会写错位置**。
变体是**逐个显式登记**的（`compat/titan_variants.lua`），不做"同目录批量借用"。

> **蟑龙的飞行适配是上游自带的**：`weakpoint_route` 的 thorax 分支**没有地面净空检查**（源码注释：
> *"Dragonroach can be airborne; its root is not a terrain-height sample."*）⇒ 我们只做了"放行资源"，几何一个字没改。
> **泰坦**用的是上游 `titan_profile.lua` + `titan_route.lua` 里本来就为泰坦标定的几何，不是照抄别人的参数。
> **到达判定形状**：试过"球形"（各向同性），实机**明显变差** ⇒ 已回滚为上游**圆柱**（水平 `dx²+dy² ≤ r²`
> 且 `-depth ≤ dz ≤ above`）。形状不再动，只调数值。

**不接管**：`weakpoint_profiles.lua` 里另外登记的 5 种（穿刺者 Impaler、孢子冲锋兵 Spore Charger、
冲锋兵巨兽 Charger Behemoth ×3、冲锋兵 Charger）—— 仍由引擎原生 TargetLock 处理。
放行用的是**精确资源哈希**，不按 `kind` 推断（按 kind 会把同类型其它敌人一起拉进来）。

---

## 安装

> ### 📦 成品包下载
> **[GitHub Releases › 最新版](https://github.com/LovedeHua/HD2-G60-BugHole-Lock/releases/latest)**
> —— 下载 `G60-BugHole-Lock-0.1.6.zip` 直接导入 mod 管理器。（本仓库只有**源码**，成品包在 Releases 附件里。）

1. 关闭游戏，安装 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)
   （**API 1，v15+**，需 addon discovery）。
2. 把 `G60-BugHole-Lock-0.1.6.zip` 导入 mod 管理器。
3. **与上游官方包二选一** —— 两个包都会改 G-60 的决策，同时启用会打架。
   本包 GUID `9c1d4e77-…`，官方包 GUID `58a16a67-…`。
4. Purge / Deploy 后重启游戏。

> ⚠ **装完先看 `G60BugholeLock.log` 的开头几行** —— 有 `version=<版本>-bughole;…` 才算加载成功。
> 一行都没有 = **没生效**（没进 addon 发现列表，或产物编译失败），**此时任何"调参"都无意义**。
> 那一行同时给出 `runtime_baseline=0.5.20`（**上游运行时基线**，与本 mod 版本不是一回事）。
>
> ★★ **启动状态行拆成 3 段**（2026-10-03）★★ —— 原因：`emit` 有 **900 字符**上限，而状态行早已超 1000 字符
> ⇒ 实机日志里它被**从中间切断**，其后所有字段（含 `unit_mark_live_only` 等）一个字都没打出来（"承诺了却看不到"）。
>
> | 行 | 内容 |
> |---|---|
> | `version=…` | 版本 / 运行时基线 / 特性开关（build、scope、gates…） |
> | `titan_settings;…` | 泰坦参数 + 蟑龙 + 否决表（`titan_standoff` … `titan_resource`） |
> | `mark_settings;…` | 标记存续与档位开关（`unit_mark_live_only` / `structure_mark_live_only` / `marked_unit_rank_first`） |
> | `status_len;core=…;titan=…;marks=…;cap=900` | **自报各段长度** ⇒ 将来再变长也能一眼看出被切（> `cap` 即被切） |
>
> **字段名一个都没改**（文档与脚本按名 grep），例如 `grep -E "^(version|titan_settings|mark_settings)" G60BugholeLock.log`。

卸载：禁用本包 → Purge / Deploy → 重启。

---

## 日志判读

日志在 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\G60BugholeLock.log`（日志失败不影响功能）。

| 日志片段 | 含义 |
|---|---|
| `mode=EXPERIMENTAL_NATIVE_CALLS` | **签名校验通过，功能已激活** |
| `disabled: game layout mismatch` / `disabled: Titan engine layout mismatch` | 游戏版本与签名不符 ⇒ **安全停用**（不崩游戏），需等上游适配 |
| `structure_mark;…;reason=ACCEPTED` | 读到你的虫洞 / 构筑标记 |
| `search_applied;entity=…` | 已让该手雷进入"朝目标飞"的状态 |
| `arrival_detonated;entity=…;distance=…` | **到达并引爆** |
| `titan_aim;…;point=…` | 虫洞瞄准点（结构 profile 换算出来的爆点） |
| `arrival_quarantined;entity=…;detail=…` | **只放弃这一颗**：那次写入与引擎原生写重叠（瞬时竞争），其余照常接管 |
| `structure_lock_lost;target=…;detail=…` | 已持有的锁被放弃。`RESOURCE_NOT_IN_WHITELIST` 只应出现在**资源真的变了**（实体 id 被引擎复用）时 |
| `disabled;applied=N` | 已用完的熔断：N = 停手前完成的接管数。只在**结构性**失败或同帧多颗竞争时出现 |
| `point_marker;slot=…;pos=x/y/z;dist=…;age=…` | 你 ping 到**空地**时，槽里那个**世界坐标**（只读诊断） |
| `point_taken;entity=…;pos=…` / `point_released;entity=…` | 点目标接管 / 释放（ping 标记被淘汰、TTL 到期、你标记了虫洞） |
| `point_guide;entity=…;dist=…` | 点目标引导中，每 60 帧报一次当前距离 |
| `point_stalled;entity=…;dist=…` | 到达判定 4 秒内没满足 ⇒ 交回引擎。**看到这条就是"飞过去没炸"** ⇒ 调 `point_arrival_region` |
| `blast_guide;entity=…;dist=…;own_z=…;origin_z=…;above_origin=…` | **体内爆点**的引导诊断（每 60 帧）。`above_origin` = 这颗雷**当前相对目标原点有多高** —— 判断"低抛是上不去、还是根本没被引导"的**唯一依据** |
| `blast_stalled;entity=…;dist=…` | 体内爆点 4 秒没满足到达 ⇒ 交回引擎。⚠ **交回后引擎按实体原点（=底部）飞 ⇒ 看起来就是"在底部引爆"** |
| `blast_point;entity=…;resource=…;lift=…;sweep=…;origin=…;point=…` | **体内爆点**：实体原点 / 这一颗实际用的 lift / 标定档号 / 实际下发的爆点。**每颗一条**（`sweep=off` = 档位表已清空） |
| `blast_hit;entity=<G-60>;target=<目标>;via=arrival\|engine;own=…;origin=…;delta=…` | 这颗 G-60 **实际在哪炸的**（相对目标原点）。`via=engine` = 引擎自己撞爆的、`via=arrival` = 本 mod 下发的。**标定的原始数据**，每颗一条 |
| `point_armed;slot=…;note=structure_mark_present` | 本次 ping 登记成功，但同时存在结构标记（优先级按每颗判） |
| `unit_lock_yielded;entity=…;target=…;to=…` | **让位**：正在追单位的 G-60 遇到新近的结构标记 ⇒ 改去炸结构。看到它 = 优先级生效 |
| `arrival_already_exploded;…;detail=EXPLOSIVE_ALREADY_TRIGGERED` | ★ **正常收尾**（不是错误）：这颗的爆炸**已经触发**（引擎撞击 / 引信 / 另一颗已把它炸了） |
| `priority_precheck_exploded;entity=…` | 在**写内存之前**的只读探测就发现它已爆 ⇒ 短路掉整段 priority（**不写 setter**、不出现误导性的 `priority_locked`）。每颗只打一条 |
| `generic_rejected;…;detail=TARGET_RESERVED` | 这个目标已被**另一颗** G-60 预约 ⇒ 本次不接管（此前这里会抛 `frame_error` 并中止当帧剩余处理） |
| `enemy_selection;…;resource=…;vetoed=true\|false` / `enemy_veto;…;via=no_mark\|after_priority` | 引擎自选目标的否决过程 |

> ★ **2026-09-30 修掉的一个致命 bug**（留档）：`arrival` 段原先沿用上游 `if mutated then disabled=true end`，
> 而 `priority` 段早已改成"瞬时竞争只放弃一颗" ⇒ 一次普通的**写后回读不符**就把**整个 mod 停手并当场关闭日志**
> （症状："玩着玩着虫洞标记失效了"，日志却停在那一刻不再增长）。现在两条链路共用**同一份**判定：
> 竞争态只放弃这一颗；`explode()` 之后的消息、计时器被动、结构性校验仍 fail-closed。

启动时那行会明确打印本包的能力边界：
`build=BUGHOLE_ONLY;scope=marked_bughole_only;bughole_profiles=16;enemy_priority=REMOVED;weakpoints=REMOVED;shrieker_spewer_egg=REMOVED;unmarked_behavior=VANILLA`

## ping 槽结构（逆向笔记，2026-10-01 实测）

按一下 ping，游戏往一个 **128 槽环形缓冲**（每槽 `0x58` 字节，`head/tail` 在头部）写一条。
本 mod 只认 **owner = 本机玩家**且在活窗口 `head..tail` 内的槽。

| 偏移 | 类型 | 含义 | 证据 |
|---|---|---|---|
| `+0x04/+0x08/+0x0c` | float3 | **世界坐标** | 各槽不同、量级合理、Z≈地形高度；**三边定位自洽**（8 组 (坐标,距离) 解出同一公共点，残差 ~0.7 m RMS） |
| `+0x10` | float | `8.0`（像标记存活时长） | 常量 |
| `+0x14` | float | ⚠ **不是"存活时间"** | 同帧各槽几乎相同（差 1e-6~1e-5 s）⇒ 更像**每帧刷新**的量（值≈帧长） |
| `+0x18` | u32 | 创建者实体 id（本机玩家） | 同局常量 |
| **`+0x20`** | u32 | **目标实体 id；`0` = 空白标记**（ping 到空地） | `NO_ENTITY_MARK` 时读到 0 |
| `+0x28` | float | **到玩家/相机的距离（米）** | 与坐标三边定位自洽 |
| `+0x2c/+0x30` | float | 屏幕坐标（≈ `960,600` = 准星中心） | ping 落在准星上 |
| `+0x44..+0x50` | float | 像颜色/透明度 `(1,1,1,0.93)` | — |

> **一次 ping 写一个槽**；取活窗口里**最后一项**即最新 ping（实测两次 ping ⇒ 恰好两个槽，
> 两坐标间距 **37.3 m**，与"走开约 30 m 再 ping"吻合）。
> ⚠ 因为 `+0x14` 不是时间戳，**不能用它挑"最新"**（上游那句 `age>=0 and age<duration` 实际只起 owner 匹配作用）。

---

## 已知限制

- **版本敏感**：88 条 `game.dll` 机器码签名 + exe 签名守卫。游戏更新后若不匹配会**直接停用**
  （刻意设计：宁可不做，也不在错误地址上执行原生调用）。
- **`native_lifetime_verified=false`**：上游自标"原生对象生命周期证明未完成"。
- **不是寻路器**：爆点来自模型节点换算，地形 / 移动目标 / 虫腿仍可能干扰。
- **泰坦离地太近**（两个旋钮，**方向在 2026-10-02 被反转**，别按旧注释调）：

  | 旋钮 | 位置 | 当前 |
  |---|---|---|
  | `FLOOR_MARGIN` | `titan_route`（守卫文件，**保持上游 1.25**） | 爆点相对泰坦根部的最低高度 —— **不动** |
  | `titan_standoff_min` | `entry` | **2.0**（0.85 → 2.5 → 1.75 → 2.0）⇒ `standoff` 只能收到 2.0~2.5 |

  **现在要的是"爆点离腹部保持 ≥2.0 m、名义 2.5 m"**。旧注释的"要贴近腹部、伤害才集中"**已被用户证伪**：
  「**G60 杀死泰坦是靠多部位伤害累加，太靠近腹部会让受伤部位减少**」⇒ 贴到腹下 0.5 m 只波及腹部一处 ⇒ 一发炸不死。
  ⇒ **可复用判据**：想让爆炸更靠近目标时，先问**"这会不会减少被波及的部位数？"** —— 对多部位目标，**更近 ≠ 伤害更高**；
  若仍"炸不死"，该往**远**调爆距。
  净空不足（连 2.0 都放不下）⇒ 拒绝规划，运行时当**等待**（`WAITING_FOR_SAFE_BLAST`，不计失败、不退休），腹部抬起后照常引爆。
  日志：`titan_standoff_adapted` / `titan_clearance` / **`titan_blast`（引爆瞬间的 `belly_dz`）**。
- **泰坦引爆半径 = 1.5**（试错链 `2.0 → 2.25 → 1.75 → 1.0 → 1.5`，见"修复记录索引"）。
  ⚠ 该值**同时**是 `titan_route.terminal_radius`。微调方向：又出现"偶尔炸不死/偏侧" ⇒ 回 **1.25**；
  仍"飞过去不炸" ⇒ 上 **1.75**。
- **`above` 对泰坦一直是空转**（2026-10-02 发现）：到达判定后面还有一道 `below`（`own_z ≤ goal_z`），
  而泰坦的 `goal` **已经**是 `blast_z = 腹点 − standoff` ⇒ `above` 被完全抵消。
  ⇒ 试过的 `titan_belly_above` 已置 **0**（回旧行为）。
  ★★ **`dz` / `goal_dist` 判不出"离腹部多远"**（目标点会被地面净空抬高）⇒ 只用腹点：
  `titan_probe` 的 `p_z` / `belly_dz = own_z − p_z`、`titan_blast` 的 `belly_dz`（正常 **2.5~3.7**）。
- **多颗 G-60 同时锁定同一目标**：先到的炸掉后，后来的识别为"爆炸已触发"并收尾（`arrival_already_exploded`），不会无限盘旋。
  ⚠ 该判定**必须三处共用同一个函数**（disposal / arrival / 引导记账）—— 否则走泰坦段的 G-60 会把
  `'explosion already requested'` 当成普通引导失败连记 30 次，打出一条**假的** `guide_give_up`（那颗其实已经炸了）。
- **同类残留（未修，待评估）**：`if mutated then disabled=true end` 仍存在于 `native_disposal` / `native_minimal` /
  `native_titan_aim` / `search_return` 四处。它们写的是导航/movement 结构，失败更可能是真结构性 ⇒ **暂时保持 fail-closed**。
- **⚠ 虫洞附近没有敌人时炸不了虫洞** —— 见"使用前提"。

### 实机验证状态

| 项目 | 状态 |
|---|---|
| 普通虫洞（9 基线）/ 大型 colony 洞 | ✅ 已实机验证（引爆距离 0.9–1.8 m） |
| 吐酸泰坦 | ✅ 已实机验证（引爆距离 2.1–2.3 m） |
| 巨型构筑者（体内爆点） | ✅ 已实机验证（2026-10-03：45~62 m 远抛 4/4 稳定拆毁） |
| 蟑龙 Dragonroach | ⚠️ **尚未实机验证**（几何与路由是上游自带且已自测） |
| 孢子泰坦（变体借用） | ⚠️ **尚未实机验证**（同目录证据强，但借用几何必须上机确认） |
| 其余 8 个虫洞变体 | ⚠️ 清单已覆盖，实机样本较少 |
| 未支持的敌人不被接管 | ✅ 已实机验证（其它敌人不产生接管日志） |

> **清单覆盖 ≠ 实机验证**，两者必须分开看。

---

## 性能（每帧开销）

mod 挂 `update`，每帧走一次 `tick`。口径：`tests/test_perf_probe.py` + `tests/test_runtime_perf.py`。

| 项 | 每帧 | 说明 |
|---|---|---|
| `Layout.capture` | ~40 读 / 3.3 KB | 无条件一次（五个引擎队列 + behavior 数组） |
| `Readiness.capture` | **1 次**（优化前 5~10 次） | 2026-09-30 起按帧缓存 |
| `with_observation` | 每颗在飞的 G-60、每步 1 次 | 内含 `Search.capture`（~30–50 读） |

**优化一：`jobs_ready()` 按帧缓存**（2026-09-30）。优化前一帧内**一颗**在飞的 G-60 就能触发 5~10 次
（tick 开头 / 每次 `with_observation` / `scope.validate()` 的每次 assert / disposal 的 ready 回调），
即 80~160 次读取/帧。缓存依据：`host:tick` 在**引擎主线程**同步执行 ⇒ 同帧内观测值不变 ⇒ 缓存与重读等价
（**只在成功时缓存**，抛错照常上抛）。

**优化二 / 三：观测节流。** 判据 = "**有没有事可做**"（有 state-4 的 G-60 / 掌持 / 要否决的目标 /
`early_nav_probe`），否则算空转。**两档周期**（`perf` 行的 `idle=` 即当前档位）：

| 档位 | 周期 | 参数 |
|---|---|---|
| 引擎选中**要否决**的目标 | **1（每帧）** | —（刻意不跟着降：`veto_must` ⇒ 1，"否决必须每帧重申"是既有安全属性） |
| 有事可做（持有 / 可接管 / 早期探测） | **2 帧** | `scan_every_busy=2` |
| 纯空转（没有可接管的 G-60） | **6 帧** | `scan_every_idle=6` |

> ⚠ 参数读取有防呆：非数 / `0` / **负数**一律回默认。**负数**会让 `frame%N` 恒为 0 ⇒ 每帧 `return` ⇒
> **mod 永远不跑**（静默整体失效）；测试对 8 组敌意输入做了真实求值。
> ⚠ 副作用（知情）：日志里的状态停留帧数（`sig=[4/3e@N]`）在降频期间按**观测帧**计，会偏小。

`perf` 行（每 600 帧一条，已进白名单）：
`perf;frame=N;frames=K;ready=R;observe=O;layout_reads=L;layout_bytes=B;active=A;idle=I;frames_seen=F`
—— `ready` 应≈ `frames`（缓存生效）；`active` = behavior 数组的**活跃前缀**；
`idle` = 当前档位；`frames_seen` = 本窗口实际跑 tick 体的帧数。

> ★★ **要看"卡不卡"的数字，请用 `%APPDATA%/Arrowhead/Helldivers2/mod_lag_finder.log`** ——
> 那是旁观者 mod 写的，把 ≥50 ms 的帧**按 mod 拆开**，比自插桩更客观、且零风险。
> ⚠ `layout_reads` **只统计 `Layout.capture` 内部**（不含 `TargetData` 的 `d.read`）—— 用现有日志量不出那部分，
> 别拿它当"总内存读"。
> ⚠ 本工程**没有写内存原语**（只有 `ReadProcessMemory` + 6 个原生调用），任何"改数值"的方案在此工程都做不到。

### ☠️ 禁区：**不要再往共享 C 命名空间塞新符号**（2026-10-02 实机事故）

> ⚠ **范围边界**（免得被误读成"addon 一律禁用 cdef"）：`entry.lua.in` 自身有一段 `ffi.cdef` 声明
> `ReadProcessMemory` / `GetCurrentProcess` / `GetCurrentThreadId` / `GetModuleHandleA` ——
> 那是**读内存的根基，既有且必需**。本禁区指的是：**不要再用 `ffi.cdef` 去声明"可能已被别人声明过"的新符号**
> （通用 Win32 API 尤其危险）。

**事故**：为量墙钟微秒加了一段 `ffi.cdef[[QueryPerformanceFrequency/…Counter]]` ⇒ 游戏**启动即崩**。
两次转储同签名（`lua51.dll+0x4a050` **ACCESS_VIOLATION**），而 09-30~10-01 的**全部**历史转储是另一个签名
（`helldivers2.exe+0x626296`，游戏自身的旧崩溃）⇒ 新签名由本轮改动引入；本 mod 日志只有版本行 ⇒ **首次 tick 前就死了**。

**根因**：`ffi.cdef` 写的是**整个 Lua 状态共享的全局 C 命名空间**，而加载器把所有 mod 合进同一批 `patch_N`。
实机里同一批符号已被**不同 mod** 用**不兼容的签名**声明过：

```
QueryPerformanceFrequency(int64_t *frequency);   ← 某个 mod
QueryPerformanceFrequency(void *frequency);      ← 另一个 mod
```

我再去声明 ⇒ `ffi.cdef` 报错（被自己的 `pcall` 吞掉，看不出来），但 C 类型表已被写坏 ⇒
之后**别的 mod** 调 QPC 崩溃。**硬件 AV 无法被 `pcall` 捕获**，所以日志里什么都没有。

**处置**：撤销要**彻底**（`ffi.cdef` / `ffi.load` / `P.now` / `us_*` 字段全部删除，不能只停用）；
既有 `ffi.new/cast`（`early_nav_probe` 只读探测）**保留**（只消费者内置类型，不做 `cdef`）。
**守门**：`tests/test_runtime_perf.py` ⑺ `runtime_never_cdefs` / `runtime_no_ffi_load` / `no_wall_clock_fields`
（按**去注释后的代码**判 —— "禁止它"这句话本身要写在注释里）。

> ★ 通用教训：**"只读诊断"不等于"零风险"**。`ffi.cdef` 看起来只是声明类型、不读写内存，
> 但它动的是**全局命名空间** —— 那是在别人的地盘上施工，而其他 mod 也在同一块地上。

---

## 构建

```sh
python -B scripts/build.py       # 出包 -> dist/G60-BugHole-Lock-<RELEASE_VERSION>.zip
python -B scripts/run_tests.py   # 跑测试（本机无 luajit/lua，用 lupa 跑）
python -B tests/test_bughole_scope.py             # 裁剪点 + 产物级验证
python -B tests/lua_syntax.py                     # 40 个模块语法（lupa/Lua 5.5）
python -B tests/check_lua51_compile.py            # ★ 用游戏自带 lua51.dll 做**真实编译**（Lua 5.1）
python -B tests/test_priority_fault_isolation.py  # 故障域隔离 + 通用接管 + sticky
python -B tests/test_runtime_perf.py              # 每帧读取开销回归
```

> ### ⚠️ 为什么必须跑 `check_lua51_compile.py`
> 其余检查都跑在 **lupa = Lua 5.5**，而游戏是 **Lua 5.1 / LuaJIT**，两者**函数级上限不同**：
>
> | 限制 | Lua 5.1 / LuaJIT | Lua 5.5（lupa） |
> |---|---|---|
> | 每函数 **upvalue** 数 | **60** | 255 |
> | 每函数 local 数 | 200 | 200 |
>
> **2026-09-30 实机事故**：为性能诊断往 `M.new` 加了 10 个独立局部变量，`host:tick` 内那个
> `pcall(function() … end)` 的 upvalue 被顶到 **61 > 60** ⇒ **整个 chunk 编译失败** ⇒
> 文件已正确部署、游戏日志却**一行都没有**（表现为"mod 没生效"），而 `lua_syntax.py`（5.5）**全绿**。
> ⇒ 该脚本用**游戏自己的 `bin/lua51.dll`** 编译 `build/entry.lua` + `src/g60/*.lua`，等价于实机加载期检查
> （路径可用 `G60_LUA51` 覆盖，找不到时自动 SKIP，换机不误报）。
> **教训**：往大函数里加独立局部变量前先跑它；宁可直接塞进一个 table。
> ⚠ 合并后的 `entry` 会超限而单模块通过 ⇒ **必须编译 entry**，不能只编模块。

`scripts/run_tests.py` 会跳过 13 个 `*_windows` 套件（需要 `scripts/test_windows.py` 编译
`tests/native_minimal_fixture.c` 成 DLL 并用 Windows Lua 注入 `G60_FIXTURE_DLL`）。
**本机没有该环境，因此覆盖 `native_priority` / `experimental_runtime` 的集成测试未运行**；
裁剪点由 `tests/test_bughole_scope.py` 做静态与产物级验证兜底。

## 裁剪了什么（相对上游的 diff 摘要）

| 文件 | 改动 |
|---|---|
| `src/g60/native_priority.lua` | 删除"从引擎候选列表按 rank 自动挑敌人"整段（`Candidates.capture` + `Policy.choose`）。**保留** structure_mark 分支 —— 它才是"标记虫洞时打断敌人锁、优先去炸"的那段 |
| `src/g60/experimental_runtime.lua` | `excluded` 恒 false · `has_weakpoint()` 收窄为只认 `structure_profiles` · priority / arrival / disposal 三段加"只对持有锁定的实体生效"门控 · `result.released or reservations` → `result.released` |
| `compat/structure_profiles.lua` | 13 条 → 9 条，只留 `structure_hole`（删 3 条 `structure_tower` + 1 条 `structure_egg`）；2026-10-03 又扩到 16 条（补 7 个能标记的变体） |
| `src/g60/small_filter.lua` | 上游 9 项 `excluded` 整表清空（那 9 项的症状是"打不了中小型敌人"，正是清空的原因） |
| **`addon/entry.lua.in`** | `designed_targets_only=false`；独立 `_G` 全局名 / 日志名 / 启动描述 |
| `scripts/build.py` | 独立 GUID / 资源名，`resource_id` 按新资源名现算（不再复用上游的） |

`compat/build.json`（签名守卫 + 引擎签名）、`compat/titan_profile.lua`、`compat/native_search_binding.lua`、
`src/g60/native_minimal.lua`、`src/g60/native_arrival.lua`（`explode` 调用）**均未改动**。

---

## 修复记录索引

> 详细过程见 git log 与 `.workbuddy/memory/`。**每条都附守门** —— 这些守门是防回归的主要依赖。

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | "只能锁大型敌人、打不了中小型" | **两道闸门**只关了一道：`designed_targets_only`（`allowed`）+ `small_filter.excluded` 表 | 关 `designed_targets_only` + **清空** `excluded` 表 |
| 2 | 追踪虫（stalker）的虫洞标记后不炸（`structure_unavailable;NATIVE_TARGET_INVALID`） | 拿**索敌系统的函数**（`target_valid`）去否决虫洞 —— 而虫巢没有 `HealthComponent`，正是引擎索敌排除它们的原因（**本 mod 的核心恰是绕过索敌**） | `target_valid` 从**硬否决降级为软信号**；硬门槛改成**纯只读校验**（实体可读 / identity 未变 / unit 未变 / `pose.validate()` / 距离 <200 m）。启动自述加 `target_valid=SOFT_SIGNAL` |
| 3 | 关掉筛选层后仍打不了中小型敌人 | 筛选层之外还有**三条接管路径**无条件作用于所有 state-4 G-60（建 `tracked`、每帧 `clear`+`orbit`、`or reservations` 恒真、到期主动引爆） | 三处都改成**只对本 mod 真正持有锁定的实体生效** ⇒ 无标记时对任何 G-60 **一个字节都不写** |
| 4 | 标记多个虫洞时，后标记的把前一颗 G-60 拉走（前目标永久报废） | `native_priority` 未区分 `previous` 是"敌人锁"还是"已在飞的虫洞锁" | 已在飞向某虫洞的 G-60 **保持忠实**（sticky），只有该虫洞真的不可用（消失 / 无效 / 超 200 m / unit 变了）才改投，并发 `structure_lock_lost` |
| 5 | 通用目标锁"每帧重锁"（刷 `RESOURCE_NOT_IN_WHITELIST`） | `track` 重建时**丢掉了 `generic` 标志** ⇒ 通用目标落进"虫洞白名单复核"那一支（那段"通用 sticky"代码**从未执行过**） | 两处 `track` 构造都补 `generic=chosen.generic`；守门做**穷举**断言（每一处 `track` 都必须带） |
| 6 | "有些虫洞不能标记炸毁" | 8 个同样能 ping 的虫巢类型（`markerType=EnemyMassive`）不在清单里 | 清单 9 → 17；其中 5 个复用基线（逐条比对组件集与碰撞参数），`mechanical_bughole` 用最保守通用爆点并标注 ⚠ |
| 7 | 把**尖啸者巢**当成虫洞（违反用户"有生命值的巢不接管"） | 用"它可标记"推出"它是虫洞"，且"核实"用的是**自己写的标签**（循环论证） | 移除；改为**必须用独立来源**（游戏资源路径 / 社区表）判定，测试加两条防线 |
| 8 | 一次**写后回读不符**就让整个 mod 停手并关闭日志（"玩着玩着标记失效了"） | `arrival` 段沿用上游 `if mutated then disabled=true end`，而 `priority` 段早已改成"只放弃一颗" | 两条链路共用**同一份**判定：竞争态只放弃这一颗；其余仍 fail-closed |
| 9 | 引擎自选的运输船 / 光能族增援飞船没有被清掉 | `take_gate` 的 veto 分支被 `structure_mark` 挡住；priority 又正确拒绝了（友方）⇒ 没人清 | priority **之后**加一处兜底 veto（单一实现 `run_veto` 两处共用）。⚠ `runner:step` 的返回契约是 `(result, reason)` —— 第一版按 `(ok, result, why)` 取值，145 条日志全打成 `nil`，**诊断把自己骗了一次** |
| 10 | 排除表第一版**排错了哈希** | "名字对得上"当成"就是那个哈希"（社区表说它是运输船、实体表里也存在，都不足以证明引擎会把 G-60 指向它） | 判据改为**实机日志里真的出现过的哈希**；测试 `veto_list_covers_logged_dropship` 用日志反查（"这条断言如果早一天写，本次 bug 不会发生"）。另加 `veto_list_excludes_friendly_pelican`（不得排除玩家自己的撤离机） |
| 11 | 泰坦引爆半径反复调（`2.0 → 2.25 → 1.75 → 1.0 → 1.5`） | ① 2.25：`distance` 常贴 2.3~2.43 边缘 ⇒ 伤害不集中（"有几次不能一颗炸死"）；② 1.0：**整颗漏炸**（移动中的泰坦 `goal_dist` 恒 1.2~3.0，进不了 1.0） | 最终 **1.5**（居中：既给判定球留接住移动目标的余量，又不比 1.75 更容易偏侧） |
| 12 | "即使站泰坦前方丢，G60 也从**侧面到后面再到腹部**" | 捷径②两个问题：`forward<=2.5` 门槛太窄（正前方 `forward≈5~15` 永不命中）+ **判定写在 `else` 分支里、只在接管第一帧评估一次** | `forward<=RADIUS`（取消侧向限制）+ 判定**移到公共区、每帧评估**；保留 `radius<=RADIUS`、`own_z<=under+2.5` 两条硬约束 |
| 13 | "偶尔在**离腹部极近**处引爆" | `titan_standoff_min=0.85` 允许爆点贴到腹下 0.85 m；而 `under = max(p_z−3.5, floor)` 在腹部被压低时会顶住目标点 | `titan_standoff_min` **0.85 → 2.0**（⇒ 引爆点必在腹下 **≥2.0 m** 的**数学不变量**）+ 净空拒绝改判**等待**（`WAITING_FOR_SAFE_BLAST`，不计 `guide_fail`、不退休） |
| 14 | `titan_belly_above` 一直**空转** | 到达判定后还有 `below`（`own_z ≤ goal_z`），而泰坦 `goal` 已是 `腹点 − standoff` ⇒ `above` 被完全抵消 | 承认并置 **0**（回上游标定窗口）；`above` 的教训写进"已知限制" |
| 15 | 2026-10-02 **游戏启动即崩** | `ffi.cdef` 声明 `QueryPerformance*` ⇒ 撞上别的 mod 的**不兼容声明** ⇒ 写坏全局 C 命名空间 | **彻底撤销** + 永久守门（见"禁区"一节）。⚠ 两次转储同签名 + 历史转储是另一签名，才确认是本次引入 |
| 16 | 泰坦段的 G-60 打出**假的** `guide_give_up`（其实已经炸了） | `note_already_exploded` 只接在 disposal / arrival 两段，**引导失败记账**那段没接 | 三处**共用同一个判定函数** |
| 17 | 12 次标记全是"锁上即发现已爆"，但照样走了完整 priority（**含一次 setter 写内存**）并打误导性的 `priority_locked` | 引擎在我们接管前就炸了它，实体还会留几帧 | **首次接管那一帧**先做只读探测（`arrival:triggered`，判据 = `Explosive.capture` 的两条文案），命中直接收尾 ⇒ **不写内存**。⚠ 只在首次接管时探（已锁定的实体每帧走粘性路径，setter 本来就不写） |
| 18 | `frame_error;…: target already reserved`（中止当帧剩余处理，后面的 G-60 被跳过一帧） | 预约复查只接在**虫洞**的两条路径上，**通用目标**的三条入口一条都没查 | 复查补进**唯一**的通用复核 `generic_validate` ⇒ 三条入口一次性覆盖；命中返回 `TARGET_RESERVED` |
| 19 | 巨型构筑者炸不掉（在底部引爆） | 引擎 `aim` 落在**实体原点**（地表/地下），而它要求爆炸进入体内 | 新增**体内爆点**名册 + 专用 `region`（详见上文该节） |
| 20 | 标定数据被日志缺陷吃掉（`blast_point` 同目标第 2 颗起不打 / `blast_hit;target=-`） | ① 去重键只含目标 id；② `old.lock.id` 在 `local function` 里**不可见**（解析成全局 nil） | 去重键改成 **(手雷, 目标)**；目标 id 在建爆点时存进 `P.site[m.id]`。★ 教训：**诊断字段要有一条"它真能取到值"的守门** |

> ★ **两条通用的**：① **`local function` 只在其定义点之后可见**（定义顺序是语义，错序 = 被 `pcall` 吞掉的静默失效）；
> ② **"只改一份副本"是本仓库反复出事故的模式** —— 任何"两处共用同一实现"的地方，守门必须落在**每一处**。

### 已排除的方案（别再试）与"看着像 bug"的正常现象

| 曾考虑 | 为什么不行 |
|---|---|
| **调 G-60 的"追踪数值"**让它干脆不锁运输船 | **数据上不成立**：`SeekingMissileComponentData`(29 行) / `GuidanceTargetComponentData`(6) / `TargetingComponentData`(295) / `ThrowableComponentData`(46) / `DetectorComponentData`(319) 里**都没有 G-60**（那 14 个可调字段属于 5 把玩家导弹武器）。更彻底：G-60 的资源哈希 `62bf553e935c328e` 在 46 MB `generated_entities.dl_bin` 里**以任何字节形式出现 0 次**（同法检索其它手雷/实体哈希都能命中）⇒ 连"它的组件"都无法在数据里定位 |
| **节流否决**（每 N 帧一次）/ **否决几次后放弃** | 都会**削弱效果**：`clear` 后引擎 ~1 帧就重选，节流窗口内手雷会飞向运输船。**次数是引擎决定的**（只在"引擎*当前*选择 == 运输船"时才否决；成功 clear 后选择为空 ⇒ 下一帧不再否决）—— 145 次否决 = **引擎 145 次重新获取目标**。开销约 **7 ms（整局总和）≈ 1% 量级** ⇒ 判定**不改** |
| **改 retarget**（指向真实敌人） | 唯一根治，但 `native_minimal` 只接受 `search`（守卫文件不能改）；`search_return.lua` 的 retarget 是死代码且需 `scores_current` 由已验证适配器提供；还会重开已移除的"自动挑敌人" |
| **到达判定改成球形**（各向同性） | 实机**明显变差** ⇒ 已回滚为圆柱；形状不再动，只调数值 |
| **无敌人时用原生函数绕过引擎** | 三条路径全不行（原生 setter / `orbit` 写导航目的地 / 裸写内存）—— 见"使用前提" |

**"看着像 bug"但其实正确**：`structure_unavailable;detail=NATIVE_TARGET_INVALID` 里多数是**巢已被炸塌**后的
正常失效；个别是**连锁殉爆**（两个巢挨太近，一个被引爆把另一个一起带走）。

> ⚠ profile 里的 `nodes`（骨架节点数）/ `offset` / `belly_hash` 是**上游实机标定值** ——
> **没有为新类型编造过**，猜错会让 G-60 飞到错误的爆点甚至炸不塌。扩充需要实机标定或等上游补充。

## 如果虫洞仍然偶尔不去，按日志顺序定位

| 看到什么 | 卡在哪 |
|---|---|
| `structure_mark;…;reason=RESOURCE_NOT_SUPPORTED` | 该资源不在 16 个 profile 里（敌人 / 投掷物 / 未收录巢型）—— 不是 bug |
| 有 `structure_mark;…;ACCEPTED` 但无 `priority_locked` | 标记读到了但锁定被拒 —— 看紧跟其后的 `structure_unavailable;detail=…` |
| 有 `priority_locked` 但无 `titan_aim;…;point=…` | 进入了朝虫洞飞的状态，但**爆点没算出来** |
| 有 `titan_aim` 但无 `arrival_detonated` | 飞到了但到达判定没过（多半是 `front_distance` / 爆点高度带） |
| `titan_skipped;reason=…` / `arrival_skipped;detail=…` / `priority_skipped;detail=…` | **把这几行的 reason 原样发我**，能直接定位到哪一层拒绝 |
| 开头一串 `frame_error;detail=…: pointer bound` | 正常现象：进任务初期引擎指针未就绪，会自愈（前 ~50 帧） |
| 连 `version=` 都没有 | 包没被 loader 加载，看 `BingusSharedLoader.log` |

## 许可与来源

代码 MIT（见 `LICENSE`）。**派生自 etxp/HD2-G60-Smart-Targeting**，原作者版权声明按 MIT 要求原样保留；
本衍生作品的版权归 LovedeHua。上游来源与 AI 辅助开发声明见 `THIRD_PARTY_NOTICES.md`，
上游原始 README 保留为 `README.upstream.md` / `README.upstream.zh-TW.md`。
游戏数据与美术资源权利另计（见该文件）。
