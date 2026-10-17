-- Local-player allocation only; these keys are observations, not lifetime leases.
local M={}
local function identity(bytes)
    assert(type(bytes)=='string' and #bytes==24,'reservation identity required')
    -- Activity flags may change while the same entity still exists.
    return bytes:sub(1,20)
end
function M.owner(match) return identity(match.identity_bytes) end
-- ★★★ 2026-10-14（用户要求）：**同一目标可被几颗 G-60 预约，做成可配置** ★★★
--   移植自主支 `g60-bughole-lock`（0.1.55+ 已实机验证）。用户要的三条：
--     ① 单个标记可自定义分配手雷数量
--     ② 多个标记也可自定义分配手雷数量
--     ③ 标记按照**时间顺序**分配手雷（见 runtime 的挑选用 `marked_at` 最小）
--
--   ⚠ 旧实现是 `target -> 单个 owner` 的映射 ⇒ **结构上**就只能一颗雷占一个目标：
--       `return held==nil or held==owner` —— 别人来问一律 false。
--       ⇒ 第 2 颗雷在 `generic_validate` / 结构分支拿不到锁（日志 `TARGET_RESERVED`）。
--   ⇒ 改成 `target -> { [owner]=true, … }`（**一组** owner）+ 上限 `cap`。
--
--   ⚠ **默认 cap=1 = 完全维持既有行为**（`target_reservations.lua` 的老测试测的就是单 owner 语义）。
--     要"2 颗雷一起追同一个标记"就把 cap 调到 2 及以上。
--   ⚠ cap 是**每目标**的上限，不是全局。夹取到 ≥1（0/负数会让"可预约"恒假 ⇒ 谁都锁不上）。
--   ⚠ `exclusive_targets=false` 时 runtime **根本不建** reservations（`reservations=nil`）
--     ⇒ 那是"完全不做预约"（不限颗数），与本 cap 是两回事：
--       · `exclusive_targets=false`      ⇒ 不预约（历史上就是这样，保留）
--       · `max_grenades_per_target=N`    ⇒ 预约，且每目标最多 N 颗
-- ★★★ 2026-10-18（用户要求）：**按单位资源的白名单上限** ★★★
--   用户原话：「增加白名单，白名单里面的单位可以突破手雷数量上限，
--     移动工厂接受2颗手雷，坦克及其变体接受2颗手雷，噪轰引擎可以接受4颗手雷，
--     猎杀器、证真者可以接受2颗手雷」，且「这个白名单对无标记的情况下也起作用」。
--   ⇒ 上限不再是**一个数**，而是 `cap_by_resource[resource] or cap`。
--   ⚠ 为什么必须按资源取：白名单是"某些单位能多挨几颗"，
--     而不是"所有目标都能多挨几颗"（后者会把 1:1 分散规则毁掉）。
--   ⚠ `resource` 是**16 进制 16 字符**的资源哈希（与 `spread_priority.lua` /
--     `enemy_faction.lua` 同一写法），由调用点传入（它们手里都有 `ent.resource`）。
--   ⚠ 白名单缺席时**行为与旧版逐字一致**（只认 `cap`）⇒ 老测试不受影响。
function M.new(cap, cap_by_resource)
    cap=tonumber(cap) or 1
    if cap<1 then cap=1 end
    local caps=cap_by_resource or nil
    -- ★ 上限解析的**唯一入口**（`available` 与 `claim` 共用 ⇒ 判定与登记永远一致）
    local function limit(resource)
        local n=caps and resource and caps[resource]
        n=tonumber(n)
        if n and n>=1 then return n end
        return cap
    end
    local targets={}          -- target_key -> { [owner]=true, … }
    -- ★ 2026-10-14：**缺席计数**（见 reconcile 的宽限说明）
    local missing={}
    local api={}
    local function count(held)
        local n=0
        for _ in pairs(held) do n=n+1 end
        return n
    end
    function api:reset() targets={};missing={} end
    -- ★★★ 2026-10-14（主支记录的事故：标 2 个构筑、扔 2 颗，只有 1 颗飞）★★★
    --   **缺席宽限**：一次完整观测里"没看到"某颗雷，**不足以**判定它已经不在场 ——
    --   状态切换（3→4）、观测窗口边界、刚生成都可能让它短暂缺席。
    --   ⚠⚠ 旧实现**立刻回收** ⇒ 名额被释放 ⇒ 另一颗雷看到"空闲"就挑了**同一个**标记。
    --   ⇒ 改成"**连续缺席 `grace` 次完整观测**才回收"（默认 1 = 旧行为；
    --     runtime 传较大值 ⇒ 短暂缺席不再泄漏名额）。
    --   ⚠ 仍然会回收真离场的（爆炸/移除后连续缺席必然累计到 grace）⇒ 不会永久占位。
    --   ⚠ `reconcile` 只在**完整观测**之后调用（调用点已保证）—— 这是宽限能成立的前提。
    function api:reconcile(matches,grace)
        grace=tonumber(grace) or 1
        if grace<1 then grace=1 end
        -- Only call after a complete accepted observation, never after a failed
        -- read, skipped update, or a list filtered down to guidable projectiles.
        local present={}
        for _,m in ipairs(matches) do present[M.owner(m)]=true end
        -- ★ 缺席计数每次 reconcile 只能进 1
        --   （按 target 遍历时，持有 2 个标记的缺席者会计 2 次 ⇒ 宽限减半）
        local aged,expired={},{}
        for key,held in pairs(targets) do
            -- ⚠ 遍历中把**已存在的键**置 nil 是允许的（新增键才不允许）——
            --   所以这里安全；不要改成"另建一张表再替换"，那会漏掉别人持有的 owner。
            for owner in pairs(held) do
                if present[owner] then
                    missing[owner]=nil
                else
                    if not aged[owner] then
                        aged[owner]=true
                        local n=(missing[owner] or 0)+1
                        if n>=grace then expired[owner]=true;missing[owner]=nil
                        else missing[owner]=n end
                    end
                end
            end
            if next(held)==nil then targets[key]=nil end
        end
        -- ★ 宽限到期的 owner 必须**一次性释放全部**（否则 grace=1 时
        --   只有当前这一个 target 被释放，其余占用永远清不掉）
        for owner in pairs(expired) do api:release_owner(owner) end
    end
    -- ★ 语义：本目标**还剩名额**（或本来就是我持有的）⇒ 可用
    --   ⚠ `resource` 可选：给了就走白名单上限，没给就用 `cap`（旧行为）
    function api:available(owner,target,resource)
        local held=targets[identity(target)]
        if held==nil then return true end
        if held[owner] then return true end
        return count(held)<limit(resource)
    end
    -- ★★★ 2026-10-14（用户要求"多个标记也能自定义"）★★★
    --   **当前负载**：该目标已被几个 owner 持有（无则 0）。
    --   ⚠ runtime 用它实现"**先分散、再共享**"：在**还有空位**的标记里挑
    --     **负载最小**的那个（同负载时保持队列顺序 = 档位优先）。
    --   ⚠ 为什么必须有这个 API：只判 `available`（= 还有空位）会让"挑第一个有空位的"
    --     在 cap>1 时把**第 2 颗也送到同一个标记**（第一个仍有空位）
    --     ⇒ 多标记时 1:1 被破坏。
    function api:set_cap(n)
        n=tonumber(n) or 1
        if n<1 then n=1 end
        cap=n
    end
    -- ★ 2026-10-18：白名单表（resource -> 上限）。传 nil 即撤销白名单。
    function api:set_cap_map(map)
        caps=(type(map)=='table') and map or nil
    end
    function api:load(target)
        local held=targets[identity(target)]
        return held and count(held) or 0
    end
    function api:claim(owner,target,resource)
        local key=identity(target)
        local held=targets[key]
        if held==nil then held={};targets[key]=held end
        if held[owner] then return end
        assert(count(held)<limit(resource),'target already reserved')
        held[owner]=true
    end
    -- ⚠⚠ **不存在 `claim_shared`**（主支 v0.1.39 短暂加过，已删除）⚠⚠
    --   它当时让 runtime 在"所有标记都已被预约"时绕过名额断言强行登记，
    --   理由是 runtime 注释里那句"全都被占了 ⇒ 允许共享（避免一颗都不打）"。
    --   用户明确推翻：「单标记情况下可以允许多颗雷（**前面的自定义数量**）
    --   追踪锁定标记敌人，多标记敌人同时存在时每个敌人分一颗手雷」
    --   ⇒ **cap 是硬上限**。⚠ 2026-10-18（用户要求）起口径变了：
    --     基础上限**只有一个**（runtime 传进来的 `cap`；无标记时是硬性 1），
    --     而**按单位资源的白名单**（`cap_by_resource`）可以把它抬高
    --     —— 原来的"单标记/多标记两个设置"已随滑块一起移除。
    --   强行共享会让 cap 变成摆设（cap=2 时第 3、4 颗照样挤进来）。
    --   ⇒ 空位用尽时**如实拒绝**（`TARGET_RESERVED`），这才符合"上限"的语义。
    --   ⚠ 名额断言（下面 `claim` 里的 `assert(count(held)<cap)`）是"同一目标被两颗雷
    --     同时预约"这类真实 bug 的防线，**任何时候都不要拆**。
    function api:release_owner(owner)
        for key,held in pairs(targets) do
            held[owner]=nil
            if next(held)==nil then targets[key]=nil end
        end
    end
    -- ★★★ 2026-10-14（主支**离线仿真 S10 找到的真问题**）★★★
    --   **一颗雷只能持有"当前分到的那一个"标记。**
    --   ⚠⚠ 不加这条会**囤积预约**：`available` 对"本人已持有"的键恒真，
    --     所以当一颗雷的标记**暂时不可用**（被取消 / 引擎暂时不认 / 判据短暂为假）时，
    --     它会去 claim **另一个**标记，而**原来那个仍然记在它名下**
    --     ⇒ 那个名额被**永久占住**，直到这颗雷退役（或 `reconcile` 把它算作离场）
    --     ⇒ 别人再也拿不到它，即使它又变回可用。
    --   【仿真铁证】主支 `tests/test_allocation_simulation.py` 的 S10：
    --     g1 第 1 帧 → 1001（loads=[1,0]）
    --     g1 第 2 帧 → 1002（loads=[1,1]）← ★ 同时握着 A 和 B
    --     g2 第 3 帧 → **None**（loads=[1,1]）← ★ A 被陈旧预约卡死
    --   ⇒ `keep_only` 在每次**选中之后**清掉该雷名下**除它之外**的全部预约。
    --   ⚠ 与 `release_owner` 的区别：那个清**全部**（退役用），这个**留一个**（分配用）。
    --   ⚠ 单标记 + cap≥1 时也适用：那颗雷本来也只该持有那一个标记。
    function api:keep_only(owner,keep)
        local keepkey=identity(keep)
        for key,held in pairs(targets) do
            if key~=keepkey and held[owner] then
                held[owner]=nil
                if next(held)==nil then targets[key]=nil end
            end
        end
    end
    return api
end
return M
