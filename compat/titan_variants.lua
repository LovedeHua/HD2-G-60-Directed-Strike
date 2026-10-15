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
--
-- ★★★ 2026-10-14 事故与修法：「显式**逐字段**复制」会静默漏掉后来新增的字段 ★★★
--   症状（用户报）：孢子泰坦的**姿态系统不生效** —— 而两者同模型、姿势法线逐字相同。
--   根因（已用 git 历史钉死）：
--     · 本模块 **2026-09-29**（`2a166fa`）写下逐字段复制清单；
--     · `animated_belly` / `right_local` / `forward_local` 是 **2026-10-09**（`83f69c8`）
--       才加进基线的。
--     ⇒ **白名单式的显式复制不会自动跟上基线的新字段**，而当时没有任何守门提醒。
--   后果链（不是崩，是**静默退化**）：
--     `titan_context.lua` 的门是 `follow_animation and profile.animated_belly and …`
--     ⇒ 变体 `belly_pose` 恒 nil ⇒ `belly_outward`/`pose_signature`/`pose_unreliable`
--       全 nil ⇒ `Adaptive` 退回兜底法线 `{0,0,-1}`，**而且"姿态不可靠就拒绝引爆"
--       那条保护也一并失效**（`pose_unreliable` 为 nil ⇒ 判据不成立）。
--     ⚠ 实测偏移量级：同一目标、法线倾斜 40° 时，有姿态 vs 无姿态的爆点
--       **水平相差 ~1.9 m** —— 这就是"爆点不太对"的来源之一。
--     ⚠ `right_local`/`forward_local` 缺失时 `titan_context` 有 `or` 兜底，
--       所以症状更隐蔽：**朝向悄悄换成兜底值**，日志里一个字都没有。
--
--   ⇒ **修法（结构性的，不只是补三个字段）**：
--     借用清单改成**从基线自动全覆盖**（`for k,v in pairs(base)`），
--     只排除必须自有的键（现在是 `resource`）。
--     · 于是**基线以后新增任何字段，变体自动跟上** —— 这次事故在结构上不可能重演；
--     · 仍保留 `BORROWED` 显式登记表管"**哪些变体**可以借"（不做同目录批量放行）；
--     · `tests/` 里有一条守门做**反向穷举**（基线每个几何字段都必须在变体里出现），
--       万一将来有人把这里改回手写清单，门会当场红。
--     ⚠ 安全性没有放松：`titan_context` 的 fail-closed 校验（身份/同类/锚点）一条未动，
--       而且 `right_local`/`forward_local` 本来就是**身体局部系常量**，
--       同 unit 同模型 ⇒ 逐字相同（这正是"可以借用"的那份证据）。
return function(base)
    assert(type(base)=='table' and type(base.resource)=='string','variant base profile required')
    local M={}
    -- 显式登记表：变体 resource → 基线 resource
    -- 每个条目都必须在注释里写明路径证据（同 unit 目录）。
    M.BORROWED={
        -- cha_strider_gloom（孢子泰坦 / Spore Burst Bile Titan）
        --   content/fac_bugs/cha_strider/cha_strider_gloom
        --   与基线 cha_strider 同目录 ⇒ 借用其**全部几何**（含姿态法线 animated_belly
        --   与朝向基准 right_local/forward_local —— 2026-10-14 补，见文件头事故说明）。
        ["ef04cb84d097a497"]="9e2e17f2ccccafdd",
    }
    -- ★ 必须**自有**、绝不从基线继承的键。
    --   `resource` = 变体自己的身份（借了会当场触发 titan_context 的 identity mismatch）。
    local OWN_KEYS={resource=true}
    -- ★ `borrowed_from` = 溯源字段，由本模块写入（基线没有它）。
    local profiles={}
    for variant,source in pairs(M.BORROWED) do
        assert(source==base.resource,
            'variant '..variant..' declares a base that is not the loaded profile')
        local p={resource=variant,borrowed_from=source}
        -- ★★★ 自动全覆盖（不是手写清单）：基线有的字段**一个不落地**带过来 ★★★
        --   ⚠ 逐字段复制**引用**（不深拷贝）：`getters` 有 1500+ 条，共享即可，
        --     几何是只读的（与旧实现同一取舍）。
        for k,v in pairs(base) do
            if not OWN_KEYS[k] then p[k]=v end
        end
        profiles[variant]=p
    end
    M.profiles=profiles
    -- ★ 供守门做**反向穷举**：返回"基线里应当被借用的字段名"（排序后，稳定可比）。
    --   为什么必须由模块自己算：字段清单散落在三处（模块/测试/基线）必然漂移 ——
    --   这是本项目反复栽的「同一个判断写两遍」。
    function M.borrowable_fields()
        local out={}
        for k in pairs(base) do
            if not OWN_KEYS[k] then out[#out+1]=k end
        end
        table.sort(out)
        return out
    end
    -- 变体 resource 的列表（供日志/测试枚举）
    function M.resources()
        local out={}
        for k in pairs(profiles) do out[#out+1]=k end
        table.sort(out)
        return out
    end
    return M
end
