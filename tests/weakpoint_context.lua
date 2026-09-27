local ffi=require('ffi')
local Context=require('g60.titan_context')
local common=G60TitanFixture
local profiles=assert(loadfile(G60_WEAKPOINT_PROFILE))()(common.profile)
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(profile)
    local f=common.new();local u32=common.u32
    f.maps[f.entity]=u32(tonumber(profile.resource:sub(9),16))..u32(tonumber(profile.resource:sub(1,8),16))..f.maps[f.entity]:sub(9)
    f.maps[f.graph+0x10]=u32(profile.nodes)
    local hashes={};local aim=profile.aim_hash==profile.boss_hash and 93 or 92
    for i=0,profile.nodes-1 do hashes[#hashes+1]=u32(i==93 and profile.boss_hash or i==94 and profile.belly_hash or i==aim and profile.aim_hash or i) end
    f.maps[f.names]=table.concat(hashes)
    f.maps[f.poses+92*64]=common.matrix(100,202,309)
    function f.capture(prior) return Context.capture(f.read,f.base,f.exe,521,profile,prior) end
    return f,aim
end
test('all seven enemy resources including mapped Behemoth aliases decode, with exact model node counts',function()
    local count=0
    for _,p in pairs(profiles) do
        count=count+1;local f,aim=setup(p);local c=f.capture()
        local anchor=aim==93 and {100,200,308} or {100,202,309}
        for k=1,3 do assert(math.abs(c.point[k]-anchor[k]-p.offset[k])<1e-4) end
        assert(c.profile==p and c.forward and c.validate() and not c.native_lifetime_verified)
        f.maps[f.graph+0x10]=common.u32(p.nodes-1);assert(not pcall(f.capture))
    end
    assert(count==7 and profiles['672f7da17f3ba34a']==nil)
end)
test('Charger head and Behemoth rear anchors follow their respective moving bones',function()
    local count=0
    for _,p in pairs(profiles) do if (p.kind=='head' or p.kind=='rear') then
        count=count+1;local f=setup(p);local old=f.capture()
        f.maps[f.poses+92*64]=common.matrix(nil,nil,nil,{0,1,0,0,-1,0,0,0,0,0,1,0,103,204,310,1})
        assert(not old.validate());local c=f.capture(old)
        assert(math.abs(c.point[1]-(103-p.offset[2]))<1e-4)
        assert(math.abs(c.point[2]-(204+p.offset[1]))<1e-4)
        assert(c.body_center[1]==100)
        f.maps[f.poses+92*64]=common.u32(0x7fc00000)..string.rep('\0',60)
        assert(not pcall(f.capture))
    end end
    assert(count==5)
end)
test('new profile cannot silently accept a different enemy or absent aim bone',function()
    for _,p in pairs(profiles) do
        local f=setup(p);f.maps[f.entity]=common.u64(1)..f.maps[f.entity]:sub(9)
        assert(not pcall(f.capture))
        f=setup(p);f.maps[f.names]=string.rep('\0',p.nodes*4);assert(not pcall(f.capture))
    end
end)
print('RESULT '..passed..' passed; 0 failed (new weakpoint pose decoding; synthetic)')
