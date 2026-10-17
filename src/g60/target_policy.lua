-- New-shot priority only. A valid per-grenade lock always wins over later pings.
local Filter=require('g60.small_filter')
local M={}
-- ★★★ 2026-10-14（用户要求）：**接管距离上限的唯一实现**（远距离追踪）★★★
--
--   用户原话（第一轮）：「增加主支的远距离追踪功能，不过只增加虫洞、构筑、巨型构筑、
--     尖啸巢、孢子喷涌虫、落地穿梭舰这几个，其他的就不弄远距离追踪了」。
--   用户原话（第二轮，纠正了上一版的两个数）：
--     · 「其他敌人的距离上限改为 100m」
--     · 「我说的那几个单位的距离上限改为 250m」
--
--   ⚠⚠ 2026-10-14 **用户实机修正**（纠正的是**说明**，不是数值）★★
--     我上一版把"泰坦 / 蟑龙 / 泰坦变体"写进"其他敌人 ⇒ 100 m"那一栏 —— **那是错的**。
--     用户原话：「泰坦这些是享受不到 100 m 的范围的，只保留虫洞这些的说明」。
--     核实（见 `experimental_runtime.lua`）：
--        `selected = m.selection_flag~=0 and m.selection_id~=P.inv_invalid`（**引擎的选中**）
--        `titan_selected = not abandoned and titan and selected`
--     ⇒ 泰坦由**引擎选中**触发、再由**泰坦链**引导，**根本不经过这里**；
--       本函数对泰坦返回的那个数只决定"玩家的标记进不进队列"，**不是**泰坦的行为边界。
--     ⇒ 说明与注释里**不再**把泰坦列进"其他敌人 100 m"（那会说出一个不成立的规则）。
--
--   ⚠⚠ **必须只有这一份**（这也是把它从 `native_priority.lua` 搬过来的原因）：
--     原来 `40000`（= 200 m 的平方）**硬编码在 4 处**，其中
--     `native_ping.lua` 那处跑在**更早**的"标记观察谓词"里 —— 主支 v0.1.35 漏改它，
--     超距的标记**进不了队列** ⇒ 用户报「有一些构筑标记后 G60 不会去追踪」
--     （实机 9 条 `OUTSIDE_200M`）。
--     ⚠ 教训：**同一个判据分散在多个模块时，"改全了"靠的是扫描而不是记忆。**
--       现在的门禁会扫 `src/g60/` 下**所有** lua 文件里的硬编码 40000。
--
--   ★ 名单来源 = `structure_profiles` **本身**（= "能拿到结构锁的目标"）：
--     用户点名的 6 类（虫洞 / 构筑 / 巨型构筑 / 尖啸巢 / 孢子喷涌虫 / 落地穿梭舰）
--     **全部**登记在那张表里；非结构目标（普通标记敌人等）不在表里。
--     ⇒ 用表当名单**不抄哈希**（"同一个判断不许出现两处"是本工程的硬纪律）；
--       以后往结构表加目标，远距离自动覆盖 —— 不需要再动这里。
--   ⚠ `structure_profiles` 关掉时（`marked_structures=false`）`env.structure_profiles`
--     为 nil ⇒ 名单为空 ⇒ **一律 100 m**（非结构目标的值）。
--
--   返回的是**平方**（米²）：所有调用点算出的 distance 都是平方和。
--
--   ★★★ 2026-10-14（用户报"标记远处泰坦有时飞向最近的敌人"）⇒ 三档，不是两档 ★★★
--     我上一版把判据写成"在不在结构表里"⇒ **泰坦也被算进"其他目标 100 m"**。
--     那是我引入的**回归**：0.1.22 原本对一切标记目标都是 200 m
--     （硬编码 `40000`），泰坦标记在 100~200 m 之间**本来能进队列，现在被丢掉了**。
--     用户上一轮其实已经指出过（「泰坦这些是享受不到 100 m 的范围的」），
--     但我当时**只改了文档、没改代码** —— 这是我的错。
--     ⇒ 现在给泰坦家族/蟑龙**自己一档 200 m**（= 它们改动前的值），
--       既不吃"其他目标 100 m"，也不跟结构那个滑块走
--       （用户明确要求滑块只管结构目标）。
function M.max_distance2(env, resource)
    if not (resource and env) then return 100*100 end
    -- ① 结构表里的目标 ⇒ 可自定义上限（菜单 `max_takeover_distance`，默认 250）。
    if env.structure_profiles and env.structure_profiles[resource] then
        local m=tonumber(env.max_takeover_distance) or 250
        -- ⚠ 夹取 50~1000 m：下限防止 0/负数让判据恒真（等于取消上限）；
        --   上限 1000 防止锁到天边目标时每帧做无意义的长距离几何。
        if m<50 then m=50 elseif m>1000 then m=1000 end
        return m*m
    end
    -- ★★★ 2026-10-18（用户要求）：**被点名的雕像目标走结构档** ★★★
    --   实机证据：雕像放行后**不再** `NOT_ENEMY_RESOURCE`，但仍被
    --     `structure_mark;…;resource=7c9455fcef107e41;reason=OUTSIDE_RANGE` 拒 ——
    --     因为它不在 `structure_profiles` 里 ⇒ 落到下面"其他目标"那一档
    --     （`other_takeover_distance`，用户当时设 **150**）。
    --   用户原话（选定方案 A）：「雕像改走结构档」。
    --   ⚠ 用 `Filter.statue_target`（**单一数据源**，表在 `small_filter.lua`）——
    --     不在这里抄哈希，也不去翻 `marked_allowed`（那里面运输船/构筑/泰坦
    --     都不该跟着改距离）。
    --   ⚠ 夹取与滑块范围**对齐**（50~1000），与上面那档同规则。
    if Filter.statue_target(resource) then
        local m=tonumber(env.max_takeover_distance) or 250
        if m<50 then m=50 elseif m>1000 then m=1000 end
        return m*m
    end
    -- ② **非结构**的标记目标 ⇒ 一档（菜单 `other_takeover_distance`，默认 200）。
    --
    --   ★★★ 2026-10-14（第二轮，用户要求）：**泰坦与其他敌人合并成这一档** ★★★
    --     用户原话：「泰坦距离上限跟其他敌人的合并在一起调整」。
    --     ⇒ 泰坦 / 泰坦变体 / 蟑龙 / 普通敌人… **共用**这一个值。
    --     ⇒ 因此这里**不再需要**"泰坦家族"的单独判据 —— 判据简化成
    --       「在结构表里 / 不在结构表里」两档（这也消除了一个会漂移的名单判断）。
    --         · `env.titan_profile` / `titan_variant_profiles` / `dragonroach_resource`
    --           这三条判据**已从本函数删除**；家族名单仍活在它该在的地方
    --           （`titan_approach.is_titan`、`small_filter.marked_allowed`）。
    --     ⚠ 默认 **200**：泰坦保持改动前的值（用户反复强调泰坦不该被 100 m 卡住）；
    --       代价是"其他敌人"从 100 → 200（= 0.1.22 对一切标记目标的 200 m）。
    --       要反过来（都按 100）只需改这一处默认与菜单滑块的默认。
    --     ⚠ 夹取与滑块范围**对齐**（50~1000，**步长 5**），否则就是"界面够得着却被夹掉"
    --       或"代码允许但界面到不了"的死配置 —— 本工程明令忌讳。
    --
    --   ▸ 历史（别抹掉）：2026-10-14 早先有过**三档** —— 结构 / 泰坦家族 200 /
    --     其他 100。那是我把"非结构一律 100"写错、导致 100~200 m 的泰坦标记被静默
    --     丢掉之后补的（用户报「标记远处泰坦有时飞向最近的敌人」）。
    --     现在用户要求**合并**，于是回到两档，但**两档都可调**。
    local m=tonumber(env.other_takeover_distance) or 200
    if m<50 then m=50 elseif m>1000 then m=1000 end
    return m*m
end
function M.choose(rows,catalog,mark,lock,allowed)
    local eligible={}
    for _,r in ipairs(rows) do
        if not Filter.excluded(r.entity.resource) and (not allowed or allowed(r.entity.resource)) then eligible[#eligible+1]=r end
    end
    if lock then
        for _,r in ipairs(eligible) do if r.entity.identity==lock.identity then return r,'LOCKED' end end
    end
    if mark then
        for index,ping in ipairs(mark.queue or {mark}) do
            for _,r in ipairs(eligible) do
                if r.entity.identity==ping.identity then
                    return r,ping.current and 'CURRENT_PING' or 'REMEMBERED_PING',index
                end
            end
        end
    end
    local best,rank
    for _,r in ipairs(eligible) do
        local spec=catalog[r.entity.resource]
        if spec and (not best or spec.rank<rank or (spec.rank==rank and r.score>best.score)) then best,rank=r,spec.rank end
    end
    if best then return best,'AUTO_PRIORITY_'..rank end
    return nil,'VANILLA'
end
return M
