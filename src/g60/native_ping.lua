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
    -- ★★ "空白标记"位置暴露（2026-10-01，**只读**）★★
    --   用户目标：「有敌人时，ping 一个位置 ⇒ G-60 飞过去炸」（指哪打哪）。
    --   实机已证实 ping 槽 `+0x04/+0x08/+0x0c` 是**世界坐标 float3**、`+0x28` 是到玩家距离：
    --     · 8 槽三边定位自洽（8 组 (pos,dist) 解出同一公共点，残差 ~0.7m RMS）
    --     · 两次 ping ⇒ 两个槽，坐标间距 37.3m（与用户"走开约 30m 再 ping"吻合）
    --     · `+0x2c/+0x30` ≈ 屏幕中心 (960,600) —— 因为 ping 就落在准星上
    --   本函数只把"最新一项空白标记"的位置**暴露给上层**（`api:last_point()`）；
    --   本轮**不改任何行为**：`observe()` 的返回值仍只含"有实体的标记"，
    --   该位置目前仅用于诊断日志（见 experimental_runtime 的 `point_marker;`）。
    --   ⚠ 与 dump_slot 同款**自兜异常**：本函数也在 structure_mark 的 pcall 内部被调用，
    --     抛错会被记成 `ENTITY_READ_FAILED`，把这次观测一起废掉。
    local function slot_point(r)
        local ok,x,y,z,d=pcall(function()
            local buf=ffi.new('uint8_t[0x58]',r)
            local f=ffi.cast('float *',buf)
            return f[1],f[2],f[3],f[10]
        end)
        if not ok then return nil end
        local function fin(v) return v==v and math.abs(v)<100000 end
        if not (fin(x) and fin(y) and fin(z)) then return nil end
        if x==0 and y==0 and z==0 then return nil end
        if math.abs(x)+math.abs(y)+math.abs(z)<0.5 then return nil end   -- 量级太小 ⇒ 不像真实坐标
        if not (fin(d) and d>=0) then d=0 end
        return x,y,z,d
    end
    local last_point
    local slot_seen={}
    local dump_count=0
    local DUMP_CAP=80                  -- 防刷屏上限（超了只再打一行 dump_capped）
    local function dump_slot(slot,bytes)
        -- ★★ 去重键 = **位置 12 字节**（2026-10-01 第二次迭代）★★
        --   第一版用 `slot:前4字节`，而那 4 字节恒为 0 ⇒ **每槽一生只 dump 一次**。
        --   实测后果：一次就把 8 个槽全打完，之后再 ping 新位置**不再出日志**
        --   ⇒ 无法回答"哪一次 ping 落到哪个槽 / 哪个坐标"（而那正是本探测的目的）。
        --   现在改为 `slot:位置字节` ⇒ 只有**同一个槽里的坐标真的变了**才再 dump
        --   （= 玩家在同一个槽上 ping 了新位置时刚好命中）；坐标不变则完全静默。
        local key=tostring(slot)..':'..bytes:sub(5,16)
        if slot_seen[key] then return end
        slot_seen[key]=true
        if not options.slot_dump_diagnostic then return end
        if dump_count>=DUMP_CAP then
            if dump_count==DUMP_CAP then
                dump_count=dump_count+1
                options.slot_dump_diagnostic('dump_capped;limit='..DUMP_CAP)
            end
            return
        end
        dump_count=dump_count+1
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
            -- ★ 2026-10-01 实测解码（8 槽 + 三边定位交叉验证自洽）：
            --   +0x04/+0x08/+0x0c = **世界坐标 float3**（各槽不同、量级合理、Z≈地形高度）
            --   +0x10 = 8.0 常量（像标记存活时长）· +0x14 = 0.0222（原解为 age，见下注）
            --   +0x18 = 457 常量（像创建者/本地玩家实体 id）· +0x20 = 0（= 无实体，即"空白标记"）
            --   +0x28 = **到某个公共点的距离**（三边定位：8 点解得公共点，残差 ~0.7m RMS）
            --   +0x2c/+0x30 ≈ (960, 600) 常量附近（像屏幕/UI 投影）· +0x44..0x50 ≈ (1,1,1,0.933)
            return 'slot='..slot..';id='..tostring(L.u32(bytes,0x20))
                ..';age='..string.format('%.2f',f[5])
                ..';pos='..string.format('%.2f/%.2f/%.2f',f[1],f[2],f[3])
                ..';dist='..string.format('%.2f',f[10])
                ..';hex='..hex..';f3='..table.concat(cand,'|')
        end)
        options.slot_dump_diagnostic(ok and detail
            or ('slot='..slot..';dump_error='..tostring(detail)))
    end
    -- ★ 只读：最近一次观测到的**空白标记**（玩家 ping 到空地）的世界坐标。
    --   返回 `{x,y,z,dist,slot}` 或 nil。⚠ **不参与任何现有决策** ——
    --   本轮（2026-10-01）只把它打成诊断日志，为"ping 位置 ⇒ 点目标接管"做前置验证。
    function api:last_point() return last_point end
    function api:reset()
        memory:reset();diagnosed={};diagnostic_count=0
        last_selected=nil;failed_frames=0;last_point=nil
    end
    function api:forget(identity)
        memory:forget(identity)
        -- 该实体已被确认不可用（被引爆/实体销毁），stale 引用必须同步清掉，
        -- 否则失败帧返回 last_selected 时又会把它喂回给 priority。
        if last_selected and last_selected.identity==identity then last_selected=nil end
    end
    -- ★★ 2026-10-09：本机玩家（"我自己"）的只读取用 ★★
    --   为什么放这里：这段 owner 判定（`local_ownership_observed` + 实体/身份复核）
    --   是本工程**唯一经过实机验证**的"挑出本机玩家"的路径，
    --   在这里复用 ⇒ runtime 侧不必重复实现、也不必新 require 一个 Authority。
    --   ⚠ 只读：不写任何内存。⚠ 失败一律返回 `nil,reason`（调用方 pcall 包住）。
    --   用途：给「G-60 爆炸安全区」确认"玩家是谁 + 坐标"，本身不改变任何行为。
    function api:self()
        local ok,result=pcall(function()
            local d=Data.new(env.read,env.base,env.exe)
            local actors=d.ptr(env.base+0x3326d20)
            if not actors then return nil,'actors_unavailable' end
            local count=d.u32(actors+0x70)
            if not count or count==0 or count>16 then return nil,'count:'..tostring(count) end
            local want=env.self_resource          -- 玩家本体哈希（可为 nil）
            local by_hash,by_owner,slots,nets=nil,nil,0,{}
            for i=0,count-1 do
                local p=d.read(actors+0x110+i*8,8)
                if L.hex64(p,0)~='0000000000000000' then
                    local address=L.pointer(p,0)
                    local bytes=d.read(address,24)
                    local e=d.entity(L.u32(bytes,8))
                    if e then
                        slots=slots+1
                        -- ⚠ 字段名是 **resource**（`d.entity` 里 `resource=L.hex64(identity,0)`），
                        --   不是 hash —— 我第一版写成 `e.hash` ⇒ 恒 nil ⇒ by_hash 永远 miss
                        --   （实机日志 `by_hash=miss;...hash=nil;nets=` 空就是这个错）。
                        nets[#nets+1]=tostring(e.resource)
                        if want and e.resource==want and not by_hash then
                            pcall(d.unit,e)
                            by_hash={entity=e,index=i,position=d.position(e)}
                        end
                        -- ② 按本地归属匹配（本工程已实机验证过的那条路）
                        if Authority.inspect(env.engine,L.u32(bytes,16)).local_ownership_observed
                            and not by_owner then
                            -- ★★ 2026-10-10 关键修复（实机：安全区全路径失效）★★
                            --   `d.unit(e)` 内部读 `d.ptr(exe+0x1a100f0)`，**会抛
                            --   `pointer bound`**（实机 `selfprobe;err=…:1050: pointer bound` 就是它）。
                            --   而它只是"这实体确实是 Unit"的**校验**，**坐标根本不需要它**
                            --   （`d.position` 走 motion manager 0x3326508）。
                            --   ⚠ 我此前把 unit 与 position 放在**同一个 pcall** 里 ⇒
                            --     unit 一抛错就把整个 self() 打回 nil ⇒ `by_owner` 永远拿不到
                            --     ⇒ 门函数每帧 fail-open ⇒ **三条路径全都不拦**
                            --     （实机铁证：上一版 blast_hold 1062 条 → 本版 **0 条**）。
                            --   ⇒ 单独 pcall：unit 校验失败**不影响**返回坐标。
                            local uok=pcall(d.unit,e)
                            by_owner={entity=e,net=L.u32(bytes,16),index=i,
                                unit_ok=uok,position=d.position(e)}
                        end
                    end
                end
            end
            -- ★ 双路都打出来：这是"这个哈希对不对"的唯一判据 ——
            --   两条指向同一实体 ⇒ 哈希可用；只有一条 ⇒ 需要判读哪个可信。
            return {by_hash=by_hash,by_owner=by_owner,count=count,slots=slots,nets=nets}
        end)
        if not ok then return nil,tostring(result) end
        return result
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
            local point_seen                      -- 本帧看到的空白标记位置（见 slot_point）
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
                            -- ★ 且记下它的**世界坐标**（只接受 `id==invalid` 的真空白标记：
                            --   `not e` 也包含"有 id 但实体读不到"，那种不能当地面点用）。
                            --
                            -- ★★ 2026-10-02：多个空标记并存时取**最新 ping 的那个**（用户要求）★★
                            --   旧行为只按**扫描顺序**（head→tail，取最后扫到的槽）—— 那是
                            --   "最后看到的"，不是"最后 ping 的"：ping 环是**环形复用**的，
                            --   先 ping 的标记完全可能落在更靠后的槽位 ⇒ 优先级反了。
                            --   新判据：`age` **最小**（= 存在时间最短 = 最近 ping 的）。
                            --     · `age` 来自槽 `+0x14`，单位秒，精度约 1 帧（0.01s）
                            --       —— 实机佐证：`slot=75 age=0.03` vs `slot=76 age=0.01`
                            --     · 同一帧内的多个标记无法区分 ⇒ 用 `<=`（而非 `<`）保留
                            --       "扫描顺序最后"作为兜底，与旧行为一致
                            --     · 取不到 age 时同样保留旧行为
                            --   ⚠ 纯**选择**逻辑：不改任何槽的读写语义、不多读一个字节。
                            if id==d.invalid then
                                local px,py,pz,pd=slot_point(r)
                                if px and (point_seen==nil or point_seen.age==nil or age==nil
                                    or age<=point_seen.age) then
                                    point_seen={x=px,y=py,z=pz,dist=pd,slot=slot,age=age,
                                        -- token = 槽 + 位置字节：同一个槽里**换了位置**也算新标记
                                        -- （玩家在同一个槽上 ping 了新地点时必须重新计时）
                                        token=tostring(slot)..':'..r:sub(5,16)}
                                end
                            end
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
            -- ★★ 记忆的**存续判据**（2026-10-01，用户实机反馈）★★
            --
            --   用户原话：「标记过的单位，即使取消标记，G60 仍会追踪该单位」。
            --
            --   背景：ping_memory 的设计是"UI 过期不代表意图过期" —— history 只要
            --   实体还有效（`valid()`）就一直留着。这对**虫洞**是对的
            --   （"ping 一次虫洞、过一会儿才扔"是常规操作），但对**通用单位**
            --   就成了"取消不掉"：标记从画面上消失之后，记忆里那条还在 ⇒
            --   之后每一颗 G-60 仍会照它去追那个单位。
            --
            --   ⚠ 这里**不修改 ping_memory**（它在"上游原样"清单里，见
            --     tests/test_bughole_scope.py 的 UNTOUCHED）—— 改为在**返回给上层的
            --     队列上过滤**：`queue` 每一项的 `current` 由 ping_memory 算好
            --     （= 本帧 ping 环里确实还看得到它，即 UI 的 8 秒窗口内），
            --     两者组合就是"允许存活的标记"。判据由调用方给
            --     （`options.remembered_intent`，未提供 = 完全原行为）。
            --
            --   ⚠ 已在飞向该单位的那颗**不受影响**：它持有 old.lock，下一帧走
            --     native_priority 的 sticky 复核（按实体 id 重读），不依赖这条记忆
            --     —— 2026-09-28「半路停手」的修复不会被这条改回退。
            --   ⚠ 观测失败那一帧上面已把 `current` 翻成 false ⇒ 通用标记会当帧消失、
            --     下一帧成功观测时按 `current` 重算恢复（只抖一帧，不会永久丢）。
            if selected and options.remembered_intent then
                local kept={}
                for _,m in ipairs(selected.queue or {selected}) do
                    if m.current or options.remembered_intent(m,false) then
                        kept[#kept+1]=m
                    end
                end
                if #kept==0 then
                    selected=nil
                else
                    -- ⚠ 复制一份当 top，**不要**直接拿 kept[1] 并给它挂 queue ——
                    --   那会让 `selected.queue[1]==selected`（自引用环），
                    --   任何"顺着 queue 往下走一层"的写法都会绕回自己。
                    --   ping_memory 自己也是用 copy 这个写法（top=copy(queue[1])）。
                    local top={}
                    for k,v in pairs(kept[1]) do top[k]=v end
                    top.queue=kept
                    selected=top
                end
            end
            -- ★★ 队列内部的**优先级**（2026-10-02，用户：「标记敌人单位时，泰坦的优先级不是最高的」）★★
            --
            --   背景：队列（ping_memory 的 history）是按**新旧**排的 —— 队首 = 最晚 ping 的那个。
            --   于是"先标泰坦、后标一只小怪"时，小怪会盖住泰坦；而名册里的 rank
            --   （泰坦/蟑龙 = 10，最高）**只在自动索敌路径用过**，那条路径本工程早已裁掉。
            --   ⇒ 让调用方用 `options.priority(mark) -> number`（**小的先**）指定队内次序。
            --   典型实现：虫洞/构筑 → 0；名册敌人 → 1000+rank；其它单位 → 1500（见 runtime）。
            --
            --   ⚠ **只在"最高优先级不是队首"时才换** ⇒
            --     · 未提供 `options.priority`（如空白标记那条队列）⇒ 完全原行为（不复制、不换）
            --     · 队首本来就是最优 ⇒ 也不动（`bi<=1`）⇒ 零行为变化
            --   ⚠ 相等优先级**保持原顺序**（"最新优先"）—— 用严格 `<` 逐个比较实现，
            --     不用 `table.sort`（Lua 的 sort 不稳定，相等项会被打乱）。
            --   ⚠ `top.queue=base` 仍是**原顺序**（与 ping_memory 的写法一致：queue 是完整队列，
            --     top 是其中的一个 copy）⇒ 顺着 queue 走的消费者语义不变。
            if selected and options.priority then
                local base=selected.queue or {selected}
                local best,bi
                for i=1,#base do
                    local p=options.priority(base[i])
                    if p~=nil and (best==nil or p<best) then best,bi=p,i end
                end
                if bi and bi>1 then
                    local top={}
                    for k,v in pairs(base[bi]) do top[k]=v end
                    top.queue=base
                    selected=top
                end
            end
            -- ★ 空白标记位置：只在**本帧确实看到**时才更新，看不到就清空 ——
            --   位置随标记存活而失效，不会拿一个已经过期的 ping 点去引导 G-60。
            last_point=point_seen
            return selected
        end)
        if not ok then
            -- 瞬时读取失败：保留记忆，继续用上一次成功选中的标记。
            -- ★ 但**不能**继续声称它是"活标记"（2026-10-01）★
            --   本帧什么都没读到 ⇒ "它还在 ping 环里"这件事**没有被观测到**。
            --   `current` 是给上层判"新近标记"的门槛（native_priority 的让位规则、
            --   以及通用单位标记的存活判据），一个陈旧的真值会让上层基于**没观测过**
            --   的状态去抢占。这里把它翻成 false 是**语义正确**的，不是保守补丁。
            --   `last_selected` 是 memory:update 返回的 `copy(queue[1])`，与 history
            --   里的条目不是同一张表 ⇒ 改它不会污染记忆。
            if last_selected then last_selected.current=false end
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
