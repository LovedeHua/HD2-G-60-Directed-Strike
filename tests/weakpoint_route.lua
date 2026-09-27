package.path='src/?.lua;'..package.path
local Route=require('g60.weakpoint_route')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function target()
    return {point={0,1.5,2.2},body_center={0,0,2.5},origin={0,0,0},right={1,0,0},forward={0,1,0}}
end
test('Charger from behind or overhead reaches a front-head final approach without terminal transit',function()
    for _,start in ipairs({{0,-3,2},{0,0,8},{-7,-4,2}}) do
        local t=target();local p={kind='head'};local own=start;local previous;local done=false
        for _=1,30 do
            local r=assert(Route.step(own,t,previous,p))
            if r.terminal then assert(r.point[2]>t.point[2] and own[2]>=t.point[2]);done=true;break end
            assert(r.route.stage~='attack');own=r.point;previous=r.route
        end
        assert(done)
    end
end)
test('moving and turning Charger invalidates a previously frontal attack',function()
    local t=target();local a=Route.step({0,3,2},t,nil,{kind='head'});assert(a.terminal)
    t.point={0,-1.5,2.2};t.forward={0,-1,0};t.right={-1,0,0}
    local b=Route.step({0,3,2},t,a.route,{kind='head'});assert(not b.terminal)
    assert(a.route.stage=='attack')
end)
test('Impaler underside uses low side approach and never puts its waypoint below the root clearance',function()
    local t=target();t.point={0,-0.3,1.76};local p={kind='underside',standoff=0.4}
    local own={0,0,7};local previous;local done=false
    for _=1,30 do
        local r=assert(Route.step(own,t,previous,p));assert(r.point[3]>=0.3)
        if r.terminal then assert(math.abs(r.point[3]-1.36)<1e-5);done=true;break end
        own=r.point;previous=r.route
    end
    assert(done);t.point[3]=0.7;assert(Route.step(own,t,nil,p)==nil)
end)
test('airborne Dragonroach keeps its standoff relative to chest, independent of root height',function()
    local t=target();t.point={0,1.2,20};t.body_center={0,0.7,22};t.origin={0,0,21}
    local p={kind='thorax',standoff=2.5};local own={0,1.2,17};local r=Route.step(own,t,nil,p)
    assert(r.terminal and r.point[3]==17.5)
    local above=Route.step({0,1.2,25},t,r.route,p);assert(not above.terminal and above.point[3]>=25)
end)
test('nonrepresentable belly height guides inside its arrival band instead of onto the upper boundary',function()
    local t=target();t.point={0,0,1.76}
    local r=Route.step({0,0,1},t,nil,{kind='underside',standoff=0.4,region={radius=0.8,depth=0.4}})
    assert(r.terminal and math.abs(r.arrival_point[3]-1.36)<1e-6 and math.abs(r.point[3]-1.16)<1e-6)
end)
test('Behemoth approaches rear flab from outside and below the rear armor',function()
    local t=target();t.point={0,-2.34,1.77};t.body_center={0,0,2.151}
    for _,start in ipairs({{0,6,3},{0,-2.34,8},{0,0,1},{0,-5,1.47}}) do
        local own=start;local prior;local done=false
        for i=1,40 do
            local r=assert(Route.step(own,t,prior,{kind='rear'}))
            if r.terminal then
                assert(own[2]<=t.point[2] and own[3]<=t.point[3]+.2)
                assert(math.abs(r.point[2]+2.74)<1e-6 and math.abs(r.point[3]-1.47)<1e-6)
                done=true;break
            end
            if own[3]==1 and r.route.stage=='out' then assert(r.point[3]==1) end
            own=r.point;prior=r.route
        end
        assert(done)
    end
end)
test('rear route reroutes when a body turn places the grenade ahead of the abdomen',function()
    local t=target();t.point={0,-2.34,1.77}
    local a=Route.step({0,-3,1.47},t,nil,{kind='rear'});assert(a.terminal)
    t.forward={0,-1,0};t.right={-1,0,0};t.point={0,2.34,1.77}
    local b=Route.step({0,-3,1.47},t,a.route,{kind='rear'});assert(not b.terminal)
    assert(a.route.stage=='attack')
end)
test('new route rejects invalid heading and non-finite positions',function()
    local t=target();t.forward={0,0,1};assert(not pcall(Route.step,{0,0,1},t,nil,{kind='head'}))
    t=target();assert(not pcall(Route.step,{0/0,0,1},t,nil,{kind='head'}))
end)
print('RESULT '..passed..' passed; 0 failed (weakpoint geometric routes)')
