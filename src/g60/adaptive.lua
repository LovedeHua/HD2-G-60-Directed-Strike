-- ★★★ 2026-10-05：逐字移植上游 1.1.0 的 `Adaptive`（用户拍板"泰坦方面全部改成上游"）★★★
--   它才是 `animated_belly` 的**消费者**：把泰坦引爆点从"竖直向下"改成
--     `c = 腹点 + 腹法线 × 2.5`，并用 `Navigation` 规划一条不穿身的航路；
--   姿态不可靠 / 爆点低于地板 ⇒ 不授权引爆（调用方按"我们兜底"处理）。
--   ⚠ 上游原文：`_refs/upstream-g60st-1.1.0-body.lua` 2943-3037，除下面这一处外逐字未改。
--   ⚠ 唯一改动：上游结尾的 `head/rear/underside/thorax` 分支调用 `WeakNavigation.refine`；
--     本工程没有 `weakpoint_profiles`（空表）⇒ 该分支**永不可达**，故置为显式 no-op，
--     而不是引入一个用不到的模块（`WeakNavigation` 依赖 `NavigationModels`/`WeakZones`）。
-- 0.5.24: visibility-graph Titan navigation, bounded lead, animated belly.
-- Prediction steers only. Detonation always uses the current observed region.
local Policy=require('g60.arrival_policy')
local Navigation=require('g60.navigation')
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function copy(p) return {p[1],p[2],p[3]} end
local function distance(a,b)
    return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
end
local function heading(v)
    local n=math.sqrt(v[1]^2+v[2]^2);assert(n>0.5 and n<2,'adaptive heading')
    return v[1]/n,v[2]/n
end
local function contains(own,c,r)
    return Policy.step(0,own,c,true,'adaptive',nil,r)=='detonate'
end
local function ellipsoid_goal(own,c,r)
    local dx,dy,dz=own[1]-c[1],own[2]-c[2],own[3]-c[3]
    local fx,fy=r.forward[1],r.forward[2]
    local q=math.sqrt(((dx*fx+dy*fy)/r.length)^2+((-dx*fy+dy*fx)/r.width)^2+(dz/r.height)^2)
    local s=q>0.75 and 0.75/q or 1
    return {c[1]+dx*s,c[2]+dy*s,c[3]+dz*s}
end
function M.observe(t,previous,profile,now)
    assert(type(now)=='number' and now>=0 and now<30,'adaptive clock')
    local prior=previous and previous.motion
    local dt=prior and now-prior.at
    local valid_dt=dt and dt>=0.001 and dt<=0.25
    local motion={at=now,body=copy(t.body_center),hold_until=prior and prior.hold_until or 0,
        signature=t.pose_signature}
    local kind=profile.kind or 'titan'
    local rx,ry=heading(t.right)
    local fx,fy
    if t.forward then fx,fy=heading(t.forward) else fx,fy=-ry,rx end
    motion.forward={fx,fy}
    if kind=='titan' then
        motion.outward=t.belly_outward and copy(t.belly_outward)
        -- Whole-body pitching also rotates the belly even when its body-local
        -- articulation is unchanged. Translation alone still never adds delay.
        if motion.outward and prior and prior.outward and valid_dt then
            local dot=0;for i=1,3 do dot=dot+motion.outward[i]*prior.outward[i] end
            if dot<math.cos(math.rad(math.max(2,45*dt))) then motion.hold_until=now+0.15 end
        end
        if t.pose_signature and prior and prior.signature and valid_dt then
            local shift=distance(t.pose_signature,prior.signature)
            local dot=0;for i=4,6 do dot=dot+t.pose_signature[i]*prior.signature[i] end
            if shift>math.max(0.035,1.5*dt) or dot<math.cos(math.rad(math.max(2,45*dt))) then
                motion.hold_until=now+0.15
            end
        end
        if t.pose_unreliable then motion.hold_until=now+0.15 end
    end
    return motion
end
function M.refine(own,t,previous,profile,route,now)
    if profile.structure then return route end
    local motion=M.observe(t,previous,profile,now)
    route.route.motion=motion
    local kind=profile.kind or 'titan'
    if kind=='titan' then
        local n=t.belly_outward or {0,0,-1}
        local p=t.point;local floor=t.origin[3]+1.25
        local c={p[1]+n[1]*2.5,p[2]+n[2]*2.5,p[3]+n[3]*2.5}
        if c[3]<floor+0.1 or t.pose_unreliable then
            route.terminal=false;return route
        end
        local depth=math.min(0.8,(c[3]-floor)/(-n[3]))
        local region={kind='surface',normal=copy(n),radius=2,depth=depth,min_z=floor}
        route.arrival_point=c;route.arrival_region=region
        if contains(own,c,region) then
            route.point=copy(own);route.terminal=now>=motion.hold_until
            route.route.stage='attack';route.route.blast_zone='titan_navigation'
            route.route.navigation={mode='arrived'}
        else
            local prior_nav=previous and previous.navigation and previous.navigation.state
            local plan,reason=Navigation.plan(own,t,c,region,prior_nav,now)
            if not plan then
                -- No unsafe direct fallback. The existing route remains guidance
                -- only; its waypoint cannot authorize an explosion.
                route.terminal=false;route.route.navigation={mode='unavailable',reason=reason}
            else
                route.point=plan.point;route.terminal=plan.terminal and now>=motion.hold_until
                route.route.stage=plan.terminal and 'attack' or 'around'
                route.route.blast_zone='titan_navigation'
                route.route.navigation={mode=plan.mode,state=plan.state,length=plan.length,nodes=plan.nodes}
            end
        end
    elseif kind=='head' or kind=='rear' or kind=='underside' or kind=='thorax' then
        if WeakNavigation then return WeakNavigation.refine(own,t,previous,profile,route,now) end
    end
    return route
end
return M
