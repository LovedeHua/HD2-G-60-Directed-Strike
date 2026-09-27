-- Current G60 programmatic explosive, not a collision/timed explosive variant.
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local M={}
function M.capture(read,base,exe,identity,profile)
    local d=Data.new(read,base,exe)
    assert(L.hex64(identity,0)=='8e325c933e55bf62','explosive resource')
    local id=L.u32(identity,8)
    local e=assert(d.entity(id),'explosive entity absent')
    assert(e.identity==identity and L.u32(identity,20)%2==1,'explosive local native authority')
    d.unit(e)
    local manager=d.ptr(base+0x3326728)
    local h=d.read(manager,0x70);local count=L.u32(h,0x24)
    assert(count>0 and count<=4096 and count<=L.u32(h,0x18),'explosive array bound')
    local index=assert(d.hash(manager+0x38,id,count),'explosive component absent')
    local entity=d.ptr(L.pointer(h,0x50)+index*8)
    assert(entity==e.address and d.read(entity,24)==identity,'explosive component identity')
    local state_address=L.pointer(h,0x60,4)+index*64
    local network_address=L.pointer(h,0x68,4)+index*56
    local state=d.read(state_address,64);local network=d.read(network_address,56)
    assert(L.u32(state,0x38)==2,'unexpected native explosive mode')
    assert(state:byte(1)==0 and network:byte(2)==0,'explosion already requested')
    assert(state:byte(0xd)==0,'secondary explosion pending')
    -- 0x50c4f0 allows a per-entity configuration override: reject it.
    local overrides=d.read(manager+0x78,20)
    if L.u32(overrides,8)>0 then
        assert(not d.hash(manager+0x78,id,4096),'explosive configuration override')
    end
    local cfg=d.ptr(d.root+profile.root_offset,4)
    assert(d.read(cfg-32,32)==profile.header and d.read(cfg+profile.hash_offset,16)==profile.hash_bytes,'explosive template layout')
    local entry=d.read(cfg+profile.row_offset,360)
    assert(entry==profile.bytes,'G60 explosive template changed')
    assert(L.u32(entry,0)==2 and entry:byte(0x13d)==0,'unsupported trigger template')
    local invalid_source=d.u32(base+0x3483c4c)
    assert(d.validate(),'explosive observation changed')
    return {manager=manager,id=id,entity=e,network_address=network_address,state_address=state_address,
        invalid_source=invalid_source,validate=d.validate,root=d.root}
end
return M
