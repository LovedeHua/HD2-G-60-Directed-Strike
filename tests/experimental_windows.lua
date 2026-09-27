-- Integration with real C fixture calls and synthetic read-only world observations.
local ffi=require('ffi')
ffi.cdef[[void fixture_reset(unsigned);void *fixture_entity(void);void *fixture_record(void);
void *fixture_movement(void);unsigned fixture_clears(void);unsigned fixture_orbits(void);
unsigned fixture_bad_args(void);void fixture_clear(void **,const void *);
void fixture_orbit(void **,float,float,float);
unsigned fixture_points(void);unsigned fixture_validations(void);
void fixture_mode(unsigned);
bool fixture_target_valid(void *,uint32_t,const void *);
unsigned fixture_consume_point(float,float,float);]]
local native=ffi.load(G60_FIXTURE_DLL)
local Layout=require('g60.native_observer')
local Search=require('g60.native_search_context')
local actual_readiness=require('g60.native_readiness')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function fixture(mode)
    native.fixture_reset(mode or 0)
    local function addr(p) return tonumber(ffi.cast('uintptr_t',p)) end
    local e,r,m=addr(native.fixture_entity()),addr(native.fixture_record()),addr(native.fixture_movement())
    local base,root,clock,manager=0x10000000,0x20000000,0x30000000,0x40000000
    local function u64(v) return ffi.string(ffi.new('uint64_t[1]',v),8) end
    local maps={[base+0x346bf98]=u64(root),[base+0x3326348]=u64(clock),
        [base+0x3326740]=u64(manager),[base+0x3483c20]=string.rep('\0',4),
        [root+0xf3f828]='\1\0\0',[clock+0x18]=u64(2000000),[manager]=string.rep('\0',0x70)}
    local f={ready=true,owned=true,resource='be39e313a1e46bb9',logs={},titan=G60TitanFixture.new(),record=r,movement=m}
    f.position={100,200,300}
    f.select=function(resource)
        f.resource=resource
        ffi.cast('uint32_t *',r+0x18)[0]=521
        ffi.cast('uint32_t *',r+0x70)[0]=521
        ffi.cast('uint32_t *',r+0x60)[0]=1
        ffi.cast('uint32_t *',r+0x64)[0]=1
        ffi.cast('uint8_t *',r+0x78)[0]=1
    end
    f.read=function(a,n)
        if maps[a] then assert(#maps[a]==n);return maps[a] end
        for _,span in ipairs({{e,24},{r,0x1f8},{m,0xa8}}) do
            if a>=span[1] and n>0 and a+n<=span[1]+span[2] then return ffi.string(ffi.cast('const char *',a),n) end
        end
        return f.titan.read(a,n)
    end
    local fake_observer=setmetatable({capture=function()
        local identity,record=f.read(e,24),f.read(r,0x1f8)
        return {all_observed_queues_complete=true,update_mode=0,root_flags={1,0,0},matches={{
            index=0,id=547,behavior_id=4,state=4,native_update_eligible=true,
            identity_bytes=identity,record_bytes=record,flight_start=Layout.hex64(record,0x188),
            selection_id=Layout.u32(record,0x18),selection_flag=record:byte(0x79),selection_resource=f.resource}}}
    end},{__index=Layout})
    package.loaded['g60.native_observer']=fake_observer
    package.loaded['g60.native_readiness']={capture=function()
        return {engine_main_thread_observed=f.ready,world_job_completion=1,context_job_busy=0,context_job_active=0}
    end}
    package.loaded['g60.native_search_context']={capture=function()
        local record=f.read(r,0x1f8)
        return {entity_address=e,state_address=r+8,movement_address=m,identity_bytes=f.read(e,24),record_bytes=record,
            own_position_bytes=ffi.string(ffi.new('float[3]',f.position),12),
            selection=Search.selection(record,0),ownership={local_ownership_observed=f.owned}}
    end,selection=Search.selection,pending_events=Search.pending_events}
    package.loaded['g60.experimental_runtime']=nil
    local Runtime=require('g60.experimental_runtime')
    f.host=Runtime.new({read=f.read,base=base,exe=0x140000000,thread=function() return 328 end,
        engine={},titan_profile=G60TitanFixture.profile,
        calls={clear=ffi.cast('void (*)(void **,const void *)',native.fixture_clear),
            target_valid=ffi.cast('bool (*)(void *,uint32_t,const void *)',native.fixture_target_valid),
            orbit=ffi.cast('void (*)(void **,float,float,float)',native.fixture_orbit)},
        emit=function(line) f.logs[#f.logs+1]=line end})
    package.loaded['g60.native_observer']=Layout
    package.loaded['g60.native_search_context']=Search
    package.loaded['g60.native_readiness']=actual_readiness
    return f,Runtime
end
test('runtime excludes Warrior, continues search next frame, and preserves unverified status',function()
    local f=fixture();f.host:tick();f.host:tick()
    assert(native.fixture_clears()==1 and native.fixture_orbits()==2 and native.fixture_bad_args()==0)
    assert(f.host.applied==2 and not f.host.native_lifetime_verified and not f.host.disabled)
end)
test('Titan point candidate follows movement, preserves fuse metadata and original timer',function()
    local f=fixture();f.select(G60TitanFixture.profile.resource);f.host:tick()
    assert(native.fixture_points()==1 and f.host.aimed==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(native.fixture_validations()==1 and native.fixture_bad_args()==0)
    local r=f.read(f.record,0x1f8);local a=ffi.cast('float *',f.record+0x1c)
    local x,y,z=tonumber(a[0]),tonumber(a[1]),tonumber(a[2])
    assert(r:byte(0x79)==1 and Layout.u32(r,0x18)==0 and Layout.u32(r,0x188)==1000000)
    assert(Layout.u32(r,0x64)==1 and native.fixture_consume_point(x,y,z)==1)
    assert(native.fixture_consume_point(x+3,y,z)==0)
    assert(math.abs(tonumber(ffi.cast('float *',f.movement+0x68)[0])-z-0.25)<1e-4)
    f.titan.maps[f.titan.poses+93*64]=G60TitanFixture.matrix(102,203,308)
    f.host:tick();assert(native.fixture_points()==2 and f.host.aimed==2,table.concat(f.logs,'\n'))
    assert(math.abs(tonumber(a[0])-x-2)<1e-4 and math.abs(tonumber(a[1])-y-3)<1e-4)
end)
test('Titan overhead route suppresses waypoint proximity and restores original category for attack',function()
    local f=fixture();f.position={100,200,315};f.select(G60TitanFixture.profile.resource)
    ffi.cast('uint32_t *',f.record+0x64)[0]=0x80000001
    local seen={};local finished=false
    for _=1,20 do
        f.host:tick();assert(not f.host.disabled,table.concat(f.logs,'\n'))
        local record=f.read(f.record,0x1f8)
        local xyz=ffi.cast('float *',f.record+0x1c)
        local x,y,z=tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])
        local category=Layout.u32(record,0x64)
        local line=f.logs[#f.logs];local stage=line:match(';stage=([^;]+)')
        assert(stage,line);seen[stage]=true
        assert(Layout.u32(record,0x188)==1000000 and record:byte(0x79)==1)
        if stage=='attack' then
            assert(category==0x80000001 and native.fixture_consume_point(x,y,z)==1)
            finished=true;break
        end
        assert(category==0 and native.fixture_consume_point(x,y,z)==0)
        if stage=='out' then assert(z+0.25>=315-0.001) end
        f.position={x,y,z+0.25}
    end
    -- Exterior descent may already be complete when the side corridor is reached.
    assert(finished and seen.out and seen.around and seen.under and seen.attack)
    assert(native.fixture_bad_args()==0)
end)
test('native reselection of the same Titan keeps route progress; transit can return to small filtering',function()
    local f=fixture();f.position={100,200,315};f.select(G60TitanFixture.profile.resource);f.host:tick()
    local xyz=ffi.cast('float *',f.record+0x1c)
    f.position={tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])+0.25}
    f.select(G60TitanFixture.profile.resource);f.host:tick()
    assert(f.logs[#f.logs]:find(';stage=around;',1,true),table.concat(f.logs,'\n'))
    assert(Layout.u32(f.read(f.record,0x1f8),0x64)==0)
    f.select('be39e313a1e46bb9');f.host:tick();f.host:tick()
    assert(native.fixture_orbits()==2 and not f.host.disabled)
end)
test('Titan disappears: clear waypoint and orbit until a Charger is selected',function()
    local f=fixture();f.select(G60TitanFixture.profile.resource);f.host:tick()
    f.titan.maps[f.titan.entity]=string.rep('\0',24)
    f.host:tick();f.host:tick()
    assert(native.fixture_points()==1 and native.fixture_clears()==2 and native.fixture_orbits()==2,table.concat(f.logs,'\n'))
    assert(f.read(f.record+0x78,1)=='\0' and not f.host.disabled)
    f.select('1a7fcdff98c664b0');f.host:tick()
    assert(native.fixture_points()==1 and native.fixture_orbits()==2)
end)
test('Titan death after point guidance clears the old waypoint without resetting the fuse',function()
    local f=fixture();f.select(G60TitanFixture.profile.resource);f.host:tick()
    native.fixture_mode(5);f.host:tick()
    assert(native.fixture_points()==1 and native.fixture_validations()==2 and native.fixture_orbits()==1)
    assert(Layout.u32(f.read(f.record,0x1f8),0x188)==1000000 and not f.host.disabled)
end)
test('Titan observation interruption retains cleanup state, but foreign ownership forbids calls',function()
    local f=fixture();f.select(G60TitanFixture.profile.resource);f.host:tick()
    f.ready=false;f.host:tick();f.ready=true
    f.titan.maps[f.titan.generations+3]='\8';f.owned=false;f.host:tick()
    assert(native.fixture_clears()==0 and native.fixture_points()==1)
    f.owned=true;f.host:tick();assert(native.fixture_clears()==1 and native.fixture_orbits()==1)
end)
test('Titan rejects dead targets and unavailable bones without replacing original selection',function()
    local f=fixture(5);f.select(G60TitanFixture.profile.resource);f.host:tick()
    assert(native.fixture_points()==0 and native.fixture_clears()==0 and native.fixture_validations()==1)
    f=fixture();f.select(G60TitanFixture.profile.resource);f.titan.maps[f.titan.names]=string.rep('\0',700)
    f.host:tick();assert(native.fixture_points()==0 and native.fixture_validations()==0)
    assert(Layout.u32(f.read(f.record,0x1f8),0x18)==521)
end)
test('Titan hands the same grenade back to small filtering and allowed targets',function()
    local f=fixture();f.select(G60TitanFixture.profile.resource);f.host:tick()
    f.select('a1f37bf2a40fbde4');f.host:tick();f.host:tick()
    assert(native.fixture_points()==1 and native.fixture_orbits()==2)
    f.select('1a7fcdff98c664b0');f.host:tick()
    assert(native.fixture_points()==1 and native.fixture_orbits()==2 and not f.host.disabled)
end)
test('Titan failed setter or timer change disables further native operations',function()
    for _,mode in ipairs({6,7}) do
        local f=fixture(mode);f.select(G60TitanFixture.profile.resource);f.host:tick();f.host:tick()
        assert(f.host.disabled and native.fixture_points()==1 and native.fixture_orbits()==0,table.concat(f.logs,'\n'))
    end
end)
test('runtime excludes Hive Guard then releases the same grenade to a Charger',function()
    local f=fixture();f.select('a1f37bf2a40fbde4')
    f.host:tick();f.host:tick()
    assert(native.fixture_clears()==1 and native.fixture_orbits()==2 and f.host.applied==2)
    f.select('1a7fcdff98c664b0');f.host:tick();f.host:tick()
    assert(native.fixture_clears()==1 and native.fixture_orbits()==2 and not f.host.disabled)
    f.select('a1f37bf2a40fbde4');f.host:tick()
    assert(native.fixture_clears()==2 and native.fixture_orbits()==3 and native.fixture_bad_args()==0)
end)
test('runtime skips other targets, foreign ownership and unready observations',function()
    for _,mutate in ipairs({function(f) f.resource='ffffffffffffffff' end,
        function(f) f.owned=false end,function(f) f.ready=false end}) do
        local f=fixture();mutate(f);f.host:tick()
        assert(native.fixture_clears()==0 and native.fixture_orbits()==0 and f.host.applied==0)
    end
end)
test('partial native failure disables future runtime calls',function()
    local f=fixture(2);f.host:tick();f.host:tick()
    assert(f.host.disabled and native.fixture_clears()==1 and native.fixture_orbits()==0)
end)
test('installed update preserves nil returns, calls once and restores its callback on stop',function()
    local f,Runtime=fixture();local old_calls=0
    local old=function(...) old_calls=old_calls+1;assert(select('#',...)==3);return nil,7,nil end
    local globals={update=old};local closed=0
    local stop=Runtime.install(globals,f.host,function() closed=closed+1 end)
    local function verify(...) assert(select('#',...)==3);local a,b,c=...;assert(a==nil and b==7 and c==nil) end
    verify(globals.update(1,nil,3))
    assert(old_calls==1 and native.fixture_orbits()==1)
    stop();stop();assert(globals.update==old and closed==1)
end)
test('original update error propagates and does not run control; later wrapper is retained',function()
    local f,Runtime=fixture();local marker={}
    local globals={update=function() error(marker) end}
    local stop=Runtime.install(globals,f.host)
    local ok,err=pcall(globals.update);assert(not ok and err==marker and native.fixture_orbits()==0)
    local later=function() end;globals.update=later;stop();assert(globals.update==later)
end)
test('assembled addon refuses absent game and leaves the existing callback intact',function()
    local old=function() return nil,7,nil end
    update=old
    CowboyBingusModLoader={api=1,open_log=function(name)
        assert(name=='G60SmartTargeting.log');return assert(io.open(G60_TEST_LOG,'wb'))
    end}
    G60SmartTargeting=nil
    local state=assert(loadfile(G60_ENTRY))()
    assert(not state.filter_enabled and state.state:find('game module unavailable',1,true))
    assert(update==old and state.native_lifetime_verified==false and state.designed_targets_only==true)
    assert(state.mark_priority_enabled==false and state.exclusive_targets==true)
end)
test('assembled addon reaches the game guard when optional logging is unavailable',function()
    for _,loader in ipairs({{api=1},{api=1,open_log=function() return nil,'denied' end},
        {api=1,open_log=function() error('denied') end}}) do
        local old=function() end;update=old;CowboyBingusModLoader=loader;G60SmartTargeting=nil
        local state=assert(loadfile(G60_ENTRY))()
        assert(not state.filter_enabled and state.state:find('game module unavailable',1,true),state.state)
        assert(update==old and state.native_lifetime_verified==false)
    end
end)
print('RESULT '..passed..' passed; 0 failed (experimental runtime integration; no game session)')
