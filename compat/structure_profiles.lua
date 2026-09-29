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
-- ★ bug_spawner_shrieker（尖啸者巢）：上游把它归为 structure_tower(nodes=72, offset z=13.0)，
--   本工程第一版按"只接管虫洞"把它删了。但它同样是可标记的 EnemyMassive 巢体，
--   玩家会期望能炸 ⇒ 按其**上游原始参数**恢复（不是套用 bug_spawner_warrior 的）。
profiles["095686275a113614"]={resource="095686275a113614",kind="structure_hole",nodes=72,structure=true,boss_hash=0x4a182741,belly_hash=0x4a182741,aim_hash=0x4a182741,offset={0.0,0.0,13.0},forward_local={0.0,1.0,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- ★ mechanical_bughole（机械虫洞，超级地球基地）：不同阵营的机械结构，
--   **没有同模型基线可复用**。先按最保守的通用爆点（模型原点正上方 3m）登记，
--   让它至少能被接管与引爆；炸不塌的话再按实机标定 nodes/offset。
profiles["688949109126ece4"]={resource="688949109126ece4",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
profiles["5cf84155e60c6e4d"]={resource="5cf84155e60c6e4d",kind="structure_hole",nodes=77,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.5,3.0999999046325684,0.6000000238418579},forward_local={0.04377192001860948,0.9990415501959288,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- bug_spawner_base（虫巢基类，通常不直接生成在地图上；登记以防漏网）
profiles["0df874e208040d2f"]={resource="0df874e208040d2f",kind="structure_hole",nodes=86,structure=true,boss_hash=0x4a182741,belly_hash=0x8ea852c8,aim_hash=0x4a182741,offset={-0.4000000059604645,3.0,0.3499999940395355},forward_local={0.013470103975976559,0.9999092740338378,0.0},getters=common.getters,alive_rva=common.alive_rva}
-- ★ 裁剪：上游此处还有 2 条 structure_tower(普通/大型 Spore Spewer 孢子菇)
--   与 1 条 structure_egg(embryo_01 任务虫卵)。孢子菇与虫卵不属于"虫洞"，
--   按需求不接管，标记它们时本 mod 保持游戏原生行为。
--   尖啸者巢(Shrieker Nest)已在上方按其原始参数恢复。
return profiles
end
