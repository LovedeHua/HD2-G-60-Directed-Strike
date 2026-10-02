-- User-authorized experimental point-candidate setter. No executable writes.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Context=require('g60.titan_context')
local Route=require('g60.titan_route')
local WeakRoute=require('g60.weakpoint_route')
local StructureRoute=require('g60.structure_route')
local ArrivalPolicy=require('g60.arrival_policy')
local M={}
local setter=ffi.typeof('void (*)(void **, const void *)')
local orbit=ffi.typeof('void (*)(void **, float, float, float)')
local valid=ffi.typeof('bool (*)(void *, uint32_t, const void *)')
function M.new(env)
    local disabled,busy=false,false
    -- ★ 净空诊断的去重集合（2026-09-29）
    -- 同一目标的同一原因/同一 standoff 只记一次，避免逐帧刷屏把别的信息埋掉。
    local clearance_logged={}
    local standoff_logged={}
    local api={}
    function api:step(scope,previous)
        if disabled or busy then return nil,'TITAN_OPERATION_DISABLED' end
        if ffi.os~='Windows' or not ffi.abi('64bit') then return nil,'TITAN_ABI_UNSUPPORTED' end
        busy=true
        local mutated=false
        local ok,result=pcall(function()
            assert(scope.experimental and not scope.native_lifetime_verified
                and scope.reference_is_observation_key,'experimental Titan window required')
            local c=scope.prepared;local record=c.record_bytes
            assert(c.ownership.local_ownership_observed and scope.validate(),'Titan scope unavailable')
            assert(L.hex64(c.identity_bytes,0)=='8e325c933e55bf62'
                and L.u32(record,0)==4 and L.u32(record,8)==4
                and L.u32(record,0x68)==L.u32(c.identity_bytes,8),'Titan source mismatch')
            local calls=scope.calls
            assert(ffi.istype(setter,calls.clear) and ffi.istype(orbit,calls.orbit)
                and ffi.istype(valid,calls.target_valid),'Titan call ABI mismatch')
            local resource=c.selection.has_target and scope.snapshot.selected and scope.snapshot.selected.resource
            -- ★ 查找顺序：泰坦优先（2026-09-29）
            -- 原上游顺序是 weakpoint → structure → titan，最后判泰坦。
            -- 那个顺序有个隐患：`env.weakpoint_profiles` 里登记着 7 个**敌人**
            -- （head/rear/thorax/underside），一旦本函数拿到敌人目标，
            -- 就会用敌人的弱点几何去引导 G-60。
            -- 进入本函数的唯一条件是 runtime 的 `titan_selected`（已限定泰坦资源），
            -- 所以现在**逻辑上不可达**；但把泰坦放第一位可以让这个不变量
            -- 由代码本身保证，而不是依赖"调用方一定传对了"——
            -- 跨模块的隐式约定正是 2026-09-29 越权 bug 的成因。
            -- ★ 解析顺序：基线泰坦 → 变体 → 虫洞 → 弱点敌人
            --   变体必须在基线之后、其它之前：它们的几何是借来的（同 unit 目录），
            --   与基线同族，不该落到后面的分支。
            --   用 `~=nil` 判空而非真值判断 —— profile 是表，恒真，但显式更好读。
            local profile=resource and ((resource==env.titan_profile.resource) and env.titan_profile
                or (env.titan_variant_profiles or {})[resource]
                or (env.structure_profiles or {})[resource]
                or (env.weakpoint_profiles or {})[resource])
            local fresh=profile~=nil and profile~=false
            if not fresh and previous and previous.target then profile=previous.target.profile or env.titan_profile end
            local owned_point=previous and not c.selection.has_target and c.selection.flag==1
                and record:sub(0x1d,0x28)==previous.point_bytes
            assert(fresh or (previous and (owned_point or c.selection.cleared)), 'Titan selection changed')
            local candidate=fresh and record:sub(0x19,0x68) or previous.candidate
            local target,reason,own_position,route
            if not (previous and previous.cancelled and not fresh) then
                local id=fresh and c.selection.id or previous.target.id
                local same=previous and previous.target and previous.target.id==id and previous.target or nil
                local captured,value=pcall(Context.capture,scope.read,env.base,env.exe,id,profile,same)
                if captured then target=value else reason=tostring(value) end
            end
            local function check()
                assert(scope.validate(),'Titan scope expired')
                assert(scope.read(c.entity_address,24)==c.identity_bytes,'Titan projectile changed')
                local r=scope.read(c.state_address-8,0x1f8)
                assert(r:sub(0x189,0x190)==record:sub(0x189,0x190),'Titan flight timer changed')
                assert(r:sub(1,12)==record:sub(1,12),'Titan behavior changed')
                return r
            end
            assert(check()==record,'Titan projectile state changed')
            if target then
                assert(type(c.own_position_bytes)=='string' and #c.own_position_bytes==12,'Titan projectile position unavailable')
                local own=ffi.new('uint8_t[12]',c.own_position_bytes)
                local xyz=ffi.cast('float *',own);local distance=0
                own_position={tonumber(xyz[0]),tonumber(xyz[1]),tonumber(xyz[2])}
                for i=0,2 do distance=distance+(target.point[i+1]-tonumber(xyz[i]))^2 end
                if not (distance<40000) then target=nil;reason='Titan point outside projectile range bound' end
            end
            if target then
                assert(target.validate(),'Titan target changed')
                -- ★ 裁剪 K（第三处，也是最关键的一处）：`target_valid` 硬否决 → 软信号。
                --
                -- 上游这里是 `if not alive then target=nil;reason='Titan no longer alive' end`，
                -- 而它**每个飞行帧都会跑**。虫巢没有 HealthComponent ——
                -- 原生 target_valid（game.dll+0x8858a0，索敌系统的函数）可能对
                -- "实际存在但引擎不认"的巢返回 false ⇒ target 每帧被置 nil
                -- ⇒ 永远算不出航点 ⇒ G-60 飞到附近也不会引爆。
                --
                -- 这解释了"priority_locked 出现了、却没有 titan_aim"的那些失败案例。
                -- 改成：原生说 false 时做**只读复核**（实体可读 / identity 未变 / 位置可读），
                -- 复核通过就继续规划航点，只发诊断；复核也失败才真的放弃。
                local alive=calls.target_valid(nil,target.id,ffi.cast('const void *',target.address))
                assert(scope.validate() and target.validate(),'Titan target changed during validation')
                if not alive then
                    -- 只读复核：复用 Context.capture（它本来就在每帧重新读该实体），
                    -- 能成功重读并拿到有效 pose 就说明实体还在，只是原生不认它。
                    local ok, again = pcall(Context.capture, scope.read, env.base, env.exe,
                                             target.id, profile, target)
                    local why = 'ALIVE_BY_READ'
                    if not ok then why = 'CAPTURE_FAILED' end
                    if ok and type(again)=='table' and type(again.validate)=='function'
                        and not again.validate() then
                        ok, why = false, 'POSE_INVALID'
                    end
                    if ok then
                        if env.emit then env.emit('structure_target_soft_invalid;target='..tostring(target.id)
                            ..';native=false;readonly='..why..';context=TITAN') end
                    else
                        local tid = target and target.id or '?'
                        target=nil;reason='Titan gone: '..tostring(why)
                        if env.emit then env.emit('structure_unavailable;target='..tostring(tid)
                            ..';detail='..tostring(why)..';context=TITAN') end
                    end
                end
            end
            if target then
                local prior=previous and not previous.cancelled and previous.target.id==target.id
                    and previous.route or nil
                local planned,value,detail
                local route_standoff=env.titan_standoff
                if profile.structure then
                    planned,value,detail=pcall(StructureRoute.step,own_position,target,prior,profile)
                elseif profile.kind then
                    local now=profile.kind=='charger_front' and ArrivalPolicy.elapsed(c.time_hex,c.flight_start)/1000000 or nil
                    planned,value,detail=pcall(WeakRoute.step,own_position,target,prior,profile,now)
                else
                    -- ★★ standoff 自适应 1.5~2.5（2026-09-29，用户明确授权）★★
                    --
                    -- titan_route 的净空判定是**硬拒绝**：
                    --     blast_z(=p_z-standoff) >= floor_z(=origin_z+1.25)
                    -- ⇒ 要求 p_z >= origin_z + 1.25 + standoff
                    --   ★ 2026-09-30：离地余量**保持上游原值 1.25**（不动）——
                    --     降它只会让爆点更低、更远离腹部（实机：离腹部远、贴地、炸不死泰坦）。
                    --     真正该放宽的是**下限 `lo`**：让 standoff 能缩到更小，
                    --     即爆点贴近腹部（伤害集中）。现已收到 0.5。
                    -- 泰坦站姿/坡度稍变就踩线（实测 4 次接管有 1 次因此放弃 = 25%）。
                    --
                    -- 用户授权把 standoff 从 2.5 收到 1.5 ⇒ 在**调用方**算出
                    -- "刚好能清空地板"的值再传进去。`titan_route.lua` 因此保持
                    -- 逐字节不变（它是 tests/test_bughole_scope.py 的 `untouched:` 安全层）。
                    --
                    -- ★ 2026-09-30：曾把 floor 余量（1.25）与 standoff 下限（→0/0.5）
                    --   先后调小试验，**实机效果都不好，已全部回滚到本行这一版**：
                    --   floor 余量回到上游的 1.25（titan_route 逐字节恢复），
                    --   standoff 自适应范围回到用户授权的 1.5~2.5。
                    --   ⇒ 教训：这条净空链上的数值是上游按泰坦体型标定的，别再逐项试小。
                    --
                    -- ⚠️ 与上游意图的取舍（必须记录）：上游有一条测试写明
                    --   "refuses instead of moving the blast back against the belly"，
                    --   即宁可放弃也不把爆点往腹部压。这里**由用户明确决定**放宽：
                    --   1.5 仍是有效 standoff（不会贴到腹部），用它换"不再因几厘米净空差放弃"。
                    --   max_standoff 连 1.5 都不到时 Route.step 依然拒绝 —— 硬底线保留。
                    local max_standoff=target.point[3]-(target.origin[3]+1.25)
                    if route_standoff and route_standoff>0 and max_standoff<route_standoff then
                        -- ★★ 2026-10-02：默认下限 **0.85 → 2.0**（用户裁定，逐级实测所得）。
                        --   理由见 `addon/entry.lua.in` 里那段完整记录：
                        --   · 0.85 太松：允许爆点贴到腹下 0.85 m ⇒ "偶尔在离腹部极近处引爆"
                        --   · 1.75 实测**仍会偶尔炸不死**（贴腹区间还是太宽）
                        --   · 2.5（= 不许缩短）过于严格：腹部压低时直接拒绝、手雷干等
                        --   · 2.0 最终取值 ⇒ `max(lo, max_standoff)` 恒 ≥ 2.0
                        --     （收缩区间只剩 2.0~2.5）
                        --   腹部低到连 2.0 都放不下时 `titan_route` 拒绝规划，
                        --   运行时把它当**等待**（不是引导失败）。
                        --   回退：0.85（松）/ 1.75 / 2.5（严）。
                        local lo=env.titan_standoff_min or 2.0
                        route_standoff=math.max(lo,max_standoff)
                        local tag=tostring(target.id)..'|'..string.format('%.2f',route_standoff)
                        if env.emit and not standoff_logged[tag] then
                            standoff_logged[tag]=true
                            env.emit(string.format(
                                'titan_standoff_adapted;target=%s;from=%.2f;to=%.2f;min=%.2f;max=%.2f',
                                tostring(target.id),env.titan_standoff,route_standoff,lo,max_standoff))
                        end
                    end
                    planned,value,detail=pcall(Route.step,own_position,target,prior,route_standoff,
                        env.titan_arrival_region and env.titan_arrival_region.radius)
                end
                if planned then route,reason=value,detail else reason=tostring(value) end
                if not route then
                    -- ★★ 净空不足的几何画像（2026-09-29）★★
                    --
                    -- `titan_route` 拒绝时只返回文本，看不出"差多少"。而区分下面两种
                    -- 情况**决定了完全不同的改法**：
                    --   · 只差 0.1~0.3m  → 调 floor 余量就能救
                    --   · 差 2m 以上     → 泰坦站在坑里，任何参数调整都无解
                    --
                    -- 数值在这里（调用方）补，**不是**去改 titan_route.lua ——
                    -- 那个文件属于"安全层逐字节不可变"（tests/test_bughole_scope.py 的
                    -- `untouched:` 守卫）。上游还有一条测试明令
                    -- "refuses instead of moving the blast back against the belly"，
                    -- 所以 `standoff` 不能缩、爆点不能往腹部压，可动的只有判定余量。
                    --
                    -- 只对几何/净空类拒绝记录；其它拒绝不是几何问题，记了是噪音。
                    if env.emit and type(reason)=='string'
                        and (reason:find('clearance',1,true) or reason:find('belly',1,true)) then
                        local tag=tostring(target.id)..'|'..reason
                        if not clearance_logged[tag] then
                            clearance_logged[tag]=true
                            -- 用**实际传入**的 standoff（可能是自适应后的值），
                            -- 否则日志会显示 2.5 而实际用的是别的 ⇒ 误导。
                            local standoff=route_standoff or env.titan_standoff or 0
                            local p=target.point
                            local o=target.origin
                            env.emit(string.format(
                                'titan_clearance;target=%s;p_z=%.2f;origin_z=%.2f;floor_z=%.2f;'
                                ..'blast_z=%.2f;short=%.2f;standoff=%.2f;need_p_z=%.2f',
                                tostring(target.id),p[3],o[3],o[3]+1.25,
                                p[3]-standoff,math.max(0,(o[3]+1.25)-(p[3]-standoff)),
                                standoff,o[3]+1.25+standoff))
                        end
                    end
                    target=nil
                end
            end
            local arrival_progress
            if target and env.arrival then
                local stage=(profile.kind and 'weakpoint/'..profile.kind or 'titan')..'/'..route.route.stage
                local options=profile.kind and {point=true,below=not profile.structure and profile.kind~='head' and profile.kind~='rear',region=route.arrival_region or profile.region}
                -- ★★ 泰坦「腹部提前引爆」余量（2026-10-02，用户要求"飞到腹部底下就引爆"）★★
                --   与 native_arrival 的 `below` 配合：允许在爆点
                --   （`blast_z = 腹点 - standoff`）**上方** belly 以内引爆，
                --   让 G-60 不必先够到那个更深的爆点（那正是"在腹部盘旋很久"的来源）。
                --   ★ 上限由 standoff 约束：引爆点最高 = blast_z + belly ≤ 腹点 - 0.25 m
                --     ⇒ **仍在腹部下方**，不会退化成"在头顶炸"。
                --   ★ 只对泰坦 baseline 生效：弱点路径（`profile.kind`）不传该字段
                --     ⇒ native_arrival 侧缺省 0 ⇒ 弱点行为逐字节不变。
                --   ⚠ `env.titan_belly_above` 置 0（或不配）⇒ 完全回到旧行为。
                if not profile.kind and env.titan_belly_above and route_standoff then
                    local limit=route_standoff-0.25
                    if limit>0 then
                        local belly=math.min(env.titan_belly_above,limit)
                        if belly>0 then options={titan_belly_above=belly} end
                    end
                end
                -- ★ 泰坦接近诊断（2026-10-02）：每 30 次调用一条，给出**实际几何**。
                --   为什么必须：用户报"在腹部盘旋很久才引爆"时，日志里**只有 stage 变化**，
                --   看不出"盘旋多久、卡在哪个高度、窗口差多少" ⇒ 只能猜。
                --   ⚠ 用 `self._probe_n` 计数（`self` 是参数，不占 upvalue ——
                --     `api:step` 的 pcall 匿名函数 upvalue 余量有限）。
                if env.emit and not profile.kind then
                    self.probe_n=(self.probe_n or 0)+1
                    if self.probe_n>=30 then
                        self.probe_n=0
                        local dx,dy=own_position[1]-route.point[1],own_position[2]-route.point[2]
                        -- ★ 2026-10-02 新增 `forward` / `under_dz`：
                        --   `forward` = G-60 在泰坦**前后轴**上的偏移（来自 titan_route 的
                        --     返回值，单一来源）—— 捷径② 要求 `<=2.5`（腿间侧带）。
                        --     用户实机观察「站在泰坦正前方丢，G-60 仍从侧面绕」⇒
                        --     这条是判断"放宽到多少能命中"的**唯一数据**。
                        --   `under_dz` = 当前高度 − 捷径②解锁所需的 `under` 高度
                        --     （<=0 表示高度条件已满足，剩下的只卡在 forward 上）。
                        local udz=route.under and (own_position[3]-route.under) or 0
                        -- ★ 2026-10-02 新增 `p_z` / `belly_dz`：
                        --   `p_z` = **腹点高度**（`target.point[3]`，来自腹骨 pose ⇒ 随吐酸等
                        --      动画下降）；`belly_dz` = `own_z - p_z`（**负 = 在腹部下方几米**）。
                        --   为什么必须：`dz`/`goal_dist` 都是相对**目标点**的，而目标点会被
                        --   地面净空抬高（`under=max(p_z-3.5, floor)`）⇒ 目标点与腹部**不重合**，
                        --   光看 `dz` 判不出"爆点离腹部多远"（用户报"距离腹部极近"时正是如此）。
                        env.emit(string.format(
                            'titan_probe;target=%s;stage=%s;dist=%.2f;goal_dist=%.2f;dz=%.2f'
                            ..';forward=%.2f;under_dz=%.2f;belly=%s;terminal=%s;p_z=%.2f;belly_dz=%.2f'
                            ..';point=%s;own=%s',
                            tostring(target.id),tostring(route.route.stage),
                            route.distance or -1,math.sqrt(dx*dx+dy*dy),
                            own_position[3]-route.point[3],
                            route.forward or -1,udz,
                            tostring(own_position[3]<=route.point[3]+(options and options.titan_belly_above or 0)),
                            tostring(route.terminal==true),
                            target.point[3],own_position[3]-target.point[3],
                            table.concat(route.point,','),
                            table.concat(own_position,',')))
                    end
                end
                local value,why=env.arrival:step(scope,target,route.arrival_point or route.point,stage,
                    route.terminal,previous and previous.arrival_progress,nil,options)
                assert(value,why)
                -- ★★ 引爆瞬间的**腹部距离**（2026-10-02，用户：「还是偶尔会在距离腹部
                --   极近的情况下引爆」/「准备吐酸时腹部会降低…杀不死泰坦」）★★
                --
                --   为什么必须有这一行：`arrival_detonated` 里的 `dz` = `own_z - 目标点z`，
                --   而**目标点会被地面净空抬高**（`under=max(p_z-3.5, floor)`）
                --   ⇒ 目标点 ≠ 腹部，`dz` 小并不代表"贴着腹部"、`dz` 大也不代表"离腹部远"。
                --   判据只能是**腹点本身**：
                --       `belly_dz = own_z - target.point[3]`（负 = 在腹部下方）
                --   ⇒ 稳定 |belly_dz| 应落在 `standoff ~ standoff+depth`（2.5~3.7）区间；
                --     若偶尔出现 |belly_dz| 明显偏小（<2.5）⇒ "极近腹部"被复现，
                --     再按 `p_z` 判断是"腹部被动画压低"还是别的原因。
                --   ⚠ 纯诊断、与决策无关；一次性（同一目标只打一条）。
                --   ⚠ 复用 `standoff_logged` 表（键加 `blast:` 前缀）—— 不新增 upvalue
                --     （`api:step` 的 pcall 匿名函数 upvalue 余量有限，见文件头注释）。
                if value and value.kind=='detonate' and env.emit
                    and not standoff_logged['blast:'..tostring(target.id)] then
                    standoff_logged['blast:'..tostring(target.id)]=true
                    env.emit(string.format(
                        'titan_blast;target=%s;stage=%s;p_z=%.2f;own_z=%.2f;belly_dz=%.2f;standoff=%.2f',
                        tostring(target.id),tostring(route.route.stage),
                        target.point[3],own_position[3],own_position[3]-target.point[3],
                        route_standoff or env.titan_standoff or 0))
                end
                if profile.structure and value.kind=='search' and env.emit then
                    env.emit('structure_stalled;entity='..L.u32(c.identity_bytes,8)..';target='..target.id
                        ..';resource='..profile.resource..';stage='..route.route.stage
                        ..';own='..table.concat(own_position,',')..';goal='..table.concat(route.point,','))
                end
                if value.kind=='detonate' or value.kind=='search' then
                    value.track={cancelled=true,candidate=candidate,target=target}
                    return value
                end
                arrival_progress=value.progress
            end
            if not target and not previous then return {kind='keep',reason=reason} end
            local pair=ffi.new('void *[2]',{ffi.cast('void *',c.entity_address),ffi.cast('void *',c.state_address)})
            if not target then
                assert(check()==record,'Titan cleanup state changed')
                mutated=true;calls.clear(pair,nil)
                local cleared=check()
                assert(L.u32(cleared,0x18)==scope.invalid_id and cleared:byte(0x79)==0
                    and L.u32(cleared,0x60)==0 and L.u32(cleared,0x70)==scope.invalid_id,'Titan cleanup failed')
                calls.orbit(pair,10,2.5,1.2000000476837158);check()
                return {kind='search',track={cancelled=true,candidate=candidate,target=previous.target},reason=reason}
            end
            assert(type(candidate)=='string' and #candidate==80,'Titan candidate size')
            local data=ffi.new('uint8_t[80]',candidate)
            ffi.cast('uint32_t *',data)[0]=scope.invalid_id
            local xyz=ffi.cast('float *',data+4)
            for i=0,2 do xyz[i]=route.point[i+1] end
            -- Reviewed guidance adds 0.25 m to Z. Without the arrival controller,
            -- legacy builds keep the original final 2.5 m proximity radius.
            xyz[2]=xyz[2]-0.25
            -- 0x8859c0 tests the candidate category mask at +0x4c. Zero cannot
            -- match any category: transit waypoints must not act as fuse targets.
            -- Retain original metadata for legacy final approach and cleanup.
            if env.arrival or not route.terminal then ffi.cast('uint32_t *',data+0x4c)[0]=0 end
            local point_bytes=ffi.string(data+4,12)
            assert(check()==record and target.validate(),'Titan pre-call changed')
            mutated=true;calls.clear(pair,data)
            local after=check()
            assert(L.u32(after,0x18)==scope.invalid_id and after:byte(0x79)==1
                and after:sub(0x1d,0x28)==point_bytes and L.u32(after,0x70)==scope.invalid_id,
                'Titan point setter postcondition')
            -- The setter may refresh the timestamp; all later bytes must match
            -- our submitted candidate, including the per-stage category mask.
            assert(after:sub(0x31,0x68)==ffi.string(data+24,56),'Titan candidate metadata changed')
            return {kind='aim',point=route.point,stage=route.route.stage,own_position=own_position,
                track={target=target,candidate=candidate,point_bytes=point_bytes,route=route.route,arrival_progress=arrival_progress}}
        end)
        busy=false
        if not ok then if mutated then disabled=true end;return nil,tostring(result) end
        return result
    end
    function api:disabled() return disabled end
    return api
end
return M
