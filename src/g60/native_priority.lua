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
                    if env.forget_mark then env.forget_mark(e.identity) end
                    return false
                end
                row.unit=unit;return true
            end
            local chosen,reason,mark_candidate,chosen_mark_index
            -- An explicit structure mark may interrupt an existing enemy lock.
            -- Never discover structures from the automatic candidate list.
            if structure_mark and env.structure_profiles then
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
                    local alive=scope.calls.target_valid(nil,e.id,ffi.cast('const void *',e.address))
                    assert(pose.validate() and d.validate() and scope.validate(),'marked structure validation changed')
                    if not alive then
                        if env.emit then env.emit('structure_unavailable;target='..e.id
                            ..';resource='..e.resource..';detail=NATIVE_TARGET_INVALID') end
                        if env.forget_mark then env.forget_mark(e.identity) end
                        return
                    end
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
            if not chosen and previous and not previous.marked_structure then
                local e=d.entity(previous.id)
                local row=e and {entity=e,raw=previous.raw,score=previous.score}
                if eligible(row,previous) then chosen,reason=row,'LOCKED' end
            end
            if not chosen then
                local rows=Candidates.capture(d,c)
                if mark then
                    mark_candidate=false
                    for _,row in ipairs(rows) do
                        if row.entity.identity==mark.identity then mark_candidate=true;break end
                    end
                end
                -- Validate in policy order; an invalid top-ranked corpse cannot
                -- prevent a live lower-ranked candidate from being considered.
                while #rows>0 do
                    local row,why,mark_index=Policy.choose(rows,env.priority_catalog,mark,nil,env.target_allowed)
                    if not row then
                        for _,r in ipairs(rows) do if r.entity.id==c.selection.id then row,why=r,'VANILLA_LOCK';break end end
                    end
                    if not row and env.target_allowed then
                        -- Profile-backed enemies without an automatic rank (Dragonroach)
                        -- remain selectable when vanilla picked a forbidden enemy.
                        for _,r in ipairs(rows) do
                            if env.target_allowed(r.entity.resource) and (not row or r.score>row.score) then
                                row,why=r,'ALLOWED_CANDIDATE'
                            end
                        end
                    end
                    if not row then break end
                    if eligible(row) then chosen,reason,chosen_mark_index=row,why,mark_index;break end
                    for i,r in ipairs(rows) do if r==row then table.remove(rows,i);break end end
                end
            end
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
