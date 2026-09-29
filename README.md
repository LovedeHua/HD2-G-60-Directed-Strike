# G-60 Bug Hole Lock —— 标记虫洞 / 大型虫族 专用版

《绝地潜兵2》G-60 反坦克追踪者手雷的**目标专用**接管 mod。
只接管**玩家标记的虫洞** 与 **吐酸泰坦 / 孢子泰坦 / 蟑龙**。其余全部交还游戏原生 ——
唯一例外是"不让 G-60 追踪运输船"（见下文"唯一例外"一节，可一键关闭）。

> 本工程是 [`etxp/HD2-G60-Smart-Targeting`](https://github.com/etxp/HD2-G60-Smart-Targeting)
> 0.1-beta.1 的**裁剪派生版**（源码 MIT / AI-assisted）。裁剪只动"决策层"，
> **签名守卫、持锁窗口、状态机白名单、身份复验等安全机制全部原样保留**。
> 上游原始说明保留在 `README.upstream.md` / `README.upstream.zh-TW.md`（仅供对照，**不打进包**）。

---

## 它做什么（只有两件事）

**你标记虫洞或吐酸泰坦 → G-60 接管并飞过去炸它。** 其他一概不碰。

| 情况 | 行为 |
|---|---|
| 你标记了下面 16 个虫洞之一 | **本 mod 接管**：打断 G-60 当前的敌人锁定，改为朝该虫洞飞去，到达后引爆 |
| 你标记了**吐酸泰坦**（Bile Titan） | **本 mod 接管**：走为体型标定的航路（around → descend → under → attack），在腹部下方引爆 |
| 你标记了**蟑龙**（Dragonroach） | **本 mod 接管**：飞到胸腔气囊下方引爆 |
| 引擎自己选中了吐酸泰坦 / 蟑龙（你没标记） | 同上接管 |
| 虫洞与泰坦同时被标记 | **虫洞优先** |
| 你没标记任何支持目标 | **本 mod 完全不插手**，G-60 按游戏原生 TargetLock 打敌人 |
| 引擎给 G-60 选了**运输船** | 例外：清掉该选择（`enemy_veto_enabled`，见下文"唯一例外"） |
| 你标记了其他敌人 / 尖啸者巢 / 孢子菇 / 任务虫卵 | **本 mod 不接管**，G-60 原生处理 |

上游那套「按固定顺位自动追打 Bile Titan / Impaler / Spore Charger / Charger」以及
「按部位弱点瞄准」**已全部移除**——那正是它"只能标记虫族敌人、不能标记机器人/光能族"的原因。
本 mod 只接管**吐酸泰坦这一种敌人**，且是精确资源哈希匹配，不做任何顺位或自动挑选。

`titan_enabled=false` 关闭泰坦接管，`titan_variants_enabled=false` 只关掉变体
（保留普通泰坦），`dragonroach_enabled=false` 关闭蟑龙接管。全部设 false 即退回"只打虫洞"。

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

**不接管**：`weakpoint_profiles.lua` 里另外登记的 5 种敌人 —— 穿刺者（Impaler）、
孢子冲锋兵（Spore Charger）、冲锋兵巨兽（Charger Behemoth ×3）、冲锋兵（Charger）。
它们仍由引擎原生 TargetLock 处理。

> 放行用的是**精确资源哈希**，不按 `kind` 推断 —— 按 kind 会把同类型的其它敌人
> 一起拉进来（例如 Spore Charger 也是 `head`）。

## 安装

1. 关闭游戏，安装 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)
   （**API 1，v15+**，需 addon discovery）。
2. 把 `G60-BugHole-Lock-0.1.0.zip` 导入 mod 管理器。
3. **与上游官方包二选一**——两个包都会改 G-60 的决策，同时启用会打架。
   本包 GUID `9c1d4e77-…`，官方包 GUID `58a16a67-…`。
4. Purge / Deploy 后重启游戏。

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

启动时那行会明确打印本包的能力边界：
`build=BUGHOLE_ONLY;scope=marked_bughole_only;bughole_profiles=16;enemy_priority=REMOVED;weakpoints=REMOVED;shrieker_spewer_egg=REMOVED;unmarked_behavior=VANILLA`

## 已知限制

- **版本敏感**：88 条 game.dll 机器码签名 + exe 签名守卫。游戏更新后若不匹配会**直接停用**
  （这是刻意设计：宁可不做，也不要在错误的地址上执行原生调用）。
- **`native_lifetime_verified=false`**：上游自己标注"原生对象生命周期证明未完成"。
- **不是寻路器**：爆点来自模型节点换算，地形/移动目标/虫腿仍可能干扰。
- **泰坦离地太近时会主动放弃**：`titan_route` 要求爆点在地面之上，泰坦贴地时
  `standoff=2.5` 会落到地面以下 ⇒ 日志出现
  `titan_skipped;reason=Titan has insufficient blast standoff clearance`。
  这是保护设计（避免炸到地面），不是缺陷。
- **多颗 G-60 同时锁定同一目标**：先到的炸掉后，后来的会识别为"爆炸已触发"并收尾
  （`arrival_already_exploded`），不会无限盘旋。

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

## 构建

```sh
python -B scripts/build.py       # 出包 -> dist/G60-BugHole-Lock-0.1.0.zip
python -B scripts/run_tests.py   # 跑测试（本机无 luajit/lua，用 lupa 跑）
python -B tests/test_bughole_scope.py   # 裁剪点 + 产物级验证
```

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

### ★★ 唯一例外：引擎选择否决（2026-09-29，用户要求"G-60 不追踪运输船"）

上面那条"一个字节都不写"有一条**点名例外**：当引擎给一颗**非本 mod 持有**的 G-60
选中的目标落在**排除表**里时（目前只有运输船 `98152772a72f7838`），会清掉那个选择。

```lua
-- take_gate.lua：放在 no_mark_no_hold **之后** ⇒ 有虫洞标记时永不触发
if not (o.structure_mark or (old and (old.lock or old.titan))) then
    if o.selection_vetoed then
        return {drive=false,early=false,veto=true,why='VETO_ENEMY_SELECTION'}
    end
    return {drive=false,early=false,why='no_mark_no_hold'}
end
```

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
enemy_veto;entity=..;resource=..;result=..;why=..         ← 实际执行了否决
```

> ⚠️ **第一版过滤错了哈希 —— 已修正**（2026-09-29 当晚实机）
>
> 第一版只排除了 `98152772a72f7838`（社区表「哈希表-整合」第 112 行标"运输船 | Dropship"，
> 用户给的十进制 ID 也确实是它）。**但它从未被引擎选中过** —— 玩家看到的仍是"运输船没被过滤"。
>
> 用户日志给出了直接否证：
> ```
> enemy_selection;entity=933;resource=db90077e76faa025;vetoed=false
> ```
> `db90077e76faa025` → `content/fac_cyborgs/vehicles/cyborg_dropship/cyborg_dropship`
> ⇒ **引擎真正分配给 G-60 的运输船是机器人运输船 `cyborg_dropship`。**
> 而 `98152772a72f7838` 连游戏资源路径都反查不到。
>
> | 排除项 | 证据 |
> |---|---|
> | `db90077e76faa025` | ★ **实机日志**（entity=933 的引擎选择）+ 游戏路径 `cyborg_dropship` |
> | `98152772a72f7838` | 用户点名 + 社区表"运输船"；**暂无实机证据**（保留，无害） |
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

### 关于虫洞清单（历史说明）

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
