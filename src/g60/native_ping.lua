-- Read-only native UI ring. Creator must match the uniquely locally owned actor.
local ffi=require('ffi')
local L=require('g60.native_observer')
local Data=require('g60.native_target_data')
local Authority=require('g60.native_authority')
local Memory=require('g60.ping_memory')
local M={}
function M.new(env,options)
    options=options or {}
    local function allowed(resource)
        local check=options.allowed or env.target_allowed
        return not check or check(resource)
    end
    local memory=Memory.new()
    -- ★ 稳健性改进（不是"完全没生效"的原因 —— 那是我 2026-09-27 引入的
    --   `old.quarantined` nil 崩溃；用户明确指出上一版是"压根没生效"而非"时灵时不灵"）★
    --
    -- 上游的收尾是 `if not ok then memory:reset(); return nil, ... end` ——
    -- **任何一次读取失败就把整个标记记忆清空**。而 `local Ping creator unavailable`
    -- （第 42 行的 assert：在 actors 表里没找到本地拥有的 Ping creator）在实机里
    -- 会连续失败很多帧（23:28 那版日志里它刷了几百条）。
    --
    -- 影响：读失败的那一帧 structure_mark 为 nil，且**之前记住的标记也被抹掉**。
    -- 只要 UI 的标记还在 ring 里未过期，下一帧成功时会重新记住 —— 所以它不至于
    -- 让功能完全失效，只会让标记"断断续续"。真正的"压根没生效"是别的原因。
    --
    -- 但这里的上游写法与设计意图相悖：这个 memory 存在的意义恰恰是
    -- "UI 的标记到期后**仍然记住**玩家的意图"（ping_memory.lua 文件头：
    -- `UI expiry does not expire remembered intent`），一次读失败就清掉它是错的。
    --
    -- 现在：读失败 → **保留** history，返回上一次成功选中的标记（stale）；
    -- 只有**连续**失败到上限（说明不是抖动而是真的读不到/版本漂了）才真正 reset。
    local last_selected
    local failed_frames=0
    local FAILURE_RESET_LIMIT=240      -- 约 4 秒 @60fps
    local diagnosed,diagnostic_count={},0
    local function diagnose(id,resource,reason)
        if not options.diagnostic then return end
        local detail='target='..tostring(id)..';resource='..tostring(resource)..';reason='..tostring(reason)
        if diagnosed[detail] or diagnostic_count>=64 then return end
        diagnosed[detail]=true;diagnostic_count=diagnostic_count+1;options.diagnostic(detail)
    end
    local api={}
    -- ★★ ping 槽**全字段** dump（2026-10-01，**只读**）★★
    --
    -- 背景：ping 环每槽 0x58 字节，而本文件只解出 4 个字段
    --   （+0x10 duration / +0x14 age / +0x18 owner / +0x20 目标实体 id）。
    -- 用户提出：「无目标的**空白标记**（ping 到空地）是否也能接管？」
    --   ⇒ 要先回答一个客观问题：**ping 空地时槽里到底有没有世界坐标**。
    -- 设计（三条）：
    --   ① 只在**读不到实体**（NO_ENTITY_MARK）时才 dump —— 那正是"空白标记"的形态，
    --      既聚焦又天然不刷屏（ping 到实体时槽里是什么我们并不需要）；
    --   ② 每槽只 dump 一次（用 `slot:前4字节` 去重）；
    --   ③ **纯读**：只 read + 格式化，不写任何内存。
    -- 输出两样：88 字节的 hex（全量证据）+ 扫描出的"疑似 float 三元组"候选
    --   （连续 3 个小量级有限浮点，可能就是坐标 —— 但会有误报，需人工比对）。
    local slot_seen={}
    local function dump_slot(slot,bytes)
        local key=tostring(slot)..':'..bytes:sub(1,4)
        if slot_seen[key] then return end
        slot_seen[key]=true
        if not options.slot_dump_diagnostic then return end
        -- ⚠ 本函数在 structure_mark 的 pcall **内部**被调用 ⇒ 一旦抛错会被记成
        --   `ENTITY_READ_FAILED`，把这次观测一起废掉（2026-10-01 实测就是这么踩的：
        --   日志里只有 ENTITY_READ_FAILED:…:nonfinite target data，dump 一行没出）。
        --   根因：原来用 `Data.float` 扫全槽，而它对非有限/超大值**直接断言**
        --   （`assert(f==f and math.abs(f)<1000000,'nonfinite target data')`），
        --   而 88 字节里必然有若干偏移构不出合法 float。
        --   ⇒ 改两点：① 用 ffi 直接解 float（**不做任何断言**）；
        --             ② 整段自己 pcall 兜住，异常只写进日志、不往外冒。
        local ok,detail=pcall(function()
            local hex=(bytes:gsub('.',function(ch) return string.format('%02x',string.byte(ch)) end))
            local buf=ffi.new('uint8_t[0x58]',bytes)
            local f=ffi.cast('float *',buf)
            local cand={}
            for i=0,0x58/4-3 do
                local a,b,c=f[i],f[i+1],f[i+2]
                if a==a and b==b and c==c
                    and math.abs(a)<100000 and math.abs(b)<100000 and math.abs(c)<100000
                    and (a~=0 or b~=0 or c~=0) then
                    cand[#cand+1]=string.format('0x%x=%.2f/%.2f/%.2f',i*4,a,b,c)
                end
            end
            return 'slot='..slot..';id='..tostring(L.u32(bytes,0x20))
                ..';age='..string.format('%.2f',f[5])
                ..';hex='..hex..';f3='..table.concat(cand,'|')
        end)
        options.slot_dump_diagnostic(ok and detail
            or ('slot='..slot..';dump_error='..tostring(detail)))
    end
    function api:reset()
        memory:reset();diagnosed={};diagnostic_count=0
        last_selected=nil;failed_frames=0
    end
    function api:forget(identity)
        memory:forget(identity)
        -- 该实体已被确认不可用（被引爆/实体销毁），stale 引用必须同步清掉，
        -- 否则失败帧返回 last_selected 时又会把它喂回给 priority。
        if last_selected and last_selected.identity==identity then last_selected=nil end
    end
    function api:observe()
        local ok,result=pcall(function()
            local d=Data.new(env.read,env.base,env.exe)
            local actors=d.ptr(env.base+0x3326d20)
            local count=d.u32(actors+0x70);assert(count<=16,'Ping actor count')
            local owner
            for i=0,count-1 do
                local p=d.read(actors+0x110+i*8,8)
                if L.hex64(p,0)~='0000000000000000' then
                    local address=L.pointer(p,0);local bytes=d.read(address,24)
                    if Authority.inspect(env.engine,L.u32(bytes,16)).local_ownership_observed then
                        assert(not owner,'ambiguous local Ping creator')
                        owner=assert(d.entity(L.u32(bytes,8)),'Ping creator entity missing')
                        assert(owner.address==address and owner.identity==bytes,'Ping creator changed')
                        d.unit(owner)
                    end
                end
            end
            assert(owner,'local Ping creator unavailable')
            local ring=d.ptr(env.base+0x347ce30)
            local header=d.read(ring,16)
            assert(header:byte(1)==1,'Ping UI inactive')
            local head,tail=L.u32(header,8),L.u32(header,12)
            assert(head<128 and tail<128,'Ping ring bounds')
            local marks={}
            for step=0,(tail-head)%128-1 do
                local slot=(head+step)%128
                local r=d.read(ring+16+slot*0x58,0x58)
                local duration,age=Data.float(r,0x10),Data.float(r,0x14)
                if L.u32(r,0x18)==owner.id and age>=0 and age<duration then
                    local id=L.u32(r,0x20)
                    local good,mark=pcall(function()
                        local e=id~=d.invalid and d.entity(id)
                        if not e then
                            diagnose(id,nil,'NO_ENTITY_MARK')
                            -- ★ "空白标记"（读不到实体）⇒ 把整槽 dump 出来（见 dump_slot 说明）
                            if options.slot_dump then dump_slot(slot,r) end
                        elseif not allowed(e.resource) then diagnose(id,e.resource,'RESOURCE_NOT_SUPPORTED') end
                        if e and (not allowed or allowed(e.resource)) then
                            local unit=d.unit(e)
                            return {id=id,identity=e.identity,resource=e.resource,unit=unit,age=age,slot=slot,
                                token=tostring(slot)..':'..r:sub(1,4)..r:sub(0x11,0x14)..r:sub(0x19,0x1c)..e.identity}
                        end
                    end)
                    -- A recycled/unavailable marked unit must not erase older
                    -- valid marks; the full read observation is still rechecked.
                    if good and mark then marks[#marks+1]=mark end
                    if not good then diagnose(id,nil,'ENTITY_READ_FAILED:'..tostring(mark)) end
                end
            end
            local origin=d.position(owner)
            local function valid(m)
                local good,value=pcall(function()
                    local e=d.entity(m.id)
                    if not e or (allowed and not allowed(e.resource))
                        or e.identity~=m.identity or d.unit(e)~=m.unit then return false end
                    local p=options.position and options.position(e) or d.position(e);local distance=0
                    for i=1,3 do distance=distance+(p[i]-origin[i])^2 end
                    if distance>=40000 then diagnose(m.id,m.resource,'OUTSIDE_200M');return false end
                    diagnose(m.id,m.resource,'ACCEPTED');return true
                end)
                if not good then diagnose(m.id,m.resource,'POSE_READ_FAILED:'..tostring(value)) end
                return good and value
            end
            local clock=d.ptr(env.base+0x3326348)
            local observation={scene=tostring(d.root)..':'..tostring(ring)..':'..owner.identity,
                time=L.hex64(d.read(clock+0x18,8),0),marks=marks}
            local selected=memory:update(observation,valid)
            assert(d.validate(),'Ping observation changed')
            return selected
        end)
        if not ok then
            -- 瞬时读取失败：保留记忆，继续用上一次成功选中的标记。
            failed_frames=failed_frames+1
            if failed_frames>=FAILURE_RESET_LIMIT then
                memory:reset();last_selected=nil
            end
            return last_selected,tostring(result)
        end
        failed_frames=0
        -- 直接赋值而不是 `if result then`：观察成功却**没有任何**记住的标记
        -- （场景切换后 memory 内部已 reset）时必须同步清掉 last_selected，
        -- 否则会把上个场景的虫洞当成当前标记继续喂给 priority。
        last_selected=result
        return result
    end
    return api
end
return M
