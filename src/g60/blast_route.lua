-- ★★★ 2026-10-05：逐字移植上游 1.1.0 的 `BlastRoute`（用户拍板"泰坦方面全部改成上游"）★★★
--   它在泰坦链上是**第二段**：`TitanRoute` → **本模块** → `Adaptive`。
--   对 `kind=="titan"` 它给出**圆柱**爆区（`center = 腹点 - (0,0,2.5)`、`radius=2`、
--   `depth=min(0.8, 腹点-2.5-origin-1.25)`）并置 `terminal/arrival_point/arrival_region`；
--   随后 `Adaptive` 在姿态可靠时**覆盖**成腹法线点 + `surface` 区域。
--   ⚠ 上游原文：`_refs/upstream-g60st-1.1.0-body.lua` 2470-2573，逐字未改。
--   ⚠ `head/rear/charger` 那几个分支引用弱点/冲锋者几何 —— 本工程 `weakpoint_profiles`
--     为空 ⇒ 不可达；仍然逐字保留（改它只会引入"与上游不一致"的风险）。
-- Experimental geometric detonation volumes, not a verified damage solver.
-- Runs after the existing planner validates the current pose and clearance.
local Policy=require('g60.arrival_policy')
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function heading(v)
    assert(type(v)=='table','blast heading missing')
    local x,y=v[1],v[2];local n=math.sqrt(x*x+y*y)
    assert(n>0.5 and n<2,'blast heading unavailable')
    return x/n,y/n
end
local function contains(own,zone)
    return Policy.step(0,own,zone.center,true,'region',nil,zone.region)=='detonate'
end
local function distance(a,b)
    return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
end
local function guide(own,zone)
    local c,r=zone.center,zone.region
    local dx,dy,dz=own[1]-c[1],own[2]-c[2],own[3]-c[3]
    if r.kind=='ellipsoid' then
        local fx,fy=r.forward[1],r.forward[2]
        local along=dx*fx+dy*fy;local across=-dx*fy+dy*fx
        local q=math.sqrt((along/r.length)^2+(across/r.width)^2+(dz/r.height)^2)
        -- Interior navigation waypoint reduces float rounding/overshoot chatter.
        local scale=q>0.8 and 0.8/q or 1
        return {c[1]+dx*scale,c[2]+dy*scale,c[3]+dz*scale}
    end
    local radius=math.sqrt(dx*dx+dy*dy)
    local scale=radius>r.radius-0.15 and (r.radius-0.15)/radius or 1
    return {c[1]+dx*scale,c[2]+dy*scale,c[3]+clamp(dz,-r.depth*0.8,-r.depth*0.2)}
end
function M.refine(own,target,previous,profile,base)
    if profile.structure or profile.kind=='charger_front' then return base end
    local p=target.point;local kind=profile.kind or 'titan'
    local rx,ry=heading(target.right)
    local zones={};local low_side=false
    if kind=='head' or kind=='rear' then
        local fx,fy=heading(target.forward)
        if kind=='rear' then fx,fy=-fx,-fy end
        local ahead=(own[1]-p[1])*fx+(own[2]-p[2])*fy
        local across=math.abs(-(own[1]-p[1])*fy+(own[2]-p[2])*fx)
        local rear=kind=='rear';local offset=rear and 1.3 or 1.4
        zones[1]={id=kind,center={p[1]+fx*offset,p[2]+fy*offset,p[3]-(rear and 0.3 or 0)},
            region={kind='ellipsoid',forward={fx,fy},length=rear and 1.2 or 1.25,width=rear and 1.4 or 1.2,height=rear and 0.85 or 0.9},
            reachable=ahead>=0 and across<=3 and (not rear or own[3]<=p[3]+0.4)}
        do
            local c=target.body_center
            -- All three Charger variants share this body/leg reference layout.
            -- Preserve the tested Behemoth side geometry for head profiles too.
            local forward_x,forward_y=heading(target.forward)
            for _,sign in ipairs({-1,1}) do
                local sx,sy=rx*sign,ry*sign
                local lateral=(own[1]-c[1])*sx+(own[2]-c[2])*sy
                local longitudinal=math.abs((own[1]-c[1])*fx+(own[2]-c[2])*fy)
                zones[#zones+1]={id='side'..sign,
                    center={c[1]+sx*2.2-forward_x*0.5,c[2]+sy*2.2-forward_y*0.5,rear and p[3] or c[3]-0.38},
                    region={kind='ellipsoid',forward={sx,sy},length=0.4,width=0.6,height=0.5},
                    reachable=lateral>=1.8 and longitudinal<=2 and own[3]<=c[3]+1
                        and own[3]>=target.origin[3]+0.3}
            end
        end
    else
        assert(kind=='titan' or kind=='thorax' or kind=='underside','unsupported blast profile')
        local standoff=kind=='underside' and 0.4 or 2.5
        local depth=kind=='underside' and math.min(0.6,p[3]-standoff-target.origin[3]-0.3) or 0.8
        if kind=='titan' then
            depth=math.min(depth,p[3]-standoff-target.origin[3]-1.25)
            if depth<=0.05 then return base end
        end
        assert(depth>0,'blast region lacks lower clearance')
        local radius=kind=='underside' and 1.2 or 2.0
        zones[1]={id=kind,center={p[1],p[2],p[3]-standoff},region={radius=radius,depth=depth}}
        local forward=math.abs(-(own[1]-p[1])*ry+(own[2]-p[2])*rx)
        low_side=forward<=(kind=='underside' and 2 or 2.5) and own[3]<=zones[1].center[3]
        zones[1].reachable=low_side or base.route.stage=='under' or base.terminal
    end
    -- Actual current-position membership overrides stale route stages.
    local chosen,best
    for _,z in ipairs(zones) do
        if contains(own,z) then chosen=z;break end
        if z.reachable then
            local score=distance(own,guide(own,z))
            if previous and previous.blast_zone==z.id then score=score-0.3 end
            if not best or score<best then best=score;chosen=z end
        end
    end
    if chosen then
        base.point=guide(own,chosen);base.arrival_point=chosen.center
        base.arrival_region=chosen.region;base.terminal=true
        base.route.stage='attack';base.route.blast_zone=chosen.id
    elseif kind=='titan' or kind=='thorax' or kind=='underside' then
        -- Descend into the vertical band before entering, avoiding an upward correction.
        if base.route.stage=='around' or base.route.stage=='descend' then
            base.point[3]=zones[1].center[3]-zones[1].region.depth*0.75
        end
        base.arrival_point=zones[1].center;base.arrival_region=zones[1].region
    else
        -- Never leave a legacy terminal flag active against a transit waypoint.
        base.terminal=false
    end
    return base
end
return M
