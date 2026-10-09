-- Custom arrival decision; original game explosion and clear/orbit executors.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Policy=require('g60.arrival_policy')
local Explosive=require('g60.explosive_context')
-- ★ 竞争态判定（2026-09-30）：与 native_priority 共用**同一份**分类，见 g60.priority_faults。
--   不写 `local Faults=require(...)`：build.py 会把 require 文本换成 chunk 别名，同名
--   local 就成了 `local Faults=Faults`（可读性差、易被误读成自引用），所以只取函数 ——
--   与 experimental_runtime 取 CONTENTION_LIMIT 的写法一致。
local competitive=require('g60.priority_faults').competitive
local M={}
local explode_type=ffi.typeof('void (*)(void *, uint32_t, uint32_t, void *)')
local setter_type=ffi.typeof('void (*)(void **, const void *)')
local orbit_type=ffi.typeof('void (*)(void **, float, float, float)')
local aim_type=ffi.typeof('void *(*)(void *, void **, const void *)')
function M.new(env)
    local disabled,busy=false,false
    local api={}
    function api:disabled() return disabled end
    -- ★★ 只读探测：这颗 G-60 的爆炸是否**已经触发**（2026-10-03）★★
    --
    -- 为什么要有它：runtime 需要在**写内存之前**短路掉一颗已爆的手雷。
    --   实机 2026-10-03 13:16 那局：12 次标记**全部**是"锁上即发现已爆" ——
    --   引擎（撞击 / 引信）在我们接管之前就把它炸了，实体还要留几帧；
    --   而我们照样收它 ⇒ 走完整 priority 路径（**含一次 setter 写内存**）
    --   + 打一条本来不该存在的 `priority_locked`，之后才在 arrival 段被
    --   `Explosive.capture` 判成 `explosion already requested`。
    --
    -- 判据**逐字同源**：直接跑 `Explosive.capture` 并只认那两条"已完成"文案
    --   —— 与 arrival 段、disposal 段、引导失败记账**同一把尺子**。
    --   ⇒ 不存在"我们自造的假阳性"（假阳性会把一颗**健康**的手雷提前退休，
    --     那比现在这点浪费严重得多 —— 所以不另造"轻量判据"）。
    --
    -- 成本：一次捕获（~20 次读）。调用方只在**首次接管那一帧**调它
    --   （已锁定的实体每帧本就不写 setter，见 runtime 的门控）。
    -- 返回：(true, 原始文案) = 已触发；(false) = 没有 / 无法判定 ⇒ 照常走。
    function api:triggered(read,identity)
        local ok,err=pcall(Explosive.capture,read,env.base,env.exe,identity,env.fuse_profile)
        if ok then return false end
        local s=tostring(err)
        if s:find('explosion already requested',1,true)
            or s:find('secondary explosion pending',1,true) then
            return true,s
        end
        return false
    end
    function api:step(scope,target,goal,stage,terminal,previous,mask_only,options)
        if disabled or busy then return nil,'ARRIVAL_DISABLED' end
        busy=true
        local mutated=false
        local ok,result=pcall(function()
            assert(ffi.os=='Windows' and ffi.abi('64bit'),'arrival ABI')
            assert(scope.experimental and not scope.native_lifetime_verified and scope.reference_is_observation_key,'arrival experimental scope')
            local c=scope.prepared;local record=c.record_bytes
            assert(c.ownership.local_ownership_observed and scope.validate(),'arrival scope unavailable')
            -- ★ 早期接管：env.allow_state3 时放行 state 2/3 —— 用于"无敌人时
            --   直接飞向虫洞"。引爆参数与 state 4 相同（region 由调用方传），
            --   飞行计时器由 source()/check 链路每次校验。
            local early=env.allow_state3 and (L.u32(record,8)==2 or L.u32(record,8)==3)
            assert(L.hex64(c.identity_bytes,0)=='8e325c933e55bf62' and L.u32(record,0)==4
                and (L.u32(record,8)==4 or early)
                and L.u32(record,0x68)==L.u32(c.identity_bytes,8),'arrival source')
            assert(ffi.istype(explode_type,scope.calls.explode) and ffi.istype(setter_type,scope.calls.clear)
                and ffi.istype(orbit_type,scope.calls.orbit),'arrival call ABI')
            local function source()
                assert(scope.validate() and scope.read(c.entity_address,24)==c.identity_bytes,'arrival source changed')
                return scope.read(c.state_address-8,0x1f8)
            end
            assert(source()==record,'arrival behavior changed')
            local pair=ffi.new('void *[2]',{ffi.cast('void *',c.entity_address),ffi.cast('void *',c.state_address)})
            local own=Data.vector(c.own_position_bytes,0)
            local now=Policy.elapsed(c.time_hex,c.flight_start)/1000000
            local ex=Explosive.capture(scope.read,env.base,env.exe,c.identity_bytes,env.fuse_profile)
            assert(ex.validate() and source()==record,'arrival preflight changed')
            local action,progress,dist='guide',nil,nil
            -- ★★「本帧飞行记录没有被外力改写」的参照快照 ★★
            --   默认 = 本帧读到的 record。于是 `source()==flight_reference` 的语义是
            --   "record 从本帧开始到现在没被动过"。
            --
            --   ⚠ 一旦**我们自己**往 record 里写过东西（下面的点目标 setter），参照就必须
            --   换成**写后回读**（`after`）—— 否则这个断言比较的是"我们写之前的世界"：
            --   只要引擎在这两帧之间给这颗 G-60 重新选过一次目标（它自己的 TargetLock
            --   正常在跑），写前快照 ≠ 写后内容 ⇒ 引爆帧必炸断言。
            --
            --   2026-10-01 实机（entity=577，第 8 次点目标接管）就这么死的：
            --     point_taken;entity=577;…;frame=19053
            --     point_guide;entity=577;dist=4.34;frame=19113      ← 已经飞到 4.3m
            --     arrival_skipped;…:2727: arrival trigger changed   ← 本断言
            --     frame_error;…:6586: arrival operation disabled    ← 整局熔断
            --     disabled;applied=0
            --   而它前面 7 次全部成功（`arrival_detonated;target=point`）—— 因为那几帧
            --   record 里还留着我们上一帧写的点（写前快照恰好等于写后内容），
            --   断言的**参照系错了**，只是恰好没暴露。
            local flight_reference=record
            -- ★★ 纯坐标目标（2026-10-01，用户要求"ping 一个位置 ⇒ G-60 飞过去炸"）★★
            --   `options.point_target={x,y,z}` 时，**没有实体**也要能引导：
            --   把玩家 ping 的地面点写成**点目标选择**，与泰坦路径完全同款写法
            --   （泰坦 `native_titan_aim` 每一帧都这么做，state 4 已实机验证）：
            --     ① candidate = 本 record 自己的 80 字节 selection 块（0x19..0x68）
            --     ② +0x00 ← invalid_id（= 不是实体目标，而是"点"）
            --     ③ +0x04 ← 三维坐标
            --     ④ +0x4c ← 0（类别掩码清零：过渡航点不得被当成引信目标）
            --   随后 `calls.clear(pair,data)` 提交，并回读三个不变量。
            --   ⚠ 与 titan 同款：本段**必须**在 Policy.step 之前写，否则这一帧
            --     引擎还按旧选择飞，arrival 的到达判定就会与真实飞行方向脱节。
            local want_point=options and options.point_target
            -- ★ 本帧"我们自己写进去的那个点"的原始字节（12 B）。
            --   2026-10-05：为了让 runtime 能把它记到锁上，从而让 priority 下一帧认出
            --   "记录里这个点是我们写的"（上游 `continued` / `guidance_observation`）。
            --   上游靠 `track.titan.point_bytes` 承载，我们的**体内爆点**是 runtime 现算的
            --   ⇒ 必须由写入者（本段）把字节交出去，否则上游那套机制在我们这里永不触发。
            --   ⚠ 只在该分支内赋值 ⇒ 走实体 `aim` 路径时它保持 nil（= "没有点"，语义正确）。
            local written_point
            if mask_only=='search' then action='search' end
            if (target or want_point) and not mask_only then
                if target then assert(target.validate(),'arrival target changed') end
                if want_point then
                    assert(type(want_point)=='table' and type(want_point[1])=='number'
                        and type(want_point[2])=='number' and type(want_point[3])=='number','point target shape')
                    local data=ffi.new('uint8_t[80]',record:sub(0x19,0x68))
                    ffi.cast('uint32_t *',data)[0]=scope.invalid_id
                    local xyz=ffi.cast('float *',data+4)
                    for i=0,2 do xyz[i]=want_point[i+1] end
                    ffi.cast('uint32_t *',data+0x4c)[0]=0
                    local point_bytes=ffi.string(data+4,12)
                    mutated=true;scope.calls.clear(pair,data)
                    local after=source()
                    assert(L.u32(after,0x18)==scope.invalid_id and after:byte(0x79)==1
                        and after:sub(0x1d,0x28)==point_bytes and L.u32(after,0x70)==scope.invalid_id,
                        'point setter postcondition')
                    -- ★ 写后快照成为本帧的参照（见 flight_reference 定义处的实机事故）
                    flight_reference=after
                    goal={want_point[1],want_point[2],want_point[3]}
                    written_point=point_bytes
                elseif not goal then
                    assert(c.selection.has_target and c.selection.id==target.id,'arrival selected target mismatch')
                    assert(ffi.istype(aim_type,scope.calls.aim),'arrival aim ABI')
                    local out=ffi.new('float[3]');local position=ffi.new('uint8_t[12]',c.own_position_bytes)
                    assert(scope.calls.aim(out,pair,position)==ffi.cast('void *',out),'arrival aim output')
                    goal=Data.vector(ffi.string(out,12),0);goal[3]=goal[3]+0.25
                    assert(target.validate() and ex.validate() and source()==record,'arrival aim observation changed')
                end
                -- ★★ 泰坦「腹部提前引爆」（2026-10-02，用户实机要求）★★
                --
                --   现状：`below` 要求 `own[3] <= goal[3]`。而泰坦的 goal **已经**是
                --   `blast_z = 腹点 - standoff`（比腹部低 0.85~2.5 m）⇒ 两个条件叠加，
                --   有效引爆窗口只剩 `dz ∈ [-depth, 0]` —— **必须在爆点或更低**。
                --   实机表现（用户原话）：「G-60 几乎都要在泰坦腹部盘旋很久才会引爆」——
                --   它到了腹部附近却够不到那个更低的爆点，就在窗口外绕圈。
                --
                --   ⇒ 允许在爆点**上方** `options.titan_belly_above` 以内引爆。
                --   ★ 余量由**调用方**按当前 standoff 约束（`≤ standoff-0.25`）⇒
                --     引爆点最高 = `腹点 - 0.25 m`，**仍在腹部下方**，
                --     不会退化成"在头顶炸"。
                --   ⚠ 缺省 0 ⇒ 与上游行为**逐字节等价**（只有泰坦路径显式传值时才放宽）。
                local titan_stage=stage:sub(1,6)=='titan/'
                local titan_above=0
                if titan_stage and options and type(options.titan_belly_above)=='number'
                    and options.titan_belly_above>0 then
                    titan_above=options.titan_belly_above
                end
                local region=options and options.region or titan_stage and env.titan_arrival_region or nil
                local below=not (titan_stage or options and options.below)
                    or own[3]<=goal[3]+titan_above
                -- ★ 上游 4012：`surface` 区域**自带**"从外侧靠近 + 地板"的判定
                --   ⇒ `below` 交给 Policy，不再叠加"必须在目标点下方"。
                --   没有这一句时，`surface` 区域会同时被两条互相矛盾的判据约束
                --   （法线要求从外侧来、`below` 要求低于点）⇒ 永远判不到 arrival。
                --   ⚠ 只放行 `surface`（我们支持的唯一"自带几何"区域）—— 不照抄
                --     `damage_grid` / `impaler_body`，那两个区域种类本工程没有。
                if region and region.kind=='surface' then below=true end
                action,progress,dist=Policy.step(now,own,goal,terminal and below,
                    tostring(target and target.id or 'point')..':'..stage,previous,region)
            end
            if action=='detonate' then
                assert((not target or target.validate()) and ex.validate()
                    and source()==flight_reference,'arrival trigger changed')
                mutated=true
                scope.calls.explode(ffi.cast('void *',ex.manager),ex.id,ex.invalid_source,nil)
                assert(scope.read(ex.network_address+1,1)=='\1','arrival request not committed')
                assert(source()==flight_reference,'arrival request changed flight state')
                -- ★ 2026-10-02：一并给出**引爆点的几何分解**（水平 / dz），只为诊断 ——
                --   三维 `distance` 分不清"偏侧"还是"贴脸"，而这两者的修法**相反**：
                --     · 偏侧（水平大）⇒ 只覆盖一侧 ⇒ 收紧 `radius`
                --     · 贴脸（dz 正、离腹部太近）⇒ 只覆盖腹部 ⇒ 关掉 `titan_belly_above`
                --   ⚠ 纯增量字段，不参与决策。
                local hx,hy=own[1]-goal[1],own[2]-goal[2]
                return {kind='detonate',distance=dist,target=target and target.id or 'point',
                    horizontal=math.sqrt(hx*hx+hy*hy),dz=own[3]-goal[3]}
            end
            if action=='search' then
                mutated=true;scope.calls.clear(pair,nil)
                local cleared=source()
                assert(L.u32(cleared,0x18)==scope.invalid_id and cleared:byte(0x79)==0,'arrival clear failed')
                scope.calls.orbit(pair,10,2.5,1.2000000476837158)
                assert(source():sub(0x189,0x190)==record:sub(0x189,0x190),'arrival orbit changed timer')
                return {kind='search',reason='arrival stalled or invalid target',blocked=target and {identity=target.identity,until_seconds=now+Policy.retry_seconds}}
            end
            -- Titan writes its own point immediately after this call. Other
            -- targets retain native aim selection with proximity categories zero.
            if stage:sub(1,6)~='titan/' and not (options and options.point)
                and c.selection.flag==1 and L.u32(record,0x64)~=0 then
                local raw=ffi.new('uint8_t[80]',record:sub(0x19,0x68))
                ffi.cast('uint32_t *',raw+0x4c)[0]=0
                mutated=true;scope.calls.clear(pair,raw)
                local after=source()
                assert(L.u32(after,0x64)==0 and after:byte(0x79)==1
                    and L.u32(after,0x18)==c.selection.id and L.u32(after,0x70)==c.selection.id,
                    'arrival proximity suppression failed')
                assert(after:sub(0x189,0x190)==record:sub(0x189,0x190),'arrival changed flight timer')
            end
            return {kind='guide',progress=progress,distance=dist,point_bytes=written_point}
        end)
        busy=false
        if not ok then
            -- ★★ 故障域隔离（2026-09-30 实机事故的直接修复）★★
            --   判定与 native_priority **完全同一份**（分类见 g60.priority_faults）。
            --   写后回读不符**不是**内存布局漂移，而是：引擎原生 TargetLock 在同一帧
            --   后写覆盖了同一块 record，或 clear 的效果落到 record 上有延迟。
            --   我们写进去的是**观测到的合法值**（proximity 抑制只是把 record 自身
            --   字节复制一份、把一个 uint32 清零），不会破坏内存 ⇒
            --   **只放弃这一颗 G-60，绝不 disabled**。
            --
            --   不做隔离的后果（22:10 那局实测，`grep proximity` 全文只有这一次）：
            --     arrival_skipped;…:2348: arrival proximity suppression failed
            --   ⇒ 下面一句 `if mutated … then disabled=true` 把 arrival 段永久关掉
            --   ⇒ runtime 下一帧 `error('arrival operation disabled')` ⇒ on_fatal
            --   ⇒ `disabled;applied=49` + close()：**整局 mod 停手、日志当场关闭**。
            --   用户看到的只是"虫洞标记失效了一次"，而根因是全局熔断。
            if competitive(result) then
                return {kind='quarantine',contended=tostring(result)}
            end
            -- ★ 早期接管（state 2/3）的失败**不计入**永久禁用：
            --   引擎对早期 state 的行为与 state 4 不同，失败很可能是正常现象
            --   （例如还没到可引爆的窗口），不该把 state-4 的引爆也一起废掉。
            --   早期路径自己的熔断由调用方（runtime 的 state3_danger）负责。
            if mutated and not (options and options.early) then disabled=true end
            return nil,tostring(result)
        end
        return result
    end
    return api
end
return M
