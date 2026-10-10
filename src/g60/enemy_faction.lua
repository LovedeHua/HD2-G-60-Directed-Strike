-- 敌人阵营资源表 —— **生成文件，不要手改**（改判据请改生成器再重跑）。
--
-- 生成器：scripts/gen_enemy_faction.py
-- 数据源：EntityComponentMap.json
--   sha256 = 09f6c4334d115773b2e88ed3b4850511fdd1798f7cefc46c8aa70703dfe11d3f
--   导出类型 1909 / 组件类型 319（来自数据源自带的 _metadata）
-- 判据：AiEnemyComponentData(302) 且 无 FriendlyNpcComponentData(263)
--       且 无 AvatarComponentData(232)
-- 条目数：138
--
-- 为什么需要它（2026-10-10 实机事故）：
--   旧代码拿 `calls.target_valid` 当阵营判据，理由是"引擎索敌不锁友方"。
--   实测它是"能不能被打"：哨戒炮/补给支架**有生命值** ⇒ 返回 true ⇒
--   玩家标记的友方哨戒炮/支架被当成合法目标炸掉（517/592/536 三条实机证据）。
--   本表是**反向**判据：只有"可证明是敌人"才允许被当目标（fail-safe）。
--   ⚠ 数据源里没有的资源一律**不是**敌人 ⇒ 不接管（交回原生索敌）。
local M={}
-- 快照成局部表：生成后无人能改动它（与 target_allowlist 同一纪律）。
local SET={
    ['0002ba767df856f3']=true, ['0883366204e1ccc5']=true, ['089833d2880d9e06']=true, ['08e6ffc2474287bd']=true,
    ['09dfb04b2e578bc3']=true, ['09fe0be51a23396c']=true, ['0ab7b92b131c228c']=true, ['0adc9f9173ad8e1d']=true,
    ['10081acef6163ef6']=true, ['137988cea16458f7']=true, ['1448d494665d01a0']=true, ['1897bdd32105d2dc']=true,
    ['1a7fcdff98c664b0']=true, ['1b5b9ac4f96b36e5']=true, ['1e66ee1f6f7fd00e']=true, ['1f0a91729c0004e0']=true,
    ['20b9c7734daead65']=true, ['215ce160a17be4cd']=true, ['257d805caa7e10c0']=true, ['262351741c53ff0c']=true,
    ['282eb766c1ffa6a1']=true, ['2a12104f2853ae16']=true, ['2cf3488c4845f8bd']=true, ['304c3124208291e9']=true,
    ['30cf04b2ec8c9bd4']=true, ['30f2dee2333f227a']=true, ['31bae74d2f064d8d']=true, ['32541fc4ec7c9cdc']=true,
    ['32cdeada234fb8df']=true, ['34dfd23365472e9e']=true, ['36aa99cce5e60146']=true, ['3aff5fd7d5450b99']=true,
    ['3d0e03e2d574e1ca']=true, ['3e0537d606438fea']=true, ['4019623142351cb6']=true, ['44458a2c52b002fb']=true,
    ['453fe22c634eb30f']=true, ['4e97fb073bdc7a4b']=true, ['51eea86bf6997e4e']=true, ['52018deb9ab6827e']=true,
    ['53d8919d7b8abd67']=true, ['54e107dacf6929cb']=true, ['57eed0eac346cd9d']=true, ['58b2b86c11369241']=true,
    ['5ca832447445c0ba']=true, ['5d142c3a73ebc634']=true, ['6021e22338333d88']=true, ['604a794ec45bb820']=true,
    ['611ba777783b08a2']=true, ['63df3d07b7424588']=true, ['64090088502435dd']=true, ['64ba5f030b114ec1']=true,
    ['672f7da17f3ba34a']=true, ['67dc32dca4f02d33']=true, ['684284354532cc0e']=true, ['6b202392f4ab605e']=true,
    ['6dab2eadf5d8b692']=true, ['728421351d440ebc']=true, ['72a83e49ced6db3d']=true, ['746a7f3beda32699']=true,
    ['78e1497571012c47']=true, ['7b48cacdbacb3881']=true, ['7ece5304f868f6b3']=true, ['82a87ad8d595b2ba']=true,
    ['843d18d4b5512b63']=true, ['856e9710e45e760f']=true, ['883401af2a98a5f6']=true, ['8ff0a839830a7692']=true,
    ['905809a4c28d8a45']=true, ['9076eeed17fcee35']=true, ['91ebd77931110afc']=true, ['960b48a421a3faaa']=true,
    ['96110f9d6b010e02']=true, ['9647b00cc3a9d36f']=true, ['965eae5a51acdd4a']=true, ['96ba14c9ebb49ce1']=true,
    ['9926876b2375a1bb']=true, ['9a8a3aae287b230c']=true, ['9d8827fed763650e']=true, ['9e2e17f2ccccafdd']=true,
    ['9f57782f00e6ed20']=true, ['a05bd1ec67b3ac4c']=true, ['a1f37bf2a40fbde4']=true, ['a35207c6f2150806']=true,
    ['a381a11c07d3eb94']=true, ['a4552f97033392f4']=true, ['a6a68d8af177f3a1']=true, ['a71aafd82c6ebc92']=true,
    ['aab438596f5e8fd9']=true, ['abdb2e2a0479d8ca']=true, ['ac60e78435098c9d']=true, ['ae57fcdb49f74e98']=true,
    ['ae63e525853d7044']=true, ['af0f9b3a163787a5']=true, ['b056f8fc74aba02d']=true, ['b2a6fa1e4284c7e6']=true,
    ['b4ed319b39f5457b']=true, ['b5dbc0c240c921ad']=true, ['b92435fbf60f0748']=true, ['bc242702fb46b7e7']=true,
    ['be39e313a1e46bb9']=true, ['be743b2faa3a6e26']=true, ['c626d2bb495a202d']=true, ['c6449ffd9ea3779c']=true,
    ['c9bcccb0a54a82a4']=true, ['cbb1ba3366009c3a']=true, ['cc188f0c80505c6c']=true, ['cc7022fdd172089b']=true,
    ['ccae5264acd591b7']=true, ['cd28a27a79be53d5']=true, ['d1e990baf22d5a52']=true, ['d37e8d120d2836e3']=true,
    ['d522fd4748d443a5']=true, ['d5792f6856b06ba4']=true, ['d63fcbff0851b7af']=true, ['d8cbc4a807a6d035']=true,
    ['d9511e9f6bd62e3f']=true, ['da40bb347c7447f2']=true, ['db964631be1cf501']=true, ['dcf8e74212fbee3b']=true,
    ['dfbacbd977a948dc']=true, ['e0353177f1329573']=true, ['e44ec9f9b3fe1d2a']=true, ['e683d2ca5618d74a']=true,
    ['e8f19a0aa958e46d']=true, ['eacee39fa017b495']=true, ['ef04cb84d097a497']=true, ['ef570293245a17c2']=true,
    ['f0b26fa9258128d3']=true, ['f1610ac48cdc5240']=true, ['f540ca9d9d4a422e']=true, ['f66d0bad8693779a']=true,
    ['f79cd8bb654397df']=true, ['f8131632aa867107']=true, ['f8b5a81a86d5d4eb']=true, ['fb9937035d652c43']=true,
    ['fc8dec78be8ab47d']=true, ['fd5247653c897803']=true,
}
-- ★ 判据入口：resource 是 16 位小写十六进制哈希（与 e.resource 同格式）。
function M.is_enemy(resource)
    return type(resource)=='string' and SET[resource]==true
end
M.count=138
return M
