-- ============================================================================
-- ★ 已搁置 · **不纳入工程** ★
--   Harvester（猎杀器 = `cha_tripod`）部位瞄准 + 骨骼世界坐标探测（B 方案）
--
--   归档日期 2026-10-04 ｜ 归档原因：用户拍板「暂时搁置，把相关代码移出工程」
--   本文件**不参与构建、不被测试扫描**（build.py 只打包 `compat/build.json` 里
--   列出的 `src/g60/*.lua`；`tests/lua_syntax.py` / `tests/check_lua51_compile.py` 只扫 `src/g60`）。
--   ⚠ 但它是**可用的**：下面 [1] 段就是完整的 Lua 模块，拷回去即可工作。
-- ============================================================================
--
-- 【为什么搁置 —— 四轮实机 + 离线数据已把结论钉死】
--   1) **伤害算术（硬门槛）**：Harvester 要害 `body_default` = health **2000** / armor **4** /
--      `causes_death_on_death=1`；G-60 = `ExplosionType 351 → damageId 345`，
--      damage **1800**、**内半径 4 m** ⇒ **只打中主体是打不穿的**（1800 < 2000）。
--      一发能杀 ⇒ 必须让 4 m 球**同时罩住 3 个** `affected_by_explosions` 部位
--      （2000 + 800 + 800 = 3600 ≥ 本体 3000）。
--   2) **与高度无关**：55 颗按档位统计击杀率同量级且非单调
--      （2.0→57% · 5.0→100% · 11.0→43% · 12.5→83%）⇒ 调 `lift` 是白费手雷。
--   3) **A+ 也无效**：`region.radius` 收到 0.6 后，5 颗 G-60 全部正常引爆
--      （`horiz` 0.25~0.58、`|dz| ≤ 0.36）仍**无一击杀**。
--   4) **目标会走**：锁定 → 引爆之间中位 **1.95 m**、最大 6.92 m（41/55 > 1 m）。
--   5) **骨骼探测（B）走到场景图后卡住**：Harvester 的 **151** 个节点名**不含** `c_head`
--      —— 离线反查确认日志前 8 个样本是 `cha_tripod` / `StingrayEntityRoot` /
--      `FbxAxisSystem_ConvertNode` / `shadow_mesh` / `g_body_shadow(_LOD1/2/3)`
--      —— **全是模型节点，不是骨骼**；「`body_default` 骨骼 = `c_head`」**存疑**。
--   本工程**没有写内存原语** ⇒ 改不了伤害/血量（要改只能去军械调校台）。
--
-- 【怎么恢复（6 步）】
--   1. 把下面 **[1] 段**整体写回 `src/g60/bone_probe.lua`。
--   2. `compat/build.json` 的 `aliases` 加回 `"bone_probe": "BoneProbe",`
--      —— ⚠ **必须排在 `experimental_runtime` 之前**（依赖顺序；见 build.py `assert_alias_order`）。
--   3. `addon/entry.lua.in` 加回 **4 处**接线（见 **[3] 段**）。
--   4. `src/g60/experimental_runtime.lua` 加回 `bp={},`（P 表里）与探测调用块（见 **[3] 段**）。
--   5. 把下面 **[2] 段**贴回 `compat/blast_sites.lua` 的 `return sites` **之前**。
--   6. `tests/test_bughole_scope.py` 的 `allowed_new` 加回 `'bone_probe'`；
--      `tests/test_priority_fault_isolation.py` 的 bone_probe 守门按 **[4] 段**补回。
--
-- 【继续开发时的起点（未解决）】
--   拿一局 `bone_probe;…;step=names;part=*;hex=…` 的**全量**节点哈希
--   ⇒ 用离线表反查 151 个真名（判据 `murmur64a(name) >> 32`；
--     表可重建：`Hd2-Armory-Tuning-Bench/offline/datalibrary/` 的
--     `hashes.txt` + `thinhashes.txt`，约 13.8 万条）
--   ⇒ 定位 3 个吃爆炸部位的骨骼索引 ⇒ 才能回答「4 m 球能否同时罩住」。
--   ⚠ 旁证已排除：全库 `_jnt` 后缀名**恰好也是 151 个**，但逐个看全是**人脸骨骼**
--     （`l_head096_jnt` / `r_nosewing_jnt` / `campos001_jnt`）—— **巧合，别顺着猜。**
--
-- ⚠ 相关历史提交：`bbf8cac`（本功能的完整实现，含两轮探针修复）· `c1769b3`（v0.1.6）
-- ============================================================================


-- ============================================================================
-- [1] 模块全文 —— 原位置：`src/g60/bone_probe.lua`（可直接拷回）
-- ============================================================================
-- ★★★ B 方案第 1 步：**只读探测**「实体 → Unit → 场景图 → 骨骼世界坐标」（2026-10-04）★★★
--
-- 为什么需要它（用户拍板走 B）：
--   G-60 打 Harvester 的爆点现在是「实体原点 + 常数 lift」。实测（55 颗）证明这条**不行**：
--     · 目标在"锁定→引爆"之间**中位走 1.95 m**（最大 6.92、41/55 超过 1 m）；
--     · 各档位击杀率同量级（2.0→57% / 5.0→100% / 11.0→43%）⇒ **与高度无关**；
--     · 算术上还要"一发同时罩住 3 个吃爆炸部位"（要害 2000 HP / G-60 1800）。
--   ⇒ 正确做法是让爆点**跟着主体骨骼**（`c_head`）走 —— 与步态、朝向、行走无关。
--
-- 为什么先"探测"而不是直接改爆点：这条指针链**在 Harvester 上从未验证过**。
--   `titan_context`（SAFETY_LAYER，按纪律不可改）里的机制是：
--     Unit 虚表 `+0xe8` → accessor 函数 → **解释它唯一那条** `mov/lea rax,[rcx+disp]`
--     → 场景图 `graph` → `u32(graph+0x10)` = 骨骼数 → `names = *(graph+0x40)`（每骨 4 B 哈希）
--     → `poses = *(graph+0x28)`（每骨 64 B 的 4×4 矩阵，平移在最末 3 个 float = 字节 48/52/56）。
--
--   ★★ 那条指令有**四种**合法形状，位移宽度两种都要认（2026-10-04 实机日志纠正）★★
--     · disp32：`48 8B 81 imm32 C3`（mov rax,[rcx+imm32]）· `48 8D 81 imm32 C3`（lea）
--     · **disp8**：`48 8B 41 disp8 C3`（mov rax,[rcx+disp8]）· **`48 8D 41 disp8 C3`（lea）**
--     依据：`compat/titan_profile.lua` 的白名单里**本来就有** disp8 条目
--       `[0xe84080]={112,true,"488b4170c3"}`；而 Harvester 的 accessor 实测就是
--       **`48 8D 41 60 C3` = `lea rax,[rcx+0x60]`**。
--     ⚠ 只认 imm32 的旧版后果：`step=accessor` 直接 `fail=unknown accessor shape`，
--       骨骼坐标**一局都拿不到**（2026-10-04 第一次实机日志，5 个目标全断在这一段）。
--   但泰坦的 accessor **白名单**（`compat/titan_profile.lua` 的 `getters`）未必含 Harvester 的，
--   `alive_rva` 也是按单位类型记的 ⇒ **先把链走一遍，看它断在哪一段**。
--
-- ★ 安全边界（与 titan_context 同一口径）：
--   · 所有读都走传入的 `read`（= entry 提供的 `ReadProcessMemory`）⇒ **坏指针只会短读**，
--     断言失败 → 由本模块的 `run()` 记一条日志 → 上层 pcall 兜住。**不写任何内存**。
--   · **不执行**任何读出来的代码 —— 只按一条已知形状的指令（`mov/lea rax,[rcx+imm32]`）解释；
--     形状不认得就**停止**并记 `step=accessor;fail=unknown accessor shape`。
--   · **不碰 ffi**（本模块没有 `require('ffi')`）：float 手工解 IEEE754，
--     因为本工程有明令 `runtime_no_ffi_load`（ffi.cdef 会污染全局 C 命名空间 ⇒ 别的 mod 崩）。
--   · 预算：单次 ≤4096 B、总计 ≤32768 B（与 titan_context 相同）。
--
-- 日志形状（每一步一条，失败说清**在哪一段**）：
--   bone_probe;id=…;step=root;ok;root=…
--   bone_probe;id=…;step=hash;ok;cap=…;empty=…;mul=…
--   bone_probe;id=…;step=lookup;ok;index=…;address=…
--   bone_probe;id=…;step=identity;ok;rec_id=…;resource=…;handle=…
--   bone_probe;id=…;step=unit;ok;unit=…;count=…;index=…;gen=…
--   bone_probe;id=…;step=accessor;ok;rva=…;deref=…;off=…;code=…
--   bone_probe;id=…;step=graph;ok;nodes=…
--   bone_probe;id=…;step=names;ok;found=…;count=…
--   bone_probe;id=…;step=names;part=k;hex=…,…
--   bone_probe;id=…;step=pose;ok;<骨骼>=x,y,z,…;origin=x,y,z
--   bone_probe;id=…;step=<段>;fail=<原因>
local M={}
local function u32(s,o)
    local a,b,c,d=s:byte(o+1,o+4)
    return ((d*256+c)*256+b)*256+a
end
local function h64(s,o)
    return string.format('%08x%08x',u32(s,o+4),u32(s,o))
end
local function p64(s,o)
    return u32(s,o+4)*4294967296+u32(s,o)
end
local function f32(s,o)
    -- IEEE754 单精度（不用 ffi，见文件头）
    local a,b,c,d=s:byte(o+1,o+4)
    local v=((d*256+c)*256+b)*256+a
    local sign=1
    if v>=2147483648 then sign=-1;v=v-2147483648 end
    local e=math.floor(v/8388608);local m=v%8388608
    if e==0 then return sign*m*2^-149 end
    if e==255 then error('non-finite pose') end
    return sign*(m+8388608)*2^(e-150)
end
-- 要找的骨骼（全部由 `thin(name) = murmur64a(name)>>32` 离线算出，见 REF §11）
local NODES={
    {3086982327,'c_head'},        -- body_default（要害）的骨骼
    {4223265597,'c_eye'},
    {1727583650,'c_body_front'},
    {2665904039,'c_head_left'},
    {676627662,'c_head_right'},
    {274072294,'z800a'},          -- 另一个吃爆炸部位的 actor（名字未解出）
    {1027847345,'z800b'},
}
function M.probe(read,base,exe,id,emit)
    local total=0
    local function rd(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and a+n<2^47 and n>0 and n<=4096,
            'read bound')
        total=total+n
        assert(total<=32768,'read budget')
        local s=read(a,n)
        assert(type(s)=='string' and #s==n,'short read')
        return s
    end
    local function mul32(a,b)
        local al,bl=a%65536,b%65536
        return (al*bl+((math.floor(a/65536)*bl+math.floor(b/65536)*al)%65536)*65536)%4294967296
    end
    local function say(step,detail)
        emit('bone_probe;id='..tostring(id)..';step='..step..';ok;'..detail)
    end
    local function fail(step,err)
        emit('bone_probe;id='..tostring(id)..';step='..step..';fail='..tostring(err):sub(1,140))
    end
    -- 每一段自己兜异常：**失败要停在那一段**，而不是整条链没有任何输出
    -- ⚠ 必须返回**全部**返回值：`pose` 段是成对返回 (pose,origin)，
    --   只取第一个会让 origin 变 nil ⇒ 整段**静默**跳过（合成映像测试抓到的真 bug）
    local function run(step,fn)
        local ok,a,b,c=pcall(fn)
        if not ok then fail(step,a);return nil end
        return a,b,c
    end
    local root=run('root',function() return p64(rd(base+0x346bf98,8),0) end)
    if not root then return end
    say('root','root='..string.format('%x',root))
    local h=run('hash',function() return rd(root+0xf1aeb0,20) end)
    if not h then return end
    local entries,cap,empty,mul=p64(h,0),u32(h,8),u32(h,12),u32(h,16)
    say('hash','cap='..cap..';empty='..empty..';mul='..mul)
    local address=run('lookup',function()
        assert(cap>0 and cap<=1048576 and id~=empty,'cap bound')
        local c=cap;while c>1 and c%2==0 do c=c/2 end
        assert(c==1,'cap not power of two')
        for probe=0,math.min(cap,256)-1 do
            local row=rd(entries+((mul32(id,mul)+probe)%cap)*8,8)
            local key=u32(row,0)
            if key==empty then break end
            if key==id then return root+0xf32f18+u32(row,4)*24,u32(row,4) end
        end
        error('id not in entity hash')
    end)
    if not address then return end
    say('lookup','address='..string.format('%x',address))
    local identity=run('identity',function() return rd(address,24) end)
    if not identity then return end
    local handle=u32(identity,12)
    say('identity','rec_id='..u32(identity,8)..';resource='..h64(identity,0)..';handle='..handle)
    local unit,ucount,uidx=run('unit',function()
        assert(handle~=0,'handle 0')
        local manager=p64(rd(exe+0x1a100f0,8),0)
        local idx=handle%0x400000
        local count=u32(rd(manager+0x98,4),0)
        assert(idx<count and count<=0x400000,'unit index bound')
        assert(rd(p64(rd(manager+0xa0,8),0)+idx,1):byte()==math.floor(handle/0x400000)%256,
            'unit generation mismatch')
        return p64(rd(p64(rd(manager+0x88,8),0)+idx*8,8),0),count,idx
    end)
    if not unit then return end
    say('unit','unit='..string.format('%x',unit)..';count='..tostring(ucount)..';index='..tostring(uidx))
    -- ★ accessor 在 **Unit 的虚表** 上：`getter = *(*(unit) + 0xe8)`
    --   （与 titan_context 的 `ptr(ptr(unit)+0xe8)` 逐字一致 —— 少一层解引用就会
    --     读到 Unit 自己的字段，形状对不上 ⇒ 白跑一轮）
    local getter=run('accessor',function()
        local vt=p64(rd(unit,8),0)
        return p64(rd(vt+0xe8,8),0)
    end)
    if not getter then return end
    local code=run('accessor',function() return rd(getter,12) end)
    if not code then return end
    local off,deref
    local op=code:sub(1,3)
    -- 每条都必须以 `C3`(ret) 收尾 —— 这是"函数体只有这一条指令"的强形状证据。
    -- ⚠ 不做这个校验就等于"看到 48 8D 41 就当 accessor"，别的函数被误解释也发现不了。
    if op=='\72\139\129' and code:byte(8)==0xc3 then      -- 48 8B 81 imm32 ⇒ mov rax,[rcx+imm32]
        off,deref=u32(code,3),true
    elseif op=='\72\141\129' and code:byte(8)==0xc3 then  -- 48 8D 81 imm32 ⇒ lea rax,[rcx+imm32]
        off,deref=u32(code,3),false
    elseif op=='\72\139\065' and code:byte(5)==0xc3 then  -- 48 8B 41 disp8 ⇒ mov rax,[rcx+disp8]
        off=code:byte(4);if off>=128 then off=off-256 end;deref=true
    elseif op=='\72\141\065' and code:byte(5)==0xc3 then  -- 48 8D 41 disp8 ⇒ lea rax,[rcx+disp8]
        off=code:byte(4);if off>=128 then off=off-256 end;deref=false
    end
    say('accessor','rva=0x'..string.format('%x',getter-exe)..';deref='..tostring(deref)
        ..';off='..tostring(off)..';code='..code:gsub('.',function(c)
            return string.format('%02x',c:byte()) end))
    if off==nil then
        fail('accessor','unknown accessor shape')
        return
    end
    local graph=run('graph',function()
        local g=deref and p64(rd(unit+off,8),0) or unit+off
        local nodes=u32(rd(g+0x10,4),0)
        assert(nodes>=1 and nodes<=512,'nodes bound '..nodes)
        return {g=g,nodes=nodes}
    end)
    if not graph then return end
    say('graph','nodes='..graph.nodes)
    local names=run('names',function() return rd(p64(rd(graph.g+0x40,8),0),graph.nodes*4) end)
    if not names then return end
    local found,all={},{}
    for i=0,graph.nodes-1 do
        local hash=u32(names,i*4)
        all[#all+1]=string.format('%08x',hash)
        for _,want in ipairs(NODES) do
            if hash==want[1] then found[want[2]]=i end
        end
    end
    local fl={}
    for k,v in pairs(found) do fl[#fl+1]=k..'@'..v end
    table.sort(fl)
    say('names','found='..(#fl>0 and table.concat(fl,',') or 'none')..';count='..#all)
    -- ★★ 全量输出节点哈希（分批：emit 单行 ≤900 字符）★★
    --   为什么必须全量（2026-10-04 实机教训）：`found=none` —— 我们**以为**是骨骼名的那 7 个哈希
    --   一个都不在；而日志里给的前 8 个样本离线反查出来是
    --     `StingrayEntityRoot` / `FbxAxisSystem_ConvertNode` / **`cha_tripod`** /
    --     `shadow_mesh` / `g_body_shadow_LOD3` / `_LOD2` / `_LOD1` / `g_body_shadow`
    --   —— **全是模型/LOD/阴影节点，不是骨骼**。只给 8 个样本 ⇒ 永远解不出骨骼清单。
    --   全量打出来 ⇒ 离线用 `thinhashes.txt` 一把反查（`murmur64a(name)>>32`）。
    --   每行 60 个（60×9 = 540 字符 + 前缀 ≈ 580 < 900）。
    local CHUNK=60
    for k=1,#all,CHUNK do
        local seg={}
        for j=k,math.min(k+CHUNK-1,#all) do seg[#seg+1]=all[j] end
        emit('bone_probe;id='..tostring(id)..';step=names;part='
            ..tostring(math.floor((k-1)/CHUNK)+1)..';hex='..table.concat(seg,','))
    end
    -- ★ origin（根骨骼平移）**总是**读一次 —— 它是"`*(graph+0x28)` 真是 poses"的独立证据，
    --   不该因为"没找到 c_head"就跳过验证这一环（否则下次还是不知道 poses 链通不通）。
    local poses=run('poses',function() return p64(rd(graph.g+0x28,8),0) end)
    if not poses then return end
    local parts,origin=run('pose',function()
        local r=rd(poses,64)
        local list={}
        for _,want in ipairs(NODES) do
            local i=found[want[2]]
            if i then
                local m=rd(poses+i*64,64)
                list[#list+1]=want[2]..'='..string.format('%.2f,%.2f,%.2f',f32(m,48),f32(m,52),f32(m,56))
            end
        end
        return table.concat(list,','),string.format('%.2f,%.2f,%.2f',f32(r,48),f32(r,52),f32(r,56))
    end)
    if not parts or not origin then return end
    say('pose',(#parts>0 and parts..';' or '')..'origin='..origin)
end
return M


-- ============================================================================
-- [2] Harvester 站点段原文 —— 原位置：`compat/blast_sites.lua` 的 `return sites` 之前
-- ============================================================================

-- ============================================================================
-- ★★★ Harvester（猎杀器 = `cha_tripod`）—— **敌人部位瞄准**（2026-10-04 用户要求）★★★
--
--   为什么必须指定爆点：Harvester 的 34 个 `damageable_zones` 里 **只有 3 个**
--   `affected_by_explosions = 1`（吃爆炸伤害），其余 **31 个对爆炸免疫** ——
--   免疫的那批包括 `eye` / `left|right|back_hip` / 各段 `leg` / `shield_generator_*`。
--   G-60 的伤害**就是爆炸** ⇒ 爆点落在那些部位上**一点伤害都不产生**。
--   （用户实测口径：「其他部位有爆炸免疫」。）
--
--   吃爆炸的三个部位（离线数据 / Darctor `HealthComponentData`）：
--     · **`body_default`** armor 4 / health **2000** / affects_main 1.0 ← **本条目瞄准它**
--     · 另两个 armor 2 / health 800 的部位（zone_name 未解出）
--   ⇒ 爆点必须落进 `body_default` 的**体积**。该部位的骨骼 = **`c_head`**（3086982327）。
--
--   ★ 本条走 **A 方案（近似）**：`实体原点 + lift` ⇒ 点目标 ⇒ arrival
--     （与巨型构筑者**同一条已验证路径**）。
--     `lift` 的物理含义 = "`c_head`（主体中心）相对实体原点的高度"，**需要实机标定**。
--   ★ 专用档位 `HARV_SCAN`：逐颗 G-60 依次取一档 ⇒ **哪一颗把它炸死 ⇒ 主体就在那个高度**。
--     档位按手雷推进（`P.swk[m.id]`）、绝不按帧；标定完把 `HARV_SCAN` 清成 `{}` 即可退回单值。
--   ⚠ 精度边界（知情）：近似点**不跟骨骼**，Harvester 走动/上下坡时只保证"原点 + lift 那么高"。
--     若要贴死主体，需要读 `c_head` 的世界坐标（工程里 `titan_context` 有现成实现，
--     但那套要按单位类型标定场景图访问器 ⇒ 泰坦级工作量，未做）。
--
--   资源身份：`965eae5a51acdd4a` = `content/fac_illuminate/cha_tripod/cha_tripod`
--     （MurmurHash64A 验证；Darctor `Hash.csv` 同值 ⇒「光能族 / Harvester / 猎杀器」）。
--   ⚠ 这是**敌人**（不是结构）⇒ 本名册的语义已扩为「**需要指定爆点的目标**」。
local HARV_LIFT=6.5
--
-- ★★★ 第二轮实机（2026-10-04 09:4x，**55 颗**）：**这不是"高度标定"能解决的问题** ★★★
--
--   ⚠ **撤回第一轮的结论**：那条"判定带 ∈ (4.13, 7.28]"只是**两个样本的巧合**。
--   本局 55 颗、12 组同目标连投（组内最后一颗视为击杀）按档位统计击杀率：
--
--       2.0 → 57% · 3.5 → 71% · **5.0 → 100%(7/7)** · 6.5 → 86% · 8.0 → 86%
--       · 9.5 → 86% · 11.0 → 43% · 12.5 → 83%
--
--   非单调、且各档都在同一量级 ⇒ **命中与否与 `lift` 基本无关**
--   ⇒ 继续扫高度（下一轮本来要扫 0.5 档距）**是白费手雷**，已停。
--
--   ★ 真正的原因两条，都从这局日志 / 离线数据里量出来了：
--
--   (1) **目标在"锁定→引爆"之间会走**：`blast_point;…;origin=`（锁定时）与
--       `blast_hit;…;origin=`（引爆时）之差 = 目标走了多远 ——
--       中位 **1.95 m**、最大 **6.92 m**、**41/55 超过 1 m**。
--       ⚠ 爆点本身没问题：`arrival_detonated` 的 `horiz` 1.31~1.50、`|dz| ≤ 1.0，
--       且该点**每帧重算**（在 `arrival:step` 的逐帧回调里）确实跟着目标。
--       但**主体是挂在骨骼上的体积、会随步态起伏** ⇒ "原点 + 常数 lift" 没法保证
--       爆炸的 **4 m 内半径罩住该罩的部位**。
--
--   (2) ★★★ **伤害算术 —— 这才是硬门槛（离线数据）** ★★★
--       · Harvester 本体 health **3000**；**要害 = `body_default`**：
--         health **2000** / armor **4** / **`causes_death_on_death=1`（打掉它即杀本尊）** /
--         `affects_main_health=1.0` / `main_health_affect_capped_by_zone_health=1` /
--         骨骼 = `c_head`；`child_zones=[eye]`。
--       · G-60 = `ExplosionType 351 → damageId 345`：**damage 1800**、装甲档 5/5/5/**4**、
--         **内半径 4 m** / 外半径 12 m。
--       · 34 个部位里**只有 3 个**吃爆炸：`body_default`(2000) + 两个 armor2/**800**
--         （骨骼 `0x105602e6` / `0x3d43b4b1`，名字未解出）。
--       ⇒ **一发 1800 < 要害 2000 ⇒ 只打中主体是打不穿的**。
--         一发能杀 ⇒ 必须让内半径 4 m **同时罩住这 3 个部位**
--         （主血转移按各部位血量封顶：2000 + 800 + 800 = 3600 ≥ 3000）。
--       ⇒ "有时一发死、有时不死" = **那一发罩住了几个部位**在变，**与高度无关**。
--       ⇒ **不要再靠调 `lift` 追"一发稳定"**；问题不在标定。
--
--   ⚠⚠ 本文件改不了伤害/血量（本工程**没有写内存原语**）⇒ 要动数值只能去军械调校台。
--   下一步三条路（已交用户拍板）：
--     **A+** 收紧 `region.radius`：把"我们自己 ~1.4 m 的**随机方向**偏移"消掉
--          ⇒ 球更容易罩全那 3 个部位（本轮先按这条出一包，见下面的 region）。
--     **B**  读 `c_head` **骨骼世界坐标**当爆点（`titan_context` 有现成机制：
--          accessor → `graph+0x10` nodes → `names(graph+0x40)` → `poses(graph+0x28)+i*64`；
--          `thin("c_head")` = **3086982327** 已离线验证）⇒ 跟着主体走，与步态/朝向无关。
--     **C**  接受算术结论：**2 发**才是稳定解，把目标改成"两发稳定击杀"。
--
--   ⚠ **档位机制保留但关着**（`HARV_SCAN={}`）：它仍然是有用的工具，
--     但**只在对某个量有成对假设时才开**（高度已被证伪，别再开它扫高度）。
--
-- ★★★ 第三轮实机（2026-10-04 10:1x，**A+ 方案的验证局**）：A+ 也无效 ★★★
--
--   本局 = lift 6.5 + `region.radius` 收到 **0.6**（A+：消掉我们自己那 ~1.4 m 的
--   **随机方向**偏移）。结果——**"接管质量"无可挑剔，但一颗都没杀死**：
--
--     · 5 颗 G-60 **全部**由本 mod 正常引爆（`blast_hit;via=arrival` × 5）：
--       `delta` 的竖直分量 6.14 / 6.49 / 6.52 / 6.67 / 6.85（= 爆心确在原点上方 ~6.5 m）；
--     · 到达精度**反而更好**了：`arrival_detonated` 的 `horiz` **0.25~0.58**
--       （上一轮 1.31~1.50）、`|dz| ≤ 0.36` ⇒ **不是"没到位"，也不是"偏了"**；
--     · 另有 1 颗（entity 789）连引爆都被**引擎抢先**：
--       `arrival_skipped;…explosion already requested` + `blast_hit;via=engine`
--       —— 引擎自己的 `aim` 落在原点附近（地面/底部）⇒ 那一发必然白炸。
--
--   ⇒ **A+ 不成立**（收紧水平半径并没有提高击杀率）⇒ 与"高度无关"同样的结论：
--     **单一固定爆点（原点 + 常数）在原理上就到不了"球同时罩住 3 个吃爆炸部位"**。
--     只能走 **B（跟着骨骼走）**，或接受 **C（两发稳定）**。
--
--   ★ 同轮日志还暴露了 B 的**阻塞点**（已修，`src/g60/bone_probe.lua`）：
--     5 个目标的探测**全部**停在该段 ——
--       `bone_probe;step=accessor;fail=unknown accessor shape`（`code=488d4160c3`）
--     ⇒ 实机 accessor 是 **disp8 形状** `48 8D 41 60 C3`（`lea rax,[rcx+0x60]`），
--       而探针只实现了 disp32（`48 8D 81 imm32`）⇒ 链在"进场景图之前"就断了，
--       `c_head` 一局都没拿到。**这不是猜测**：`compat/titan_profile.lua` 白名单里
--       本来就有 disp8 条目（`[0xe84080]={112,true,"488b4170c3"}`）。
--     修法：两种位移宽度都认 + 要求 `C3`(ret) 收尾；并让 `step=pose` 输出**全部**
--     命中的骨骼（B 需要的是 3 个吃爆炸部位的**相对位置**，只给 `c_head` 一个点算不出来）。
--
--   ⇒ **下一局的判据**：探针应打出
--       `step=names;ok;found=c_head@N,z800a@…,z800b@…` + `step=pose;ok;<骨骼>=x,y,z,…;origin=…`
--     拿到三点后即可回答"4 m 内半径能否同时罩住这 3 个" ⇒ 决定 B 是否可行、或转 C。
-- ★★★ 第四轮实机（2026-10-04 10:4x）：**B 的链已走通，但骨骼名对不上** ★★★
--
--   accessor 修复**生效**（上一轮那个 `unknown accessor shape` 没了）：
--     bone_probe;step=accessor;ok;rva=0x2bd870;deref=false;off=96;code=488d4160c3…
--     bone_probe;step=graph;ok;nodes=**151**
--     bone_probe;step=names;ok;found=**none**;sample=4a182741,7f30e61c,722e2631,1d667f2e,…
--
--   ⇒ **到场景图为止全对**（151 个名字是真实名字，不是垃圾数据）。
--   ⇒ 但 `found=none`：候补的 7 个名字（`c_head`/`c_eye`/`c_body_front`/
--      `c_head_left`/`c_head_right`/`z800a`/`z800b`）**一个都不在**这 151 个节点里。
--
--   ★ 离线反查（`thinhashes.txt` + `hashes.txt`，判据 `murmur64a(name) >> 32`；
--     自检：`murmur64a("hello, world!") = 0xd18abe154a2a9637` ✓、
--     泰坦 `boss_hash = 0x9b115563` 反查 = **`boss`**、`belly_hash = 0x561d5e2e` = `belly_entrails2_3` ✓
--     ⇒ 方法与库都可信）：
--       0x722e2631 = **`cha_tripod`**（Harvester 模型名 —— 节点表里确实有它）
--       0x4a182741 = `StingrayEntityRoot` · 0x7f30e61c = `FbxAxisSystem_ConvertNode`
--       0x1d667f2e = `shadow_mesh`
--       0x51c77b11 / 0x7a3790c2 / 0x1e307614 / 0x71b4f330 =
--         `g_body_shadow` / `g_body_shadow_LOD3` / `_LOD2` / `_LOD1`
--     ⇒ 前 8 个是**模型 / LOD / 阴影节点**，不是骨骼 ⇒ 节点表是"模型节点 + 骨骼"混合，
--       骨骼在**后面**（而日志只给了前 8 个样本 —— 这正是拿不到结论的原因）。
--   ⚠ `c_head` **确实存在于名字库**（`thin("c_head") = 3086982327` 已复算确认），
--     但**不在 Harvester 的场景图里** ⇒「`body_default` 的骨骼 = `c_head`」这条**存疑**：
--     要么骨骼名体系不同（库里同族还有 `c_head0142_jnt` / `c_head0148_jnt` 这种
--     **带数字后缀的 `_jnt`**），要么该字段根本不是场景图节点名。**以实机全量数据为准。**
--     （旁证：全库 `_jnt` 后缀名恰好也是 151 个，但逐个看是**人脸骨骼** `l_head096_jnt` /
--       `r_nosewing_jnt` / `campos001_jnt` … ⇒ 与 Harvester 无关，纯属巧合，别顺着猜。）
--
--   ⇒ 本次出包（B 第 2 步）：探针改为
--     ① **全量**输出节点哈希（分批 `step=names;part=k;hex=…`，每行 60 个 < 900）；
--     ② **无条件**读一次 `origin`（"`*(graph+0x28)` 真是 poses"的独立证据，不再因为
--        `found=none` 就跳过）。
--     下一局拿到全量 ⇒ 离线一把反查 ⇒ 得到 151 个**真名** ⇒ 定位"吃爆炸的 3 个部位"的骨骼索引。
local HARV_SCAN={}
sites["965eae5a51acdd4a"]={resource="965eae5a51acdd4a",lift=HARV_LIFT,scan=HARV_SCAN,
    -- 到达区域（2026-10-04 第二轮，A+ 方案）：
    -- ★ **水平 1.5 → 0.6**：实测爆心总落在 ~1.4 m 的**随机一侧**
    --   （`horiz` 1.31~1.50，四颗方向各不相同），而"罩住 3 个部位"对偏移方向敏感
    --   ⇒ 先把爆点拉回中轴（这是"球罩得更全"的直接手段）。
    -- 竖向保持 −0.4/+0.5（比巨型构筑者的 [−0.25,+0.6] 略松；55 颗里 `blast_stalled` = 0）。
    -- ⚠ 若新窗口出现 `blast_stalled` ⇒ 说明水平收得过紧，把 radius 放回 0.8~1.0。
    region={radius=0.6,depth=0.4,above=0.5},
    label="cha_tripod.body_default"}


-- ============================================================================
-- [3] 接线片段 —— 摘除时从以下位置删除；恢复时贴回
-- ============================================================================
--
-- ▍3.1 `compat/build.json` 的 `aliases`（插在 `"experimental_runtime": "Runtime"` **之前**）
--     "bone_probe": "BoneProbe",
--
-- ▍3.2 `addon/entry.lua.in` —— 共 4 处 bone_probe + 1 处 Harvester 状态行
--
--   (a) state 表里（`blast_sites_enabled=true,` 之后）：
--         bone_probe_enabled=true,
--
--   (b) emit 的日志节流白名单（多行 and 链里）：
--             and not line:match('^bone_probe;')
--
--   (c) env 透传（`blast_sites=state.blast_sites_enabled and BlastSites or nil,` 之后）：
--         bone_probe=state.bone_probe_enabled and BoneProbe or nil,
--
--   (d) 启动状态行（`..';blast_sites='..tostring(state.blast_sites_enabled)` 之后）：
--         ..';bone_probe='..tostring(state.bone_probe_enabled)
--
--   (e) Harvester 状态行块（在巨型构筑者那段的 `local s=BlastSites and BlastSites["4232ee48e2cfd24e"]` 之后）：
--         local hv=';harv_lift=nil;harv_region=none;harv_scan=off'
--         local h=BlastSites and BlastSites["965eae5a51acdd4a"]
--         if h then
--             local hs='off'
--             if h.scan and #h.scan>0 then hs=table.concat(h.scan,',') end
--             hv=';harv_lift='..tostring(h.lift)
--                 ..';harv_region='..(...region 三元...)
--                 ..';harv_scan='..hs
--         end
--       （**恢复时以 git 历史 `bbf8cac` 的逐字原文为准** —— 上面是结构示意，
--         不要照抄省略号；`git show bbf8cac:addon/entry.lua.in` 可取全文。）
--
-- ▍3.3 `src/g60/experimental_runtime.lua`
--
--   (a) P 表里（`swk`/`swn` 之后）：
--         -- ★ 骨骼探针的"每目标一次"去重表（2026-10-04，见 g60.bone_probe）
--         bp={},
--
--   (b) 接管分支里（Harvester/体内爆点那段之后）：
--         if env.bone_probe and env.emit and not P.bp[e.id] then
--             P.bp[e.id]=true
--             pcall(env.bone_probe.probe,read,base,env.exe,e.id,env.emit)
--         end
--       （逐字原文见 `git show bbf8cac:src/g60/experimental_runtime.lua`）

-- ============================================================================
-- [4] 测试守门 —— 摘除时一并删除；恢复时按需补回
-- ============================================================================
--
-- ▍4.1 `tests/test_bughole_scope.py` 的 `allowed_new`：
--         'bone_probe',   # 骨骼位置只读探测（B 方案第 1 步；零写入、零 ffi、逐段日志）
--
-- ▍4.2 `tests/test_priority_fault_isolation.py` 的 bone_probe 守门（原 8 条）：
--         bone_probe_module_is_a_table              用 lupa 真求值，验模块是**表**且含 probe
--         bone_probe_is_read_only_and_ffi_free      去注释后源码不得含 ffi./WriteProcessMemory
--         bone_probe_steps_are_staged               9 个 step 名齐全 + run()/fail() 存在
--         bone_probe_wired_through_env              env 透传 + P.bp 每目标一次 + tick 内 pcall
--         bone_probe_switch_status_whitelist        开关/env/状态行/白名单四处齐全
--         bone_probe_dumps_all_node_hashes          必须全量输出节点哈希（分批）
--         bone_probe_reads_origin_unconditionally   origin 无条件读一次
--         bone_probe_behavior_* + _fail_says_where  合成内存映像行为测试（**这条最有价值**）
--       外加：`bone_probe_does_not_change_blast_point`（第 1 步不改爆点）
--       以及 Harvester 站点守门：
--         blast_harv_scan_region_tight / blast_harv_region_horizontal_tightened /
--         blast_harv_damage_arithmetic_documented / blast_harv_scan_not_reopened_for_lift /
--         blast_sites_harvester_registered / blast_harvester_aims_explosion_immune /
--         blast_harvester_visible_in_status_line
--       ⚠ 其中**合成映像行为测试**最值钱：它当场抓到过两个实机上只表现为"链断了"的 bug
--         （① accessor 少解一层 `*(*(unit)+0xe8)`；② `run()` 只取 pcall 第一个返回值
--          ⇒ 成对返回的 origin 变 nil、整段静默跳过）。恢复时务必把它一起带回来。
--
-- ▍4.3 离线反查工具（本次新建，不在工程里）：
--         用 `murmur64a(name) >> 32` 把 `hashes.txt` + `thinhashes.txt` 建成
--         `32位hex → 名字` 的表（约 13.8 万条）。日志里任何 `xxxx????` 8 位 hex
--         都能一把查出名字。自检：`murmur64a("hello, world!") = 0xd18abe154a2a9637`。
