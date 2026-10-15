-- 接近标记的泰坦，到距离后**放手** —— 用户 2026-10-14 的方案。
--
-- 为什么需要这一条：**泰坦链的触发条件是引擎自己的选中**。历史上"认领/接管泰坦"
-- （A/C/D 路）全都毁掉爆点，因为它们在泰坦链前面**插了第二个驱动者**。
-- 用户方案 = 先像普通标记目标那样把雷**驱动到泰坦附近**，到 ~10 m **放开接管**
-- ⇒ 引擎自己选中它 ⇒ 泰坦链成为**最后的唯一引导者**，爆点由 Adaptive 算
-- （腹点 + 腹法线 × 2.5），与 0.1.22 基线一致。
--
-- ⚠ 两半缺一不可：
--   ① `decide` / `is_released`：到距离 ⇒ 放手。
--      调用侧（runtime）清 `old.lock`/`old.titan`，并让 `marked_lock_held` 对这颗**失效**
--      —— 否则 priority 每帧重建锁（实机 31~83 次 `priority_locked`）⇒ 链的门永远挡住。
--      这是 A/C/D 路一直缺的那一环：**它们接管到底、从不放手**。
--   ② `point`：接近阶段给一个**航点**（= 目标实体原点），供 arrival 的
--      `options.point_target` 写路径使用（与"ping 空地"同一条已验证过的路）。
--      ⚠ 它**只是航点，不是引爆点**：放手距离（默认 10 m）远大于默认到达区域
--        （`point_arrival_region` radius 3）⇒ 正常情况下在进入区域**之前**就已经放手，
--        真正的爆点仍由泰坦链给。
--
-- ⚠⚠ **本仓相对主支修正了一处死结**（用户要求"顺手把点提供者修好"）：
--   主支 `point()` 的顺序是 `is_titan(env,resource)` 在前、解析 profile 在后，
--   而它的 runtime 传的是 **profile 表** ⇒ `is_titan` 里全是
--   `p.resource == resource`（**字符串 vs 表**）⇒ 恒假 ⇒ 实测 `why=NOT_TITAN`、
--   **点永远不提供**（v0.2.35 声称修好了，但没修对；只是不影响结果所以没人发现）。
--   本仓改成：**先把入参归一成 profile，再判家族**，并且家族判据**只来自 `env.*` 名单**
--   （`is_titan`）—— 与 `claim_profile` 的认领判据**同源**，不抄哈希、不按 `kind` 推断。
--   ⚠ 为什么不按"非结构、无 kind"推断（主支那份 `is_titan_profile` 的做法）：
--     **蟑龙的 profile 带 `kind="thorax"`**（见 `compat/weakpoint_profiles.lua`）
--     ⇒ 按 kind 会把它误判成"不是泰坦"，与 `is_titan`（名单）**两把尺子**打架。
--     现在只有**一把尺子**：`env.*` 名单。
local Data = require('g60.native_target_data')

local M = {}

-- 每颗雷的记账。**模块级**，不是 tick 闭包的 upvalue（那个闭包恰好 60 个）。
M.released = {}   -- grenade id -> 放手的帧
M.logged = {}     -- grenade id -> 上次打诊断的帧

-- ★ 家族判据：基线泰坦 / 泰坦变体 / 蟑龙。只用 `env.*` 名单（不抄哈希）。
function M.is_titan(env, resource)
    if not (env and resource) then return false end
    local p = env.titan_profile
    if p and p.resource == resource then return true end
    local v = env.titan_variant_profiles
    if v and v[resource] then return true end
    if env.dragonroach_resource and env.dragonroach_resource == resource then return true end
    return false
end

-- 入参归一：允许**资源字符串**（推荐）或**已解析的 profile**（调用侧两种都可能有）。
-- 返回 profile（或 nil）。
function M.resolve_profile(env, resource)
    if type(resource) == 'string' then
        return (env and env.claim_profile and env.claim_profile(resource)) or nil
    end
    if type(resource) == 'table' then return resource end
    return nil
end

local function origin(read, base, exe, id)
    local d = Data.new(read, base, exe)
    local e = d.entity(id)
    if not e then return nil end
    return d.position(e)
end

-- 返回 nil，或 {dist=<米>, want=<米>, release=<bool>}。
-- ⚠ 这里**不判家族**：它只管"离多近了"。放手那一半对任何被标记目标都成立，
--   而"要不要接近"由调用侧按家族决定（`point` 才判家族）。
function M.decide(read, base, exe, env, grenade_id, target_id, frame)
    if env and env.titan_approach_enabled == false then return nil end
    if type(grenade_id) ~= 'number' or grenade_id == 0 then return nil end
    if type(target_id) ~= 'number' or target_id == 0 then return nil end
    local ok, res = pcall(function()
        local g = origin(read, base, exe, grenade_id)
        local t = origin(read, base, exe, target_id)
        if not g or not t then return nil end
        local s2 = 0
        for i = 1, 3 do s2 = s2 + (g[i] - t[i]) ^ 2 end
        local d = math.sqrt(s2)
        local want = tonumber(env and env.titan_approach_dist) or 10
        -- 与菜单滑块范围（3~60）**对齐** —— 否则就是"界面够得着却被夹掉"的死配置。
        if want < 3 then want = 3 elseif want > 60 then want = 60 end
        return {dist = d, want = want, release = d <= want}
    end)
    if not ok or not res then return nil end
    if res.release and not M.released[grenade_id] then
        M.released[grenade_id] = frame
    end
    return res
end

-- 接近阶段的航点。返回 {x,y,z}；**已放手 / 不是泰坦 / 解析不出** ⇒ nil。
-- nil 是正常语义（"不要再驱动了"），调用侧据此保持"没有点"。
function M.point(read, base, exe, env, grenade_id, target_id, frame, resource)
    local function no(why)
        M.last_why = why
        if M.last_reported ~= why then
            M.last_reported = why; M.changed = true
        else
            M.changed = false
        end
        return nil
    end
    -- ★ 先把入参归一成 profile，**再**判家族（顺序即语义，见文件头那段）。
    local prof = M.resolve_profile(env, resource)
    if not prof then return no('NO_PROFILE') end
    -- 一把尺子：profile 的资源名必须落在 `env.*` 家族名单里。
    if not M.is_titan(env, prof.resource) then return no('NOT_TITAN') end
    -- ⚠ 结构/弱点类**不在**家族名单里，上面那句已经挡掉；
    --   这里再挡一次"名单与 profile 形状漂移"（认领路径改了而名单没跟上）。
    if prof.structure then return no('NOT_TITAN') end
    if type(target_id) ~= 'number' or target_id == 0 then return no('NO_TARGET_ID') end
    local res = M.decide(read, base, exe, env, grenade_id, target_id, frame)
    if not res then return no('NO_DECIDE') end
    if res.release then return no('RELEASED') end
    local ok, pos = pcall(origin, read, base, exe, target_id)
    if not ok or not pos then return no('NO_ORIGIN') end
    M.last_why = 'OK'
    if M.last_reported ~= 'OK' then
        M.last_reported = 'OK'; M.changed = true
    else
        M.changed = false
    end
    return {pos[1], pos[2], pos[3]}
end

-- 这颗雷是否已经放手。runtime 用它让 `marked_lock_held` 失效 ——
-- 这是"不让 priority 重新接管"的**唯一**手段（清一次锁不够）。
function M.is_released(id)
    return id ~= nil and M.released[id] ~= nil
end

function M.forget(id)
    M.released[id] = nil
    M.logged[id] = nil
end

-- 每颗雷每 ~30 帧一条诊断；**放手那一帧必打**（否则"到底放没放手"看不见）。
function M.line(res, grenade_id, target_id, frame, released_now)
    if not res then return nil end
    local last = M.logged[grenade_id]
    if not released_now and last and frame and (frame - last) < 30 then return nil end
    M.logged[grenade_id] = frame
    return 'titan_approach;entity=' .. tostring(grenade_id)
        .. ';target=' .. tostring(target_id)
        .. ';dist=' .. string.format('%.2f', res.dist)
        .. ';want=' .. string.format('%.1f', res.want)
        .. ';released=' .. (released_now and '1' or '0')
        .. ';frame=' .. tostring(frame)
end

return M
