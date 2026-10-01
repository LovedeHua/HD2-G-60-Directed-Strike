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
-- ★★ 实机修正（2026-09-29 晚）：**我第一版过滤错了哈希** ★★
--
--   第一版只放了 98152772a72f7838（社区表「哈希表-整合」第 112 行标为
--   "运输船 | Dropship"，用户给的十进制 ID 也确实是它）。
--   但实机日志直接否证了这个选择：
--       enemy_selection;entity=933;resource=db90077e76faa025;vetoed=false
--   ⇒ 引擎真正分配给 G-60 的"运输船"是 **db90077e76faa025**，
--     而 98152772a72f7838 **一次都没出现过**（它连游戏资源路径都反查不到）。
--   ⇒ 表现就是用户看到的"运输船没有被过滤"：判据资源从头到尾没被选中过。
--
--   教训：**"名字对得上"不等于"就是那个哈希"**。社区表说它是运输船、
--   实体表里也确实存在，但两者都不足以证明"引擎会把 G-60 指向它"。
--   最终判据只能是**实机日志里真的出现过的那个哈希**。
--
--   逐条证据（每条都必须能追到来源）：
--     · db90077e76faa025 —— ★ 实机日志证据（上面那行）
--         游戏路径 = content/fac_cyborgs/vehicles/cyborg_dropship/cyborg_dropship
--         ⇒ 机器人运输船本体。
--     · 74e2285c01da4f71 —— ★ 实机日志证据（2026-10-01，光能族战线）
--         `enemy_selection;entity=1241;resource=74e2285c01da4f71;vetoed=false`
--         游戏路径 = content/fac_illuminate/vehicles/illuminate_dropship
--         社区表名 = 增援穿梭舰 / Warp Ship ⇒ **光能族的增援飞船**。
--         用户 2026-10-01 明确要求："光能族的飞船也要过滤（注意是**增援**的飞船）"。
--
--   ★★★ 这里只排除**增援**那一艘，**不是**"光能族的飞船全都排除" ★★★
--     · `b3c9cdb79dc17937`（营地的穿梭舰 / Warp Ship Landed）**必须保留在表外** ——
--       是玩家**会主动标记去炸**的目标（2026-10-01 实机日志：同一局里
--       `structure_mark … ACCEPTED` 6 次 + `priority_locked` **14** 次）。
--       用户原话补充："注意是**增援**的飞船" ⇒ 停落的营地穿梭舰不在过滤范围。
--       测试里 `veto_list_excludes_landed_warp_ship` 钉住这一点。
--     · 同理 `2ad2e055dad21f6e`（入侵的穿梭舰 / Warp Ship Invasion）与
--       `01fe503dcd17847b`（营地的穿梭舰，另一个 id）**都没加** ——
--       它们**从未在实机日志里被引擎选中过**，加进去没有任何证据支撑，
--       而且 `01fe…` 与 b3c9… 同名（营地的穿梭舰）⇒ 加了可能误伤玩家想炸的那艘。
--       **判据永远只能是实机日志里真的出现过的那个哈希**（见下面 98152772a72f7838 的教训）。
--
--   ⚠️ **98152772a72f7838 已从本表去除**（2026-09-29，用户决定）
--       它 = 社区表「哈希表-整合」第 112 行的"运输船 | Dropship"，
--       游戏资源路径反查不到，实机日志里**从未被引擎选中过**。
--       用户判断那大概是**停落在地面上的运输船**（不再起飞投放兵力的那种），
--       所以 G-60 本来就不会去锁它 ⇒ 排除它没有意义，去掉。
--       ⇒ **后来者请注意：不要再把它加回来。** 除非日志里真的出现
--         `enemy_selection;...;resource=98152772a72f7838`。
--
--   ⚠️ 明确**不得**加入本表的：`7b0f8449ca9d2da0`
--       = content/fac_helldivers/vehicles/shuttle_gunship/shuttle_dropship
--       = 鹈鹕 MK2（**玩家自己的撤离机**）。把友军撤离机也否决掉是严重错误，
--       测试里有 `veto_list_excludes_friendly_pelican` 钉住这一点。
--   ⚠️ 同类但**未**加入（用户决定）：
--       `b3c9cdb79dc17937` = 营地的穿梭舰 / Warp Ship Landed
--         —— 玩家会主动标记去炸的目标，**不能**过滤（2026-10-01 用户："是增援的飞船"）
--       `01fe503dcd17847b` = 营地的穿梭舰（另一个 id）、
--       `2ad2e055dad21f6e` = 入侵的穿梭舰 / Warp Ship Invasion
--         —— 日志里从未被引擎选中过，无证据；且 `01fe…` 与 b3c9… 同名 ⇒ 加了可能误伤。
--       `2ad2e055dad21f6e` 若将来在日志里出现且确实是**增援**用船，再加。
--
--   ⇒ 仍保留 enemy_selection 只读日志（实机确认触发时机）与
--     enemy_veto_enabled 开关（一键回退）。
local excluded = {
    ['db90077e76faa025'] = true,   -- ★ 机器人运输船 cyborg_dropship（实机日志证据）
    ['74e2285c01da4f71'] = true,   -- ★ 光能族增援飞船 illuminate_dropship / 增援穿梭舰（实机日志证据）
}
function M.excluded(resource) return excluded[resource] == true end
-- ★★★ 2026-10-01（用户要求）：同一张表的**反方向**用途 ★★★
--
--   `M.excluded(r)`       = 引擎**自己选中** r 时要清掉（不让 G-60 去追载具）
--   `M.marked_allowed(r)` = 玩家**点名标记** r 时反而要接管（绕过引擎索敌的否决）
--
--   为什么是"两个函数共用一张表"，而不是"取反"或"两张表"：
--     · 方向相反，函数名必须自解释 —— 读代码的人不能只看表名去猜方向
--       （本仓库因为"同一判据两处副本"出过事故，所以**共用同一个集合**，
--        将来若真的要解耦，再拆成两张表 + 各配断言）。
--     · 两张内容相同的表必然漂移。
--
--   为什么"引擎要排除的"正好就是"玩家点名要放的"：
--     这两项都是**载具**（机器人运输船 / 光能族增援飞船）。
--     引擎索敌（game.dll+0x8858a0）不把载具当合法锁定目标 ⇒ 返回 false ⇒
--       · 引擎"误选"它们时我们要清（排除表）；
--       · 玩家点名它们时，priority 的通用复核（原本拿同一个 target_valid 当
--         硬门槛）会**误杀**，标记了也不飞过去炸。
--     ⇒ 本函数就是给"玩家点名"这条例外开的门。
--
--   ⚠ **只对玩家标记路径生效**：
--       · structure_ping 的认领判定（runtime 的 generic_claimed）
--       · priority 的通用复核（native_priority 的 generic_validate）
--     **不**参与 selection_veto / take_gate / 兜底 veto 的"引擎自选 ⇒ 清掉"判据
--     —— 那三处继续只看 `M.excluded`，行为完全不变。
function M.marked_allowed(resource) return excluded[resource] == true end
-- 只读：把排除表如实列出来（**排序后**，保证启动日志稳定可比）。
--   存在的意义：启动日志的 `enemy_veto_resources=` 必须由这里生成，
--   而不是在 entry 里再抄一份哈希 —— 2026-09-29 就是因为日志里硬编码了
--   旧哈希，实机核对时把我带偏过一次（日志说 9815…，实现里其实换了）。
function M.excluded_resources()
    local out={}
    for resource in pairs(excluded) do out[#out+1]=resource end
    table.sort(out)
    return out
end
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
