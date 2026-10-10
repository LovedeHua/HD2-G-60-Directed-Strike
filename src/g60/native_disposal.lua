-- Requests normal entity removal after the original flight lifetime. No explosion.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Authority=require('g60.native_authority')
local Policy=require('g60.arrival_policy')
local Search=require('g60.native_search_context')
local M={}
local remove_type=ffi.typeof('void (*)(void *, uint32_t)')
function M.new(env)
    local disabled,busy=false,false
    local api={}
    function api:disabled() return disabled end
    -- ★★ 2026-10-10 显式的「提前移除」（安全区·**贴脸取消**，用户拍板，默认关）★★
    --   本模块的默认语义是"**寿命到期后**的正常移除"（见文件第 1 行），所以下面有一句
    --   硬断言 `disposal before expiry`。而贴脸取消是**另一个意图**：在引擎自己把它引爆
    --   之前主动移除掉（不爆炸、敌人也不掉血 —— 代价是这一发白扔）。
    --   ⇒ 只有调用方**显式**传 `{early_cancel=true}` 时才跳过那句断言；
    --     默认路径**照旧**断言（语义不变，守门钉着）。
    --
    --   ⚠⚠⚠ 2026-10-10 实机证实：**跳过断言并不能真的提前移除** ⚠⚠⚠
    --     本模块的移除走的是引擎的 RPC/队列（见文件末尾的说明："it does not delete
    --     inline"），而实机取证表明**引擎只对"寿命已到期"的雷兑现这条移除**：
    --       · `safe_cancel;`（成功返回）之后，同一颗雷（id **未**被复用 —— 日志里没有
    --         新的 `sel_probe;…;was=first`）又活了 **323 / 430 / 353 帧**（5~7 秒），
    --         期间引擎还在给它换目标（`safe_engine_lost;sel=…`）；
    --       · 另外 4 例"取消后 1~6 帧消失"其实是**被引擎炸了**（`safe_engine_exploded`
    --         出现在同一帧），不是被移除。
    --     ⇒ 那句 `disposal before expiry` 是**功能性前提**（引擎的状态机只在到期后才
    --       处理移除），不是单纯的策略守门。贴脸取消这条路**防不了爆**；
    --       保留它只为"以后若找到真正的提前移除手段，现成的取证行还能用"。
    function api:step(m,ready,options)
        if disabled or busy then return nil,'DISPOSAL_DISABLED' end
        local early=options and options.early_cancel==true
        busy=true
        local mutated=false
        local ok,result=pcall(function()
            assert(ffi.os=='Windows' and ffi.abi('64bit'),'disposal ABI')
            assert(ffi.istype(remove_type,env.calls.remove),'disposal call type')
            assert(ready(),'disposal jobs unavailable')
            local d=Data.new(env.read,env.base,env.exe)
            local e=assert(d.entity(m.id),'disposal entity missing')
            assert(e.resource=='8e325c933e55bf62' and e.identity==m.identity_bytes,'disposal identity')
            assert(Authority.inspect(env.engine,e.network).local_ownership_observed,'disposal ownership')
            local manager=d.ptr(env.base+0x3326740);local header=d.read(manager,0x70)
            local count=L.u32(header,0x2c)
            assert(count<=4096 and m.index<count,'disposal behavior bound')
            if not env.experimental_event_window then assert(L.u32(header,8)==0,'disposal pending events') end
            assert(d.ptr(L.pointer(header,0x58)+m.index*8)==e.address,'disposal behavior identity')
            local r=d.read(L.pointer(header,0x60)+m.index*0x1f8,0x1f8)
            assert(r==m.record_bytes and L.u32(r,0)==4 and (L.u32(r,8)==3 or L.u32(r,8)==4 or L.u32(r,8)==5),'disposal state')
            local clock=d.ptr(env.base+0x3326348)
            local now=L.hex64(d.read(clock+0x18,8),0)
            Search.pending_events(d.read,header,now,d.invalid,{[m.id]=true})
            -- ⚠ 提前取消是**显式**的例外：只有 `options.early_cancel==true` 才跳过。
            if not early then
                assert(Policy.elapsed(now,L.hex64(r,0x188))>=Policy.lifetime_ticks,'disposal before expiry')
            end
            assert(d.read(d.root+0xf3f828,3)=='\1\0\0','disposal world inactive')
            -- Native removal either sends the normal removal RPC or appends the
            -- entity index to this existing queue; it does not delete inline.
            local session=d.ptr(d.root+8)
            assert(d.hash(session+0xb020,e.network,32768),'disposal network object absent')
            local queue_count=d.u32(d.root+0xf3ef18)
            assert(queue_count<2048,'disposal queue full')
            local queue=d.ptr(d.root+0xf3ef20,4)
            d.read(queue+queue_count*4,4)
            assert(d.validate() and ready() and Authority.inspect(env.engine,e.network).local_ownership_observed,'disposal observation changed')
            mutated=true;env.calls.remove(ffi.cast('void *',d.root),e.id)
            local after=L.u32(env.read(d.root+0xf3ef18,4),0)
            assert(after==queue_count or after==queue_count+1,'disposal queue postcondition')
            if after>queue_count then
                assert(L.u32(env.read(queue+queue_count*4,4),0)==(e.address-d.root-0xf32f18)/24,
                    'disposal queued identity mismatch')
            end
            return {kind='retire',delivery=after>queue_count and 'native_queue' or 'native_request'}
        end)
        busy=false
        if not ok then if mutated then disabled=true end;return nil,tostring(result) end
        return result
    end
    return api
end
return M
