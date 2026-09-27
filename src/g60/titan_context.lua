-- Read-only observed target/Unit/pose chain. No lifetime lease is acquired.
local ffi=require('ffi')
local L=require('g60.native_observer')
local M={}
local function mul32(a,b)
    local al,bl=a%65536,b%65536
    return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
end
local function floats(s)
    local a=ffi.new('float[16]');local p=ffi.cast('uint8_t *',a)
    for i=1,#s do p[i-1]=s:byte(i) end
    local out={}
    for i=0,#s/4-1 do
        local v=tonumber(a[i]);assert(v==v and math.abs(v)<1000000,'invalid Titan pose');out[i+1]=v
    end
    return out
end
function M.capture(reader,base,exe,id,profile,previous)
    local guards,total={},0
    local function read(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and a+n<2^47 and n>0 and n<=4096,'Titan read bound')
        total=total+n;assert(total<=32768,'Titan read budget')
        local s=reader(a,n);assert(type(s)=='string' and #s==n,'short Titan read')
        guards[#guards+1]={a,n,s};return s
    end
    local function ptr(a,align) return L.pointer(read(a,8),0,align) end
    local root=ptr(base+0x346bf98)
    local h=read(root+0xf1aeb0,20)
    local entries,cap,empty,mul=L.pointer(h,0,4),L.u32(h,8),L.u32(h,12),L.u32(h,16)
    assert(cap>0 and cap<=1048576 and id~=empty,'Titan entity hash bound')
    local c=cap;while c>1 and c%2==0 do c=c/2 end;assert(c==1,'Titan hash capacity')
    local address
    for probe=0,math.min(cap,256)-1 do
        local row=read(entries+((mul32(id,mul)+probe)%cap)*8,8)
        local key,index=L.u32(row,0),L.u32(row,4)
        if key==empty then break end
        if key==id then
            assert(index<2048,'Titan entity index');address=root+0xf32f18+index*24;break
        end
    end
    assert(address,'Titan disappeared')
    local identity=read(address,24)
    assert(L.u32(identity,8)==id and L.hex64(identity,0)==profile.resource,'Titan identity mismatch')
    if previous then assert(identity==previous.identity,'Titan identity reused') end
    local handle=L.u32(identity,12);assert(handle~=0,'Titan Unit missing')
    local manager=ptr(exe+0x1a100f0)
    local index=handle%0x400000
    local count=L.u32(read(manager+0x98,4),0)
    assert(index<count and count<=0x400000,'Titan Unit index bound')
    assert(read(ptr(manager+0xa0)+index,1):byte()==math.floor(handle/0x400000)%256,'Titan Unit generation changed')
    local unit=ptr(ptr(manager+0x88)+index*8)
    if previous then assert(unit==previous.unit,'Titan Unit replaced') end
    local getter=ptr(ptr(unit)+0xe8)
    local g=assert(profile.getters[getter-exe],'unsupported Titan scenegraph accessor')
    local expected=g[3]:gsub('..',function(v) return string.char(tonumber(v,16)) end)
    assert(read(getter,#expected)==expected,'Titan accessor changed')
    -- Interpret only whitelisted leaf address/load instructions; never execute them.
    local graph=g[2] and ptr(unit+g[1]) or unit+g[1]
    local nodes=L.u32(read(graph+0x10,4),0)
    assert(nodes>=(profile.structure and 1 or 95) and nodes<=512,'Titan scenegraph count')
    if profile.nodes then assert(nodes==profile.nodes,'weakpoint scenegraph variant mismatch') end
    local names=read(ptr(graph+0x40,4),nodes*4)
    local boss,belly,aim
    for i=0,nodes-1 do
        local hash=L.u32(names,i*4)
        if hash==profile.boss_hash then assert(not boss,'duplicate body anchor');boss=i end
        if hash==profile.belly_hash then assert(not belly,'duplicate belly node');belly=i end
        if profile.aim_hash and hash==profile.aim_hash then assert(not aim,'duplicate aim anchor');aim=i end
    end
    assert(boss and belly,'Titan bones unavailable')
    local poses=ptr(graph+0x28)
    local pose=floats(read(poses+boss*64,64))
    assert(not profile.aim_hash or aim,'weakpoint aim anchor unavailable')
    local aim_pose=aim and aim~=boss and floats(read(poses+aim*64,64)) or pose
    local origin=floats(read(poses,64))
    -- Reject torn/uninitialized/scaled-out matrices before constructing a waypoint.
    for _,pose in ipairs(aim_pose==pose and {pose} or {pose,aim_pose}) do
    for i=0,2 do
        local norm=0;for k=1,3 do norm=norm+pose[i*4+k]^2 end
        assert(norm>0.25 and norm<(profile.structure and 256 or 4),'Titan body pose scale')
        for j=0,i-1 do
            local dot=0;for k=1,3 do dot=dot+pose[i*4+k]*pose[j*4+k] end
            assert(math.abs(dot)<0.05,'Titan body pose basis')
        end
    end
    assert(math.abs(pose[4])+math.abs(pose[8])+math.abs(pose[12])<0.001
        and math.abs(pose[16]-1)<0.001,'Titan pose affine form')
    end
    local point={};local distance=0
    for k=1,3 do
        point[k]=aim_pose[12+k]
        for i=1,3 do point[k]=point[k]+aim_pose[(i-1)*4+k]*profile.offset[i] end
        distance=distance+(point[k]-origin[12+k])^2
    end
    assert(distance<(profile.structure and 10000 or 900),'Titan point outside body bound')
    -- Check the downstream Unit-alive dispatch used by the original validator.
    local api=ptr(ptr(base+0x3326308)+0x18)
    assert(ptr(api+0x720)==exe+profile.alive_rva,'Titan Unit-alive dispatch mismatch')
    local function validate()
        for _,row in ipairs(guards) do if reader(row[1],row[2])~=row[3] then return false end end
        return true
    end
    assert(validate(),'Titan observation changed')
    local function direction(v)
        if not v then return nil end
        local out={0,0,0}
        for k=1,3 do for i=1,3 do out[k]=out[k]+pose[(i-1)*4+k]*v[i] end end
        return out
    end
    return {id=id,address=address,identity=identity,unit=unit,point=point,
        body_center={pose[13],pose[14],pose[15]},origin={origin[13],origin[14],origin[15]},
        right=direction(profile.right_local) or {-pose[5],-pose[6],-pose[7]},
        forward=direction(profile.forward_local),profile=profile,
        validate=validate,boss= boss,belly=belly,native_lifetime_verified=false}
end
return M
