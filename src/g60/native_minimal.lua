-- Minimal native operation, with a separate user-authorized experimental entry.
-- with_scope must HOLD a verified engine lifetime/update window across the whole
-- callback. Readiness samples, stable rereads and ownership alone cannot supply it.
local ffi=require('ffi')
local U=require('g60.util')
local Veto=require('g60.selection_veto')
local Layout=require('g60.native_observer')
local Search=require('g60.native_search_context')
local M={}
local clear_type=ffi.typeof('void (*)(void **, const void *)')
local orbit_type=ffi.typeof('void (*)(void **, float, float, float)')
local function bytes(reader,address,n)
    local s=reader(address,n)
    assert(type(s)=='string' and #s==n,'short operation read')
    return s
end
local function address(a,alignment)
    assert(type(a)=='number' and a>=65536 and a<2^47 and a%alignment==0,'operation address bound')
    return a
end
local function finite_vector(s)
    for i=0,2 do
        assert(math.floor(Layout.u32(s,i*4)/8388608)%256~=255,'nonfinite search destination')
    end
end
local function create(with_scope,experimental,allowed)
    assert(allowed==nil or type(allowed)=='function','invalid target eligibility predicate')
    assert(with_scope==nil or type(with_scope)=='function','scope provider must be a function')
    local searching,last_window={},{}
    local disabled,busy=false,false
    local api={}
    function api:step(ref)
        if disabled then return nil,'NATIVE_OPERATION_DISABLED' end
        if busy then return nil,'REENTRANT_OPERATION' end
        local key=U.key(ref)
        if not key then return nil,'INVALID_REF' end
        if not with_scope then return nil,'VERIFIED_RUNTIME_SCOPE_UNAVAILABLE' end
        if ffi.os~='Windows' or not ffi.abi('64bit') then return nil,'UNSUPPORTED_NATIVE_ABI' end
        busy=true
        local entered,mutated=false,false
        local ok,result,reason=pcall(with_scope,U.ref(ref),function(scope)
            assert(not entered,'scope callback repeated');entered=true
            assert(type(scope)=='table' and type(scope.validate)=='function'
                and type(scope.read)=='function','invalid held scope')
            if experimental then
                assert(scope.experimental==true and scope.native_lifetime_verified==false
                    and scope.reference_is_observation_key==true,'explicit experimental window required')
            end
            assert(type(scope.window)=='string' and scope.window~='','missing scope window')
            assert(scope.validate()==true,'scope expired')
            local s,c=scope.snapshot,scope.prepared
            assert(type(s)=='table' and U.key(s.ref)==key,'scope identity differs')
            local plan,why=Veto.plan(s,searching[key]==true,allowed)
            if not plan then return nil,why end
            if plan.kind=='keep' then searching[key]=nil;return plan,why end
            assert(plan.kind=='search','unsupported minimal command')
            if last_window[key]==scope.window then return nil,'ALREADY_APPLIED_IN_WINDOW' end
            assert(type(c)=='table' and type(c.ownership)=='table'
                and c.ownership.local_ownership_observed==true,'ownership unavailable')
            assert(type(c.identity_bytes)=='string' and #c.identity_bytes==24
                and type(c.record_bytes)=='string' and #c.record_bytes==0x1f8,'missing prepared bytes')
            local entity=address(c.entity_address,8)
            local state=address(c.state_address,8)
            local movement=address(c.movement_address,8)
            local reader=scope.read
            assert(bytes(reader,entity,24)==c.identity_bytes,'projectile identity changed')
            assert(bytes(reader,state-8,0x1f8)==c.record_bytes,'projectile state changed')
            assert(Layout.hex64(c.identity_bytes,0)=='8e325c933e55bf62'
                and Layout.u32(c.record_bytes,0)==4 and Layout.u32(c.record_bytes,8)==4,
                'not state-4 G60')
            local id=Layout.u32(c.identity_bytes,8)
            assert(tonumber(ref.id)==id and Layout.u32(c.record_bytes,0x68)==id,
                'prepared projectile differs from requested identity')
            assert(math.floor(Layout.u32(c.identity_bytes,20)/2)%2==0,'native update excluded')
            assert(type(scope.invalid_id)=='number' and scope.invalid_id>=0
                and scope.invalid_id<=0xffffffff and scope.invalid_id%1==0,'invalid ID bound')
            local selection=Search.selection(c.record_bytes,scope.invalid_id)
            if selection.has_target then
                assert(s.selected and tonumber(s.selected.ref.id)==selection.id,'selection differs')
            else assert(s.selected==nil,'selection differs') end
            local calls=scope.calls
            assert(type(calls)=='table' and ffi.istype(clear_type,calls.clear)
                and ffi.istype(orbit_type,calls.orbit),'unverified native call types')
            local pair=ffi.new('void *[2]',{ffi.cast('void *',entity),ffi.cast('void *',state)})
            local original_timer=c.record_bytes:sub(0x189,0x190)
            local original_state=c.record_bytes:sub(9,12)
            local old_destination=bytes(reader,movement+0x60,12)
            local function check_identity_and_timer()
                assert(scope.validate()==true,'scope expired during operation')
                assert(bytes(reader,entity,24)==c.identity_bytes,'projectile changed during operation')
                local record=bytes(reader,state-8,0x1f8)
                assert(record:sub(0x189,0x190)==original_timer,'flight timer changed')
                assert(record:sub(9,12)==original_state,'behavior state changed')
                return record
            end
            -- No yields or engine queries between this validation and the calls.
            assert(scope.validate()==true,'scope expired before call')
            last_window[key]=scope.window
            if not selection.cleared then
                mutated=true
                calls.clear(pair,nil)
                assert(Search.selection(check_identity_and_timer(),scope.invalid_id).cleared,
                    'NULL setter did not clear selection')
            end
            mutated=true
            -- Exact argument types/order and float constants of game 0xbb009..0xbb021.
            -- Never call the state-3 transition, which resets the flight timer.
            calls.orbit(pair,10.0,2.5,1.2000000476837158)
            local record=check_identity_and_timer()
            assert(Search.selection(record,scope.invalid_id).cleared,'search left selection active')
            local destination=bytes(reader,movement+0x60,12)
            finite_vector(destination)
            -- An identical destination is possible on repeated paused-time updates.
            -- Verified mode keeps its stronger observed-change requirement.
            if not experimental then assert(destination~=old_destination,'search movement effect not observed') end
            searching[key]=true
            return {kind='search',selection_cleared=true,search_call_completed=true,
                movement_change_observed=destination~=old_destination,
                timer_preserved=true,state_preserved=true,
                experimental=experimental,native_lifetime_verified=false},why
        end)
        busy=false
        if not ok then
            if mutated then disabled=true end -- No rollback of RNG/nav/network effects.
            return nil,mutated and 'NATIVE_OPERATION_FAILED_DISABLED' or 'NATIVE_PRECONDITION_FAILED',tostring(result)
        end
        if not entered then return nil,'VERIFIED_RUNTIME_SCOPE_UNAVAILABLE' end
        return result,reason
    end
    function api:release(ref)
        local key=U.key(ref)
        if key then searching[key]=nil;last_window[key]=nil end
    end
    function api:disabled() return disabled end
    return api
end
function M.new(with_scope) return create(with_scope,false) end
function M.new_experimental(with_observation_window,allowed) return create(with_observation_window,true,allowed) end
return M
