-- 泰坦链**第二段**：把一个几何爆区叠到接近航路上。
--
-- 对 `kind=="titan"` 给出**圆柱**爆区：`center = 腹点 - (0,0,2.5)`、`radius=2`、
--   `depth = min(0.8, 腹点 - 2.5 - origin - 1.25)`，
--   并置 `terminal` / `arrival_point` / `arrival_region`。
-- 随后 `adaptive.lua` 在姿态可靠时**覆盖**成"腹法线点 + `surface` 区域"
--   ⇒ 本模块的实际价值主要在**姿态不可靠时的兜底几何**。
--
-- ⚠⚠ **已知缺陷（2026-10-18 核实，未修）**：`head` / `rear` 两个分支构造的是
--   `kind='ellipsoid'` 区域，而下面的 `contains()` 会把它交给
--   `ArrivalPolicy.step`，后者**硬性要求** `region.depth>0`（`'arrival region'` 断言）
--   ⇒ `ellipsoid` 没有 `depth` ⇒ **每次调用必抛错**，被调用方的 `pcall` 吞掉。
--   后果：`weakpoint_profiles` 里 `kind=head/rear` 的 4 个目标
--   （`1a7fcdff…` / `3aff5fd7…` / `a05bd1ec…` / `fd524765…`）走到这里就**丢失本帧的
--   航路结果**。**这不是本轮引入的**，而是从纳入该数据结构起就存在；
--   修它属于**改行为**（要让 `ellipsoid` 也能判定到达），故本轮只标注、不修改。
--   ⚠ 另注：本文件里 `charger` 相关几何对**泰坦链不可达**（`native_titan_aim`
--     把 `kind=='charger_front'` 先送去 `Charger.step`），但那些分支与
--     `head/rear` 共用同一个 `do` 块，未拆分。
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

-- 头/尾：主轴上的椭球 + 两侧"甲壳侧带"。两段各自独立产出 zone，
-- 用同名参数登记，避免两处 `rear and … or …` 各写一遍。
local function axis_zone(p,own,kind,fx,fy,rear)
    local ahead=(own[1]-p[1])*fx+(own[2]-p[2])*fy
    local across=math.abs(-(own[1]-p[1])*fy+(own[2]-p[2])*fx)
    local offset=rear and 1.3 or 1.4
    return {id=kind,
        center={p[1]+fx*offset,p[2]+fy*offset,p[3]-(rear and 0.3 or 0)},
        region={kind='ellipsoid',forward={fx,fy},
            length=rear and 1.2 or 1.25,width=rear and 1.4 or 1.2,
            height=rear and 0.85 or 0.9},
        reachable=ahead>=0 and across<=3 and (not rear or own[3]<=p[3]+0.4)}
end
local function side_zones(own,c,rx,ry,axis_x,axis_y,fwd_x,fwd_y,rear,p)
    -- All three Charger variants share this body/leg reference layout.
    -- Preserve the tested Behemoth side geometry for head profiles.
    -- ⚠ `axis_x/axis_y` 是**可能已被 rear 取负**的前向轴（用于 longitudinal，取 abs 后无差别）；
    --   `fwd_x/fwd_y` 是**未取负**的原始前向轴 —— `center` 必须用它，否则尾部的侧带
    --   会前后错位 1.0 m。这两个值在原实现里是两个不同的变量，重构时不可合并。
    local out={}
    for _,sign in ipairs({-1,1}) do
        local sx,sy=rx*sign,ry*sign
        local lateral=(own[1]-c[1])*sx+(own[2]-c[2])*sy
        local longitudinal=math.abs((own[1]-c[1])*axis_x+(own[2]-c[2])*axis_y)
        out[#out+1]={id='side'..sign,
            center={c[1]+sx*2.2-fwd_x*0.5,c[2]+sy*2.2-fwd_y*0.5,rear and p[3] or c[3]-0.38},
            region={kind='ellipsoid',forward={sx,sy},length=0.4,width=0.6,height=0.5},
            reachable=lateral>=1.8 and longitudinal<=2 and own[3]<=c[3]+1}
    end
    return out
end
function M.refine(own,target,previous,profile,base)
    if profile.structure or profile.kind=='charger_front' then return base end
    local p=target.point;local kind=profile.kind or 'titan'
    local rx,ry=heading(target.right)
    local zones={};local low_side=false
    if kind=='head' or kind=='rear' then
        local rear=kind=='rear'
        local fx,fy=heading(target.forward)
        local forward_x,forward_y=fx,fy
        if rear then fx,fy=-fx,-fy end
        zones[1]=axis_zone(p,own,kind,fx,fy,rear)
        local c=target.body_center
        local sides=side_zones(own,c,rx,ry,fx,fy,forward_x,forward_y,rear,p)
        local floor_z=target.origin[3]+0.3
        for _,z in ipairs(sides) do
            z.reachable=z.reachable and own[3]>=floor_z
            zones[#zones+1]=z
        end
    else
        assert(kind=='titan' or kind=='thorax' or kind=='underside','unsupported blast profile')
        local underside=kind=='underside'
        local standoff=underside and 0.4 or 2.5
        local depth=underside and math.min(0.6,p[3]-standoff-target.origin[3]-0.3) or 0.8
        if kind=='titan' then
            depth=math.min(depth,p[3]-standoff-target.origin[3]-1.25)
            if depth<=0.05 then return base end
        end
        assert(depth>0,'blast region lacks lower clearance')
        local radius=underside and 1.2 or 2.0
        zones[1]={id=kind,center={p[1],p[2],p[3]-standoff},region={radius=radius,depth=depth}}
        local forward=math.abs(-(own[1]-p[1])*ry+(own[2]-p[2])*rx)
        low_side=forward<=(underside and 2 or 2.5) and own[3]<=zones[1].center[3]
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
