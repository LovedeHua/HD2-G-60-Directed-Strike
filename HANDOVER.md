# G-60 Directed Strike · 无标记优先级改派 —— 交接文档

> 交接时间：2026-10-16 · 分支 `master` · 仓库 `D:\桌面\Hd2 mod test\G60分支`
> 版本串 `0.1.25-bughole`（fork 自 `g60-bughole-lock`）
> **本文写给接手的人（或下一轮会话的我自己）：哪些已落地、哪些验证过、哪些没验证、坑在哪。**
>
> ★★ **2026-10-16 二次修订**：接手人复核发现初版把**最关键的一环写错了** ——
> 改派功能**从未生效**（实机 `spread_pick;` 0 条），且 §5.2 的 upvalue 候选表**整张无效**。
> 本版已按实测重写 §2.2 / §3.4 / §3.5 / §4 / §5 / §7，并修好代码。
> **运行期行为仍未验证**（只有用户能上机确认）。

---

## 1. 功能是什么（用户原话与最终规则）

**需求**：「无标记时投掷多颗手雷，多颗大概率会锁定同一个目标，优化成无标记时每个敌人只能接受一颗手雷」，
并按用户给的**分阵营优先级**挑目标（用户逐条审过 11 轮修正）。

**最终优先级名册**（`rank` 越小越优先；名册里没有的 = 该阵营「其他敌人」，最低优先）：

| 阵营 | 档位（从高到低） |
|---|---|
| 终结族 | 1 蟑龙 ＞ 2 吐酸泰坦(含变体) ＞ 3 穿刺虫 ＞ 4 强袭虫(含变体) ＞ 5 阿尔法指挥官 ＞ 6 喷涌虫(胆汁+抚育+钻地同档) ＞ **》档位间隙** ＞ 7 追踪虫 / 掠食追踪虫(同档) |
| 机器人 | 1 移动工厂、噪轰引擎 ＞ 2 坦克(湮灭/碎裂/铁幕等全体) 、战争纵步者 ＞ 3 巨型者(含变体) ＞ 4 **炮艇** ＞ 5 强化侦察纵步者、激进先锋、惑乱者(男/女) ＞ 6 蹂躏者(含变体) |
| 光能族 | 1 猎杀器 ＞ 2 证真者、御门者、粉碎者 ＞ 3 崇高监视者、新月监视者、肉瘤体 ＞ 4 监视者 ＞ 5 突入者、悲怜体 |

**判定规则（用户 11 条修正后，全部写进了生成器与守门）**：
1. 英文名优先匹配家族词；**中文名只按开头匹配**（防「蹂躏者 MK2 移动工厂生产」被「移动工厂」劫持）。
2. 中文名的空格尾段 = 子部件 ⇒ 剔除；但尾段以「带」开头是**本体变体** ⇒ 收录（如「移动工厂 带干扰塔」）。
3. 硬排除：**反坦克 / Anti-Tank**（"含 Tank" 会误伤）、结构类（洞/巢）、`(Model)/(Projectile)/(Shell)`、备注=废案。
4. **一条只进一个档**（长关键词优先）—— 否则崇高/新月监视者会被 `Overseer` 重复收进两档。
5. 军团变体同档；「生产/刷新」类只要是单位本体就收；炮艇必须收（不能因为"炮"字被剔）。

---

## 2. 代码在哪、怎么跑（已落地的实现）

### 2.1 名册（数据）

| 项 | 位置 |
|---|---|
| 名册 | `src/g60/spread_priority.lua`（**63 条**，文件头写明来源表、审阅日期、全部判定规则；**由脚本从 xlsx 生成，不要手改**）|
| 生成器 | 临时脚本（从 `D:\桌面\绝地潜兵2哈希整合表.xlsx` / 工作表 `哈希表-整合` 生成）；逻辑要点见 §1 |
| 人审草稿 | `SPREAD_PRIORITY_DRAFT.md`（仓库根，作为审阅过程记录）|
| 查询原语 | `env.spread_rank(resource)` → rank / `env.spread_faction(resource)` → 阵营（运行时加载时建 O(1) 反查表 `P.spread_index`）|

### 2.2 改派（逻辑）

> ⚠⚠ **本节已于 2026-10-16 二次修正如实重写。** 初版描述的是**从未生效**的实现
> （实机 `spread_pick;` **0 条**），照它排查会走错方向。根因见下。

全部在 `src/g60/experimental_runtime.lua`：

| 步 | 位置 | 做什么 |
|---|---|---|
| 接线 | entry `addon/entry.lua.in` env 字面量 | `spread_priority=SpreadPriority,spread_candidates=Candidates,`（**必须用构建别名**，见 §3.2）|
| 算候选 | ★ **`local gate=TakeGate.decide{` 之前**（不再在 `if enters then` 内） | 条件 `reservations and 完全无标记 and env.spread_candidates` → 上下文**由本帧观测行**构造（`m.identity_bytes` + `m.entity_address`，**不额外付 `Search.capture`**）→ `Candidates.capture(TargetData.new(read,base,env.exe),ctx)` → 按 `env.spread_rank` 取**最低 rank**（同 rank 取候选表**更早**的 = 引擎评分顺序）→ 过滤 `reservations:available(owner,ent.identity)` → 存 `P.spread_pick_row` → 日志 `spread_pick;…`。整块用 `do…end` 限定作用域（**不新增被闭包捕获的外层 local**）|
| 开门 | `local gate=TakeGate.decide{ … spread_armed=P.spread_pick_row~=nil }` | take_gate 里 `spread_armed` 让门不再落进 `no_mark_no_hold`；**排在否决之后**，且**复用既有尾段**（早期门槛 / `can_guide` 全不变）|
| 消费 | `if reservations then my_structure=my_mark end` **之后** | `if reservations and my_structure==nil and P.spread_pick_row then my_mark=P.spread_pick_row; my_structure=my_mark; reservations:claim/keep_only(…) end`，随后 `P.spread_pick_row=nil` |
| 驱动 | 既有 `priority:step(scope,old.lock,my_mark,old.blocked,available,my_structure)` | **不新增任何写途径** |

**生效条件**：完全无标记（无 `structure_mark`、无 ping 点、无 `old.lock/titan/point`）。有标记的路径不动。
**失败方向**：拿不到候选（`Candidates.capture` 断言失败 / 候选全不可用）⇒ 整块跳过（静默 no-op，**不会崩**）。

**★ 初版为什么从未生效（三重阻塞，各自都能独立致死）**：

1. **`P.cap=ok_c and cap or nil` 写在 `local ok_c,cap=…` 的上一行** ⇒ Lua 的 local
   作用域从声明语句**之后**才开始 ⇒ 读到的是**全局**（恒 nil）⇒ 消费门 `… and P.cap`
   永远为假。（真值语义已用 lupa 现场复现。）
2. 该缓存还被关在 `early_nav_probe`（默认 `false`）且只在 state 2/3 的调试块里。
3. **★ 最致命**：整块写在 `if enters then` 内，而 `enters=priority~=nil and gate.drive`。
   "完全无标记"时 `take_gate` 返回 `no_mark_no_hold`（`gate.drive=false`）⇒ **结构性不可达**；
   而 `old` 又只在该块内创建 ⇒ **先有鸡还是先有蛋**。

⇒ 教训：**"包里有这段代码 + 加载器 loaded" 完全不能证明它跑过**。判据只有日志行。
   `P.cap` 这条路顺带说明：缓存点必须由**真实观测**供给，而不是某个默认关闭的实验块。

---

## 3. 血泪坑（**踩过，务必别再踩**）

### 3.1 ★★★ Lua 5.1 的「每函数 60 个 upvalue」上限
tick 闭包**本来就用满 60 个** ⇒ 只要引用**一个新的外层局部**，整份 chunk **编译失败 ⇒ mod 无法加载**。
- 实机证据：`build/entry.lua:13079: function at line 9886 has more than 60 upvalues`。
- **唯一防线**：`tests/check_lua51_compile.py`（`lupa/5.5` 看不见这个错误）。
- 对策：凡 tick 要用的东西，**一律挂 `env` / `P`**（它们已是 upvalue ⇒ 零新增）。本项目 2026-10-10 有同款实机事故。
- 同族限制：LuaJIT 的**单函数 65535 字节码指令**上限会让加载器**静默跳过**整个 mod（装了却什么都不做、日志无行）。

### 3.2 打包机制（我猜错过两次，这里是**已确认**的）
- `compat/build.json` 的 `aliases` 是**「模块 → 局部别名」映射**，不是文件清单；且 build.py 只在 **`src/g60/<name>.lua`** 找模块（`ROOT/'src/g60'/(name+'.lua')`）。
- 因此：名册必须放 `src/g60/`、`aliases` 用**裸键**（`"spread_priority": "SpreadPriority"`，带 `g60.` 前缀会让 build 去找 `src/g60/g60.spread_priority.lua` 而崩）。
- `compat/*.lua` 里的数据表（`structure_profiles` 等）**不在 aliases 里也能进包**；但 `require('g60.X')` 必须 X 在 aliases 中，否则 build 报 `requires unknown module`。
- 包内核对是唯一判据（我用的命令：解 `.patch_0` → 头 192 字节后取长度 → 在文本里查关键词）。

### 3.3 未声明的全局名 = 静默失效
引用一个**未声明的全局**（如 `SpreadPriority`，因缺 require）**不占 upvalue、编译也过**，但运行期恒为 nil ⇒ 功能静默失效。
**并且**用错名字（`SpreadPriority2`/`SpreadCandidates`，非构建别名）会让 `env.spread_*` 为 nil ⇒ `env.spread_candidates.capture` **每帧 nil 索引** ⇒ 被 tick 的 xpcall 抓住 ⇒ **整帧剩余工作全丢**。

### 3.4 作用域（★ 已两次踩坑，这条最重要的是**门控前后的位置**）
- 改派块**不能**放在 `if enters then` 内。`enters=priority~=nil and gate.drive`，
  而无标记时 `gate.drive=false` ⇒ 结构性不可达（初版就死在这里）。
- 改派块**必须**放在 `local gate=TakeGate.decide{` **之前**（要算出 `spread_armed` 才能开门）。
- **消费**放在 `my_structure` 那一行之后（那里 `my_mark` 才存在）。放错 ⇒ 静默空转。
- ★ 同类第二坑：判据也可能被写在 **early return 之后**。`take_gate` 里第一版我把
  `if o.spread_armed then … end` 追加在 `no_mark_no_hold` 那个 `return` **之后**
  ⇒ 永远到不了。**凡新增"放行条件"，一定写进那道 `if` 的条件里**（与 `o.point_armed` 同处）。
- ★ 第三坑：新增放行条件**别抢走 veto 的优先级**（否决必须排在前面，它是用户确认过的语义）。

### 3.5 守门的两个"假绿灯"（★ 都真实发生过）
1. **断言插在汇总之后** ⇒ 一条都不计入。看 `RESULT: ALL PASS (N checks)` 的 **N 有没有变大**。
2. **★ 裸子串断言会把 bug 钉成"正确"**：初版守门写的是
   `"P.cap=ok_c and cap or nil" in _RT` —— 它**只匹配文本、不校验顺序**，
   而那行恰恰写在 `local ok_c,cap=…` **之前**（恒 nil）⇒ 守门全绿而功能是死的。
   ⇒ **凡断言"接线正确"，要断言顺序/可达性（`index()` 比较）或直接真求值**。

### 3.6 其它老坑
- 中文串里出现 ASCII 双引号 ⇒ 生成的 `.py` 直接 `SyntaxError`（踩过 6 次）；中文文本里用「」。
- PowerShell 里内联 `python -c` 带 `\"` 会被解析坏 ⇒ 写脚本文件；含中文的 Lua 片段用**单引号 here-string** 最稳。
- `python -c` 里写 Lua 长括号 `[==[ ]==]` 会被 Python 当语法错（踩过）⇒ 用普通三引号字符串。
- 用 lupa 且 `encoding=None` 时，Lua 表的字符串键要**按 bytes 取**（`t[b"key"]`），否则恒得 nil（我自己踩过一次，得出过一个完全错误的"门控不放行"结论）。
- 诊断被节流掉 = 诊断不存在；看不到 = 无法确认。

---

## 4. 验证状态（截至本文件）

| 项 | 结果 |
|---|---|
| 编译门禁（Lua5.1，upvalue 上限） | **48 文件全过** ✅ |
| 局部序 / 字段引用门禁 | ✅ / ✅ |
| 构建 | 正常（`spread_pick` 与名册均在包内；识别版本看启动行的 `entry_build;id=`，**别用 `entry_sha256`** —— 它含 git 指纹，每次提交都变）|
| 守门 `tests/test_spread_priority.py` | **34 checks 全过**（名册数据 + 归属断言 + 改派接线/红线/可达性）|
| 守门 `tests/test_spread_gate.py` | **8 checks 全过**（★ 门控真求值：放行/收窄/不越过 veto）|
| 故障隔离 | **814** ✅ |
| 全量 `scripts/run_tests.py` | **204 passed / 0 failed / 0 crashed** ✅ |
| **运行期行为** | ⬜ **仍未验证**（需上机看日志 `spread_pick;…`）|

**名册正确性的独立证据**：守门里有一条 `xlsx_cross_check` —— 名册每条哈希都能在源表 `绝地潜兵2哈希整合表.xlsx` 里找到。

> ⚠ **关于 `tests/test_bughole_scope.py` / `tests/test_priority_fault_isolation.py` 之外的门禁**：
> `scripts/run_tests.py` **只跑 Lua 套件**，它**不会**运行那些 `.py` 守门。
> 所以"全量 204 passed"**不能**代替逐个跑 `.py` 守门（见 §6 清单）。
> 另外 `tests/test_bughole_scope.py` 目前**有 29 条失败**（`profiles_count_is_16`、
> `build_json_parses`、"baseline missing" 等），**在本次改动之前的 HEAD 上就已如此**
> —— 它钉的是旧裁剪基线（16 条 profile），与本轮无关，但**别把它当绿灯**。

---

## 5. 未完成清单（按优先级）

### 5.1 ★★ 上机确认改派真的生效（最高优先，只有用户能做）
**前置**：必须用**修好之后**的包（即含本次修复的构建）。
识别办法：看启动日志第 4 行的 `entry_build;id=…` ——
**旧包是 `id=619c4f3+dirty`**（那一版无论怎么玩都不会出现 `spread_pick;`，
它是结构性恒假的）；新包应是 `id=<本次提交之后>`（提交 `204913e` 及其后）。

> ⚠ **不要用 `entry_sha256` 当识别依据**：`scripts/build.py` 会把
> `git rev-parse --short HEAD` + `+dirty` 编进入口（构建指纹，见 build.py:30-48）
> ⇒ 每提交一次、甚至工作区一脏，`entry_sha256` 就变。**稳定的判据是 `entry_build;id=`。**

无标记连扔 2~3 颗，看日志：
```
spread_pick;entity=…;target=…;resource=…;rank=…;why=PRIORITY;candidates=N;frame=…
```
- **出现** ⇒ 候选计算通了（每个敌人只吃一颗、优先 rank 高者）。**是否"正确生效"仍需看行为**（见下）。
- **不出现** ⇒ 按 §2.2 的链路逐点查。失败方向安全（不崩）。

⚠ 上机时**另需重点确认两件事**（都是本工程踩过的坑）：
1. **泰坦/蟑龙会不会被改派带坏爆点**。名册里 rank 1~2 就是 蟑龙 / 吐酸泰坦 / 孢子泰坦，
   而用户两次实测确认过："在泰坦链前面插第二个驱动者会毁掉爆点"（A/C 路事故）。
   本仓已有一条 `titan_approach` 在 ~10 m **放手**的补救，但**改派新增了一条目标来源**，
   必须实测泰坦爆点是否仍然正确（`titan_blast belly_dz` 应为负、且能颗秒）。
2. **`alloc_cap;…;src=NO_MARK_ONE_PER_ENEMY` 是否出现** —— 它是"无标记 ⇒ cap=1"那条
   规则的可见证据（旧日志里 `marks=0` 一次都没出现过）。

> ⚠ 另：本次**未改** `scripts/build.py` 的指纹逻辑，但每跑一次构建都会重写
> `evidence/derived-payload.json`（它进了版本库）⇒ 工作区会显示该文件被改。
> 这是既有行为，不是本次引入的。

### 5.2 upvalue 减负（把余量从 0 做到 ≥5）

现状：tick 闭包**正好 60**，零余量。★ 已用游戏自带 `lua51.dll` **实测确认余量 = 0**
（往闭包体加 1 个被捕获的外层 local ⇒ `function at line 9885 has more than 60 upvalues`）。

> ⚠⚠ **初版这张"候选表"整张都是错的，已作废。** 它按**全文件引用次数**选名字，
> 而那 12 个名字（`Memory`/`explode_type`/`SET`/`Binding`/`WeakpointProfiles`/
> `PriorityCatalog`/`FuseProfile`…）**全部声明在兄弟函数里**（作用域深度 1~2），
> **不在 tick 闭包的祖先链上** ⇒ 从闭包引用它们等于**引用全局**，既不占 upvalue，
> 搬成 `P.X` 也**一分余量都换不来**。（判定法：往闭包体加一次引用，若编译**通过**
> 则它要么已是 upvalue、要么是全局；还得再看它声明在哪个函数里。）

**实测有效的候选**（= 真的在闭包祖先链上 + 闭包内确有引用；按改造成本升序）：

| 名字 | 全文件引用 | 备注 |
|---|---|---|
| `GUIDE_FAIL_LIMIT` | 2 | |
| `blast_safe_hold_td` | 2 | |
| `OBSERVE_FAIL_LIMIT` | 3 | |
| `release_all` | 3 | |
| `EARLY_MIN_AGE` | 3 | |
| `last_link_status` / `last_time` / `last_structure_issue` | 3 | |
| `note_contention` / `saw_state4` / `skipped_probe` / `target_position` / `veto_seen` | 3 | |

搬 5 个即可把余量做到 ≥5（全部已用真 `lua51.dll` 阴影法复核为真 upvalue）。

**规程**：① 用**作用域栈**判定候选（不是全文件计数）→ ② 把 `local X=…` 改为挂 `P.X`/`env.X`
→ ③ **每搬一个立刻跑 `tests/check_lua51_compile.py`** → ④ 全量 + 逐个 `.py` 守门 → ⑤ 提交。目标 ≤55。

### 5.3 行为层守门（★ 门控部分已升级为真求值）
`tests/test_spread_gate.py` 已用 **lupa 真跑 `TakeGate.decide`**（不是文本抠取），
覆盖：`spread_armed` 放行、不设时行为不变、不越过 `quarantined`/`engine_owns_it`/`retired`、
只对 G-60 生效、**veto 仍优先**、`can_guide` 边界。
⇒ 它当场抓出了两个真 bug（判据写在 early return 之后；spread 抢走 veto 优先级）。
**仍未覆盖**：候选挑选本身（最低 rank / 同 rank 取更早 / 跳过已预定）—— 那段仍在
runtime 内联、依赖 `env`/`reservations`，要测得先抽成纯函数。

---

## 6. 构建 / 测试 / 发布

```powershell
# 环境
$py="C:\Users\dsypk\AppData\Local\Python\pythoncore-3.14-64\python.exe"
$env:PYTHONPATH="C:\Users\dsypk\.dsh\pylibs"; $env:PYTHONIOENCODING="utf-8"; $env:PYTHONUTF8="1"

# 构建（产出 dist/G60-Directed-Strike-0.1.25.zip）
& $py -B scripts/build.py

# 关键门禁 + 套件（★ 逐个跑：run_tests.py **不**跑这些 .py 守门）
& $py -B tests/check_lua51_compile.py     # ★ upvalue / 指令上限唯一防线
& $py -B tests/check_local_order.py
& $py -B tests/check_field_refs.py
& $py -B tests/test_spread_priority.py    # 名册 + 改派接线/可达性（34 checks）
& $py -B tests/test_spread_gate.py        # ★ 门控真求值（8 checks）
& $py -B tests/test_priority_fault_isolation.py   # 814
& $py -B scripts/run_tests.py             # 全量 Lua 套件（204 passed）
# ⚠ tests/test_bughole_scope.py 另有 29 条**既存**失败（钉的是旧 16-profile 基线），
#   不是本轮引入的；修它属于另一件事，但别把它当绿灯。
```

**发布纪律（用户明确要求，硬规则）**：**只有用户明确说「推送/发布」才允许 `git push` 或发 Release**；提交可以做。当前本地**领先 13 条提交、全部未推送**（含一条空提交 `0832144`，推送前应先整理/压缩）。

---

## 7. 一页速查：这一轮真正的三个故障

1. **`P.cap=ok_c and cap or nil` 写在 `local ok_c,cap=…` 之前** ⇒ 读到全局、恒 nil
   ⇒ 消费门 `… and P.cap` 永远为假。
   修法：删掉该缓存，候选上下文改由**本帧观测行**（`m.identity_bytes`/`m.entity_address`）构造。
2. **改派块写在 `if enters then` 内** ⇒ 无标记时 `gate.drive=false` ⇒ **结构性不可达**
   （而 `old` 只在块内创建 ⇒ 先有鸡后有蛋）。
   修法：计算**上移到门控之前**，并在 `take_gate` 用 `spread_armed` 开门（**排在否决之后**）。
3. **守门用裸子串断言**（`"P.cap=ok_c and cap or nil" in _RT`）**把 bug 钉成了「正确」**
   ⇒ 34 checks 全绿而功能是死的。
   修法：改为断言**顺序/可达性**，并新增真求值门控测试（它当场抓出我自己两个新 bug）。

另外两个历史故障仍然有效（初版记录的）：
- 改派块撞 60 upvalue ⇒ 整份 chunk 编译失败（mod 装不上）。
- entry 接线用错名（`SpreadPriority2`/`SpreadCandidates`）⇒ `env.spread_candidates` 为 nil ⇒ 每帧 nil 索引 ⇒ 整帧剩余全丢。

**共同结论：凡涉及构建、作用域、upvalue、门控顺序的地方，先读清楚再写，并让**真求值**门禁替你证明 —— 文本级断言证明不了任何东西。**
