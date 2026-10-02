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
    -- ★ 2026-10-02：`forward` 从下面的 `else` 分支**提到这里** ——
    --   只为让返回值也能带上它（诊断的**单一来源**：不再在调用方重算一遍公式，
    --   避免"日志与实现不一致"那类误导；公式与行为一字未改）。
    --   含义：G-60 在泰坦**前后轴**上的偏移量。
    --     `<=2.5` = 位于"腿间侧带"（正侧方 ±2.5 m）⇒ 捷径② 的唯一入口。
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
        --
        -- ★ 2026-09-30（锚点例外）：高度门槛 `under+0.5` → **`under+2.5`**。
        --   实机证据：4 次泰坦接管的 `titan_started;…;stage=` **全是 `around`**
        --   ⇒ 这条捷径**从未命中过**，每次都得绕 12 m 外圈（实测单次绕行 3.0~4.7 s，
        --   还常因 `under → out` 退回重来，最坏 ~14 s）。
        --   ★ **2.5 是数学上的安全上限**，不是拍脑袋：
        --     下方有兜底"高于 `p[3]+0.5` 就退回 out 重绕" ⇒ 门槛**最高只能到 `p[3]+0.5`**，
        --     再高就是"命中即被退回"，白改。由 `under = max(p_z − max(2, standoff+1), floor)`：
        --       standoff=0.85（自适应下限，最坏）: under=p_z−2.0 ⇒ **X ≤ 2.5**
        --       standoff=2.5（名义值）:           under=p_z−3.5 ⇒ X ≤ 4.0
        --     ⇒ 取 **X=2.5** 覆盖所有 standoff；此时门槛恰贴退回线（等于不算高于 ⇒ 不退）。
        --   门槛效果：standoff=2.5 ⇒ 低于腹部 **1.0 m**；standoff=0.85 ⇒ **腹部上方 0.5 m 以内**。
        --   安全性：进入点最高 `p[3]+0.5`，仍低于泰坦身体上半部，且退回兜底保留。
        --
        --   ★★ 2026-10-02（用户**明确授权**）：`forward<=2.5` → **`forward<=RADIUS`** ★★
        --   = **取消"必须从腿间侧带进入"的限制**。
        --   依据（用户实机原话）：「即使我站在泰坦前方丢 G60，G60 也会从侧面绕到腹部，
        --   而不是直接飞到腹部引爆」。代码层验证：从正前方来 ⇒ `forward` ≈ 5~15
        --   ⇒ **永久不命中**本条 ⇒ 只能走 `out → around`（绕 12 m 外圈转到侧面）
        --   ⇒ 实机日志 8/8 泰坦接管全是 `stage=around`，本条**从未命中过一次**。
        --   ⇒ 现在任何 12 m 内、高度够低的 G-60 都**直接奔向腹部正下方**。
        --   ⚠ 仍然保留的两条硬约束（不可撤）：
        --      · `radius<=RADIUS` —— 仍在 12 m 包围圈内（泰坦脚外接圆 + 余量）
        --      · `own[3]<=under+2.5` —— 高度必须已在腹部附近（防从上方穿身体）
        --   ⚠ 已知风险（知情）：从正前方直飞可能**穿过前腿** ⇒ 炸在腿边、伤不到腹部。
        --     若实测"炸不死泰坦"，把这里改回 `2.5` 即完全恢复旧行为。
        --   ⚠ `forward` 已在函数顶部算好（提到那里只为让返回值也带上它，见那段注释）——
        --     这里**不再重复定义**，避免遮蔽出两个语义不同的同名变量。
        --
        --   ★★★ 2026-10-02（第二次修复）：判定语句**已移到下方「捷径②【每帧】」** ★★★
        --   它原来**只在这个 `else`（= `previous==nil`，接管的第一帧）里评估** ⇒
        --   第一帧往往还太高/太远 ⇒ 不命中 ⇒ 之后 `route.stage` 从 `previous` **继承**
        --   ⇒ 这条捷径**再也不会被评估** ⇒ 只能走完 `out → around`（绕 12 m 外圈）。
        --   实机佐证：用户「还是会从侧面绕到腹部，准确说是从**侧面到后面再到腹部**」——
        --   那正是 `around` 沿外圈转一整段的表现；而 `titan_probe` 显示绕行期间
        --   `under_dz ≤ 2.5`、`forward ≤ 12` **经常已经满足**
        --   （如 `stage=around;dz=-0.04;forward=5.47;under_dz=-0.04`）却始终停在 `around`。
        --   ⇒ 现在改为**每帧评估**（见下方）："够近 + 够低"的当帧就中断绕行、直奔腹部下方。
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
    -- ★★★ 捷径②【每帧】：从 `out`/`around` **直接内收到腹部正下方**（2026-10-02）★★★
    --   原来这条判定只在 `else`（接管第一帧）里评估 ⇒ 第一帧没命中就**永远不再评估**
    --   ⇒ 只能绕 12 m 外圈（用户：「从侧面到后面再到腹部」）。现在**每帧**评估。
    --   判据（来历见 `else` 分支里那段完整说明）：
    --     · `radius>terminal_radius` —— 还没到最终接近距离（到了就该走 attack）
    --     · `radius<=RADIUS`         —— 仍在 12 m 包围圈内（泰坦脚外接圆 + 余量）
    --     · `forward<=RADIUS`        —— 2026-10-02 用户授权：取消「必须从腿间侧带进」
    --     · `own[3]<=under+2.5`      —— 高度必须已在腹部附近（防从上方穿身体）
    --   ⚠ 与上方"退回 out"**不会互跳**：退回要求 `own[3]>p[3]+0.5`，本条要求
    --     `own[3]<=under+2.5`，而 `under+2.5 = p[3]-max(2,standoff+1)+2.5 ≤ p[3]+0.5`
    --     （standoff≥0.85）⇒ 两个区间**不重叠**，不可能来回抖。
    --   ⚠ 只在 `out`/`around` 生效：`descend`/`under`/`attack` 的前进与退回规则照旧。
    if (route.stage=='out' or route.stage=='around')
        and radius>terminal_radius and radius<=RADIUS and forward<=RADIUS
        and own[3]<=under+2.5 then
        route.stage='under'
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
    -- ★ 2026-10-02：把 `under` / `forward` / `distance` 一并返回，**只为诊断**（`titan_probe;`）。
    --   ⚠ `distance` = 到 **`target.point`** 的平面距离；它与调用方自己算的
    --     "到 `point`（本帧目标点）的距离"是**两回事** —— 之前日志里把后者标成了
    --     `radius=` 极具误导性（`around` 阶段目标点在 12 m 外圈上，读出来像"贴着泰坦"）。
    --   ⚠ 纯增量字段，不参与任何决策；调用方不读也不影响行为。
    return {point=point,route=route,terminal=route.stage=='attack',under=under,forward=forward,
        distance=radius}
end
return M
