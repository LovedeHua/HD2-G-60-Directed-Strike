-- Asset-based approach, not collision/pathfinding proof. Terminal arrival only.
local M={}
local function distance(a,b)
    local n=0;for k=1,3 do
        assert(type(a[k])=='number' and a[k]==a[k] and math.abs(a[k])<1000000,'structure position')
        assert(type(b[k])=='number' and b[k]==b[k] and math.abs(b[k])<1000000,'structure target')
        n=n+(a[k]-b[k])^2
    end;return math.sqrt(n)
end
function M.step(own,target,previous,profile)
    local point=target.point;distance(own,point)
    if profile.kind=='structure_hole' then
        local forward=assert(target.forward,'structure entrance direction')
        local length=math.sqrt(forward[1]^2+forward[2]^2)
        assert(length>0.25,'structure entrance axis')
        local x,y=forward[1]/length,forward[2]/length
        local approach=profile.front_distance or 5
        assert(type(approach)=='number' and approach>=5 and approach<=12,'structure approach bound')
        local front={point[1]+x*approach,point[2]+y*approach,point[3]+0.5}
        local stage=previous and previous.stage or 'front'
        if stage=='front' and distance(own,front)<=1.5 then stage='attack' end
        -- A back/overhead grenade must reach the entrance side first. Keep
        -- the exterior transfer above the mouth, then descend on that side.
        if stage=='front' then
            if (own[1]-point[1])*x+(own[2]-point[2])*y<2 then
                front[3]=math.max(front[3],own[3],point[3]+4)
            end
            return {point=front,terminal=false,route={stage='front'}}
        end
        -- The effect node can be embedded behind the mouth geometry. Guide to
        -- the open side and accept a bounded entrance volume, never the back
        -- of the nest or an arbitrary stalled position.
        local goal={point[1]+x,point[2]+y,point[3]+0.5}
        return {point=goal,terminal=true,route={stage='attack'},
            arrival_region={kind='entrance',forward={x,y},back=0.75,front=1.5,width=1.5,height=1.25}}
    end
    assert(profile.kind=='structure_tower' or profile.kind=='structure_egg','unknown structure route')
    -- Aim beside the measured upper trunk, not the underground entity origin.
    local dx,dy=own[1]-point[1],own[2]-point[2]
    local length=math.sqrt(dx*dx+dy*dy)
    local side=previous and previous.side or (length>0.1 and {dx/length,dy/length} or {1,0})
    -- Egg sacks are much smaller than towers. Use a close blast beside the
    -- measured egg centre, with the ordinary current-position arrival check.
    local standoff=profile.kind=='structure_egg' and 0.9 or 2.5
    local goal={point[1]+side[1]*standoff,point[2]+side[2]*standoff,point[3]}
    return {point=goal,terminal=true,route={stage='attack',side=side}}
end
return M
