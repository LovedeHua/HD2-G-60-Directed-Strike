-- Bounded observed entity/Unit/motion reads shared by experimental selection.
local ffi=require('ffi')
local L=require('g60.native_observer')
local M={}
local function mul(a,b)
    local al,bl=a%65536,b%65536
    return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
end
function M.float(s,o)
    local v=ffi.new('uint32_t[1]',L.u32(s,o));local f=tonumber(ffi.cast('float *',v)[0])
    assert(f==f and math.abs(f)<1000000,'nonfinite target data');return f
end
function M.vector(s,o) return {M.float(s,o),M.float(s,o+4),M.float(s,o+8)} end
function M.new(reader,base,exe)
    local guards,total,calls={},0,0
    local d={base=base,exe=exe}
    function d.read(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and n>0 and n<=32768 and a+n<2^47,'target read bound')
        total=total+n;calls=calls+1;assert(total<=262144 and calls<=4096,'target data budget')
        local s=reader(a,n);assert(type(s)=='string' and #s==n,'short target read')
        guards[#guards+1]={a,n,s};return s
    end
    function d.ptr(a,align) return L.pointer(d.read(a,8),0,align) end
    function d.u32(a) return L.u32(d.read(a,4),0) end
    function d.hash(a,id,limit)
        local h=d.read(a,20)
        local entries,cap,empty,factor=L.pointer(h,0,4),L.u32(h,8),L.u32(h,12),L.u32(h,16)
        assert(cap>0 and cap<=1048576,'target hash capacity')
        local c=cap;while c>1 and c%2==0 do c=c/2 end;assert(c==1,'target hash not power of two')
        if id==empty then return nil end
        for probe=0,math.min(cap,256)-1 do
            local row=d.read(entries+((mul(id,factor)+probe)%cap)*8,8)
            local key,index=L.u32(row,0),L.u32(row,4)
            if key==empty then return nil end
            if key==id then
                if index==0xffffffff then return nil end
                assert(index<limit,'target index bound');return index
            end
        end
        error('target hash probe budget')
    end
    d.root=d.ptr(base+0x346bf98)
    d.invalid=d.u32(base+0x3483c20)
    local entities={}
    function d.entity(id)
        if entities[id] then return entities[id] end
        local index=d.hash(d.root+0xf1aeb0,id,2048)
        if not index then return nil end
        local address=d.root+0xf32f18+index*24
        local identity=d.read(address,24)
        assert(L.u32(identity,8)==id,'target entity identity mismatch')
        local e={id=id,address=address,identity=identity,resource=L.hex64(identity,0),handle=L.u32(identity,12),network=L.u32(identity,16)}
        entities[id]=e;return e
    end
    function d.unit(e)
        assert(e.handle~=0,'target Unit missing')
        local manager=d.ptr(exe+0x1a100f0)
        local index=e.handle%0x400000;local count=d.u32(manager+0x98)
        assert(count<=0x400000 and index<count,'target Unit index')
        assert(d.read(d.ptr(manager+0xa0)+index,1):byte()==math.floor(e.handle/0x400000)%256,'target Unit generation changed')
        return d.ptr(d.ptr(manager+0x88)+index*8)
    end
    function d.position(e)
        local manager=d.ptr(base+0x3326508)
        local i=assert(d.hash(manager+0x40,e.id,4096),'target motion missing')
        return M.vector(d.read(d.ptr(manager+0x68,4)+i*0x308+0x2e0,12),0)
    end
    function d.validate()
        for _,g in ipairs(guards) do if reader(g[1],g[2])~=g[3] then return false end end
        return true
    end
    return d
end
return M
