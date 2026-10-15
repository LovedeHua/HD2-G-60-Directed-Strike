-- Marked structures only; approximate asset-derived blast sites need live testing.
return function(common)
local profiles={}
profiles["8901f188db366b4b"]={resource="8901f188db366b4b",kind="structure_hole",nodes=86,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.4000000059604645,3.0,0.3499999940395355},forward_local={0.013470103975976559,0.9999092740338378,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["9b58c95349d051f9"]={resource="9b58c95349d051f9",kind="structure_hole",nodes=86,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.4000000059604645,3.0,0.3499999940395355},forward_local={0.013470103975976559,0.9999092740338378,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["8c31b749759cbd61"]={resource="8c31b749759cbd61",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["36cc8ead2bb18d78"]={resource="36cc8ead2bb18d78",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["bc2af8548c6d5e06"]={resource="bc2af8548c6d5e06",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["f78bf0ff5c62140d"]={resource="f78bf0ff5c62140d",kind="structure_hole",nodes=113,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.8500000238418579,4.599999904632568,0.8500000238418579},forward_local={0.05421429783459729,0.9985293235104824,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["97dd3178e9f0ab70"]={resource="97dd3178e9f0ab70",kind="structure_hole",nodes=113,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.8500000238418579,4.599999904632568,0.8500000238418579},forward_local={0.05421429783459729,0.9985293235104824,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["4776a1cf3f19a13b"]={resource="4776a1cf3f19a13b",kind="structure_hole",nodes=113,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.8500000238418579,4.599999904632568,0.8500000238418579},forward_local={0.05421429783459729,0.9985293235104824,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["3a2cef12ed32a088"]={resource="3a2cef12ed32a088",kind="structure_hole",nodes=85,structure=true,boss_hash=0x4a182741,belly_hash=0x06bb7b12,aim_hash=0x4a182741,offset={-0.4017753601074219,0.638911247253418,0.0},forward_local={0.03874820869406746,0.9992490061656308,0.0},getters=common.getters,alive_rva=common.alive_rva,front_distance=10.368875714477495}
-- ★ 裁剪 J：补全"同一模型的摆放变体"（2026-09-27 实机"有些虫洞标记后没反应"）
--
-- 离线核对（generated_entities.dl_bin 全表 + 107,744 条资源名）发现 8 个实体
--   SpottableComponent.markerType 都是 EnemyMassive(3)、findable/startActive 都开
--   ⇒ **玩家能正常打点标记它们**，但不在上游的 9 条 profile 里 ⇒ mod 报
--   RESOURCE_NOT_SUPPORTED 不接管。这就是"有些虫洞不能标记炸毁"的直接原因。
--
-- 复用基线参数的依据（不是猜）：逐条对比组件集与碰撞参数
--   bug_spawner_warrior vs warrior_captive   组件差异仅 ['AnimationComponent']，碰撞参数一致
--   bug_spawner_warrior vs warrior_ceiling  组件集完全相同，碰撞参数一致
--   bug_spawner_warrior vs warrior_tutorial 组件集完全相同，碰撞参数一致
--   bug_spawner_scavenger vs scavenger_captive 组件集完全相同，碰撞参数一致
-- ⇒ 它们是**同一模型的不同摆放**，爆点相对模型的偏移不变，故整条复制基线参数。
-- ⚠ 未在实机逐个验证；若某个变体炸不塌，删掉对应那一行即可（其余不受影响）。

-- 复用到 bug_spawner_warrior（nodes=77）
profiles["7e4c6b45bcc45c3f"]={resource="7e4c6b45bcc45c3f",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["b6a181adcf547aeb"]={resource="b6a181adcf547aeb",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["9d8632a79c2d9789"]={resource="9d8632a79c2d9789",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- 复用到 bug_spawner_scavenger（nodes=86）
profiles["d666aa61d804d311"]={resource="d666aa61d804d311",kind="structure_hole",nodes=86,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.4000000059604645,3.0,0.3499999940395355},forward_local={0.013470103975976559,0.9999092740338378,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- ★★ 095686275a113614（尖啸者巢 Shrieker Nest）**已恢复接管**（2026-10-14）★★
--
--   游戏资源路径：content/env_bugs/assets/gameplay/bug_spawner_shrieker
--   （本工程离线 MurmurHash64A 反查）与社区表《绝地潜兵2资源ID》
--   「哈希表-整合」标注的"尖啸虫巢穴 | Shrieker Nest"**两个独立来源一致**。
--
--   ★★ 这是一次**方向反转**，理由与历史都留在这里，别再翻回去 ★★
--     · 2026-09-28 用户要求「对于有生命值的尖啸巢穴这一类的不要接管，直接使用游戏原生行为」
--       ⇒ 2026-09-29 提交 `9936f97` 把它从清单移除（17 → 16），并加了
--         `shrieker_nest_removed` 等一批断言钉住"不得再出现"。
--     · **2026-10-14 用户明确反转**：要求把「尖啸巢」加入远距离追踪名单
--       （原话：「只增加虫洞、构筑、巨型构筑、尖啸巢、孢子喷涌虫、落地穿梭舰这几个」）。
--       ⇒ 现在恢复接管，并用**主支（g60-bughole-lock）已实机验证过**的 `kind="structure_tower"`。
--
--   ★ 为什么用 `structure_tower` 而不是 `structure_hole`：
--     上游本来把它归为 **structure_tower**（巢体，长在高处），
--     `src/g60/structure_route.lua` 已有该分支：瞄准**主干旁 2.5 m**，
--     靠**伤害**拆而不是靠"进入洞口"的距离判定 —— 这对有生命值的巢体才成立。
--     ⚠ 它现在仍然进 `structure_profiles` ⇒ `env.mark_tier` 自动给**档位 0**
--       （与虫洞并列最高优先）。这是刻意的：玩家点名就该最高优先。
--   ⚠ 几何取自**主支**（`g60-bughole-lock` 的 `compat/structure_profiles.lua` 第 82 行），
--     不是猜的：`nodes=72`、`offset={0,0,13.0}`（巢在高处 13 m）、
--     `belly_hash` 与 `boss_hash` 相同（巢体没有独立的"腹部"节点）。
--     塔分支不读 `forward_local`（只有洞口分支 `assert(target.forward)` 才要），
--     这里保留原值只为不改变已有语义。
profiles["095686275a113614"]={resource="095686275a113614",kind="structure_tower",nodes=72,structure=true,boss_hash=0x4a182741,belly_hash=0x4a182741,aim_hash=0x4a182741,offset={0.0,0.0,13.0},forward_local={0.0,1.0,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- ★ mechanical_bughole（机械虫洞，超级地球基地）：不同阵营的机械结构，
--   **没有同模型基线可复用**。先按最保守的通用爆点（模型原点正上方 3m）登记，
--   让它至少能被接管与引爆；炸不塌的话再按实机标定 nodes/offset。
profiles["688949109126ece4"]={resource="688949109126ece4",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["5cf84155e60c6e4d"]={resource="5cf84155e60c6e4d",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- bug_spawner_base（虫巢基类，通常不直接生成在地图上；登记以防漏网）
profiles["0df874e208040d2f"]={resource="0df874e208040d2f",kind="structure_hole",nodes=86,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.4000000059604645,3.0,0.3499999940395355},forward_local={0.013470103975976559,0.9999092740338378,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- ★ 裁剪：上游此处还有 1 条 structure_egg(embryo_01 任务虫卵)。
--   虫卵不属于用户点名的 6 类，按需求不接管，标记它时本 mod 保持游戏原生行为。

-- ★★★ 2026-10-14（用户要求）：**远距离追踪名单** —— 只加这几类，其他不弄 ★★★
--
--   用户原话：「增加主支的远距离追踪功能，不过只增加虫洞、构筑、巨型构筑、
--     尖啸巢、孢子喷涌虫、落地穿梭舰这几个，其他的就不弄远距离追踪了」。
--   经确认：**距离上限只对这 6 类放开**，其他标记目标仍维持 200 m。
--
--   ⚠⚠ 关键：`structure_profiles` 是**唯一**能让这些目标拿到 `old.lock` 的地方
--     （白名单分支**绕过** `native_priority` 的敌阵营硬门槛 `NOT_ENEMY_RESOURCE`）。
--     这几类**都不是** AiEnemy（离线求值确认 `EnemyFaction.is_enemy` 全为 false）——
--     详见 `small_filter.lua` 里记的那次"登记位置不对 ⇒ 永远拿不到锁"的事故。
--
--   ★ 三种 kind 的分工（决定走哪条航路）：
--     · `structure_tower`（尖啸巢 / 孢子喷涌虫）：**有锚点几何**，瞄准主干旁 2.5 m，
--       靠伤害拆。几何取自主支（已实机验证）。
--     · `structure_vent`（构筑 5 变体 / 巨型构筑 / 落地穿梭舰）：**没有锚点几何**
--       ⇒ `motion_point=true`，瞄准点用实体的 motion 位置（`d.position`），
--       爆点仍由 `compat/blast_sites.lua` 的 `lift` 在**到达段**提供。
--       ⚠ 直接照虫洞写会让 `titan_context.capture` 的
--         `assert(boss and belly,'Titan bones unavailable')` **抛错** ⇒ 目标被拒
--         ⇒ 比现状更差。这就是必须 `motion_point` 的全部理由。

-- ★★★ 孢子喷涌虫（Spore Spewer）×2（2026-10-14，用户点名）★★★
--   ⚠ 与"孢子菇"（Spore Burst / fog_generator）**不是**一回事，别混：
--     这里两条是 `aa28caf964d05500` / `e02e6bd34b606a85`，主支注释里写的
--     "普通/大型 Spore Spewer"；工程内 `tests/hole_coverage.py` 把它们标为
--     `bug_fog_generator`。用户点名的是**孢子喷涌虫** ⇒ 按主支这两条登记。
--   ★ 机制：与尖啸巢同一条**塔航路**（`structure_route.lua`，主干旁 2.5 m、靠伤害拆）。
--   ⚠ 几何取自**主支**（已实机验证过的那两条）：
--     `nodes=76`、`offset={-0.5,0.0,12.0}`、`belly_hash=0x36652574`。
--   ⚠ 主支在这两条上多了 `grenades=2`，**本工程没有实现 `grenades` 字段**
--     （全仓无读取点）⇒ 这里**不写**它，免得留一个看起来生效其实被忽略的配置。
--     ⚠ 已知缺口：塔类目标可能**需要 2 颗**才拆得掉（塔血 > 一颗 G-60 的伤害），
--       而本工程 `exclusive_targets=true` = 一目标一颗。见 README 的"已知缺口"。
profiles["aa28caf964d05500"]={resource="aa28caf964d05500",kind="structure_tower",nodes=76,structure=true,boss_hash=0x4a182741,belly_hash=0x36652574,aim_hash=0x4a182741,offset={-0.5,0.0,12.0},forward_local={0.0,1.0,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["e02e6bd34b606a85"]={resource="e02e6bd34b606a85",kind="structure_tower",nodes=76,structure=true,boss_hash=0x4a182741,belly_hash=0x36652574,aim_hash=0x4a182741,offset={-0.5,0.0,12.0},forward_local={0.0,1.0,0.0},getters=common.getters,alive_rva=common.alive_rva}

-- ★★★ 2026-10-14（用户点名）：**构筑 / 巨型构筑 / 落地穿梭舰** 移入结构路径 ★★★
--
--   取自主支「方案 B」（2026-10-13，主支已实机验证）：`kind="structure_vent"`
--   + `motion_point=true`（免几何兜底）。
--
--   为什么用 `structure_vent`（而不是照虫洞写 profile）：
--     这几类**从来没有过**锚点几何（`boss_hash`/`belly_hash`/`nodes` 一个都没有），
--     直接照虫洞写会让 `TargetContext.capture` 的
--     `assert(boss and belly,'Titan bones unavailable')` 抛错 ⇒ 目标被拒。
--     ⇒ `motion_point=true` 显式声明"本 profile 没有锚点，瞄准点用实体 motion 位置"。
--       三处 `capture` 调用点都按这个标志分支（见 runtime 两处 + native_priority 一处）。
--   ★ 爆点仍由 `compat/blast_sites.lua` 的 `lift` 提供 —— 它在**到达段**生效
--     （`blast_point={p[1],p[2],p[3]+lift}` + 专用 region）。移入结构路径只是让它们
--     **拿到结构锁**，从而走我们自己的航路与区域判定；lift 那条机制一个字没改。
--   ⚠ **无 `nodes` / `offset` / `boss_hash`** 是刻意的。
--   ⚠ 精度：motion 位置 ≈ 模型原点 ⇒ 准头依赖 `lift`，**不如锚点几何准**。
--     用户已知情（主支选的就是 B 方案）。要更准得补锚点（需上机探针）。
--
--   ⚠ 巨型构筑（4232ee48e2cfd24e）**原来只在 `blast_sites` 里**
--     ⇒ 它走的是 generic 路（引擎 aim）+ 事后挪爆点。现在移入结构路径，
--     获得我们自己的航路 —— 这正是"远距离追踪"需要的那一步。
profiles["4232ee48e2cfd24e"]={resource="4232ee48e2cfd24e",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["5158e582fbeb26bd"]={resource="5158e582fbeb26bd",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["22cc0ed4ceb9cb68"]={resource="22cc0ed4ceb9cb68",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["f0b98fb953b13960"]={resource="f0b98fb953b13960",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["4fb8eb356ac8553e"]={resource="4fb8eb356ac8553e",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["a1a7b76b29088843"]={resource="a1a7b76b29088843",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
-- 落地穿梭舰（Warp Ship Landed / Invasion）。
--   ⚠ 主支的注释标明这两条哈希是**未验证**的（`warp_ship_*_UNVERIFIED_hash`）。
--     失败方向是安全的：runtime 按 `e.resource` 查表，查不到 ⇒ 完全退回旧行为，
--     不会误炸别的目标。上机时读 `structure_mark;…;resource=` 的真值来核对。
profiles["b3c9cdb79dc17937"]={resource="b3c9cdb79dc17937",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["2ad2e055dad21f6e"]={resource="2ad2e055dad21f6e",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}

-- ★★★ 2026-10-14：**非法广播任务的广播台（屏幕实体）**（用户实机核对）★★★
--   用户原话：「有一些问题，比如说非法广播任务里面的广播台 ping 了之后手雷不会飞过去炸毁」。
--
--   【实机证据】两局独立复现，链路完全一致：
--     `structure_mark;target=433;resource=57db57121f3e7ed2;reason=ACCEPTED`
--     → `mark_queue;…;ids=433;resources=57db57121f3e7ed2;tiers=1500;…;picked=433`
--     → `generic_rejected;target=433;resource=57db57121f3e7ed2;detail=NOT_ENEMY_RESOURCE`
--     → `link;mark=433;…;entered=0;locked=0`
--     ⇒ 标记**进了队列**（认领成功）却**锁不上** ⇒ 手雷不飞。
--
--   【为什么被拒】它在数据源里只有 4 个组件
--     （`UnitComponentData` / `DestructibleComponentData` / `SpottableComponentData` /
--      `BehaviorComponentData`），**没有 `AiEnemyComponentData(302)`**
--     ⇒ 被敌阵营门槛判成"非敌人"（`NOT_ENEMY_RESOURCE`）。
--
--   ★★ 为什么**不能**改那道门槛（本工程已用数据证伪过）★★
--     它现在的判据是"**只有可证明是敌人**才允许"（2026-10-10 修"标记友方被炸"后定的）。
--     若改成"只拒绝可证明友方"，会把这些**全部放回来**：
--       · 2026-10-10 被误炸的友方（哨戒机枪/火焰哨戒炮/补给支架/信标球/MGX-42）
--         **全都没有** `FriendlyNpcComponentData(263)` 或 `AvatarComponentData(232)`；
--       · 全表 1909 个实体里 **1742 个（91%）** 是"既非可证明敌人也非可证明友方"；
--       · 连另一份独立的友方名单（AggroCounter `FRIENDLY_HASHES`，107 条）
--         也只能认出 6 条被炸友方里的 **2 条**。
--     ⇒ 走**本表**：白名单分支**不经过**敌阵营门槛，那道门槛一个字都不用动。
--
--   ⚠ `kind="structure_vent"`（免几何）：它没有锚点几何（无 boss/belly/nodes）
--     ⇒ 走 `motion_point` 分支（瞄准实体自身运动位置），与构筑/穿梭舰同款。
--
--   ★ 用户实机补充（同一局）：广播台的**底座不是一个实体** ——
--     ping 底座时游戏给的是 `structure_mark;target=0;resource=nil;reason=NO_ENTITY_MARK`
--     ⇒ 退化成**空 ping 坐标点**，走 point 路径（`point_taken` →
--     `arrival_detonated;…;target=point;horiz=2.82` 成功引爆）。
--     ⇒ 需要登记的只有**屏幕**这一个实体。
--
--   ★★ 哈希已用**独立来源确认**（不是靠猜）★★
--     游戏资源路径反查（MurmurHash64A，107,744 条名字，见
--     `tests/test_priority_fault_isolation.py` 里那套自检过的反查）：
--       `57db57121f3e7ed2` = `content/objectives/obj_common/truth_transmitter/
--                             truth_transmitter_tower_screen_03`
--     ⇒ 就是"非法广播/真相发射塔"那个塔的**屏幕**，与用户实机描述逐字对上。
--
--   ★ 家族**全查过**了（同一套反查 + 组件表交叉）：
--     整个 `truth_transmitter` 家族里**只有这一个**是"可点(Spottable) +
--     可毁(Destructible) + 非敌人"的**实体**；其余部件（tower /
--     screen_01·02·04·05·06 / speakers / terminal / gen_truth_transmitter）
--     要么不在实体表里（子模型/材质），要么 `可点=False` ⇒ 玩家**根本 ping 不到**。
--     ⇒ 需要登记的就**这一个**，不是漏了别的。
--     ⚠ 用户实机补充：塔的**底座** ping 出来是 `NO_ENTITY_MARK`（底座不是实体）
--       ⇒ 退化成空 ping 坐标点，走 point 路径（`arrival_detonated;…;target=point` 成功）。
profiles["57db57121f3e7ed2"]={resource="57db57121f3e7ed2",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
-- ★★★ 2026-10-14（用户要求）：**把机器人的碉堡 / 炮塔 / 营地武器 / 目标建筑
--   加进"虫洞这一档"的远距离追踪** ★★★
--
--   用户原话：「这一些加入虫洞这一档的远距离追踪」（附 9 个十进制实体 ID + 中英名）。
--
--   ▸ 加进本名册 = 自动进 **0 档**：`mark_tier` 的判据就是
--     `env.structure_profiles[r]~=nil ⇒ 0`（与虫洞同档），距离门用
--     `max_takeover_distance`（默认 250 m、可调），走结构接管路
--     （priority 锁 + 体内爆点 + `structure_vent` 航路）。
--
--   ▸ **为什么一律用 `kind="structure_vent"` + `motion_point=true`**：
--     `structure_route.lua` 在 **SAFETY_LAYER**（只读）里按**显式 kind** 分流，
--     只认 4 种，其它会 `assert('unknown structure route')`。其中
--       · `structure_hole` 需要**锚点几何**（虫洞入口那套）；
--       · `structure_tower` 也需要**模型锚点**（尖啸巢那条带了
--         `nodes` / `boss_hash` / `belly_hash`，都是从模型表核对出来的）；
--       · **`structure_vent` 是唯一的"免几何"档**：`motion_point=true`
--         ⇒ 瞄准点直接用实体的 motion 位置（`d.position`），不需要任何模型数据。
--     ⇒ 这 9 个的模型几何我们**没有**（没在离线表里核对过）⇒ 只能走免几何档；
--       硬套 `structure_tower` 是**猜几何**，本工程明令不许（"不要再臆测几何"）。
--
--   ▸ 若某个目标"雷飞到了、在底部炸、但目标没毁" ⇒ 那是**爆点高度**问题，
--     按既有流程给它加一条 `compat/blast_sites.lua`（`lift` + 扫描表），
--     与巨型构筑者 8.0 / 构筑者 2.5 / 穿梭舰 2.5 / 广播台 2.5 同款。
--     ⚠ 每个目标必须**各自标定**：构筑者与巨型构筑者不是同一模型，这一点
--       用户 2026-10-13 明确纠正过。
--
--   ▸ 哈希来源（逐个标清，不混）：
--     · 7 条**双源核过**（离线 MurmurHash64A 反查，107,744 条名字）：
--         cd28a27a79be53d5 = content/fac_cyborgs/turrets/cyborg_turret_command_bunker_hmg/…
--         5336583c1f8ba745 = content/objectives/obj_cyborgs/cyborg_command_bunker/cyborg_command_bunker_spawner
--         aeaef7a1851e6c9d = content/fac_cyborgs/turrets/cyborg_tank_turret_autocannons/cyborg_turret_autocannons
--         ff5cc825b9571052 = content/fac_cyborgs/turrets/cyborg_tank_turret_mortar/cyborg_turret_mortar
--         a98f8b559c7993d8 = content/fac_cyborgs/emplacements/cyborg_emplacement_hmg/cyborg_emplacement_hmg
--         2c1a7790c435fd67 = content/fac_cyborgs/emplacements/cyborg_emplacement_mg/cyborg_emplacement_mg
--         e2e6e77dcc99a1cb = content/objectives/obj_cyborgs/cyborg_shutdown_grinder/grinder
--       ⚠ `ff5cc825b9571052`（迫击炮塔）与 `2c1a7790c435fd67`（营地机枪）
--         在用户 2026-10-15 的实机日志里出现过（`structure_mark;…;ACCEPTED` /
--         `enemy_selection;…`）⇒ **实机 ID 与离线反查一致**，三源对上。
--     · 2 条**只有单一来源**（用户给的十进制 ID，名字库反查不到）：
--         9926876b2375a1bb（机器人 碉堡炮塔 / Bunker Turret）
--         fb293a4018d14eea（生化斯坦城市大门 / Cyberstan Wall Gate）
--       ⚠ **知情标注**：这两条没有第二来源。若实机发现它们"标记了没反应"或
--         表现异常，先怀疑这两条（删掉即可，其余 7 条不受影响）。
--         验证办法：标记它们后看日志有没有
--         `priority_locked;…;resource=9926876b2375a1bb;reason=PLAYER_MARK_STRUCTURE`
--         —— 有就说明 ID 与实体确实是同一个。
--
--   ⚠ 这些是**机器人（Automaton/cyborg）设施**，其中炮塔/营地武器在原版里
--     可能也算可锁定的敌人。加进本名册后它们**优先走结构接管路**
--     （结构判据在敌人判据之前）⇒ 远距离可追踪；这是用户明确要求的行为。
profiles["cd28a27a79be53d5"]={resource="cd28a27a79be53d5",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["5336583c1f8ba745"]={resource="5336583c1f8ba745",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["9926876b2375a1bb"]={resource="9926876b2375a1bb",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["aeaef7a1851e6c9d"]={resource="aeaef7a1851e6c9d",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["ff5cc825b9571052"]={resource="ff5cc825b9571052",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["a98f8b559c7993d8"]={resource="a98f8b559c7993d8",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["2c1a7790c435fd67"]={resource="2c1a7790c435fd67",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["e2e6e77dcc99a1cb"]={resource="e2e6e77dcc99a1cb",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
profiles["fb293a4018d14eea"]={resource="fb293a4018d14eea",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
-- ★★★ 2026-10-14（用户报告）：**落地的机器人运输舰**不能远距离追踪 ★★★
--
--   用户原话：「最后 ping 的就是落地的机器人运输舰」。日志实机证据：
--     structure_mark;target=429;resource=d84ffc32a6e640a8;reason=ACCEPTED
--     mark_queue;…;resources=d84ffc32a6e640a8;**tiers=1500**        ← 名册外
--     target_fields;tag=generic;…;**valid=true**                    ← 引擎说能锁
--     generic_rejected;…;detail=**NOT_ENEMY_RESOURCE**              ← 被敌阵营门槛拒
--   ⇒ 标记收下了、引擎也认它能锁，但通用路要 `EnemyFaction.is_enemy`，
--     而它是**载具/目标物**（不是 AiEnemy）⇒ `NOT_ENEMY_RESOURCE` ⇒
--     **永远拿不到 `old.lock`** ⇒ 没有航路 ⇒ 远距离追踪无从谈起。
--   ⇒ 与"营地穿梭舰"完全同一类问题 ⇒ 用**同一条**已验证的路：进本名册
--     （结构白名单分支**绕过**敌阵营门槛）+ `structure_vent` 免几何航路。
--
--   ⚠ **不是**否决表那一条：飞行中的运输船是 `db90077e76faa025`
--     （`content/fac_cyborgs/vehicles/cyborg_dropship`，仍在 `excluded` 里、
--      引擎自选时照旧清掉）；**落地**的是 `d84ffc32a6e640a8`
--     （`content/objectives/obj_cyborgs/cyborg_landed_dropship`）——
--     两个**不同资源** ⇒ 可以精确区分，不需要动否决表。
--   ★ 哈希双源核过：离线 MurmurHash64A 反查 107,744 条名字命中上条路径，
--     且与用户实机 ping 出来的 `resource=` 逐字一致。
profiles["d84ffc32a6e640a8"]={resource="d84ffc32a6e640a8",kind="structure_vent",structure=true,motion_point=true,getters=common.getters,alive_rva=common.alive_rva}
return profiles
end
