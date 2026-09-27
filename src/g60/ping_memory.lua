-- Local mark history, newest first. UI expiry does not expire remembered intent.
local M={limit=32}
local function copy(value)
    local out={};for k,v in pairs(value) do out[k]=v end;return out
end
function M.new()
    local scene,time,serial=nil,nil,0
    local seen,history={},{}
    local api={}
    function api:reset() scene,time,serial=nil,nil,0;seen={};history={} end
    function api:forget(identity) history[identity]=nil end
    function api:update(observation,valid)
        if observation.scene~=scene or (time and observation.time<time) then self:reset() end
        scene,time=observation.scene,observation.time
        -- Seconds from the guarded native microsecond clock; age is UI seconds.
        local now=(tonumber(time:sub(1,8),16)*4294967296+tonumber(time:sub(9),16))/1000000
        local marks=observation.marks or (observation.mark and {observation.mark}) or {}
        for identity,mark in pairs(history) do if not valid(mark) then history[identity]=nil end end
        for _,mark in ipairs(marks) do
            local key=mark.slot or mark.token
            local old=seen[key]
            local renewed=not old or mark.token~=old.token or mark.age<old.age
            seen[key]={token=mark.token,age=mark.age}
            if renewed and valid(mark) then
                serial=serial+1
                local entry=copy(mark);entry.marked_at=now-mark.age;entry.order=serial
                local prior=history[entry.identity]
                -- An older ring record first observed late must not demote a
                -- newer mark for the same entity. Equal-age ties use ring order.
                if not prior or entry.marked_at>=prior.marked_at then history[entry.identity]=entry end
            end
        end
        local ordered={}
        for _,mark in pairs(history) do ordered[#ordered+1]=mark end
        table.sort(ordered,function(a,b)
            if a.marked_at~=b.marked_at then return a.marked_at>b.marked_at end
            return a.order>b.order
        end)
        while #ordered>M.limit do history[ordered[#ordered].identity]=nil;table.remove(ordered) end
        local queue={}
        for _,entry in ipairs(ordered) do
            local mark=copy(entry);mark.current=false
            for _,visible in ipairs(marks) do
                if visible.identity==mark.identity and visible.token==mark.token then mark.current=true;break end
            end
            queue[#queue+1]=mark
        end
        if #queue==0 then return nil end
        -- Keep the existing top-mark interface while exposing all older marks.
        local top=copy(queue[1]);top.queue=queue
        return top
    end
    return api
end
return M
