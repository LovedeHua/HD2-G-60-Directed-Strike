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
    -- ★ 2026-10-02：原断言是 `around>=3 and previous.stage=='attack'`。
    --   `around>=3` 的前提（"前方接近**必须**绕至少 3 帧外圈弦线"）**已按用户要求作废**
    --   —— 用户实机：「还是会从侧面绕到腹部，准确说是从**侧面到后面再到腹部**」，
    --   那正是这段绕行；捷径② 现已改为**每帧评估** ⇒ 够近够低的当帧就中断绕行。
    --   ⚠ **脚区安全属性原样保留**（上面 `>11` 那条）：只要处于 `around`，指令线段不得进脚区。
    assert(previous.stage=='attack')
end)
-- ★★ 2026-10-05：捷径② **恢复上游语义**（用户拍板「泰坦方面全部改成上游 1.1」）★★
--   上游把它写在 `else` 分支里 ⇒ **只在接管首帧评估**；第一帧没命中就靠 `previous` 继承
--   stage，后续帧**不再重估**。
--   （我们曾改成"每帧评估"以治「从侧面绕到后面再到腹部」；该改法现已按用户要求撤回。）
test('side corridor shortcut is evaluated on the first takeover frame only (upstream)',function()
    local t=target()
    assert(Route.step({6,1,3},t).route.stage=='under')   -- 首帧够近够低 ⇒ 直接 under
    local p=Route.step({6,1,14},t)                       -- 位置太高 ⇒ 不命中
    assert(p.route.stage=='out')
    p=Route.step({6,1,3},t,p.route)                      -- 带 previous ⇒ **不再重估**
    assert(p.route.stage=='out')
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
-- ★★ 2026-10-05：捷径② 的 `forward<=RADIUS` **恢复为上游的 `forward<=2.5`**（用户拍板）★★
--   ⇒ 只有"**腿间侧带**"（前后轴偏移 ≤2.5 m）才允许直接内收；
--     正前方（forward≈6）**仍然必须绕外圈** —— 这正是我们当初授权改掉、现在按用户要求改回的行为。
test('side corridor entry requires forward<=2.5 (upstream); a frontal approach still detours',function()
    local t=target()
    assert(Route.step({6,1,3},t).route.stage=='under')     -- 侧方、够低 ⇒ 直接内收
    assert(Route.step({0,6,3},t).route.stage~='under')     -- ★ 正前方（forward=6>2.5）⇒ 上游行为：绕
    assert(Route.step({6,1,12},t).route.stage=='out')      -- 够低但**位置太高** ⇒ 绕外圈
    assert(Route.step({0,6,12},t).route.stage=='out')
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
-- ★★ 2026-10-05：高度门槛 `under+2.5` **恢复为上游的 `under+0.5`**（用户拍板）★★
--   ⚠ 我们当初把 `+0.5` 抬到 `+2.5` 是为了让捷径命中（否则每次都绕 12 m 外圈）。
--     现按用户要求回到上游 ⇒ 命中窗口显著收窄，绕行会变多 —— 这是**上游的原始行为**。
test('side corridor entry height gate is upstream under+0.5',function()
    -- 默认 target：point={0,0,6} origin={0,0,0} standoff=2.5
    --   blast_z=3.5；under = max(6−3.5, 1.25) = 2.5 ⇒ 门槛 own[3] ≤ 3.0
    local p=Route.step({8,0,2.9},target(),nil,2.5)
    assert(p.route.stage=='under')                     -- 2.9 ≤ 3.0 ⇒ 命中
    local q=Route.step({8,0,4.2},target(),nil,2.5)     -- 4.2 > 3.0 ⇒ 上游行为：绕
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
