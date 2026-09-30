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
            if mask_only=='search' then action='search' end
            if target and not mask_only then
                assert(target.validate(),'arrival target changed')
                if not goal then
                    assert(c.selection.has_target and c.selection.id==target.id,'arrival selected target mismatch')
                    assert(ffi.istype(aim_type,scope.calls.aim),'arrival aim ABI')
                    local out=ffi.new('float[3]');local position=ffi.new('uint8_t[12]',c.own_position_bytes)
                    assert(scope.calls.aim(out,pair,position)==ffi.cast('void *',out),'arrival aim output')
                    goal=Data.vector(ffi.string(out,12),0);goal[3]=goal[3]+0.25
                    assert(target.validate() and ex.validate() and source()==record,'arrival aim observation changed')
                end
                local below=not (stage:sub(1,6)=='titan/' or options and options.below) or own[3]<=goal[3]
                local region=options and options.region or stage:sub(1,6)=='titan/' and env.titan_arrival_region or nil
                action,progress,dist=Policy.step(now,own,goal,terminal and below,tostring(target.id)..':'..stage,previous,region)
            end
            if action=='detonate' then
                assert(target.validate() and ex.validate() and source()==record,'arrival trigger changed')
                mutated=true
                scope.calls.explode(ffi.cast('void *',ex.manager),ex.id,ex.invalid_source,nil)
                assert(scope.read(ex.network_address+1,1)=='\1','arrival request not committed')
                assert(source()==record,'arrival request changed flight state')
                return {kind='detonate',distance=dist,target=target.id}
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
            return {kind='guide',progress=progress,distance=dist}
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
