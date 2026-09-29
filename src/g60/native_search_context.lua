-- Bounded, read-only preparation for the reviewed NULL-selection/orbit calls.
-- This is not a native adapter: stable reads never grant authority or lifetime.
local Layout=require('g60.native_observer')
local Authority=require('g60.native_authority')
local M={}
local u32,ptr,hex=Layout.u32,Layout.pointer,Layout.hex64
local function mul32(a,b)
    local al,bl=a%65536,b%65536
    return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
end
local function finite_vector(bytes,offset)
    for i=0,2 do
        assert(math.floor(u32(bytes,offset+i*4)/8388608)%256~=255,'nonfinite motion position')
    end
end
function M.selection(record,invalid)
    assert(type(record)=='string' and #record==0x1f8,'behavior record size')
    local id,flag=u32(record,0x18),record:byte(0x79)
    assert(flag==0 or flag==1,'selection flag bound')
    local cleared=id==invalid and flag==0 and u32(record,0x60)==0
        and u32(record,0x70)==invalid
    return {id=id,flag=flag,has_target=flag==1 and id~=invalid,
        cleared=cleared,needs_clear=not cleared,
        stale_flag=flag==1 and id==invalid}
end
-- Experimental refinement of the strict empty-queue gate. Reviewed 0x843090:
-- 16-byte rows {due:u64,event:u32,entity:u32}; future rows are not dispatched.
-- Keep a 250 ms margin and reject all events for the grenade or tracked target.
function M.pending_events(read,header,now,invalid,protected)
    local count=u32(header,8)
    if count==0 then return nil end
    assert(count<=256,'pending behavior event bound')
    local address=ptr(header,0,4);local bytes=read(address,count*16)
    assert(type(bytes)=='string' and #bytes==count*16,'short pending behavior events')
    for i=0,count-1 do
        local offset=i*16;local due=hex(bytes,offset);local id=u32(bytes,offset+12)
        assert(id~=invalid and not protected[id],'pending behavior event for protected entity '..id)
        assert(due>now,'due behavior event')
        local delta=(tonumber(due:sub(1,8),16)-tonumber(now:sub(1,8),16))*4294967296
            +tonumber(due:sub(9),16)-tonumber(now:sub(9),16)
        assert(delta>250000,'imminent behavior event')
    end
    return {address=address,bytes=bytes,count=count}
end
function M.capture(reader,base,observed,engine,options)
    assert(type(reader)=='function' and type(base)=='number' and base>=65536
        and base<2^47 and base%4096==0,'module base bound')
    assert(type(observed)=='table' and type(observed.index)=='number'
        and observed.index>=0 and observed.index%1==0
        and type(observed.identity_bytes)=='string' and #observed.identity_bytes==24
        and type(observed.record_bytes)=='string' and #observed.record_bytes==0x1f8,
        'expected observation required')
    local guards,total,calls={},0,0
    local function read(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and n>0 and n<=4096
            and a+n<2^47,'read bound')
        total=total+n;calls=calls+1
        assert(total<=65536 and calls<=2048,'search context budget')
        local bytes=reader(a,n)
        assert(type(bytes)=='string' and #bytes==n,'short search context read')
        guards[#guards+1]={a,n,bytes};return bytes
    end
    local function decode_pointer(bytes,offset,label,alignment)
        local ok,value=pcall(ptr,bytes,offset,alignment)
        assert(ok,'search pointer '..label..' value='..hex(bytes,offset)..': '..tostring(value))
        return value
    end
    local function pointer(a,label,alignment) return decode_pointer(read(a,8),0,label,alignment) end
    local function hash_index(address,id)
        local h=read(address,20)
        -- Native component hash allocations request alignment 4, despite stride 8.
        local entries,capacity,empty,multiplier=decode_pointer(h,0,string.format('hash entries at %x',address),4),u32(h,8),u32(h,12),u32(h,16)
        assert(capacity>0 and capacity<=1048576,'component hash capacity')
        local c=capacity;while c>1 and c%2==0 do c=c/2 end
        assert(c==1,'component hash power of two')
        if id==empty then return nil end
        for probe=0,math.min(capacity,256)-1 do
            local entry=read(entries+((mul32(id,multiplier)+probe)%capacity)*8,8)
            local key,index=u32(entry,0),u32(entry,4)
            if key==empty then return nil end
            if key==id then
                if index==0xffffffff then return nil end
                assert(index<4096,'component index bound');return index
            end
        end
        error('component hash probe budget')
    end
    local invalid=u32(read(base+0x3483c20,4),0)
    local manager=pointer(base+0x3326740,'behavior manager')
    local header=read(manager,0x70)
    local count,active=u32(header,0x2c),u32(header,0x34)
    assert(active<=count and count<=u32(header,0x20) and u32(header,0x20)<=4096
        and observed.index<active,'inactive behavior index')
    if not (options and options.experimental_event_window==true) then
        assert(u32(header,8)==0,'pending behavior events')
    end
    local entity=pointer(decode_pointer(header,0x58,'behavior entities')+observed.index*8,'behavior entity')
    local identity=read(entity,24)
    local record_address=decode_pointer(header,0x60,'behavior records')+observed.index*0x1f8
    local record=read(record_address,0x1f8)
    assert(identity==observed.identity_bytes and record==observed.record_bytes,'stale observation')
    local id=u32(identity,8)
    -- ★ 早期接管：options.allow_early_state 时放行 state 2/3（观测+设目标用）。
    --   只放宽**观测**，写入端（titan/arrival）的门控另行独立判断。
    local early=options and options.allow_early_state
        and (u32(record,8)==2 or u32(record,8)==3)
    assert(id~=invalid and hex(identity,0)=='8e325c933e55bf62'
        and u32(record,0)==4 and (u32(record,8)==4 or early),'not active state-4 G60')
    assert(math.floor(u32(identity,20)/2)%2==0,'native update excluded')
    assert(u32(record,0x68)==id,'candidate source mismatch')
    local root=pointer(base+0x346bf98,'root')
    local clock=pointer(base+0x3326348,'clock')
    local now=hex(read(clock+0x18,8),0)
    local protected={[id]=true}
    local selected=u32(record,0x18)
    if selected~=invalid then protected[selected]=true end
    if options and options.target_id then protected[options.target_id]=true end
    local pending=M.pending_events(read,header,now,invalid,protected)
    local start=hex(record,0x188)
    -- Hex comparison/subtraction uses exact 32-bit halves, never a lossy u64 double.
    assert(now>=start,'flight start in future')
    local elapsed=(tonumber(now:sub(1,8),16)-tonumber(start:sub(1,8),16))*4294967296
        +tonumber(now:sub(9,16),16)-tonumber(start:sub(9,16),16)
    assert(elapsed<30000000,'flight expired')
    local motion=pointer(base+0x3326508,'motion manager')
    local motion_records=pointer(motion+0x68,'motion records',4)
    local own_motion=assert(hash_index(motion+0x40,id),'missing projectile motion')
    local own_position=read(motion_records+own_motion*0x308+0x2e0,12)
    finite_vector(own_position,0)
    local actors=pointer(base+0x3326d20,'actor manager')
    local actor_count=u32(read(actors+0x70,4),0)
    assert(actor_count<=16,'orbit anchor count bound')
    local anchor
    for i=0,actor_count-1 do
        local bytes=read(actors+0x110+i*8,8)
        if hex(bytes,0)~='0000000000000000' then
            local address=decode_pointer(bytes,0,'orbit anchor entity');local e=read(address,24);local aid=u32(e,8)
            local index=aid~=invalid and hash_index(motion+0x40,aid) or nil
            if index then
                local position=read(motion_records+index*0x308+0x2e0,12)
                finite_vector(position,0)
                anchor={entity_address=address,id=aid,position_bytes=position};break
            end
        end
    end
    assert(anchor,'no native orbit anchor') -- The helper otherwise returns without moving.
    local orbit=pointer(base+0x3326cc8,'orbit manager')
    local orbit_index=assert(hash_index(orbit+0x80,id),'missing orbit component')
    local orbit_record=read(pointer(orbit+0xa0,'orbit records',4)+orbit_index*8,8)
    -- Serialized LDLD configuration is packed to four bytes (observed live in 0.5.0).
    local config=pointer(root+0xf124c8,'orbit config',4)
    local config_header=read(config-32,32)
    assert(u32(config_header,0)==10 and u32(config_header,4)==0xc9500230
        and config_header:sub(9,12)=='LDLD' and u32(config_header,12)==1
        and u32(config_header,16)==0xc9500230 and u32(config_header,20)==120
        and u32(config_header,24)==1 and u32(config_header,28)==0,'orbit config layout')
    local config_bytes=read(config,120)
    -- resource % 6 without converting the 64-bit resource to a Lua number.
    local slot=(u32(identity,4)%6*4+u32(identity,0)%6)%6
    local divisor
    for probe=0,5 do
        local offset=((slot+probe)%6)*16
        local key=hex(config_bytes,offset)
        if key=='0000000000000000' then break end
        if key==hex(identity,0) then
            local index=u32(config_bytes,offset+8)
            assert(index<3,'orbit config value bound')
            divisor=u32(config_bytes,96+index*8);break
        end
    end
    assert(divisor and divisor>0,'missing or zero orbit divisor')
    local movement=pointer(base+0x3326418,'movement manager')
    local movement_index=assert(hash_index(movement+0x30,id),'missing movement component')
    local movement_address=pointer(movement+0x50,'movement records')+movement_index*0xa8
    local movement_bytes=read(movement_address,0xa8)
    local speed=pointer(base+0x3326460,'speed manager')
    local speed_index=assert(hash_index(speed+0x30,id),'missing speed component')
    local speed_entity=pointer(pointer(speed+0x48,'speed entities')+speed_index*8,'speed entity')
    assert(speed_entity==entity and read(speed_entity,24)==identity,'speed entity identity mismatch')
    local speed_address=pointer(speed+0x50,'speed records',4)+speed_index*0x534+0x50c
    local speed_mirror_address=pointer(speed+0x60,'speed mirrors',4)+speed_index*0x38+8
    local speed_bytes=read(speed_address,4)
    local speed_mirror_bytes=read(speed_mirror_address,4)
    local ownership=Authority.inspect(engine,u32(identity,16))
    -- Recheck without spinning. This detects changes, not concurrent reader/writer safety.
    for _,g in ipairs(guards) do
        total=total+g[2];calls=calls+1
        assert(total<=65536 and calls<=2048,'search context budget')
        assert(reader(g[1],g[2])==g[3],'search context changed')
    end
    return {entity_address=entity,state_address=record_address+8,id=id,
        identity_bytes=identity,record_bytes=record,
        selection=M.selection(record,invalid),flight_start=start,time_hex=now,pending_event_observation=pending,
        own_position_bytes=own_position,
        orbit_anchor=anchor,orbit_slot=orbit_record:byte(5),orbit_divisor=divisor,
        movement_address=movement_address,movement_bytes=movement_bytes,
        speed_address=speed_address,speed_bytes=speed_bytes,
        speed_mirror_address=speed_mirror_address,speed_mirror_bytes=speed_mirror_bytes,
        path_agent_present=u32(movement_bytes,8)~=0xffffffff,
        network_entity_index=u32(identity,16),
        ownership=ownership,
        bytes_read=total,read_calls=calls,control_allowed=false,
        native_lifetime_verified=false,external_effects_verified=false}
end
return M
