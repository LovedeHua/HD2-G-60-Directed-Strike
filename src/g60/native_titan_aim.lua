-- User-authorized experimental point-candidate setter. No executable writes.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Context=require('g60.titan_context')
local Route=require('g60.titan_route')
local WeakRoute=require('g60.weakpoint_route')
local StructureRoute=require('g60.structure_route')
local ArrivalPolicy=require('g60.arrival_policy')
local M={}
local setter=ffi.typeof('void (*)(void **, const void *)')
local orbit=ffi.typeof('void (*)(void **, float, float, float)')
local valid=ffi.typeof('bool (*)(void *, uint32_t, const void *)')
function M.new(env)
    local disabled,busy=false,false
    local api={}
    function api:step(scope,previous)
        if disabled or busy then return nil,'TITAN_OPERATION_DISABLED' end
        if ffi.os~='Windows' or not ffi.abi('64bit') then return nil,'TITAN_ABI_UNSUPPORTED' end
        busy=true
        local mutated=false
        local ok,result=pcall(function()
            assert(scope.experimental and not scope.native_lifetime_verified
                and scope.reference_is_observation_key,'experimental Titan window required')
            local c=scope.prepared;local record=c.record_bytes
            assert(c.ownership.local_ownership_observed and scope.validate(),'Titan scope unavailable')
            assert(L.hex64(c.identity_bytes,0)=='8e325c933e55bf62'
                and L.u32(record,0)==4 and L.u32(record,8)==4
                and L.u32(record,0x68)==L.u32(c.identity_bytes,8),'Titan source mismatch')
            local calls=scope.calls
            assert(ffi.istype(setter,calls.clear) and ffi.istype(orbit,calls.orbit)
                and ffi.istype(valid,calls.target_valid),'Titan call ABI mismatch')
            local resource=c.selection.has_target and scope.snapshot.selected and scope.snapshot.selected.resource
            local profile=resource and ((env.weakpoint_profiles or {})[resource]
                or (env.structure_profiles or {})[resource]
                or resource==env.titan_profile.resource and env.titan_profile)
            local fresh=profile~=nil and profile~=false
            if not fresh and previous and previous.target then profile=previous.target.profile or env.titan_profile end
            local owned_point=previous and not c.selection.has_target and c.selection.flag==1
                and record:sub(0x1d,0x28)==previous.point_bytes
            assert(fresh or (previous and (owned_point or c.selection.cleared)), 'Titan selection changed')
            local candidate=fresh and record:sub(0x19,0x68) or previous.candidate
            local target,reason,own_position,route
            if not (previous and previous.cancelled and not fresh) then
                local id=fresh and c.selection.id or previous.target.id
                local same=previous and previous.target and previous.target.id==id and previous.target or nil
                local captured,value=pcall(Context.capture,scope.read,env.base,env.exe,id,profile,same)
                if captured then target=value else reason=tostring(value) end
            end
            local function check()
                assert(scope.validate(),'Titan scope expired')
                assert(scope.read(c.entity_address,24)==c.identity_bytes,'Titan projectile changed')
                local r=scope.read(c.state_address-8,0x1f8)
                assert(r:sub(0x189,0x190)==record:sub(0x189,0x190),'Titan flight timer changed')
                assert(r:sub(1,12)==record:sub(1,12),'Titan behavior changed')
                return r
            end
            assert(check()==record,'Titan projectile state changed')
            if target then
                assert(type(c.own_position_bytes)=='string' and #c.own_position_bytes==12,'Titan projectile position unavailable')
                local own=ffi.new('uint8_t[12]',c.own_position_bytes)
                local xyz=ffi.cast('float *',own);local distance=0
                own_position={tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])}
                for i=0,2 do distance=distance+(target.point[i+1]-tonumber(xyz[i]))^2 end
                if not (distance<40000) then target=nil;reason='Titan point outside projectile range bound' end
            end
            if target then
                assert(target.validate(),'Titan target changed')
                -- ★ 裁剪 K（第三处，也是最关键的一处）：`target_valid` 硬否决 → 软信号。
                --
                -- 上游这里是 `if not alive then target=nil;reason='Titan no longer alive' end`，
                -- 而它**每个飞行帧都会跑**。虫巢没有 HealthComponent ——
                -- 原生 target_valid（game.dll+0x8858a0，索敌系统的函数）可能对
                -- "实际存在但引擎不认"的巢返回 false ⇒ target 每帧被置 nil
                -- ⇒ 永远算不出航点 ⇒ G-60 飞到附近也不会引爆。
                --
                -- 这解释了"priority_locked 出现了、却没有 titan_aim"的那些失败案例。
                -- 改成：原生说 false 时做**只读复核**（实体可读 / identity 未变 / 位置可读），
                -- 复核通过就继续规划航点，只发诊断；复核也失败才真的放弃。
                local alive=calls.target_valid(nil,target.id,ffi.cast('const void *',target.address))
                assert(scope.validate() and target.validate(),'Titan target changed during validation')
                if not alive then
                    -- 只读复核：复用 Context.capture（它本来就在每帧重新读该实体），
                    -- 能成功重读并拿到有效 pose 就说明实体还在，只是原生不认它。
                    local ok, again = pcall(Context.capture, scope.read, env.base, env.exe,
                                             target.id, profile, target)
                    local why = 'ALIVE_BY_READ'
                    if not ok then why = 'CAPTURE_FAILED' end
                    if ok and type(again)=='table' and type(again.validate)=='function'
                        and not again.validate() then
                        ok, why = false, 'POSE_INVALID'
                    end
                    if ok then
                        if env.emit then env.emit('structure_target_soft_invalid;target='..tostring(target.id)
                            ..';native=false;readonly='..why..';context=TITAN') end
                    else
                        local tid = target and target.id or '?'
                        target=nil;reason='Titan gone: '..tostring(why)
                        if env.emit then env.emit('structure_unavailable;target='..tostring(tid)
                            ..';detail='..tostring(why)..';context=TITAN') end
                    end
                end
            end
            if target then
                local prior=previous and not previous.cancelled and previous.target.id==target.id
                    and previous.route or nil
                local planned,value,detail
                if profile.structure then
                    planned,value,detail=pcall(StructureRoute.step,own_position,target,prior,profile)
                elseif profile.kind then
                    local now=profile.kind=='charger_front' and ArrivalPolicy.elapsed(c.time_hex,c.flight_start)/1000000 or nil
                    planned,value,detail=pcall(WeakRoute.step,own_position,target,prior,profile,now)
                else
                    planned,value,detail=pcall(Route.step,own_position,target,prior,env.titan_standoff,
                        env.titan_arrival_region and env.titan_arrival_region.radius)
                end
                if planned then route,reason=value,detail else reason=tostring(value) end
                if not route then target=nil end
            end
            local arrival_progress
            if target and env.arrival then
                local stage=(profile.kind and 'weakpoint/'..profile.kind or 'titan')..'/'..route.route.stage
                local options=profile.kind and {point=true,below=not profile.structure and profile.kind~='head' and profile.kind~='rear',region=route.arrival_region or profile.region}
                local value,why=env.arrival:step(scope,target,route.arrival_point or route.point,stage,
                    route.terminal,previous and previous.arrival_progress,nil,options)
                assert(value,why)
                if profile.structure and value.kind=='search' and env.emit then
                    env.emit('structure_stalled;entity='..L.u32(c.identity_bytes,8)..';target='..target.id
                        ..';resource='..profile.resource..';stage='..route.route.stage
                        ..';own='..table.concat(own_position,',')..';goal='..table.concat(route.point,','))
                end
                if value.kind=='detonate' or value.kind=='search' then
                    value.track={cancelled=true,candidate=candidate,target=target}
                    return value
                end
                arrival_progress=value.progress
            end
            if not target and not previous then return {kind='keep',reason=reason} end
            local pair=ffi.new('void *[2]',{ffi.cast('void *',c.entity_address),ffi.cast('void *',c.state_address)})
            if not target then
                assert(check()==record,'Titan cleanup state changed')
                mutated=true;calls.clear(pair,nil)
                local cleared=check()
                assert(L.u32(cleared,0x18)==scope.invalid_id and cleared:byte(0x79)==0
                    and L.u32(cleared,0x60)==0 and L.u32(cleared,0x70)==scope.invalid_id,'Titan cleanup failed')
                calls.orbit(pair,10,2.5,1.2000000476837158);check()
                return {kind='search',track={cancelled=true,candidate=candidate,target=previous.target},reason=reason}
            end
            assert(type(candidate)=='string' and #candidate==80,'Titan candidate size')
            local data=ffi.new('uint8_t[80]',candidate)
            ffi.cast('uint32_t *',data)[0]=scope.invalid_id
            local xyz=ffi.cast('float *',data+4)
            for i=0,2 do xyz[i]=route.point[i+1] end
            -- Reviewed guidance adds 0.25 m to Z. Without the arrival controller,
            -- legacy builds keep the original final 2.5 m proximity radius.
            xyz[2]=xyz[2]-0.25
            -- 0x8859c0 tests the candidate category mask at +0x4c. Zero cannot
            -- match any category: transit waypoints must not act as fuse targets.
            -- Retain original metadata for legacy final approach and cleanup.
            if env.arrival or not route.terminal then ffi.cast('uint32_t *',data+0x4c)[0]=0 end
            local point_bytes=ffi.string(data+4,12)
            assert(check()==record and target.validate(),'Titan pre-call changed')
            mutated=true;calls.clear(pair,data)
            local after=check()
            assert(L.u32(after,0x18)==scope.invalid_id and after:byte(0x79)==1
                and after:sub(0x1d,0x28)==point_bytes and L.u32(after,0x70)==scope.invalid_id,
                'Titan point setter postcondition')
            -- The setter may refresh the timestamp; all later bytes must match
            -- our submitted candidate, including the per-stage category mask.
            assert(after:sub(0x31,0x68)==ffi.string(data+24,56),'Titan candidate metadata changed')
            return {kind='aim',point=route.point,stage=route.route.stage,own_position=profile.structure and own_position,
                track={target=target,candidate=candidate,point_bytes=point_bytes,route=route.route,arrival_progress=arrival_progress}}
        end)
        busy=false
        if not ok then if mutated then disabled=true end;return nil,tostring(result) end
        return result
    end
    function api:disabled() return disabled end
    return api
end
return M
