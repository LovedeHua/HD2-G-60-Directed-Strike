local ffi=require('ffi')
local native=ffi.load(G60_FIXTURE_DLL)
local W=G60WeakpointWindows
local L=require('g60.native_observer')
local Allowlist=require('g60.target_allowlist')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(resource)
    return W.setup(resource or '1a7fcdff98c664b0',W.profiles[resource or '1a7fcdff98c664b0'] or W.profiles['1a7fcdff98c664b0'],true)
end
local function resource(f,slot,key)
    f.u32(f.identities,slot*24,tonumber(key:sub(9),16));f.u32(f.identities,slot*24+4,tonumber(key:sub(1,8),16))
end
test('strict runtime derives eight exact identities from the enabled profiles',function()
    local f=setup();local count=0
    assert(f.target_allowed('9e2e17f2ccccafdd'));count=count+1
    for key in pairs(W.profiles) do assert(f.target_allowed(key));count=count+1 end
    assert(count==8 and not f.target_allowed('ef04cb84d097a497') and not f.target_allowed(nil))
end)
test('marked or unmarked forbidden native choices clear to orbit without requesting explosion',function()
    for _,key in ipairs({'d522fd4748d443a5','ef04cb84d097a497','672f7da17f3ba34a','be39e313a1e46bb9',
        'a1f37bf2a40fbde4','1111111111111111'}) do
        for _,marked in ipairs({false,true}) do
            local f=setup(key);f.position={10,0,0};if marked then f.ping(0,522) end
            f.host:tick();f.host:tick()
            assert(not f.host.disabled and f.host.aimed==0,table.concat(f.logs,'\n'))
            assert(native.fixture_explosions()==0 and native.fixture_points()==0 and native.fixture_orbits()==2,table.concat(f.logs,'\n'))
            local r=f.read(f.source.record,0x1f8);assert(L.u32(r,0x18)==0 and r:byte(0x79)==0 and L.u32(r,0x188)==1000000)
        end
    end
end)
test('excluded marked Commander cannot outrank allowed Charger; permitted mark still outranks Titan',function()
    local f=setup();f.candidate(2,526,1000);f.ping(0,526);f.host:tick()
    assert(f.host.aimed==1 and table.concat(f.logs,'\n'):find(';target=522;',1,true),table.concat(f.logs,'\n'))
    f=setup();f.candidate(2,521,1000);f.ping(0,522);f.host:tick()
    assert(f.host.aimed==1 and table.concat(f.logs,'\n'):find(';reason=CURRENT_PING;',1,true),table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find(';target=522;',1,true))
end)
test('Dragonroach without a rank is acquired when vanilla selected an excluded Commander',function()
    local f=setup('d522fd4748d443a5');resource(f,2,'960b48a421a3faaa');f.candidate(2,523,5)
    f.weakpoint_geometry={point={10,1.2,6},body_center={10,0,8},origin={10,0,0}}
    f.host:tick();assert(f.host.aimed==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find(';target=523;',1,true))
    assert(table.concat(f.logs,'\n'):find(';reason=ALLOWED_CANDIDATE;',1,true))
end)
test('same orbiting grenade acquires an allowed enemy when it enters the original candidate list',function()
    local f=setup('d522fd4748d443a5');f.host:tick()
    assert(native.fixture_orbits()==1 and f.host.aimed==0)
    resource(f,2,'1a7fcdff98c664b0');f.candidate(2,523,2);f.host:tick()
    assert(f.host.aimed==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find(';target=523;',1,true))
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('priority rejects an existing forbidden lock before selecting an eligible replacement',function()
    local f=G60PriorityWindows.setup();f.select(526);f.candidate(1,526)
    local old=f.step();assert(old.track.id==526)
    f.target_allowed=Allowlist.new({resource='9e2e17f2ccccafdd'},W.profiles)
    f.candidate(2,522);local nextone=f.step(old.track)
    assert(nextone.track.id==522 and native.fixture_bad_args()==0)
end)
test('whitelisted weakpoint keeps its existing route and detonates once',function()
    for _,case in ipairs({{'1a7fcdff98c664b0',{10,1.9,2.2}}, {'6b202392f4ab605e',{10,1.9,2.2}},
        {'3aff5fd7d5450b99',{10,-2.74,1.47}}, {'dcf8e74212fbee3b',{10,0,1.16}},
        {'960b48a421a3faaa',{10,1.2,3.1}}}) do
        local f=setup(case[1]);f.position=case[2];f.host:tick();f.host:tick()
        assert(native.fixture_explosions()==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    end
end)
test('no eligible target still expires with removal and no explosion',function()
    local f=setup('d522fd4748d443a5');f.host:tick();f.u64(f.clock,0x18,31000000)
    f.host:tick();f.host:tick()
    assert(tonumber(ffi.cast('uint32_t *',native.fixture_retire_count())[0])==1)
    assert(native.fixture_explosions()==0 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
print('RESULT '..passed..' passed; 0 failed (strict custom-profile allowlist, Windows owned fixture)')
