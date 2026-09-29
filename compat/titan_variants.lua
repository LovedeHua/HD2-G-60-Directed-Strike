-- ★ 泰坦/敌人变体：**借用基线 profile 的几何**（2026-09-29）★
--
-- 【为什么可以借用 —— 证据，不是猜测】
--   用 datalibrary 的字符串表 + MurmurHash64A 反查资源路径（工具见
--   tests/hole_coverage.py 的 murmur64a / build_name_map）：
--     ef04cb84d097a497 → content/fac_bugs/cha_strider/cha_strider_gloom
--     9e2e17f2ccccafdd → content/fac_bugs/cha_strider/cha_strider
--   ⇒ **两者同属 `content/fac_bugs/cha_strider/` 这一个 unit 目录**，
--     只是叶子名不同 ⇒ 同一单位的变体。
--   旁证：priority_catalog 里两者都是 `name="Bile Titan"`；
--        generated_entities.dl_bin 里两者的记录结构相同（组件计数都是 55）。
--
-- 【项目既有先例】
--   tests/hole_coverage.py 的 BORROWED 表就是这个模式：
--     "7e4c6b45bcc45c3f": "8c31b749759cbd61",   -- warrior_captive -> warrior
--     "b6a181adcf547aeb": "8c31b749759cbd61",   -- warrior_ceiling -> warrior
--   即：变体没有自己的 profile 时，**复用基线参数**（组件集/碰撞参数几乎逐条相同）。
--
-- 【安全边界 —— 失败是 fail-closed 的】
--   借用不等于一定能用。titan_context 会在**写任何东西之前**校验：
--     · assert(L.hex64(identity,0)==profile.resource)          ← 身份必须匹配
--     · assert(profile.getters[getter-exe],'unsupported ... ')  ← 类必须同族
--     · boss_hash / belly_hash 锚点必须能在场景图里找到
--   任一条不过 ⇒ pcall 捕获 ⇒ 记 titan_skipped ⇒ **一个字节都不写**。
--   ⇒ 最坏情况是"借用无效、退回原生"，不会写错位置。
--
-- 【不要做成"按目录前缀批量借用"】
--   虽然同目录 = 同单位的证据很强，但批量借用会把未验证的变体一起放进来。
--   这里坚持**逐个显式登记**，每个条目都要能追溯到路径证据。
return function(base)
    assert(type(base)=='table' and type(base.resource)=='string','variant base profile required')
    local M={}
    -- 显式登记表：变体 resource → 基线 resource
    -- 每个条目都必须在注释里写明路径证据（同 unit 目录）。
    M.BORROWED={
        -- cha_strider_gloom（孢子泰坦 / Spore Burst Bile Titan）
        --   content/fac_bugs/cha_strider/cha_strider_gloom
        --   与基线 cha_strider 同目录 ⇒ 借用其 boss_hash/belly_hash/offset/
        --   alive_rva/engine_guards/getters。
        ["ef04cb84d097a497"]="9e2e17f2ccccafdd",
    }
    local profiles={}
    for variant,source in pairs(M.BORROWED) do
        assert(source==base.resource,
            'variant '..variant..' declares a base that is not the loaded profile')
        -- 逐字段复制引用（不深拷贝：getters 有 1500+ 条，共享即可，
        -- 几何是只读的）
        profiles[variant]={resource=variant,
            boss_hash=base.boss_hash,belly_hash=base.belly_hash,offset=base.offset,
            alive_rva=base.alive_rva,engine_guards=base.engine_guards,
            getters=base.getters,borrowed_from=source}
    end
    M.profiles=profiles
    -- 变体 resource 的列表（供日志/测试枚举）
    function M.resources()
        local out={}
        for k in pairs(profiles) do out[#out+1]=k end
        table.sort(out)
        return out
    end
    return M
end
