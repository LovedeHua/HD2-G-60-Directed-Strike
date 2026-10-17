-- 泰坦引爆点与绕行航路的**最终决定者**（泰坦链第三段）。
--
-- 职责：消费 `titan_context` 的姿态输出（含 `animated_belly` 的腹法线），
--   ① 算出爆点 `c = 腹点 + 腹法线 × 2.5`；
--   ② 用 `Navigation` 的可见性图规划一条**不穿身**的航路；
--   ③ 决定「这一帧是否授权引爆」。
-- 安全语义：姿态不可靠、或爆点低于地板 ⇒ **不授权引爆**（宁可拒绝，也不硬炸进地里）。
--
-- ★ 爆点公式里的 2.5 是**制导/瞄准距离**，恒定不变；本模块不搬动它。
--   允许在哪一段（沿腹法线）授权引爆，由下面 `BAND_LO/BAND_HI` 那对常量控制 ——
--   见 `M.refine` 内 titan 分支处的完整说明（含实测数值与取舍）。
--
-- ⚠ `head/rear/underside/thorax` 四个分支需要 `WeakNavigation`（弱点专用导航）。
--   本工程没有弱点区数据（`weakpoint_profiles` 为空表）⇒ 那些分支**不可达**，
--   故显式保留为 no-op，而不是引入一套用不到的导航模块
--   （`WeakNavigation` 还依赖 `NavigationModels`/`WeakZones`）。
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
        -- ★★★ 2026-10-18（用户指定 outward 区间）：**[-0.35, +1.0]** ★★★
        --
        --   背景：用户报「G-60 会在泰坦腹部晃荡很久才引爆」，并要求「优化 outward 区间」。
        --   收敛过程（每步都实测）：[-0.1,+0.1]（捕获 80%）→ [-0.1,+0.8]（100% 但爆距被外扩
        --   吃成 2.72~3.30）→ [-0.3,+0.65]（100% + 2.85~3.15）→ [-0.35,+1.0]（更远）
        --   → [-0.45,+0.9]（收外沿 ⇒ 爆点内移、更贴腹部）→ **本次 [-0.35,+0.95]**。
        --
        --   ★ 机理（离线真求值得出，反直觉但关键）：手雷是**从外侧向腹部逼近**的，
        --     而判据是 `outward <= depth` ⇒ **第一个满足条件的帧就引爆**
        --     ⇒ 落点必然停在**外沿附近**，内沿几乎不经手。
        --       · **外沿 `depth` 决定「最远炸在哪」**（主要杠杆）
        --       · 内沿 `lo` 决定「最近炸在哪」；实测**放宽到 -0.45 之后完全饱和**
        --         （再往内是零收益 —— 因为手雷几乎总在外沿就炸了）
        --     ⇒ 前几版把窗口收窄成 [-0.1,+0.1] 时捕获率只有 ~80%
        --       （五分之一的情况炸不出来 ⇒ 只能重新绕圈 = 用户看到的「晃荡」）。
        --
        --   ★ 2026-10-18 起：用户定 **[−0.35, +0.95]**（爆距 2.15 ~ 3.45 m）
        --     —— 调整目的：**让爆点更接近泰坦腹部**。
        --     依据（实机日志 15 条 `titan_blast`，`entry_build;id=2886939`；
        --     `belly_dz` 在腹法线竖直时等于 −爆距，换算 outward = −belly_dz − 2.5）：
        --       · 有 **2 条**产出 outward **+0.98**（爆距 3.48 m）——**顶到了旧上限 +1.0**
        --         ⇒ 手雷确实是**贴着外沿**炸的，收紧外沿就能把爆点拉近腹部。
        --       · 其余 13 条落在 +0.19 ~ +0.78（2.69 ~ 3.28 m）
        --       · 最内 1 条 outward −0.54（1.96 m，低于旧下限 −0.35 —— 见下方引信线说明）
        --     ⇒ 旧窗口 15 条里 14 条在内；新窗口 12 条在内
        --       （2 条顶边的会被拒、继续飞近；1 条过内的不受影响，见下）。
        --
        --   ⚠ **外沿是唯一决定"最远炸在哪"的旋钮**（手雷从外侧逼近，第一个满足
        --     `outward<=depth` 的帧就引爆）⇒ 想更贴腹部，只能收外沿，不能靠动内沿。
        --   ⚠ 内沿放宽到 −0.45 之后**完全饱和**（再往内零收益）—— 它的作用是
        --     "允许更内的情况也能炸"，不是"把爆点拉近"。
        --
        --   ⚠ 内沿 −0.35 ⇒ 名义下限 **2.15 m**，仅比引擎引信线（实测 ~2.2 m）低 0.05 m，
        --     两次独立取证 2.22 / 2.25 m）0.15 m**。实测确有一条 1.96 m 的样本能炸
        --     ⇒ 要么该帧腹法线倾斜（`belly_dz` 只是垂直分量，不等于沿法线投影），
        --       要么那条是**引擎自己的引信**炸的。日志未记录法线，**无法区分**。
        --     若将来出现"引擎先炸"（爆点不由我们决定、且在更贴近腹部处伤害更小），
        --     第一件事就是把内沿收回 −0.30。
        --
        --   ⚠ 语义仍是「允许在哪一段授权引爆」，**不是**把瞄准点搬走：
        --     上面的 `c` 仍是 `腹点 + 腹法线 × 2.5`（恒定）⇒ **制导/飞行不变**。
        --   ⚠ 内沿(< 瞄准点 2.5)在瞄准点**内侧** ⇒ 需要 `region.lo` 为负；
        --     `arrival_policy` 原本写死 `outward>=0`，不放宽会把内沿那半静默砍掉。
        --     该字段缺省 0 ⇒ 不带它的区域与加这个字段之前逐字节等价。
        --
        --   ⚠ 这只是**窗口调参**（治法之一）。更彻底的治法是把吐酸泰坦改走
        --     "引擎真正用来算伤害的体素网格"那条路（见 `addon/entry.lua.in`
        --     里 `damage_regions` 处的说明）。本工程**未采用**那条路，原因写在那里。
        local BAND_LO,BAND_HI=2.15,3.45
        local lo=BAND_LO-2.5
        local depth=math.min(BAND_HI-2.5,(c[3]-floor)/(-n[3]))
        -- 净空把窗口压没了 ⇒ 与既有安全语义一致：**不授权引爆**（宁可拒绝，也不硬炸进地里）。
        -- ⚠⚠ 判据必须是「**窗口宽度**」而不是「`depth` 是否 >0」：
        --   瞄准点落在区间中点 ⇒ `lo` 是**负数**，净空不足时可能出现 `depth < lo`
        --   （窗口反了）。若只看 `depth>0` 就放过去，`arrival_policy` 里那条
        --   `lo<=depth` 断言会**抛错**，而调用方用 pcall 包着 ⇒ 错误被吞掉，
        --   表现是"泰坦**一整局**都不接管"（本工程反复栽过的静默失效）。
        --   ⚠ 两个条件都要：`depth>0` 是 `arrival_policy` 对 surface 区域的**硬断言**，
        --     单独用「宽度」判会在 `lo` 为负时放过 `depth<=0`。
        if depth<=0.02 or depth-lo<=0.02 then route.terminal=false;return route end
        local region={kind='surface',normal=copy(n),radius=2,depth=depth,min_z=floor,lo=lo}
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
        -- 弱点部位（头/尾/腹下/胸）在本工程**没有专用导航** ⇒ 落到下面的
        -- `return route`（= 本模块不对这些部位改写航路，由调用方的兜底处理）。
        -- ⚠ 这里原本有一个 `if WeakNavigation then … end` 分支，但本工程从未
        --   声明 `WeakNavigation`（也没有它依赖的 `NavigationModels`/`WeakZones`）
        --   ⇒ 那个 `if` **恒为假**、永不执行。删掉恒假分支不改变任何行为
        --   （已用运行时对拍确认：四种 kind 的输出逐位相同）。
    end
    return route
end
return M
