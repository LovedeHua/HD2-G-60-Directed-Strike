-- 接管**门控判定**：每一帧对每颗 G-60 决定"这个实体本帧要不要被驱动"。
--
-- ★ 为什么把这些判断抽成纯函数（2026-09-28 重构）★
--   重构前这些判断全部内联在 experimental_runtime 的 host:tick() 里，
--   那个函数有 550 行、混合 7 类职责。而仓库里 195 个测试跑的是
--   g60/core.lua 的纯 Lua 策略层 —— **一行 runtime 都跑不到**。
--   后果是连续四轮实机事故全部从测试缝隙里溜过去：
--     · old.quarantined 缺 nil 保护 → 每帧 attempt to index nil
--     · diag.state3 未初始化 → nil+1 每帧崩
--     · Geometry 别名排在使用者之后 → upvalue nil，标记读到却锁不上
--     · selection_resource 用 assert → 11 次 state-4 实体一次都锁不上
--
--   纯函数化之后，这些判定可以在测试环境里**真跑**，
--   覆盖住"runtime 每帧到底做什么决定"这个从未被测过的层面。
--
-- 本模块**不做任何原生调用、不读内存**，只回答一个问题：
--   给定这一帧的观测结果与历史状态，应该驱动哪些实体、以什么方式驱动？
local M={}

-- 早期接管（state 2/3）默认关闭。见 compat/entry 的说明：
--   state 2/3 的导航不读任何目标数据，且 Search.capture 在早期 state
--   会 `pointer bound` 失败 ⇒ 打开只会让接管链每帧报错。
M.DEFAULT_EARLY=false

-- 单颗 G-60 连续观测失败多少次后放弃它。
--   单实体观测失败不影响其他实体，所以 mod 不会 disabled，
--   若不放弃就会每帧重试同一条必然失败的路径（实机静默 300+ 帧）。
M.OBSERVE_FAIL_LIMIT=8

-- 结构性致命消息：出现即永久停手。
--   注意这里必须是**完整消息**。上游按裸字符串精确比对，而 pcall 捕获的
--   error 带 `chunkname:line: ` 前缀 ⇒ 比对失败 ⇒ 竞争态被误当结构漂移
--   ⇒ 单颗 G-60 的瞬时竞争杀死整局（2026-09-27 实机事故）。
M.STRUCTURAL=nil   -- 由 native 模块负责分类，本模块不重复定义

-- 单颗实体这一帧的驱动方式。
-- 返回值 fields:
--   drive   true/false  本帧是否驱动它
--   early   true/false  是否走早期路径（只设目标，不做航点/引爆）
--   why     字符串      不驱动时的原因（供诊断）
function M.decide(opts)
    assert(type(opts)=='table','gate options')
    local o=opts
    if o.behavior_id~=4 then
        return {drive=false,early=false,why='not_g60'}
    end
    if o.retired then
        return {drive=false,early=false,why='already_retired'}
    end
    if o.native_update_eligible==false then
        -- 引擎已把它交给原生更新；本 mod 不再写。
        return {drive=false,early=false,why='engine_owns_it'}
    end

    local in_early_state=(o.state==2 or o.state==3)
    if in_early_state and not o.allow_early then
        return {drive=false,early=false,why='early_state_disabled'}
    end

    -- ⚠ old 可能为 nil（首次遇到这颗 G-60）。任何 old.<field> 访问
    --   都必须先判空 —— 2026-09-27 我写成 `not old.quarantined and ...`
    --   每次"有标记 + 无历史"都 attempt to index nil，整帧被 pcall 吞掉，
    --   表现为标记 ACCEPTED 却一次 priority_locked 都没有。
    local old=o.old
    if old and old.quarantined then
        -- 已被引擎抢写过的实体交回原生，本局不再写。
        return {drive=false,early=false,why='quarantined'}
    end

    -- 门控：只在"玩家标记了虫洞"或"本 mod 已持有锁定/航点"时才驱动。
    --   无标记的敌人 G-60：本 mod 不建 tracked、不读 Search、不写任何内存。
    if not (o.structure_mark or (old and (old.lock or old.titan))) then
        return {drive=false,early=false,why='no_mark_no_hold'}
    end

    -- 早期路径还有飞行时长门槛：刚出膛那几帧 movement 还没建立，
    --   此时写入风险最高（游戏崩过一次）。
    if in_early_state and (o.state_age or 0)<(o.early_min_age or 0) then
        return {drive=false,early=false,why='too_early_in_flight'}
    end

    -- ★ 关键安全属性 ★
    --   航点（titan aim/orbit）与引爆（explode）**只允许 state 4**。
    --   那两套要写 movement 结构，state 2/3 时它可能还没初始化。
    --   早期路径只准"设目标"，不得一路放到引爆。
    local can_guide=(o.state==4)
    local early=in_early_state
    return {
        drive=true,
        early=early,
        can_priority=true,
        can_guide=can_guide,
        can_detonate=can_guide,
        why=early and 'early_drive' or 'state4_drive',
    }
end

-- arrival 段（aim/orbit/explode）的门控。与 decide 分开是因为它还有
-- 额外的"必须真正持有"条件 —— 只有 priority 刚返回锁的那一帧才进。
function M.decide_guidance(opts)
    assert(type(opts)=='table','guidance options')
    local o=opts
    if not o.drive then
        return {run=false,why='not_driving'}
    end
    if not (o.old and (o.old.lock or o.old.titan)) then
        -- 没有实际持有锁定/航点 ⇒ 不做 aim/orbit/explode。
        --   arrival:step 在 target=nil 且 mask_only='search' 时会执行
        --   clear(pair,nil) 逐帧清掉引擎刚选中的目标 ⇒ G-60 永远锁不上
        --   （实机症状：只能锁大型敌人）。
        return {run=false,why='holding_nothing'}
    end
    if o.retired then
        return {run=false,why='already_retired'}
    end
    if not o.can_guide then
        return {run=false,why='state_not_guidable'}
    end
    return {run=true,why=o.early and 'early_guidance' or 'normal_guidance'}
end

return M
