package.path='./src/?.lua;'..package.path
local Observer=require('g60.native_observer')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function fixture()
    local mem={};local base,root,manager=0x10000000,0x20000000,0x60000000
    local function put(a,s) for i=1,#s do mem[a+i-1]=s:byte(i) end end
    local function u32(a,v)
        local b={};for i=1,4 do b[i]=string.char(v%256);v=math.floor(v/256) end
        put(a,table.concat(b))
    end
    local function pointer(a,v) u32(a,v%4294967296);u32(a+4,math.floor(v/4294967296)) end
    local function zero(a,n) put(a,string.rep('\0',n)) end
    pointer(base+0x346bf98,root);pointer(base+0x347cf20,0x30000000)
    pointer(base+0x347cef0,0x31000000);zero(0x31000000+0x1f86a,1)
    pointer(base+0x3326348,0x32000000);zero(0x32000000+0x18,8)
    zero(root+0xf3f828,3);zero(0x30000000+0x134d01,1)
    local qs={{0x10,0x40010,12,24},{0x18,0x1203c,36,24},{0x20,0xe010,12,8},
        {0x28,0x4000c,12,8},{0x38,0x65c10,12,12}}
    local slots={}
    for i,q in ipairs(qs) do
        local address=0x40000000+i*0x100000
        pointer(root+q[1],address);zero(address+q[2],(q[4]-1)*q[3]+4)
        for j=0,q[4]-1 do u32(address+q[2]+j*q[3],1);slots[#slots+1]=address+q[2]+j*q[3] end
    end
    pointer(base+0x3326740,manager);zero(manager,0x70)
    local function read(a,n)
        local b={};for i=0,n-1 do assert(mem[a+i],'unreadable fixture');b[#b+1]=string.char(mem[a+i]) end
        return table.concat(b)
    end
    local function g60()
        u32(manager+0x20,8);u32(manager+0x2c,1);u32(manager+0x34,1)
        pointer(manager+0x58,0x61000000);pointer(manager+0x60,0x62000000)
        pointer(0x61000000,0x63000000);zero(0x63000000,24)
        u32(0x63000000,0x3e55bf62);u32(0x63000004,0x8e325c93);u32(0x63000008,547)
        zero(0x62000000,0x1f8);u32(0x62000000,4);u32(0x62000008,4);u32(0x62000068,547)
    end
    return {read=read,base=base,root=root,manager=manager,u32=u32,pointer=pointer,zero=zero,
        put=put,slots=slots,g60=g60}
end
test('76 completed worker slots are observations, not a control lease',function()
    local f=fixture();local r=Observer.capture(f.read,f.base)
    local count=0;for _,q in ipairs(r.queues) do count=count+q.count end
    assert(count==76 and r.all_observed_queues_complete)
    assert(not r.control_allowed and not r.native_lifetime_verified and not r.atomic_snapshot)
end)
test('each worker group reports an unfinished final slot',function()
    for _,i in ipairs({24,48,56,64,76}) do
        local f=fixture();f.u32(f.slots[i],0)
        assert(not Observer.capture(f.read,f.base).all_observed_queues_complete)
    end
end)
test('optional four-worker group is captured only when enabled',function()
    local f=fixture();f.put(0x30000000+0x134d01,'\1')
    f.zero(0x30000000+0x134cb0,76)
    for i=0,3 do f.u32(0x30000000+0x134cb0+i*24,1) end
    local r=Observer.capture(f.read,f.base)
    assert(#r.queues==6 and r.all_observed_queues_complete)
end)
test('worker completion changing during the snapshot is rejected without retry',function()
    local f=fixture();local calls=0
    local function read(a,n)
        local b=f.read(a,n)
        if a==f.slots[1] then calls=calls+1;if calls==1 then f.u32(a,0) end end
        return b
    end
    local ok,err=pcall(Observer.capture,read,f.base)
    assert(not ok and tostring(err):find('snapshot changed',1,true) and calls==2)
end)
test('G60 eligibility follows native active-prefix and flag checks',function()
    local f=fixture();f.g60()
    local r=Observer.capture(f.read,f.base);assert(r.matches[1].native_update_eligible and r.matches[1].id==547)
    f.u32(f.manager+0x34,0);assert(not Observer.capture(f.read,f.base).matches[1].native_update_eligible)
    f.u32(f.manager+0x34,1);f.u32(0x63000000+20,2)
    assert(not Observer.capture(f.read,f.base).matches[1].native_update_eligible)
end)
test('resource identifier keeps all 64 bits',function()
    local f=fixture();f.g60();assert(#Observer.capture(f.read,f.base).matches==1)
    f.u32(0x63000000,0x3e55bf63);assert(#Observer.capture(f.read,f.base).matches==0)
end)
test('invalid array size or null queue cannot be followed',function()
    local f=fixture();f.u32(f.manager+0x20,4097)
    assert(not pcall(Observer.capture,f.read,f.base))
    f=fixture();f.pointer(f.root+0x10,0);assert(not pcall(Observer.capture,f.read,f.base))
end)
test('short OS read is rejected',function()
    local f=fixture();assert(not pcall(Observer.capture,function(a,n) return f.read(a,n):sub(2) end,f.base))
end)
test('selection resource lookup checks entity identity',function()
    local f=fixture();f.g60();f.u32(0x62000018,521);f.put(0x62000078,'\1')
    f.pointer(f.root+0xf1aeb0,0x65000000);f.u32(f.root+0xf1aeb8,8)
    f.u32(f.root+0xf1aebc,0xffffffff);f.u32(f.root+0xf1aec0,0x9e3779b1)
    -- Low bits of 521 * 0x9e3779b1 are 1 modulo 8.
    f.u32(0x65000008,521);f.u32(0x6500000c,2)
    local entity=f.root+0xf32f18+48;f.zero(entity,24)
    f.u32(entity,0xa1e46bb9);f.u32(entity+4,0xbe39e313);f.u32(entity+8,521)
    assert(Observer.capture(f.read,f.base).matches[1].selection_resource=='be39e313a1e46bb9')
    f.u32(entity+8,522);assert(not pcall(Observer.capture,f.read,f.base))
end)
print(string.format('RESULT %d passed; %d failed (synthetic memory, no game writes)',passed,failed))
if failed>0 then os.exit(1) end
