-- ★★★ 2026-10-05：本文件已**逐字恢复为上游 1.1.0 的 TitanRoute**（用户拍板"泰坦方面全部改成上游"）★★★
--
-- 历史（我们曾有两处偏离上游，都带注释与实测依据，本次按用户要求**全部撤回**）：
--   ① 高度门槛从上游的 `under` 加 0.5 抬到加 2.5（2026-09-30，为让"腿间侧带捷径"命中，
--      避免每次绕 12 m 外圈）
--   ② `forward` 门槛从上游的 2.5 放宽到 `RADIUS`（2026-10-02 用户明确授权，
--      取消"必须从腿间侧带进"）
--   ★ 现在回到上游原值（两个门槛都是上游的），且该捷径**只在接管首帧**评估
--     （上游就把它写在 `else` 分支里，见 1233-1251）。
--   ⚠ 上面两处旧写法**不得再出现**在代码里 —— 由 tests/test_bughole_scope.py 的
--     `TITAN_ROUTE_FORBIDDEN` 硬性禁止（那两处都会改变接近姿态与引爆时机）。
--
-- 上游对应位置：`_refs/upstream-g60st-1.1.0-body.lua` 第 1205-1293 行，逐字节可对。
-- ⚠ 唯一保留的**非行为**差异：返回值多带 `under` / `forward` / `distance` 三个**诊断**字段
--   （供 `native_titan_aim` 的 `titan_probe;` 打印，不参与任何决策）。
--   为此把 `forward` 提到函数顶部计算 —— 纯函数、与上游在 `else` 分支里的同名计算**同值**。
--
-- Geometric experimental approach, not a collision query or terrain navigation.
-- Route state belongs to one grenade/target identity; all points follow the body.
local M={}
local RADIUS=12 -- Bind feet extend about nine metres radially; allow extra margin.
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<1000000 end
local function vector(v)
    assert(type(v)=='table' and finite(v[1]) and finite(v[2]) and finite(v[3]),'invalid route vector')
end
function M.step(own,target,previous,standoff,terminal_radius)
    vector(own);vector(target.point);vector(target.body_center);vector(target.origin)
    local p=target.point
    standoff=standoff or 0 -- Legacy callers retain their original contact point.
    terminal_radius=terminal_radius or 1.25
    assert(finite(terminal_radius) and terminal_radius>0 and terminal_radius<=3,'invalid terminal radius')
    assert(finite(standoff) and standoff>=0 and standoff<=10,'invalid Titan standoff')
    local blast_z=p[3]-standoff
    local floor=target.origin[3]+1.25 -- Pose-relative lower bound, not terrain sampling.
    if standoff>0 and blast_z<floor then return nil,'Titan has insufficient blast standoff clearance' end
    local rx,ry=target.right[1],target.right[2]
    assert(finite(rx) and finite(ry),'invalid route heading')
    local norm=math.sqrt(rx*rx+ry*ry)
    assert(norm>0.5 and norm<2,'Titan body heading unavailable')
    rx,ry=rx/norm,ry/norm
    local dx,dy=own[1]-p[1],own[2]-p[2]
    local radius=math.sqrt(dx*dx+dy*dy)
    -- ★ 诊断用（上游在 else 分支内计算，值相同；提到此处只为让它能进返回值）
    local forward=math.abs(-dx*ry+dy*rx)
    local under=math.max(p[3]-math.max(2,standoff+1),floor)
    if under>p[3]-0.6 then return nil,'Titan has insufficient observed belly clearance' end
    local route
    if previous then
        -- Never mutate a saved route before the native setter succeeds.
        route={stage=previous.stage,side=previous.side,cruise_offset=previous.cruise_offset}
    else
        route={stage='out',side=dx*rx+dy*ry<0 and -1 or 1}
        route.cruise_offset=own[3]-p[3]
        if own[3]>p[3]+0.5 then
            route.cruise_offset=math.max(route.cruise_offset,target.body_center[3]+2-p[3])
        end
        -- A grenade already centrally below the belly need not circle outside.
        if radius<=terminal_radius and own[3]<=p[3]-0.6 then route.stage='attack' end
        -- Already below the belly and inside the side corridor: go inward,
        -- without first travelling out to the full twelve-metre ring.
        if radius>terminal_radius and radius<=RADIUS and forward<=2.5 and own[3]<=under+0.5 then
            route.stage='under'
        end
    end
    assert(route.side==1 or route.side==-1,'invalid route side')
    assert(finite(route.cruise_offset),'invalid route cruise height')
    local sx,sy=rx*route.side,ry*route.side
    local ux,uy=sx,sy
    if radius>0.01 then ux,uy=dx/radius,dy/radius end
    local dot=math.max(-1,math.min(1,ux*sx+uy*sy))
    local angle=math.acos(dot)
    local side_x,side_y=p[1]+sx*RADIUS,p[2]+sy*RADIUS
    local side_distance=math.sqrt((own[1]-side_x)^2+(own[2]-side_y)^2)
    -- If motion/reselection puts it back above the body, never dive through it.
    if (route.stage=='under' or route.stage=='attack') and own[3]>p[3]+0.5 then
        route.stage='out'
        route.cruise_offset=math.max(own[3]-p[3],target.body_center[3]+2-p[3])
    end
    if route.stage=='out' and radius>=RADIUS-1 then route.stage='around' end
    if route.stage=='around' and angle<=math.rad(8) and radius>=RADIUS-1 then route.stage='descend' end
    if route.stage=='descend' and side_distance<=1.75 and math.abs(own[3]-under)<=0.75 then route.stage='under' end
    if route.stage=='under' and radius<=terminal_radius and own[3]<=p[3]-0.6 then route.stage='attack' end
    local point
    if route.stage=='out' then
        point={p[1]+ux*RADIUS,p[2]+uy*RADIUS,p[3]+route.cruise_offset}
    elseif route.stage=='around' then
        -- Small chords around the outside, rather than a diagonal across the back.
        local turn=math.min(angle,math.rad(20))
        if ux*sy-uy*sx<0 then turn=-turn end
        local c,s=math.cos(turn),math.sin(turn)
        -- Once outside the back/foot envelope, descend while following the
        -- exterior arc. No separate wait for the whole arc at cruise height.
        point={p[1]+(ux*c-uy*s)*RADIUS,p[2]+(ux*s+uy*c)*RADIUS,under}
    elseif route.stage=='descend' then
        point={side_x,side_y,under}
    elseif route.stage=='under' then
        point={p[1],p[2],under}
    elseif route.stage=='attack' then
        point={p[1],p[2],blast_z}
    else error('unknown Titan route stage') end
    vector(point)
    -- ⚠ `under` / `forward` / `distance` 为**诊断增量**（上游只返回前三个字段）。
    --   `distance` = 到 `target.point` 的平面距离 —— 与调用方自己算的"到本帧目标点的距离"
    --   是两回事，日志里必须分开标，否则会误读成"贴着泰坦"。
    return {point=point,route=route,terminal=route.stage=='attack',under=under,forward=forward,
        distance=radius}
end
return M
