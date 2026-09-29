-- Explicitly experimental: observations reduce risk but do not hold a lifetime lease.
local Layout=require('g60.native_observer')
local Readiness=require('g60.native_readiness')
local Search=require('g60.native_search_context')
local Filter=require('g60.small_filter')
local Allowlist=require('g60.target_allowlist')
local Reservations=require('g60.target_reservations')
local Minimal=require('g60.native_minimal')
local Titan=require('g60.native_titan_aim')
local Priority=require('g60.native_priority')
local Ping=require('g60.native_ping')
local Arrival=require('g60.native_arrival')
local Disposal=require('g60.native_disposal')
local ArrivalPolicy=require('g60.arrival_policy')
local TargetData=require('g60.native_target_data')
local TargetContext=require('g60.titan_context')
local U=require('g60.util')
local M={}
function M.new(env)
    local read,base=assert(env.read),assert(env.base)
    if env.designed_targets_only then
        env.target_allowed=Allowlist.new(env.titan_profile,env.weakpoint_profiles)
    end
    local tracked,serial,frame={},0,0
    local reservations=env.exclusive_targets and Reservations.new()
    assert(not reservations or (env.priority_catalog and env.fuse_profile),'exclusive allocation requires priority and search cleanup')
    local current,runner
    local arrival=env.fuse_profile and Arrival.new(env)
    env.arrival=arrival
    local disposal=env.fuse_profile and Disposal.new(env)
    local retired={}
    local titan=env.titan_profile and Titan.new(env)
    local function has_weakpoint(resource)
        -- ★ 裁剪 C：原上游把 titan_profile / weakpoint_profiles / structure_profiles
        --   三类都算作"有自定义瞄准点"。本工程只用第三类(9 个虫洞)，所以收窄成
        --   只认 structure_profiles —— 否则敌人仍会被 arrival 阶段当成弱点目标而跳过
        --   实体到达判定(下方 `if has_weakpoint(...) then target=nil end`)。
        return env.structure_profiles and env.structure_profiles[resource]~=nil
    end
    local ping=env.priority_catalog and env.mark_priority_enabled~=false and Ping.new(env)
    local structure_ping=env.structure_profiles and Ping.new(env,{
        diagnostic=function(detail) env.emit('structure_mark;'..detail) end,
        allowed=function(resource) return env.structure_profiles[resource]~=nil end,
        position=function(e)
            local pose=TargetContext.capture(read,base,env.exe,e.id,env.structure_profiles[e.resource])
            assert(pose.validate(),'structure Ping pose changed');return pose.point
        end})
    if ping or structure_ping then env.forget_mark=function(identity)
        if ping then ping:forget(identity) end
        if structure_ping then structure_ping:forget(identity) end
    end end
    local priority=env.priority_catalog and Priority.new(env)
    local world,last_time,last_ping_issue,last_ping_queue
    local host={applied=0,aimed=0,skipped=0,disabled=false,native_lifetime_verified=false}
    local function pointer(a) return Layout.pointer(read(a,8),0) end
    local function jobs_ready()
        local r=Readiness.capture(read,base,env.exe,env.thread(),{matches={}},nil)
        return r.engine_main_thread_observed and r.world_job_completion==1
            and r.context_job_busy==0 and r.context_job_active==0
    end
    local function release_all()
        for _,t in pairs(tracked) do runner:release(t.ref) end
        tracked={};current=nil
        retired={};last_ping_queue=nil
        if reservations then reservations:reset() end
        if ping then ping:reset() end
        if structure_ping then structure_ping:reset() end
    end
    local function with_observation(ref,callback)
        assert(current and U.key(ref)==U.key(current.ref),'expired observation key')
        assert(jobs_ready(),'thread or jobs not ready')
        local track=tracked[current.match.id]
        local c=Search.capture(read,base,current.match,env.engine,
            env.experimental_event_window and {experimental_event_window=true,target_id=track and track.lock and track.lock.id})
        assert(c.ownership.local_ownership_observed,'projectile not locally owned')
        local root,clock,manager=pointer(base+0x346bf98),pointer(base+0x3326348),pointer(base+0x3326740)
        local header=read(manager,0x70)
        local time=read(clock+0x18,8)
        local active=true
        local scope={experimental=true,native_lifetime_verified=false,
            reference_is_observation_key=true,window=tostring(frame),read=read,
            invalid_id=Layout.u32(read(base+0x3483c20,4),0),prepared=c,calls=env.calls}
        scope.snapshot={ref=ref,resource='8e325c933e55bf62',behavior_id=4,state=4,
            active=true,expired=false,selection_complete=true,selection_cleared=c.selection.cleared}
        if c.selection.has_target then
            assert(current.match.selection_resource,'selected resource unavailable')
            scope.snapshot.selected={ref={id=tostring(c.selection.id),scene=ref.scene,
                generation='observed-target-only'},resource=current.match.selection_resource}
        end
        scope.validate=function()
            -- This only checks observed state. It never reports lifetime_verified=true.
            return active and not host.disabled and jobs_ready()
                and pointer(base+0x346bf98)==root and pointer(base+0x3326740)==manager
                and pointer(base+0x3326348)==clock and read(clock+0x18,8)==time
                and read(manager,0x70)==header and read(root+0xf3f828,3)=='\1\0\0'
                and read(c.entity_address,24)==c.identity_bytes
                and (not c.pending_event_observation or read(c.pending_event_observation.address,
                    #c.pending_event_observation.bytes)==c.pending_event_observation.bytes)
        end
        local ok,result,reason,detail=pcall(callback,scope)
        active=false
        if not ok then error(result,0) end
        return result,reason,detail
    end
    runner=Minimal.new_experimental(with_observation,env.target_allowed)
    function host:tick()
        if self.disabled then return end
        frame=frame+1
        local ok,why=pcall(function()
            -- Keep observation keys across a skipped frame so an owned Titan
            -- waypoint can be cleaned up on the next eligible update.
            if not jobs_ready() then current=nil;return end
            local observed=Layout.capture(read,base)
            if not observed.all_observed_queues_complete or observed.update_mode~=0
                or observed.root_flags[1]~=1 or observed.root_flags[2]~=0 or observed.root_flags[3]~=0 then
                if ping then ping:reset() end
                if structure_ping then structure_ping:reset() end
                current=nil;return
            end
            local root=pointer(base+0x346bf98)
            local time=Layout.hex64(read(pointer(base+0x3326348)+0x18,8),0)
            if world and (world~=root or time<last_time) then release_all() end
            world,last_time=root,time
            if reservations then
                -- Keep claims through stalls, state changes, pending explosion /
                -- removal and skipped guidance. Release only when the entity is
                -- absent (or replaced) in this complete observation.
                reservations:reconcile(observed.matches)
                table.sort(observed.matches,function(a,b)
                    if a.flight_start~=b.flight_start then return a.flight_start<b.flight_start end
                    return a.id<b.id
                end)
            end
            local mark,ping_issue
            local structure_mark,structure_issue
            if structure_ping then
                structure_mark,structure_issue=structure_ping:observe()
                if structure_issue then env.emit('structure_ping_unavailable;detail='..tostring(structure_issue)) end
            end
            if ping then
                mark,ping_issue=ping:observe()
                if ping_issue and ping_issue~=last_ping_issue then env.emit('ping_unavailable;detail='..ping_issue) end
                last_ping_issue=ping_issue
                local ids={}
                for _,m in ipairs(mark and (mark.queue or {mark}) or {}) do ids[#ids+1]=tostring(m.id) end
                local queue=table.concat(ids,',')
                if queue~=last_ping_queue then env.emit('ping_queue;targets='..queue..';count='..#ids);last_ping_queue=queue end
            end
            local seen={}
            for _,m in ipairs(observed.matches) do
                local retired_key=m.identity_bytes..m.flight_start
                if retired[m.id] and retired[m.id]~=retired_key then retired[m.id]=nil end
                -- ★ 裁剪 H：上游此处只判 `disposal and m.behavior_id==4 and state in {3,4,5}`
                --   且到期 —— 对**所有** G-60 生效，包括引擎原生锁定敌人的那些。
                --   日志里 5 次 `arrival_retired;delivery=native_queue` 就是敌人在飞的 G-60
                --   被本 mod 主动引爆（原生行为是让它自然过期）。同样属于"影响其他地方"。
                --   现在只对本 mod 持有锁定/航点的实体做寿命回收。
                local held=tracked[m.id] and (tracked[m.id].lock or tracked[m.id].titan)
                if disposal and held and m.behavior_id==4 and (m.state==3 or m.state==4 or m.state==5)
                    and time>=m.flight_start and ArrivalPolicy.elapsed(time,m.flight_start)>=ArrivalPolicy.lifetime_ticks
                    and not retired[m.id] then
                    local result,reason=disposal:step(m,jobs_ready)
                    if result then
                        retired[m.id]=retired_key
                        env.emit('arrival_retired;entity='..m.id..';delivery='..result.delivery)
                    else env.emit('arrival_skipped;entity='..m.id..';detail='..tostring(reason)) end
                    if disposal:disabled() then self.disabled=true;error('disposal operation disabled') end
                end
                if tracked[m.id] and m.behavior_id==4 and m.state==4 and not m.native_update_eligible
                    and tracked[m.id].fingerprint==m.identity_bytes..m.flight_start then seen[m.id]=true end
                if m.behavior_id==4 and m.state==4 and m.native_update_eligible and not retired[m.id] then
                    local old=tracked[m.id]
                    local fingerprint=m.identity_bytes..m.flight_start
                    if old and old.fingerprint~=fingerprint then runner:release(old.ref);old=nil;tracked[m.id]=nil end
                    -- ★ 裁剪 F（同上，入口侧）★
                    -- priority 段会做 with_observation → Search.capture（预算上限
                    -- 65536 B / 2048 次读），对**没有虫洞锁**的敌人 G-60 是纯浪费，
                    -- 而且它返回 {kind='keep'} 后下面的 `elseif result.released or
                    -- reservations` 会把 old.force_search 置 true —— 正是这个标志
                    -- 让 arrival 块进入 'search' 分支去 clear 引擎目标。
                    --
                    -- 所以只在"有虫洞标记"或"本 mod 已持有锁定/航点"时才进入。
                    -- 无标记的敌人 G-60：本 mod 不建 tracked、不读 Search、不写任何内存。
                    if priority and (structure_mark or (old and (old.lock or old.titan))) then
                        if not old then
                            serial=serial+1
                            old={fingerprint=fingerprint,ref={id=tostring(m.id),
                                generation='observation-'..serial,scene='experimental-session'}}
                            tracked[m.id]=old
                        end
                        seen[m.id]=true;current={ref=old.ref,match=m}
                        local owner=reservations and Reservations.owner(m)
                        local available=reservations and function(identity) return reservations:available(owner,identity) end
                        local good,result,reason=pcall(with_observation,old.ref,function(scope)
                            return priority:step(scope,old.lock,mark,old.blocked,available,structure_mark)
                        end)
                        current=nil
                        if priority:disabled() then self.disabled=true;error('priority native operation disabled: '..tostring(reason)) end
                        if good and result then
                            if result.kind=='lock' then
                                if reservations then reservations:claim(owner,result.track.identity) end
                                if not old.lock or old.lock.identity~=result.track.identity then
                                    env.emit('priority_locked;entity='..m.id..';target='..result.track.id..';reason='..result.reason
                                        ..';resource='..tostring(result.resource)..';mark='..tostring(result.mark_id)
                                        ..';mark_current='..tostring(result.mark_current)
                                        ..';mark_candidate_observed='..tostring(result.mark_candidate_observed)
                                        ..';mark_queue_count='..tostring(result.mark_queue_count)
                                        ..';selected_mark='..tostring(result.selected_mark_id)
                                        ..';selected_mark_index='..tostring(result.selected_mark_index))
                                    old.titan=nil
                                end
                                old.lock=result.track
                                old.force_search=nil
                                m.record_bytes=result.record
                                m.selection_id=Layout.u32(result.record,0x18)
                                m.selection_flag=result.record:byte(0x79)
                                m.selection_resource=result.resource
                            -- ★ 裁剪 G（实机"标记虫洞时灵时不灵"的另一半）★
                            -- 上游原文是 `elseif result.released or reservations then`，那个
                            -- `or reservations` 建立在"keep == 候选全被否掉"的前提上，所以要
                            -- 强制重搜。但裁剪后本 mod 的 priority 对**敌人**永远返回
                            -- {kind='keep',released=false}（自动挑敌人那段已删），于是每一帧
                            -- 都会命中 `or reservations` 把 old.force_search 置 true。
                            -- 后果：虫洞标记来了以后，titan_selected 因为
                            -- `not retry_search` 被压掉 → 标记被读到却不接管。
                            -- 现在只在**真的释放了已有锁定**时才强制重搜。
                            elseif result.released then old.lock=nil;old.force_search=true end
                        else
                            env.emit('priority_skipped;entity='..m.id..';detail='..tostring(good and reason or result))
                            if reservations then old.lock=nil;old.force_search=true end
                        end
                    end
                    local selected=m.selection_flag~=0 and m.selection_id~=Layout.u32(read(base+0x3483c20,4),0)
                    -- ★ 裁剪 A：原上游在此判 excluded —— 被 small_filter 列入的小怪、或不在
                    --   allowlist(泰坦+弱点) 里的敌人，都会触发"清掉引擎选择 + 强制搜索"。
                    --   那是 mod 的"只打指定敌人"行为。恒置 false 后，没有虫洞标记时
                    --   G-60 的敌人选择完全交给引擎原生 TargetLock，本 mod 不再插手。
                    --   (下方 titan_selected 走 has_weakpoint，而它已被裁剪成只认
                    --    structure_profiles，所以只有 9 个虫洞会进入接管路径。)
                    local excluded=false
                    local retry_search=arrival and old and (old.force_search or (old.blocked and not old.lock))
                    if retry_search then old.titan=nil end
                    local titan_selected=titan and selected and not retry_search and has_weakpoint(m.selection_resource)
                    if excluded or titan_selected or (old and not selected) then
                        if not old then
                            serial=serial+1
                            old={fingerprint=fingerprint,ref={id=tostring(m.id),
                                generation='observation-'..serial,scene='experimental-session'}}
                            tracked[m.id]=old
                        end
                        seen[m.id]=true
                        current={ref=old.ref,match=m}
                        local result,status,detail
                        if titan_selected or (old.titan and not selected) then
                            runner:release(old.ref)
                            result,status=with_observation(old.ref,function(scope) return titan:step(scope,old.titan) end)
                            if result then
                                local starting=not old.titan or old.titan.cancelled
                                local stage_changed=old.titan and old.titan.route
                                    and result.stage~=old.titan.route.stage
                                old.titan=result.track
                                if result.kind=='aim' then
                                    self.aimed=self.aimed+1
                                    env.emit((starting and 'titan_started' or stage_changed and 'titan_stage' or 'titan_aim')..';entity='..m.id
                                        ..';target='..result.track.target.id..';point='
                                        ..table.concat(result.point,',')..';stage='..tostring(result.stage)..';frame='..frame
                                        ..(result.own_position and ';own='..table.concat(result.own_position,',') or ''))
                                elseif result.kind=='search' and starting==false then
                                    env.emit('titan_released;entity='..m.id..';reason='..tostring(result.reason))
                                elseif result.kind=='keep' then
                                    env.emit('titan_skipped;entity='..m.id..';reason='..tostring(result.reason))
                                end
                                if result.blocked then old.blocked=result.blocked;old.lock=nil;old.titan=nil end
                                if arrival and old.lock and (result.kind=='keep' or result.kind=='search') then
                                    old.blocked={identity=old.lock.identity,
                                        until_seconds=ArrivalPolicy.elapsed(time,m.flight_start)/1000000+ArrivalPolicy.retry_seconds}
                                    old.lock=nil;old.titan=nil
                                    old.force_search=result.kind=='keep'
                                end
                                if result.kind=='detonate' then
                                    retired[m.id]=retired_key
                                    env.emit('arrival_detonated;entity='..m.id..';target='..result.target..';distance='..result.distance)
                                end
                            end
                        else
                            old.titan=nil
                            result,status,detail=runner:step(old.ref)
                        end
                        current=nil
                        if result and result.kind=='search' then
                            self.applied=self.applied+1
                            env.emit('search_applied;entity='..m.id..';selected='..m.selection_id
                                ..';resource='..tostring(m.selection_resource)..';frame='..frame)
                        elseif not result then
                            self.skipped=self.skipped+1
                            env.emit('skipped;entity='..m.id..';reason='..tostring(status)..';detail='..tostring(detail))
                        end
                        if runner:disabled() or (titan and titan:disabled()) then self.disabled=true;error('native operation disabled after partial failure') end
                    end
                    -- ★ 裁剪 F（实机反馈"打不了中小型敌人"的真凶）★
                    -- 原上游在这里只判 `arrival and old`：`old` 是 priority 段为**每个**
                    -- state-4 G-60 建的记录，所以**敌人 G-60 也会走进 arrival:step**。
                    -- 而 arrival:step 在 target=nil 且 mask_only='search' 时会执行
                    --   scope.calls.clear(pair,nil)   ← 清掉引擎的原生目标选择
                    --   scope.calls.orbit(pair,10,2.5,1.2)
                    -- 逐帧重复 ⇒ 引擎刚选中的中小型敌人被反复清掉，G-60 永远锁不上，
                    -- 表现为"只能锁大型敌人"（大型目标离得远、被重选的机会多）。
                    --
                    -- 本工程只在**本 mod 真正持有锁定**时才需要 arrival：
                    --   · old.lock      —— 玩家标记的虫洞（priority 的 PLAYER_MARK_STRUCTURE）
                    --   · old.titan     —— 已建立的虫洞航点
                    -- 两者皆无 ⇒ 敌人侧完全交还引擎原生逻辑，本 mod 一个字节都不写。
                    if arrival and old and (old.lock or old.titan) and not retired[m.id] then
                        -- Recapture after preceding setters, including the Titan waypoint.
                        local manager=pointer(base+0x3326740)
                        local records=Layout.pointer(read(manager+0x60,8),0)
                        m.record_bytes=read(records+m.index*0x1f8,0x1f8)
                        m.selection_id=Layout.u32(m.record_bytes,0x18);m.selection_flag=m.record_bytes:byte(0x79)
                        current={ref=old.ref,match=m}
                        local ok_arr,result,reason=pcall(with_observation,old.ref,function(scope)
                            local target
                            if old.lock then
                                local d=TargetData.new(read,base,env.exe)
                                local e=d.entity(old.lock.id)
                                if e and (not env.target_allowed or env.target_allowed(e.resource))
                                    and e.identity==old.lock.identity and d.unit(e)==old.lock.unit then
                                    e.validate=d.validate;target=e
                                end
                            end
                            local titan_point=old.titan and not old.titan.cancelled
                                and not scope.prepared.selection.has_target
                                and scope.prepared.record_bytes:sub(0x1d,0x28)==old.titan.point_bytes
                            -- Titan already evaluated arrival against its live weakpoint.
                            if titan_point then return {kind='guide'} end
                            if has_weakpoint(m.selection_resource) then target=nil end
                            local blocked_selected=old.blocked and old.lock==nil and m.selection_flag==1
                            return arrival:step(scope,target,nil,'vanilla',true,old.arrival_progress,
                                (old.force_search or blocked_selected) and 'search' or not target)
                        end)
                        current=nil
                        if ok_arr and result then
                            old.arrival_progress=result.progress;old.force_search=nil
                            if result.blocked then old.blocked=result.blocked end
                            if result.kind=='search' then old.lock=nil;old.titan=nil end
                            if result.kind=='detonate' then
                                retired[m.id]=retired_key
                                env.emit('arrival_detonated;entity='..m.id..';target='..result.target..';distance='..result.distance)
                            end
                        else env.emit('arrival_skipped;entity='..m.id..';detail='..tostring(ok_arr and reason or result)) end
                    end
                    if arrival and arrival:disabled() then self.disabled=true;error('arrival operation disabled') end
                end
            end
            for id,t in pairs(tracked) do
                if not seen[id] then runner:release(t.ref);tracked[id]=nil end
            end
            local present={};for _,m in ipairs(observed.matches) do present[m.id]=true end
            for id in pairs(retired) do if not present[id] then retired[id]=nil end end
        end)
        if not ok then current=nil;env.emit('frame_error;detail='..tostring(why)) end
    end
    function host:stop() self.disabled=true;release_all() end
    return host
end
-- Runs once after the existing Lua update, before the reviewed native game update.
function M.install(globals,host,on_stop)
    local previous=globals.update
    assert(previous==nil or type(previous)=='function','unsupported update callback')
    local wrapper
    local stopped=false
    local function stop()
        if stopped then return end
        stopped=true;host:stop()
        if globals.update==wrapper then globals.update=previous end
        if on_stop then on_stop() end
    end
    local function after(...)
        local result={n=select('#',...),...}
        if not stopped then host:tick();if host.disabled then stop() end end
        return unpack(result,1,result.n)
    end
    wrapper=function(...)
        if previous then return after(previous(...)) end
        return after()
    end
    globals.update=wrapper
    return stop
end
return M
