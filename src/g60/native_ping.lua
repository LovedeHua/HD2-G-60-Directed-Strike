-- Read-only native UI ring. Creator must match the uniquely locally owned actor.
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Authority=require('g60.native_authority')
local Memory=require('g60.ping_memory')
local M={}
function M.new(env,options)
    options=options or {}
    local function allowed(resource)
        local check=options.allowed or env.target_allowed
        return not check or check(resource)
    end
    local memory=Memory.new()
    local diagnosed,diagnostic_count={},0
    local function diagnose(id,resource,reason)
        if not options.diagnostic then return end
        local detail='target='..tostring(id)..';resource='..tostring(resource)..';reason='..tostring(reason)
        if diagnosed[detail] or diagnostic_count>=64 then return end
        diagnosed[detail]=true;diagnostic_count=diagnostic_count+1;options.diagnostic(detail)
    end
    local api={}
    function api:reset() memory:reset();diagnosed={};diagnostic_count=0 end
    function api:forget(identity) memory:forget(identity) end
    function api:observe()
        local ok,result=pcall(function()
            local d=Data.new(env.read,env.base,env.exe)
            local actors=d.ptr(env.base+0x3326d20)
            local count=d.u32(actors+0x70);assert(count<=16,'Ping actor count')
            local owner
            for i=0,count-1 do
                local p=d.read(actors+0x110+i*8,8)
                if L.hex64(p,0)~='0000000000000000' then
                    local address=L.pointer(p,0);local bytes=d.read(address,24)
                    if Authority.inspect(env.engine,L.u32(bytes,16)).local_ownership_observed then
                        assert(not owner,'ambiguous local Ping creator')
                        owner=assert(d.entity(L.u32(bytes,8)),'Ping creator entity missing')
                        assert(owner.address==address and owner.identity==bytes,'Ping creator changed')
                        d.unit(owner)
                    end
                end
            end
            assert(owner,'local Ping creator unavailable')
            local ring=d.ptr(env.base+0x347ce30)
            local header=d.read(ring,16)
            assert(header:byte(1)==1,'Ping UI inactive')
            local head,tail=L.u32(header,8),L.u32(header,12)
            assert(head<128 and tail<128,'Ping ring bounds')
            local marks={}
            for step=0,(tail-head)%128-1 do
                local slot=(head+step)%128
                local r=d.read(ring+16+slot*0x58,0x58)
                local duration,age=Data.float(r,0x10),Data.float(r,0x14)
                if L.u32(r,0x18)==owner.id and age>=0 and age<duration then
                    local id=L.u32(r,0x20)
                    local good,mark=pcall(function()
                        local e=id~=d.invalid and d.entity(id)
                        if not e then diagnose(id,nil,'NO_ENTITY_MARK')
                        elseif not allowed(e.resource) then diagnose(id,e.resource,'RESOURCE_NOT_SUPPORTED') end
                        if e and (not allowed or allowed(e.resource)) then
                            local unit=d.unit(e)
                            return {id=id,identity=e.identity,resource=e.resource,unit=unit,age=age,slot=slot,
                                token=tostring(slot)..':'..r:sub(1,4)..r:sub(0x11,0x14)..r:sub(0x19,0x1c)..e.identity}
                        end
                    end)
                    -- A recycled/unavailable marked unit must not erase older
                    -- valid marks; the full read observation is still rechecked.
                    if good and mark then marks[#marks+1]=mark end
                    if not good then diagnose(id,nil,'ENTITY_READ_FAILED:'..tostring(mark)) end
                end
            end
            local origin=d.position(owner)
            local function valid(m)
                local good,value=pcall(function()
                    local e=d.entity(m.id)
                    if not e or (allowed and not allowed(e.resource))
                        or e.identity~=m.identity or d.unit(e)~=m.unit then return false end
                    local p=options.position and options.position(e) or d.position(e);local distance=0
                    for i=1,3 do distance=distance+(p[i]-origin[i])^2 end
                    if distance>=40000 then diagnose(m.id,m.resource,'OUTSIDE_200M');return false end
                    diagnose(m.id,m.resource,'ACCEPTED');return true
                end)
                if not good then diagnose(m.id,m.resource,'POSE_READ_FAILED:'..tostring(value)) end
                return good and value
            end
            local clock=d.ptr(env.base+0x3326348)
            local observation={scene=tostring(d.root)..':'..tostring(ring)..':'..owner.identity,
                time=L.hex64(d.read(clock+0x18,8),0),marks=marks}
            local selected=memory:update(observation,valid)
            assert(d.validate(),'Ping observation changed')
            return selected
        end)
        if not ok then memory:reset();return nil,tostring(result) end
        return result
    end
    return api
end
return M
