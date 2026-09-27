local ffi=require('ffi')
ffi.cdef[[void fixture_dead(unsigned);]]
local native=ffi.load(G60_FIXTURE_DLL)
local L=require('g60.native_observer')
local Search=require('g60.native_search_context')
local Priority=require('g60.native_priority')
local Ping=require('g60.native_ping')
local catalog={['9e2e17f2ccccafdd']={rank=10},['dcf8e74212fbee3b']={rank=20},
    ['6b202392f4ab605e']={rank=30},['1a7fcdff98c664b0']={rank=40}}
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(mode)
    native.fixture_reset(mode or 0)
    local function addr(p) return tonumber(ffi.cast('uintptr_t',p)) end
    local f=G60PriorityFixture.new({address=addr(native.fixture_entity()),record=addr(native.fixture_record())})
    f.priority_catalog=catalog;f.calls={clear=ffi.cast('void (*)(void **,const void *)',native.fixture_clear),
        target_valid=ffi.cast('bool (*)(void *,uint32_t,const void *)',native.fixture_target_valid)}
    f.alive=true;f.owned=true;f.pings=Ping.new(f);f.forget_mark=function(id) f.pings:forget(id) end
    f.priority=Priority.new(f)
    function f.select(id)
        ffi.cast('uint32_t *',f.source.record+0x18)[0]=id
        ffi.cast('uint32_t *',f.source.record+0x70)[0]=id
        ffi.cast('uint8_t *',f.source.record+0x78)[0]=id==0 and 0 or 1
    end
    function f.scope()
        local c=f.context();c.record_bytes=f.read(f.source.record,0x1f8);c.state_address=f.source.record+8
        c.selection=Search.selection(c.record_bytes,0);c.ownership={local_ownership_observed=f.owned}
        c.own_position_bytes=string.rep('\0',12)
        return {experimental=true,native_lifetime_verified=false,reference_is_observation_key=true,
            prepared=c,calls=f.calls,read=f.read,invalid_id=0,validate=function() return f.alive end}
    end
    function f.step(lock,mark) local result,reason=f.priority:step(f.scope(),lock,mark);assert(result,reason);return result end
    return f
end
test('native setter chooses Titan over closer-scored Charger and preserves flight timer',function()
    local f=setup();f.select(522);f.candidate(1,522,100);f.candidate(2,521,1)
    local r=f.step();assert(r.track.id==521 and r.reason=='AUTO_PRIORITY_10' and r.changed)
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000 and native.fixture_bad_args()==0)
end)
test('automatic rank chain skips dead Titan, then Impaler, then Spore Charger',function()
    for _,expected in ipairs({523,524,522}) do
        local f=setup();f.select(0)
        f.candidate(1,522,100);if expected<=524 and expected~=522 then f.candidate(2,524,9) end
        if expected==523 then f.candidate(3,523,2);f.candidate(4,521,1);native.fixture_dead(521) end
        assert(f.step().track.id==expected)
    end
end)
test('local current and remembered mark outrank Titan; newer Ping cannot steal existing lock',function()
    local f=setup();f.select(0);f.candidate(1,521,100);f.candidate(2,522,1);f.ping(0,522)
    local r=f.step(nil,f.pings:observe());assert(r.track.id==522 and r.reason=='CURRENT_PING')
    f.float(f.ring+16,0x14,11);f.select(0)
    local nextshot=f.step(nil,f.pings:observe());assert(nextshot.track.id==522 and nextshot.reason=='REMEMBERED_PING')
    f.ping(1,521);f.select(521)
    local locked=f.step(r.track,f.pings:observe());assert(locked.track.id==522 and locked.reason=='LOCKED')
end)
test('lock survives candidate-list loss; invalid lock reselects without flight timer reset',function()
    local f=setup();f.select(0);f.candidate(1,522);local r=f.step()
    f.u32(f.candidates,0x310,0);f.select(521);local same=f.step(r.track);assert(same.track.id==522)
    native.fixture_dead(522);f.candidate(1,521);f.select(522)
    local nextone=f.step(same.track);assert(nextone.track.id==521 and nextone.reason=='AUTO_PRIORITY_10')
    assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
end)
test('marked excluded Hive Guard is still ignored; unknown unmarked keeps native choice',function()
    local f=setup();f.select(525);f.candidate(1,525,100);f.candidate(2,522,1);f.ping(0,525)
    assert(f.step(nil,f.pings:observe()).track.id==522)
    f=setup();f.select(526);f.candidate(1,526);local r=f.step();assert(r.track.id==526 and r.reason=='VANILLA_LOCK' and not r.changed)
end)
test('marked Commander eligible in original candidate list outranks Titan',function()
    local f=setup();f.select(521);f.candidate(1,521);f.candidate(2,526);f.ping(0,526)
    local r=f.step(nil,f.pings:observe())
    assert(r.track.id==526 and r.mark_id==526 and r.mark_current and r.mark_candidate_observed==true)
end)
test('mark outside original candidates cannot force acquisition',function()
    local f=setup();f.select(521);f.candidate(1,521);f.ping(0,522)
    local r=f.step(nil,f.pings:observe())
    assert(r.track.id==521 and r.mark_id==522 and r.mark_candidate_observed==false)
end)
test('reused entity and distant target release the saved lock',function()
    for _,change in ipairs({function(f) f.generations[2]=1 end,function(f) f.float(f.positions[522],0,201) end}) do
        local f=setup();f.select(0);f.candidate(1,522);local r=f.step();change(f)
        f.candidate(2,521);assert(f.step(r.track).track.id==521)
    end
end)
test('dead remembered target is forgotten and does not block automatic selection',function()
    local f=setup();f.select(0);f.candidate(1,521);f.candidate(2,522);f.ping(0,522)
    local mark=f.pings:observe();native.fixture_dead(522)
    assert(f.step(nil,mark).track.id==521);assert(f.pings:observe()==nil)
end)
test('unowned and changed scope forbid calls; partial setter failures disable operation',function()
    for _,change in ipairs({function(f) f.owned=false end,function(f) f.alive=false end}) do
        local f=setup();f.candidate(1,522);change(f)
        assert(not f.priority:step(f.scope()));assert(native.fixture_points()==0)
    end
    for _,mode in ipairs({6,7}) do
        local f=setup(mode);f.select(0);f.candidate(1,522)
        assert(not f.priority:step(f.scope()) and f.priority:disabled())
        assert(not f.priority:step(f.scope()) and native.fixture_points()==1)
    end
end)
local function runtime(f)
    local saved={}
    local function replace(name,value) saved[name]=package.loaded[name];package.loaded[name]=value end
    f.ready=true;f.present=true;f.position={10,0,15};f.logs={}
    local root,manager=f.root or 0x20000000,0x41000000
    f.u64(f.block(f.base+0x3326740,8),0,manager);f.behavior_header=f.block(manager,0x70)
    local source_count=f.source_count or 1
    f.u64(f.behavior_header,0x60,f.source.record);f.u32(f.behavior_header,0x2c,source_count)
    f.u64(f.behavior_header,0x58,0x43000000)
    local sources=f.block(0x43000000,8*source_count)
    for i=0,source_count-1 do f.u64(sources,i*8,f.source.address+i*24) end
    local flags=f.block(root+0xf3f828,3);flags[0]=1
    local oldread=f.read;local movement=tonumber(ffi.cast('uintptr_t',native.fixture_movement()))
    f.read=function(a,n)
        if a>=movement and a+n<=movement+0xa8 then return ffi.string(ffi.cast('const char *',a),n) end
        return oldread(a,n)
    end
    replace('g60.native_observer',setmetatable({capture=function()
        assert(not f.observe_error,'synthetic incomplete observation')
        local matches={}
        for i=0,source_count-1 do
        local c=f.scope(i).prepared;local r=c.record_bytes;local resource
        if c.selection.has_target then
            local d=require('g60.native_target_data').new(f.read,f.base,f.exe)
            resource=d.entity(c.selection.id).resource
        end
        if f.present and not (f.absent and f.absent[i]) then matches[#matches+1]={
            index=i,id=547+i,behavior_id=4,state=L.u32(r,8),native_update_eligible=not (f.inactive and f.inactive[i]),
            identity_bytes=c.identity_bytes,record_bytes=r,flight_start=L.hex64(r,0x188),
            selection_id=c.selection.id,selection_flag=c.selection.flag,selection_resource=resource} end
        end
        if f.reverse then local reversed={};for i=#matches,1,-1 do reversed[#reversed+1]=matches[i] end;matches=reversed end
        return {all_observed_queues_complete=true,update_mode=0,root_flags={1,0,0},matches=matches}
    end},{__index=L}))
    replace('g60.native_readiness',{capture=function() return {engine_main_thread_observed=f.ready,
        world_job_completion=1,context_job_busy=0,context_job_active=0} end})
    replace('g60.native_search_context',{pending_events=Search.pending_events,capture=function(_,_,match)
        local c=f.scope(match.index).prepared;c.movement_address=c.movement_address or movement
        c.own_position_bytes=ffi.string(ffi.new('float[3]',f.position),12);return c
    end})
    -- Pose geometry is synthetic here; the production pose decoder has its own suite.
    replace('g60.titan_context',{capture=function(_,_,_,id,profile,prior)
        assert(not f.pose_missing,'synthetic missing Titan pose')
        local d=require('g60.native_target_data').new(f.read,f.base,f.exe)
        local e=d.entity(id);local unit=d.unit(e)
        assert(not prior or (prior.identity==e.identity and prior.unit==unit))
        local geometry=f.weakpoint_geometry or {}
        return {id=id,address=e.address,identity=e.identity,unit=unit,point=geometry.point or {10,0,6},
            body_center=geometry.body_center or {10,0,8},origin=geometry.origin or {10,0,0},
            right={1,0,0},forward={0,1,0},profile=profile,validate=d.validate}
    end})
    replace('g60.native_titan_aim',nil);f.point_executor=require('g60.native_titan_aim')
    replace('g60.native_priority',nil)
    replace('g60.experimental_runtime',nil)
    local Runtime=require('g60.experimental_runtime')
    f.calls.orbit=ffi.cast('void (*)(void **,float,float,float)',native.fixture_orbit)
    f.titan_profile={resource='9e2e17f2ccccafdd'};f.thread=function() return 328 end
    f.emit=function(line) f.logs[#f.logs+1]=line end
    f.host=Runtime.new(f)
    for name,value in pairs(saved) do package.loaded[name]=value end
    return f
end
test('enabled priority runtime preserves Titan route through repeated native reselection',function()
    local f=setup();f.select(522);f.candidate(1,521);f.candidate(2,522);runtime(f)
    local finished=false
    for i=1,12 do
        f.host:tick();assert(not f.host.disabled,table.concat(f.logs,'\n'))
        local r=f.read(f.source.record,0x1f8)
        assert(L.u32(r,0x18)==0 and r:byte(0x79)==1,table.concat(f.logs,'\n'))
        if L.u32(r,0x64)==1 then finished=true;break end
        local p=ffi.cast('float *',f.source.record+0x1c)
        f.position={tonumber(p[0]),tonumber(p[1]),tonumber(p[2])+0.25}
        f.select(522) -- Native candidate scoring attempts to steal the target.
    end
    assert(finished and f.host.aimed>=4 and native.fixture_bad_args()==0,table.concat(f.logs,'\n'))
end)
test('runtime observes Ping before any grenade and uses it after UI expiration',function()
    local f=setup();f.select(521);f.candidate(1,521);f.candidate(2,522);f.ping(0,522);runtime(f)
    f.present=false;f.host:tick();assert(native.fixture_points()==0)
    f.float(f.ring+16,0x14,11);f.present=true;f.host:tick()
    assert(L.u32(f.read(f.source.record,0x1f8),0x18)==522 and not f.host.disabled,table.concat(f.logs,'\n'))
    assert(table.concat(f.logs,'\n'):find('REMEMBERED_PING',1,true))
end)
test('Ping reader failure leaves automatic priority and small filtering operational',function()
    local f=setup();f.select(525);f.candidate(1,525);runtime(f);f.ring[0]=0;f.host:tick()
    assert(native.fixture_clears()==1 and native.fixture_orbits()==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    f.candidate(2,522);f.select(525);f.host:tick()
    assert(L.u32(f.read(f.source.record,0x1f8),0x18)==522 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
G60PriorityWindows={setup=setup,runtime=runtime,catalog=catalog}
print('RESULT '..passed..' passed; 0 failed (Windows priority native fixture; no game session)')
