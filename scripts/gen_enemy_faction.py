"""生成 src/g60/enemy_faction.lua —— 敌人阵营资源表。

为什么需要这个文件（2026-10-10 实机事故）：
    本 mod 的「通用标记目标」复核一直拿 `calls.target_valid`
    （game.dll+0x8858a0）当**阵营判据**，注释里写的理由是
    「引擎索敌不锁友方 ⇒ 返回 false 就排除了友方」。
    实机证明这条假设是**错的**：`target_valid` 是"这个实体**能不能被打**"，
    不是"它是不是敌人"。于是：

        517 820cc3bafe962858  A/FLAM-40 火焰哨戒炮（友方）  valid=true  -> 被炸（0.78 m）
        592 37cde43876ba26bb  A/MG-43 哨戒机枪（友方）      valid=true  -> 被炸（0.74 m）
        536 31400a6a3003e29c  B-1 补给背包（支架，友方）    valid=true  -> 被炸
        524 c87555eed1e9f092  MGX-42 子弹风暴（支架，友方）  valid=true
        509 16f397ca5f51f271  战略配备信标球（友方）        valid=false -> 正确忽略
        590 b16c9d490aa59b77  MGX-42 子弹风暴（模型）       valid=false -> 正确忽略

    哨戒炮/支架**有生命值**（虫子会打它们）⇒ 引擎说"能打" ⇒ 旧判据放行。
    我上次"4/4 友方全 false"的样本**全是信标球和模型** —— 样本偏了。

本表的判据（来自**游戏自己的 archetype 数据**，不是猜的）：
    enemy = 有 AiEnemyComponentData(302)
            且 无 FriendlyNpcComponentData(263)   （平民 / SEAF / 撤离科学家）
            且 无 AvatarComponentData(232)        （玩家本体 / 队友）
    数据源：EntityComponentMap.json（Armory Tuning Bench 从 game.dll 导出的
            「实体 -> 组件」表，含 1909 个导出类型 / 319 个组件类型）。

    为什么必须减掉 263/232：平民与 SEAF **也有** AiEnemyComponentData
    （它的语义是"会被敌方 AI 锁定"），不减就会把中立 NPC 判成敌人。

用法：python scripts/gen_enemy_faction.py [EntityComponentMap.json 路径]
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_SRC = os.path.join(os.path.dirname(ROOT), 'Hd2-Armory-Tuning-Bench',
                           'build', '_refdata', 'EntityComponentMap.json')
OUT = os.path.join(ROOT, 'src', 'g60', 'enemy_faction.lua')

AI_ENEMY = '302 <=> AiEnemyComponentData'
FRIENDLY_NPC = '263 <=> FriendlyNpcComponentData'
AVATAR = '232 <=> AvatarComponentData'

# 生成后必须成立的抽查（防止数据源换版后规则悄悄失效）：
MUST_BE_ENEMY = {
    'be39e313a1e46bb9': '武斗虫 MK2',
    'a1f37bf2a40fbde4': '虫窝护卫',
    '3d0e03e2d574e1ca': '追猎虫 MK2',
    '9e2e17f2ccccafdd': '吐酸泰坦（titan_resource）',
    'ef04cb84d097a497': '泰坦变体（titan_variants）',
    '960b48a421a3faaa': '蟑龙（dragonroach_resource）',
}
MUST_NOT_BE_ENEMY = {
    '021eaecf4ca267dc': 'SEAF（城市）—— 规则唯一误判，见 EXCLUDE 的说明',
    '37cde43876ba26bb': 'A/MG-43 哨戒机枪（友方，实机被炸）',
    '820cc3bafe962858': 'A/FLAM-40 火焰哨戒炮（友方，实机被炸）',
    '31400a6a3003e29c': 'B-1 补给背包支架（友方，实机被炸）',
    'c87555eed1e9f092': 'MGX-42 支架（友方）',
    '16f397ca5f51f271': '战略配备信标球（友方）',
    'b16c9d490aa59b77': 'MGX-42 模型（友方）',
    '8e325c933e55bf62': 'G-60 投掷物（友方）',
    '4d1c334d294dfa97': '玩家本体（友方）',
    '4abcf54464695efa': '平民（中立）',
    '74e2285c01da4f71': '光能族增援飞船（敌载具，靠 marked_allowed 显式例外）',
    'db90077e76faa025': '机器人运输船（敌载具，靠 marked_allowed 显式例外）',
    '8c31b749759cbd61': '虫洞 MK9（走 structure_profiles 白名单，不经此表）',
}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    raw = open(src, 'rb').read()
    sha = hashlib.sha256(raw).hexdigest()
    doc = json.loads(raw.decode('utf-8'))[0]['EntityComponentMap']
    ents = doc['entities']

    def is_enemy(e):
        c = set(e.get('components', []))
        return AI_ENEMY in c and FRIENDLY_NPC not in c and AVATAR not in c

    raw_enemies = {'%016x' % int(e['resource_id']) for e in ents if is_enemy(e)}

    # ★ 显式排除（规则唯一误判）—— 有**独立**证据，不是随手加白名单：
    #   `021eaecf4ca267dc` = SEAF（城市）：它有 AiEnemyComponentData(302) 但**缺**
    #   FriendlyNpcComponentData(263)（其余 SEAF/平民/科学家都有 263）⇒ 被规则误判。
    #   独立证据：同工程 `_scratch/aggro`（aggro_counter）由 `scripts/find_friendlies.py`
    #   从 game.dll dump 生成的 105 条「超级地球实体」表**里有它** ⇒ 玩家阵营。
    #   ⚠ 若数据源换版后它不再被误判，下面那条 assert 会报错 ⇒ 排除项不会悄悄失效。
    EXCLUDE = {
        '021eaecf4ca267dc': 'SEAF（城市）：有 302 缺 263，规则误判；aggro_counter 的'
                            'FRIENDLY_HASHES 独立标注为超级地球',
    }
    for h in EXCLUDE:
        assert h in raw_enemies, (
            'EXCLUDE 里的 %s 已经不再被规则判为敌人 ⇒ 这条排除已失效，请删掉并复核' % h)
    enemies = sorted(raw_enemies - set(EXCLUDE))

    # ---- 抽查 ----
    bad = []
    for h, note in MUST_BE_ENEMY.items():
        if h not in enemies:
            bad.append('必须判为敌人却没有: %s %s' % (h, note))
    for h, note in MUST_NOT_BE_ENEMY.items():
        if h in enemies:
            bad.append('必须**不**判为敌人却被判了: %s %s' % (h, note))
    if bad:
        for line in bad:
            print('FAIL ' + line)
        raise SystemExit('生成中止：抽查不通过')

    # ---- 写出 ----
    lines = []
    lines.append('-- 敌人阵营资源表 —— **生成文件，不要手改**（改判据请改生成器再重跑）。')
    lines.append('--')
    lines.append('-- 生成器：scripts/gen_enemy_faction.py')
    lines.append('-- 数据源：%s' % os.path.basename(src))
    lines.append('--   sha256 = %s' % sha)
    lines.append('--   导出类型 %s / 组件类型 %s（来自数据源自带的 _metadata）'
                 % (doc['_metadata'].get('exported_type_count'),
                    doc['_metadata'].get('component_type_count')))
    lines.append('-- 判据：AiEnemyComponentData(302) 且 无 FriendlyNpcComponentData(263)')
    lines.append('--       且 无 AvatarComponentData(232)')
    lines.append('-- 条目数：%d' % len(enemies))
    lines.append('--')
    lines.append('-- 为什么需要它（2026-10-10 实机事故）：')
    lines.append('--   旧代码拿 `calls.target_valid` 当阵营判据，理由是"引擎索敌不锁友方"。')
    lines.append('--   实测它是"能不能被打"：哨戒炮/补给支架**有生命值** ⇒ 返回 true ⇒')
    lines.append('--   玩家标记的友方哨戒炮/支架被当成合法目标炸掉（517/592/536 三条实机证据）。')
    lines.append('--   本表是**反向**判据：只有"可证明是敌人"才允许被当目标（fail-safe）。')
    lines.append('--   ⚠ 数据源里没有的资源一律**不是**敌人 ⇒ 不接管（交回原生索敌）。')
    lines.append('local M={}')
    lines.append('-- 快照成局部表：生成后无人能改动它（与 target_allowlist 同一纪律）。')
    lines.append('local SET={')
    for i in range(0, len(enemies), 4):
        # ⚠ 必须是**键值**形式 `['hash']=true`。第一版写成 `'hash',` ⇒ SET 成了**数组**，
        #   `SET[resource]`（字符串键）恒为 nil ⇒ 门槛把所有目标全拒。
        #   这个错误是 tests 里"真跑模块"的那条门抓出来的（只比 Python 列表查不出来）。
        lines.append('    ' + ' '.join("['%s']=true," % h for h in enemies[i:i + 4]))
    lines.append('}')
    lines.append('-- ★ 判据入口：resource 是 16 位小写十六进制哈希（与 e.resource 同格式）。')
    lines.append("function M.is_enemy(resource)")
    lines.append("    return type(resource)=='string' and SET[resource]==true")
    lines.append('end')
    lines.append('M.count=%d' % len(enemies))
    lines.append('return M')
    body = '\n'.join(lines) + '\n'
    open(OUT, 'w', encoding='utf-8', newline='\n').write(body)
    print('wrote %s  entries=%d  bytes=%d' % (os.path.relpath(OUT, ROOT), len(enemies),
                                              len(body.encode('utf-8'))))
    print('source sha256=%s' % sha)


if __name__ == '__main__':
    main()
