local ffi=require('ffi')
ffi.cdef[[void fixture_fuse_reset(void);void *fixture_fuse_state(void);void *fixture_fuse_network(void);
void *fixture_retire_count(void);void *fixture_retire_queue(void);unsigned fixture_explosions(void);
void fixture_explode(void *,uint32_t,uint32_t,void *);void *fixture_aim(void *,void **,const void *);
void fixture_remove(void *,uint32_t);]]
local native=ffi.load(G60_FIXTURE_DLL)
local L=require('g60.native_observer')
local Search=require('g60.native_search_context')
local Data=require('g60.native_target_data')
local Context=require('g60.explosive_context')
local Arrival=require('g60.native_arrival')
local Disposal=require('g60.native_disposal')
local Priority=require('g60.native_priority')
local profile=assert(loadfile(G60_FUSE_PROFILE))()
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function addr(p) return tonumber(ffi.cast('uintptr_t',p)) end
local function setup(mode)
    native.fixture_reset(mode or 0);native.fixture_fuse_reset()
    local e,r=addr(native.fixture_entity()),addr(native.fixture_record())
    local f=G60PriorityFixture.new({address=e,record=r,root=e-0xf32f18-8*24})
    local ex,net=addr(native.fixture_fuse_state()),addr(native.fixture_fuse_network())
    local qc,queue=addr(native.fixture_retire_count()),addr(native.fixture_retire_queue())
    local move=addr(native.fixture_movement());local read=f.read
    f.read=function(a,n)
        if a==f.root+0xf3ef18 and n==4 then return ffi.string(ffi.cast('const char *',qc),4) end
        for _,span in ipairs({{ex,64},{net,56},{queue,8192},{move,0xa8}}) do
            if a>=span[1] and a+n<=span[1]+span[2] then return ffi.string(ffi.cast('const char *',a),n) end
        end
        return read(a,n)
    end
    f.exstate,f.exnet=ex,net
    f.u64(f.block(f.base+0x3326728,8),0,0x42000000)
    local h=f.block(0x42000000,0x70);f.u32(h,0x18,16);f.u32(h,0x24,1)
    f.hash(h,0x38,0x42002000,{[547]=0});f.u64(h,0x50,0x42001000)
    f.u64(f.block(0x42001000,8),0,e);f.u64(h,0x60,ex);f.u64(h,0x68,net)
    f.overrides=f.block(0x42000078,20);f.hash(f.overrides,0,0x42003000,{})
    f.u32(f.block(f.base+0x3483c4c,4),0,0xdeadbeef)
    f.u64(f.block(f.root+profile.root_offset,8),0,0x45000020)
    local template=f.block(0x45000000,32+profile.row_offset+360)
    ffi.copy(template,profile.header,32);ffi.copy(template+32+profile.hash_offset,profile.hash_bytes,16)
    ffi.copy(template+32+profile.row_offset,profile.bytes,360)
    f.template=template
    f.u64(f.block(f.root+8,8),0,0x46000000)
    f.hash(f.block(0x4600b020,20),0,0x46010000,{[77]=0})
    f.u64(f.block(f.root+0xf3ef20,8),0,queue)
    f.owners[77]=true;f.ready=true;f.owned=true;f.position={0,0,0}
    f.fuse_profile=profile;f.priority_catalog=G60PriorityWindows.catalog
    f.calls={clear=ffi.cast('void (*)(void **,const void *)',native.fixture_clear),
        orbit=ffi.cast('void (*)(void **,float,float,float)',native.fixture_orbit),
        target_valid=ffi.cast('bool (*)(void *,uint32_t,const void *)',native.fixture_target_valid),
        explode=ffi.cast('void (*)(void *,uint32_t,uint32_t,void *)',native.fixture_explode),
        aim=ffi.cast('void *(*)(void *,void **,const void *)',native.fixture_aim),
        remove=ffi.cast('void (*)(void *,uint32_t)',native.fixture_remove)}
    function f.scope()
        local c=f.context();c.record_bytes=f.read(r,0x1f8);c.state_address=r+8;c.movement_address=move
        c.selection=Search.selection(c.record_bytes,0);c.ownership={local_ownership_observed=f.owned}
        c.own_position_bytes=ffi.string(ffi.new('float[3]',f.position),12)
        c.time_hex=L.hex64(ffi.string(f.clock+0x18,8),0);c.flight_start=L.hex64(c.record_bytes,0x188)
        return {experimental=true,native_lifetime_verified=false,reference_is_observation_key=true,
            prepared=c,calls=f.calls,read=f.read,invalid_id=0,validate=function() return f.ready end}
    end
    function f.select(id)
        ffi.cast('uint32_t *',r+0x18)[0]=id;ffi.cast('uint32_t *',r+0x70)[0]=id
        ffi.cast('uint8_t *',r+0x78)[0]=id==0 and 0 or 1
        ffi.cast('uint32_t *',r+0x64)[0]=1
    end
    function f.target(id)
        local d=Data.new(f.read,f.base,f.exe);local e=d.entity(id);d.unit(e);e.validate=d.validate;return e
    end
    f.arrival=Arrival.new(f)
    function f.step(goal,stage,terminal,progress)
        local result,reason=f.arrival:step(f.scope(),f.target(522),goal,stage or 'vanilla',terminal~=false,progress)
        assert(result,reason);return result
    end
    return f
end
test('explosive reader validates exact G60 mode, identity, configuration and no pending request',function()
    local f=setup();assert(Context.capture(f.read,f.base,f.exe,f.scope().prepared.identity_bytes,profile))
    for _,change in ipairs({function(f) ffi.cast('uint32_t *',f.exstate+0x38)[0]=0 end,
        function(f) ffi.cast('uint8_t *',f.exnet)[1]=1 end,
        function(f) f.template[32+profile.row_offset+0x13c]=1 end,
        function(f) ffi.cast('uint32_t *',f.source.address+20)[0]=0 end}) do
        f=setup();change(f);assert(not pcall(Context.capture,f.read,f.base,f.exe,f.scope().prepared.identity_bytes,profile))
    end
end)
test('optional override table may be unallocated; actual per-entity overrides are rejected',function()
    local f=setup();f.u64(f.overrides,0,0);f.u32(f.overrides,8,0)
    assert(Context.capture(f.read,f.base,f.exe,f.scope().prepared.identity_bytes,profile))
    f=setup();f.hash(f.overrides,0,0x42003000,{[547]=0})
    assert(not pcall(Context.capture,f.read,f.base,f.exe,f.scope().prepared.identity_bytes,profile))
end)
test('two metres never requests detonation; current point within tolerance requests exactly once',function()
    local f=setup();f.select(522);f.position={8,0,0}
    local result=f.step({10,0,0});assert(result.kind=='guide' and native.fixture_explosions()==0)
    assert(L.u32(f.read(f.source.record,0x1f8),0x64)==0)
    f.position={9.5,0,0};result=f.step({10,0,0});assert(result.kind=='detonate' and native.fixture_explosions()==1)
    assert(not f.arrival:step(f.scope(),f.target(522),{10,0,0},'vanilla',true))
    assert(native.fixture_explosions()==1 and L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('native aim getter retains non-Titan aim plus existing Z guidance offset',function()
    local f=setup();f.select(522)
    local p=ffi.cast('float *',f.source.record+0x1c);p[0]=10;p[1]=0;p[2]=-0.25
    f.position={10,0,0};assert(f.step(nil).kind=='detonate' and native.fixture_bad_args()==0)
end)
test('priority acquisition never enables vanilla proximity while waiting for the arrival step',function()
    for _,selected in ipairs({0,522}) do
        local f=setup();f.select(selected);f.candidate(1,522)
        local priority=Priority.new(f);local result,reason=priority:step(f.scope())
        assert(result and result.kind=='lock',reason)
        assert(L.u32(result.record,0x18)==522 and L.u32(result.record,0x64)==0)
        local p=ffi.cast('float *',f.source.record+0x1c)
        assert(native.fixture_consume_point(p[0],p[1],p[2])==0)
        local calls=native.fixture_points()
        assert(priority:step(f.scope(),result.track))
        assert(native.fixture_points()==calls and native.fixture_explosions()==0)
    end
end)
test('Titan arrival within tolerance above the belly does not request detonation',function()
    local f=setup();f.select(522);f.position={10,0,6.5}
    assert(f.step({10,0,6},'titan/attack',true).kind=='guide' and native.fixture_explosions()==0)
    f.position={10,0,5.5}
    assert(f.step({10,0,6},'titan/attack',true).kind=='detonate' and native.fixture_explosions()==1)
end)
test('transit point cannot detonate and four seconds without progress clears into orbit',function()
    local f=setup();f.select(522);f.position={10,0,0}
    assert(f.step({10,0,0},'titan/out',false).kind=='guide' and native.fixture_explosions()==0)
    f.position={0,0,0};local a=f.step({10,0,0})
    f.u64(f.clock,0x18,6000000);local b=f.step({10,0,0},'vanilla',true,a.progress)
    assert(b.kind=='search' and b.blocked and native.fixture_orbits()==1)
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('changed ownership, scope and partially failed request never produce repeated calls',function()
    local f=setup();f.owned=false;assert(not f.arrival:step(f.scope(),f.target(522),{0,0,0},'vanilla',true))
    assert(native.fixture_explosions()==0)
    for _,mode in ipairs({8,9}) do
        f=setup(mode);assert(not f.arrival:step(f.scope(),f.target(522),{0,0,0},'vanilla',true))
        assert(f.arrival:disabled() and native.fixture_explosions()==1)
        assert(not f.arrival:step(f.scope(),f.target(522),{0,0,0},'vanilla',true))
        assert(native.fixture_explosions()==1)
    end
end)
test('full runtime keeps Titan proximity off until actual belly arrival',function()
    for _,standoff in ipairs({0,2.5}) do
    local f=setup();f.select(522);f.candidate(1,521);f.candidate(2,522);G60PriorityWindows.runtime(f)
    f.titan_standoff=standoff
    local detonated=false
    for i=1,16 do
        f.host:tick();assert(not f.host.disabled,table.concat(f.logs,'\n'))
        if native.fixture_explosions()==1 then detonated=true;break end
        local r=f.read(f.source.record,0x1f8)
        assert(L.u32(r,0x64)==0,table.concat(f.logs,'\n'))
        local p=ffi.cast('float *',f.source.record+0x1c)
        f.position={tonumber(p[0]),tonumber(p[1]),tonumber(p[2])+0.25}
        f.u64(f.clock,0x18,2000000+i*100000)
        f.select(522)
    end
    assert(detonated and f.host.aimed>=4 and native.fixture_bad_args()==0,table.concat(f.logs,'\n'))
    f.host:tick();assert(native.fixture_explosions()==1)
    end
end)
test('near-belly arrival no longer explodes; the lowered point drives both guidance and detonation',function()
    local f=setup();f.titan_standoff=2.5;f.select(521);f.candidate(1,521);G60PriorityWindows.runtime(f)
    f.position={10,0,5.3};f.host:tick()
    assert(native.fixture_explosions()==0 and not f.host.disabled,table.concat(f.logs,'\n'))
    local p=ffi.cast('float *',f.source.record+0x1c)
    assert(math.abs(tonumber(p[2])+0.25-3.5)<0.0001,table.concat(f.logs,'\n'))
    assert(L.u32(f.read(f.source.record,0x1f8),0x64)==0)
    f.position={10,0,3.5};f.host:tick()
    assert(native.fixture_explosions()==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('Titan region detonates off-center at the retained height; high, low and lateral misses keep guiding',function()
    for _,case in ipairs({{{11.5,0,3},true},{{11.76,0,3},false},{{10,0,3.6},false},{{10,0,2.6},false}}) do
        local f=setup();f.titan_standoff=2.5;f.titan_arrival_region={radius=1.75,depth=0.8}
        f.select(521);f.candidate(1,521);G60PriorityWindows.runtime(f);f.position=case[1]
        f.host:tick()
        assert((native.fixture_explosions()==1)==case[2] and not f.host.disabled,table.concat(f.logs,'\n'))
        if not case[2] then assert(L.u32(f.read(f.source.record,0x1f8),0x64)==0) end
        f.host:tick();assert(native.fixture_explosions()==(case[2] and 1 or 0))
        assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
    end
end)
test('Titan region setting leaves non-Titan arrival tolerance unchanged',function()
    local f=setup();f.titan_arrival_region={radius=1.75,depth=0.8};f.select(522);f.position={11.5,0,3}
    assert(f.step({10,0,3.5},'vanilla',true).kind=='guide' and native.fixture_explosions()==0)
end)
test('stalled lock releases, rejected target is skipped, a different target can be acquired',function()
    local f=setup();f.select(522);f.candidate(1,522);G60PriorityWindows.runtime(f);f.position={0,0,0}
    local p=ffi.cast('float *',f.source.record+0x1c);p[0]=10;p[1]=0;p[2]=0
    f.host:tick();f.u64(f.clock,0x18,6000000);f.host:tick()
    assert(native.fixture_orbits()==1 and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
    f.candidate(2,523);f.select(522);f.host:tick()
    assert(L.u32(f.read(f.source.record,0x1f8),0x18)==523 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
test('expiry queues removal without an explosion, with original timer and once per grenade',function()
    for _,state in ipairs({3,4,5}) do
        local f=setup();f.select(0);G60PriorityWindows.runtime(f)
        ffi.cast('uint32_t *',f.source.record+8)[0]=state
        f.u64(f.clock,0x18,31000000);f.host:tick();f.host:tick()
        assert(tonumber(ffi.cast('uint32_t *',native.fixture_retire_count())[0])==1,table.concat(f.logs,'\n'))
        assert(native.fixture_explosions()==0 and native.fixture_points()==0 and not f.host.disabled)
        assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
    end
end)
test('stalled Titan cannot bypass cooldown through native reselection; retry resumes after cooldown',function()
    local f=setup();f.select(521);f.candidate(1,521);G60PriorityWindows.runtime(f)
    f.host:tick();f.u64(f.clock,0x18,6000000);f.host:tick()
    assert(native.fixture_orbits()==1 and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
    local aims=f.host.aimed
    f.select(521);f.host:tick()
    assert(f.host.aimed==aims and native.fixture_orbits()==2,table.concat(f.logs,'\n'))
    assert(f.read(f.source.record+0x78,1)=='\0')
    f.u64(f.clock,0x18,11000000);f.select(521);f.host:tick()
    assert(f.host.aimed==aims+1 and native.fixture_explosions()==0 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
test('dead locked target clears to orbit and a later eligible target can be acquired',function()
    local f=setup();f.select(522);f.candidate(1,522);G60PriorityWindows.runtime(f)
    f.host:tick();native.fixture_dead(522);f.host:tick()
    assert(native.fixture_orbits()==1 and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
    f.candidate(2,523);f.host:tick()
    assert(L.u32(f.read(f.source.record,0x1f8),0x18)==523 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
test('unavailable Titan weakpoint returns to search instead of keeping an unusable lock',function()
    local f=setup();f.select(521);f.candidate(1,521);f.candidate(2,522);G60PriorityWindows.runtime(f)
    f.pose_missing=true;f.host:tick()
    assert(native.fixture_orbits()==1 and native.fixture_explosions()==0,table.concat(f.logs,'\n'))
    f.select(521);f.host:tick()
    assert(L.u32(f.read(f.source.record,0x1f8),0x18)==522 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
test('expiry rejects premature, foreign-owned and full-queue removal',function()
    for _,mutate in ipairs({function(f) end,function(f) f.u64(f.clock,0x18,31000000);f.owners[77]=false end,
        function(f) f.u64(f.clock,0x18,31000000);ffi.cast('uint32_t *',native.fixture_retire_count())[0]=2048 end}) do
        local f=setup();G60PriorityWindows.runtime(f);mutate(f)
        local before=tonumber(ffi.cast('uint32_t *',native.fixture_retire_count())[0])
        local c=f.scope().prepared
        local m={index=0,id=547,identity_bytes=c.identity_bytes,record_bytes=c.record_bytes}
        assert(not Disposal.new(f):step(m,function() return true end))
        assert(tonumber(ffi.cast('uint32_t *',native.fixture_retire_count())[0])==before and native.fixture_explosions()==0)
    end
end)
test('expiry event gate permits distant unrelated events but still blocks events for the grenade',function()
    for _,id in ipairs({999,547}) do
        local f=setup();G60PriorityWindows.runtime(f);f.experimental_event_window=true
        f.u64(f.clock,0x18,31000000)
        f.u64(f.behavior_header,0,0x43001000);f.u32(f.behavior_header,8,1)
        local row=f.block(0x43001000,16);f.u64(row,0,35000000);f.u32(row,12,id)
        local c=f.scope().prepared
        local m={index=0,id=547,identity_bytes=c.identity_bytes,record_bytes=c.record_bytes}
        local result=Disposal.new(f):step(m,function() return true end)
        assert((result~=nil)==(id==999))
        assert(native.fixture_explosions()==0)
    end
end)
G60ArrivalWindows={setup=setup}
print('RESULT '..passed..' passed; 0 failed (arrival and expiry Windows owned fixture; no game session)')
