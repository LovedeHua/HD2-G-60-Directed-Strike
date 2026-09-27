-- Real C calls through Windows x64 ABI, exclusively on owned fixture storage.
local ffi=require('ffi')
ffi.cdef[[
void fixture_reset(unsigned);
void *fixture_entity(void); void *fixture_record(void); void *fixture_movement(void);
unsigned fixture_clears(void); unsigned fixture_orbits(void); unsigned fixture_bad_args(void);
void fixture_clear(void **, const void *); void fixture_orbit(void **, float, float, float);
]]
local native=ffi.load(assert(G60_FIXTURE_DLL))
local Minimal=require('g60.native_minimal')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function ref(id) return {id=id,generation='fixture-allocation-1',scene='owned-fixture'} end
local function fixture(mode,resource,experimental)
    native.fixture_reset(mode or 0)
    local function addr(p) return tonumber(ffi.cast('uintptr_t',p)) end
    local e,r,m=addr(native.fixture_entity()),addr(native.fixture_record()),addr(native.fixture_movement())
    local valid,window=true,'fixture-window-1'
    local scope={window=window,invalid_id=0,experimental=experimental==true,
        native_lifetime_verified=false,reference_is_observation_key=experimental==true}
    scope.read=function(a,n)
        local allowed=false
        for _,span in ipairs({{e,24},{r,0x1f8},{m,0xa8}}) do
            if a>=span[1] and n>0 and a+n<=span[1]+span[2] then allowed=true end
        end
        assert(allowed,'fixture read outside owned memory')
        return ffi.string(ffi.cast('const char *',a),n)
    end
    scope.validate=function() return valid end
    scope.calls={clear=ffi.cast('void (*)(void **, const void *)',native.fixture_clear),
                 orbit=ffi.cast('void (*)(void **, float, float, float)',native.fixture_orbit)}
    scope.snapshot={ref=ref('547'),resource='8e325c933e55bf62',behavior_id=4,state=4,
        active=true,expired=false,selection_complete=true,
        selected={ref=ref('521'),resource=resource or 'be39e313a1e46bb9'}}
    local function prepare()
        scope.prepared={entity_address=e,state_address=r+8,movement_address=m,
            identity_bytes=scope.read(e,24),record_bytes=scope.read(r,0x1f8),
            ownership={local_ownership_observed=true}}
    end
    prepare()
    local constructor=experimental and Minimal.new_experimental or Minimal.new
    local api=constructor(function(wanted,callback)
        assert(wanted.id=='547');valid=true
        local ok,result,reason=pcall(callback,scope)
        valid=false
        if not ok then error(result,0) end
        return result,reason
    end)
    return api,scope,prepare,{entity=e,record=r,movement=m}
end
test('no runtime scope cannot enable native calls',function()
    native.fixture_reset(0)
    local result,why=Minimal.new():step(ref('547'))
    assert(not result and why=='VERIFIED_RUNTIME_SCOPE_UNAVAILABLE')
    assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
end)
test('game binding rejects absent scope or changed code without invoking any address',function()
    local Binding=require('g60.native_search_binding')
    local reads=0
    local function reader() reads=reads+1;return '' end
    assert(not pcall(Binding.bind,reader,0x140000000,nil) and reads==0)
    assert(not pcall(Binding.bind,reader,0x140000000,function() return false end) and reads==0)
    assert(not pcall(Binding.bind,reader,0x140000000,function() return true end) and reads==1)
    assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
end)
test('all eight excluded resources execute NULL clear then native orbit with exact float ABI',function()
    for _,resource in ipairs({'51eea86bf6997e4e','9a8a3aae287b230c','aab438596f5e8fd9',
        '72a83e49ced6db3d','3d0e03e2d574e1ca','5ca832447445c0ba','be39e313a1e46bb9',
        'a1f37bf2a40fbde4'}) do
        local api,s=fixture(0,resource)
        local p,why,err=api:step(ref('547'))
        assert(p and p.kind=='search',tostring(why)..':'..tostring(err))
        assert(p.timer_preserved and p.state_preserved and p.movement_change_observed)
        assert(native.fixture_clears()==1 and native.fixture_orbits()==1 and native.fixture_bad_args()==0)
    end
end)
test('allowed or unknown resource keeps vanilla without native calls',function()
    local api=fixture(0,'ffffffffffffffff')
    assert(api:step(ref('547')).kind=='keep')
    assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
end)
test('state three, expiry, other weapons and unavailable authority never mutate',function()
    for _,mutate in ipairs({function(s) s.snapshot.state=3 end,
        function(s) s.snapshot.expired=true end,
        function(s) s.snapshot.resource='2d398d1ec35e0838';s.snapshot.behavior_id=621 end,
        function(s) s.prepared.ownership.local_ownership_observed=false end}) do
        local api,s=fixture();mutate(s);api:step(ref('547'))
        assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
    end
end)
test('recycled identity and changed state are rejected before calls',function()
    for _,field in ipairs({'entity','record'}) do
        local api,s,_,a=fixture()
        ffi.cast('uint8_t *',a[field])[0]=0
        local p,why=api:step(ref('547'))
        assert(not p and why=='NATIVE_PRECONDITION_FAILED' and not api:disabled())
        assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
    end
end)
test('expired scope before call rejects without mutation',function()
    local api,s=fixture();local checks=0
    s.validate=function() checks=checks+1;return checks==1 end
    assert(api:step(ref('547'))==nil and native.fixture_clears()==0 and native.fixture_orbits()==0)
end)
test('same window is not applied twice and later cleared search only calls orbit',function()
    local api,s,prepare=fixture();assert(api:step(ref('547')))
    s.snapshot.selected=nil;s.snapshot.selection_cleared=true;prepare()
    local p,why=api:step(ref('547'))
    assert(not p and why=='ALREADY_APPLIED_IN_WINDOW' and native.fixture_orbits()==1)
    s.window='fixture-window-2';assert(api:step(ref('547')))
    assert(native.fixture_clears()==1 and native.fixture_orbits()==2 and native.fixture_bad_args()==0)
end)
test('internally consistent bytes from another projectile cannot satisfy the requested identity',function()
    local api,s,prepare,a=fixture()
    ffi.cast('uint32_t *',a.entity+8)[0]=999
    ffi.cast('uint32_t *',a.record+0x68)[0]=999
    prepare()
    local p,why=api:step(ref('547'))
    assert(not p and why=='NATIVE_PRECONDITION_FAILED')
    assert(native.fixture_clears()==0 and native.fixture_orbits()==0)
end)
test('nested step is rejected while the outer scope is held',function()
    local api,s=fixture();local first=true
    s.validate=function()
        if first then
            first=false
            local p,why=api:step(ref('547'))
            assert(not p and why=='REENTRANT_OPERATION')
        end
        return true
    end
    assert(api:step(ref('547')) and native.fixture_clears()==1 and native.fixture_orbits()==1)
end)
test('clear failure, timer reset, absent movement and state transition latch disabled',function()
    for mode=1,4 do
        local api=fixture(mode)
        local p,why=api:step(ref('547'))
        assert(not p and why=='NATIVE_OPERATION_FAILED_DISABLED' and api:disabled())
        assert(native.fixture_clears()==1 and native.fixture_orbits()==(mode<=2 and 0 or 1))
        local count=native.fixture_orbits();api:step(ref('547'));assert(native.fixture_orbits()==count)
    end
end)
test('explicit experimental mode runs calls while leaving lifetime evidence false',function()
    local api=fixture(0,nil,true)
    local r=assert(api:step(ref('547')))
    assert(r.experimental and r.native_lifetime_verified==false and native.fixture_orbits()==1)
    api=fixture(3,nil,true)
    r=assert(api:step(ref('547')))
    assert(r.search_call_completed and not r.movement_change_observed and not api:disabled())
end)
test('experimental mode refuses a window mislabelled as a verified lifetime lease',function()
    local api,s=fixture(0,nil,true);s.native_lifetime_verified=true
    assert(api:step(ref('547'))==nil and native.fixture_clears()==0)
end)
print('RESULT '..passed..' passed; 0 failed (Windows native ABI fixture; no game session)')
