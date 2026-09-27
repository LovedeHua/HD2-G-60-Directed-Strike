-- Geometric routes for the new enemy profiles; no terrain/collision query.
local Charger=require('g60.charger_route')
local M={}
local function vector(v)
    assert(type(v)=='table','missing weakpoint vector')
    for i=1,3 do assert(type(v[i])=='number' and v[i]==v[i] and math.abs(v[i])<1000000,'invalid weakpoint vector') end
end
local function heading(v)
    vector(v);local n=math.sqrt(v[1]^2+v[2]^2)
    assert(n>0.5 and n<2,'weakpoint heading unavailable')
    return v[1]/n,v[2]/n
end
function M.step(own,target,previous,profile,now)
    if profile.kind=='charger_front' then return Charger.step(own,target,previous,profile,now) end
    vector(own);vector(target.point);vector(target.body_center);vector(target.origin)
    local head=profile.kind=='head'
    local rear=profile.kind=='rear'
    local endcap=head or rear
    assert(endcap or profile.kind=='underside' or profile.kind=='thorax','unknown weakpoint route')
    local p=target.point;local rx,ry=heading(target.right);local fx,fy=heading(target.forward)
    local center=endcap and target.body_center or p
    local dx,dy=own[1]-center[1],own[2]-center[2]
    local radius=math.sqrt(dx*dx+dy*dy)
    local ring=endcap and 5 or profile.kind=='underside' and 6 or 8
    local side=previous and previous.side or (dx*rx+dy*ry<0 and -1 or 1)
    assert(side==1 or side==-1,'invalid weakpoint route side')
    if rear then fx,fy=-fx,-fy end
    local sx,sy=endcap and fx or rx*side,endcap and fy or ry*side
    local goal,transit
    if endcap then
        goal={p[1]+fx*0.4,p[2]+fy*0.4,p[3]-(rear and 0.3 or 0)};transit=goal[3]
    else
        goal={p[1],p[2],p[3]-profile.standoff}
        transit=goal[3]-(profile.kind=='underside' and 0.4 or 1)
        if profile.kind=='underside' and transit<target.origin[3]+0.3 then
            return nil,'Impaler has insufficient observed underside clearance'
        end
        -- Dragonroach can be airborne; its root is not a terrain-height sample.
    end
    local stage=previous and previous.stage or 'out'
    local cruise=previous and previous.cruise_offset or math.max(own[3],target.body_center[3]+2)-p[3]
    local frontal=(own[1]-p[1])*fx+(own[2]-p[2])*fy
    local lateral=math.abs((own[1]-p[1])*rx+(own[2]-p[2])*ry)
    if endcap and frontal>=0 and lateral<=2.5 and (not rear or own[3]<=p[3]+0.2) then
        stage='attack'
    elseif not endcap and own[3]<=goal[3] and radius<=ring
        and math.abs(-dx*ry+dy*rx)<=2 then
        stage='attack'
    elseif stage=='attack' or stage=='under' then
        if endcap or own[3]>p[3]-0.2 then
            stage='out';cruise=math.max(own[3],target.body_center[3]+2)-p[3]
        end
    end
    -- A rear approach starting below the body exits at its current low height.
    if rear and stage=='out' and own[3]<=p[3]+0.2 then cruise=own[3]-p[3] end
    local ux,uy=sx,sy;if radius>0.01 then ux,uy=dx/radius,dy/radius end
    local angle=math.acos(math.max(-1,math.min(1,ux*sx+uy*sy)))
    if stage=='out' and radius>=ring-0.5 then stage='around' end
    if stage=='around' and angle<=math.rad(8) and radius>=ring-0.5 then stage='descend' end
    local side_x,side_y=center[1]+sx*ring,center[2]+sy*ring
    if stage=='descend' and (own[1]-side_x)^2+(own[2]-side_y)^2<=1
        and math.abs(own[3]-transit)<=0.4 then stage=endcap and 'attack' or 'under' end
    if stage=='under' and radius<=0.8 and own[3]<=goal[3] then stage='attack' end
    local point
    if stage=='out' then point={center[1]+ux*ring,center[2]+uy*ring,p[3]+cruise}
    elseif stage=='around' then
        local turn=math.min(angle,math.rad(20));if ux*sy-uy*sx<0 then turn=-turn end
        local c,s=math.cos(turn),math.sin(turn)
        point={center[1]+(ux*c-uy*s)*ring,center[2]+(ux*s+uy*c)*ring,transit}
    elseif stage=='descend' then point={side_x,side_y,transit}
    elseif stage=='under' then point={p[1],p[2],transit}
    elseif stage=='attack' then
        point={goal[1],goal[2],goal[3]}
        -- Guide inside the permitted vertical band, not exactly on its upper
        -- boundary: the engine stores float32 waypoints and may round upward.
        if not endcap and profile.region then point[3]=point[3]-profile.region.depth/2 end
    else error('unknown weakpoint route stage') end
    vector(point)
    return {point=point,arrival_point=stage=='attack' and goal or point,
        route={stage=stage,side=side,cruise_offset=cruise},terminal=stage=='attack'}
end
return M
