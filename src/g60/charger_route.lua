-- Charger-only front-belly approach. Prediction steers; it never triggers a fuse.
local M={}
local function vector(v)
    assert(type(v)=='table','missing Charger vector')
    for k=1,3 do assert(type(v[k])=='number' and v[k]==v[k] and math.abs(v[k])<1000000,'invalid Charger vector') end
end
function M.step(own,target,previous,profile,now)
    vector(own);vector(target.point);vector(target.origin);vector(target.body_center)
    assert(type(now)=='number' and now==now and now>=0 and now<30,'Charger clock unavailable')
    local p=target.point;local depth=profile.region.depth
    local goal={p[1],p[2],p[3]-profile.standoff}
    if goal[3]-depth<target.origin[3]+0.2 then return nil,'Charger front-belly clearance unavailable' end
    local guide_z=goal[3]-depth/2
    local dx,dy=own[1]-p[1],own[2]-p[2]
    local radius=math.sqrt(dx*dx+dy*dy)
    local lx,ly=0,0
    if previous and previous.sample then
        local dt=now-previous.at
        if dt>=0.005 and dt<=0.25 then
            local vx,vy=(p[1]-previous.sample[1])/dt,(p[2]-previous.sample[2])/dt
            local speed=math.sqrt(vx*vx+vy*vy)
            -- Discontinuities or long skipped observations do not grant velocity.
            if speed<=35 then
                local horizon=math.min(0.3,radius/20)
                if speed*horizon>3 then horizon=3/speed end
                lx,ly=vx*horizon,vy*horizon
            end
        end
    end
    local stage,point
    if own[3]<=goal[3] then
        -- Approach from whichever low side is available; never chase the front
        -- of the head again when the charging body overtakes the grenade.
        stage='attack';point={p[1]+lx,p[2]+ly,guide_z}
    elseif radius>=3.5 then
        stage='descend';point={own[1],own[2],guide_z}
    elseif radius<=profile.region.radius and own[3]<=goal[3]+0.2 then
        stage='descend';point={p[1],p[2],guide_z}
    else
        stage='out'
        local ux,uy
        if radius>0.05 then ux,uy=dx/radius,dy/radius
        else
            vector(target.right);local norm=math.sqrt(target.right[1]^2+target.right[2]^2)
            assert(norm>0.5 and norm<2,'Charger heading unavailable')
            ux,uy=target.right[1]/norm,target.right[2]/norm
        end
        point={p[1]+ux*4,p[2]+uy*4,math.max(own[3],target.body_center[3]+1)}
    end
    return {point=point,arrival_point=stage=='attack' and goal or point,terminal=stage=='attack',
        route={stage=stage,sample={p[1],p[2],p[3]},at=now},lead={lx,ly}}
end
return M
