-- Synthetic engine layout checks using the production read-only decoder.
local ffi=require('ffi')
local Context=require('g60.titan_context')
local profile=assert(loadfile(G60_TITAN_PROFILE))()
local function bytes(ctype,v,n) return ffi.string(ffi.new(ctype,v),n) end
local function u32(v) return bytes('uint32_t[1]',v,4) end
local function u64(v) return bytes('uint64_t[1]',v,8) end
local function matrix(x,y,z,rotation)
    return bytes('float[16]',rotation or {1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1},64)
end
local function fixture()
    local base,exe,root=0x10000000,0x140000000,0x20000000
    local entries,manager,units,generations,unit,vtable=0x30000000,0x31000000,0x32000000,0x33000000,0x34000000,0x35000000
    local graph,names,poses,bridge,api=0x36000000,0x37000000,0x38000000,0x39000000,0x3a000000
    local accessor,access
    for k,v in pairs(profile.getters) do if v[2] then accessor=k;access=v;break end end
    assert(accessor)
    local entity=root+0xf32f18+2*24
    local handle=7*0x400000+3
    local maps={
        [base+0x346bf98]=u64(root),[root+0xf1aeb0]=u64(entries)..u32(8)..u32(0)..u32(1),
        [entries+8]=u32(521)..u32(2),
        [entity]=u32(0xccccafdd)..u32(0x9e2e17f2)..u32(521)..u32(handle)..u32(99)..u32(0),
        [exe+0x1a100f0]=u64(manager),[manager+0x98]=u32(16),[manager+0x88]=u64(units),
        [manager+0xa0]=u64(generations),[generations+3]=string.char(7),[units+24]=u64(unit),
        [unit]=u64(vtable),[vtable+0xe8]=u64(exe+accessor),
        [exe+accessor]=access[3]:gsub('..',function(s) return string.char(tonumber(s,16)) end),
        [unit+access[1]]=u64(graph),[graph+0x10]=u32(175),[graph+0x40]=u64(names),[graph+0x28]=u64(poses),
        [poses]=matrix(100,200,300),[poses+93*64]=matrix(100,200,308),
        [base+0x3326308]=u64(bridge),[bridge+0x18]=u64(api),[api+0x720]=u64(exe+profile.alive_rva),
    }
    local n={};for i=0,174 do n[#n+1]=u32(i==93 and profile.boss_hash or i==94 and profile.belly_hash or i) end
    maps[names]=table.concat(n)
    local f={maps=maps,base=base,exe=exe,profile=profile,entity=entity,unit=unit,graph=graph,names=names,poses=poses,
        generations=generations,manager=manager,vtable=vtable,accessor=exe+accessor}
    function f.read(a,n)
        for start,s in pairs(maps) do if a>=start and a+n<=start+#s then return s:sub(a-start+1,a-start+n) end end
        error(string.format('unmapped synthetic Titan read %x %d',a,n))
    end
    function f.capture(old) return Context.capture(f.read,base,exe,521,profile,old) end
    return f
end
G60TitanFixture={new=fixture,u32=u32,u64=u64,matrix=matrix,profile=profile}
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('Titan bounded pose chain computes an anchor-local point',function()
    local f=fixture();local c=f.capture()
    for i=1,3 do assert(math.abs(c.point[i]-({100,200,308})[i]-profile.offset[i])<1e-5) end
    assert(c.boss==93 and c.belly==94 and c.validate() and not c.native_lifetime_verified)
end)
test('Titan point follows body translation and rotation',function()
    local f=fixture();local a=f.capture()
    f.maps[f.poses+93*64]=matrix(nil,nil,nil,{0,1,0,0,-1,0,0,0,0,0,1,0,102,203,308,1})
    assert(not a.validate());local b=f.capture(a)
    assert(math.abs(b.point[1]-(102-profile.offset[2]))<1e-5)
    assert(math.abs(b.point[2]-(203+profile.offset[1]))<1e-5)
end)
test('Titan missing/reused identity or Unit generation is rejected',function()
    for _,mutate in ipairs({function(f) f.maps[f.entity]=string.rep('\0',24) end,
        function(f) f.maps[f.generations+3]='\8' end,
        function(f) f.maps[f.manager+0x98]=u32(2) end}) do
        local f=fixture();mutate(f);assert(not pcall(f.capture))
    end
    local f=fixture();local prior=f.capture();local s=f.maps[f.entity]
    f.maps[f.entity]=s:sub(1,16)..u32(100)..s:sub(21);assert(not pcall(f.capture,prior))
end)
test('Titan unknown getter, missing bone and NaN pose fail closed',function()
    for _,mutate in ipairs({function(f) f.maps[f.vtable+0xe8]=u64(f.exe+0x123456) end,
        function(f) f.maps[f.names]=string.rep('\0',700) end,
        function(f) f.maps[f.poses+93*64]=u32(0x7fc00000)..string.rep('\0',60) end,
        function(f) f.maps[f.graph+0x10]=u32(513) end,
        function(f) f.maps[f.poses+93*64]=matrix(10000,200,308) end}) do
        local f=fixture();mutate(f);assert(not pcall(f.capture))
    end
end)
test('Titan repeat read detects concurrent pose change',function()
    local f=fixture();local old=f.read;local reads=0
    f.read=function(a,n)
        local s=old(a,n)
        if a==f.poses+93*64 then reads=reads+1;if reads>1 then return matrix(105,200,308) end end
        return s
    end
    assert(not pcall(f.capture))
end)
print('RESULT '..passed..' passed; 0 failed (Titan read-only synthetic layout)')
