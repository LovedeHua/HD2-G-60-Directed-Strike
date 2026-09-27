-- Read-only native layout observer. A completed snapshot is NOT a control lease.
-- reader(address,size) must return exactly size bytes or raise an error.
local M={}
local MAX_ADDRESS=2^47
local function u32(s,o)
    local a,b,c,d=s:byte(o+1,o+4)
    assert(d,'short u32');return a+b*256+c*65536+d*16777216
end
local function ptr(s,o,alignment)
    alignment=alignment or 8
    assert(alignment==4 or alignment==8,'pointer alignment policy')
    local high=u32(s,o+4)
    assert(high<32768,'pointer precision bound')
    local p=u32(s,o)+high*4294967296
    assert(p>=65536 and p<MAX_ADDRESS and p%alignment==0,'pointer bound')
    return p
end
local function hex64(s,o) return string.format('%08x%08x',u32(s,o+4),u32(s,o)) end
local function multiply32(a,b)
    local al,bl=a%65536,b%65536
    return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
end
M.u32=u32;M.pointer=ptr;M.hex64=hex64
function M.capture(reader,base)
    assert(type(reader)=='function' and type(base)=='number' and base>=65536
        and base<MAX_ADDRESS and base%4096==0,'module base bound')
    local total,reads,guards=0,0,{}
    local function read(a,n,guard)
        assert(type(a)=='number' and a%1==0 and a>=65536 and n>0 and n<=32768
            and a+n<MAX_ADDRESS,'read bound')
        total=total+n;reads=reads+1
        assert(total<=262144 and reads<=8192,'snapshot budget')
        local b=reader(a,n);assert(type(b)=='string' and #b==n,'short native read')
        if guard then guards[#guards+1]={a,n,b} end
        return b
    end
    local function pointer(a) return ptr(read(a,8,true),0) end
    local root=pointer(base+0x346bf98)
    local function entity_resource(id)
        local h=read(root+0xf1aeb0,20,true)
        local entries,capacity,empty,multiplier=ptr(h,0),u32(h,8),u32(h,12),u32(h,16)
        assert(capacity>0 and capacity<=1048576,'entity hash capacity')
        local c=capacity
        while c>1 and c%2==0 do c=c/2 end
        assert(c==1,'entity hash capacity is not a power of two')
        if id==empty then return nil end
        for probe=0,math.min(capacity,256)-1 do
            local slot=(multiply32(id,multiplier)+probe)%capacity
            local pair=read(entries+slot*8,8,true)
            local key,index=u32(pair,0),u32(pair,4)
            if key==empty then return nil end
            if key==id then
                assert(index<2048,'diagnostic entity index bound')
                local entity=read(root+0xf32f18+index*24,24,true)
                assert(u32(entity,8)==id,'entity hash identity mismatch')
                return hex64(entity,0)
            end
        end
        error('entity hash probe budget')
    end
    local queues={}
    local all_complete=true
    local layouts={
        {name='raycast',root_offset=0x10,first=0x40010,stride=12,count=24},
        {name='areafinder',root_offset=0x18,first=0x1203c,stride=36,count=24},
        {name='group_20',root_offset=0x20,first=0xe010,stride=12,count=8},
        {name='group_28',root_offset=0x28,first=0x4000c,stride=12,count=8},
        {name='navmesh_edges',root_offset=0x38,first=0x65c10,stride=12,count=12},
    }
    local function queue(name,address,stride,count)
        local bytes=read(address,(count-1)*stride+4,true)
        local pending={}
        for i=0,count-1 do
            if u32(bytes,i*stride)==0 then pending[#pending+1]=i end
        end
        if #pending>0 then all_complete=false end
        queues[#queues+1]={name=name,count=count,pending=pending}
    end
    for _,layout in ipairs(layouts) do
        queue(layout.name,pointer(root+layout.root_offset)+layout.first,layout.stride,layout.count)
    end
    local optional=pointer(base+0x347cf20)
    local optional_enabled=read(optional+0x134d01,1,true):byte(1)~=0
    if optional_enabled then queue('optional_group',optional+0x134cb0,24,4) end
    local root_flags=read(root+0xf3f828,3,true)
    local mode=pointer(base+0x347cef0)
    local update_mode=read(mode+0x1f86a,1,true):byte(1)
    local time=read(pointer(base+0x3326348)+0x18,8,true)
    local manager=pointer(base+0x3326740)
    local header=read(manager,0x70,true)
    local capacity,count,active=u32(header,0x20),u32(header,0x2c),u32(header,0x34)
    assert(active<=count and count<=capacity and capacity<=4096,'behavior array bound')
    local matches={}
    if count>0 then
        local entities,states=ptr(header,0x58),ptr(header,0x60)
        local pointers=read(entities,count*8,true)
        for index=0,count-1 do
            local entity=ptr(pointers,index*8)
            local identity=read(entity,24,false)
            if hex64(identity,0)=='8e325c933e55bf62' then
                assert(#matches<16,'G60 count bound')
                guards[#guards+1]={entity,24,identity}
                local record=read(states+index*0x1f8,0x1f8,true)
                local id,flags=u32(identity,8),u32(identity,20)
                local row={index=index,id=id,behavior_id=u32(record,0),state=u32(record,8),
                    native_update_eligible=index<active and math.floor(flags/2)%2==0,
                    candidate_source=u32(record,0x68),selection_id=u32(record,0x18),
                    selection_flag=record:byte(0x78+1),flight_start=hex64(record,0x188),
                    identity_bytes=identity,record_bytes=record}
                if row.selection_flag~=0 then row.selection_resource=entity_resource(row.selection_id) end
                matches[#matches+1]=row
            end
        end
    end
    -- Repeat the small identity/state/queue observations without spinning until
    -- success. Stable reads remain observations, not synchronization primitives.
    for _,g in ipairs(guards) do assert(read(g[1],g[2],false)==g[3],'native snapshot changed') end
    return {queues=queues,all_observed_queues_complete=all_complete,
        optional_queue_enabled=optional_enabled,update_mode=update_mode,
        root_flags={root_flags:byte(1,3)},time_hex=hex64(time,0),
        behavior_count=count,active_prefix=active,matches=matches,
        bytes_read=total,read_calls=reads,atomic_snapshot=false,
        native_lifetime_verified=false,control_allowed=false}
end
return M
