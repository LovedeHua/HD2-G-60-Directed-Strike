package.path='src/?.lua;'..package.path
local Route=require('g60.charger_route')
local Policy=require('g60.arrival_policy')
local p={standoff=0.5,region={radius=1.25,depth=0.6}}
local function target(x,y)
    return {point={x or 0,y or 0.59,1.763},origin={x or 0,y or 0,0},body_center={x or 0,y or 0,2.151},right={1,0,0}}
end
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('from overhead or behind, Charger route exits above body then descends before terminal approach',function()
    for _,start in ipairs({{0,0,8},{0,-2,3},{6,0,3}}) do
        local own=start;local prior;local done=false
        for i=1,8 do
            local r=assert(Route.step(own,target(),prior,p,i*.05))
            if r.terminal then assert(own[3]<=r.arrival_point[3] and r.point[3]<r.arrival_point[3]);done=true;break end
            if r.route.stage=='out' then assert(r.point[3]>=own[3]) end
            own=r.point;prior=r.route
        end
        assert(done)
    end
end)
test('low grenade remains in attack when a charging target passes or reverses direction',function()
    local own={0,0,1};local a=Route.step(own,target(0,-1),nil,p,1)
    local b=Route.step(own,target(0,1),a.route,p,1.1)
    local c=Route.step(own,target(0,-1),b.route,p,1.2)
    assert(a.terminal and b.terminal and c.terminal)
    assert(b.lead[2]>0 and c.lead[2]<0 and a.route.sample[2]==-1)
end)
test('bounded lead changes guidance but arrival stays at the currently observed body',function()
    local a=Route.step({0,-8,1},target(),nil,p,1)
    local t=target(0,1.99);local b=Route.step({0,-8,1},t,a.route,p,1.1)
    assert(b.lead[2]>0 and b.lead[2]<=3 and b.arrival_point[2]==1.99)
    local near_prediction={b.point[1],b.point[2],b.point[3]}
    assert(Policy.step(1.1,near_prediction,b.arrival_point,true,'charger',nil,p.region)~='detonate')
end)
test('skipped frames, clock reversal and implausible displacement discard velocity',function()
    local a=Route.step({0,-8,1},target(),nil,p,1)
    for _,case in ipairs({{1,1.5},{1,.9},{20,1.1}}) do
        local b=Route.step({0,-8,1},target(0,case[1]),a.route,p,case[2])
        assert(b.lead[1]==0 and b.lead[2]==0)
    end
end)
test('moving-target synthetic kinematics reach current arrival region at several charge speeds',function()
    for _,speed in ipairs({4,12,20}) do
        local own={-5,-5,1};local previous;local done=false
        for i=1,160 do
            local now=i*.05;local t=target(0,speed*now)
            local r=Route.step(own,t,previous,p,now)
            if Policy.step(now,own,r.arrival_point,r.terminal,'charger',nil,p.region)=='detonate' then done=true;break end
            local d=0;for k=1,3 do d=d+(r.point[k]-own[k])^2 end;d=math.sqrt(d)
            for k=1,3 do own[k]=own[k]+(r.point[k]-own[k])*math.min(1,22*.05/d) end
            previous=r.route
        end
        assert(done,'synthetic speed '..speed)
    end
end)
test('insufficient belly clearance is rejected and a waypoint never goes below the root bound',function()
    local t=target();t.point[3]=1
    assert(Route.step({0,0,3},t,nil,p,1)==nil)
    assert(not pcall(Route.step,{0,0,1},target(),nil,p,0/0))
end)
print('RESULT '..passed..' passed; 0 failed (Charger routes and synthetic motion; no game physics)')
