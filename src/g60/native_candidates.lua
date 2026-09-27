-- Original cached candidate list; scores remain observed, never called fresh.
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local M={}
function M.capture(d,c)
    local manager=d.ptr(d.base+0x3326548)
    local header=d.read(manager,0x58);local count=L.u32(header,0x20)
    assert(count>0 and count<=4096,'candidate manager count')
    local index=assert(d.hash(manager+0x30,L.u32(c.identity_bytes,8),count),'candidate source missing')
    local entity=d.ptr(L.pointer(header,0x48)+index*8)
    assert(entity==c.entity_address and d.read(entity,24)==c.identity_bytes,'candidate source identity')
    local record=d.read(L.pointer(header,0x50)+index*0x13f8,0x13f8)
    local offsets,seen={},{}
    for _,g in ipairs({{0x310,0x318},{0x818,0x820},{0xd20,0xd28}}) do
        local n=L.u32(record,g[1]);assert(n<=16,'candidate group bound')
        for i=0,n-1 do offsets[#offsets+1]=g[2]+i*80 end
    end
    -- Preserve original 0x889940 sparse-special ordinal behavior, rejecting aliases.
    local special={0x1228,0x1278,0x12c8};local active,n={},0
    for i,o in ipairs(special) do active[i]=L.u32(record,o+0x48)~=0;if active[i] then n=n+1 end end
    for ordinal=1,n do
        local i=ordinal;while i<=3 and not active[i] do i=i+1 end
        local offset=special[i] or special[1]
        assert(not seen[offset],'ambiguous sparse candidates');seen[offset]=true;offsets[#offsets+1]=offset
    end
    local rows={}
    for i,o in ipairs(offsets) do
        local raw=record:sub(o+1,o+80);local id=L.u32(raw,0)
        local score=Data.float(raw,0x44)
        if score>0 and id~=d.invalid and L.u32(raw,0x48)~=0 and L.u32(raw,0x4c)~=0 then
            local e=d.entity(id)
            if e then rows[#rows+1]={entity=e,raw=raw,score=score,position=Data.vector(raw,4),ordinal=i} end
        end
    end
    assert(d.validate(),'candidate observation changed')
    return rows
end
return M
