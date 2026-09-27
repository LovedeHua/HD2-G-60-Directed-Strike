-- New-shot priority only. A valid per-grenade lock always wins over later pings.
local Filter=require('g60.small_filter')
local M={}
function M.choose(rows,catalog,mark,lock,allowed)
    local eligible={}
    for _,r in ipairs(rows) do
        if not Filter.excluded(r.entity.resource) and (not allowed or allowed(r.entity.resource)) then eligible[#eligible+1]=r end
    end
    if lock then
        for _,r in ipairs(eligible) do if r.entity.identity==lock.identity then return r,'LOCKED' end end
    end
    if mark then
        for index,ping in ipairs(mark.queue or {mark}) do
            for _,r in ipairs(eligible) do
                if r.entity.identity==ping.identity then
                    return r,ping.current and 'CURRENT_PING' or 'REMEMBERED_PING',index
                end
            end
        end
    end
    local best,rank
    for _,r in ipairs(eligible) do
        local spec=catalog[r.entity.resource]
        if spec and (not best or spec.rank<rank or (spec.rank==rank and r.score>best.score)) then best,rank=r,spec.rank end
    end
    if best then return best,'AUTO_PRIORITY_'..rank end
    return nil,'VANILLA'
end
return M
