-- Exact resources only. Unknown variants retain vanilla eligibility.
local U = require('g60.util')
local M = {}
-- ★★ 裁剪 E（修 bug 的最后一层）：上游这张表排除了 8 种小虫 + Impaler 触手 + Hive Guard，
--   而 selection_veto.plan() 第 23 行的判据是
--       if not Filter.excluded(r) and (not allowed or allowed(r)) then keep end
--   即使 designed_targets_only=false 让 allowed 变成 nil，**这半个条件仍会生效**，
--   于是这 9 个资源照样被 clear_selection + 强制搜索 —— 表现就是
--   "G-60 打不了中小型敌人、只锁大型目标"。
--   本工程要求"未标记虫洞时完全按游戏原生处理"，所以整表清空：
--   敌人选择权 100% 交还引擎 TargetLock，本 mod 只在 9 个虫洞上接管。
--
-- ★★★ 2026-09-29 例外：用户明确要求"G-60 不追踪运输船"，重新启用**一项** ★★★
--
--   上游那 9 项（8 种小虫 + Impaler 触手 + Hive Guard）**不恢复** ——
--   它们的症状是"G-60 打不了中小型敌人"，正是本工程当初清空该表的原因。
--   这里只放**用户点名的一个资源**，范围最小化。
--
--   ⚠️ 与上游用法的关键差别：这张表的**三个调用方**
--     ① native_priority.lua:120  eligible()   —— 只作用于本 mod 已持有的实体
--     ② target_policy.lua:7     候选打分      —— 同上
--     ③ selection_veto.lua:23   选择否决      —— 经 runner 调用，**这才是生效点**
--   ①② 的效果只是"我们不会把运输船当成自己的锁定目标"，无害且符合意图；
--   ③ 才是实现"不追踪"的地方：Veto.plan 返回
--      {kind='search', clear_selection=true} → calls.clear + calls.orbit。
--
--   ⚠️ 仅把资源加进这张表**并不够** —— `runner` 只在"本 mod 持有的实体"上被调用
--      （见 take_gate 的 no_mark_no_hold 门控）。所以配套改了 take_gate：
--      当**非自有** G-60 的引擎选择命中本表时，专门放行一条 `veto` 决策。
--      缺了那一步，这张表对本场景**完全无效**。
--
--   证据程度（诚实记录）：用户给的十进制 ID 换算为 98152772a72f7838，
--   该哈希**确认存在于**游戏实体表 generated_entities.dl_bin（小端 @67356，
--   32 B/条，组件数 30）；但用 MurmurHash64A 反查资源路径**查不到**
--   （17/17 虫洞都能反查），所以"它=运输船"**未经独立验证**。
--   ⇒ 因此加了 enemy_selection 只读日志与 enemy_veto_enabled 开关：
--      实机看到 enemy_veto 在追运输船时触发 = 身份得到确认；
--      若在别的东西上触发，置 false 即可立即回退。
local excluded = {
    ['98152772a72f7838'] = true,   -- 运输船 Dropship（用户 2026-09-29 点名排除）
}
function M.excluded(resource) return excluded[resource] == true end
local function resource(value)
    return type(value)=='string' and #value==16 and value:match('^[0-9a-f]+$')~=nil
end
function M.plan(snapshot, was_searching)
    if type(snapshot)~='table' or snapshot.resource~='8e325c933e55bf62'
        or snapshot.behavior_id~=4 then return nil,'NOT_G60' end
    if snapshot.active~=true or snapshot.expired~=false
        or (snapshot.state~=3 and snapshot.state~=4) then return nil,'INACTIVE' end
    if not U.ref(snapshot.ref) or type(snapshot.candidates)~='table'
        or snapshot.complete~=true or snapshot.aliased~=false then return nil,'INCOMPLETE' end
    local selected=snapshot.selected
    if selected~=nil then
        if type(selected)~='table' or not U.ref(selected.ref) or not resource(selected.resource)
            or selected.ref.scene~=snapshot.ref.scene then return nil,'INVALID_SELECTION' end
        if not excluded[selected.resource] then return {kind='keep'},'VANILLA_ALLOWED' end
    elseif not was_searching then
        return {kind='keep'},'VANILLA_SEARCH'
    end
    -- Existing trace scores alone do not establish freshness. This must be
    -- supplied by a verified runtime adapter, never inferred from score >= 0.
    if snapshot.scores_current~=true then return nil,'STALE_SCORES' end
    local best, seen, count = nil, {}, 0
    for index,row in pairs(snapshot.candidates) do
        count=count+1
        if type(index)~='number' or index%1~=0 or index<1 or index>51
            or type(row)~='table' or not U.ref(row.ref) or not resource(row.resource)
            or row.ref.scene~=snapshot.ref.scene or not U.finite(row.score) then
            return nil,'INCOMPLETE_CANDIDATE'
        end
        local key=U.key(row.ref)
        if seen[key] then return nil,'ALIASED_CANDIDATE' end
        seen[key]=true
        if row.score<0 then return nil,'SCORE_NOT_READY' end
    end
    for index=1,count do
        local row=snapshot.candidates[index]
        if not row then return nil,'SPARSE_CANDIDATES' end
        if not excluded[row.resource] and row.score>0 and (not best or row.score>best.score) then
            best=row
        end
    end
    if best then
        return {kind='retarget',target=U.ref(best.ref)},'ALLOWED_CANDIDATE'
    end
    return {kind='search',clear_selection=selected~=nil},'NO_ALLOWED_CANDIDATE'
end
return M
