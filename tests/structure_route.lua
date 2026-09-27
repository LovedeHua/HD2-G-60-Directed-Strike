package.path='src/?.lua;'..package.path
local R=require('g60.structure_route')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local target={point={10,20,1},forward={0,1,0}}
test('hole approach transfers to front before terminal entry',function()
    local p={kind='structure_hole'}
    local a=R.step({10,10,8},target,nil,p);assert(not a.terminal and a.point[2]==25 and a.point[3]>=8)
    local b=R.step(a.point,target,a.route,p);assert(not b.terminal and b.point[3]==1.5)
    local c=R.step(b.point,target,b.route,p);assert(c.terminal and c.point[2]==21 and c.point[3]==1.5)
end)
test('hole entrance tolerates rim obstruction but rejects backside roof and transit',function()
    local P=require('g60.arrival_policy')
    for _,axis in ipairs({{0,1,0},{1,0,0},{-0.6,0.8,0}}) do
        local t={point={10,20,1},forward=axis}
        local r=R.step({10,25,1},t,{stage='attack'},{kind='structure_hole'})
        local function check(along,lateral,height,terminal)
            local own={r.point[1]+axis[1]*along+axis[2]*lateral,
                r.point[2]+axis[2]*along-axis[1]*lateral,r.point[3]+height}
            return P.step(1,own,r.point,terminal~=false,'hole',nil,r.arrival_region)
        end
        assert(check(1,1,0.3)=='detonate') -- Outside old 0.8 m sphere.
        assert(check(-0.5,0,0)=='detonate')
        for _,v in ipairs({{-1.01,0,0},{1.51,0,0},{0,1.51,0},{0,0,1.26},{0,0,-1.26},{0,1.3,1}}) do
            assert(check(v[1],v[2],v[3])=='guide')
        end
        assert(check(0,0,0,false)=='guide')
    end
end)
test('hole front direction rotates and zero direction is refused',function()
    local p={kind='structure_hole'};local t={point={10,20,1},forward={1,0,0}}
    local a=R.step({0,20,8},t,nil,p);assert(a.point[1]==15 and a.point[2]==20)
    t.forward={0,0,0};assert(not pcall(R.step,{0,0,0},t,nil,p))
end)
test('colony exterior waypoint does not arm early at the ordinary hole approach',function()
    local p={kind='structure_hole',front_distance=10.36}
    local a=R.step({10,25,1.5},target,nil,p)
    assert(not a.terminal and math.abs(a.point[2]-30.36)<1e-6)
    local b=R.step(a.point,target,a.route,p)
    assert(b.terminal and b.point[2]==21 and b.point[3]==1.5)
    for _,bad in ipairs({0,13,0/0}) do
        p.front_distance=bad;assert(not pcall(R.step,{10,25,1.5},target,nil,p))
    end
end)
test('tower holds one approach side and uses the elevated measured site',function()
    local p={kind='structure_tower'};local t={point={10,20,13}}
    local a=R.step({20,20,0},t,nil,p);assert(a.point[1]==12.5 and a.point[3]==13 and a.terminal)
    local b=R.step({0,20,0},t,a.route,p);assert(b.point[1]==12.5)
end)
test('egg blast stays close to the measured sack and does not detonate on a distant pass',function()
    local P=require('g60.arrival_policy')
    local t={point={10,20,1.1}};local p={kind='structure_egg'}
    local a=R.step({20,20,4},t,nil,p)
    assert(a.terminal and math.abs(a.point[1]-10.9)<1e-6 and a.point[3]==1.1)
    assert(P.step(1,{10.9,20,1.1},a.point,a.terminal,'egg')=='detonate')
    assert(P.step(1,{10.9,20,2.1},a.point,a.terminal,'egg')=='guide')
    local b=R.step({0,20,1.1},t,a.route,p);assert(b.point[1]==a.point[1])
    local c=R.step({10,20,5},t,nil,p);assert(c.point[1]==a.point[1])
end)
test('invalid positions are rejected',function()
    assert(not pcall(R.step,{0/0,0,0},target,nil,{kind='structure_hole'}))
end)
print('RESULT '..passed..' passed; 0 failed (marked structure geometry, no collision simulation)')
