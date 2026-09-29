-- Arrival uses the current positions, never a historical segment crossing.
local M={radius=0.8,stalled_seconds=4,retry_seconds=5,lifetime_ticks=30000000}
function M.elapsed(now,start)
    assert(type(now)=='string' and #now==16 and type(start)=='string' and #start==16 and now>=start,'arrival clock')
    return (tonumber(now:sub(1,8),16)-tonumber(start:sub(1,8),16))*4294967296
        +tonumber(now:sub(9),16)-tonumber(start:sub(9),16)
end
local function distance(a,b)
    local v=0
    for i=1,3 do
        assert(type(a[i])=='number' and a[i]==a[i] and math.abs(a[i])<1000000,'arrival position')
        assert(type(b[i])=='number' and b[i]==b[i] and math.abs(b[i])<1000000,'arrival goal')
        v=v+(a[i]-b[i])^2
    end
    return math.sqrt(v)
end
function M.step(now,own,goal,terminal,key,previous,region)
    assert(type(now)=='number' and now>=0 and now<30,'arrival time bound')
    local dist=distance(own,goal)
    local arrived=dist<=M.radius
    if region and region.kind=='entrance' then
        local axis=region.forward
        assert(type(axis)=='table' and type(axis[1])=='number' and type(axis[2])=='number'
            and math.abs(axis[1]^2+axis[2]^2-1)<0.001,'entrance axis')
        for _,key in ipairs({'back','front','width','height'}) do
            assert(type(region[key])=='number' and region[key]>0 and region[key]<=2,'entrance bounds')
        end
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        local along=dx*axis[1]+dy*axis[2]
        local across=dx*axis[2]-dy*axis[1]
        arrived=along>=-region.back and along<=region.front
            and (across/region.width)^2+(dz/region.height)^2<=1
    elseif region then
        assert(type(region.radius)=='number' and region.radius>0 and region.radius<=3
            and type(region.depth)=='number' and region.depth>0 and region.depth<=2,'arrival region')
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        -- ★ `above`（2026-09-28）：原来的判定是 `dz<=0`，即**必须在目标点下方**才算到达。
        --   那是给泰坦标定的：泰坦是高目标，seeker 会俯冲到它身下再攻击。
        --   虫洞在地上，G-60 绕着它飞时**一直在洞口上方** ——
        --   实机 5 个采样点里，水平距离够近的(1.39/1.45)全部 dz=+1.0~+1.1（在上方），
        --   高度够低的(dz=-0.03/-0.48)水平距离又是 1.79/2.22（超出 1.75）。
        --   **两个条件互斥 ⇒ G-60 在洞口绕圈 250 帧也从不引爆**（structure_stalled）。
        --   现在允许在洞口**上方** above 米以内引爆；不配 above 时行为与上游一致。
        local above=region.above or 0
        assert(type(above)=='number' and above>=0 and above<=2,'arrival region above')
        arrived=dx*dx+dy*dy<=region.radius^2 and dz<=above and dz>=-region.depth
    end
    if terminal and arrived then return 'detonate',nil,dist end
    local p=previous
    if not p or p.key~=key or now<p.at or distance(goal,p.goal)>3 or dist<p.best-0.3 then
        p={at=now,best=dist,key=key,goal={goal[1],goal[2],goal[3]}}
    end
    if now-p.at>=M.stalled_seconds then return 'search',nil,dist end
    return 'guide',p,dist
end
return M
