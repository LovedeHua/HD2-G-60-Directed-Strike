-- Copies an observed eligible candidate through the original setter only.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Candidates=require('g60.native_candidates')
local Policy=require('g60.target_policy')
local Filter=require('g60.small_filter')
local ArrivalPolicy=require('g60.arrival_policy')
local Context=require('g60.titan_context')
local M={}
local setter=ffi.typeof('void (*)(void **, const void *)')
local valid=ffi.typeof('bool (*)(void *, uint32_t, const void *)')
function M.new(env)
    local disabled,busy=false,false
    local api={}
    function api:disabled() return disabled end
    function api:step(scope,previous,mark,blocked,available,structure_mark)
        if disabled or busy then return nil,'PRIORITY_DISABLED' end
        if ffi.os~='Windows' or not ffi.abi('64bit') then return nil,'PRIORITY_ABI_UNSUPPORTED' end
        busy=true;local mutated=false
        local ok,result=pcall(function()
            assert(scope.experimental and not scope.native_lifetime_verified
                and scope.reference_is_observation_key,'experimental priority scope required')
            local c=scope.prepared;local record=c.record_bytes
            assert(c.ownership.local_ownership_observed and scope.validate(),'priority scope unavailable')
            assert(L.hex64(c.identity_bytes,0)=='8e325c933e55bf62' and L.u32(record,0)==4
                and L.u32(record,8)==4 and L.u32(record,0x68)==L.u32(c.identity_bytes,8),'priority source mismatch')
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
            if previous and previous.marked_structure then
                local e=d.entity(previous.id)
                local row=e and {entity=e,raw=previous.raw,score=previous.score,
                    unit=previous.unit,marked_structure=true}
                if row and eligible(row,previous) then chosen,reason=row,'LOCKED' end
                if not chosen and env.emit then env.emit('structure_lock_lost;target='..tostring(previous.id)
                    ..';detail='..(e and 'NO_LONGER_ELIGIBLE' or 'ENTITY_GONE')) end
            end
            if not chosen and structure_mark and env.structure_profiles then
                local good,row=pcall(function()
                    local e=d.entity(structure_mark.id)
                    local profile=e and env.structure_profiles[e.resource]
                    if not profile or e.identity~=structure_mark.identity or d.unit(e)~=structure_mark.unit then return end
                    if available and not available(e.identity) then return end
                    if blocked_now and e.identity==blocked.identity then return end
                    local pose=Context.capture(scope.read,env.base,env.exe,e.id,profile,structure_mark)
                    local distance=0;for k=1,3 do distance=distance+(pose.point[k]-own[k])^2 end
                    if distance>=40000 then return end
                    assert(pose.validate() and d.validate() and scope.validate(),'marked structure changed')
                    -- ★ 裁剪 K：软信号校验（原生 target_valid 只是参考，以只读复核为准）
                    if not check_alive(e,'NEW_MARK') then return end
                    -- Original setter accepts position candidates. Preserve the
                    -- observed metadata and suppress proximity; the point route
                    -- will replace this temporary entity selection immediately.
                    local raw=ffi.new('uint8_t[80]',record:sub(0x19,0x68))
                    ffi.cast('uint32_t *',raw)[0]=e.id
                    return {entity=e,raw=ffi.string(raw,80),score=1,unit=structure_mark.unit,marked_structure=true}
                end)
                if good and row then chosen,reason=row,'PLAYER_MARK_STRUCTURE'
                elseif not good and env.emit then env.emit('structure_unavailable;detail='..tostring(row)) end
            end
            -- ★ 裁剪 I 的配套：原来的 `if not chosen and previous and not previous.marked_structure`
            -- 分支（保住上一帧的**敌人**锁）在本工程已无意义 —— 敌人锁由引擎原生 TargetLock
            -- 负责，本 mod 从不创建也不会保留它。上面的 sticky 分支已覆盖 marked_structure，
            -- 这里保留原样但注明原因，便于日后对照上游。
            if not chosen and previous and not previous.marked_structure then
                local e=d.entity(previous.id)
                local row=e and {entity=e,raw=previous.raw,score=previous.score}
                if eligible(row,previous) then chosen,reason=row,'LOCKED' end
            end
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
                track={id=chosen.entity.id,identity=chosen.entity.identity,unit=chosen.unit,raw=chosen.raw,score=chosen.score,
                    marked_structure=chosen.marked_structure}}
        end)
        busy=false
        if not ok then if mutated then disabled=true end;return nil,tostring(result) end
        return result
    end
    return api
end
return M
