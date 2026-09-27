local ffi=require('ffi')
local native=ffi.load(G60_FIXTURE_DLL)
local L=require('g60.native_observer')
local profiles=assert(loadfile(G60_WEAKPOINT_PROFILE))()(G60TitanFixture.profile)
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(resource,p,strict)
    local f=G60ArrivalWindows.setup();f.weakpoint_profiles=profiles;f.designed_targets_only=strict
    f.u32(f.identities,24,tonumber(resource:sub(9),16));f.u32(f.identities,28,tonumber(resource:sub(1,8),16))
    f.select(522);f.candidate(1,522)
    f.weakpoint_geometry={point=p.kind=='head' and {10,1.5,2.2} or p.kind=='rear' and {10,-2.34,1.77} or p.kind=='underside' and {10,0,1.76} or {10,1.2,6},
        body_center=(p.kind=='head' or p.kind=='rear') and {10,0,2.151} or p.kind=='underside' and {10,0,3.15} or {10,0,8},origin={10,0,0}}
    G60PriorityWindows.runtime(f);return f
end
for resource,p in pairs(profiles) do
    test(p.kind..' '..resource..' full runtime guides through native setters and requests one arrival explosion',function()
        local f=setup(resource,p);f.position={10,-3,12};local done=false
        for i=1,40 do
            f.host:tick();assert(not f.host.disabled,table.concat(f.logs,'\n'))
            local record=f.read(f.source.record,0x1f8)
            assert(L.u32(record,0x188)==1000000 and L.u32(record,0x64)==0,table.concat(f.logs,'\n'))
            if native.fixture_explosions()==1 then done=true;break end
            local xyz=ffi.cast('float *',f.source.record+0x1c)
            assert(native.fixture_consume_point(xyz[0],xyz[1],xyz[2])==0)
            f.position={tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])+0.25}
            f.u64(f.clock,0x18,2000000+i*100000)
        end
        assert(done and f.host.aimed>1 and native.fixture_bad_args()==0,table.concat(f.logs,'\n'))
        f.host:tick();assert(native.fixture_explosions()==1)
    end)
end
test('new weakpoint cannot fall back to a vanilla explosion when its pose is unavailable',function()
    for resource,p in pairs(profiles) do
        local f=setup(resource,p);f.pose_missing=true;f.position={10,0,0}
        f.host:tick();f.host:tick()
        assert(native.fixture_explosions()==0 and native.fixture_orbits()>=1 and not f.host.disabled,table.concat(f.logs,'\n'))
    end
end)
test('Impaler tentacle is rejected in favor of the body and cannot steal a mark',function()
    local key='dcf8e74212fbee3b';local f=setup(key,profiles[key])
    f.u32(f.identities,48,0x7f3ba34a);f.u32(f.identities,52,0x672f7da1)
    f.candidate(2,523,100);f.select(523);f.ping(0,523);f.host:tick()
    assert(f.host.aimed==1 and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find(';target=522;',1,true))
end)
test('dead Dragonroach releases its saved point, suppresses detonation and preserves flight start',function()
    local key='960b48a421a3faaa';local f=setup(key,profiles[key]);f.position={10,0,12}
    f.host:tick();native.fixture_dead(522);f.host:tick()
    assert(native.fixture_orbits()==1 and native.fixture_explosions()==0 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('Dragonroach region keeps the vertical standoff, accepts lateral offset and rejects transit',function()
    local p=profiles['960b48a421a3faaa']
    for _,case in ipairs({{{11.5,0,3.2},true,true},{{10,0,3.6},true,false},{{10,0,2.6},true,false},
        {{11.76,0,3.2},true,false},{{10,0,3.5},false,false}}) do
        local f=G60ArrivalWindows.setup();f.select(522);f.position=case[1]
        local r,why=f.arrival:step(f.scope(),f.target(522),{10,0,3.5},'weakpoint/thorax/attack',case[2],nil,nil,
            {point=true,below=true,region=p.region})
        assert(r,why);assert((r.kind=='detonate')==case[3])
        assert(native.fixture_explosions()==(case[3] and 1 or 0))
    end
end)
test('new point executor suppresses vanilla fuse when starting without priority category suppression',function()
    local key='1a7fcdff98c664b0';local f=setup(key,profiles[key]);f.position={10,-3,12}
    local scope=f.scope();scope.snapshot={selected={resource=key}}
    local aim=f.point_executor.new(f)
    local r,why=aim:step(scope);assert(r and r.kind=='aim',why or r and r.reason)
    assert(L.u32(f.read(f.source.record,0x1f8),0x64)==0 and not aim:disabled())
end)
G60WeakpointWindows={setup=setup,profiles=profiles}
print('RESULT '..passed..' passed; 0 failed (new enemy routes and fuse, Windows owned fixture)')
