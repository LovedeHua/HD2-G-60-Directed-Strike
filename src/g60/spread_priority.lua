-- 无标记时"主动改派"的**分阵营优先级名册**（2026-10-16 用户逐条审过；当日二次细分）
--
-- 来源表：《绝地潜兵2哈希整合表.xlsx》/ 工作表「哈希表-整合」。
-- ⚠ 本文件原由临时脚本生成，脚本未入库；现**手工维护**。唯一防线是守门里的
--   `xlsx_cross_check` —— 它逐条断言"每个哈希都能在源表里复核到"。
--   ⇒ 任何增删都必须同时跑 `tests/test_spread_priority.py`，不许凭记忆写哈希。
--
-- rank 越小越优先；同一档内 rank 相同。名册里没有的 = 该阵营「其他敌人」（最低优先）。
--
-- ── 原始判定规则（用户 11 条修正后）────────────────────────────────────────
--   · 英文名优先匹配家族词（含 Hulk/Charger/Devastator…），中文名只按**开头**匹配
--     （防「蹂躏者 MK2 移动工厂生产」被「移动工厂」劫持；中文兜住英文拼写错误）
--   · 中文名的空格尾段 = 子部件 ⇒ 剔除；但尾段以「带」开头是**本体变体** ⇒ 收录
--   · 硬排除：反坦克/Anti-Tank（「含 Tank」会误伤）、结构类（洞/巢）、
--     (Model)/(Projectile)/(Shell)、废案
--   · 一条只进一个档（长关键词优先）
--   · 档位间隙由 rank 跳号表达（终结族 喷涌虫 → 追踪虫 之间是用户标的 》）
--
-- ── 2026-10-16 细分（用户第二轮要求）──────────────────────────────────────
--   终结族（细分后 13 档）：
--     强袭虫档拆 4 级：**孢子强袭虫 > 巨兽级强袭虫(含 MK2) > 钻地强袭虫 > 强袭虫**
--       ⚠ 用户口语称「爆裂强袭虫」，经确认**就是源表的「钻地强袭虫 / Rupture Charger」**
--         （源表里没有"爆裂强袭虫"这个名字）—— 已当面确认，不是推测。
--     新增最低档：**虫窝护卫 > 狂暴武斗虫 > 其他武斗虫**
--       「其他武斗虫」含 武斗虫 / MK2 / MK2（俘虏）/ MK3 / 酸液武斗虫 / 钻地武斗虫
--       / **孢子武斗虫**（用户确认孢子武斗虫与其它武斗虫**同档**，不单独升级）。
--   机器人（细分后 12 档）：
--     巨型者档拆 2 级：**巨型抹煞者 / 巨型碾压者 / 巨型烈焰轰炸者 / 喷气旅巨型碾压者**
--       > 其他巨型者及其变体（巨型者 / 巨型炙焰者 / 巨型炙焰者 MK2 / 喷气巨型炙焰者）
--     惑乱者 > 激进先锋；**强化侦察纵步者与惑乱者同档**（用户确认，高于激进先锋）
--     蹂躏者档拆 4 级：**重型蹂躏者(含变体) + 烈火蹂躏者 > 火箭蹂躏者(含变体)**
--       > 其他蹂躏者 > **狂暴者（本轮新加入）**
--     新增最低档：**机枪奇袭者** = 机枪奇袭者 / 机枪奇袭者（炽灼部队）/
--       喷气机枪奇袭者 / **装甲兵 MK2（机枪奇袭者，无背包）**（用户确认这 4 个）
--
--   ⚠ 用户口语里的「第 7 / 第 8 档」指的是**新增的最低档**；因为档内细分会占号，
--     实际 rank 见下表（只看大小关系，数值本身无语义）。
return {
  source_table = '绝地潜兵2哈希整合表.xlsx / 哈希表-整合',
  reviewed_by_user = '2026-10-16',
  ['终结族'] = {
    -- 1
    ['960b48a421a3faaa'] = {rank=1, zh='蟑龙', en='Dragonroach', band='终结族-基础单位'},
    -- 2
    ['9e2e17f2ccccafdd'] = {rank=2, zh='吐酸泰坦', en='Bile Titan', band='终结族-基础单位'},
    ['ef04cb84d097a497'] = {rank=2, zh='孢子泰坦', en='Spore Burst Bile Titan', band='终结族-特殊变体'},
    -- 3
    ['dcf8e74212fbee3b'] = {rank=3, zh='穿刺虫', en='Impaler', band='终结族-基础单位'},
    -- 4 强袭虫档细分：孢子 > 巨兽级(含 MK2) > 钻地(=用户说的「爆裂」) > 普通
    ['6b202392f4ab605e'] = {rank=4, zh='孢子强袭虫', en='Spore Charger', band='终结族-基础单位'},
    ['3aff5fd7d5450b99'] = {rank=5, zh='巨兽级强袭虫', en='Charger Behemoth', band='终结族-基础单位'},
    ['a05bd1ec67b3ac4c'] = {rank=5, zh='巨兽级强袭虫 MK2', en='Charger Behemoth MK2', band='终结族-基础单位'},
    ['0ab7b92b131c228c'] = {rank=6, zh='钻地强袭虫', en='Rupture Charger', band='终结族-特殊变体'},
    ['1a7fcdff98c664b0'] = {rank=7, zh='强袭虫', en='Charger', band='终结族-基础单位'},
    -- 8
    ['f79cd8bb654397df'] = {rank=8, zh='阿尔法指挥官', en='Alpha Commander', band='终结族-基础单位'},
    -- 9 喷涌虫一档（胆汁 + 抚育 + 钻地）
    ['36aa99cce5e60146'] = {rank=9, zh='胆汁喷涌虫', en='Bile Spewer', band='终结族-基础单位'},
    ['ccae5264acd591b7'] = {rank=9, zh='胆汁喷涌虫 MK2', en='Bile Spewer MK2', band='终结族-基础单位'},
    ['6021e22338333d88'] = {rank=9, zh='抚育喷涌虫', en='Nursing Spewer', band='终结族-基础单位'},
    ['cc7022fdd172089b'] = {rank=9, zh='抚育喷涌虫 MK2', en='Nursing Spewer MK2', band='终结族-基础单位'},
    ['a381a11c07d3eb94'] = {rank=9, zh='钻地喷涌虫', en='Rupture Spewer', band='终结族-特殊变体'},
    -- 10（用户标的 》 间隙在此之上：喷涌虫 与 追踪虫 之间断层）
    ['f540ca9d9d4a422e'] = {rank=10, zh='追踪虫', en='Stalker', band='终结族-基础单位'},
    ['d1e990baf22d5a52'] = {rank=10, zh='掠食追踪虫', en='Predator Stalker', band='终结族-特殊变体'},
    -- 11~13 新增最低档：虫窝护卫 > 狂暴武斗虫 > 其他武斗虫（含孢子武斗虫）
    ['a1f37bf2a40fbde4'] = {rank=11, zh='虫窝护卫', en='Hive Guard', band='终结族-基础单位'},
    ['b2a6fa1e4284c7e6'] = {rank=12, zh='狂暴武斗虫', en='Warrior (Spawned)', band='终结族-基础单位'},
    ['eacee39fa017b495'] = {rank=13, zh='武斗虫', en='Warrior', band='终结族-基础单位'},
    ['be39e313a1e46bb9'] = {rank=13, zh='武斗虫 MK2', en='Warrior MK2', band='终结族-基础单位'},
    ['4e97fb073bdc7a4b'] = {rank=13, zh='武斗虫 MK2（俘虏）', en='Warrior MK2 (Captive)', band='终结族-基础单位'},
    ['32541fc4ec7c9cdc'] = {rank=13, zh='武斗虫 MK3', en='Warrior MK3', band='终结族-基础单位'},
    ['10081acef6163ef6'] = {rank=13, zh='酸液武斗虫', en='Bile Warrior', band='终结族-基础单位'},
    ['a35207c6f2150806'] = {rank=13, zh='钻地武斗虫', en='Rupture Warrior', band='终结族-特殊变体'},
    ['728421351d440ebc'] = {rank=13, zh='孢子武斗虫', en='Spore Burst Warrior', band='终结族-特殊变体'},
  },
  ['机器人'] = {
    -- 1
    ['d37e8d120d2836e3'] = {rank=1, zh='移动工厂', en='Factory Strider', band='机器人-基础单位'},
    ['30f2dee2333f227a'] = {rank=1, zh='移动工厂 带干扰塔', en='Jammer Factory Strider', band='机器人-基础单位'},
    ['bc242702fb46b7e7'] = {rank=1, zh='噪轰引擎', en='Vox Engine', band='机器人-特殊变种'},
    -- 2
    ['53d8919d7b8abd67'] = {rank=2, zh='湮灭坦克', en='Annihilator Tank', band='机器人-基础单位'},
    ['c6449ffd9ea3779c'] = {rank=2, zh='碎裂坦克', en='Shredder Tank', band='机器人-基础单位'},
    ['63df3d07b7424588'] = {rank=2, zh='铁幕坦克', en='Barrager Tank', band='机器人-基础单位'},
    ['ef570293245a17c2'] = {rank=2, zh='战争纵步者', en='War Strider', band='机器人-基础单位'},
    -- 3 巨型者档细分（高）：用户点名的 4 个
    ['1e66ee1f6f7fd00e'] = {rank=3, zh='巨型抹煞者', en='Hulk Obliterator', band='机器人-基础单位'},
    ['137988cea16458f7'] = {rank=3, zh='巨型碾压者', en='Hulk Bruiser', band='机器人-基础单位'},
    ['6dab2eadf5d8b692'] = {rank=3, zh='巨型烈焰轰炸者', en='Hulk Firebomber', band='机器人-特殊变种'},
    ['32cdeada234fb8df'] = {rank=3, zh='喷气巨型碾压者', en='Jet Brigade Hulk Bruiser', band='机器人-特殊变种'},
    -- 4 其他巨型者及其变体
    ['96ba14c9ebb49ce1'] = {rank=4, zh='巨型者', en='Hulk', band='机器人-基础单位'},
    ['3e0537d606438fea'] = {rank=4, zh='巨型炙焰者', en='Hulk Scorcher', band='机器人-基础单位'},
    ['1897bdd32105d2dc'] = {rank=4, zh='巨型炙焰者 MK2（炽灼部队）', en='Hulk Scorcher MK2', band='机器人-特殊变种'},
    ['e44ec9f9b3fe1d2a'] = {rank=4, zh='喷气巨型炙焰者', en='Jet Brigade Hulk Scorcher', band='机器人-特殊变种'},
    -- 5
    ['282eb766c1ffa6a1'] = {rank=5, zh='炮艇', en='Gunship', band='机器人-基础单位'},
    -- 6 惑乱者与强化侦察纵步者同档（用户确认：都高于激进先锋）
    ['9d8827fed763650e'] = {rank=6, zh='惑乱者（男）', en='Male Agitator', band='机器人-特殊变种'},
    ['09fe0be51a23396c'] = {rank=6, zh='惑乱者（女）', en='Female Agiator', band='机器人-特殊变种'},
    ['9076eeed17fcee35'] = {rank=6, zh='强化侦察纵步者', en='Reinforced Scout Strider', band='机器人-基础单位'},
    -- 7 激进先锋（低于惑乱者）
    ['746a7f3beda32699'] = {rank=7, zh='激进先锋（男）', en='Male Radical', band='机器人-特殊变种'},
    ['cbb1ba3366009c3a'] = {rank=7, zh='激进先锋（女）', en='Female Radical', band='机器人-特殊变种'},
    -- 8 蹂躏者档细分（最高）：重型(含变体) + 烈火
    ['f8b5a81a86d5d4eb'] = {rank=8, zh='重型蹂躏者', en='Heavy Devastator', band='机器人-基础单位'},
    ['b92435fbf60f0748'] = {rank=8, zh='重型蹂躏者 MK2', en='Heavy Devastator MK2', band='机器人-基础单位'},
    ['91ebd77931110afc'] = {rank=8, zh='重型蹂躏者 MK3', en='Heavy Devastator MK3', band='机器人-基础单位'},
    ['e0353177f1329573'] = {rank=8, zh='烈火蹂躏者', en='Conflagration Devastator', band='机器人-特殊变种'},
    -- 9 火箭蹂躏者（含变体）
    ['9647b00cc3a9d36f'] = {rank=9, zh='火箭蹂躏者', en='Rocket Devastator', band='机器人-基础单位'},
    ['f66d0bad8693779a'] = {rank=9, zh='火箭蹂躏者 MK2', en='Rocket Devastator MK2', band='机器人-基础单位'},
    ['c9bcccb0a54a82a4'] = {rank=9, zh='火箭蹂躏者 MK3（炽灼部队）', en='Incendiary Rocket Devastator', band='机器人-特殊变种'},
    -- 10 其他蹂躏者
    ['c626d2bb495a202d'] = {rank=10, zh='蹂躏者', en='Devastator', band='机器人-基础单位'},
    ['fc8dec78be8ab47d'] = {rank=10, zh='蹂躏者 MK2 移动工厂生产', en='Devastator MK2 Spawn', band='机器人-基础单位'},
    ['ae63e525853d7044'] = {rank=10, zh='蹂躏者 MK3', en='Devastator MK3', band='机器人-基础单位'},
    ['57eed0eac346cd9d'] = {rank=10, zh='蹂躏者 MK3（炽灼部队）', en='Incendiary Devastator', band='机器人-特殊变种'},
    ['58b2b86c11369241'] = {rank=10, zh='燃烧机枪蹂躏者', en='Incendiary MG Devastator', band='机器人-特殊变种'},
    ['be743b2faa3a6e26'] = {rank=10, zh='喷气蹂躏者', en='Jet Brigade Devastator', band='机器人-特殊变种'},
    -- 11 狂暴者（本轮新加入；低于其他蹂躏者）
    ['a6a68d8af177f3a1'] = {rank=11, zh='狂暴者', en='Berserker', band='机器人-基础单位'},
    ['54e107dacf6929cb'] = {rank=11, zh='狂暴者 MK2', en='Berserker MK2', band='机器人-基础单位'},
    ['b5dbc0c240c921ad'] = {rank=11, zh='狂暴者 MK3（炽灼部队）', en='Incendiary Berserker', band='机器人-特殊变种'},
    ['d5792f6856b06ba4'] = {rank=11, zh='喷气狂暴者', en='Jet Brigade Berserker', band='机器人-特殊变种'},
    -- 12 新增最低档：机枪奇袭者（用户点名的 4 个）
    ['b4ed319b39f5457b'] = {rank=12, zh='机枪奇袭者', en='MG Raider', band='机器人-基础单位'},
    ['089833d2880d9e06'] = {rank=12, zh='机枪奇袭者（炽灼部队）', en='Incendiary MG Raider', band='机器人-特殊变种'},
    ['a4552f97033392f4'] = {rank=12, zh='喷气机枪奇袭者', en='Jet Brigade MG Raider', band='机器人-特殊变种'},
    ['ae57fcdb49f74e98'] = {rank=12, zh='装甲兵 MK2（机枪奇袭者，无背包）', en='Trooper MK2 MG', band='机器人-基础单位'},
  },
  ['光能族'] = {
    ['965eae5a51acdd4a'] = {rank=1, zh='猎杀器', en='Harvester', band='光能族-基础单位'},
    ['d63fcbff0851b7af'] = {rank=1, zh='猎杀器 MK2', en='Harvester MK2', band='光能族-基础单位'},
    ['20b9c7734daead65'] = {rank=2, zh='证真者', en='Veracitor', band='光能族-特殊变种'},
    ['453fe22c634eb30f'] = {rank=2, zh='御门者', en='Gatekeeper', band='光能族-特殊变种'},
    ['905809a4c28d8a45'] = {rank=2, zh='粉碎者', en='Crusher', band='光能族-特殊变种'},
    ['604a794ec45bb820'] = {rank=3, zh='崇高监视者', en='Elevated Overseer', band='光能族-基础单位'},
    ['e8f19a0aa958e46d'] = {rank=3, zh='新月监视者', en='Crescent Overseer', band='光能族-基础单位'},
    ['67dc32dca4f02d33'] = {rank=3, zh='肉瘤体', en='Fleshmob', band='光能族-基础单位'},
    ['da40bb347c7447f2'] = {rank=4, zh='监视者', en='Overseer', band='光能族-基础单位'},
    ['08e6ffc2474287bd'] = {rank=4, zh='监视者 MK2', en='Overseer MK2', band='光能族-基础单位'},
    ['34dfd23365472e9e'] = {rank=5, zh='突入者', en='Obtruder', band='光能族-特殊变种'},
    ['cc188f0c80505c6c'] = {rank=5, zh='悲怜体', en='Wretch', band='光能族-特殊变种'},
  },
}
