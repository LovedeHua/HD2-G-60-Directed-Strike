-- Multiple owned native projectiles; synthetic world/pose observations, real C setters.
local ffi=require('ffi')
ffi.cdef[[void *fixture_entity_at(unsigned);void *fixture_record_at(unsigned);void *fixture_movement_at(unsigned);
void *fixture_fuse_state_at(unsigned);void *fixture_fuse_network_at(unsigned);]]
local native=ffi.load(G60_FIXTURE_DLL)
local L=require('g60.native_observer')
local Search=require('g60.native_search_context')
local Priority=require('g60.native_priority')
local Reservations=require('g60.target_reservations')
local catalog=assert(loadfile(G60_PRIORITY_CATALOG))()
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function addr(p) return tonumber(ffi.cast('uintptr_t',p)) end
local function resource(f,id,key)
    local offset=(id-521)*24
    f.u32(f.identities,offset,tonumber(key:sub(9),16));f.u32(f.identities,offset+4,tonumber(key:sub(1,8),16))
end
local function setup(count,structure_profiles)
    local f=G60ArrivalWindows.setup();f.source_count=count or 3
    f.exclusive_targets=true;f.mark_priority_enabled=false;f.designed_targets_only=true
    f.structure_profiles=structure_profiles
    f.weakpoint_profiles=G60WeakpointWindows.profiles;f.priority_catalog=catalog
    f.titan_standoff=2.5;f.titan_arrival_region={radius=1.75,depth=0.8}
    resource(f,525,'3aff5fd7d5450b99');resource(f,526,'960b48a421a3faaa')
    local read=f.read;local spans={}
    for i=0,3 do
        assert(addr(native.fixture_entity_at(i))==f.source.address+i*24)
        assert(addr(native.fixture_record_at(i))==f.source.record+i*0x1f8)
        for _,v in ipairs({{native.fixture_entity_at(i),24},{native.fixture_record_at(i),0x1f8},
            {native.fixture_movement_at(i),0xa8},{native.fixture_fuse_state_at(i),64},{native.fixture_fuse_network_at(i),56}}) do
            spans[#spans+1]={addr(v[1]),v[2]}
        end
    end
    f.read=function(a,n)
        for _,s in ipairs(spans) do if a>=s[1] and a+n<=s[1]+s[2] then return ffi.string(ffi.cast('const char *',a),n) end end
        return read(a,n)
    end
    local entities={[521]=0,[522]=1,[523]=2,[524]=3,[525]=4,[526]=5,[600]=6,[601]=7}
    local sources={};for i=0,f.source_count-1 do entities[547+i]=8+i;sources[547+i]=i end
    f.hash(f.block(f.root+0xf1aeb0,20),0,0x38000000,entities)
    local units=f.maps[0x30001000][1]
    for i=0,f.source_count-1 do f.u64(units,(9+i)*8,0x40000900+i*0x100) end
    local ex=f.maps[0x42000000][1];f.u32(ex,0x24,f.source_count)
    f.hash(ex,0x38,0x42002000,sources)
    local ep=f.block(0x42001000,8*f.source_count)
    for i=0,f.source_count-1 do f.u64(ep,i*8,f.source.address+i*24) end
    local cm=f.maps[0x36000000][1];f.u32(cm,0x20,f.source_count)
    f.hash(cm,0x30,0x38002000,sources)
    local cp=f.block(0x38003000,8*f.source_count)
    for i=0,f.source_count-1 do f.u64(cp,i*8,f.source.address+i*24) end
    local candidates=f.block(0x37000000,0x13f8*f.source_count)
    function f.candidates_for(index,list)
        local b=candidates+index*0x13f8;ffi.fill(b,0x13f8)
        f.u32(b,0x310,#list)
        for i,row in ipairs(list) do
            local id,score=type(row)=='table' and row[1] or row,type(row)=='table' and row[2] or 1
            local r=b+0x318+(i-1)*80
            f.u32(r,0,id);f.float(r,4,10);f.float(r,0x44,score);f.u32(r,0x48,1);f.u32(r,0x4c,1)
        end
    end
    function f.candidates_all(list) for i=0,f.source_count-1 do f.candidates_for(i,list) end end
    function f.record_at(i) return ffi.cast('uint8_t *',native.fixture_record_at(i)) end
    function f.select_at(i,id)
        local r=f.record_at(i);f.u32(r,0x18,id);f.u32(r,0x70,id);r[0x78]=id==0 and 0 or 1;f.u32(r,0x64,1)
    end
    function f.scope(index)
        index=index or 0
        local e,r=f.source.address+index*24,f.source.record+index*0x1f8
        local record=f.read(r,0x1f8)
        local c={entity_address=e,state_address=r+8,identity_bytes=f.read(e,24),record_bytes=record,
            movement_address=addr(native.fixture_movement_at(index)),selection=Search.selection(record,0),
            ownership={local_ownership_observed=f.owned},own_position_bytes=ffi.string(ffi.new('float[3]',f.position),12),
            time_hex=L.hex64(ffi.string(f.clock+0x18,8),0),flight_start=L.hex64(record,0x188)}
        return {experimental=true,native_lifetime_verified=false,reference_is_observation_key=true,
            prepared=c,calls=f.calls,read=f.read,invalid_id=0,validate=function() return f.ready end}
    end
    f.candidates_all({521,522,523,524,525,526})
    G60PriorityWindows.runtime(f)
    function f.locked(i,id)
        return table.concat(f.logs,'\n'):find('priority_locked;entity='..(547+i)..';target='..id..';',1,true)~=nil
    end
    function f.check()
        assert(not f.host.disabled and native.fixture_bad_args()==0,table.concat(f.logs,'\n'))
        for _,line in ipairs(f.logs) do assert(not line:find('frame_error',1,true),line) end
    end
    return f
end

test('generated exact ranks match the requested chain including Dragonroach and every Behemoth',function()
    for _,case in ipairs({{'9e2e17f2ccccafdd',10},{'960b48a421a3faaa',10},{'dcf8e74212fbee3b',20},
        {'6b202392f4ab605e',30},{'3aff5fd7d5450b99',40},{'a05bd1ec67b3ac4c',40},
        {'fd5247653c897803',40},{'1a7fcdff98c664b0',50}}) do assert(catalog[case[1]].rank==case[2]) end
end)
test('three simultaneous grenades split Titan, Dragonroach and Impaler despite lower-priority marks',function()
    local f=setup();f.ping(0,522);f.reverse=true;f.host:tick();f.check()
    assert(f.locked(0,521) and f.locked(1,526) and f.locked(2,523),table.concat(f.logs,'\n'))
    for i=0,2 do assert(L.u32(f.read(f.source.record+i*0x1f8,0x1f8),0x188)==1000000) end
    assert(not table.concat(f.logs,'\n'):find('ping_queue',1,true) and native.fixture_explosions()==0)
end)
test('remaining chain splits Spore, Behemoth and ordinary Charger',function()
    local f=setup();f.candidates_all({{522,1000},{525,100},{524,1}});f.host:tick();f.check()
    assert(f.locked(0,524) and f.locked(1,525) and f.locked(2,522),table.concat(f.logs,'\n'))
end)
test('equal-rank score picks Dragonroach first and valid locks survive candidate score changes',function()
    local f=setup(2);f.candidates_all({{521,1},{526,9}});f.host:tick();f.check()
    assert(f.locked(0,526) and f.locked(1,521))
    f.logs={};f.candidates_all({{521,100},{526,1}});f.host:tick();f.check()
    assert(not f.locked(0,521) and not f.locked(1,526))
end)
test('all occupied targets clear vanilla selections to orbit; disappearance frees same-frame acquisition',function()
    local f=setup(2);f.candidates_all({521});f.host:tick();f.check()
    assert(f.locked(0,521) and not f.locked(1,521) and native.fixture_orbits()==1,table.concat(f.logs,'\n'))
    local r=f.read(f.source.record+0x1f8,0x1f8);assert(L.u32(r,0x18)==0 and r:byte(0x79)==0)
    f.select_at(1,521);f.host:tick();f.check();assert(not f.locked(1,521) and native.fixture_orbits()==2)
    f.absent={[0]=true};f.host:tick();f.check();assert(f.locked(1,521),table.concat(f.logs,'\n'))
end)
test('three waiting grenades see a Titan together and only one leaves orbit, including native reselection',function()
    local f=setup(3);f.candidates_all({})
    for i=0,2 do f.select_at(i,0) end
    for _=1,3 do f.host:tick();f.check() end
    assert(f.host.aimed==0 and native.fixture_orbits()>=9 and native.fixture_explosions()==0)
    f.candidates_all({521});f.reverse=true
    for turn=1,3 do
        -- Model all three original seekers choosing the newly visible Titan
        -- between Lua callbacks, including retries after our previous clear.
        for i=0,2 do f.select_at(i,521) end
        local aimed,orbits=f.host.aimed,native.fixture_orbits()
        f.host:tick();f.check()
        assert(f.host.aimed==aimed+1 and native.fixture_orbits()==orbits+2,table.concat(f.logs,'\n'))
        assert(f.locked(0,521) and not f.locked(1,521) and not f.locked(2,521))
        for i=1,2 do
            local r=f.read(f.source.record+i*0x1f8,0x1f8)
            assert(L.u32(r,0x18)==0 and r:byte(0x79)==0 and L.u32(r,0x188)==1000000)
        end
    end
    f.absent={[0]=true};local aimed=f.host.aimed;f.host:tick();f.check()
    assert(f.host.aimed==aimed+1 and f.locked(1,521) and not f.locked(2,521))
    assert(native.fixture_explosions()==0)
end)
test('inactive guidance and state five do not release the existing grenade reservation',function()
    for _,change in ipairs({function(f) f.inactive={[0]=true} end,function(f) f.u32(f.record_at(0),8,5) end}) do
        local f=setup(2);f.candidates_all({521});f.host:tick();change(f);f.host:tick();f.check()
        assert(not f.locked(1,521),table.concat(f.logs,'\n'))
        f.absent={[0]=true};f.host:tick();f.check();assert(f.locked(1,521))
    end
end)
test('detonation request retains reservation until the projectile actually disappears',function()
    local f=setup(2);f.candidates_all({521});f.position={10,0,3.5};f.host:tick();f.check()
    assert(native.fixture_explosions()==1 and not f.locked(1,521),table.concat(f.logs,'\n'))
    f.host:tick();f.check();assert(native.fixture_explosions()==1 and not f.locked(1,521))
    f.absent={[0]=true};f.host:tick();f.check();assert(f.locked(1,521) and native.fixture_explosions()==2)
end)
test('pending expiry removal retains reservation until disappearance',function()
    local f=setup(2);f.candidates_all({521});f.host:tick()
    f.u64(f.clock,0x18,31000000);f.u64(f.record_at(1),0x188,29000000)
    f.host:tick();f.check()
    assert(tonumber(ffi.cast('uint32_t *',native.fixture_retire_count())[0])==1 and not f.locked(1,521))
    f.absent={[0]=true};f.host:tick();f.check();assert(f.locked(1,521) and native.fixture_explosions()==0)
end)
test('loss of a usable weakpoint releases guidance but not the live grenade reservation',function()
    local f=setup(2);f.candidates_all({521});f.host:tick();f.pose_missing=true
    f.host:tick();f.host:tick();f.check();assert(not f.locked(1,521),table.concat(f.logs,'\n'))
    f.pose_missing=false;f.absent={[0]=true};f.host:tick();f.check();assert(f.locked(1,521))
end)
test('skipped readiness and failed observation cannot release a reservation',function()
    for _,field in ipairs({'ready','observe_error'}) do
        local f=setup(2);f.candidates_all({521});f.host:tick();f.absent={[0]=true}
        f[field]=field~='ready';f.host:tick()
        f[field]=field=='ready';f.absent=nil;f.logs={};f.host:tick();f.check()
        assert(not f.locked(1,521))
    end
end)
test('reservation rejects an old competing lock and every native fallback selection',function()
    local f=setup(2);local priority=Priority.new(f);local book=Reservations.new()
    local owner=Reservations.owner({identity_bytes=f.scope(0).prepared.identity_bytes})
    local first=assert(priority:step(f.scope(0)));book:claim(owner,first.track.identity)
    f.candidates_for(1,{521});local other=Reservations.owner({identity_bytes=f.scope(1).prepared.identity_bytes})
    local result=assert(priority:step(f.scope(1),first.track,nil,nil,function(identity) return book:available(other,identity) end))
    assert(result.kind=='keep' and result.released and native.fixture_bad_args()==0)
end)
print('RESULT '..passed..' passed; 0 failed (exclusive allocation, multiple Windows owned native projectiles)')

G60AllocationWindows={setup=setup,resource=resource}
