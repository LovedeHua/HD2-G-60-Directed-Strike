local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Candidates=require('g60.native_candidates')
local Ping=require('g60.native_ping')
local F={}
function F.new(source)
    local f={base=0x10000000,exe=0x140000000,maps={},positions={},entities={}}
    local root,um,units,gens,motion,mp,actors,ring,clock,cm,cr=source and source.root or 0x20000000,0x30000000,0x30001000,0x30002000,0x31000000,0x32000000,0x33000000,0x34000000,0x35000000,0x36000000,0x37000000
    function f.block(a,n) local b=ffi.new('uint8_t[?]',n);f.maps[a]={b,n};return b end
    function f.u32(b,o,v) ffi.cast('uint32_t *',b+o)[0]=v end
    function f.u64(b,o,v) ffi.cast('uint64_t *',b+o)[0]=v end
    function f.float(b,o,v) ffi.cast('float *',b+o)[0]=v end
    local function ptr(a,v) f.u64(f.block(a,8),0,v) end
    function f.read(a,n)
        for start,row in pairs(f.maps) do if a>=start and a+n<=start+row[2] then return ffi.string(row[1]+a-start,n) end end
        if source and a>=source.address and a+n<=source.address+24 then return ffi.string(ffi.cast('const char *',a),n) end
        if source and a>=source.record and a+n<=source.record+0x1f8 then return ffi.string(ffi.cast('const char *',a),n) end
        error(string.format('unmapped priority read %x %x',a,n))
    end
    function f.hash(header,offset,address,rows)
        f.u64(header,offset,address);f.u32(header,offset+8,64);f.u32(header,offset+12,0xffffffff);f.u32(header,offset+16,1)
        local entries=f.block(address,64*8)
        for i=0,63 do f.u32(entries,i*8,0xffffffff) end
        for id,index in pairs(rows) do f.u32(entries,(id%64)*8,id);f.u32(entries,(id%64)*8+4,index) end
    end
    ptr(f.base+0x346bf98,root);f.u32(f.block(f.base+0x3483c20,4),0,0)
    ptr(f.exe+0x1a100f0,um);local u=f.block(um,0xa8);f.u32(u,0x98,64);f.u64(u,0x88,units);f.u64(u,0xa0,gens)
    local up=f.block(units,64*8);f.generations=f.block(gens,64)
    local resources={'9e2e17f2ccccafdd','1a7fcdff98c664b0','dcf8e74212fbee3b','6b202392f4ab605e','a1f37bf2a40fbde4','d522fd4748d443a5','1111111111111111','1111111111111111'}
    local ids={521,522,523,524,525,526,600,601};local rows={}
    local e=f.block(root+0xf32f18,24*#ids)
    for i,id in ipairs(ids) do
        local o=(i-1)*24;local res=resources[i]
        f.u32(e,o,tonumber(res:sub(9),16));f.u32(e,o+4,tonumber(res:sub(1,8),16));f.u32(e,o+8,id)
        f.u32(e,o+12,i);f.u32(e,o+16,id);f.u64(up,i*8,0x40000000+i*0x100)
        rows[id]=i-1;f.entities[id]=root+0xf32f18+o
    end
    f.root=root
    if source and source.root then rows[547]=8;f.u64(up,9*8,0x40000900) end
    f.identities=e
    f.hash(f.block(root+0xf1aeb0,20),0,0x38000000,rows)
    ptr(f.base+0x3326508,motion);local mh=f.block(motion,0x70);f.u64(mh,0x68,mp)
    f.hash(mh,0x40,0x38001000,rows);local positions=f.block(mp,#ids*0x308)
    for i,id in ipairs(ids) do
        f.positions[id]=positions+(i-1)*0x308+0x2e0
        f.float(f.positions[id],0,id<600 and 10 or 0)
    end
    ptr(f.base+0x3326d20,actors);local ah=f.block(actors,0x190)
    f.u32(ah,0x70,2);f.u64(ah,0x110,f.entities[600]);f.u64(ah,0x118,f.entities[601])
    ptr(f.base+0x347ce30,ring);f.ring=f.block(ring,16+128*0x58);f.ring[0]=1
    ptr(f.base+0x3326348,clock);f.clock=f.block(clock,0x20);f.u64(f.clock,0x18,2000000)
    f.owners={[600]=true}
    f.engine={Network={game_session=function() return 7 end},GameSession={game_object_exists=function() return true end,
        game_object_owned=function(_,id) return f.owners[id]==true end}}
    function f.ping(slot,id,creator,age,duration)
        f.u32(f.ring,12,slot+1)
        local b=f.ring+16+slot*0x58;f.u32(b,0,1);f.float(b,0x10,duration or 10);f.float(b,0x14,age or 0)
        f.u32(b,0x18,creator or 600);f.u32(b,0x20,id)
    end
    ptr(f.base+0x3326548,cm);local ch=f.block(cm,0x58);f.u32(ch,0x20,1)
    f.hash(ch,0x30,0x38002000,{[547]=0});f.u64(ch,0x48,0x38003000);f.u64(ch,0x50,cr)
    ptr(0x38003000,source and source.address or 0x39000000)
    f.candidates=f.block(cr,0x13f8)
    f.source=source or {address=0x39000000}
    if not source then
        local b=f.block(f.source.address,24);f.u32(b,0,0x3e55bf62);f.u32(b,4,0x8e325c93);f.u32(b,8,547)
    end
    function f.candidate(i,id,score)
        f.u32(f.candidates,0x310,i)
        local b=f.candidates+0x318+(i-1)*80
        f.u32(b,0,id);f.float(b,4,10);f.float(b,0x44,score or 1);f.u32(b,0x48,1);f.u32(b,0x4c,1)
    end
    function f.context() return {identity_bytes=f.read(f.source.address,24),entity_address=f.source.address} end
    return f
end
G60PriorityFixture=F
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function data(f) return Data.new(f.read,f.base,f.exe) end
test('candidate reader resolves original eligible rows and excludes nonpositive score',function()
    local f=F.new();f.candidate(1,522,2);f.candidate(2,521,-1)
    local rows=Candidates.capture(data(f),f.context());assert(#rows==1 and rows[1].entity.id==522 and rows[1].score==2)
end)
test('candidate reader rejects oversized list, sparse alias, and foreign source',function()
    local f=F.new();f.u32(f.candidates,0x310,17);assert(not pcall(Candidates.capture,data(f),f.context()))
    f=F.new();f.u32(f.candidates,0x1278+0x48,1);f.u32(f.candidates,0x12c8+0x48,1)
    assert(not pcall(Candidates.capture,data(f),f.context()))
    f=F.new();local c=f.context();c.entity_address=c.entity_address+24;assert(not pcall(Candidates.capture,data(f),c))
end)
test('entity generation and stable rereads reject reused and changed data',function()
    local f=F.new();local d=data(f);local e=d.entity(521);assert(d.unit(e))
    f.generations[1]=1;assert(not d.validate());assert(not pcall(d.unit,e))
end)
test('local mark wins over more recent teammate mark and survives UI expiry',function()
    local f=F.new();f.ping(0,522,600,2);f.ping(1,521,601,0)
    local p=Ping.new(f);local m,why=p:observe();assert(m and m.id==522 and m.current,tostring(why))
    f.float(f.ring+16,0x14,11);m=p:observe();assert(m and m.id==522 and not m.current)
    f.u64(f.clock,0x18,90000000000);m=p:observe();assert(m and m.id==522,'no arbitrary memory TTL')
end)
test('new mark leads history; UI expiry does not move older visible marks ahead',function()
    local f=F.new();f.ping(0,522,600,1);local p=Ping.new(f);assert(p:observe().id==522)
    f.ping(1,521,600,0);assert(p:observe().id==521)
    f.float(f.ring+16+0x58,0x14,11);local m=p:observe()
    -- The still-visible older marker must not replace the latest remembered mark.
    assert(m and m.id==521 and not m.current and #m.queue==2 and m.queue[2].id==522)
    p:forget(m.identity);assert(p:observe().id==522)
end)
test('invalid unit, distance, ownership ambiguity, UI reset and clock rewind expire memory',function()
    for _,change in ipairs({function(f) f.generations[2]=1 end,
        function(f) f.float(f.positions[522],0,201) end,
        function(f) f.owners[601]=true end,function(f) f.ring[0]=0 end,
        function(f) f.u64(f.clock,0x18,1);f.u32(f.ring,12,0) end}) do
        local f=F.new();f.ping(0,522);local p=Ping.new(f);assert(p:observe())
        change(f);assert(p:observe()==nil)
    end
end)
test('forgotten dead mark stays forgotten until refreshed',function()
    local f=F.new();f.ping(0,522,600,2);local p=Ping.new(f);local m=p:observe();p:forget(m.identity)
    f.float(f.ring+16,0x14,3);assert(p:observe()==nil)
    f.float(f.ring+16,0x14,0);assert(p:observe().id==522)
end)
print('RESULT '..passed..' passed; 0 failed (synthetic priority data and Ping ring)')
