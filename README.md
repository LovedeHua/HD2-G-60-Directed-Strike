# G-60 Bug Hole Lock —— 标记虫洞 / 大型虫族 专用版

《绝地潜兵2》G-60 反坦克追踪者手雷的**目标专用**接管 mod。
只接管**玩家标记的虫洞** 与 **吐酸泰坦 / 孢子泰坦 / 蟑龙**。其余全部交还游戏原生 ——
唯一例外是"不让 G-60 追踪**运输船 / 光能族增援飞船**"（见下文"唯一例外"一节，可一键关闭）。

> **当前版本：v0.1.2** —— 版本号的**唯一来源**是 `compat/build.json` 的 `public_version`，
> `TITLE`（manifest 里的显示名）、成品包文件名、`BUILD-INFO.json` 全部由它派生。
> 发新版**只改那一个地方**（`scripts/build.py` 里不再有硬编码的版本串）。
>
> 本工程是 [`etxp/HD2-G60-Smart-Targeting`](https://github.com/etxp/HD2-G60-Smart-Targeting)
> 0.1-beta.1 的**裁剪派生版**（源码 MIT / AI-assisted）。裁剪只动"决策层"，
> **签名守卫、持锁窗口、状态机白名单、身份复验等安全机制全部原样保留**。
> 上游原始说明保留在 `README.upstream.md` / `README.upstream.zh-TW.md`（仅供对照，**不打进包**）。

---

## 它做什么

**你标记什么，G-60 就去炸什么。**

| 情况 | 行为 |
|---|---|
| 你标记了下面 16 个虫洞之一 | **本 mod 接管**：打断 G-60 当前的敌人锁定，改为朝该虫洞飞去，到达后引爆 |
| 你标记了**吐酸泰坦 / 孢子泰坦 / 蟑龙** | **本 mod 接管**：各走为体型标定的航路，在标定位置引爆（几何**不由引擎算**） |
| **你标记了任何其它目标**（敌人 / 建筑…）| **★ 本 mod 接管**（2026-09-30 新增）：强制飞向它并引爆。**引爆位置由引擎决定**（`calls.aim`），本 mod 不算几何 |
| **你标记了运输船 / 光能族增援飞船** | **★ 本 mod 接管**（2026-10-01 新增）：同上一行。它们虽然在"引擎自选要清掉"的排除表里，但**玩家点名**时照样飞过去炸（见"唯一例外"下半节） |
| 虫洞与泰坦同时被标记 | **虫洞优先** |
| 引擎自己选中了吐酸泰坦 / 蟑龙（你没标记） | 同上接管 |
| **你标记了友方目标**（信标球 / 撤离机 / 平民…）| **不接管** —— 见下方"友方如何排除" |
| 引擎给 G-60 选了**运输船 / 光能族增援飞船**（**你没标记**） | 清掉该选择（`enemy_veto_enabled`，见"唯一例外"） |
| **你 ping 了一片空地** | **★ 本 mod 接管**（2026-10-01 新增）：ping 槽里存着那个位置的**世界坐标**，本 mod 把它写成"点目标"，G-60 飞过去炸。见下节 |
| 你没标记任何东西 | **本 mod 完全不插手**，G-60 按游戏原生 TargetLock 打敌人 |

### ★ ping 空地 ⇒ 指哪打哪（2026-10-01）

玩家 ping **空地**（标记不到实体）时，引擎其实把**那个位置的世界坐标**存在 ping 槽里
（`+0x04` float3；本 mod 用三边定位交叉验证过——8 组 (坐标, 距离) 解出同一公共点、
残差 ~0.7 m RMS）。开启 `point_target_enabled` 后，本 mod 把它写成**点目标选择**
（`invalid_id` + 坐标，与泰坦路径同款写法），G-60 就会飞过去，到点引爆。

**优先级（保守，不抢既有行为）**：
```
虫洞标记  >  引擎自选的泰坦/弱点目标  >  ping 的地面点  >  完全不管
```
即：只有这颗 G-60 既没被虫洞标记认领、引擎也没选中泰坦类目标时，才接管点目标。

| 前提 | 说明 |
|---|---|
| **附近必须有敌人** | G-60 得先被引擎驱动到 state 4（同上节）。没敌人时它停在弹道模式，标什么都不飞 |
| **必须是"ping 到空地"** | ping 到实体时走原有的实体接管路径（更精确） |
| **TTL 之内** | `point_target_ttl_frames`（默认 1200 帧 ≈ 20 秒 @60fps）。同一个 ping 过期后自动释放 |

日志：`point_taken;entity=…;pos=…`（首次接管）/ `point_released;entity=…`（标记消失或过期）。

### ★★ 使用前提：虫洞附近必须有**敌人**（引擎机制，不是 mod 故障）

**本 mod 不创造 G-60 的追踪能力，只是"改写引擎已经分配给它的目标"** ——
把"最近的敌人"改成"你标记的虫洞"。而 G-60 的原生追踪逻辑
**只在引擎已经给它分配了目标时才激活**：

- 代码里对此有硬断言：接管前必须通过 `native update excluded` 检查
  （`assert(math.floor(Layout.u32(c.identity_bytes,20)/2)%2==0,'native update excluded')`）
  —— **引擎必须正在原生驱动这颗 G-60**，本 mod 才接管。
- 日志里看 `link;…;g60=<n>;eligible=<n>`：只有 `eligible≥1` 的帧才会出现 `entered=1`。
- **实测**：虫洞附近没有敌人时，G-60 不会被引擎驱动 ⇒ 本 mod 不接管 ⇒ **虫洞炸不掉**。

**⇒ 想炸虫洞，请确保虫洞附近（G-60 的索敌范围内）有敌人。**
站在空无一怪的虫洞前扔 G-60，它不会有反应 —— 这是引擎机制，不是本 mod 故障。

> ★ **2026-10-01 实测记录：mod 侧试过的三条"绕过"路径都不行**（用户要求专项探查"无敌人时
> 能否利用游戏原生函数"）：
>
> | 路径 | 结果 |
> |---|---|
> | **原生 setter**（`clear` 设目标） | state 2/3 写入回读一致，但 G-60 行为不变（v1/v2 两轮实验） |
> | **`orbit` 写导航目的地**（`movement+0x60`） | **11 颗实测 11/11**：调用成功、destination 确实从 `0,0,0` 变成真实坐标（如 `-189.86,-3.54,-0.96`），**但 `path_agent` 始终 `false`** |
> | 裸写内存 | mod **不具备**写内存能力（只绑了读的 API，所有写都走引擎函数）⇒ 做不到 |
>
> **机制结论**：state 2/3 的 G-60 处于**弹道飞行模式**（没有寻路代理）—— 它
> **既不读 selection，也不读导航目的地**；两种写入失效是**同一个原因**：
> 引擎还没把它从"弹道"切到"导航"。⇒ 在早期 state 里改任何目标数据都无效，
> 除非能让引擎**自己**建立寻路代理（那需要逆向 game.dll 找"分配目标 / 状态转换"
> 类函数，当前**未做**）。
>
> 诊断开关 `early_nav_probe` / `early_nav_orbit` 保留在 `entry`（默认**关**，
> 需要重启实验时改成 `true`；后者是写操作，谨慎）。

### 友方如何排除（2026-09-30）

通用接管用 `calls.target_valid`（`game.dll+0x8858a0`，**引擎索敌系统**的
"能不能把这个实体当锁定目标"）作**硬门槛**：

- 引擎索敌不会把友方当目标 ⇒ 友方返回 `false` ⇒ **直接不接管**。
- ⚠ 这与**虫洞路径正好相反**：虫洞因为没有 `HealthComponent` 也被它判 `false`，
  所以虫洞那边把它降级为**软信号** + 只读复核（详见下文「追踪虫巢被拒」一节）。
  通用目标不需要绕过索敌 ⇒ 正好用它当硬门槛。
- ★ **唯一的例外（2026-10-01）**：玩家**点名标记**运输船 / 光能族增援飞船时放行 ——
  它们是**载具**，索敌同样判 `false`，但用户要求"标记了就要飞过去炸"。
  例外只对 `small_filter.marked_allowed`（当前恰好那两项）生效 ⇒
  标记**信标球 / 鹈鹕撤离机 / 平民**照样被拒（它们的索敌结果同样是 `false`）。
  详见「唯一例外」下半节。
- 排除表（`small_filter`，含运输船与光能族增援飞船）**仍然生效** —— 但只针对
  **引擎自己选中**的场景（玩家点名标记时走的是上面那条例外）。

### 三项能力可分别开关

`titan_enabled=false` 关闭泰坦，`titan_variants_enabled=false` 只关变体，
`dragonroach_enabled=false` 关闭蟑龙，**`generic_takeover_enabled=false` 关闭通用接管**
（退回"只打虫洞/泰坦/变体"）。全部设 false 即退回"只打虫洞"。

> 上游那套「按固定顺位自动追打 Bile Titan / Impaler / Spore Charger / Charger」以及
> 「按部位弱点瞄准」**已全部移除**。本 mod **不做顺位挑选、不做自动选择** ——
> 通用接管只处理**玩家明确标记**的目标。

## 支持的 16 个虫巢（9 基线 + 7 变体）

- **8 种普通虫洞**：scavenger / spitter / warrior / hiveguard / hunter / boomer / prowler / stalker
- **1 个大型 colony 洞** = `bug_spawner_bile_titan`（**泰坦巢**）使用的模型

已删除（标记它们本 mod 不接管）：**Shrieker Nest（尖啸者巢）**、普通/大型 Spore Spewer（孢子菇）、
`embryo_01`（任务虫卵）。

### ★★ 2026-09-29 移除尖啸者巢（修正一处长期错误）

`095686275a113614` 是**尖啸者巢 Shrieker Nest**，不是虫洞。两个**独立来源**一致：

| 来源 | 内容 |
|---|---|
| 游戏资源路径（本工程 MurmurHash64A 反查 107,744 条资源名） | `content/env_bugs/assets/gameplay/bug_spawner_shrieker` |
| 社区表《绝地潜兵2资源ID》→「哈希表-整合」 | `尖啸虫巢穴 \| Shrieker Nest` |

**它违反用户 2026-09-28 的明确要求**："对于有生命值的尖啸巢穴这一类的不要接管，
直接使用游戏原生行为"。现已在 `compat/structure_profiles.lua` 中移除 ⇒ 清单 17 → 16。

> ⚠️ **我犯的错，记在这里**：裁剪 J 当初因为它"可标记（`SpottableComponent.markerType=EnemyMassive`）
> 且能被 ping"就把它当成虫洞恢复了 —— **把"可标记"错当成"是虫洞"**，而上游本来
> 把它归为 `structure_tower`。更糟的是 2026-09-28 我"核实"时说"它不在表里"，
> 证据是"17 项全是 `kind=\"structure_hole\"`" —— **循环论证**：`kind` 是我们自己写的标签。
> 而当时的实机日志里 `structure_mark;resource=095686275a113614` 明明是 `ACCEPTED`。
> ⇒ **判定"是不是虫洞"必须用独立来源（游戏资源路径 / 社区表），不能用自己的标签。**
> 现在测试里有两条防线：点名断言（该哈希不得出现）+ 用游戏路径反查验证"每条都是
> `bug_spawner_*`/`mechanical_bughole`"。

## 支持的敌人（3 种）

| 敌人 | resource | 航路 | 几何来源 |
|---|---|---|---|
| **吐酸泰坦** Bile Titan | `9e2e17f2ccccafdd` | `titan_route`（RADIUS=12 / standoff 2.5） | 自有 profile |
| **孢子泰坦** Spore Burst Bile Titan | `ef04cb84d097a497` | 同上（**借用**） | **借用**基线泰坦 |
| **蟑龙** Dragonroach | `960b48a421a3faaa` | `weakpoint_route` 的 **thorax** 分支（standoff 2.5） | 自有 profile |

### 孢子泰坦为什么能"借用"

它不是猜的 —— 用资源路径哈希反查（`MurmurHash64A`）得到了确凿证据：

```
ef04cb84d097a497 → content/fac_bugs/cha_strider/cha_strider_gloom
9e2e17f2ccccafdd → content/fac_bugs/cha_strider/cha_strider
                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 同一个 unit 目录
```

⇒ 同一单位目录 = 同一模型 ⇒ 借用基线的 `boss_hash` / `belly_hash` / `offset` /
`alive_rva` / `engine_guards` / `getters`。这与项目既有的
`warrior_captive -> warrior` 借用模式（见 `tests/hole_coverage.py` 的 `BORROWED`）一致。

**失败是 fail-closed 的**：`titan_context` 在写任何字节之前会校验身份 / 类 / 场景图锚点，
不符则记 `titan_skipped` 直接放弃 —— **不会写错位置**。

> 变体是**逐个显式登记**的（`compat/titan_variants.lua`），不做"同目录批量借用" ——
> 那会把未验证的变体一起拉进来。

> **蟑龙的飞行适配是上游自带的**，不是我们新写的：
> `weakpoint_route` 的 thorax 分支**没有地面净空检查**（只有穿刺者的 underside
> 分支才有），源码注释原话是 *"Dragonroach can be airborne; its root is not a
> terrain-height sample."* ⇒ 爆点由「瞄准点 − standoff」得出，与地面高度无关。
> ⇒ 我们只做了"放行资源"这一步，几何一个字没改。

> 支持泰坦用的是上游 `titan_profile.lua` + `titan_route.lua` 里**本来就为泰坦标定**的那套几何
> （`RADIUS=12` / `standoff=2.5`），不是照抄别人的参数，也不是为虫洞标定的值。

> ★ **2026-09-30：到达判定试过"球形"，实机效果很差 ⇒ 已回滚为上游的圆柱。**
> 试过的版本是 `dx²+dy²+dz² ≤ r²`（各向同性，期望"靠够了就炸"），但实测判定为**明显变差**
> ⇒ 形状不再动，只调数值。记录在此避免以后再试一遍。
> 当前判定 = **圆柱**：水平 `dx²+dy² ≤ r²` 且 `-depth ≤ dz ≤ above`。
>
> **当前参数**（`above` 是 2026-09-28 为让绕飞中的 G-60 在洞口/腹部**上方**也能引爆而加的；
> 不配时 `above=0`，行为与上游一致）：
>
> | 目标 | 参数 | 来源 |
> |---|---|---|
> | 吐酸泰坦 / 孢子泰坦 | `radius=**2.25**` / `depth=1.2` / `above=1.2` | `env.titan_arrival_region`（`entry`） |
>
> ★ **2026-09-30：泰坦半径 2.0 → 2.25**（用户报"G-60 到达引爆点耗时久"）。
> 实测瓶颈是**绕行几何**（12 m 外圈 / 20° 步长；捷径②放宽到数学上限后仍 0 命中）
> ⇒ 改用"提前判定到达"。本值**同时**是 `titan_route` 的 `terminal_radius`，
> 调大后 `under` 段里 `radius<=terminal_radius` 更早成立 ⇒ **更早切 `attack` 直冲**。
> 代价：爆点离腹部略远（+0.25 m，小幅）⇒ 需实测确认仍"炸得死"。
> （实测仍看日志 `titan_started;…;stage=` 与 `arrival_detonated` 的 `distance`。）
> | 蟑龙（thorax） | `radius=1.75` / `depth=0.8` / 无 `above` | `weakpoint_profiles` 的 `960b48a421a3faaa.region` |
>
> 虫洞走 `kind='entrance'` 盒状分支，**不受影响**。
>
> ⚠ 参数分工：「**侧面/斜上**」只受 `radius` 限制（水平=r、dz=h 处水平=√(r²−h²)），
> 「**上方**」才受 `above` 限制 —— 想放宽斜上时别去动 `above`。

**不接管**：`weakpoint_profiles.lua` 里另外登记的 5 种敌人 —— 穿刺者（Impaler）、
孢子冲锋兵（Spore Charger）、冲锋兵巨兽（Charger Behemoth ×3）、冲锋兵（Charger）。
它们仍由引擎原生 TargetLock 处理。

> 放行用的是**精确资源哈希**，不按 `kind` 推断 —— 按 kind 会把同类型的其它敌人
> 一起拉进来（例如 Spore Charger 也是 `head`）。

## 安装

> ### 📦 成品包下载
> **[GitHub Releases › 最新版](https://github.com/LovedeHua/HD2-G60-BugHole-Lock/releases/latest)**
> —— 下载 `G60-BugHole-Lock-0.1.2.zip` 直接导入 mod 管理器。
> （本仓库里只有**源码**，成品包放在 Releases 的附件里。）

1. 关闭游戏，安装 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)
   （**API 1，v15+**，需 addon discovery）。
2. 把 `G60-BugHole-Lock-0.1.2.zip` 导入 mod 管理器。
3. **与上游官方包二选一**——两个包都会改 G-60 的决策，同时启用会打架。
   本包 GUID `9c1d4e77-…`，官方包 GUID `58a16a67-…`。
4. Purge / Deploy 后重启游戏。

> ⚠ 装完先看 `G60BugholeLock.log` 的**第一行**——有 `version=0.1.2-bughole;…` 才算加载成功。
> 那一行同时给出 `runtime_baseline=0.5.20`（**上游运行时基线**，与本 mod 的版本不是一回事）。
> 一行都没有 = 没生效（可能是没进 addon 发现列表，或产物编译失败），**此时任何"调参"都无意义**。

卸载：禁用本包 → Purge / Deploy → 重启。

## 日志判读

日志在 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\G60BugholeLock.log`
（beta.1 起日志是可选的，日志失败不影响功能）。

| 日志片段 | 含义 |
|---|---|
| `mode=EXPERIMENTAL_NATIVE_CALLS` | **签名校验通过，功能已激活** |
| `disabled: game layout mismatch` | 游戏版本与签名不符 → **安全停用**（不崩游戏），需等上游适配 |
| `disabled: Titan engine layout mismatch` | 同上（另一组 exe 签名） |
| `structure_mark;…` | 读到你的虫洞标记 |
| `search_applied;entity=…` | 已让该手雷进入"朝虫洞飞"的状态 |
| `arrival_detonated;entity=…;distance=…` | **到达并引爆** |
| `titan_aim;…;point=…` | 虫洞瞄准点（结构 profile 换算出来的爆点） |
| `arrival_quarantined;entity=…;detail=…` | **只放弃这一颗**：那次写入与引擎原生写重叠（瞬时竞争），该 G-60 交回引擎，其余照常接管 |
| `structure_lock_lost;target=…;detail=…` | 已持有的锁被放弃。`RESOURCE_NOT_IN_WHITELIST` 只应出现在**资源真的变了**（实体 id 被引擎复用）时 |
| `disabled;applied=N` | **已用完的熔断**：N = 停手前完成的接管数。只在**结构性**失败（版本漂移）或同帧多颗竞争时出现 |
| `point_marker;slot=…;pos=x/y/z;dist=…` | ★ 你 ping 到**空地**（空白标记）时，槽里那个**世界坐标**（2026-10-01 新增，**只读诊断**）。实测：一次 ping 写一个槽、坐标就是 ping 的那一点 |
| `point_taken;entity=…;pos=…` | ★ **点目标接管**（2026-10-01）：本 mod 把 ping 的地面点写成"点目标"，G-60 正飞过去炸（见"ping 空地 ⇒ 指哪打哪"） |
| `point_released;entity=…` | 点目标释放（ping 标记被引擎淘汰 / TTL 到期 / 你标记了虫洞）——该 G-60 交回引擎 |
| `point_guide;entity=…;dist=…` | 点目标引导中，每 60 帧报一次**当前到目标点的距离**（看它有没有在靠近） |
| `point_stalled;entity=…;dist=…` | ★ 到达判定 4 秒内没满足 ⇒ 交回引擎。**看到这条就是"飞过去没炸"** ⇒ 调 `point_arrival_region` |

> ★ **2026-09-30 修掉的一个致命 bug**：`arrival` 段原先沿用上游那句
> `if mutated then disabled=true end`，而 `priority` 段早已改成"瞬时竞争只放弃一颗"。
> 结果一次普通的**写后回读不符**（引擎原生 TargetLock 同帧后写覆盖）就把
> **整个 mod 停手并当场关闭日志** —— 症状是"玩着玩着虫洞标记失效了"，日志却停在那一刻
> 不再增长（而其它 mod 的日志仍在更新 ⇒ 游戏没崩，是它自己关了）。
> 现在两条链路共用 `g60.priority_faults` 的**同一份**判定：
> 竞争态（`arrival proximity suppression failed` / `arrival clear failed`）
> 只放弃这一颗；`explode()` 之后的消息、计时器被动、结构性校验仍 fail-closed。

启动时那行会明确打印本包的能力边界：
`build=BUGHOLE_ONLY;scope=marked_bughole_only;bughole_profiles=16;enemy_priority=REMOVED;weakpoints=REMOVED;shrieker_spewer_egg=REMOVED;unmarked_behavior=VANILLA`

## ping 槽结构（逆向笔记，2026-10-01 实测）

你按一下 ping，游戏会往一个 **128 槽的环形缓冲**（每槽 `0x58` 字节，`head/tail` 在头部）写一条。
本 mod 只认 **owner = 本机玩家** 且在活窗口 `head..tail` 内的那些槽。

| 偏移 | 类型 | 含义 | 证据 |
|---|---|---|---|
| `+0x00` | u32 | 恒 0 | 8 槽全 0 |
| **`+0x04/+0x08/+0x0c`** | float3 | **世界坐标** | 各槽不同、量级合理、Z≈地形高度；**三边定位自洽**（8 组 (坐标,距离) 解出同一公共点，残差 ~0.7m RMS） |
| `+0x10` | float | 8.0（像标记存活时长） | 常量 |
| `+0x14` | float | ⚠ **不是"存活时间"** | 同帧各槽几乎相同（差 1e-6~1e-5 s）⇒ 更像**每帧刷新**的量（值≈帧长） |
| `+0x18` | u32 | 创建者实体 id（本机玩家） | 同局常量 |
| **`+0x20`** | u32 | **目标实体 id；`0` = 空白标记**（ping 到空地） | `NO_ENTITY_MARK` 时读到的就是 0 |
| `+0x28` | float | **到玩家/相机的距离（米）** | 与上面坐标三边定位自洽 |
| `+0x2c/+0x30` | float | 屏幕坐标（≈ `960,600` = 准星中心） | ping 落在准星上，故恒在中心 |
| `+0x44..+0x50` | float | 像颜色/透明度 `(1,1,1,0.93)` | — |

> **一次 ping 写一个槽**；取活窗口里**最后一项**即最新 ping（实测：两次 ping ⇒ 恰好两个槽，
> 两坐标间距 **37.3 m**，与"走开约 30m 再 ping"吻合）。
> ⚠ 因为 `+0x14` 不是时间戳，**不能用它挑"最新"**；上游那句 `age>=0 and age<duration`
> 实际只起 owner 匹配的作用。
>
> 目前该坐标**只用于诊断日志**（`point_marker;`）——「ping 一个位置 ⇒ G-60 飞过去炸」
> 所需的引导通路尚未实现（前提仍是**有敌人**、G-60 处于 state 4）。

## 已知限制

- **版本敏感**：88 条 game.dll 机器码签名 + exe 签名守卫。游戏更新后若不匹配会**直接停用**
  （这是刻意设计：宁可不做，也不要在错误的地址上执行原生调用）。
- **`native_lifetime_verified=false`**：上游自己标注"原生对象生命周期证明未完成"。
- **不是寻路器**：爆点来自模型节点换算，地形/移动目标/虫腿仍可能干扰。
- **泰坦离地太近** —— 这一条有两个**方向相反**的旋钮，别搞混：
  | 旋钮 | 位置 | 作用 | 调大的后果 |
  |---|---|---|---|
  | `FLOOR_MARGIN`（**保持上游 1.25**） | `titan_route`，守卫文件 | 爆点相对**泰坦根部**的最低高度 | 更严（更早放弃） |
  | `titan_standoff_min`（**2026-09-30: 1.5 → 0.5 → 0.75 → 1.0 → 0.85**） | `entry`，调用方 | `standoff` 最小能缩到多少 | 爆点离腹部更远 |
  **用户真正要的是"爆点贴近腹部"** ⇒ 该放的是 `standoff` 下限，**不是** `FLOOR_MARGIN`。
  （曾误降 `FLOOR_MARGIN` 到 0.5：那只会允许爆点更低，而腹部在高处 ⇒
  实测"离腹部太远、离地面太近、炸不死泰坦"，已回滚；`titan_route.lua` 也**恢复逐字节上游**。）
  现在的行为：净空充足用 `standoff=2.5`；受限时收到"刚好清空地板"的值，**最低 0.85**
  （爆点贴近腹部 ⇒ 伤害集中）；连 0.85 都放不下（泰坦几乎贴地）时仍拒绝。
  > **为什么是 0.85**：逐级试过 0.5 / 0.75 / 1.0 —— 贴太近**小概率吃不到弱点、炸不死**，
  > 太保守则又回到"离腹部远"。**0.85 是实机试出来的取值，别随手改。**
  接管门槛由 `p_z−origin_z ≥ 2.75` 降到 **`≥ 1.75`**。
  日志：`titan_standoff_adapted`（实际用的 standoff）/ `titan_clearance`（差多少）。
- **多颗 G-60 同时锁定同一目标**：先到的炸掉后，后来的会识别为"爆炸已触发"并收尾
  （`arrival_already_exploded`），不会无限盘旋。
- **同类残留（未修，待评估）**：`if mutated then disabled=true end` 这句上游收尾仍存在于
  `native_disposal` / `native_minimal` / `native_titan_aim` / `search_return` 四处。
  它们写的是导航/movement 结构，失败更可能是真结构性 ⇒ **暂时保持 fail-closed**；
  `priority` 与 `arrival` 两处（"写后回读"型）已改为瞬时竞争只放弃一颗。
  若实机再出现"玩着玩着整个 mod 停手 + 日志停止增长"，按同一思路逐个评估。
- **⚠ 虫洞附近没有敌人时炸不了虫洞** —— 本 mod 是"改写引擎已分配的目标"，
  而引擎的原生追踪要有目标才激活 ⇒ 空地上扔 G-60 不会有反应。
  详见上文 **「使用前提：虫洞附近必须有敌人」**。

### 实机验证状态

| 项目 | 状态 |
|---|---|
| 普通虫洞（9 基线） | ✅ 已实机验证（引爆距离 0.9–1.8m） |
| 大型 colony 洞 | ✅ 已实机验证 |
| 吐酸泰坦 | ✅ 已实机验证（引爆距离 2.1–2.3m） |
| 蟑龙 Dragonroach | ⚠️ **尚未实机验证**（几何与路由是上游自带且已自测，但本 mod 未上机确认） |
| 孢子泰坦（变体借用） | ⚠️ **尚未实机验证** —— 同目录证据强，但借用几何必须上机确认 |
| 其余 8 个虫洞变体 | ⚠️ 清单已覆盖，实机样本较少 |
| 未支持的敌人不被接管 | ✅ 已实机验证（其它敌人不产生接管日志） |

> **清单覆盖 ≠ 实机验证**，两者必须分开看。

## 性能（每帧开销）

mod 挂 `update`，每帧走一次 `tick`。口径：`tests/test_perf_probe.py`（每帧固定两件事）+
`tests/test_runtime_perf.py`（缓存回归）。

| 项 | 每帧 | 说明 |
|---|---|---|
| `Layout.capture` | ~40 读 / 3.3 KB | 无条件一次（五个引擎队列 + behavior 数组） |
| `Readiness.capture` | **1 次**（优化前 5~10 次） | 2026-09-30 起按帧缓存，见下 |
| `with_observation` | 每颗在飞的 G-60、每步 1 次 | 内含 `Search.capture`（~30–50 读） |

**2026-09-30 优化：`jobs_ready()` 按帧缓存。** 优化前它的调用点有
① tick 开头 ② 每次 `with_observation` 开头 ③ **`scope.validate()` 每次被 assert 时**
（`native_priority.step` 里出现多次）④ `disposal:step` 的 ready 回调 ——
一帧内**一颗**在飞的 G-60 就能触发 5~10 次，即 80~160 次读取/帧，多颗并发时是帧读取量的绝对大头。
缓存依据：`host:tick` 在**引擎主线程**里同步执行（所有读成立的前提）⇒ 同帧内 Readiness 观测值
不变 ⇒ 缓存与重读等价。**只在成功时缓存**，`Readiness.capture` 抛错照常上抛。

`perf` 行（每 600 帧 ≈ 10 秒一条，已进日志白名单）给出实测：

```
perf;frame=N;frames=K;ready=R;observe=O;layout_reads=L;layout_bytes=B
```

`ready` 应≈ `frames`（缓存生效）；若接近 `frames` 的 5 倍以上，说明缓存没起作用。

**2026-09-30 优化二：空闲降频。** 实机 `perf` 显示**没有 G-60 在场**时
`layout_reads≈93~100 读/帧`，且全部来自 `Layout.capture` 遍历 behavior 数组找 G-60
（数组常驻 ~55 项 ⇒ 55 次 identity 读 + 队列/头/guards）。用户反馈"没投掷时也有开销"
指的就是这部分纯空转。处置：上一次捕获**没有任何 G-60** ⇒ 之后隔 `IDLE_DIV=3` 帧才
观测一次；一旦发现 G-60 立即恢复每帧。代价：投掷后最多延迟 2 帧（≈33 ms）被发现，
远小于 G-60 到可接管 state-4 的时间（`EARLY_MIN_AGE`≥15 帧）；标记在 UI ring 里持续
数秒，不会漏读。

## 构建

```sh
python -B scripts/build.py       # 出包 -> dist/G60-BugHole-Lock-0.1.2.zip
python -B scripts/run_tests.py   # 跑测试（本机无 luajit/lua，用 lupa 跑）
python -B tests/test_bughole_scope.py           # 裁剪点 + 产物级验证
python -B tests/lua_syntax.py                   # 40 个模块语法（lupa/Lua 5.5）
python -B tests/check_lua51_compile.py          # ★ 用游戏自带 lua51.dll 做**真实编译**（Lua 5.1）
python -B tests/test_priority_fault_isolation.py  # 故障域隔离 + 通用接管 + sticky
python -B tests/test_runtime_perf.py            # 每帧读取开销回归
```

> ### ⚠️ 为什么必须跑 `check_lua51_compile.py`
> 本地其余检查都跑在 **lupa = Lua 5.5**，而游戏是 **Lua 5.1**。两者**函数级上限不同**：
>
> | 限制 | Lua 5.1 / LuaJIT | Lua 5.5（lupa） |
> |---|---|---|
> | 每函数 **upvalue** 数 | **60** | 255 |
> | 每函数 local 数 | 200 | 200 |
>
> **2026-09-30 实机事故**：为性能诊断往 `M.new` 加了 10 个独立局部变量，
> `host:tick` 内那个 `pcall(function() … end)` 的 upvalue 被顶到 **61 > 60**
> ⇒ **整个 chunk 编译失败** ⇒ 文件已正确部署、游戏日志却**一行都没有**（表现为"mod 没生效"）。
> 而 `lua_syntax.py`（5.5）**全绿**，硬是绕了一大圈才定位。
> ⇒ 该脚本用**游戏自己的 `bin/lua51.dll`** 编译 `build/entry.lua` + `src/g60/*.lua`，
> 等价于实机加载期检查；路径可用环境变量 `G60_LUA51` 覆盖，找不到时自动 SKIP（换机不误报）。
> **教训**：往 `M.new` 这类大函数里加独立局部变量前，先跑这个脚本；宁可直接塞进一个 table。

`scripts/run_tests.py` 会跳过 13 个 `*_windows` 套件——它们需要
`scripts/test_windows.py` 编译 `tests/native_minimal_fixture.c` 成 DLL 并用 Windows Lua 注入
`G60_FIXTURE_DLL`。**本机没有该环境，因此覆盖 `native_priority` / `experimental_runtime`
的集成测试未运行**；裁剪点由 `tests/test_bughole_scope.py` 做静态与产物级验证兜底。

## 裁剪了什么（相对上游的 diff 摘要）

| 文件 | 改动 |
|---|---|
| `src/g60/native_priority.lua` | 删除"从引擎候选列表按 rank 自动挑敌人"整段（`Candidates.capture` + `Policy.choose`）。**保留** structure_mark 分支——它才是"标记虫洞时打断敌人锁、优先去炸"的那段 |
| `src/g60/experimental_runtime.lua` | 5 处：① `excluded` 恒 `false` ② `has_weakpoint()` 收窄为只认 `structure_profiles` ③ priority 段入口加门控 ④ arrival 段加门控 ⑤ `result.released or reservations` → `result.released` ⑥ disposal 段加门控（详见"实机反馈"） |
| `compat/structure_profiles.lua` | 13 条 → 9 条，只留 `structure_hole`；删掉 3 条 `structure_tower` + 1 条 `structure_egg` |
| `src/g60/small_filter.lua` | **`excluded` 表整表清空**（见下方"实机反馈"） |
| **`addon/entry.lua.in`** | **`designed_targets_only=false`**（见下方"实机反馈"）；独立 `_G` 全局名 / 日志名 / 启动描述 |
| `scripts/build.py` | 独立 GUID / 资源名，`resource_id` 按新资源名现算（不再复用上游的） |

`compat/build.json`（88 条签名守卫 + 引擎签名）、`compat/titan_profile.lua`、
`compat/native_search_binding.lua`（`clear`/`orbit` 原生绑定）、`src/g60/native_minimal.lua`、
`src/g60/native_arrival.lua`（`explode` 调用）**均未改动**。

## 实机反馈与修复记录

### 目标筛选有**两道闸门**，我第一版只关了一道（裁剪 D / E）

`src/g60/selection_veto.lua:23` 的判据是两个条件的**与**：

```lua
if not Filter.excluded(selected.resource) and (not allowed or allowed(selected.resource)) then
    return {kind='keep'}, 'VANILLA_ALLOWED'
end
return {kind='search', clear_selection=true}, 'EXCLUDED_SELECTION'
```

| 闸门 | 上游默认 | 后果 | 修法 |
|---|---|---|---|
| `allowed` = `Allowlist(泰坦 + 弱点)` | 非 nil（`designed_targets_only=true`） | 非名单目标一律被清 selection | **裁剪 D**：`designed_targets_only=false` ⇒ `target_allowed=nil` ⇒ `not allowed` 恒真 |
| `Filter.excluded`（`small_filter.lua` 的表，9 个资源：8 种小虫 + Impaler 触手 + Hive Guard） | 非空 | **即使 `allowed` 变 nil，这半个条件仍生效** | **裁剪 E**：整表清空 |

⇒ 这两处合起来，才是"**G-60 只锁大型敌人、打不了中小型**"的**筛选层**原因，也正是官方包
"只能标记虫族敌人"的真正机制。虫洞同样不在名单里（上游自己的
`tests/structure_windows.lua:54` 就写着 `assert(not f.target_allowed(hole) ...)`）。

### ★ 但筛选层之外还有**三条接管路径**也在碰敌人的 G-60（裁剪 F / G / H）

第二轮实测（关掉 D+E 后）**仍然打不了中小型敌人**，日志给出决定性证据：

```
arrival_retired;entity=663;delivery=native_queue      ← 敌人在飞的 G-60 被本 mod 主动引爆
arrival_retired;entity=664;delivery=native_queue        （原生行为是让它自然过期）
```

根因是：`selection_veto` / `small_filter` 只是**筛选层**，而 runtime 里的**接管流程**
本身对**所有** state-4 G-60 无条件执行：

| 编号 | 位置 | 上游判据 | 实际影响 |
|---|---|---|---|
| **F** | priority 段入口 | `if priority then` | 为**每个** state-4 G-60 建 `tracked` 记录（顺带跑一次 `Search.capture`） |
| **F** | arrival 段入口 | `if arrival and old and not retired` | 敌人因此走 `arrival:step(target=nil, …, mask_only='search')` → **每帧 `scope.calls.clear(pair,nil)` + `orbit`**。引擎刚选中的中小型敌人被反复清掉；大型目标离得远、被重选的机会多，所以表现为"**只锁大型**" |
| **G** | priority 返回处理 | `elseif result.released or reservations` | 裁剪后 priority 对敌人**永远**返回 `{kind='keep',released=false}`，`or reservations` 恒真 ⇒ 每帧把 `old.force_search` 置 true ⇒ 虫洞标记来了以后 `titan_selected` 被 `not retry_search` 压掉 ⇒ **"标记了却不接管"** |
| **H** | disposal 段 | `if disposal and m.behavior_id==4 and state∈{3,4,5} and 到期` | 敌人 G-60 到期被本 mod 主动引爆（就是上面那 5 条 `arrival_retired` 的来源） |

**修法：三处都改成"只对本 mod 真正持有锁定的实体生效"**

```lua
if priority and (structure_mark or (old and (old.lock or old.titan))) then   -- F 入口
…
elseif result.released then old.lock=nil;old.force_search=true end            -- G
…
if arrival and old and (old.lock or old.titan) and not retired[m.id] then      -- F 出口
…
if disposal and held and m.behavior_id==4 and …                               -- H
```

⇒ **无虫洞标记时，本 mod 对任何 G-60 一个字节都不写**（不建 `tracked`、不跑
`Search.capture`、不调 `clear` / `orbit` / `explode`）—— **唯一例外见下节**。启动日志会打印：

```
enemy_tracking=VANILLA_UNTOUCHED;priority_gated=STRUCTURE_ONLY;
arrival_gated=HELD_LOCK_ONLY;disposal_gated=HELD_LOCK_ONLY
```

### ★★ 唯一例外：引擎选择否决（2026-09-29 起，用户要求"G-60 不追运输船 / 光能族增援飞船"）

上面那条"一个字节都不写"有一条**点名例外**：当引擎给一颗**非本 mod 持有**的 G-60
选中的目标落在**排除表**里时，会清掉那个选择。**排除表目前恰好两项**，
**每一项都必须带实机日志证据**（"名字对得上"不等于"就是那个哈希"）：

| 资源 | 是什么 | 证据 |
|---|---|---|
| `db90077e76faa025` | 机器人运输船 `cyborg_dropship` | `enemy_selection;entity=933;resource=db90077e76faa025` |
| `74e2285c01da4f71` | **光能族增援飞船** `illuminate_dropship` / 增援穿梭舰 | `enemy_selection;entity=1241;resource=74e2285c01da4f71` |

> ★ **只排除"增援"那一艘，不是"光能族飞船全排除"**：
> **营地穿梭舰**（`b3c9cdb79dc17937` / Warp Ship Landed）**不在表里** ——
> 它是玩家会**主动标记去炸**的目标（实机同一局：`structure_mark … ACCEPTED` 6 次 +
> `priority_locked` **14** 次）。用户 2026-10-01 特意强调"**注意是增援的飞船**"。
> 测试 `veto_list_excludes_landed_warp_ship` / `small_filter_landed_warp_ship_not_excluded` 钉住这一点。
>
> 另有两个**无证据**的变体**没有加**：`2ad2e055dad21f6e`（入侵的穿梭舰 / Warp Ship Invasion）
> 与 `01fe503dcd17847b`（营地的穿梭舰，另一个 id）—— 日志里从未被引擎选中过，
> 且后者与 b3c9… 同名 ⇒ 加了可能误伤玩家想炸的那艘。

**两个触发点**（`run_veto` 是单一实现，两处共用）：

```lua
-- take_gate.lua：无标记路径（原唯一入口）
if not (o.structure_mark or (old and (old.lock or old.titan))) then
    if o.selection_vetoed then return {veto=true,why='VETO_ENEMY_SELECTION'} end
    return {drive=false,why='no_mark_no_hold'}
end
```

```lua
-- experimental_runtime.lua：priority 段**之后**的兜底（2026-09-30 修复）
--   take_gate 的 veto 分支被 structure_mark 挡住 ⇒ 玩家标记了东西时不可达；
--   而 priority 会拒绝不该接管的目标（友方 ⇒ NOT_VALID_TARGET）
--   ⇒ 引擎给的运输船没人清。
if structure_mark and not abandoned
    and not (old and (old.lock or old.titan))    -- 持有说明正飞向自己的目标，不能清
    and Filter.excluded(m.selection_resource) then
    run_veto(m, m.selection_resource, 'after_priority')
end
```

> ⚠️ **2026-09-30 实机修复**：玩家标记**信标球**（友方）时，`structure_mark` 非 nil
> ⇒ take_gate 的 veto 不可达；而 priority 又正确拒绝了它（`NOT_VALID_TARGET`）
> ⇒ 引擎的运输船选择没人清，表现就是"运输船没被过滤"。
> 在此之前只有虫洞/泰坦，标记的一定会被接管 ⇒ setter 自然覆盖了运输船，缺口一直没暴露。

| 项 | 设计 |
|---|---|
| **只清不接管** | 不建 `tracked`、不设 `lock`/`titan` ⇒ `titan`/`arrival`/`disposal` 三条引导与引爆路径**都碰不到它**（它们一律要求 `old.lock` 或 `old.titan`） |
| **复用已实机验证的路径** | 走 `runner`（`native_minimal`）的 search 动作，不新增任何原生调用代码 |
| **立刻 `runner:release`** | 否则 search 成功后 `searching[key]` 恒真 ⇒ 每帧 `CONTINUE_SEARCH` ⇒ 每帧强行 `orbit`，把"不追踪"变成"一直盘旋" |
| **范围最小** | 排除表**恰好一项**，上游那 9 项（8 种小虫 + Impaler 触手 + Hive Guard）**不恢复** —— 它们的症状是"打不了中小型敌人"，正是当初清空该表的原因 |
| **可一键回退** | `enemy_veto_enabled=false` ⇒ 判据恒 false ⇒ 门控回落到 `no_mark_no_hold`，敌人侧完全原生 |
| **代价（知情）** | 与既有虫洞引导共用同一个 `runner`：一旦发生部分写入后失败，按既有惯例 `self.disabled`（fail-closed）。风险与既有引导路径同级 |

诊断（都进日志节流白名单）：

```
enemy_selection;entity=..;resource=..;vetoed=true|false   ← 只读，按 resource 去重
enemy_veto;entity=..;resource=..;result=search;why=EXCLUDED_SELECTION;via=no_mark|after_priority;frame=..
```

> ⚠️ `runner:step` 的返回契约是 **`(result, reason)`**。第一版我按 `(ok, result, why)` 取值，
> 结果 145 条日志全打成 `result=nil;why=nil`，成功失败都看不出来 —— **诊断把自己骗了一次**。

#### ★★ 与"不许追"互补的另一半：玩家**点名标记**这些载具 ⇒ 照样飞过去炸（2026-10-01）

用户要求："标记了运输船和增援的飞船，G60 也会飞过去爆炸。"
**这与上面的否决不冲突** —— 两条判据的方向不同，落点也不同：

| 场景 | 判据 | 结果 |
|---|---|---|
| 引擎**自己**给 G-60 选了运输船（玩家没标记它） | `Filter.excluded` | **清掉**该选择（上面那节） |
| 玩家**点名标记**运输船 / 增援飞船 | `Filter.marked_allowed` | **接管**：飞过去炸 |

**原来为什么不生效（两道闸，都在"玩家标记"这条链上）**：

1. **认领闸** —— `structure_ping` 的 `allowed` 走 `generic_claimed(resource)`，
   而它对排除表资源**直接判否** ⇒ 标记连读都不读，日志是 `structure_mark;…;reason=RESOURCE_NOT_SUPPORTED`。
2. **复核闸** —— 就算认领了，`priority` 的通用复核 `generic_validate` 拿
   `calls.target_valid`（引擎索敌"能不能当锁定目标"）当**硬门槛**。
   而运输船/增援飞船是**载具**，引擎索敌不把载具当合法目标 ⇒ 返回 false ⇒
   `generic_rejected;…;detail=NOT_VALID_TARGET`。

**改法**：`small_filter` 增加**同表反方向**的 `M.marked_allowed(resource)`，
只在**两条玩家标记路径**上开例外：

```lua
-- small_filter.lua（与 excluded 共用同一个集合 ⇒ 结构上不可能漂移）
function M.marked_allowed(resource) return excluded[resource] == true end

-- experimental_runtime.generic_claimed（认领闸）
if Filter.excluded(resource) then
    return Filter.marked_allowed(resource) == true   -- 玩家点名 ⇒ 放行
end

-- experimental_runtime 的 arrival 段 target 构造仍按 target_allowed 判（默认 nil ⇒ 不拦）
-- native_priority.generic_validate（复核闸）
if not valid_now then
    if not Filter.marked_allowed(e.resource) then return nil,'NOT_VALID_TARGET' end
    -- 放行，日志 generic_native_invalid_allowed;…（进节流白名单）
end
```

| 项 | 设计 |
|---|---|
| **只影响玩家点名** | 例外只写在"读标记/复核标记"这条链上；`take_gate` 的 veto、priority 之后的兜底 veto、`selection_veto.plan` **全部继续只看 `Filter.excluded`** ⇒ "引擎自选就清掉"的行为一字未变 |
| **其余 false 仍拒** | 只对表里那两个资源放开 ⇒ 标记**友方信标球 / 鹈鹕撤离机 / 平民**照样被 `NOT_VALID_TARGET` 挡住（它们的索敌结果同样是 false） |
| **仍要只读复核** | 放行不等于不检查：后面照旧要求实体可读 / identity 未变 / unit 未变 / 距离 < 200m ⇒ 真正已消失的实体照样被拒 |
| **可一键回退** | `generic_takeover_enabled=false` ⇒ 认领闸直接返回 false，退回"只接管虫洞/泰坦/变体" |

诊断：`generic_native_invalid_allowed;target=..;resource=..;context=GENERIC`
（出现它 = 索敌判否但被"点名载具"例外放行，**进日志节流白名单**）。
> 现在按正确顺序取（`result` = 结果表 `.kind`，`why` = reason），并加了 `frame` 便于量化频率。
> 测试 `veto_log_reads_tuple_in_order` 会读 `native_minimal.lua` 的 `return result,reason`
> 来钉住这个契约。

### ★ 实机结论（2026-09-29 晚，机器人战线）

```
enemy_veto            145 次（全部成功：result 表非空）
enemy_selection       entity=1170 的 db90077e76faa025 → vetoed=true
frame_error / disabled / guide_give_up / arrival_retired   ← 0（除启动期那条 pointer bound）
```

按实体分布：`1317`×30 / `1518`×28 / `1318`×26 / `1170`×21 / `1321`×18 / `1525`×12 / `1526`×8（其余各 1）。
⇒ 平均每颗 G-60 被否决 20~30 次，不是逐帧刷屏；entity=1170 在被否决后又选中了
`b92435fbf60f0748`（重型蹂躏者 MK2）⇒ **否决之后确实会转去打地面敌人**，不是白盘旋。

#### 反复否决的开销（量化，2026-09-30）

一次否决 = 一次 `with_observation` + 一次 `runner:step`：

| 组成 | 量 |
|---|---|
| `Search.capture` | ~30~50 次 `read`（固定 ~20-25 点 + `hash_index` 探测 + actor 循环，上界 16 但 1-3 次即 break）|
| `Readiness.capture` | 1 个 read 调用点 |
| `calls.clear` + `calls.orbit` | 2 次原生调用 |
| `runner:release` | 纯内存，0 |

`Search.capture` 自身预算是 **2048 次调用 / 64 KB** ⇒ 实际只用掉约 **2%**。

⇒ 145 次否决 ≈ 7000 次读取 ≈ **7 ms（整局总和）**；按每帧基线 ~15 次读取换算
≈ **470 帧**，在一局几万帧里占 **1% 量级**。

#### 为什么"反复"，以及为什么不改

**次数是引擎决定的，不是我们在刷屏**：只在"引擎**当前**选择 == 运输船"时才否决；
成功 `clear` 后选择为空 ⇒ 下一帧 `selection_flag==0` ⇒ 不再否决。
⇒ 145 次否决 = **引擎 145 次重新获取目标**。循环内生于"`clear` 是唯一可用杠杆"。

| 方案 | 结果 | 判定 |
|---|---|---|
| 节流（每 N 帧一次）| 调用数 ÷N | ❌ 会**削弱效果**：clear 后引擎 ~1 帧就重选，节流窗口内手雷会飞向运输船 |
| 否决几次后放弃 | 调用数 ↓ | ❌ 等于让运输船重新锁上 |
| 改 retarget（指向真实敌人）| 唯一根治 | ❌ `native_minimal` 只接受 `search`（守卫文件不能改）；`search_return.lua` 的 retarget 是死代码且需 `scores_current` 由已验证适配器提供；还会重开已移除的"自动挑敌人" |
| **不改** | — | ✅ **当前选择**（收益 ~1%，其余都是负收益或代价远超收益）|

#### 还有一条被排除的路：调"追踪参数"

有人会想到"把 G-60 的追踪数值调一下，让它干脆不锁运输船"。**这条路在数据上不成立** ——
G-60 的追踪数值**没有可调项**（2026-09-30 用游戏离线数据核实）：

| 游戏数据表 | 行数 | G-60 是否在内 |
|---|---|---|
| `SeekingMissileComponentData`（制导飞行：速度/转向/寿命/PID，共 14 个可调字段）| 29 | ❌ |
| `GuidanceTargetComponentData`（制导目标）| 6 | ❌ |
| `TargetingComponentData`（瞄准）| 295 | ❌ |
| `ThrowableComponentData`（投掷物）| 46（其它手雷在，如 `antitank_grenade`）| ❌ |
| `DetectorComponentData`（探测）| 319 | ❌ |

> 那 14 个可调字段属于 **5 把玩家导弹武器**（P-33 / P-92 / FAF-14 / WASP / MLS-4X），
> 见另一项目的 `SEEKING_MISSILE.md`。G-60 不在其中。

而且更彻底：G-60 的资源哈希 `62bf553e935c328e` 在 46 MB 的 `generated_entities.dl_bin`
里**以任何字节形式出现 0 次**（同法检索其它手雷/实体哈希都能命中）⇒ 该哈希不是实体资源哈希，
**连"它的组件"都无法在数据里定位**。

⇒ 结论：**"调追踪数值"不是一条可用杠杆。** 与上面"不改"的结论一致。

> ⚠️ **第一版过滤错了哈希 —— 已修正**（2026-09-29 当晚实机）
>
> 第一版只排除了 `db90077e76faa025`（社区表「哈希表-整合」第 112 行标"运输船 | Dropship"，
> 用户给的十进制 ID 也确实是它）。**但它从未被引擎选中过** —— 玩家看到的仍是"运输船没被过滤"。
>
> 用户日志给出了直接否证：
> ```
> enemy_selection;entity=933;resource=db90077e76faa025;vetoed=false
> ```
> `db90077e76faa025` → `content/fac_cyborgs/vehicles/cyborg_dropship/cyborg_dropship`
> ⇒ **引擎真正分配给 G-60 的运输船是机器人运输船 `cyborg_dropship`。**
> 而 `db90077e76faa025` 连游戏资源路径都反查不到。
>
> | 排除项 | 证据 |
> |---|---|
> | `db90077e76faa025` | ★ **实机日志**（entity=933 的引擎选择）+ 游戏路径 `cyborg_dropship` ⇒ 机器人运输船 |
> | `74e2285c01da4f71` | ★ **实机日志**（entity=1241）+ `illuminate_dropship` ⇒ **光能族增援飞船**（2026-10-01 加入） |
>
> ~~`98152772a72f7838`~~ 已**去除**（2026-09-29 用户决定）：社区表把它标为"运输船 | Dropship"，
> 但游戏资源路径反查不到、实机日志里从未被引擎选中过 —— **用户判断它是停落在地面上的运输船**
> （不再起飞投放兵力），G-60 本来就不会锁它 ⇒ 排除它没有意义。
> （原文此处误写成 `db90077e76faa025` —— 2026-10-01 更正为实际被去掉的那个哈希。）
>
> ★ **2026-10-01 加入 `74e2285c01da4f71`**：用户打光能族时报"光能族的飞船也要过滤
> （**注意是增援的飞船**）"。实机日志当天就给出证据
> `enemy_selection;entity=1241;resource=74e2285c01da4f71` —— 正好是本注释预留的那个哈希。
> ⚠️ **只加"增援"那一艘**：**营地穿梭舰** `b3c9cdb79dc17937`（Warp Ship Landed）**不加** ——
> 同一局里玩家**主动标记它去炸**（`structure_mark` ACCEPTED 6 次 + `priority_locked` 14 次）。
>
> ⚠️ 明确**不得**排除 `7b0f8449ca9d2da0`（`shuttle_dropship` = 鹈鹕 MK2，**玩家自己的撤离机**），
> 有断言 `veto_list_excludes_friendly_pelican` 钉住。
>
> **教训**：**"名字对得上"不等于"就是那个哈希"。** 社区表说它是运输船、实体表里也存在，
> 都不足以证明"引擎会把 G-60 指向它"。最终判据只能是**实机日志里真的出现过的哈希**。
> 现在测试里加了 `veto_list_covers_logged_dropship` —— 用**实机日志**反查：
> 日志出现过的运输船哈希必须都在排除表里。**这条断言如果早一天写，本次 bug 不会发生。**
>
> ⚠️ 明确**不得**排除 `7b0f8449ca9d2da0`（`shuttle_dropship` = 鹈鹕 MK2，**玩家自己的撤离机**）。
> 有断言 `veto_list_excludes_friendly_pelican` 钉住。
>
> `enemy_selection` / `enemy_veto` 保留，用于继续确认触发时机。

### 实机日志确认（第三轮，123 行）

虫洞链路**一直是通的**：

```
structure_mark;target=462;resource=8c31b749759cbd61;reason=ACCEPTED
priority_locked;entity=584;target=462;reason=PLAYER_MARK_STRUCTURE
titan_started / titan_aim / titan_stage …            ← 4 段完整航点
arrival_detonated;entity=584;target=462;distance=1.61   ← 虫洞被引爆
```

`arrival_detonated` 共 **4 次**（距离 1.61 / 1.64 / 1.73 / 1.82 m），`priority_locked` 4 次
—— **每一次标记的虫洞都炸成功了**。被拒的 6 条 `RESOURCE_NOT_SUPPORTED` 也都合理：
`51eea86b…`=`cha_scavenger_tier_1`（敌人）、`3d0e03e2…`=`cha_hunter_tier_1`（敌人）、
`16f397ca…`=带 `StratagemBallComponent`+`ThrowableComponent` 的**投掷物**。

### ★★ 追踪虫巢被拒：拿"索敌系统的函数"去否决虫洞（裁剪 K）

第五轮实测（274 行）**大成功**：22 个标记 / 21 次引爆，
`structure_lock_lost` **0 次**（裁剪 I 的 sticky 完全生效），
清单里的 `095686275a113614` 也炸了 2 次 —— **这条后来判定为错误**（当时把
"可标记的尖啸者巢"当成虫洞）。2026-09-29 已用两个独立来源确认它是**有生命值的巢体**，
并按用户要求从清单移除，见上文"2026-09-29 移除尖啸者巢"。
被拒的资源反查后确认全是**敌人**（`36aa99cce5e60146`=cha_boomer、
`a1f37bf2a40fbde4`=cha_warrior_plus、`16f397ca…`=投掷物）—— 正确。

**但用户反馈"追踪虫（stalker）的虫洞标记后不能炸"。日志给出精确证据**：

```
271 arrival_detonated     target=512   (爆点 116,-183,4)
272 structure_mark        target=511  resource=4776a1cf3f19a13b  ACCEPTED
273 structure_unavailable target=511  detail=NATIVE_TARGET_INVALID   ← 立刻否决，从未锁定
```

511 与刚被炸的 512 **位置相距甚远**（512 爆点 `(116,-183)`、513 爆点 `(-147,10)`），
所以不是连锁殉爆，而是**被原生校验直接否决**。

**根因（本 mod 最核心的一处自相矛盾）**：
`scope.calls.target_valid`（`game.dll+0x8858a0`）是**游戏索敌系统的一部分**，
它回答"引擎能不能把这个实体当作锁定目标"。而虫巢**没有 `HealthComponent`**
—— 正是这一点让引擎原生索敌排除它们（2026-09-24 我花三天证否了
"让虫巢成为合法目标"那条路，结论就是判据写在 `game.dll` 里）。

**本 mod 的核心恰恰是绕过索敌**（改导航目的地 + 直接调 `explode`），
却又拿**索敌系统的函数**去否决虫洞 —— 这正是 09-24 那三天的老问题以另一种形式回来了。

**修法**：`target_valid` 从**硬否决**降级为**软信号**。
硬门槛改成**纯只读校验**（实体可读 / `identity` 未变 / `unit` 未变 /
`pose.validate()` / 距离 < 200m —— 上游本来就有这些，只是被 `target_valid` 挡在前面）：

```lua
local function readonly_alive(id, identity)
    local ok, again = pcall(d.entity, id)
    if not ok or not again then return false, 'ENTITY_GONE' end
    if again.identity ~= identity then return false, 'IDENTITY_CHANGED' end
    local okp = pcall(d.position, again)
    if not okp then return false, 'POSITION_UNREADABLE' end
    return true, 'ALIVE_BY_READ'
end
```

`target_valid` 说 false 时做一次独立只读复核：**通过就继续接管**（并发
`structure_target_soft_invalid` 诊断），复核也失败才真的放弃。
⇒ 不会误杀"引擎不认但实际存在"的虫巢；真正已死的实体（读不到 identity）仍被拒绝。

启动自述新增 `target_valid=SOFT_SIGNAL`。

### ★ 虫洞锁被新标记劫持 + 清单漏了 8 个变体（裁剪 I / J）

第四轮实测（235 行日志）敌人侧已完全干净（`enemy_tracking=VANILLA_UNTOUCHED`，
只剩 1 次 `arrival_retired` 且属虫洞锁定期间），虫洞链路 12 次引爆成功。
但用户反馈"有的虫洞标记后不会飞过去炸"——**日志里是两个不同的原因**：

#### 原因一：G-60 飞行途中被新标记劫持（裁剪 I）

按 `entity` 分组统计"每颗 G-60 实际服务过哪些 target"，三条铁证：

```
G-60 #1083: 锁定562 -> 锁定559            ← 562 永久报废
G-60 #1107: 锁定562 -> 锁定564 -> 炸564
G-60 #1116: 锁定567 -> 锁定561 -> 炸561
```

上游 `native_priority.step` 的注释写着
`An explicit structure mark may interrupt an existing enemy lock`，
但**代码没有区分** `previous` 是「敌人锁」还是「已在飞行中的虫洞锁」——
只要来了新标记就抢占。你标记多个巢时，后标的会把前一个的 G-60 拉走。

**修法**：已在飞向某个虫洞的 G-60 **保持忠实**（sticky），只有该虫洞确实不可用
（实体消失 / `target_valid` 为假 / 超出 200m / unit 变了）才允许改投，并发
`structure_lock_lost` 诊断行区分原因。

**2026-09-30 补记（通用目标接管引入后暴露的缺口）**：sticky 的"可用性复核"原本
**只认虫洞白名单**（`structure_profiles`）。通用标记目标接管加入后，`previous.generic`
的目标每次都被判 `RESOURCE_NOT_IN_WHITELIST` ⇒ **每轮丢锁再重锁**（实机单局 66 次
`structure_lock_lost;RESOURCE_NOT_IN_WHITELIST`），表现为"通用目标不忠实 + 白算一遍"。
修法：sticky 对通用目标改走与新标记路径**同一套**复核 `generic_validate`
（`target_valid` 硬门槛 + 实体/identity 复核 + `d.position`），**不查虫洞白名单**；
两处共用同一实现，避免"只改一份副本"（本文件 334-338 行记过同类事故）。

#### 原因二：8 个同样能标记的虫巢类型不在清单里（裁剪 J）

离线核对（`generated_entities.dl_bin` 全表 + 107,744 条资源名）发现 **8 个实体**
的 `SpottableComponent.markerType` 都是 `EnemyMassive(3)`、`findable`/`startActive` 都开
⇒ **玩家能正常 ping 它们**，但上游 9 条 profile 没收录 ⇒ mod 报 `RESOURCE_NOT_SUPPORTED`
不接管。这就是"有些虫洞不能标记炸毁"的直接原因。

| 资源 | 实体 | 处理方式 |
|---|---|---|
| `7e4c6b45bcc45c3f` | bug_spawner_warrior_captive | 复用 **warrior** 基线（组件差异仅 `AnimationComponent`，碰撞参数一致） |
| `b6a181adcf547aeb` | bug_spawner_warrior_ceiling | 复用 **warrior** 基线（组件集完全相同） |
| `9d8632a79c2d9789` | bug_spawner_warrior_tutorial | 复用 **warrior** 基线（组件集完全相同） |
| `d666aa61d804d311` | bug_spawner_scavenger_captive | 复用 **scavenger** 基线（组件集完全相同） |
| ~~`095686275a113614`~~ | ~~尖啸者巢 Shrieker Nest~~ | **2026-09-29 移除**（用户要求：有生命值的巢体不接管）。两个独立来源确认它是巢体而非虫洞 |
| `688949109126ece4` | mechanical_bughole（机械虫洞） | ⚠ 无同模型基线，暂用最保守通用爆点 |
| `5cf84155e60c6e4d` | mechanical_bughole_scavenger | ⚠ 同上 |
| `0df874e208040d2f` | bug_spawner_base（基类） | 复用 **scavenger** 基线，防漏网 |

**"复用基线"不是编造**：逐条对比组件集与 `CollisionEventComponent` 参数，
4 个变体与各自基线**几乎逐条相同**（见 `compat/structure_profiles.lua` 的注释），
说明它们是**同一模型的不同摆放**，爆点相对模型的偏移不变。
唯一没有基线可依的是 `mechanical_bughole`（不同阵营的机械结构），
已明确标注 ⚠ —— 若炸不塌，删掉那一行即可，其余 16 条不受影响。

**清单从 9 → 16**（2026-09-27 加到 17，2026-09-29 按用户要求移除尖啸者巢）。
仍**不接管**：**尖啸者巢** `bug_spawner_shrieker`、孢子菇 ×2（`bug_fog_generator` / `_large`）、任务虫卵
（`embryo_01`）—— 它们不是虫洞。

#### 一个"看起来像 bug 但其实正确"的现象

日志里 8 次 `structure_unavailable;detail=NATIVE_TARGET_INVALID` 里有 7 次是
**巢已被炸塌**后的正常失效。只有 `559` 那次不同：它和 `560` 挨得太近，
`560` 被引爆时把 `559` 一起带走了 —— **连锁殉爆，属于合理行为**。

### ★ 通用目标的锁"每帧重锁"：`generic` 标志被 `track` 丢掉（2026-10-01）

**症状**：通用（非虫洞）目标锁不住 —— 日志刷 `structure_lock_lost;target=…;detail=RESOURCE_NOT_IN_WHITELIST`。

2026-09-30 就为这件事写过一段"通用目标的 sticky"代码（`if previous.generic then …`，
注释写"让通用锁真正 sticky"），但**那段分支从未执行过**：

```lua
-- native_priority.lua：这张表就是运行时存进 old.lock 的对象
track={id=…,identity=…,unit=…,raw=…,score=…,marked_structure=true}   -- ← 少了 generic
```

`generic=true` 只在 `generic_validate` 返回的 row 上，而 `track` **重建**时没把它带下去
⇒ 下一帧 `previous.generic` 恒为 `nil` ⇒ 通用目标落进"虫洞白名单复核"那一支 ⇒
既丢锁（每帧从当前标记重新派生，**不忠实**），又打出**误导性**日志
（通用目标本来就不该出现在虫洞白名单里）。

**实机双重铁证**（23:39 那局）：

1. 该分支独有的日志后缀 `;generic=true` —— 全日志 **0 次**；
2. 24 条 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST` **100% 落在非白名单目标**
   （巨兽级强袭虫 ×9 / 穿刺虫 ×3 / 抚育喷涌虫 ×2 / 孢子强袭虫 / 阿尔法指挥官…），
   而真虫洞 MK8 / MK9 **一次都没丢锁**。

**修法**：两处 `track` 构造（早期 state2/3 路径 + 主路径）都补上 `generic=chosen.generic`。
守门做了**穷举**断言 —— 每一处 `track` 都必须带 `generic`（不允许只改一份，
本仓库已因"只改一份副本"出过两次越界事故）；并做过**变异测试**验证守门真能报警。

> ⚠ **行为变化（知情）**：修好后通用锁会像虫洞锁一样**忠实** —— 一旦锁上某个被标记的
> 敌人，之后 ping 别的目标**不会**把它抢走（只在该实体失效/死亡时释放）。
> 这与上游英文注释 `An explicit structure mark may interrupt an existing enemy lock`
> 有出入（上游允许"结构标记打断敌人锁"）。当前按本工程既有注释的意图实现
> （"已经在飞行的 G-60 保持忠实"）；若你希望"标记虫洞能抢回被敌人锁住的 G-60"，
> 需要额外加一条**结构标记抢占**判据 —— 那是独立的一次改动，未做。

## 关于虫洞清单（历史说明）

离线核对（`generated_entities.dl_bin` 全表 + 107,744 条资源名）：

- 9 个 profile 覆盖了**全部 9 种带 `UnitComponent` 的普通 `bug_spawner_*`**
  （bile_titan 泰坦巢 / boomer / hiveguard / hunter / prowler / scavenger / spitter / stalker / warrior）
- **未收录但也带 `Unit` 的**：`bug_spawner_shrieker`（尖啸者巢）、
  `bug_spawner_{warrior,scavenger}_captive`、`bug_spawner_warrior_ceiling`、
  `bug_spawner_warrior_tutorial`、`mechanical_bughole(_scavenger)`（机械虫洞）、`bug_spawner_base`
- profile 里的 `nodes`（骨架节点数）/ `offset` / `belly_hash` 是**上游实机标定值**。
  **我没有为新类型编造这些数字** —— 猜错会让 G-60 飞到错误的爆点甚至炸不塌。
  扩充需要实机标定，或等上游补充。

### 如果虫洞仍然偶尔不去，按日志顺序定位

| 看到什么 | 卡在哪 |
|---|---|
| `structure_mark;…;reason=RESOURCE_NOT_SUPPORTED` | **该资源不在 9 个 profile 里**（敌人 / 投掷物 / 未收录巢型）—— 这不是 bug |
| 有 `structure_mark;…;reason=ACCEPTED` 但无 `priority_locked;…` | 标记读到了但锁定被拒 —— 看紧跟其后的 `structure_unavailable;detail=…` |
| 有 `priority_locked` 但无 `titan_aim;…;point=…` | 进入了朝虫洞飞的状态，但**爆点没算出来** |
| 有 `titan_aim` 但无 `arrival_detonated` | 飞到了但到达判定没过（多半是 `front_distance` / 爆点高度带） |
| `titan_skipped;reason=…` / `arrival_skipped;detail=…` / `priority_skipped;detail=…` | **把这几行的 reason 原样发我**，能直接定位到哪一层拒绝 |
| 开头一串 `frame_error;detail=…: pointer bound` | 正常现象：进任务初期引擎指针未就绪，会自愈（前 ~50 帧） |
| 连 `version=` 都没有 | 包没被 loader 加载，看 `BingusSharedLoader.log` |

## 许可与来源

代码 MIT（见 `LICENSE`）。**派生自 etxp/HD2-G60-Smart-Targeting**，原作者版权声明
按 MIT 要求原样保留；本衍生作品的版权归 LovedeHua。上游来源与 AI 辅助开发声明见
`THIRD_PARTY_NOTICES.md`，上游原始 README 保留为 `README.upstream.md` / `README.upstream.zh-TW.md`。
游戏数据与美术资源权利另计（见该文件）。
