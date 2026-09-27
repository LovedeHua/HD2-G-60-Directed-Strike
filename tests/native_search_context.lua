package.path='./src/?.lua;'..package.path
local Context=require('g60.native_search_context')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function fixture()
    local mem={};local f={base=0x10000000,root=0x20000000,entity=0x21000000,
        record=0x22000000,manager=0x23000000,clock=0x24000000,
        motion=0x25000000,actors=0x26000000,orbit=0x27000000,
        movement=0x28000000,speed=0x29000000,config=0x30000020}
    function f.put(a,s) for i=1,#s do mem[a+i-1]=s:byte(i) end end
    function f.zero(a,n) f.put(a,string.rep('\0',n)) end
    function f.u32(a,v)
        local b={};for i=1,4 do b[i]=string.char(v%256);v=math.floor(v/256) end
        f.put(a,table.concat(b))
    end
    function f.ptr(a,v) f.u32(a,v%4294967296);f.u32(a+4,math.floor(v/4294967296)) end
    function f.read(a,n)
        local b={};for i=0,n-1 do
            assert(mem[a+i],string.format('unmapped fixture %x',a+i));b[#b+1]=string.char(mem[a+i])
        end
        return table.concat(b)
    end
    function f.relocate(pointer_address,size)
        local Layout=require('g60.native_observer')
        local old=Layout.pointer(f.read(pointer_address,8),0)
        local copy={}
        for i=0,size-1 do copy[i]=mem[old+i];mem[old+i]=nil end
        for i=0,size-1 do mem[old+4+i]=copy[i] end
        f.ptr(pointer_address,old+4)
    end
    local globals={{0x346bf98,f.root},{0x3326740,f.manager},{0x3326348,f.clock},
        {0x3326508,f.motion},{0x3326d20,f.actors},{0x3326cc8,f.orbit},
        {0x3326418,f.movement},{0x3326460,f.speed}}
    for _,g in ipairs(globals) do f.ptr(f.base+g[1],g[2]) end
    f.u32(f.base+0x3483c20,0);f.ptr(f.clock+0x18,2000000)
    f.zero(f.manager,0x70);f.u32(f.manager+0x20,8);f.u32(f.manager+0x2c,1)
    f.u32(f.manager+0x34,1);f.ptr(f.manager+0x58,f.manager+0x100)
    f.ptr(f.manager+0x100,f.entity);f.ptr(f.manager+0x60,f.record)
    f.zero(f.entity,24);f.u32(f.entity,0x3e55bf62);f.u32(f.entity+4,0x8e325c93)
    f.u32(f.entity+8,547);f.u32(f.entity+16,77)
    f.zero(f.record,0x1f8);f.u32(f.record,4);f.u32(f.record+8,4)
    f.u32(f.record+0x68,547);f.ptr(f.record+0x188,1000000)
    local function hash(manager,offset,entries)
        local p=manager+0x1000;f.ptr(manager+offset,p)
        f.u32(manager+offset+8,8);f.u32(manager+offset+12,0)
        f.u32(manager+offset+16,1);f.zero(p,64)
        for _,e in ipairs(entries) do
            local slot=e[1]%8
            while f.read(p+slot*8,4)~='\0\0\0\0' do slot=(slot+1)%8 end
            f.u32(p+slot*8,e[1]);f.u32(p+slot*8+4,e[2])
        end
    end
    hash(f.motion,0x40,{{547,0},{123,1}})
    f.ptr(f.motion+0x68,f.motion+0x2000)
    f.zero(f.motion+0x2000+0x2e0,12);f.zero(f.motion+0x2000+0x308+0x2e0,12)
    f.u32(f.actors+0x70,2);f.ptr(f.actors+0x110,0)
    f.ptr(f.actors+0x118,f.actors+0x200);f.zero(f.actors+0x200,24)
    f.u32(f.actors+0x208,123)
    hash(f.orbit,0x80,{{547,0}});f.ptr(f.orbit+0xa0,f.orbit+0x2000)
    f.zero(f.orbit+0x2000,8);f.put(f.orbit+0x2004,'\2')
    f.ptr(f.root+0xf124c8,f.config);f.zero(f.config-32,152)
    f.u32(f.config-32,10);f.u32(f.config-28,0xc9500230);f.put(f.config-24,'LDLD')
    f.u32(f.config-20,1);f.u32(f.config-16,0xc9500230);f.u32(f.config-12,120)
    f.u32(f.config-8,1)
    -- Independently calculated resource % 6 == 0; third value is at 112.
    f.u32(f.config,0x3e55bf62);f.u32(f.config+4,0x8e325c93)
    f.u32(f.config+8,2);f.u32(f.config+112,3)
    hash(f.movement,0x30,{{547,0}});f.ptr(f.movement+0x50,f.movement+0x2000)
    f.zero(f.movement+0x2000,0xa8);f.u32(f.movement+0x2008,0xffffffff)
    hash(f.speed,0x30,{{547,0}});f.ptr(f.speed+0x48,f.speed+0x1800)
    f.ptr(f.speed+0x1800,f.entity);f.ptr(f.speed+0x50,f.speed+0x2000)
    f.ptr(f.speed+0x60,f.speed+0x3000)
    f.u32(f.speed+0x250c,0x41200000);f.u32(f.speed+0x3008,0x41200000)
    function f.observed() return {index=0,identity_bytes=f.read(f.entity,24),record_bytes=f.read(f.record,0x1f8)} end
    function f.capture() return Context.capture(f.read,f.base,f.observed()) end
    return f
end
test('native dependency graph resolves collisions and skips null anchor slots',function()
    local f=fixture();local r=f.capture()
    assert(r.entity_address==f.entity and r.state_address==f.record+8)
    assert(r.orbit_anchor.id==123 and r.orbit_slot==2 and r.orbit_divisor==3)
    assert(r.selection.cleared and r.network_entity_index==77 and not r.path_agent_present)
    assert(not r.control_allowed and not r.native_lifetime_verified and not r.external_effects_verified)
end)
test('live-log case: invalid ID with active guidance flag is not cleared',function()
    local f=fixture();f.put(f.record+0x78,'\1');local r=f.capture()
    assert(r.selection.stale_flag and not r.selection.has_target and r.selection.needs_clear)
end)
test('cached ID and candidate flags must also be cleared',function()
    for _,o in ipairs({0x60,0x70}) do
        local f=fixture();f.u32(f.record+o,1);assert(not f.capture().selection.cleared)
    end
end)
test('same-slot recycled projectile cannot reuse an observation',function()
    local f=fixture();local old=f.observed();f.u32(f.entity+8,548)
    local ok,err=pcall(Context.capture,f.read,f.base,old)
    assert(not ok and tostring(err):find('stale observation',1,true))
end)
test('missing orbit component refuses the native invalid-index dereference',function()
    local f=fixture();f.u32(f.orbit+0x1000+3*8+4,0xffffffff)
    local ok,err=pcall(f.capture);assert(not ok and tostring(err):find('missing orbit component',1,true))
end)
test('invalid dependency pointer identifies its field without dereferencing it',function()
    for _,value in ipairs({0,0x25002002}) do
        local f=fixture();f.ptr(f.motion+0x68,value)
        local original=f.read
        f.read=function(a,n)
            assert(a~=value,'invalid pointer was followed')
            return original(a,n)
        end
        local ok,err=pcall(f.capture)
        assert(not ok and tostring(err):find('search pointer motion records value=',1,true))
        assert(tostring(err):find('pointer bound',1,true))
    end
end)
test('native four-byte array allocations are accepted without weakening entity pointers',function()
    local f=fixture()
    for _,row in ipairs({{f.motion+0x40,64},{f.orbit+0x80,64},
        {f.movement+0x30,64},{f.speed+0x30,64},{f.motion+0x68,0x610},
        {f.orbit+0xa0,8},{f.speed+0x50,0x534},{f.speed+0x60,0x38}}) do
        f.relocate(row[1],row[2])
    end
    local r=f.capture()
    assert(r.orbit_anchor.id==123 and r.orbit_divisor==3)
    assert(r.speed_address%8==0 and r.speed_mirror_address%8==4)
    assert(not r.control_allowed and not r.native_lifetime_verified)
    f.ptr(f.manager+0x100,f.entity+4)
    local ok,err=pcall(f.capture)
    assert(not ok and tostring(err):find('search pointer behavior entity',1,true))
end)
test('no anchor refuses a helper that would silently return without moving',function()
    local f=fixture();f.u32(f.actors+0x70,0)
    local ok,err=pcall(f.capture);assert(not ok and tostring(err):find('no native orbit anchor',1,true))
end)
test('zero divisor and incompatible config header are rejected',function()
    local f=fixture();f.u32(f.config+112,0);assert(not pcall(f.capture))
    f=fixture();f.u32(f.config-12,128);assert(not pcall(f.capture))
end)
test('0.5.0 live failure: packed orbit config at 0x332aee584 is four-byte aligned',function()
    local f=fixture()
    local packed=f.read(f.config-32,152)
    local actual=0x332aee584
    f.put(actual-32,packed);f.ptr(f.root+0xf124c8,actual)
    local r=f.capture()
    assert(r.orbit_divisor==3 and r.orbit_anchor.id==123 and not r.control_allowed)
    -- Do not trade away the serialized layout validation while fixing alignment.
    f.u32(actual-12,128)
    local ok,why=pcall(f.capture)
    assert(not ok and tostring(why):find('orbit config layout',1,true))
end)
test('NaN or infinity anchor coordinates never reach movement preparation',function()
    for _,bits in ipairs({0x7f800000,0x7fc00001,0xff800000}) do
        local f=fixture();f.u32(f.motion+0x2000+0x308+0x2e0,bits);assert(not pcall(f.capture))
    end
end)
test('speed mirror points at the same projectile identity',function()
    local f=fixture();f.ptr(f.speed+0x1800,f.actors+0x200)
    local ok,err=pcall(f.capture);assert(not ok and tostring(err):find('identity mismatch',1,true))
end)
test('future, exact expiry and expired timestamps are rejected',function()
    for _,now in ipairs({999999,31000000,31000001}) do
        local f=fixture();f.ptr(f.clock+0x18,now);assert(not pcall(f.capture))
    end
    local f=fixture();f.ptr(f.clock+0x18,30999999);assert(f.capture())
end)
test('timestamp arithmetic handles low-half rollover',function()
    local f=fixture();f.ptr(f.record+0x188,4294967295);f.ptr(f.clock+0x18,4294967300)
    assert(f.capture().flight_start=='00000000ffffffff')
end)
test('pending behavior events, inactive prefix, source mismatch and wrong weapon refuse preparation',function()
    for _,mutate in ipairs({
        function(f) f.u32(f.manager+8,1) end,
        function(f) f.u32(f.manager+0x34,0) end,
        function(f) f.u32(f.record+0x68,100) end,
        function(f) f.u32(f.entity,0x3e55bf63) end,
        function(f) f.u32(f.entity+20,2) end,
    }) do local f=fixture();mutate(f);assert(not pcall(f.capture)) end
end)
test('changed dependency is rejected after bounded reread',function()
    local f=fixture();local read=f.read;local calls=0
    f.read=function(a,n)
        local b=read(a,n)
        if a==f.speed+0x3008 then calls=calls+1;if calls==1 then f.u32(a,0) end end
        return b
    end
    local ok,err=pcall(f.capture)
    assert(not ok and tostring(err):find('context changed',1,true) and calls==2)
end)
test('experimental future unrelated event no longer pauses the whole scene; strict path stays closed',function()
    local f=fixture();f.ptr(f.manager,0x31000000);f.u32(f.manager+8,1)
    f.zero(0x31000000,16);f.ptr(0x31000000,5000000);f.u32(0x3100000c,999)
    assert(not pcall(f.capture))
    local r=Context.capture(f.read,f.base,f.observed(),nil,{experimental_event_window=true})
    assert(r.pending_event_observation.count==1 and not r.native_lifetime_verified)
end)
test('experimental event gate still refuses own, selected, tracked, due and imminent events',function()
    for _,case in ipairs({{547,5000000},{522,5000000},{523,5000000},{999,2000000},{999,2250000},{0,5000000}}) do
        local f=fixture();f.ptr(f.manager,0x31000000);f.u32(f.manager+8,1)
        f.u32(f.record+0x18,522);f.zero(0x31000000,16);f.ptr(0x31000000,case[2]);f.u32(0x3100000c,case[1])
        assert(not pcall(Context.capture,f.read,f.base,f.observed(),nil,{experimental_event_window=true,target_id=523}))
    end
end)
test('experimental event queue mutation, invalid pointer and oversized queue refuse preparation',function()
    for _,mode in ipairs({'changed','pointer','count'}) do
        local f=fixture();f.ptr(f.manager,mode=='pointer' and 0 or 0x31000000)
        f.u32(f.manager+8,mode=='count' and 257 or 1)
        f.zero(0x31000000,16);f.ptr(0x31000000,5000000);f.u32(0x3100000c,999)
        local read=f.read
        if mode=='changed' then f.read=function(a,n)
            local b=read(a,n);if a==0x31000000 then f.u32(0x3100000c,547) end;return b
        end end
        assert(not pcall(Context.capture,f.read,f.base,f.observed(),nil,{experimental_event_window=true}))
    end
end)
test('malformed hash, out-of-range value and short reads fail closed',function()
    local f=fixture();f.u32(f.motion+0x48,7);assert(not pcall(f.capture))
    f=fixture();f.u32(f.orbit+0x1000+3*8+4,4096);assert(not pcall(f.capture))
    f=fixture();f.u32(f.config+8,3);assert(not pcall(f.capture))
    f=fixture();local old=f.observed()
    assert(not pcall(Context.capture,function() return '' end,f.base,old))
end)
test('ownership uses network index, not projectile or candidate-source ID',function()
    local f=fixture();local session={};local ids={}
    local engine={Network={game_session=function() return session end},GameSession={}}
    engine.GameSession.game_object_exists=function(s,id) assert(s==session);ids[#ids+1]=id;return true end
    engine.GameSession.game_object_owned=function(s,id) assert(s==session);ids[#ids+1]=id;return true end
    local r=Context.capture(f.read,f.base,f.observed(),engine)
    assert(r.ownership.local_ownership_observed and not r.control_allowed and not r.native_lifetime_verified)
    assert(#ids==4);for _,id in ipairs(ids) do assert(id==77 and id~=r.id) end
end)
test('identity changes during supported ownership query invalidate preparation',function()
    local f=fixture();local session={}
    local engine={Network={game_session=function() return session end},GameSession={}}
    engine.GameSession.game_object_exists=function() return true end
    engine.GameSession.game_object_owned=function() f.u32(f.entity+8,548);return true end
    local ok,err=pcall(Context.capture,f.read,f.base,f.observed(),engine)
    assert(not ok and tostring(err):find('context changed',1,true))
end)
print(string.format('RESULT %d passed; %d failed (synthetic native layouts, no game calls)',passed,failed))
if failed>0 then os.exit(1) end
