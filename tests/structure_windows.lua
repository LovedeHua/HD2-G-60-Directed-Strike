local ffi=require('ffi')
local native=ffi.load(G60_FIXTURE_DLL)
local Context=require('g60.titan_context')
local common=G60TitanFixture
local profiles=assert(loadfile(G60_STRUCTURE_PROFILE))()(common.profile)
local A=G60AllocationWindows
local hole='8c31b749759cbd61'
local nest='095686275a113614'
local spore='aa28caf964d05500'
local colony='3a2cef12ed32a088'
local egg='06d3c4720e642fc1'
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(count,key)
    local f=A.setup(count or 1,profiles);A.resource(f,526,key or hole)
    f.candidates_all({521,522,523,524,525})
    return f
end
local function pose(p)
    local f=common.new();local u32=common.u32
    f.maps[f.entity]=u32(tonumber(p.resource:sub(9),16))..u32(tonumber(p.resource:sub(1,8),16))..f.maps[f.entity]:sub(9)
    f.maps[f.graph+0x10]=u32(p.nodes)
    local names={};for i=0,p.nodes-1 do names[#names+1]=u32(i==0 and p.boss_hash or i==2 and p.belly_hash or i) end
    f.maps[f.names]=table.concat(names)
    function f.capture(prior) return Context.capture(f.read,f.base,f.exe,521,p,prior) end
    return f
end
test('thirteen exact marked structure profiles decode even when their skeletons have fewer than 95 nodes',function()
    local n=0
    for _,p in pairs(profiles) do
        n=n+1;local f=pose(p);local c=f.capture();assert(c.boss==0 and c.belly==2 and c.validate())
        for k=1,3 do assert(math.abs(c.point[k]-({100,200,300})[k]-p.offset[k])<1e-4) end
        f.maps[f.graph+0x10]=common.u32(p.nodes+1);assert(not pcall(f.capture))
    end
    assert(n==13)
end)
test('scaled and rotated structure positions follow the root without weakening enemy pose limits',function()
    local f=pose(profiles[spore]);f.maps[f.poses]=common.matrix(nil,nil,nil,{0,3,0,0,-3,0,0,0,0,0,3,0,100,200,300,1})
    local c=f.capture();local offset=profiles[spore].offset
    assert(math.abs(c.point[1]-(100-3*offset[2]))<1e-4 and math.abs(c.point[3]-(300+3*offset[3]))<1e-4)
    f.maps[f.names]=string.rep('\0',profiles[spore].nodes*4);assert(not pcall(f.capture))
end)
test('unmarked structures never join automatic enemy selection',function()
    for _,key in ipairs({hole,colony,spore,egg}) do
        local f=setup(1,key);f.candidates_all({{526,1000},{521,1}});f.host:tick();f.check()
        assert(f.locked(0,521) and not f.locked(0,526))
    end
end)
test('local hole mark interrupts a Titan lock while the other grenades retain their allocated enemies',function()
    local f=setup(3);f.host:tick();f.check();assert(f.locked(0,521))
    f.ping(0,526);f.host:tick();f.check()
    assert(f.locked(0,526) and not f.locked(1,526) and not f.locked(2,526),table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find('PLAYER_MARK_STRUCTURE',1,true))
    assert(not f.target_allowed(hole) and native.fixture_explosions()==0)
end)
test('observed colony mark preempts an airborne Titan lock and retains exclusive ownership',function()
    local f=setup(3,colony);f.host:tick();f.check();assert(f.locked(0,521))
    f.ping(0,526);f.host:tick();f.check()
    assert(f.locked(0,526) and not f.locked(1,526) and not f.locked(2,526))
    assert(not f.target_allowed(colony) and native.fixture_explosions()==0)
    local logs=table.concat(f.logs,'\n')
    assert(logs:find('resource='..colony..';reason=ACCEPTED',1,true))
    assert(not logs:find('RESOURCE_NOT_SUPPORTED',1,true))
    -- The exterior spawn locator is farther out than the normal five metres.
    local xyz=ffi.cast('float *',f.source.record+0x1c)
    assert(math.abs(tonumber(xyz[1])-profiles[colony].front_distance)<1e-4)
end)
test('own egg mark overrides an airborne monster and remembered hole; other grenades do not duplicate it',function()
    local f=setup(3,egg);A.resource(f,525,hole)
    f.host:tick();f.check();assert(f.locked(0,521))
    f.ping(0,525);f.host:tick();f.check();assert(f.locked(0,525))
    f.ping(1,526);f.host:tick();f.check()
    assert(f.locked(0,526) and not f.locked(1,526) and not f.locked(2,526))
    assert(not f.target_allowed(egg) and native.fixture_explosions()==0)
end)
test('teammate eggs and sample eggs do not redirect; destroyed marked egg returns to enemies',function()
    local f=setup(1,egg);f.ping(0,526,601);f.host:tick();f.check()
    assert(f.locked(0,521) and not f.locked(0,526))
    A.resource(f,525,'2b5d3186ee3a4a84');f.ping(1,525);f.host:tick();f.check()
    assert(not f.locked(0,525))
    f.ping(2,526);f.host:tick();f.check();assert(f.locked(0,526))
    native.fixture_dead(526);f.logs={};f.host:tick();f.check()
    assert(f.locked(0,521) and native.fixture_explosions()==0)
end)
test('marked structures work without vanilla enemy candidates and only one waiting grenade departs',function()
    for _,key in ipairs({hole,colony,spore,egg}) do
        local f=setup(3,key);f.candidates_all({});for i=0,2 do f.select_at(i,0) end
        f.host:tick();f.check();assert(f.host.aimed==0)
        f.ping(0,526);local aimed=f.host.aimed;f.host:tick();f.check()
        assert(f.host.aimed==aimed+1 and f.locked(0,526) and not f.locked(1,526) and not f.locked(2,526),table.concat(f.logs,'\n'))
    end
end)
test('teammate structure marks and ordinary enemy marks cannot override automatic rank',function()
    for _,mark in ipairs({{526,601},{522,600}}) do
        local f=setup();f.ping(0,mark[1],mark[2]);f.host:tick();f.check()
        assert(f.locked(0,521) and not f.locked(0,526) and not f.locked(0,522))
    end
end)
test('expired marker UI retains the command; a destroyed structure returns to automatic selection',function()
    local f=setup();f.ping(0,526);f.host:tick();f.check();assert(f.locked(0,526))
    f.float(f.ring+16,0x14,11);f.host:tick();f.check();assert(not f.locked(0,521))
    native.fixture_dead(526);f.host:tick();f.check();assert(f.locked(0,521))
    assert(table.concat(f.logs,'\n'):find('NATIVE_TARGET_INVALID',1,true))
    f.logs={};f.host:tick();f.check();assert(not f.locked(0,526))
end)
test('new marked structure overrides the older marked structure in flight',function()
    -- ★ 2026-09-29：原来这里用 nest(尖啸者巢)，它已按用户要求移出白名单 ⇒ 换 colony
    local f=setup();A.resource(f,525,colony);f.ping(0,526);f.host:tick();f.check()
    f.ping(1,525);f.host:tick();f.check();assert(f.locked(0,525),table.concat(f.logs,'\n'))
end)
test('missing structure pose refuses the override and keeps normal enemy targeting',function()
    local f=setup();f.ping(0,526);f.pose_missing=true;f.host:tick()
    assert(not f.locked(0,526) and native.fixture_explosions()==0 and not f.host.disabled)
    assert(table.concat(f.logs,'\n'):find('POSE_READ_FAILED',1,true))
end)
test('unsupported local structure mark is diagnosed once without opening the automatic whitelist',function()
    local f=setup();A.resource(f,526,'16f397ca5f51f271');f.ping(0,526)
    for i=1,5 do f.host:tick();f.check() end
    local n=0;for _,line in ipairs(f.logs) do
        if line:find('RESOURCE_NOT_SUPPORTED',1,true) then
            n=n+1;assert(line:find('16f397ca5f51f271',1,true))
        end
    end
    assert(n==1 and not f.locked(0,526) and f.locked(0,521))
end)
test('shrieker nest mark is refused: not a bug hole, never taken over',function()
    -- ★★ 2026-09-29 用户要求："有生命值的尖啸巢穴这一类的不要接管" ★★
    -- 两个独立来源确认它是巢体而非虫洞：
    --   游戏路径 content/env_bugs/assets/gameplay/bug_spawner_shrieker
    --   社区资源 ID 表 → "尖啸虫巢穴 | Shrieker Nest"
    local f=setup();A.resource(f,526,nest);f.ping(0,526)
    for i=1,5 do f.host:tick();f.check() end
    local n=0;for _,line in ipairs(f.logs) do
        if line:find('RESOURCE_NOT_SUPPORTED',1,true) then
            n=n+1;assert(line:find(nest,1,true))
        end
    end
    assert(n==1 and not f.locked(0,526) and f.locked(0,521)
        and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
end)
test('hole explodes near the accessible rim outside the old exact point tolerance',function()
    local f=setup();f.ping(0,526);f.host:tick();f.check()
    -- Synthetic point {10,0,6}, forward {0,1,0}: enter from the front.
    f.position={10,5,6.5};f.u64(f.clock,0x18,2100000);f.host:tick();f.check()
    assert(native.fixture_explosions()==0)
    -- Above/backside cannot trigger even after entering attack stage.
    for i,p in ipairs({{10,-1,6.5},{10,1,9},{12,1,6.5}}) do
        f.position=p;f.u64(f.clock,0x18,2100000+i*100000);f.host:tick();f.check()
        assert(native.fixture_explosions()==0)
    end
    f.position={11,2,6.8};f.u64(f.clock,0x18,2600000);f.host:tick();f.check()
    assert(native.fixture_explosions()==1,table.concat(f.logs,'\n'))
    assert(tonumber(ffi.cast('uint32_t *',f.source.record+0x188)[0])==1000000)
    f.host:tick();assert(native.fixture_explosions()==1)
end)
test('hole reaches front before explosion; towers detonate at their offset site and preserve the timer',function()
    for _,key in ipairs({hole,colony,spore,egg}) do
        local f=setup(1,key);f.ping(0,526);local complete=false
        for i=1,16 do
            f.host:tick();f.check()
            assert(tonumber(ffi.cast('uint32_t *',f.source.record+0x188)[0])==1000000)
            if native.fixture_explosions()==1 then complete=true;break end
            local xyz=ffi.cast('float *',f.source.record+0x1c)
            f.position={tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])+0.25}
            f.u64(f.clock,0x18,2000000+i*100000)
        end
        assert(complete,table.concat(f.logs,'\n'));f.host:tick();assert(native.fixture_explosions()==1)
    end
end)
print('RESULT '..passed..' passed; 0 failed (marked structures, preemption and original Windows native calls)')
