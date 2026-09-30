package.path='src/?.lua;'..package.path
local Route=require('g60.titan_route')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function target() return {point={0,0,6},body_center={0,0,8},origin={0,0,0},right={1,0,0}} end
local function near(a,b) return math.abs(a-b)<1e-6 end
test('overhead escape never commands a dive through the back',function()
    local t=target();local p=Route.step({0,0,14},t)
    assert(p.route.stage=='out' and not p.terminal and p.point[1]==12 and p.point[3]>=14)
    p=Route.step(p.point,t,p.route)
    assert(p.route.stage=='descend' and p.point[1]==12 and p.point[3]==4 and not p.terminal)
    p=Route.step(p.point,t,p.route)
    assert(p.route.stage=='under' and p.point[1]==0 and p.point[3]==4 and not p.terminal)
    p=Route.step(p.point,t,p.route)
    assert(p.route.stage=='attack' and p.terminal and p.point[3]==6)
end)
test('front approach follows outside chords before descending',function()
    local t=target();local own={0,14,14};local previous;local around=0
    for _=1,20 do
        local p=assert(Route.step(own,t,previous))
        if p.route.stage=='around' then
            around=around+1;assert(not p.terminal and p.point[3]==4)
            -- Every point on the commanded segment remains outside the foot envelope.
            for i=0,20 do
                local a=i/20;local x=own[1]*(1-a)+p.point[1]*a;local y=own[2]*(1-a)+p.point[2]*a
                assert(math.sqrt(x*x+y*y)>11)
            end
        end
        own=p.point;previous=p.route
        if p.terminal then break end
    end
    assert(around>=3 and previous.stage=='attack')
end)
test('side selection is stable and mirrored for left approach',function()
    local t=target();local p=Route.step({-2,0,12},t)
    assert(p.route.side==-1 and p.point[1]==-12)
    local old=p.route;p=Route.step({0.1,0,12},t,old)
    assert(p.route.side==-1 and old.stage=='out')
end)
test('route follows translation and yaw of Titan without changing chosen side',function()
    local t=target();local r={stage='descend',side=1,cruise_offset=8}
    local a=Route.step({12,0,14},t,r)
    t.point={10,20,7};t.origin={10,20,1};t.body_center={10,20,9};t.right={0,1,0}
    local b=Route.step({10,32,15},t,r)
    assert(a.point[1]==12 and near(b.point[1],10) and near(b.point[2],32) and b.point[3]==5)
    assert(r.stage=='descend' and b.route.side==1)
end)
test('grenade already below belly may approach directly; overhead recurrence reroutes',function()
    local t=target();local p=Route.step({0.2,0,3},t)
    assert(p.terminal)
    p=Route.step({0.2,0,12},t,p.route)
    assert(not p.terminal and p.route.stage=='out' and p.point[3]>=12)
end)
test('descending must reach outside point and height before moving inward',function()
    local t=target();local r={stage='descend',side=1,cruise_offset=8}
    assert(Route.step({12,0,10},t,r).route.stage=='descend')
    assert(Route.step({4,0,4},t,r).route.stage=='descend')
    assert(Route.step({12,0,4},t,r).route.stage=='under')
end)
test('invalid pose and insufficient belly clearance do not produce a waypoint',function()
    local t=target();t.origin[3]=6;assert(Route.step({0,0,14},t)==nil)
    t=target();t.right={0,0,1};assert(not pcall(Route.step,{0,0,14},t))
    t=target();assert(not pcall(Route.step,{0/0,0,14},t))
end)
test('side approach already below belly skips the exterior detour, but high or front approaches do not',function()
    local t=target()
    assert(Route.step({6,1,3},t).route.stage=='under')
    assert(Route.step({6,1,12},t).route.stage=='out')
    assert(Route.step({0,6,3},t).route.stage=='out')
end)
test('simultaneous exterior descent shortens the front approach without crossing the body',function()
    local function length(separate)
        local t=target();local own={0,14,14};local prior;local total=0
        for _=1,20 do
            local p=Route.step(own,t,prior)
            if separate and p.route.stage=='around' then p.point[3]=14 end
            local d=0;for j=1,3 do d=d+(p.point[j]-own[j])^2 end
            total=total+math.sqrt(d);own=p.point;prior=p.route
            if p.terminal then return total end
        end
        error('route did not converge')
    end
    assert(length(false)<length(true)-3)
end)
test('standoff final aim stays 2.5 metres below belly and follows target translation',function()
    local t=target();local p=Route.step({0,0,3},t,nil,2.5)
    assert(p.terminal and near(p.point[3],3.5))
    t.point={10,20,8};t.origin={10,20,2};t.body_center={10,20,10};t.right={0,1,0}
    p=Route.step({10,20,5},t,p.route,2.5)
    assert(p.terminal and p.point[1]==10 and p.point[2]==20 and near(p.point[3],5.5))
end)
test('standoff approach passes below the new explosion point before the final approach',function()
    local t=target();local own={0,0,14};local prior;local under_seen=false;local done=false
    for _=1,20 do
        local p=Route.step(own,t,prior,2.5)
        if p.route.stage=='under' then under_seen=true;assert(p.point[3]<3.5) end
        if p.terminal then assert(under_seen and p.point[3]==3.5);done=true;break end
        own=p.point;prior=p.route
    end
    assert(done)
end)
test('insufficient standoff clearance refuses instead of moving the blast back against the belly',function()
    local t=target();t.origin[3]=3
    assert(Route.step({0,0,5},t,nil,2.5)==nil)
    assert(not pcall(Route.step,{0,0,5},target(),nil,0/0))
end)
test('side corridor entry tolerates up to under+2.5 (2026-09-30 捷径②放宽,安全上限)',function()
    -- 默认 target：point={0,0,6} origin={0,0,0} standoff=2.5
    --   blast_z=3.5；under = max(6−3.5, 1.25) = 2.5
    --   ★ 门槛 own[3] ≤ 5.0（= under+2.5，安全上限：再高会被 own[3]>p[3]+0.5 退回线打回）
    --   4.2 ∈ (3.0, 5.0] ⇒ 只有放宽后的代码才命中 ⇒ 兼作"放宽确实生效"的守门。
    local p=Route.step({8,0,4.2},target(),nil,2.5)
    assert(p.route.stage=='under')
    -- 5.1 > 5.0 ⇒ 超出新上限，仍走默认绕行（钉住 +2.5 这个数值本身）
    local q=Route.step({8,0,5.1},target(),nil,2.5)
    assert(q.route.stage~='under')
end)
test('wider final region enters attack before perfect horizontal alignment but never above the body',function()
    local t=target();local p=Route.step({1.5,0,3},t,nil,2.5,1.75)
    assert(p.terminal and p.point[3]==3.5)
    p=Route.step({1.5,0,3},t,{stage='under',side=1,cruise_offset=8},2.5,1.75)
    assert(p.terminal)
    assert(not Route.step({1.8,0,3},t,nil,2.5,1.75).terminal)
    assert(not Route.step({1.5,0,12},t,nil,2.5,1.75).terminal)
end)
print('RESULT '..passed..' passed; 0 failed (geometric Titan route, no collision simulation)')
