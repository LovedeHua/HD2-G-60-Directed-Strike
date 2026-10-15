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
-- ★★★ 2026-10-14（用户要求）：**拆表** —— `marked_allowed` 不再与 `excluded` 共用同一集合 ★★★
--
--   用户的远距离追踪要求：「只增加虫洞、构筑、巨型构筑、尖啸巢、孢子喷涌虫、
--     落地穿梭舰这几个，其他的就不弄远距离追踪了」。
--
--   ⚠⚠ 为什么**必须拆**（这是一个**静默回归**的根因，2026-10-10 引入、主支 2026-10-13 才发现）：
--     共用一张表 ⇒ "引擎自选要清掉" 与 "玩家点名要放行" **只能同真同假**，
--     于是**无法表达**"别清它、但玩家点名要接管"这一类目标。
--     实机后果（主支查出来的思路，本工程同理）：
--       · 飞船 / 构筑者 / 塔类都**不在** `enemy_faction` 里
--         ⇒ 走 priority 的**通用路**时被 `NOT_ENEMY_RESOURCE` 拒
--       · 它们又没进那张表 ⇒ `marked_allowed` 也是 false ⇒ **永远拿不到 `old.lock`**
--       · 而没有锁就没有航路 ⇒ "远距离追踪"根本无从谈起。
--     ⚠ 本工程此前**没有** `marked_allowed` 这个独立表（`M.marked_allowed` 直接
--       转发 `excluded`）⇒ 那 6 类里凡是不在 `structure_profiles` 的都不可能被接管。
--
--   ★ 那 6 类**已经**在 `structure_profiles` 里（走白名单分支，**绕过**敌阵营门槛）
--     ⇒ 严格来说它们不依赖本表。保留这几条的理由：
--     `marked_allowed` 还参与 priority 的**通用复核**（`generic_validate`）——
--     若某类目标因某种原因落到通用路（例如结构表被菜单关掉、或用户点名了一个
--     未被结构表识别的变体），这张表就是它唯一的放行口。
--     与 `structure_profiles` **同源**地放行，失败方向安全（放行的都是用户明确
--     要求追踪的目标，不存在"误炸友方"的风险 —— 友方资源一个都不在表里）。
--
--   ⚠ 语义边界（**必须分清**，否则会误炸）：
--     · `excluded(r)`       = 引擎**自己选中** r 时要清掉（**不改动**：仍只有那两项）
--     · `marked_allowed(r)` = 玩家**点名标记** r 时反而要接管
--   **不**参与 selection_veto / take_gate / 兜底 veto 的"引擎自选 ⇒ 清掉"判据
--   —— 那三处继续只看 `M.excluded`，行为**完全不变**。
--
--   ⚠ **绝不得加入**：鹈鹕 MK2（玩家自己的撤离机）或任何友方资产。
--     测试 `marked_allowed_excludes_friendly_assets` 与
--     `veto_list_excludes_friendly_pelican` 钉着这一点。
local marked_allowed = {
    -- 原有的两项（与 excluded 内容相同）—— 保持原行为不变
    ['db90077e76faa025'] = true,   -- 机器人运输船 cyborg_dropship
    ['74e2285c01da4f71'] = true,   -- 光能族增援飞船 illuminate_dropship
    -- ★ 2026-10-14 用户点名的 6 类（与 `compat/structure_profiles.lua` **同源**）
    --   ⚠ 营地穿梭舰**只进本表、不进 `excluded`**：用户 2026-10-01 明确
    --     "玩家会主动标记去炸的目标，不能过滤"。拆表之后这才表达得出来。
    -- ★ 2026-10-14：**落地的机器人运输舰**（与结构表**同源**放行）。
    --   实机证据：标记它时通用路报 `NOT_ENEMY_RESOURCE`（它不是 AiEnemy）
    --   ⇒ 结构表分支绕过那道门槛；本表是它落到通用路时的**唯一**放行口。
    --   ⚠ 与 `excluded` 里那两项**无关**：那是「引擎自选要清掉」（飞行运输船
    --     `db90077e76faa025`），而这是玩家点名的**落地**目标（另一个资源）。
    ['d84ffc32a6e640a8'] = true,   -- 落地的机器人运输舰 cyborg_landed_dropship
    ['b3c9cdb79dc17937'] = true,   -- 营地穿梭舰 Warp Ship Landed
    ['2ad2e055dad21f6e'] = true,   -- 入侵穿梭舰 Warp Ship Invasion
    -- 构筑者 5 个变体
    ['5158e582fbeb26bd'] = true,   -- cyborg_spawner_factory_conscript_airborne
    ['22cc0ed4ceb9cb68'] = true,   -- ..._assault
    ['f0b98fb953b13960'] = true,   -- ..._base
    ['4fb8eb356ac8553e'] = true,   -- ..._standard
    ['a1a7b76b29088843'] = true,   -- ..._phalanx
    ['4232ee48e2cfd24e'] = true,   -- 巨型构筑者 cyborg_colony_spawner_base
    -- 尖啸巢 / 孢子喷涌虫（塔类，走 structure_profiles 的 structure_tower 分支）
    ['095686275a113614'] = true,   -- 尖啸者巢 Shrieker Nest
    ['aa28caf964d05500'] = true,   -- 孢子喷涌虫 Spore Spewer
    ['e02e6bd34b606a85'] = true,   -- 孢子喷涌虫（大型）Spore Spewer Large
    -- 虫洞（用户点名的 6 类之一）。
    --   ⚠ 虫洞本来就走 `structure_profiles` 白名单分支、**不需要**这条 ——
    --     加它只为"名单与用户点名的 6 类一一对应"（否则看这张表的人会以为
    --     少了虫洞）。这里**只列基线首条**（其余 15 条是同一模型的摆放变体，
    --     逐条抄进来只是噪音；判据仍是 `structure_profiles` 那张权威表）。
    ['8901f188db366b4b'] = true,   -- 虫洞 bug hole（基线）
    -- ★★★ 2026-10-14（用户最终方案「标记的泰坦走虫洞那条远距离追踪路」）★★★
    --   为什么需要这两条：`marked_allowed` 决定"玩家点名标记它时 priority 要不要接管"，
    --   而泰坦链的触发条件是**引擎自己的选中**。泰坦若拿不到 `old.lock`，
    --   我们就没有任何路径把它驱动到泰坦附近 ⇒ 手雷跟着引擎的选中（最近的敌人）。
    --   ⇒ 让泰坦**走与虫洞同一套**（priority 锁 + `max_takeover_distance` 滑块）。
    --   ⚠ 与 v0.2.29/v0.2.31 拆掉的**是同一件事** —— 但那时缺了"到 10 m 放手"：
    --     接管到底 = 在泰坦链前面插第二个驱动者 ⇒ 爆点坏。
    --     现在 `titan_approach` 会在 `titan_approach_dist`（默认 10 m）**放开接管**
    --     ⇒ 链仍是**最后的唯一引导者**（实机已验证：`titan_started=1`
    --     + `titan_blast belly_dz=-2.62`）。
    --   ⚠ 只列**基线 + 幽暗变体**两条：蟑龙（960b48a421a3faaa）走它自己的
    --     认领路（weakpoint profile，`kind="thorax"`），不在用户点名的范围里，
    --     加进来会改变蟑龙的行为 —— **不擅自扩张**。
    ['9e2e17f2ccccafdd'] = true,   -- 吐酸泰坦 cha_strider
    ['ef04cb84d097a497'] = true,   -- 幽暗变体 cha_strider_gloom（孢子泰坦）
}
function M.marked_allowed(resource) return marked_allowed[resource] == true end
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
