-- Copies an observed eligible candidate through the original setter only.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Candidates=require('g60.native_candidates')
local Policy=require('g60.target_policy')
local Filter=require('g60.small_filter')
local ArrivalPolicy=require('g60.arrival_policy')
local Context=require('g60.titan_context')
local Explosive=require('g60.explosive_context')
-- ★ 故障域隔离（2026-09-27 实机事故的直接修复）★ 判定规则见 g60.priority_faults：
-- 竞争态（setter 回读不符）→ 只放弃**这一颗**实体（返回 kind='quarantine'，
-- 由 runtime 把该 G-60 交回引擎并停止再写），**不动全局 disabled**；
-- 其余（结构性版本漂移）→ 仍然永久停手。
-- 这里不写 `local Faults=require(...)`：build.py 会把 require 替换成同一个
-- chunk 别名，写成同名 local 就成了 `local Faults=Faults`，可读性差且易被误读成自引用。
local Faults=require('g60.priority_faults')
local competitive=Faults.competitive
-- 只读几何诊断（2026-09-28）：零 ffi，runtime 通过它拿接管时机画像
local Geometry=require('g60.geometry')
-- 早期 state（2/3）的引爆圈。**刻意保守**，因为我们不知道 G-60 在早期
-- 到底飞在哪（两轮实验已证实它不导航，位置由引擎的起飞流程决定）。
-- 先用 early_probe 把真实距离打出来，再按实测标定 —— 不再凭猜测放大。
local EARLY_DETONATE_RADIUS=3.2
local EARLY_DETONATE_DEPTH=2.0
local M={}
-- 每次首次锁定时记下的"接管时机画像"（horiz/dz/剩余寿命），
-- 供 runtime 在 arrival_retired（失败终点）时引用，让成功/失败可直接对比。
M.probe_by_entity={}
-- 白名单拒绝的去重集合：同一个 target 只打首条。
-- 不去重会逐帧刷屏 —— 记忆里 2026-09-27 记过"逐条刷屏会把真正的一次性错误埋掉"。
M.rejected_targets={}
-- 让位事件（单位锁 → 新近结构标记）的去重集合，理由同上：
-- 让位之后如果结构标记这一帧**拿不到**（被别的 G-60 预约 / 超距），
-- 下一帧会再次让位 ⇒ 不按 (G-60, 结构) 去重就会逐帧刷屏。
M.yield_reported={}
local setter=ffi.typeof('void (*)(void **, const void *)')
local valid=ffi.typeof('bool (*)(void *, uint32_t, const void *)')
-- ★ 故障域隔离（2026-09-27 实机事故的直接修复）★ 判定规则见 g60.priority_faults：
-- 竞争态（setter 回读不符）→ 只放弃**这一颗**实体（返回 kind='quarantine'，
-- 由 runtime 把该 G-60 交回引擎并停止再写），**不动全局 disabled**；
-- 其余（结构性版本漂移）→ 仍然永久停手。
--
-- 判定必须从 g60.priority_faults 走（tests/test_priority_fault_isolation.py 真跑它），
-- 不能就地硬编码表 —— 上游那种"无差别永久停手"就是没有这一步。
function M.new(env)
    local disabled,busy=false,false
    -- early_probe 的去重状态：只在"水平距离跨过 0.5m 档位"或首次/状态翻转时打。
    -- 之前逐帧刷屏（structure_ping_unavailable 几百条）直接导致过误诊，别重蹈覆辙。
    local probe_bucket={}
    local api={}
    function api:disabled() return disabled end
    function api:step(scope,previous,mark,blocked,available,structure_mark)
        if disabled or busy then return nil,'PRIORITY_DISABLED' end
        if ffi.os~='Windows' or not ffi.abi('64bit') then return nil,'PRIORITY_ABI_UNSUPPORTED' end
        busy=true;local mutated=false;local early_state=false
        local ok,result=pcall(function()
            assert(scope.experimental and not scope.native_lifetime_verified
                and scope.reference_is_observation_key,'experimental priority scope required')
            local c=scope.prepared;local record=c.record_bytes
            assert(c.ownership.local_ownership_observed and scope.validate(),'priority scope unavailable')
            -- ★ 末项 `L.u32(record,8)==4` 就是 state==4 的硬门槛。
            --   state-3 实验打开时放宽到 3（**只用于设置目标**，不用于航点/引爆）；
            --   飞行计时器仍由下面的 check() 每次校验，一旦被动立刻失败。
            -- 早期接管：state 2/3 也放行（只用于**设置目标**，不用于航点/引爆）。
            --   state 1 是刚出膛那几帧，movement 还没建立，不碰。
            --   飞行计时器仍由 check() 每次校验，一旦被动立刻失败。
            assert(L.hex64(c.identity_bytes,0)=='8e325c933e55bf62' and L.u32(record,0)==4
                and (L.u32(record,8)==4 or (env.allow_state3
                     and (L.u32(record,8)==2 or L.u32(record,8)==3)))
                and L.u32(record,0x68)==L.u32(c.identity_bytes,8),'priority source mismatch')
            assert(ffi.istype(setter,scope.calls.clear) and ffi.istype(valid,scope.calls.target_valid),'priority ABI mismatch')
            local d=Data.new(scope.read,env.base,env.exe)
            local blocked_now=blocked and ArrivalPolicy.elapsed(c.time_hex,c.flight_start)/1000000<blocked.until_seconds
            local own=Data.vector(c.own_position_bytes,0)
            -- ★ 裁剪 K：`target_valid` 从"硬否决"降级为"软信号"
            --
            -- ★★ 定义位置很关键 ★★：本块必须在 `eligible` **之前**。
            -- Lua 的 upvalue 是**编译期**绑定的 —— 若把 `readonly_alive` 写在
            -- `eligible` 之后，`eligible` 体内的引用会解析成**全局变量**(nil)，
            -- 一旦 eligible 被调用就 `attempt to call a nil value`。
            -- (2026-09-27 实机事故: 我把它写在 eligible 之后, 结果 eligible 必崩,
            --  表现为 priority_locked 一次都不出现。)
            --
            -- `scope.calls.target_valid`（game.dll+0x8858a0）是**游戏索敌系统的一部分**，
            -- 它回答的是"引擎能不能把这个实体当作锁定目标"。而虫巢**没有 HealthComponent**
            -- —— 正是这一点让引擎的原生索敌排除它们（2026-09-24 我花三天证否了
            -- "让虫巢成为合法目标"那条路，结论就是判据写在 game.dll 里）。
            --
            -- 本 mod 的核心恰恰是**绕过**索敌（改导航目的地 + 直接调 explode），
            -- 却又拿索敌系统的函数去否决虫洞 —— 自相矛盾。
            -- 实机证据：target=511（bug_spawner_stalker，追踪虫巢）在 structure_mark
            -- 里 ACCEPTED 后**立刻** NATIVE_TARGET_INVALID，从未进入锁定；
            -- 而它与刚被引爆的 512 相距甚远（512 爆点 116,-183；513 爆点 -147,10），
            -- 不是连锁殉爆。
            --
            -- 现在：**只读校验才是硬门槛**（下面 79–87 行已经全过：实体可读 /
            -- identity 未变 / unit 未变 / pose.validate() / 距离 < 200m）；
            -- target_valid 只当软信号 —— 它说 false 时再做一次**独立的只读复核**，
            -- 复核通过就继续接管（并留诊断），复核也失败才真的放弃。
            -- 这样既不会误杀"引擎不认但实际存在"的虫巢，真正已死的实体仍被拒绝。
            local function readonly_alive(id, identity)
                local ok, again = pcall(d.entity, id)
                if not ok or not again then return false, 'ENTITY_GONE' end
                if again.identity ~= identity then return false, 'IDENTITY_CHANGED' end
                local okp = pcall(d.position, again)
                if not okp then return false, 'POSITION_UNREADABLE' end
                return true, 'ALIVE_BY_READ'
            end
            local function check_alive(e, tag)
                local alive = scope.calls.target_valid(nil, e.id,
                    ffi.cast('const void *', e.address))
                if alive then return true end
                local ok, why = readonly_alive(e.id, e.identity)
                if ok then
                    if env.emit then env.emit('structure_target_soft_invalid;target='..e.id
                        ..';resource='..e.resource..';native=false;readonly='..why
                        ..';context='..tag) end
                elseif env.emit then env.emit('structure_unavailable;target='..e.id
                    ..';resource='..e.resource..';detail='..why..';context='..tag) end
                return ok
            end
            local function eligible(row,prior)
                if not row or Filter.excluded(row.entity.resource)
                    or (not row.marked_structure and env.target_allowed and not env.target_allowed(row.entity.resource)) then return false end
                local e=row.entity
                if available and not available(e.identity) then return false end
                if blocked_now and e.identity==blocked.identity then return false end
                if prior and e.identity~=prior.identity then return false end
                local ok_unit,unit=pcall(d.unit,e)
                if not ok_unit or (prior and unit~=prior.unit) then return false end
                local ok_pos,p=pcall(d.position,e)
                if not ok_pos then return false end
                local distance=0;for i=1,3 do distance=distance+(p[i]-own[i])^2 end
                if distance>=40000 then return false end
                assert(scope.validate() and d.validate(),'priority target observation changed')
                local alive=scope.calls.target_valid(nil,e.id,ffi.cast('const void *',e.address))
                assert(scope.validate() and d.validate(),'priority target changed during validation')
                if not alive then
                    -- ★ 裁剪 K 同理：虫洞没有 HealthComponent，原生 target_valid（索敌系统
                    -- 的函数）可能对"实际存在但引擎不认"的巢返回 false。只读复核通过就保留。
                    local ok, why = readonly_alive(e.id, e.identity)
                    if not ok then
                        if env.forget_mark then env.forget_mark(e.identity) end
                        if env.emit then env.emit('structure_unavailable;target='..e.id
                            ..';resource='..e.resource..';detail='..why..';context=ELIGIBLE') end
                        return false
                    end
                    if env.emit then env.emit('structure_target_soft_invalid;target='..e.id
                        ..';resource='..e.resource..';native=false;readonly='..why
                        ..';context=ELIGIBLE') end
                end
                row.unit=unit;return true
            end
            -- ★★★ 通用目标的统一复核（2026-09-30）★★★
            --
            -- 通用目标有**两个**进入点：
            --   ① 新标记    —— structure_mark 分支（本文件下方）
            --   ② sticky 复用 —— previous.generic（本轮新增）
            -- 两条路必须用**同一套**判据。本文件 334-338 行记过同类事故
            -- （两个 sticky 分支只给一份加白名单复核 ⇒ 越界溜进来），
            -- 所以这里抽成单一实现，两处都调它，杜绝"只改一份副本"。
            --
            -- 与虫洞路径的**刻意差别**：
            --   · `target_valid` 是**硬门槛**（false 直接拒）。通用目标不需要绕过
            --     索敌，正好用它排除友方（引擎索敌不锁友方）。虫洞那边因为没有
            --     HealthComponent 被它判 false，只能降级成软信号 —— 两者不同源。
            --   ⚠ **2026-10-01 唯一的例外**：`small_filter.marked_allowed` 里那两项
            --     （机器人运输船 / 光能族增援飞船）是**载具**，引擎索敌对它们同样返回
            --     false —— 但用户要求"**标记了就要飞过去炸**"（引擎自己选中时仍要清掉，
            --     两件事不冲突）。⇒ 只对这两个资源把硬门槛降级为软信号（+只读复核），
            --     其余 false 仍然直接拒 ⇒ "标记友方信标球 / 鹈鹕 / 平民"依旧被挡住。
            --   · **不查虫洞白名单**（env.structure_profiles）。通用目标本来就不在
            --     里面；旧 sticky 只认白名单 ⇒ 通用锁每轮都被判"不在白名单"而丢弃，
            --     实机表现为 66 次 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST`。
            -- 返回：row（成功）/ nil + detail（失败原因，用于日志与 diagnostic）。
            local function generic_validate(e)
                if not e then return nil,'ENTITY_GONE' end
                -- ★★ 预约复查（2026-10-03，实机 `frame_error;target already reserved`）★★
                --
                -- 事故：`target_reservations.claim` 里
                --     assert(targets[key]==nil or targets[key]==owner,'target already reserved')
                -- 被触发一次。但 `available()` 门控**只接在两条路径上**
                --   · `eligible`（第 127 行，虫洞 sticky 与虫洞新标记都走它）
                --   · 第 373 行（虫洞白名单分支）
                -- 而**通用目标**（标记的任意单位：运输船 / 通缉目标 / 中小型虫…）
                -- 走的是本函数，三条入口（新标记 / 通用 sticky / 让位回退）**一条都没查**。
                -- 于是 runtime 无条件 `reservations:claim(...)` ⇒ 同一个目标被两颗 G-60
                -- 同时预约 ⇒ assert。
                --
                -- 后果是 **fail-closed**（不会真的双预约），但 `frame_error` 会中止当帧
                -- 剩余处理（整个 tick 体被 pcall 包着）⇒ 排在后面的 G-60 被跳过一帧。
                --
                -- ⇒ 修法就是在**唯一**的通用复核里补这一条：三条入口一次性覆盖
                --   （这正是本函数存在的意义 —— 抽成单一实现，杜绝"只改一份副本"，
                --     同类事故在 2026-09-30 已经因为"两个 sticky 分支只给一份加白名单"发生过）。
                -- ⚠ 顺序：放在 `target_valid` 查询**之前** —— 它是纯 Lua 表查找，零内存读；
                --   被别 G-60 预约的目标不值得再为它花一次原生调用。
                -- ⚠ 同 owner 幂等：`available` 对"自己已持有"返回 true ⇒ sticky 复用不受影响。
                if available and not available(e.identity) then return nil,'TARGET_RESERVED' end
                local ok_valid,valid_now=pcall(function()
                    return scope.calls.target_valid(nil,e.id,
                        ffi.cast('const void *',e.address))
                end)
                if not ok_valid then return nil,'TARGET_VALID_QUERY_FAILED' end
                if not valid_now then
                    -- ★★★ 2026-10-01（用户要求）：玩家**点名标记**运输船 / 光能族增援飞船时，
                    --   这条硬门槛必须让路 —— 否则"标记了也不会飞过去炸"。
                    --
                    --   为什么它们会是 false：这两项是**载具**，引擎索敌
                    --   （game.dll+0x8858a0）不把载具当合法锁定目标
                    --   （与虫洞没有 HealthComponent 同类）。
                    --   而本 mod 的引爆**本来就不依赖索敌** —— 自己算 aim 点、
                    --   自己调 explode（见 native_arrival）。所以这个 false 在本场景
                    --   是**障碍**而不是判据 —— 与虫洞路径（裁剪 K）同理。
                    --
                    --   ⚠ 只对 `small_filter.marked_allowed` 里的资源放开（当前恰好两项）。
                    --     其余 false **仍然直接拒** ⇒ "标记友方信标球 / 鹈鹕 / 平民"
                    --     依旧被挡住（它们的索敌结果也是 false）。
                    --   ⚠ 放行后仍要求下面的只读复核（readonly_alive）通过，
                    --     真正已消失的实体照样被拒。
                    if not Filter.marked_allowed(e.resource) then return nil,'NOT_VALID_TARGET' end
                    if env.emit then env.emit('generic_native_invalid_allowed;target='..e.id
                        ..';resource='..e.resource..';context=GENERIC') end
                end
                local ok_unit,unit=pcall(d.unit,e)
                local ok_ro,ro_why=readonly_alive(e.id,e.identity)
                if not ok_unit or not unit then return nil,'UNIT_MISSING' end
                if not ok_ro then return nil,tostring(ro_why) end
                local ok_pos,p=pcall(d.position,e)
                if not ok_pos or not p then return nil,'POSITION_UNREADABLE' end
                local distance=0
                for k=1,3 do distance=distance+(p[k]-own[k])^2 end
                if distance>=40000 then return nil,'OUT_OF_RANGE' end
                local raw=ffi.new('uint8_t[80]',record:sub(0x19,0x68))
                ffi.cast('uint32_t *',raw)[0]=e.id
                return {entity=e,raw=ffi.string(raw,80),score=1,unit=unit,
                    marked_structure=true,generic=true,point=p}
            end
            local chosen,reason,mark_candidate,chosen_mark_index
            -- An explicit structure mark may interrupt an existing enemy lock.
            -- Never discover structures from the automatic candidate list.
            --
            -- ★ 裁剪 I（实机"有的虫洞标记后不会飞过去炸"的真凶）★
            -- 上游注释写的是"structure mark 可以打断已有锁定"，但代码**没有区分**
            -- previous 是「敌人锁」还是「已在飞行中的虫洞锁」—— 只要来了新标记就抢占。
            -- 实机日志的三条铁证（同一颗 G-60 服务多个 target）：
            --     #1083: 锁定562 -> 锁定559            (562 永久报废)
            --     #1107: 锁定562 -> 锁定564 -> 炸564
            --     #1116: 锁定567 -> 锁定561 -> 炸561
            -- G-60 飞行途中被新标记劫持，前一个目标再也没人负责 ⇒ 表现为"时灵时不灵"。
            --
            -- 现在：**已经在飞向某个虫洞的 G-60 保持忠实**（sticky），
            -- 只有该虫洞确实不可用（实体消失/已爆/被摧毁）时才允许改投别的标记。
            --
            -- ★★ 优先级（2026-10-01 用户拍板）：**虫洞/构筑 > 标记单位 > 空白标记** ★★
            --
            --   裁剪 I 那条"保持忠实"是**同层**之间的规则（虫洞↔虫洞），不能回退。
            --   但跨层要按用户定的优先级让位 —— 本处补的是唯一还缺的一段：
            --   **已在飞往「标记单位」的 G-60，遇到新近的结构标记必须让位**
            --   （原来单位锁 sticky 到底，新虫洞标记会被 `if not chosen` 直接跳过，
            --    表现为"我标记了虫洞，G-60 却继续去追那个单位"）。
            --
            --   ⚠ 门槛 `structure_mark.current==true` 是**必需的**，不是保险：
            --     `structure_mark` 来自 ping_memory，UI 标记过期后它仍在记忆里；
            --     不加门槛就会变成"一个很久以前标记的虫洞，在记忆存续期内反复夺走
            --     之后每一颗 G-60" —— 与点目标那轮踩过的「旧结构标记把整个能力
            --     挡死」是同一种事故。`current` = 本帧 ping 环里**确实还看得到它**
            --     （UI 的 8 秒窗口内），而 native_ping 在观测失败的那一帧会把
            --     `current` 翻成 false ⇒ 这个信号不会陈旧。
            --   ⚠ 单位→单位、虫洞→虫洞 仍然不抢（同层保持忠实）。
            local fresh_structure=structure_mark~=nil and structure_mark.current==true
                and env.structure_profiles~=nil
                and env.structure_profiles[structure_mark.resource]~=nil
            local yielded_unit
            if previous and previous.marked_structure then
                local e=d.entity(previous.id)
                if previous.generic then
                    -- ★ 通用目标的 sticky（2026-09-30）★
                    -- 与虫洞走**不同**的复核：通用目标不在虫洞白名单里，
                    -- 旧逻辑每轮都把它判成 RESOURCE_NOT_IN_WHITELIST 而丢锁
                    -- （实机 66 次 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST`），
                    -- 表现为"通用目标不忠实 + 每轮重锁"。
                    -- 现在走 generic_validate —— 与新标记路径**同一套**判据，
                    -- 既保住 id 复用 / 友方 / 死亡复核，又让通用锁真正 sticky。
                    --
                    -- ★ 例外：出现**新近的结构标记** ⇒ 让位（见上面 fresh_structure）★
                    --   注意这里**不丢锁**：真正去拿结构的是下面的 structure_mark
                    --   分支；万一它拿不到（超距 / 不可用 / 已被别的 G-60 预约 /
                    --   实体读不到），末尾会回退到这个单位锁继续驱动。
                    --   直接在这里放弃会让 G-60 当场释放、白飞一趟。
                    if fresh_structure then
                        yielded_unit=previous
                        local yk=L.u32(c.identity_bytes,8)..'|'..structure_mark.id
                        if env.emit and not M.yield_reported[yk] then
                            M.yield_reported[yk]=true
                            env.emit('unit_lock_yielded;entity='..tostring(L.u32(c.identity_bytes,8))
                                ..';target='..tostring(previous.id)
                                ..';to='..tostring(structure_mark.id)
                                ..';resource='..tostring(structure_mark.resource)
                                ..';reason=FRESH_STRUCTURE_PRIORITY')
                        end
                    else
                        local row,detail=generic_validate(e)
                        if row then chosen,reason=row,'LOCKED'
                        elseif env.emit then
                            env.emit('structure_lock_lost;target='..tostring(previous.id)
                                ..';detail='..tostring(detail)..';generic=true')
                        end
                    end
                else
                    -- ★ sticky 复用也必须过白名单 ★
                    -- 虫洞被摧毁后，实体 id 可能被引擎复用给另一个对象
                    -- （2026-09-27 发生过 id 复用导致写错目标的实机事故）。
                    -- 若只靠 previous.marked_structure 这个**历史标志**就复用，
                    -- 就可能把非虫洞当成"原目标"继续接管 ⇒ 越界。
                    -- 所以每次复用都重新核对当前实体的 resource。
                    local whitelisted=e and env.structure_profiles
                        and env.structure_profiles[e.resource]
                    local row=whitelisted and {entity=e,raw=previous.raw,score=previous.score,
                        unit=previous.unit,marked_structure=true,
                        point=previous.point,point_bytes=previous.point_bytes}
                    if row and eligible(row,previous) then chosen,reason=row,'LOCKED' end
                    if not chosen and env.emit then
                        env.emit('structure_lock_lost;target='..tostring(previous.id)
                            ..';detail='..(whitelisted
                                and 'NO_LONGER_ELIGIBLE'
                                or (e and 'RESOURCE_NOT_IN_WHITELIST' or 'ENTITY_GONE')))
                    end
                end
            end
            if not chosen and structure_mark and env.structure_profiles then
                local good,row=pcall(function()
                    local e=d.entity(structure_mark.id)
                    local profile=e and env.structure_profiles[e.resource]
                    -- ★ 显式白名单：profile 表里没有的对象**绝不接管**，交回原生。
                    --
                    --   上游这里只是 `if not profile then return end`（第 176 行），
                    --   行为上已经是"不接管"，但**完全静默** ——
                    --   日志里既看不到拒绝了谁，也看不到为什么。
                    --   实机 13:50 的日志里 5 个被标记的资源哈希全部命中白名单，
                    --   零条拒绝记录，所以我无法证明"尖啸巢穴确实没被接管"，
                    --   只能证明"没看到它被接管"。
                    --
                    --   用户要求：有生命值的尖啸巢穴这类**不要接管，交给游戏原生**。
                    --   profile 表当前 17 项全部是 kind="structure_hole"（虫洞），
                    --   尖啸巢穴不在表内 ⇒ 已满足要求。
                    --   这里把原因打出来，让"未接管"变成可观测事实而非推测。
                    if not profile then
                        -- ★ 泰坦标记不归 priority 管（2026-09-29）★
                        -- 泰坦的接管由 titan 段负责（它需要引擎 selection + titan_route
                        -- 那套为体型标定的几何），priority 的"设目标点"路径对泰坦不适用。
                        -- ⇒ **静默**跳过，不打 NOT_IN_WHITELIST ——
                        --   否则日志会出现"不支持"的误导信息。
                        --   实机就是被这类误导性日志带偏过（我看到 RESOURCE_NOT_SUPPORTED
                        --   以为是"引擎没选中"，其实是我们自己拒的）。
                        -- 放行与否的唯一判定在 runtime 的 claim_profile，这里只做分流。
                        if env.titan_enabled~=false and env.titan_profile
                            and e and e.resource==env.titan_profile.resource then
                            return
                        end
                        -- ★★★ 通用标记目标接管（2026-09-30，用户要求）★★★
                        --
                        -- 除 虫洞/泰坦/蟑龙/泰坦变体（claim_profile 的专门路径）外，
                        -- 玩家标记的**任意目标**也接管：强制 G-60 飞向它并引爆。
                        --
                        -- ▸ **友方靠硬门槛排除**：`calls.target_valid`
                        --   （game.dll+0x8858a0 = 引擎索敌系统的"能不能把它当锁定目标"）。
                        --   引擎索敌不锁友方 ⇒ 返回 false ⇒ 这里直接不收。
                        --   ⚠ 这与**虫洞路径相反**：虫洞因为没有 HealthComponent 被它判 false，
                        --     所以虫洞那边把它降级为**软信号** + 只读复核；
                        --     通用目标不需要绕过索敌，正好用它当硬门槛。
                        -- ▸ 引爆位置**交给引擎**（arrival 段在 goal=nil 时调 calls.aim），
                        --   这里只提供点用于距离判定与 setter。
                        if env.generic_takeover_enabled~=false and e then
                            -- 走统一复核（与 sticky 的通用分支同一实现）。
                            local grow,gdetail=generic_validate(e)
                            if grow then return grow end
                            if env.emit and not M.rejected_targets[structure_mark.id] then
                                M.rejected_targets[structure_mark.id]=true
                                env.emit('generic_rejected;target='..tostring(structure_mark.id)
                                    ..';resource='..tostring(e.resource)..';detail='..tostring(gdetail))
                            end
                        end
                        if env.emit and not M.rejected_targets[structure_mark.id] then
                            M.rejected_targets[structure_mark.id]=true
                            env.emit('structure_not_taken_over;target='
                                ..tostring(structure_mark.id)
                                ..';resource='..tostring(e and e.resource)
                                ..';reason=NOT_IN_WHITELIST')
                        end
                        return
                    end
                    if e.identity~=structure_mark.identity or d.unit(e)~=structure_mark.unit then return end
                    if available and not available(e.identity) then return end
                    if blocked_now and e.identity==blocked.identity then return end
                    local pose=Context.capture(scope.read,env.base,env.exe,e.id,profile,structure_mark)
                    local distance=0;for k=1,3 do distance=distance+(pose.point[k]-own[k])^2 end
                    -- ★ 接管时机诊断（2026-09-28）★
                    -- 这个距离过去算完只用于 200m 射程检查就丢弃了，导致日志里
                    -- **看不到"我们接管时 G-60 离虫洞多远"** —— 而这恰恰是判定
                    -- 成功/失败的唯一变量（实机：32m 内成功，40m+ 静默移除）。
                    --
                    -- 记录"接管时机画像"：horiz（水平距离）/ dz（高度差）/
                    -- life_left（剩余寿命占 30s 的比例），外加双方绝对坐标。
                    -- 只记第一次锁定（reason~='LOCKED'），避免 sticky 复读刷屏。
                    --
                    -- 同时存进 M.probe_by_entity，让 runtime 在
                    -- arrival_retired（失败终点）时能引用同一份数据 ——
                    -- 那样成功与失败样本就能直接对比。
                    if reason~='LOCKED' then
                        local gap=Geometry.gap(own,pose.point)
                        local spent=ArrivalPolicy.elapsed(c.time_hex,c.flight_start)
                        -- ⚠ 这里是 ArrivalPolicy 不是 Policy！
                        --   本文件第 6 行的 `Policy` 是 g60.target_policy，
                        --   它**没有** lifetime_ticks 字段（那是 arrival_policy 的）。
                        --   我写成 Policy.lifetime_ticks 时 Lua 对 nil 做算术
                        --   ⇒ `attempt to perform arithmetic on field 'lifetime_ticks'`
                        --   ⇒ **每一帧**都抛错，被 pcall 吞成 structure_unavailable
                        --   ⇒ 标记读到了却一次都锁不上（2026-09-28 11:40 实机）。
                        local life=math.max(0,1-spent/ArrivalPolicy.lifetime_ticks)
                        local eid=L.u32(c.identity_bytes,8)
                        if gap then
                            M.probe_by_entity[eid]='h='..tostring(gap.horiz)
                                ..',dz='..tostring(gap.dz)..',life='..tostring(life)
                        end
                        if env.emit then
                            env.emit('takeover_probe;entity='..eid
                                ..';target='..tostring(e.id)
                                ..';state='..tostring(L.u32(record,8))
                                ..';horiz='..tostring(gap and gap.horiz or -1)
                                ..';dz='..tostring(gap and gap.dz or 0)
                                ..';life_left='..tostring(life)
                                ..';own='..tostring(own[1])..','..tostring(own[2])..','..tostring(own[3])
                                ..';point='..tostring(pose.point[1])..','..tostring(pose.point[2])
                                ..','..tostring(pose.point[3]))
                        end
                    end
                    if distance>=40000 then return end
                    assert(pose.validate() and d.validate() and scope.validate(),'marked structure changed')
                    -- ★ 裁剪 K：软信号校验（原生 target_valid 只是参考，以只读复核为准）
                    if not check_alive(e,'NEW_MARK') then return end
                    -- Original setter accepts position candidates. Preserve the
                    -- observed metadata and suppress proximity; the point route
                    -- will replace this temporary entity selection immediately.
                    local raw=ffi.new('uint8_t[80]',record:sub(0x19,0x68))
                    ffi.cast('uint32_t *',raw)[0]=e.id
                    return {entity=e,raw=ffi.string(raw,80),score=1,unit=structure_mark.unit,marked_structure=true,
                        point=pose.point}
                end)
                if good and row then
                    chosen,reason=row,row.generic and 'PLAYER_MARK_GENERIC' or 'PLAYER_MARK_STRUCTURE'
                elseif not good and env.emit then env.emit('structure_unavailable;detail='..tostring(row)) end
            end
            -- ★ 让位失败回退（见 fresh_structure 处）★
            --   为新近的结构标记让了位、但这一帧它**拿不到**（超距 / 不可用 /
            --   已被别的 G-60 预约 / 实体读不到）⇒ 继续驱动原来的单位锁。
            --   不写这段的后果：G-60 会走下面的 `{kind='keep',released=true}`，
            --   当场把锁还回引擎、白飞一趟，而且下一帧重新锁上又让位 ⇒ 每帧抖动。
            if not chosen and yielded_unit then
                local row,detail=generic_validate(d.entity(yielded_unit.id))
                if row then chosen,reason=row,'LOCKED'
                elseif env.emit then
                    env.emit('structure_lock_lost;target='..tostring(yielded_unit.id)
                        ..';detail='..tostring(detail)..';generic=true;yield_fallback=true')
                end
            end
            -- ★★ 敌人锁分支整段删除，理由见文件下方同名注释 ★★
            -- 原来这里还有第二个 sticky 分支（`if not chosen and previous.marked_structure`），
            -- 与上面那份逻辑重复。现已合并到上面那份，**只保留一处** ——
            -- 两处并存正是这次越界能溜进来的原因：只有一份加了白名单复核，
            -- 另一份没有，而"看起来哪个是主路径"很容易判断错。
            --
            -- ★ 裁剪(本工程只接管"标记虫洞") ★
            -- 原上游在这里用 Candidates.capture + Policy.choose 从引擎候选列表里按 rank
            -- 自动挑敌人(Bile Titan / Impaler / Spore Charger / Charger…)，把 G-60 从
            -- 引擎的原生 TargetLock 上抢过来。那是"只打指定敌人"的功能，与本工程无关，
            -- 整段删除。删除后 mod 不再改写敌人的选择，引擎原生逻辑保持不变。
            --
            -- 保留的是它上面的 structure_mark 分支：玩家标记虫洞时，仍然可以把 G-60
            -- 从当前敌人锁定上打断、优先飞去炸虫洞。
            --
            -- 副作用(预期内)：上一帧的 structure 锁若因标记过期而失配，这里不再回退到
            -- 候选列表，改为落到下面的 {kind='keep', released=…}，由 runtime 释放该锁。
            -- structure_ping 自带"标记消失后仍记住目标"的机制，正常操作下不会走到这条路。
            if not chosen then return {kind='keep',released=previous~=nil} end
            local function check()
                assert(scope.validate() and d.validate(),'priority scope changed')
                local r=scope.read(c.state_address-8,0x1f8)
                assert(r:sub(1,12)==record:sub(1,12) and r:sub(0x189,0x190)==record:sub(0x189,0x190),
                    'priority behavior or flight timer changed')
                return r
            end
            assert(check()==record,'priority source changed')
            -- ★ 早期接管 v2（2026-09-28）：点目标模式。
            --   v1（实体模式）已证伪：state 2/3 时把虫洞实体 id 写进 selection，
            --   引擎接受写入但不采纳（实机 saw4=0 持续 2000+ 帧，无 early_promoted）——
            --   因为虫洞不是合法敌人（没有 HealthComponent）。
            --   但 titan 让 G-60 飞向爆点用的是**另一种模式**（native_titan_aim:150-165）：
            --     data[0..4]  = scope.invalid_id     （无实体目标）
            --     data[4..16] = 三维坐标             （要飞向的点）
            --   点目标不需要目标实体合法 ⇒ state 2/3 可能被引擎接受。
            --   这是唯一没试过、且有技术依据的路径。
            early_state=env.allow_state3 and L.u32(record,8)~=4 and chosen.point
            if early_state then
                local data=ffi.new('uint8_t[80]')
                ffi.cast('uint32_t *',data)[0]=scope.invalid_id
                local xyz=ffi.cast('float *',data+4)
                xyz[0]=chosen.point[1];xyz[1]=chosen.point[2];xyz[2]=chosen.point[3]
                if env.fuse_profile then ffi.cast('uint32_t *',data+0x4c)[0]=0 end
                local point_bytes=ffi.string(data+4,12)
                local pair=ffi.new('void *[2]',{ffi.cast('void *',c.entity_address),ffi.cast('void *',c.state_address)})
                mutated=true;scope.calls.clear(pair,nil);check()
                mutated=true;scope.calls.clear(pair,data)
                local after=check()
                assert(L.u32(after,0x18)==scope.invalid_id and L.u32(after,0x70)==scope.invalid_id
                    and after:sub(0x1d,0x28)==point_bytes,'priority point setter mismatch')
                -- 到达检测（早期 state 2/3）。
                --
                -- 【不要再臆测几何】之前这里写死 ER=3.2，依据是"native_minimal:108
                -- 的 orbit 参数 2.5 应该是环绕半径"——**那是我猜的参数含义**，
                -- 而且那条 orbit 属于 native_minimal 的 vanilla search 链路，
                -- 早期路径走的是 priority:step，根本不经过它。
                -- 两轮实验已证实引擎在 state 2/3 不读任何目标数据，
                -- 所以"G-60 会绕玩家 2.5m"没有任何证据支撑。
                --
                -- 现在只做两件事：
                --   1. 把真实距离报出去（early_probe），下一轮日志直接给出答案；
                --   2. 圈保持 EARLY_DETONATE_RADIUS，实测后再标定，不再拍脑袋。
                local dx,dy,dz=own[1]-chosen.point[1],own[2]-chosen.point[2],own[3]-chosen.point[3]
                local horiz=math.sqrt(dx*dx+dy*dy)
                local bucket=math.floor(horiz*2)   -- 0.5m 一档
                -- 键用 flight_start（每颗 G-60 独有）而不是实体 id ——
                -- 引擎会复用实体 id，用 id 会让新 G-60 继承旧 G-60 的去重状态。
                local pk=c.flight_start
                if probe_bucket[pk]~=bucket then
                    probe_bucket[pk]=bucket
                    if env.emit then
                        env.emit('early_probe;entity='..tostring(chosen.entity.id)
                            ..';h='..tostring(horiz)..';dz='..tostring(dz)
                            ..';own='..tostring(own[1])..','..tostring(own[2])..','..tostring(own[3])
                            ..';point='..tostring(chosen.point[1])..','..tostring(chosen.point[2])
                            ..','..tostring(chosen.point[3]))
                    end
                end
                if horiz<=EARLY_DETONATE_RADIUS and math.abs(dz)<=EARLY_DETONATE_DEPTH then
                    local ex=Explosive.capture(scope.read,env.base,env.exe,c.identity_bytes,env.fuse_profile)
                    assert(ex.validate() and check()==after,'early explosive changed')
                    scope.calls.explode(ffi.cast('void *',ex.manager),ex.id,ex.invalid_source,nil)
                    return {kind='detonate',target=chosen.entity.id,
                        distance=math.sqrt(dx*dx+dy*dy+dz*dz),early=true}
                end
                return {kind='lock',reason=reason,changed=mutated,
                    record=after,resource=chosen.entity.resource,
                    -- ★ generic 必须带下去（2026-10-01）★
                    --   这就是运行时存进 `old.lock` 的那张表 ⇒ 漏了它，
                    --   下一帧 `previous.generic` 恒 nil ⇒ 通用 sticky 分支永不执行。
                    --   （另一处同类构造在下方主路径，两处必须一起改 ——
                    --     本文件 366-370 行记过"只给一份加复核 ⇒ 越界溜进来"的教训。）
                    track={id=chosen.entity.id,identity=chosen.entity.identity,unit=chosen.unit,
                        raw=chosen.raw,score=chosen.score,marked_structure=true,
                        generic=chosen.generic,
                        point=chosen.point,point_bytes=point_bytes}}
            end
            local same_selection=c.selection.has_target and c.selection.id==chosen.entity.id
            if not same_selection or (env.fuse_profile and L.u32(record,0x64)~=0) then
                local data=ffi.new('uint8_t[80]',same_selection and record:sub(0x19,0x68) or chosen.raw)
                -- Do not briefly re-enable native proximity between priority
                -- acquisition and the separate route/arrival observation.
                if env.fuse_profile then ffi.cast('uint32_t *',data+0x4c)[0]=0 end
                local pair=ffi.new('void *[2]',{ffi.cast('void *',c.entity_address),ffi.cast('void *',c.state_address)})
                mutated=true;scope.calls.clear(pair,data)
                local after=check()
                assert(L.u32(after,0x18)==chosen.entity.id and L.u32(after,0x70)==chosen.entity.id
                    and after:byte(0x79)==1,'priority setter target mismatch')
                assert(after:sub(0x31,0x68)==ffi.string(data+24,56),'priority setter metadata mismatch')
            end
            local marks=mark and (mark.queue or {mark}) or {}
            local chosen_mark=chosen_mark_index and marks[chosen_mark_index]
            return {kind='lock',reason=reason,changed=mutated,
                mark_queue_count=#marks,selected_mark_id=chosen_mark and chosen_mark.id,selected_mark_index=chosen_mark_index,
                mark_id=mark and mark.id,mark_current=mark and mark.current,mark_candidate_observed=mark_candidate,
                record=scope.read(c.state_address-8,0x1f8),resource=chosen.entity.resource,
                -- ★ marked_structure 必须显式为 true，否则不返回 lock ★
                -- 上游写的是 `marked_structure=chosen.marked_structure`，可为 nil。
                -- 而 runtime 的门控判的是 `old.lock or old.titan` —— nil 的
                -- marked_structure 不会阻止它被存进 old.lock，于是这个"锁"
                -- 既不受 take_gate 的 no_mark_no_hold 保护，也不受白名单保护
                -- （越界的另一半原因）。这里改成缺省即拒绝，fail-closed。
                --
                -- ★★ `generic` 必须一起带下去（2026-10-01 实机取证）★★
                --   本表就是运行时存进 `old.lock` 的对象；漏掉 `generic` 会让
                --   下一帧 `previous.generic` 恒为 nil ⇒ 上面那个"通用目标的 sticky"
                --   分支**永不执行**（只有这一处读 `.generic`，也只有 generic_validate
                --   一处写它）⇒ 通用目标每帧从当前标记重新派生、不忠实，
                --   并把 `structure_lock_lost;RESOURCE_NOT_IN_WHITELIST` 刷成误导性日志
                --   （它本就不该出现在虫洞白名单里）。
                --   实机双重铁证（23:39 那局）：① 该分支的日志后缀 `;generic=true`
                --   全日志 0 次；② 24 条 lock_lost **100% 落在非白名单目标**
                --   （强袭虫 ×9 / 穿刺虫 ×3 / 抚育喷涌虫 ×2 / 孢子强袭虫 / 阿尔法指挥官），
                --   而真虫洞 MK8/MK9 一次都没丢锁。
                track=chosen.marked_structure and
                    {id=chosen.entity.id,identity=chosen.entity.identity,unit=chosen.unit,
                     raw=chosen.raw,score=chosen.score,marked_structure=true,
                     generic=chosen.generic} or nil}
        end)
        busy=false
        if not ok then
            -- 竞争态：只放弃这一颗实体，不牵连全局（见文件头 M 处的说明）。
            if competitive(result) then
                if env.emit then env.emit('priority_contended;detail='..tostring(result)) end
                return {kind='quarantine',released=previous~=nil,contended=tostring(result)}
            end
            -- 早期接管的失败（含点目标写入不符）交由 runtime 的 danger 计数熔断，
            -- **不**设置全局 disabled —— 否则 state 3 一次失败会把 state 4 也废掉。
            if early_state and Faults.STATE3_DANGER[tostring(result)] then
                return {kind='state3_fail',detail=tostring(result)}
            end
            if mutated then disabled=true end
            return nil,tostring(result)
        end
        return result
    end
    return api
end
return M
