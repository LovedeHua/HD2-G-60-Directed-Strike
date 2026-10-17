-- Arrival uses the current positions, never a historical segment crossing.
local M={radius=0.8,stalled_seconds=4,retry_seconds=5,lifetime_ticks=30000000}
function M.elapsed(now,start)
    assert(type(now)=='string' and #now==16 and type(start)=='string' and #start==16 and now>=start,'arrival clock')
    return (tonumber(now:sub(1,8),16)-tonumber(start:sub(1,8),16))*4294967296
        +tonumber(now:sub(9),16)-tonumber(start:sub(9),16)
end
local function distance(a,b)
    local v=0
    for i=1,3 do
        assert(type(a[i])=='number' and a[i]==a[i] and math.abs(a[i])<1000000,'arrival position')
        assert(type(b[i])=='number' and b[i]==b[i] and math.abs(b[i])<1000000,'arrival goal')
        v=v+(a[i]-b[i])^2
    end
    return math.sqrt(v)
end
function M.step(now,own,goal,terminal,key,previous,region)
    assert(type(now)=='number' and now>=0 and now<30,'arrival time bound')
    local dist=distance(own,goal)
    local arrived=dist<=M.radius
    if region and region.kind=='entrance' then
        local axis=region.forward
        assert(type(axis)=='table' and type(axis[1])=='number' and type(axis[2])=='number'
            and math.abs(axis[1]^2+axis[2]^2-1)<0.001,'entrance axis')
        for _,key in ipairs({'back','front','width','height'}) do
            assert(type(region[key])=='number' and region[key]>0 and region[key]<=2,'entrance bounds')
        end
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        local along=dx*axis[1]+dy*axis[2]
        local across=dx*axis[2]-dy*axis[1]
        arrived=along>=-region.back and along<=region.front
            and (across/region.width)^2+(dz/region.height)^2<=1
    elseif region and region.kind=='surface' then
        -- ★★ `surface` 区域（2026-10-05）★★
        --   语义：沿**法线**定义"到达" —— `outward = (own-goal)·n` 必须落在
        --   `[lo, depth]`（`lo` 缺省 0 = 表面的**外侧**，见下方 `region.lo` 说明）、
        --   横向偏移不超过 `radius`，并且不低于地板 `min_z`。
        --   为什么需要它：泰坦蜷曲时腹法线会**倾斜**，爆点因此侧向跟着走；
        --   圆柱区域（下面那支）表达不了"从腹面外侧靠近"，只能表达"在点下方"。
        --   ⚠ `axis[3]<=-0.25` = 法线必须**朝下**（否则说明姿态已有问题，不该授权引爆）。
        local axis=region.normal
        assert(type(axis)=='table' and type(axis[1])=='number' and type(axis[2])=='number'
            and type(axis[3])=='number' and axis[3]<=-0.25
            and math.abs(axis[1]^2+axis[2]^2+axis[3]^2-1)<0.001,'surface region normal')
        assert(type(region.radius)=='number' and region.radius>0 and region.radius<=3
            and type(region.depth)=='number' and region.depth>0 and region.depth<=2,'surface region bounds')
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        local outward=dx*axis[1]+dy*axis[2]+dz*axis[3]
        local tangent=dx*dx+dy*dy+dz*dz-outward*outward
        -- ★★ 2026-10-16（用户要求）：**内沿 `lo` 可略为负** ★★
        --   原实现这里是 `outward>=0`：只允许在爆点**外侧**（离腹部更远）引爆。
        --   用户要求"上下范围 2.4~2.6"，而瞄准点就在 2.5（区间中点）⇒
        --   2.4 那一侧必然落在瞄准点**内侧**（`outward<0`）⇒ 必须放宽下沿，
        --   否则区间会被悄悄砍掉一半（用户看到的现象是"我设了 2.4，它只在 2.5~2.6 炸"）。
        --   ⚠ 惰性：不带 `lo` 的区域 ⇒ `lo=0` ⇒ **逐字节等价于加 `lo` 之前**（守门钉住）。
        --   ⚠ `lo` 仍是"离腹部的安全余量"：它只允许**贴近**瞄准点 0.1 m 量级，
        --     真正"炸进地里"由下面的 `min_z` 拦（同一道闸）。
        local lo=region.lo or 0
        assert(type(lo)=='number' and lo<=region.depth,'surface inner edge')
        arrived=outward>=lo and outward<=region.depth and tangent<=region.radius^2
        if region.min_z then
            assert(type(region.min_z)=='number' and math.abs(region.min_z)<1000000,'surface floor')
            arrived=arrived and own[3]>=region.min_z
        end
    elseif region and region.kind=='ellipsoid' then
        -- ★★ 2026-10-18 修复：`ellipsoid` 区域原本**没有判定分支** ★★
        --   症状：`blast_route.lua` 的 `head` / `rear` 两个分支构造的是
        --   `kind='ellipsoid'` 区域，但这里没有对应支 ⇒ 掉进下面的通用支
        --   （那条要求 `radius`+`depth`）⇒ `'arrival region'` 断言**每次必抛错**
        --   ⇒ 调用方 `pcall` 吞掉 ⇒ `weakpoint_profiles` 里
        --   `kind=head/rear` 的 4 个目标（1a7fcdff / 3aff5fd7 / a05bd1ec / fd524765）
        --   **永远拿不到本帧的航路结果**。
        --   实测（修前）：任何几何都返回 `ok=false, err="…:67: arrival region"`。
        --
        --   语义与 `BlastRoute.guide()` 对同一区域的处理**保持一致**：以 `center` 为原点、
        --   沿 `forward`（水平单位轴）分解成 `along`/`across`，三个半轴
        --   `length`（前后）/`width`（左右）/`height`（上下），归一化椭球面内即"到达"。
        --   ⇒ `q<=1` 与 `guide()` 里 `q>0.8` 的阈值同一套坐标，不会出现
        --     "引导去的地方判不成到达"这种矛盾。
        --   ⚠ `forward` 必须是**水平单位向量**（`blast_route` 用 `<world_heading>/n` 保证）。
        local axis=region.forward
        assert(type(axis)=='table' and type(axis[1])=='number' and type(axis[2])=='number'
            and math.abs(axis[1]^2+axis[2]^2-1)<0.001,'ellipsoid axis')
        for _,k in ipairs({'length','width','height'}) do
            assert(type(region[k])=='number' and region[k]>0 and region[k]<=3,'ellipsoid bounds')
        end
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        local along=dx*axis[1]+dy*axis[2]
        local across=-dx*axis[2]+dy*axis[1]
        arrived=(along/region.length)^2+(across/region.width)^2+(dz/region.height)^2<=1
    elseif region then
        assert(type(region.radius)=='number' and region.radius>0 and region.radius<=3
            and type(region.depth)=='number' and region.depth>0 and region.depth<=2,'arrival region')
        local dx,dy,dz=own[1]-goal[1],own[2]-goal[2],own[3]-goal[3]
        -- ★ `above`（2026-09-28）：原来的判定是 `dz<=0`，即**必须在目标点下方**才算到达。
        --   那是给泰坦标定的：泰坦是高目标，seeker 会俯冲到它身下再攻击。
        --   虫洞在地上，G-60 绕着它飞时**一直在洞口上方** ——
        --   实机 5 个采样点里，水平距离够近的(1.39/1.45)全部 dz=+1.0~+1.1（在上方），
        --   高度够低的(dz=-0.03/-0.48)水平距离又是 1.79/2.22（超出 1.75）。
        --   **两个条件互斥 ⇒ G-60 在洞口绕圈 250 帧也从不引爆**（structure_stalled）。
        --   现在允许在洞口**上方** above 米以内引爆；不配 above 时行为与之前一致。
        --
        -- ★★ 2026-09-30：球形判定（`dx²+dy²+dz²<=radius²`）**试过一版，实机效果很差，
        --   已回滚**为下面这个圆柱。教训：圆柱"水平/垂直各自独立"在纸面上看反直觉
        --   （水平 1.9+dz 1.15 通过、水平 0.2+dz 0.9 被拒），但它是**按泰坦体型
        --   实机标定过的**；擅自改成各向同性会连带改变 G-60 的接近姿态与引爆时机，
        --   用户实测判定为明显变差 ⇒ 形状不再动，只调数值。
        local above=region.above or 0
        assert(type(above)=='number' and above>=0 and above<=2,'arrival region above')
        arrived=dx*dx+dy*dy<=region.radius^2 and dz<=above and dz>=-region.depth
    end
    if terminal and arrived then return 'detonate',nil,dist end
    local p=previous
    if not p or p.key~=key or now<p.at or distance(goal,p.goal)>3 or dist<p.best-0.3 then
        p={at=now,best=dist,key=key,goal={goal[1],goal[2],goal[3]}}
    end
    if now-p.at>=M.stalled_seconds then return 'search',nil,dist end
    return 'guide',p,dist
end
return M
