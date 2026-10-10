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
-- 竞争态熔断阈值（见 g60.priority_faults）。不写 `local Faults=require(...)`：
-- build.py 会把 require 替换成同一个 chunk 别名，同名 local 会变成 `local Faults=Faults`。
local CONTENTION_LIMIT=require('g60.priority_faults').CONTENTION_LIMIT
local Ping=require('g60.native_ping')
local Arrival=require('g60.native_arrival')
local Disposal=require('g60.native_disposal')
-- ★ 只读几何诊断（2026-09-28）。不参与决策、不写内存，仅用于把"接管/失败时
--   G-60 离虫洞多远"打进日志 —— 此前只能靠猜，已连续三次猜错。
local Geometry=require('g60.geometry')
-- 接管门控的**纯函数**判定（见 g60.take_gate 文件头：为什么必须抽出来）
local TakeGate=require('g60.take_gate')
local ArrivalPolicy=require('g60.arrival_policy')
local TargetData=require('g60.native_target_data')
local TargetContext=require('g60.titan_context')
local U=require('g60.util')
-- ★★★ 永远不要再在本模块引入**进程内计时器**（2026-10-02 实机崩溃事故）★★★
--
-- 事实：为了量"每帧耗时微秒"，这里曾用 `ffi.cdef` 声明并调用
--   `QueryPerformanceFrequency/Counter`。结果是**游戏加载后立刻崩溃**，
--   两次转储签名完全一致：`ACCESS_VIOLATION @ lua51.dll+0x4a050`（Lua VM 内核）。
--
-- 原因：**`ffi.cdef` 写的是整个 Lua 状态共享的全局 C 命名空间**。
--   Bingus 加载器把所有 mod 合进同一批 `patch_N` —— 谁都能看见谁声明过什么。
--   本机 mod 目录里已有**多个** mod 用**互不兼容**的签名声明同一批符号
--   （`QueryPerformanceFrequency(int64_t *)` 与 `(void *)` 并存）。
--   我们再声明一次 ⇒ cdef 报错（被 pcall 吞掉、日志里毫无痕迹），
--   但 C 类型表已被写坏 ⇒ **别的 mod** 之后调用它时解引用垃圾指针。
--   硬件访问违例**无法被 pcall 捕获**、mod 侧一行日志都不会有。
--
-- ⇒ 本模块**只用 env.read**（由 entry 的 ffi 提供）读游戏内存，自己不碰 ffi。
--   ⚠ 注意：entry 自身那段 `ffi.cdef`（`ReadProcessMemory` / `GetCurrentProcess` 等，
--     读内存所必需）是**既有且必需**的 —— 本禁区指的是"**再往那个共享命名空间里
--     塞新符号**"，**不是**"addon 一律禁用 cdef"。
--   想要"卡不卡"的数字：看第三方旁观者 `mod_lag_finder.log`
--   （≥50 ms 的帧会**按 mod 拆分**，比自插桩更客观、且零风险）。
--   守门：`tests/test_runtime_perf.py` 的 `runtime_never_cdefs` /
--         `runtime_no_ffi_load`（按**去注释后的代码**判，注释里提到这些词不算违规）。
local M={}
function M.new(env)
    local read,base=assert(env.read),assert(env.base)
    if env.designed_targets_only then
        env.target_allowed=Allowlist.new(env.titan_profile,env.weakpoint_profiles)
    end
    local tracked,serial,frame={},0,0
    -- ★★ 性能统计 + 空闲降频统一收进**一个 table**（2026-09-30 修实机编译失败）★★
    --
    -- 背景：**Lua 5.1 每个函数的 upvalue 上限是 60**（`LUAI_MAXUPVAL`），
    --   而 `host:tick` 里那个 `pcall(function() ... end)` 已经吃满。
    --   我此前为诊断/降频按需新增的 **10 个独立 local** 把它顶到 61
    --   ⇒ **整个 chunk 在游戏里编译失败** ⇒ addon 一行日志都不打
    --   （表现就是"mod 没生效"：文件已正确部署、游戏日志却毫无记录）。
    -- ⚠ 本地 `lupa` 跑的是 Lua 5.5（upvalue 上限 255）⇒ 测试全绿、实机全挂，白查一轮。
    -- 收成一个 local 后，它对 upvalue 的贡献从 10 降到 1。
    -- 守门：`tests/check_lua51_compile.py`（用游戏自带 lua51.dll 做**真实编译**）。
    --   · ready_*     —— readiness 每帧缓存（见 jobs_ready）
    --   · idle_skip   —— 当前观测周期：**1**=每帧（否决重申）·2=有事可做（`scan_every_busy`）
    --                   ·6=纯空转（`scan_every_idle`）；见 tick 开头的两档节流
    --   · observe/lreads/lbytes/wframe/window/wframes —— perf 窗口统计
    --   ⚠ 时间量（微秒）**不在**这里，也不在本模块任何地方 —— 见下方
    --     "永远不要再引入进程内计时器"的说明。
    local P={ready_frame=-1,ready_value=nil,ready_reads=0,
        idle_skip=0,observe=0,lreads=0,lbytes=0,wframe=0,window=600,wframes=0,
        -- ★ 空白标记诊断去重表（2026-10-01）。**放进 P 而不是新开 local** ——
        --   `host:tick` 的匿名函数 upvalue 已吃满 60（Lua 5.1 上限），
        --   新开一个 local 就可能让整个 chunk 编译失败（"mod 没生效"）。
        pmark={},pmark_n=0,
        -- ★ 2026-10-09：本帧走的**点目标路线**（'ping' / 'blast' / nil）+
        --   ping 路强制提升的去重表。**放进 P 而不是新开 local** ——
        --   同上面 pmark 的理由：闭包 upvalue 已接近 Lua 5.1 的 60 上限，
        --   新开 local 可能让整个 chunk 编译失败（"mod 没生效"）。
        flk={},
        -- ★ 点目标（ping 地面）的"新鲜度"状态：`token` = 当前标记，`frame` = 它出现的帧。
        --   同一个 token 只在 TTL 内作数（见 point_target_ttl_frames）。
        --   `seen` = 上一帧是否看到该标记（用于"消失后又出现 ⇒ 重新计时"）
        pt={token=nil,frame=-1000000000,seen=false},
        -- ★ 点目标"每 60 帧报一次距离"的节流表（见 point_guide 诊断）
        pg={},
        -- ★ 体内爆点的"每目标报一次"去重表（2026-10-03，见 compat/blast_sites.lua）。
        --   同样放进 P 而不是新开 local（upvalue 上限 60）。
        blast={},
        -- ★ 体内爆点标定用（2026-10-03）：site=该 G-60 是体内爆点目标；
        --   orig=目标原点；hit=这颗手雷**最后一次已知位置**（每帧免费从 scope 里取，
        --   因为 `scope.prepared.own_position_bytes` 本来就被读过了）；
        --   hl=hit 日志去重。**全部放进 P**（不新增 local/upvalue）。
        --
        --   ★ 2026-10-03 追加两个 **P 内**状态：
        --     · `pex` = "已判过'手雷已爆'"的去重表。少了它，同一颗手雷会**每帧**
        --       重跑一次 `arrival:triggered`（pcall + Explosive.capture）并**每帧**
        --       重复打同一条日志 —— 实机抓到一起 45 行 `priority_precheck_exploded;entity=1566`。
        --       （根因：`retired` 的键 `identity_bytes..flight_start` 每帧都变 ⇒
        --         上面那行 `retired[m.id]=nil` 把它清掉 ⇒ 外层 `not retired[m.id]` 门又开了。）
        --     · `swk`/`swn` = 体内爆点的**标定档位**计数器（见 compat/blast_sites.lua）。
        --       必须**按手雷**推进、不能按帧推进，否则同一颗手雷飞行途中会一直换目标点。
        --       同样因为 upvalue 上限 60 而放进 P（不新增 local）。
        site={},orig={},hit={},hl={},
        pex={},swk={},swn=0,
        -- ★ 2026-10-05：`pbt` = "ping 点压过引擎自选泰坦"这条日志的按手雷去重表。
        --   不加去重会**逐帧**刷屏（条件一旦成立就一直成立，直到点打掉或 TTL 过期）。
        pbt={},
        -- ★★ 2026-10-07 转阶段探针（用户要求）★★
        --   `sel` = 按手雷记上一次的「选择元组」五个字段拼串，用于**只在变化时**打一条；
        --   `seln` = 已打行数（上限 4000，防一次长任务把日志灌爆）。
        --   为什么放 P：upvalue 上限 60，本文件的计数器一律进 P（见上面的说明）。
        sel={},seln=0,
        -- ★★ 2026-10-09 自机探针（只读，为"G-60 爆炸安全区"打底）★★
        --   目的只有一个：确认**"我自己"是谁、坐标怎么拿**，为"玩家在 6m 内不引爆"铺路。
        --   来源（交叉验证过 Aggro Counter v1.5）：
        --     · `0x3326d20` 是 avatar/actor 表；我们 native_ping 已在里面用
        --       `local_ownership_observed` 挑出"本地拥有的那个" ⇒ **那就是玩家自己**。
        --     · 坐标复用既有 `d.position(e)`（motion 0x3326508 → +0x2e0），
        --       **不再新增任何读能力**（不调 world_position、不写内存）。
        --   ⚠ 全部放进 P：tick 闭包 upvalue 已近 Lua 5.1 的 60 上限。
        selfprobe={done=false,n=0,last='',failed_logged=false},
        -- ★ 2026-10-10 安全区：`safehold[id]` = 该手雷最近一次因安全区而**拒爆**的帧。
        --   用于**压制 stalled**（不炸会被判成"卡住" ⇒ 转 search ⇒ 清锁、乱飘）。
        safehold={},
        -- ★ 2026-10-10：安全区"因读不到玩家坐标而放行"的按手雷去重表。
        --   为什么必须有：fail-open 一旦静默，三条路径全不拦时**日志里什么都看不到**
        --   （实机踩过：blast_hold 从 1062 变 0，完全不知道为什么）。
        safe_nopos={},
        -- ★ 2026-10-10：引擎引爆探针的按手雷去重表（判"绕行方案是否可行"用）
        explprobe={},
        -- ★★ 2026-10-10 安全区第二步：**主动绕行**（让手雷到不了目标）★★
        --   为什么"不引爆"不够：这道门只拦得住**我们自己**的 `calls.explode`；
        --   引擎在撞击/引信那一刻点的火**拦不住**。实机证据（2026-10-10 那一局）：
        --     `blast_hold;entity=520;player_dist=10.76;radius=12;frame=10610`
        --   同一帧附近就是 `arrival_skipped;…explosion already requested`
        --   —— 玩家还在圈内，引擎自己把雷点了（我们一条 arrival_detonated 都没有）。
        --   唯一杠杆 = 玩家在圈内时**别让它接近目标** ⇒ 把 goal 换成绕目标旋转的点。
        --     · `dg`       = 该手雷"绕行生效"的节流表（值 = 上次打日志的帧）；
        --                    同时充当"本帧在绕行"的判据（guide 诊断用它选标签）。
        --     · `dg_nopos` = 拿不到圆心 ⇒ 退回"只拦我们自己"（**必须可见** ——
        --                    静默降级 = 诊断不存在，本项目已栽过 blast_hold 从 1062 变 0）。
        --     · `tpos`     = 该手雷当前目标的圆心坐标。`P.orig` 只覆盖**体内爆点**，
        --                    普通虫洞/结构锁拿不到 ⇒ 单独一张表。
        --   ⚠ 一律进 P：tick 闭包 upvalue 已近 Lua 5.1 的 60 上限（见上面 pmark 的说明）。
        dg={},dg_nopos={},tpos={},
        -- ★★ 2026-10-10 安全区要管"**引擎自己瞄的雷**"（用户报「没标记时不生效」）★★
        --   这类雷我们**不接管**（不建 tracked、不设 lock/titan），所以状态只能挂这里：
        --     · `ehp` = 该手雷"已打过一条 `safe_engine;`"的去重表
        --     · `ehq` = {bytes=我们写下去的 12 字节, frame=写的帧, fp=飞行指纹}
        --              ⇒ 每帧**不付 capture** 就能判"我们的点还在不在记录里"
        --     · `ehk` = 已确认"点存活 ≥30 帧"（= 我们真的从引擎手里抢到过选择权）
        --     · `ehx` = 该手雷"已打过一条 `safe_engine_exploded;`"的去重表
        --     · `ehc` = 该手雷"贴脸取消"的证据/失败去重表（成功失败都只打一次）
        --   ⚠ 一律进 P：tick 闭包 upvalue 已近 Lua 5.1 的 60 上限（见上面 pmark 的说明）。
        ehp={},ehq={},ehk={},ehx={},ehc={},
        -- ★★ 2026-10-10 「玩家在圈内却**没有执行者**」的计数与告警去重（用户要求加冗余）★★
        --   为什么必须有：这一类的洞在旧日志里**一个字都没有** —— 门打了 `blast_hold`
        --   （玩家确实在圈内），然后没有任何人压这颗雷，它就一路飞到引信范围内被点火。
        --   实机 7 例（540/568/624/793/819…）全是这样，而我上一轮**判读不出来**，
        --   只能看到"最后一条 blast_hold 的距离是 11.87 m"。
        --   ⇒ 值 = 连续"门判在圈内但无执行者"的帧数；`noexec_warn` = 已报过（每颗一次）。
        noexec={},noexec_warn={},
        -- ★★ 2026-10-10 「清掉引擎的选择」那条冗余开关的取证去重（用户拍板做成开关）★★
        --   · `evv` = 已打过 `safe_veto;`（实体式选择，真的调了 run_veto）—— 同时充当
        --     "本帧不是第一次"的判据：第一次之后 `run_veto` 传 quiet=true（防刷屏）。
        --   · `evp` = 已打过 `safe_veto_skip;`（**跳过**：有标记 / 点式选择无 resource
        --     可判）—— 两类共用一张表（同一颗雷只报一次原因，先到的原因算数）。
        --   两张表分开 ⇒ "开关帮上了哪一类 / 为什么没帮上"在日志里能直接数出来。
        evv={},evp={},
        -- ★★ 2026-10-10 "谁写了谁负责"：本帧安全区给哪条雷写过点（值 = 帧号）★★
        --   用途：点目标驱动那条路**这一帧让位**，避免它拿"写之前"的观测去调原生
        --   （实机 entity=508 撞出连续 4 帧 `skipped;…stale observation`）。
        --   只判 `==frame` ⇒ 不跨帧、不影响下帧正常驱动。
        szw={},
        -- ★★ 2026-10-10 玩家坐标（自己 + 队友）：每帧一次的 avatars 列表缓存 ★★
        --   见 nearest_player 的说明。`sig` 用于"变化才打日志"，失败时置 false。
        av={},
        -- ★★ 2026-10-10 阵营判据的按标记缓存（用户要求"通过阵营判断"）★★
        --   值：'yes'（引擎说可当目标）/ 'no'（友方·中性 ⇒ 本帧当它不存在）/ 'err'（查不到，
        --   保守当有效）。为什么必须有缓存：`target_valid` 是一次原生查询，而标记可能
        --   存活很久（实体活着就一直存活）⇒ 同一个标记只该问一次。
        fk={},
        -- ★★ 2026-10-10 「友方锁定」证据行的去重表（键 'v:<手雷id>:<选择id>'）★★
        --   引擎会**反复**把选择抢回那个友方（每帧清、每帧又被锁），逐帧 emit 会把日志埋掉。
        fkl={},
        -- ★★ 2026-10-10 取消请求的时刻（`safe_cancel_stale;` 判"移除兑现了没"要用）★★
        --   值 = 取消成功那一帧；实体若还活着 ≥120 帧 ⇒ 判定移除没兑现并打一条证据行。
        ehf={}}
    local frame_errors={}
    local structure_issue_counts={}
    local last_structure_issue
    -- ★ 竞争态熔断（配合 native_priority 的故障域隔离，见 g60.priority_faults）
    -- 单颗 G-60 的一次 setter 竞争不该杀死整局；但如果同一帧里**多颗** G-60 全部
    -- 竞争态失败，说明是我们对引擎状态的理解出了问题（而不是单点时序），
    -- 这时停手才是对的。
    local contention_frame,contention_count=-1,0
    local function note_contention()
        if contention_frame~=frame then contention_frame,contention_count=frame,0 end
        contention_count=contention_count+1
        return contention_count>=CONTENTION_LIMIT
    end
    local reservations=env.exclusive_targets and Reservations.new()
    assert(not reservations or (env.priority_catalog and env.fuse_profile),'exclusive allocation requires priority and search cleanup')
    local current,runner
    -- ★★ 2026-10-10 爆炸安全区：统一门函数（**两条引爆路径都必须过这道门**）★★
    --
    --   实机教训（用户报「安全区只对空 ping 生效」）：我第一版只拦了
    --   `arrival:step` 那条路（ping 空地点），而**虫洞 / 泰坦 / 单位**走的是
    --   `titan:step` 另一条路（它内部也调 `Policy.step` ⇒ 同样会 `calls.explode`）
    --   ⇒ 只有 ping 被拦住。**两条路必须共用同一道门**。
    --   返回 true = 允许引爆；false = 玩家在安全区内 ⇒ 本帧不授权引爆。
    --   ⚠ 只读：只读坐标，不写内存。⚠ fail-open：拿不到坐标就放行（宁可照常炸）。
    --   ★★ 2026-10-10：把"判定"与"坐标从哪来"**拆开**（用户报「没标记时不生效」）★★
    --   非自有 G-60（引擎自己瞄敌人）没有 `scope`（我们从不 capture 它）⇒ 必须有
    --   第二条坐标来源。为了不出现"同一个判断写两遍"（本项目的老毛病），
    --   **判定只保留这一份**：
    --     `blast_safe_hold_at(ident,own)` = 读开关 + 玩家坐标 + 比距离 + 打日志/记 safehold
    --   两个包装只负责取"这颗雷在哪"：
    --     ① `blast_safe_hold(m,scope)` —— 已接管路径（坐标免费：scope 里本来就读过）
    --     ② `blast_safe_hold_td(m)`    —— 非自有路径（TargetData 单读，**不做 capture**）
    -- ★★ 队友也算"玩家"（2026-10-10 用户报「安全区貌似对队友不生效」）★★
    --   现状：`by_owner` 只给**本地玩家自己**（ping 环里"本地所有权"的那一条）⇒
    --     玩家离得远、队友站在雷边上时，安全区判"不在圈内" ⇒ 照常引爆 ⇒ 队友挨炸。
    --   ⚠ 工程史警告：2026-09-28 那个"4m 潜兵安全区"**被整体删除**，理由是
    --     「枚举实体表始终没能稳定工作（两次静默失败）」⇒ **绝不能再枚举实体表**。
    --   ⇒ 用**定点读**：游戏自己的 avatars 列表（同工程 aggro_counter 实机跑过的读法，
    --     其 BUILD 与本工程同一份 game.dll dump —— owner/id_map/entities 三个偏移
    --     与本工程 `d.root` 完全一致，可交叉验证）：
    --       base+0x3326d20 → count@+0x6c，实体**指针**数组@+0x110+i*8
    --       base+0x3326468 → local_net@+0x3a8（区分自己/队友，本处暂不用）
    --   ⚠ **每帧只读一次**并缓存：gate 是**逐颗雷逐帧**调用的（实机一局 1863 次
    --     `blast_hold`），逐次读 avatars 会把 layout_reads 打爆。
    --   ⚠ **失败即退回现状**（只用自己）—— 这是"未验证假设不改变行为"的保险：
    --     读不到就与改动前逐字节一致，并打一条 `safe_players;n=0;reason=…` 让失败可见。
    -- ⚠⚠ 这个 helper **必须定义在下面所有使用者之前**（词法作用域，与缩进无关）：
    --   2026-10-10 实机事故 —— 它原来在第 683 行，而 players_scan（第 242 行）就用它
    --   ⇒ 取到全局 `pointer` = nil ⇒
    --     `safe_players;n=0;reason=…:7297: attempt to call global 'pointer' (a nil value)`
    --   ⇒ 队友安全区**整段静默失效**（fail-safe 兜住了行为，但功能是死的）。
    --   与 `faction` 那次崩溃同类 ⇒ 新增 tests/check_local_order.py 做通用检查。
    local function pointer(a) return Layout.pointer(read(a,8),0) end
    -- ★ 读 avatars 列表（**每帧一次**，缓存见 nearest_player）。见上面那段说明。
    --   返回 (list, ids, why)：list = {{id=,pos=},…}；ids = 逗号串（用于变化去重）；
    --   why = 失败原因（读不到时必须能说出来 —— 静默降级 = 诊断不存在）。
    local function players_scan()
        local ok,list,ids,why=pcall(function()
            local am=pointer(base+0x3326d20)
            -- ★ 两个候选计数都读出来并**打进日志**（本工程自己的 native_search_context
            --   用的是 +0x70「actor 数」（≤16），同工程 aggro_counter 用的是 +0x6c
            --   「avatars 数」（≤8，玩家专用））。本处按玩家语义取 +0x6c，并把两个原始值
            --   一起报出来 ⇒ 第一局日志就能判定哪个字段才是玩家数（不靠猜）。
            local n6=Layout.u32(read(am+0x6c,4),0)
            local n7=Layout.u32(read(am+0x70,4),0)
            local raw='c6c='..tostring(n6)..',c70='..tostring(n7)
            if not (n6>=1 and n6<=8) then return nil,nil,raw end
            local d=TargetData.new(read,base,env.exe)
            local out,txt={},''
            for i=0,n6-1 do
                local ea=pointer(am+0x110+i*8)
                local id=Layout.u32(read(ea+8,4),0)
                if id~=0 then
                    local e=d.entity(id)
                    local p=e and d.position(e)
                    if p then
                        out[#out+1]={id=id,pos=p}
                        txt=txt..(txt~='' and ',' or '')..tostring(id)
                    end
                end
            end
            if #out==0 then return nil,nil,raw..',no-positions' end
            return out,txt..';'..raw
        end)
        if not ok then return nil,nil,tostring(list) end
        return list,ids,why
    end
    -- ★★ 玩家坐标两源：① 自己（`by_owner`，已验证）② avatars 列表（含队友）★★
    --   返回"**最近的**玩家坐标"与它到雷的**平方**距离；安全区判定与贴脸取消共用它
    --   （口径只有一个 —— 本项目吃过"同一判断写两遍"的亏）。
    --   ⚠ avatars 列表**每帧只读一次**并缓存（gate 逐颗雷逐帧调用）。
    local function nearest_player(own,mysp)
        local best,bd=mysp,nil
        if mysp then
            local dx,dy,dz=own[1]-mysp[1],own[2]-mysp[2],own[3]-mysp[3]
            bd=dx*dx+dy*dy+dz*dz
        end
        if P.av.frame~=frame then
            P.av.frame=frame
            local list,ids,why=players_scan()
            P.av.list=list
            if list then
                if P.av.sig~=ids then
                    P.av.sig=ids
                    env.emit('safe_players;n='..#list..';ids='..tostring(ids)..';frame='..frame)
                end
            elseif P.av.sig~=false then
                P.av.sig=false
                env.emit('safe_players;n=0;reason='..tostring(why)..';frame='..frame)
            end
        end
        if P.av.list then
            for _,p in ipairs(P.av.list) do
                local dx,dy,dz=own[1]-p.pos[1],own[2]-p.pos[2],own[3]-p.pos[3]
                local q=dx*dx+dy*dy+dz*dz
                if bd==nil or q<bd then bd=q;best=p.pos end
            end
        end
        return best,bd
    end
    local function blast_safe_hold_at(ident,own)
        local safe=tonumber(env.blast_safe_radius) or 0
        if safe<=0 then return true end
        -- ⚠ 走 `host.structure_ping`（由 M.new 末尾暴露）而**不是**本模块的
        --   `structure_ping` 局部 —— 后者在本函数**定义时**尚未构造（L321 在 L160 之后）
        --   ⇒ 直接引用会 `attempt to index global 'structure_ping' (a nil value)`。
        --   这是"三条路径全不拦"的真凶（实机 blast_safe_nopos 直接点名）。
        local okp,selfres=pcall(function()
            return host.structure_ping and host.structure_ping:self()
        end)
        local me=okp and selfres and selfres.by_owner
        local mysp=me and me.position
        -- ★★ fail-open 必须**可见**（2026-10-10 实机教训）★★
        --   拿不到坐标就放行是**对的**（宁可照常炸，也不让雷静默失效），
        --   但它**静默** ⇒ 三条路径全不拦时，日志里一条都看不到
        --   （实机：blast_hold 从 1062 变 0，却完全不知道为什么）。
        --   ⇒ 每颗手雷只打一次"我因为读不到玩家坐标而放行了"。
        if not mysp then
            local key='npos:'..tostring(ident)
            if not P.safe_nopos[key] then
                P.safe_nopos[key]=true
                env.emit('blast_safe_nopos;entity='..tostring(ident)
                    ..';okp='..tostring(okp)
                    ..';self='..tostring(selfres and 'table' or selfres)
                    ..';by_owner='..tostring(selfres and (selfres.by_owner and 'yes' or 'no') or '-')
                    ..';detail='..tostring(not okp and selfres or ''):sub(1,120)
                    ..';frame='..frame)
            end
            return true
        end
        -- ★★ 拿不到"**这颗雷**在哪"也必须可见（2026-10-10 补）★★
        --   原来这里是静默 `return true` —— 与 blast_safe_nopos 同族的坑：
        --   安全区整段不生效，日志里却一个字都看不到（诊断被节流掉 = 诊断不存在）。
        if not own then
            local key='noown:'..tostring(ident)
            if not P.safe_nopos[key] then
                P.safe_nopos[key]=true
                env.emit('blast_safe_noown;entity='..tostring(ident)..';frame='..frame)
            end
            return true
        end
        -- ★★ 判据改成"**最近的玩家**"（2026-10-10 用户报「安全区对队友不生效」）★★
        --   原来只比自己的坐标 ⇒ 玩家离得远、队友站在雷边上时判"不在圈内" ⇒ 照常引爆。
        --   现在 `nearest_player` 取 min(自己, avatars 列表里的每个玩家) ——
        --   **读不到 avatars 就退回只有自己**（与改动前逐字节一致），且失败会打
        --   `safe_players;n=0;reason=…` 让它可见。
        local best,d2=nearest_player(own,mysp)
        if d2==nil then return true end          -- 一个玩家都读不到 ⇒ fail-open（同改动前）
        if d2>safe*safe then return true end
        P.safehold[ident]=frame
        env.emit('blast_hold;entity='..tostring(ident)
            ..';player_dist='..string.format('%.2f',math.sqrt(d2))
            ..';radius='..safe
            ..';players='..tostring(P.av.list and #P.av.list or 0)
            ..';frame='..frame)
        -- ★ 把**最近那个玩家**的坐标交出去（贴脸取消要算"目标离那个玩家多远"）——
        --   原来交的是自己；队友才是最近者时，交队友才对得上"谁有危险"。
        -- ★★ 第三个返回值 = **玩家↔手雷**的距离（2026-10-10 用户纠正：「安全区是以
        --   手雷为中心，不是以玩家为中心」）★★
        --   这正是本函数的判据本身（`d2` 就是 |手雷−玩家|²）⇒ 直接交出去，
        --   让贴脸取消用**同一个口径**，而不是再去算"玩家离目标多远"（那是以目标为中心）。
        return false,best,math.sqrt(d2)
    end
    local function blast_safe_hold(m,scope)
        -- ⚠ `m` 可能是 G-60 的 match（含 .id），也可能来自 priority 的 `c`（identity 记录）。
        local ident=m and (m.id or (m.entity and m.entity.id)) or '?'
        local okv,v=pcall(TargetData.vector,scope.prepared.own_position_bytes,0)
        return blast_safe_hold_at(ident,okv and v or nil)
    end
    -- ★ 非自有 G-60 的坐标来源：TargetData 单读（两次哈希查找 + 12 字节）。
    --   ⚠ 这里**不做 `Search.capture`** —— 那套是 ≤65536 B/2048 次调用的量级，
    --     不能对每颗"引擎自己瞄的雷"每帧付一次（perf 门盯着 layout_reads）。
    --     只有玩家真在圈内、要写绕行点时才会付 capture（见 run_safe_hold）。
    local function blast_safe_hold_td(m)
        local ident=m and m.id or '?'
        local okv,v=pcall(function()
            local d=TargetData.new(read,base,env.exe)
            local e=d.entity(ident)
            return e and d.position(e)
        end)
        return blast_safe_hold_at(ident,okv and v or nil)
    end
    -- ★ 把门**注入 env**：`native_priority` 那条早期引爆路径要用（它拿不到本闭包）。
    --   返回 false ⇒ 玩家在安全区内 ⇒ 不引爆。
    env.blast_safe_hold=function(scope,c) return blast_safe_hold(c,scope) end
    local arrival=env.fuse_profile and Arrival.new(env)
    env.arrival=arrival
    local disposal=env.fuse_profile and Disposal.new(env)
    -- ★★ 2026-10-10 贴脸取消用**独立实例**（用户拍板，默认关）★★
    --   为什么不能共用上面那个：`native_disposal` 在"已发出移除请求但回读不符"时会把
    --   自己 `disabled=true`（fail-closed），而 runtime 的**寿命回收**那条路一旦读到
    --   disabled 就 `error('disposal operation disabled')` ⇒ **整局 mod 停手**。
    --   贴脸取消写的是"**非自有、且未到期**"的手雷，风险面比寿命回收大 ⇒ 必须隔离：
    --   它失败只关掉"取消"这一个功能，不连累正常回收。
    local disposal_cancel=env.fuse_profile and Disposal.new(env)
    local retired={}
    -- ★ 结束持有（2026-09-27 实机事故的治本点）
    -- `retired[m.id]` 只挡住了后续帧的入口，却把 tracked 里的 lock/titan **留在原地**。
    -- 虫洞被引爆/回收之后，引擎会很快复用那个 entity id；残留锁会让下一帧的
    -- priority / titan 把选择写到**另一个实体**上，写后回读必然不符 ——
    -- 实机日志第 131–132 行就是这个时序（引爆 520 之后紧跟 setter target mismatch）。
    -- 所以凡是写 retired 的地方，都必须同时把"持有"清干净。
    local function release_hold(id)
        local t=tracked[id]
        if t then t.lock=nil;t.titan=nil;t.force_search=nil;t.blocked=nil end
        -- ★ 2026-10-10：绕行状态也必须跟着持有一起清 —— 手雷 id 会被引擎复用，
        --   残留的圆心/节流表会让**下一颗**手雷的诊断与圆心张冠李戴
        --   （与上面 retired 的教训同源："只清一半 ⇒ 下一个实体被误伤"）。
        P.tpos[id]=nil;P.dg[id]=nil;P.dg_nopos[id]=nil
        P.ehp[id]=nil;P.ehq[id]=nil;P.ehk[id]=nil;P.ehx[id]=nil;P.ehc[id]=nil
    end
    local titan=env.titan_profile and Titan.new(env)
    -- ★ 本 mod 接管的目标 = 玩家标记的虫洞 + 吐酸泰坦，其余全交还引擎 ★
    --
    -- 历史（2026-09-27）：这里曾经是"裁剪 C"，把上游的三类
    -- （titan_profile / weakpoint_profiles / structure_profiles）收窄成
    -- **只认 structure_profiles**，理由是"只用 9 个虫洞"。
    -- ⇒ 泰坦 profile 虽在 compat/titan_profile.lua 里、titan_route/titan_aim
    --   全套代码都在，却因为这一行**永远进不了接管路径**。
    --
    -- 2026-09-29 用户要求接管吐酸泰坦。恢复 titan_profile 一项：
    --   · titan_route.lua 的 RADIUS=12 / standoff 是**作者为泰坦标定的**，
    --     与虫洞无关 —— 所以泰坦段有自己的几何，不需要重标。
    --   · 仍然不认 weakpoint_profiles：那里面是穿刺者/龙蟑螂等其它敌人，
    --     用户明确要求"其他交还原生"。`weakpoint_profiles.lua` 保持空表。
    --
    -- 连带影响已逐处核对（2026-09-29）：
    --   · 第 524 行 titan_selected —— 这正是我们要的入口。
    --   · 第 630 行 `if has_weakpoint(...) then target=nil end` ——
    --     泰坦成功建立航点后会在上一行 `if titan_point then return {kind='guide'}`
    --     提前返回，走不到这里 ⇒ 对泰坦是死代码，无需额外处理。
    -- ★★ 本 mod 认领的资源 → profile（**唯一判定点**）★★
    --
    -- 2026-09-29：原来 `has_weakpoint` 与 `structure_ping.allowed` **各写一份**判断，
    -- 我上一轮只改了 has_weakpoint ⇒ **标记入口仍然拒绝泰坦**，实机日志：
    --     structure_mark;target=..;resource=9e2e17f2ccccafdd;reason=RESOURCE_NOT_SUPPORTED
    -- 共 4 次（4194911 / 4195449 / 4195864 / 8388841）。
    -- ⇒ 用户报"标记吐酸泰坦接管又出问题了"就是这个 —— 标记被拒，引擎只能靠自己选中，
    --   于是时灵时不灵。**同一个判断出现两处，是我这两天反复踩的坑** ⇒ 收敛成一个函数。
    --
    -- 认领范围：9 个虫洞 + 吐酸泰坦。其余（weakpoint_profiles 里的 7 个敌人：
    -- head/rear/thorax/underside）返回 nil ⇒ 完全交还引擎。
    local function claim_profile(resource)
        if not resource then return nil end
        if env.structure_profiles and env.structure_profiles[resource] then
            return env.structure_profiles[resource]
        end
        -- 泰坦：resource 精确匹配，不做任何模糊判定。匹配不上就交还引擎
        -- （fail-open 到"原生"，不 fail 到"接管"）。
        if env.titan_enabled~=false and env.titan_profile
            and resource==env.titan_profile.resource then
            return env.titan_profile
        end
        -- ★★ 蟑龙 Dragonroach（2026-09-29）★★
        --
        -- resource=960b48a421a3faaa，weakpoint kind="thorax"，standoff=2.5。
        -- docs/TARGETS.md："胸腔气囊下方，带 blast standoff"。
        --
        -- **为什么不需要新几何**（这是查证过的，不是猜的）：
        --   · weakpoint_route 的 thorax 分支不查地面：
        --         goal={p[1],p[2],p[3]-profile.standoff}
        --     只有 Impaler 的 underside 分支才有 `transit<origin[3]+0.3` 的检查。
        --   · 上游源码里有一句注释直接说明了这一点：
        --         -- Dragonroach can be airborne; its root is not a terrain-height sample.
        --   ⇒ 爆点由"瞄准点 − standoff"得出，与地面高度无关 ⇒ 天生适配飞行单位。
        --   · titan_context 也是通用的：它的断言里写着 "weakpoint scenegraph
        --     variant mismatch" / "weakpoint aim anchor unavailable"，本来就是
        --     为 weakpoint profile 设计的。
        --
        -- 用**精确哈希**匹配，不按 kind 推断 —— 按 kind 会把 Spore Charger
        -- 等其它同 kind 敌人一起放进来，那是用户没要求的范围扩张。
        if env.dragonroach_enabled~=false and env.weakpoint_profiles
            and resource==env.dragonroach_resource then
            return env.weakpoint_profiles[resource]
        end
        -- ★★ 泰坦变体（2026-09-29）★★
        -- 变体没有自己的几何 profile，**借用基线**（同 unit 目录 ⇒ 同模型）。
        -- 目前一个：cha_strider_gloom（孢子泰坦）= ef04cb84d097a497，
        -- 与基线 cha_strider 同属 content/fac_bugs/cha_strider/。
        -- 证据与安全边界见 compat/titan_variants.lua 的文件头注释。
        if env.titan_variants_enabled~=false and env.titan_variant_profiles then
            local variant=env.titan_variant_profiles[resource]
            if variant then return variant end
        end
        return nil
    end
    local function has_weakpoint(resource) return claim_profile(resource)~=nil end
    -- ★★ 2026-10-10：目标位置（安全区**绕行圆心**用）★★
    --   为什么必须有：绕行要"绕目标"，就必须先知道目标在哪；而普通虫洞/结构锁
    --   拿不到 `P.orig`（那个只在**体内爆点**路径里写进去）。
    --   `TargetContext.capture` 是按 profile 取**几何瞄准点**（= 引擎 `aim` 用的
    --   同一个点），对虫洞实测可用 —— `structure_mark;…;reason=ACCEPTED` 的判据
    --   就是它算出来的。
    --   ⚠ 与 `structure_ping` 的 `position` 选项**逐字同源**（profile 优先、退到
    --     motion 位置）—— 不许在这里写第二套认领/回退逻辑
    --     （"同一个判断出现两处"是本项目反复踩的坑，见 has_weakpoint 处的说明）。
    --   ⚠ 只在 `held`（安全区生效）时被调用 ⇒ 不进常规每帧开销（perf 门盯着
    --     layout_reads，`TargetContext.capture` 不便宜）。
    local function target_position(e)
        local profile=claim_profile(e.resource)
        if profile then
            local pose=TargetContext.capture(read,base,env.exe,e.id,profile)
            assert(pose.validate(),'target pose changed');return pose.point
        end
        local d=TargetData.new(read,base,env.exe)
        return d.position(e)
    end
    -- ★ 方案一（2026-10-07，用户拍板）：把认领查询暴露给 native_priority ★
    --   generic（玩家标记任意目标）认领时，命中认领 profile 的目标必须用
    --   **几何爆点**而不是 motion 位置（实机取证：2026-10-07 War Strider 测试局）。
    --   ⚠ 判断只保留这一份（"同一个判断出现两处"的教训）——native_priority 通过
    --     `env.claim_profile(e.resource)` 复用，不得在模块里重写第二份认领逻辑。
    env.claim_profile=claim_profile
    -- ★★ 通用标记目标认领（2026-09-30，用户要求）★★
    --
    -- 除 虫洞 / 泰坦 / 泰坦变体（走 claim_profile 的专门路径）外，
    -- **玩家标记的任意目标**也认领 —— 强制 G-60 飞向它并引爆。
    --
    -- 三条边界（都必要）：
    --   1. `generic_takeover_enabled=false` ⇒ 整体退回"只管虫洞/泰坦/变体"
    --   2. **排除表必须仍然生效** —— 否则刚加进去的"不追踪运输船"会被这条路径
    --      反过来接管（自相矛盾）。`Filter.excluded` 与 veto 用的是同一张表。
    --   3. **友方不在这里排除** —— 靠 priority 里 `calls.target_valid` 硬门槛
    --      （引擎索敌系统的"能不能把它当锁定目标"）。放这里会让"读标记"阶段
    --      就要跑一遍索敌查询，而那时还没有受保护的 scope。
    --
    --   ★★ 2026-10-01（用户要求）：玩家**点名标记**运输船 / 光能族增援飞船时，
    --      这条路径要**认领**它（"标记了就要飞过去炸"），而不是因为它在排除表里
    --      就被 RESOURCE_NOT_SUPPORTED 挡掉。
    --      本函数**只服务 structure_ping 的 allowed 判据**（= 玩家主动标记），
    --      所以在这里放行恰好只影响"玩家点名"；take_gate / 兜底 veto 的
    --      "引擎自选 ⇒ 清掉"走的是 `Filter.excluded`，完全不受影响。
    local function generic_claimed(resource)
        if env.generic_takeover_enabled==false then return false end
        if not resource then return false end
        if Filter and Filter.excluded and Filter.excluded(resource) then
            -- 排除表里的载具：只有"玩家点名允许接管"的才放行（见 small_filter.marked_allowed，
            -- 当前就是表里那两项：机器人运输船 / 光能族增援飞船）。
            return Filter.marked_allowed ~= nil and Filter.marked_allowed(resource) == true
        end
        return true
    end
    local ping=env.priority_catalog and env.mark_priority_enabled~=false and Ping.new(env)
    local structure_ping=env.structure_profiles and Ping.new(env,{
        diagnostic=function(detail) env.emit('structure_mark;'..detail) end,
        -- ★ 认领判定（收敛到唯一入口）★
        --   claim_profile  = 虫洞 / 泰坦 / 蟑龙 / 泰坦变体（各有专门几何）
        --   generic_claimed = 玩家标记的任意其它目标（2026-09-30 新增）
        --   ⇒ 两者都不认 ⇒ RESOURCE_NOT_SUPPORTED（交还引擎原生）
        allowed=function(resource)
            return claim_profile(resource)~=nil or generic_claimed(resource)
        end,
        -- ★★ 队列内部的**优先级**（2026-10-02，用户：「标记敌人单位时，泰坦的优先级不是最高的」）★★
        --
        --   队列默认按**新旧**排（队首 = 最晚 ping 的那个）⇒ 先标泰坦、后标一只小怪时，
        --   小怪会盖住泰坦。名册里的 rank（泰坦/蟑龙 = 10 最高）**只在自动索敌路径用过**，
        --   而那条路径本工程早已裁掉 ⇒ 标记路径上根本没有"重量级"概念。
        --   ⇒ 用 `options.priority` 给队内次序（**数值小的先**），分五段：
        --     ① 虫洞 / 构筑            → **0**      （用户定的最高档；不能被下面的 rank 顶掉）
        --     ② 蟑龙（Dragonroach）     → **500**    （2026-10-03 用户指定：排在虫洞之后、泰坦之前）
        --     ③ 泰坦（含变体）          → **1000**   （任何泰坦都排在任何"其它"单位之前）
        --     ④ 名册里的其它敌人        → 1000+rank（冲锋者 50 ⇒ 1050；rank 越小越优先）
        --     ⑤ 名册外的其它单位        → 1500      （排在有名册的敌人之后；彼此仍按"最新"）
        --   ⚠ 相等优先级**保持原顺序**（= "最新 ping 优先"），见 native_ping 的说明。
        --   ⚠ 空白标记**不在这条队列里**（走 `ping` / `point_marker`）⇒ 完全不受影响。
        --   ⚠ `marked_unit_rank_first=false` ⇒ 不传该选项 ⇒ 回到"最新 ping 优先"（一键回退）。
        --
        --   ★★ ② 蟑龙的识别：**复用准入路径的同一判据**（精确哈希 + 开关）★★
        --     `env.dragonroach_enabled` + `env.dragonroach_resource`（entry 里的常量
        --     `960b48a421a3faaa`）—— 与上面 `claim_profile` 的蟑龙分支**逐字同源**。
        --   ⚠ **不按 `kind=='thorax'` 推断**：那是本工程明令禁止的做法
        --     （测试 `no_kind_based_admission` 钉着）—— 按 kind 会把同 kind 的
        --     其它敌人一起算进来，属未经要求的范围扩张。
        --     「能瞄准谁」与「谁优先」用同一把尺子 ⇒ 不会出现"优先了却瞄不了"的错配。
        priority=(env.marked_unit_rank_first~=false) and function(mark)
            local r=mark.resource
            if not r then return 2000 end
            if env.structure_profiles and env.structure_profiles[r]~=nil then return 0 end
            if env.dragonroach_enabled~=false and env.dragonroach_resource
                and r==env.dragonroach_resource then
                return 500
            end
            if env.titan_profile and env.titan_profile.resource==r then return 1000 end
            if env.titan_variant_profiles and env.titan_variant_profiles[r]~=nil then return 1000 end
            local spec=env.priority_catalog and env.priority_catalog[r]
            if spec and spec.rank then return 1000+spec.rank end
            return 1500
        end or nil,
        position=function(e)
            local profile=claim_profile(e.resource)
            if profile then
                local pose=TargetContext.capture(read,base,env.exe,e.id,profile)
                assert(pose.validate(),'structure Ping pose changed');return pose.point
            end
            -- ★ 通用目标：没有几何 profile ⇒ 用实体的 motion 位置（d.position）。
            --   这是**唯一**可用的通用位置来源（`titan_context.capture` 强依赖
            --   profile 的 resource/getters/nodes，对任意目标直接断言失败）。
            --   读不到就让它抛 —— 上层 pcall 会记 POSE_READ_FAILED，标记被判无效。
            --   **不假装成功**：位置不明的目标不该被接管。
            local d=TargetData.new(read,base,env.exe)
            return d.position(e)
        end,
        -- ★★ "空白标记"探查（2026-10-01，**只读**）★★
        --   用户问：「无目标的空白标记是否也能接管？」—— 先回答客观问题：
        --   **ping 到空地时，那个 88 字节的槽里到底有没有世界坐标**。
        --   只在读不到实体（NO_ENTITY_MARK）时 dump，每槽一次（见 native_ping.dump_slot）。
        slot_dump=env.ping_slot_dump,
        slot_dump_diagnostic=function(detail) env.emit('ping_slot;'..detail) end,
        -- ★★ 记忆存续判据（2026-10-01，用户实机反馈）★★
        --   用户原话：「标记过的单位，即使取消标记，G60 仍会追踪该单位」。
        --
        --   根因：ping_memory 的设计是"UI 过期不代表意图过期"（history 只要实体
        --   还有效就留着）⇒ 玩家 ping 一个单位、标记从画面上消失之后，记忆里那条
        --   还在 ⇒ 之后每一颗 G-60 都会照它去追那个单位，看起来就是"取消不掉"。
        --
        --   这条判据决定**哪些标记可以脱离 UI 存活**（`live` = 本帧 ping 环里
        --   还看得到它，即 UI 的 8 秒窗口内）：
        --     · 结构 / 泰坦 / 蟑龙 / 泰坦变体 ⇒ 照旧长期记忆
        --       （"ping 一次虫洞、过一会儿才扔"是常规操作，不能要求重 ping）
        --     · 通用单位标记 ⇒ 默认只认活标记（env.unit_mark_live_only 可关掉，
        --       关掉即回到旧行为：记忆里的旧单位标记继续被新 G-60 接管）
        --   ⚠ 已在飞向该单位的那颗**不受影响**：它持有 old.lock，下一帧走
        --     native_priority 的 sticky 复核（按实体 id 重读），不依赖这条记忆。
        remembered_intent=function(mark,live)
            if live then return true end
            -- ★★ 2026-10-02（用户要求"取消标记后不要再用它"）★★
            --   用户原话：「标记虫洞再取消标记丢出手雷，手雷还是会向虫洞飞过去爆炸」。
            --
            --   原来这里对**结构 / 泰坦 / 变体**一律 `return true`（脱离 UI 长期存活）——
            --   当时的理由是"ping 一次虫洞、过一会儿才扔是常规操作"。但同一个机制让
            --   **玩家取消标记之后**它依然生效（记忆里那条还在）⇒ 看起来就是"取消不掉"。
            --   ⇒ 现在同样按"活标记"判（`live` = 本帧 ping 环里还看得到它）：
            --     开关 `env.structure_mark_live_only`（默认 **true** = 只认活标记）。
            --     置 false ⇒ 回到旧的"长期记忆"行为。
            --
            --   ⚠ 权衡（知情）：ping 之后**超过标记存活时长**（UI 约 8 秒）才扔，
            --     结构标记已过期 ⇒ 不再接管。要保留"慢慢扔"的习惯就把该开关置 false。
            --   ⚠ **已在飞向它的那颗不受影响**：它持有 `old.lock`，下一帧走
            --     native_priority 的 sticky 复核（按实体 id 重读），不依赖这条记忆
            --     ⇒ 不会"半路停手"。
            if claim_profile(mark.resource) then
                return env.structure_mark_live_only==false
            end
            return env.unit_mark_live_only==false
        end})
    if ping or structure_ping then env.forget_mark=function(identity)
        if ping then ping:forget(identity) end
        if structure_ping then structure_ping:forget(identity) end
    end end
    local priority=env.priority_catalog and Priority.new(env)
    local world,last_time,last_ping_issue,last_ping_queue,last_link_status
    -- G-60 的 state 停留追踪（见下面的链路诊断）
    local state_key,state_age,saw_state4={},{},false
    local state3_blocked=false
    local state3_driven={}          -- 被 state-3 路径设过目标的 G-60
    -- 自毁保护要**连续**几次危险信号才退回：单次抖动（例如刚好撞上引擎自己的
    -- 状态切换）不该把这条实验路径永久关掉。
    local STATE3_DANGER_LIMIT=3
    local state3_danger=0
    -- priority_skipped 的去重集合（同一 G-60 + 同一 reason 只打首条）
    local skipped_probe={}
    -- 观测失败计数（见下面 with_observation 调用处的 ★ 注释）
    local OBSERVE_FAIL_LIMIT=8
    local observe_fail={}
    -- ★ 引导失败计数（2026-09-29）：与 OBSERVE_FAIL_LIMIT 同一思路，但管的是
    -- **引导本身反复失败**（titan:step / runner:step 返回 nil），而不是观测拿不到窗口。
    -- 实机 entity=1257 的 titan:step 持续抛 `Titan selection changed`，失败后
    -- old.titan 保留 ⇒ 下一帧再试 ⇒ 无限循环 ⇒ G-60 挂在泰坦底下不动直到寿命耗尽。
    -- 阈值取 30 帧（约 0.5 秒）：足够容忍偶发竞争，又能及时收手。
    -- 只放弃该实体，不做全局禁用（2026-09-28 的教训）。
    local GUIDE_FAIL_LIMIT=30
    local guide_fail={}
    -- selection_resource 缺失只提示一次（它可能连续很多帧发生）
    local selection_resource_warned=false
    -- 只读诊断去重：按**资源**去重（不是按实体）⇒ 条数受场上敌人种类数约束。
    --   用途：确认"运输船"这个哈希在实机里真的作为 G-60 的引擎选择出现过。
    local veto_seen={}
    local EARLY_MIN_AGE=15       -- 至少飞够这么多帧才在早期 state 设目标
    local host={applied=0,aimed=0,skipped=0,disabled=false,native_lifetime_verified=false}
    -- ⚠ `local function pointer` 已**上移**到文件更早处（见下方 players_scan 之前）。
    --   原因：2026-10-10 实机 `safe_players;n=0;reason=…:7297: attempt to call global
    --   'pointer' (a nil value)` —— players_scan（第 242 行）比它的定义（原第 683 行）
    --   **早 441 行** ⇒ Lua 取到全局 `pointer` = nil ⇒ 队友安全区整段静默失效。
    --   与 `faction`（2026-10-10 那次崩溃）**同一类词法作用域坑**，见
    --   tests/check_local_order.py（新增的通用检查：任何 local 都不得在其声明之前被使用）。
    -- ★★★ 每帧只读一次 readiness（2026-09-30 性能优化）★★★
    --
    -- `jobs_ready()` = 一次 `Readiness.capture` = **16 次内存读取**。它的调用点很多：
    --   ① tick 开头（`if not jobs_ready() then ...`）
    --   ② **每次** `with_observation` 开头
    --   ③ `scope.validate()` **每次**被 assert 时 —— `native_priority.step` 里
    --      `assert(scope.validate() and d.validate(),…)` 出现多次，而 validate 第一项
    --      就是 `jobs_ready()`
    --   ④ `disposal:step(m, jobs_ready)` 传入的 ready 回调
    -- 实机一帧内**一颗**在飞的 G-60 就能触发 5~10 次 ⇒ 单这一项可达上百次读取/帧，
    -- 而同一时刻常有多颗在飞 ⇒ 这是当时最大的可优化项。
    --
    -- 缓存论证（为什么与"重读"**等价**，不是削弱同步）：
    --   `host:tick` 在**引擎主线程**里同步执行 —— 这是我们所有内存读取成立的前提
    --   （否则读到的每个字节都不可信）。既然引擎不会在我们回调执行期间推进，
    --   同一帧内 Readiness 的观测值就**不会变** ⇒ 缓存与重读必然同值。
    --   ⚠ 只在**成功**时缓存；`Readiness.capture` 抛错时照常向上抛（由上层 pcall 处置），
    --     绝不会把"异常"缓存成"就绪"。
    -- ★ perf 窗口（2026-09-30）：每 `P.window` 帧打一行，**量化**"一帧到底读了多少"。
    --   只统计**真实发生**的读（readiness 的缓存命中不计入），否则测不出优化效果。
    --     ready    = readiness 真实执行次数（优化前应 ≫ 帧数，优化后应 ≈ 帧数）
    --     observe  = with_observation 次数（≈ 本窗口"每颗 G-60 的引导步数"合计）
    --     layout_* = Layout.capture 的读次数/字节（每帧无条件一次）
    --   ⚠ 所有计数器都在 `P` table 里（见上方注释：Lua 5.1 的 60 upvalue 上限）。
    local function jobs_ready()
        if P.ready_frame==frame then return P.ready_value end
        local r=Readiness.capture(read,base,env.exe,env.thread(),{matches={}},nil)
        P.ready_value=r.engine_main_thread_observed and r.world_job_completion==1
            and r.context_job_busy==0 and r.context_job_active==0
        P.ready_frame=frame
        P.ready_reads=P.ready_reads+1
        return P.ready_value
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
        P.observe=P.observe+1      -- perf 诊断（见 P.window）
        local track=tracked[current.match.id]
        local opts
        if env.experimental_event_window then
            opts={experimental_event_window=true,target_id=track and track.lock and track.lock.id}
            -- 早期接管：state 2/3 也允许观测（写入端的门控各自独立判断）
            if env.allow_state3 then opts.allow_early_state=true end
        end
        local c=Search.capture(read,base,current.match,env.engine,opts)
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
            -- ★ 上游这里是 `assert(current.match.selection_resource,
            --   'selected resource unavailable')`，实机把整条接管链打死了。
            --
            --   entity_resource() 读不到目标实体的资源哈希时返回 nil
            --   （observer:110 才会去读）。常见于 G-60 刚被引擎分配目标、
            --   目标实体尚未完全可读的那几帧。
            --
            --   问题在于语义错位：**引擎给 G-60 选了什么是引擎的事**，
            --   与"我们要不要接管、改飞去哪"无关。用 assert 把两者绑定，
            --   等于让一个只读元数据的失败阻断整个接管。
            --
            --   实机证据（2026-09-28 11:08）：
            --     priority_skipped;...;detail=selected resource unavailable;state=4
            --   11 次，全部 state=4（G-60 已到可接管状态）却一次都锁不上，
            --   而同期 structure_mark ACCEPTED 有 3 个。
            --
            --   处置：降级为"资源未知"快照，不抛错。
            --   仍然保守：resource=nil 时 native_titan_aim 的 profile 查表
            --   会得到 nil（fresh=false），于是回落到 previous.titan 的 profile
            --   或 env.titan_profile —— 与"目标变了"同等保守，不会误判为可信。
            local sel_res=current.match.selection_resource
            scope.snapshot.selected={ref={id=tostring(c.selection.id),scene=ref.scene,
                generation='observed-target-only'},resource=sel_res,
                resource_unknown=sel_res==nil}
            if sel_res==nil and not selection_resource_warned then
                selection_resource_warned=true
                env.emit('selection_resource_unknown;entity='..current.match.id
                    ..';selected='..tostring(c.selection.id)
                    ..';detail=treated_as_untrusted_target')
            end
        end
        -- ★★★ 认出"这个自定义航点是我们自己写的"（2026-10-05，移植上游 runtime 6407-6416）★★★
        --
        -- 上游原文注释一句话说清用途：
        --   `Permit priority to recognize the custom waypoint it already owns.
        --    It must still revalidate the target and current native observation.`
        --
        -- 为什么非要在这里（而不是在 priority 里自己比）：
        --   `old.titan` / `old.lock` 里存的 `point_bytes` 是**上一次**写下去时的字节，
        --   而引擎可能已经动了那块选择槽。只有**本帧的** `c.record_bytes` 才能证明
        --   "此刻记录里那个点，正是我们自己那个点"。⇒ 必须由观测者下这个结论。
        --
        -- 判据（全只读；与 native_priority 那侧同源，改一处必须两处一起改）：
        --   · `flag==1` 选择槽活着、`not has_target` 不是实体目标 ⇒ 是个"点"
        --   · `0x1d..0x28` == 持有者自己的 `point_bytes`
        --   · `+0x64 == 0` 类别掩码已清（原生 proximity 关着）
        -- 两个持有者都要看：
        --   ① `track.titan`（泰坦/航点路径；上游只有这一种）
        --   ② `track.lock`（早期接管 state 2/3 的点目标路径 —— 本工程特有，见 native_priority 504-563）
        -- ⚠ 两者都要求 `point_bytes` 非 nil：没有点的锁（普通实体锁）不参与，
        --   否则会误判成"已拥有自定义航点"，把正常的实体选择写入也一起跳过。
        local holder=track and (track.titan and not track.titan.cancelled and track.titan
            or track.lock)
        if holder and holder.point_bytes and c.selection.flag==1 and not c.selection.has_target
            and c.record_bytes:sub(0x1d,0x28)==holder.point_bytes
            and Layout.u32(c.record_bytes,0x64)==0 then
            scope.guidance_observation=holder
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
    -- ★★★ 安全区清选择的**专用** runner（2026-10-10，用户开关 safe_zone_veto_selection）★★★
    --   为什么必须另起一个实例（实机取证，2026-10-10 16:17 那局）：
    --     `runner` 的 `allowed` 来自 `env.target_allowed`，而它**只在
    --     `env.designed_targets_only==true` 时才构造**（本文件 51 行）——
    --     本裁剪版状态行是 `designed_targets_only=false` ⇒ `allowed==nil` ⇒
    --     `SelectionVeto.plan` 第 23 行 `not excluded and (not allowed or …)` **恒真**
    --     ⇒ 永远返回 `keep` ⇒ `run_veto` 只能清 small_filter 排除表里那 2 个载具，
    --     对普通敌人**一次都清不了**。铁证：那局 4 条
    --       safe_veto;entity=507/556/557/558;…;result=keep;why=VANILLA_ALLOWED
    --     —— 开关开着，却什么都没做（"功能在日志里报成功、实际是空转"是本工程最怕的形态）。
    --   ⇒ 给安全区一条**自己的**实例，`allowed` 恒 false（"谁都不在白名单里"）⇒
    --     只要引擎选中了**有效实体**，`plan` 必然给
    --     `{kind='search',clear_selection=true},'EXCLUDED_SELECTION'` ⇒ 真的清。
    --   ⚠ 实例状态是**每个实例各一份**（`create` 里 searching/last_window/disabled/busy
    --     都是 local）⇒ 与主 runner 互不干扰。
    --   ⚠ 独立实例的第二个理由与 `disposal_cancel` 同：它 `disabled` 只关掉这一个功能；
    --     主 runner 一 disabled 会让**整局 mod 停手**（见 run_veto 末尾的 fail-closed）。
    --   ⚠ 只有开关打开时才会被调用 ⇒ 关着时零行为变化、零额外读取。
    --   ⚠⚠ **为什么挂在 `runner` 上而不是另起一个 local**（2026-10-10 事故）：
    --     `host:tick` 里的 `xpcall(function() … end)` 已经**正好 60 个 upvalue**
    --     （Lua 5.1 的 `LUAI_MAXUPVAL`）—— 我第一版写成 `local safe_veto_runner=…`
    --     ⇒ 真 lua51 编译报 `function at line 7801 has more than 60 upvalues`
    --     ⇒ **整个 chunk 编译失败 = mod 完全没生效**（本工程 2026-09-30 栽过同款）。
    --     `runner` 本来就是 tick 的 upvalue ⇒ 把专用实例**当它的一个字段**挂上去，
    --     引用时是表查找、**不新增 upvalue**。
    --     ⚠ 教训：`check_lua51_compile.py` 只编译 `src/g60/*.lua`，**看不出**这条 ——
    --       必须连 `build/entry.lua`（拼装后的整份）一起编译才拦得住。该脚本已覆盖。
    runner.safe_veto_runner=Minimal.new_experimental(with_observation,
        function() return false end)
    function host:tick()
        if self.disabled then return end
        frame=frame+1
        -- ★★★ 空闲降频（2026-09-30 性能优化第二项）★★★
        --
        -- 实机 `perf` 行：**没有任何 G-60 在场**时 `layout_reads≈93~100 读/帧`，
        -- 而且这些读**全部**是 `Layout.capture` 遍历 behavior 数组去找 G-60 的成本
        -- （数组常驻约 55 项 ⇒ 55 次 identity 读 + 队列/头/guards 等）。
        -- 用户反馈"G60 没投掷时也有挺大的性能开销" —— 说的正是这部分**纯空转**：
        -- 没有手雷时我们仍然每帧把整张数组扫一遍，只为确认"还是没有"。
        --
        -- 处置（2026-10-03 起为**两档**，见下方 `两档节流` 那段）：
        --   · 没有可接管的 G-60 ⇒ 每 `scan_every_idle`（默认 **6**）帧做一次完整观测
        --   · 一旦有事可做（持有/可接管/早期探测）⇒ 收紧到 `scan_every_busy`（默认 **2**）
        --   · 引擎选中要否决的目标 ⇒ **每帧**重申，不跟着降
        --
        -- 代价（知情）：空转时投掷的 G-60 最多晚 **5 帧（≈83 ms）** 被发现；
        --   有事可做时最多晚 1 帧（≈17 ms）。
        --   远小于 G-60 从投掷到可接管 state-4 的时间（`EARLY_MIN_AGE`≥15 帧）。
        --   标记（ping）读取同样最多延迟这么多帧；标记在 UI ring 里**持续存在**
        --   （`age<duration`，数秒），因此不会因降频而漏掉。
        -- 安全性：无 G-60 时本帧**不做任何写**，跳过观测不改变任何行为，
        --   只是"晚一点知道有手雷出现"。
        if P.idle_skip>0 and (frame%P.idle_skip)~=0 then return end
        -- ★★ 2026-10-09：`pcall` → `xpcall` + 内联 handler，为的是**抓到出错处的调用栈**。
        --   背景：`frame_error` 只打一条消息、**不带调用者** ⇒ `pointer bound` 一直
        --   无法归因（`expired observation key` 那次也是靠猜才找到的）。
        --   ⚠ 必须 xpcall：handler 在**栈展开之前**执行，`debug.traceback` 才有栈；
        --     等 pcall 返回后再调 traceback，看到的只有 handler 自己。
        --   ⚠ handler 写成**内联匿名函数**（它自己捕获 P），不给 tick 闭包新增 upvalue
        --     —— 那个闭包的 upvalue 已近 Lua 5.1 的 60 上限。
        --   ⚠ `debug` 可能被裁剪 ⇒ 必须判空，否则错误路径本身再抛一次。
        local ok,why=xpcall(function()
            -- Keep observation keys across a skipped frame so an owned Titan
            -- waypoint can be cleaned up on the next eligible update.
            if not jobs_ready() then current=nil;return end
            -- ★★ 自机探针（只读 · 一次性 + 变化时才打 · 为安全区打底）★★
            --   只做三件事：①找出"我自己" ②取它的坐标 ③坐标变化时再打一条。
            --   ⚠ 全程 pcall：探针绝不能影响主链路（历史教训：探针抛错会把
            --     整条 priority 打死 ⇒ `disabled;applied=0`）。
            --   ⚠ 只读：不写任何内存，不调引擎写函数。
            if env.self_probe_enabled~=false and structure_ping and P.selfprobe.n<8 then
                local sp=P.selfprobe
                local pok,pres,perr=pcall(function() return structure_ping:self() end)
                -- ★ 失败必须**至少打一条**（且只占 1 个名额）：
                --   沉默的失败 = 没有诊断；但也不能因反复失败刷屏 ⇒ 失败只记一次。
                if not sp.failed_logged then
                    if not pok then
                        sp.failed_logged=true
                        env.emit('selfprobe;err=pcall;detail='..tostring(pres):sub(1,140)
                            ..';frame='..frame)
                    elseif not pres then
                        sp.failed_logged=true
                        env.emit('selfprobe;err='..tostring(perr)..';frame='..frame)
                    end
                end
                if pok and pres then
                    -- ★ 双路诊断：按哈希 / 按本地归属，各自是否命中、是否**同一实体**。
                    local bh,bo=pres.by_hash,pres.by_owner
                    local fmt=function(r)
                        if not r then return 'miss' end
                        local p=r.position
                        return string.format('id=%x,res=%s,idx=%d,pos=%s',
                            r.entity.id,tostring(r.entity.resource),r.index,
                            p and string.format('(%.1f,%.1f,%.1f)',p[1],p[2],p[3]) or 'nil')
                    end
                    local same=(bh and bo) and (bh.entity.id==bo.entity.id) or false
                    local tag='selfprobe;by_hash='..fmt(bh)..';by_owner='..fmt(bo)
                        ..';same='..tostring(same)
                        ..';slots='..tostring(pres.slots)..';count='..tostring(pres.count)
                        ..';nets='..table.concat(pres.nets,',')
                    -- 只在**首次**或**内容变化**时打 ⇒ 不刷屏；最多 8 条
                    if sp.n==0 or tag~=sp.last then
                        sp.n=sp.n+1;sp.last=tag
                        env.emit(tag..';frame='..frame)
                    end
                elseif sp.n==0 then
                    -- 走到这里只有一种可能：`pok` 为真但 `pres` 为 nil 且上面因
                    -- `failed_logged` 已打过 ⇒ 不再重复。保留兜底只为**绝不沉默**。
                    sp.n=1
                end
            end
            local observed=Layout.capture(read,base)
            P.lreads=P.lreads+observed.read_calls      -- perf 窗口累计
            P.lbytes=P.lbytes+observed.bytes_read
            -- ★★★ 降频判据：从"有没有 G-60"改成"**有没有事可做**"（2026-10-02）★★★
            --
            --  旧判据（`#observed.matches>0`）在实机日志里暴露出一类**纯空转**：
            --    `frame=36600 / 37200 ready=600 observe=0` —— 整窗口 600 帧
            --    **一次接管都没有**，却仍满速扫了 600 遍（141 读/帧）。
            --    原因：G-60 停在 state 3 上千帧（`sig=[4/3e@1620]` ≈ 27 秒），
            --    而 `allow_state3=false` ⇒ state 3 **一个字节都不写**。
            --    这与"场上没有 G-60"时的 40 读/帧是同一类空转。
            --
            --  新判据（任一成立 ⇒ `busy`；具体周期见下面的"两档节流"）：
            --    ① 有 state 4 的 G-60（可接管 / 可引导）
            --    ② `allow_state3` 打开时的 state 2/3（早期驱动路径要每帧）
            --    ③ 引擎选中了**要否决**的目标（运输船/增援飞船）—— 否决必须每帧重申
            --    ④ 本 mod 还**持有**某颗（`tracked` 非空 / `current` 非 nil）——
            --       disposal / arrival 要靠每帧观测推进
            --    ⑤ `early_nav_probe` 打开（该探测每颗只跑一次，不能被降频漏掉）
            --
            --  ★ 判据只遍历**本帧刚捕获的实体表**（`observed.matches`），
            --    不引入任何新的内存读（遍历是纯 CPU，十几~几十项，可忽略）。
            --  ★ 判据 ①/② 天然覆盖"我们刚接管的这颗"（它是可接管的 ⇒ 必为
            --    state 4，或 allow_state3 下的 2/3）⇒ 接管那帧必然置 0，
            --    **不会**出现"接管后却被降频跳过"的滞后。
            --  安全性同"优化二"：这些帧**不写任何内存**，跳过只是"晚 ≤2 帧
            --    （≈33 ms）知道情况变了"。
            --  ⚠ 副作用（知情）：`sig=[4/3e@N]` 的状态停留帧数在降频期按**观测帧**计，会偏小。
            local busy,veto_must=(next(tracked)~=nil) or (current~=nil) or (env.early_nav_probe==true),false
            if not busy then
                local ms=observed.matches
                for i=1,#ms do
                    local m=ms[i]
                    if m.behavior_id==4
                        and (m.state==4 or (env.allow_state3 and (m.state==2 or m.state==3))) then
                        busy=true;break
                    end
                    -- 引擎选中的目标若在排除表里 ⇒ 否决必须每帧重申，不能被降频漏掉
                    if m.selection_flag~=0 and env.enemy_veto_enabled~=false
                        and Filter.excluded(m.selection_resource) then
                        busy=true;veto_must=true;break
                    end
                end
            end
            -- ★★★ 两档节流（2026-10-03，用户要求）★★★
            --
            --   · 有事可做（持有 ✓ / 可接管 ✓ / 早期探测 ✓）⇒ `env.scan_every_busy`（默认 **2** 帧一次）
            --   · 纯空转（没有可接管的 G-60）          ⇒ `env.scan_every_idle`（默认 **6** 帧一次）
            --
            --   历史：最初是"有 G-60 就每帧 / 没有就隔 3 帧"；2026-10-02 把前者改成
            --   "**有事可做**才每帧"（治 state-3 空转），本次再把两档分别放宽到 2 / 6。
            --
            --   ⚠ **否决那一路**（`veto_must`）**仍保持每帧**（⇒ 1）：
            --     上面注释写明"否决必须每帧重申"，而节流是**最容易顺手放宽**的东西
            --     ⇒ 单列一档，不跟着 `busy` 一起降到 2。代价可忽略（否决本身罕见）。
            --
            --   防呆：非数 / 0 / 负数 ⇒ 回默认值。
            --     `0` 本身是安全的（闸门 `if P.idle_skip>0` 会短路），
            --     但**负数**会让 `frame%N` 恒为 0 ⇒ 每帧都 return ⇒ **mod 永远不跑**
            --     （静默整体失效，正是本项目最怕的那种）。
            local rb=math.floor(tonumber(env.scan_every_busy) or 0);if rb<1 then rb=2 end
            local ri=math.floor(tonumber(env.scan_every_idle) or 0);if ri<1 then ri=6 end
            P.idle_skip=busy and (veto_must and 1 or rb) or ri
            -- ★ perf 窗口打点（2026-09-30 性能优化）★
            --   放在 capture 之后、**任何早退之前**：游戏繁忙时 tick 会在下面
            --   `queues_complete=false` 处直接 return；若把打点放到 tick 末尾，
            --   繁忙局就**永远看不到 perf 行** —— 而"繁忙"恰恰是最需要量化的场景。
            --   放在这里保证只要 capture 成功就一定能采样（窗口对早退帧也计数）。
            if frame-P.wframe>=P.window then
                local span=frame-P.wframe
                P.wframe=frame
                env.emit('perf;frame='..frame..';frames='..span
                    ..';ready='..P.ready_reads..';observe='..P.observe
                    ..';layout_reads='..P.lreads..';layout_bytes='..P.lbytes
                    -- ★ 2026-10-02 新增（纯统计，**不含任何时间量**）：
                    --   active      —— behavior 数组的**活跃前缀**（活跃之外的槽位
                    --                  不可能被接管，用来解释 layout_reads 花在哪）
                    --   idle        —— 当前降频间隔（0=每帧；3=空转隔帧）
                    --   frames_seen —— 本窗口**实际跑过 tick 体**的帧数
                    --                  （对比 frames 一眼看出降频省了多少）
                    --   count       —— behavior 数组的**总长度**（= 逐槽 identity 扫描的
                    --                  圈数）。★ 2026-10-03 新增，**只读诊断**：
                    --                  实测 `layout_reads` 中位 204/次而 `active` 只有 1~9
                    --                  ⇒ 按固定开销（≈34 次：5 条队列 + 指针 + guards 复验）
                    --                  反推 `count ≈ 170~300` —— 也就是说**绝大部分内存读
                    --                  花在不可能有 G-60 的空槽上**（G-60 上限 16 颗）。
                    --                  把 count 打进日志是为了**验证这个推断**，而不是猜。
                    ..';active='..tostring(observed.active_prefix)
                    ..';count='..tostring(observed.behavior_count)
                    ..';idle='..tostring(P.idle_skip)
                    ..';frames_seen='..tostring(P.wframes))
                P.ready_reads,P.observe,P.lreads,P.lbytes=0,0,0,0
                P.wframes=0
            end
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
            -- ★★ 本帧生效的"ping 地面点"目标（2026-10-01）★★
            --   声明放在这里（tick 函数体顶层）而不是 if 里 —— 后面 per-entity 段要用它。
            --   ⚠ 不要把它带进 arrival 的匿名函数（那会多占一个 upvalue，见 P 的说明）。
            local point_marker
            -- ★ 与 point_marker 分开：`point_armed` = 还在 TTL 内（**只约束"新接管"**）。
            --   已在引导中的那颗不受 TTL 影响 —— 否则 TTL 一到期就把它当场丢掉
            --   （G-60 半路失去引导、永远不炸）。见登记处的说明。
            local point_armed
            -- ★★ 2026-10-10 本帧的"标记是友方"旗标（用户第二次报的 bug 要用）★★
            --   为什么不能只看 structure_mark：判为友方时它会被**置 nil**，而兜底 veto
            --   恰恰需要知道"玩家标记的是一个不能当目标的单位"（否则引擎的锁定没人清，
            --   手雷一直被那个友方占着 ⇒ 我们的接管段进不来）。
            local mark_friendly
            -- ★★★ 阵营判据 helper —— **必须定义在 `if structure_ping then` 之外** ★★★
            --   2026-10-10 实机事故（我引入的）：
            --     它原来定义在那个 `if` 块**内部**，而兜底 veto 那处调用在本函数
            --     **后半段**（该块闭合之后）⇒ Lua 取到全局 `faction` = nil ⇒
            --       frame_error;…:8960: attempt to call global 'faction' (a nil value)
            --     每触发一次就**中止当帧剩余的全部处理**（xpcall 吞掉，当帧后面的
            --     所有 G-60 都不再处理）。作用域必须同时覆盖两处调用点。
            --   ⚠ 教训：`local function` 的可见范围是**词法块**，与缩进无关；
            --     判断可见性只能看块边界（本工程新增 _dumps/scope_chain2.py 专门算这个）。
            local function faction(id,res)
                if not id or id==0 then return 'err',false end
                local fk='f:'..tostring(id)..':'..tostring(res)
                local v=P.fk[fk]
                if v~=nil then return v,false end
                local okf,q=pcall(function()
                    local d=TargetData.new(read,base,env.exe)
                    local e=d.entity(id)
                    if not e then return nil end
                    return env.calls.target_valid(nil,e.id,ffi.cast('const void *',e.address))
                end)
                if not okf then v='err'
                elseif q==true or q==1 then v='yes'
                elseif q==false or q==0 then v='no'
                else v='err' end
                P.fk[fk]=v
                return v,true
            end
            if structure_ping then
                structure_mark,structure_issue=structure_ping:observe()
                -- ★ 与 ping_issue 同款去重：这类"Ping creator 暂时读不到"是**逐帧**发生的
                -- （实机日志里几百条），逐条 emit 会把 structure_mark / priority_locked
                -- 这些真正有用的行彻底埋掉。只在**原因变化**时打一条，并在停机时汇总次数。
                if structure_issue then
                    structure_issue_counts[structure_issue]=(structure_issue_counts[structure_issue] or 0)+1
                    if structure_issue~=last_structure_issue then
                        env.emit('structure_ping_unavailable;detail='..tostring(structure_issue))
                    end
                end
                last_structure_issue=structure_issue
                -- ★★ 阵营判据：把"友方标记"在**一切决策之前**就当不存在（用户要求 2026-10-10）★★
                --
                --   用户报：「标记友方单位后空 ping 会失效，直到友方单位消失」，并问
                --   「能不能通过阵营来判断」。
                --
                --   判据用**引擎自己的** `calls.target_valid`（game.dll+0x8858a0）——
                --   它就是那条阵营判据。实机 12 条 `target_fields` 探针实测：
                --     · 友方/中性（信标球 16f397ca5f51f271、a94913ca014f7579、8e325c93…）
                --       **4/4 全部 valid=false**；
                --     · 敌人与虫洞（ef85d6cf…、8901f188…、fde26259…、31400a6a…、5052ec6a…）
                --       **全部 valid=true**。
                --   而同一批探针里的 f08/f0c/f4c **分不开**（f4c=0 在 false/true 里都出现）
                --   ⇒ 三个候选字段都不是阵营位，不许拿它们当判据。
                --
                --   为什么必须放在**这里**（入口之后、一切决策之前）：
                --   原来只有 priority 在**锁定阶段**才问 target_valid ⇒ 友方标记**先被收进
                --   队列**，然后每帧被拒（`generic_rejected…NOT_VALID_TARGET`）；而它在 ping
                --   记忆里只要实体活着就一直存活 ⇒ 把 `structure_mark` 长期钉住
                --   ⇒ **空白标记那条路被挡死**（用户现象完全吻合）。
                --   ⇒ 这里判一次，判为友方就把**本帧**的 `structure_mark` 置 nil：后面的
                --     take_gate / mark_is_wormhole / ping_beats_titan / priority 一律当它
                --     不存在。**只影响本帧决策，不动 ping 记忆、不写任何内存。**
                --   ⚠ 查询失败/实体读不到 ⇒ **保守当有效**（行为与改动前一致），并打一条
                --     `mark_faction_unknown;` —— 静默就等于没做。
                --   返回值：'yes'（引擎说可当目标）/ 'no'（友方·中性）/ 'err'（查不到）。
                --   ⚠ 按 (id,resource) 缓存 —— 同一个目标只查一次原生查询。
                --   ⚠ 第二个返回值 = "这次是新查的"（供调用方**只打一次**证据行）。
                --   ⚠ 定义已移到本函数顶层（`if structure_ping then` **之外**）——
                --     原因见那里的实机事故说明（块内定义 ⇒ 兜底 veto 处取到全局 nil ⇒ 崩）。
                -- ★ 把"友方标记"在**一切决策之前**就当不存在（本帧 structure_mark 置 nil）。
                --   为什么必须在这里（入口之后、决策之前）：
                --   原来只有 priority 在**锁定阶段**才问 target_valid ⇒ 友方标记**先被收进
                --   队列**，然后每帧被拒（`generic_rejected…NOT_VALID_TARGET`）；而它在 ping
                --   记忆里只要实体活着就一直存活 ⇒ 把 `structure_mark` 长期钉住
                --   ⇒ **空白标记那条路被挡死**。
                --   ⚠ 光"当它不存在"**还不够**：**引擎自己的锁定**还钉在那个友方身上
                --     （`selection_veto=DISABLED`，没人清）⇒ 手雷一直被它占着、我们的接管段
                --     进不来（用户 2026-10-10 第二次报的就是这个）⇒ 见下面兜底 veto 的
                --     `friendly_lock` 分支：用**同一套已审查的"清选择"路径**把它清掉。
                if structure_mark and structure_mark.id then
                    local verdict,fresh=faction(structure_mark.id,structure_mark.resource)
                    if fresh then
                        if verdict=='no' then
                            env.emit('mark_friendly;target='..tostring(structure_mark.id)
                                ..';resource='..tostring(structure_mark.resource)
                                ..';reason=NOT_VALID_TARGET;action=IGNORED_AS_FRIENDLY;frame='..frame)
                        elseif verdict=='err' then
                            env.emit('mark_faction_unknown;target='..tostring(structure_mark.id)
                                ..';resource='..tostring(structure_mark.resource)
                                ..';frame='..frame)
                        end
                    end
                    if verdict=='no' then
                        mark_friendly=true
                        -- ★★★ 2026-10-10 友方标记 bug 的关键取证 ★★★
                        --   引擎给"标记友方"的目标是**一个点**（实机 `3|0|1|nil` =
                        --   flag=1 但 id=0、resource=nil），那个点**极可能就是友方的坐标**
                        --   ⇒ 我们若把它当"点目标"登记，就等于亲手把雷引向友方。
                        --   这里先把友方坐标记下来（`P.fk` 用 'p:' 前缀，与 'f:' 判据不冲突），
                        --   下面登记点目标时**只读比对**：命中才跳过，不命中一切照旧。
                        local okfp,fp=pcall(function()
                            local d=TargetData.new(read,base,env.exe)
                            local e=d.entity(structure_mark.id)
                            if not e then return nil end
                            return d.position(e)
                        end)
                        -- ⚠ 只记**单位**，不记"被 ping 锁到的飞行中 G-60"：
                        --   实机 `mark_friendly;target=579;resource=8e325c933e55bf62`（8e32… 是
                        --   **G-60 自己的资源哈希**），而 579 同时被我们 force_lock/point_taken/
                        --   引爆 ⇒ 它是颗手雷。若把它的坐标也记进来，那颗雷飞向 ping 点时
                        --   距离会一路缩小 ⇒ **误判**成"友方落点" ⇒ 把正常 ping 忽略掉。
                        --   我们 `tracked` 的实体一定是 G-60 ⇒ 用它排除。
                        if okfp and fp and not (tracked and tracked[structure_mark.id]) then
                            P.fk['p:'..tostring(structure_mark.id)]=fp
                        end
                        structure_mark=nil
                    end
                end
                -- ★★ "空白标记"（ping 到空地）★★
                --   玩家 ping 空地时，ping 槽里其实**带世界坐标**（`+0x04` float3，
                --   已由三边定位交叉验证：8 组 (pos,dist) 解出同一公共点、残差 ~0.7m RMS）。
                --   两个用途，**互不依赖**：
                --     · 诊断（point_marker_enabled）：每项只打一行，便于核对
                --     · 点目标（point_target_enabled）：把它登记成"可引导的坐标目标"
                local lp=nil
                if (env.point_marker_enabled or env.point_target_enabled)
                    and structure_ping.last_point then
                    lp=structure_ping:last_point()
                end
                if lp and env.point_marker_enabled and env.emit then
                    local tk=tostring(lp.slot)..':'
                        ..string.format('%.1f/%.1f/%.1f',lp.x,lp.y,lp.z)
                    if not P.pmark[tk] and P.pmark_n<120 then
                        P.pmark[tk]=true;P.pmark_n=P.pmark_n+1
                        env.emit(string.format(
                            'point_marker;slot=%s;pos=%.2f/%.2f/%.2f;dist=%.2f;age=%.2f;source=ping_slot',
                            tostring(lp.slot),lp.x,lp.y,lp.z,lp.dist or -1,lp.age or -1))
                    end
                end
                -- ★★ 点目标登记（2026-10-01，用户要求"ping 一个位置 ⇒ G-60 飞过去炸"）★★
                --   TTL：同一个 token 只在 `point_target_ttl_frames` 内作数。
                --     为什么需要：ping 标记在引擎里的存活时长我们无法从 `+0x14` 判断
                --     （实测它不是时间戳），而"顺手 ping 一下地面"不该长期劫持 G-60。
                --     标记被引擎淘汰时 `last_point` 变 nil ⇒ 自然释放；TTL 是第二道闸。
                --
                --   ★★ 优先级改成**按每颗 G-60 判**（2026-10-01 实机修正）★★
                --   第一版写成 `and not structure_mark` —— 只要**存在**任何结构标记
                --   （虫洞/泰坦/被泛用接管的实体…）就**全局**不登记点目标。
                --   实机后果（19:44 那局）：玩家 ping 了一个虫洞 MK9 之后，
                --   那个结构标记在 ping 记忆里长期存活 ⇒ **后面所有 ping 全都不生效**
                --   （用户报"生效几次，后面又不生效"）。
                --   正解：登记不再看 structure_mark；真正的优先级在**驱动时**判 ——
                --     · 这颗 G-60 若已被 priority 锁上结构（old.lock）⇒ 结构优先（见 point_drive）
                --     · 否则才轮到点目标 ⇒ "一颗炸虫洞、其余炸 ping 点"能同时成立
                --   `point_marker` = 标记**存在**（供"已在飞行中的那颗"继续用 + 释放判定）
                --   `point_armed`  = 还在 TTL 内（**只约束"新接管"**）
                --   ★ 为什么必须把这两件事分开（2026-10-01 第二次实机修正）：
                --     第一版让 TTL 一到期就把 point_marker 置 nil ⇒ **已经在飞的那颗
                --     会被当场丢掉**（G-60 半路失去引导、永远不炸）。
                --     玩家"ping 之后隔一会儿才扔"很容易撞上（TTL 20 秒、飞行 5~14 秒）
                --     —— 这正是"时灵时不灵"的一个来源。
                --     ⇒ 现在：TTL 只挡新接管；已在引导中的那颗一直有效，
                --       直到标记真的从 ping 环里消失（`last_point` 变 nil）。
                --   另外：标记若从环里消失又出现（同一 token），TTL 重新计时
                --     （`P.pt.seen==false` 那一帧又看到它 ⇒ 是新的一次 ping）。
                if env.point_target_enabled and lp and lp.token then
                    -- ★★★ 2026-10-10 友方标记 bug 的修复（用户报了两轮）★★★
                    --   现象：「释放出的手雷会一直锁定标记的友方单位」+「标记友方期间投的
                    --   G60 不能接受空 ping 的接管」。
                    --   实机取证：那颗雷全程 `3|0|1|nil` —— 引擎给它的目标是**一个点**
                    --   （flag=1 但 id=0、resource=nil），不是实体选择。
                    --   ⇒ 判据（**纯只读**）：把 ping 槽坐标与被标记友方的坐标比一比；
                    --     命中（≤3 m）⇒ 这个点就是"友方所在的落点" ⇒ **不登记**，
                    --     否则我们等于亲手把雷引向友方（还会把友方周围当成安全区圆心）。
                    --   ⚠ 不命中（判据不成立）⇒ 一切照旧，行为与改动前**完全一致**。
                    local fp_hit=nil
                    if mark_friendly then
                        for _,fpv in pairs(P.fk) do
                            if type(fpv)=='table' then
                                local ax,ay,az=lp.x-fpv[1],lp.y-fpv[2],lp.z-fpv[3]
                                local dd=math.sqrt(ax*ax+ay*ay+az*az)
                                if dd<=3.0 and (not fp_hit or dd<fp_hit) then fp_hit=dd end
                            end
                        end
                    end
                    if fp_hit then
                        local fkey='fp:'..tostring(lp.token)
                        if not P.fk[fkey] then
                            P.fk[fkey]=true
                            env.emit('friendly_point;slot='..tostring(lp.slot)
                                ..';dist='..string.format('%.2f',fp_hit)
                                ..';action=IGNORED_AS_FRIENDLY_POINT;frame='..frame)
                        end
                        point_marker=nil
                        P.pt.seen=false
                    else
                    if P.pt.token~=lp.token or P.pt.seen==false then
                        P.pt.token=lp.token;P.pt.frame=frame
                        -- 与结构标记并存时打一行：解释"这次为什么可能先打虫洞"
                        if env.emit and structure_mark then
                            env.emit('point_armed;slot='..tostring(lp.slot)
                                ..';pos='..string.format('%.1f/%.1f/%.1f',lp.x,lp.y,lp.z)
                                ..';note=structure_mark_present;structure='..tostring(structure_mark.resource))
                        end
                    end
                    P.pt.seen=true
                    point_marker=lp
                    point_armed=(frame-P.pt.frame)<=env.point_target_ttl_frames
                    end   -- /fp_hit 的 else（判据不命中 ⇒ 与改动前完全一致）
                else
                    P.pt.seen=false
                end
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
            -- ★ 链路诊断（2026-09-27 连续两轮"静默失败"才加的）
            -- 前两轮的事故都有一个共同点：**日志里看不出卡在哪一步**。
            -- 标记读到了却没接管时，日志只有 structure_mark ACCEPTED，
            -- 之后一片空白 —— 既不知道有没有 G-60、也不知道 priority 段进没进。
            -- 这里把一帧的关键计数攒起来，状态**变化**时才打一行（不逐帧刷屏）。
            -- ⚠ 凡下面写 `diag.X=diag.X+1` 的字段，**必须**在这里初始化为 0。
            --   2026-09-28 我加了 `diag.state3` 的累加却漏了初始化 ⇒
            --   `attempt to perform arithmetic on field 'state3' (a nil value)`
            --   每帧崩在 tick 开头，整帧作废（测试是静态断言，抓不到运行时 nil）。
            --   tests/test_priority_fault_isolation.py 会比对两侧，漏一个就红。
            local diag={state4=0,state3=0,eligible=0,entered=0,locked=0,held=0,blocked=0}
            -- ★ 光看 state4 不够：它分不清"manager 里根本没有 G-60"、
            -- "有 G-60 但身份哈希没匹配上"、和"有 G-60 但停在别的 state"。
            -- 所以把 manager 的总数、matches 条数、每条的 behavior/state 都打出来。
            local sigs={}
            for _,m in ipairs(observed.matches) do
                -- 带上"在当前 state 停留了多少帧"：区分"刚扔出去还在起飞"
                -- 和"长期卡在 state-3 永远进不了可接管状态"。
                local fp=m.identity_bytes..m.flight_start
                local st=tostring(m.behavior_id)..'/'..tostring(m.state)
                    ..(m.native_update_eligible and 'e' or '-')
                if state_key[fp]~=st then state_key[fp]=st;state_age[fp]=0 end
                state_age[fp]=(state_age[fp] or 0)+1
                if m.state==4 then saw_state4=true end
                sigs[#sigs+1]=st..'@'..tostring(state_age[fp])
                -- ★★ 转阶段 / 换目标探针（2026-10-07，用户要求）★★
                --
                --   问的是："引擎在什么条件下把 G-60 转向索敌 / 丢掉目标？"
                --   （本文件上方 entry 的注释里记着同一个未解问题：
                --     「无敌人时 G-60 不被驱动（受 state 约束）」，
                --     而定位"分配目标 / 状态转换"那个函数需要 dump 运行时镜像。）
                --
                --   ⚠ 函数本体 hook 不到：引擎是**自己**去调 clear/orbit 的
                --     （`compat/native_search_binding.lua` 那两个函数指针只是
                --      我们主动调用用的入口），本工程也不引入代码注入。
                --   ⇒ 但**转阶段的后果是可见的**，而且全在每帧已经读到的 match 行上：
                --     state            阶段（2/3/4）—— 回退 = 转索敌
                --     selection_id     +0x18 当前锁定实体 id（被清成哨兵 = 丢目标）
                --     selection_flag   有效选择标志（归零 = 没有目标）
                --     selection_resource 该 id 的资源哈希 ⇒ **引擎到底锁了谁**
                --     candidate_source +0x68 选择来源（候选表选的 / 标记给的）
                --   ⇒ 零新增内存读、零新依赖、零写操作（纯观测）。
                --
                --   去重：只在元组**变化**时打一条（首次也打，用来区分
                --   "投出即锁上"与"投出就没有目标"）。一颗雷一次任务通常 3~8 条。
                --   ⚠ 上限 4000 行写死为字面量：新增模块级 local 会占 upvalue
                --     （本文件反复踩过 60 上限），这里不值得为常量付一个名额。
                if env.sel_probe_enabled~=false and m.behavior_id==4
                    and P.seln<4000 then
                    local tuple=tostring(m.state)..'|'..tostring(m.selection_id)
                        ..'|'..tostring(m.selection_flag)..'|'
                        ..tostring(m.selection_resource)..'|'..tostring(m.candidate_source)
                    local was=P.sel[fp]
                    if was~=tuple then
                        P.seln=P.seln+1
                        env.emit('sel_probe;entity='..m.id
                            ..';was='..tostring(was or 'first')..';now='..tuple
                            ..';age='..tostring(state_age[fp] or 0)
                            ..';frame='..tostring(frame))
                        P.sel[fp]=tuple
                    end
                end
            end
            diag.total=#observed.matches
            diag.manager=observed.behavior_count
            diag.sig=table.concat(sigs,',')
            -- ★ veto 执行的**单一实现**（2026-09-30 修复）
            --
            -- 两个触发点共用（这是抽出来的原因：项目吃过"同一逻辑写两份、
            -- 只改一份"的亏 —— 见 native_priority 的 sticky 分支越权事故）：
            --   ① take_gate 的 veto 分支 —— **无标记**路径（2026-09-30 前的唯一入口）
            --   ② priority 段之后的兜底 —— **有标记但 priority 没接管**
            --
            -- 为什么需要 ②：veto 判定嵌在门控的"无标记且无持有"里
            --   `if not (structure_mark or held) then ... veto ... end`
            -- ⇒ 玩家一旦标记了东西，veto 就**不可达**；而 priority 会**拒绝**
            --   不该接管的目标（友方 ⇒ NOT_VALID_TARGET）⇒ 引擎给的排除表目标
            --   没人清。实机 2026-09-30：
            --     structure_mark resource=16f397ca5f51f271(信标球) ACCEPTED
            --     generic_rejected ... detail=NOT_VALID_TARGET
            --     enemy_selection entity=923 resource=db90077e76faa025 vetoed=true
            --     enemy_veto → 0 次        ← 运输船因此没被过滤
            --   （2026-09-30 前只有虫洞/泰坦，标记的一定会被接管 ⇒ setter 自然
            --     覆盖了运输船，所以这个缺口一直没暴露。）
            --   ⚠ `quiet`（2026-10-10 加）：安全区那条路要**每帧**清（引擎每帧都会重新
            --     锁上），但 `enemy_veto;` 是逐次打的 ⇒ 逐帧 emit 会把日志埋掉。
            --     调用方传 quiet=true 并**自己打一条**证据行（`safe_veto;`）。
            --   ⚠ 新增返回值 (kind, why)：调用方要把它写进自己的证据行，
            --     否则"清了没有 / 为什么没清"又变成不可见（本项目的老毛病）。
            --   ⚠ `use_runner`（2026-10-10 加）：安全区那条路要用**专用实例**
            --     `runner.safe_veto_runner`（`allowed` 恒 false ⇒ 必然走清选择；
            --     原因见它的构造处，以及"为什么不另起 local"那条 upvalue 事故）。
            --     其余调用方不传 ⇒ 行为与改动前逐字节一致。
            local function run_veto(match,resource,via,quiet,use_runner)
                local R=use_runner or runner
                local veto_ref={id=tostring(match.id),generation='veto-'..match.id,
                    scene='experimental-session'}
                current={ref=veto_ref,match=match}
                local ok_v,res_v=R:step(veto_ref)
                current=nil
                -- 立刻释放：否则 search 一旦成功，searching[key] 会一直为真
                --   ⇒ 之后每帧都走 CONTINUE_SEARCH ⇒ 每帧强行 orbit，
                --   等于把"不追踪运输船"变成"一直盘旋"（副作用外溢）。
                --   释放后语义收敛为"只在引擎当前确实选中该目标时才清一次"。
                R:release(veto_ref)
                if env.emit and not quiet then
                    -- ★ runner:step 的返回契约是 (result, reason)，**不是** (ok,result,why)。
                    --   2026-09-29 我按后者取值 ⇒ 实际打出 `result=nil;why=nil`（145 条全是 nil）。
                    --   现在按正确顺序取，并加 via 标明触发点。
                    env.emit('enemy_veto;entity='..match.id..';resource='..tostring(resource)
                        ..';result='..tostring(ok_v and ok_v.kind or 'FAILED')
                        ..';why='..tostring(res_v)..';via='..via..';frame='..frame)
                end
                -- 与既有引导路径同一处置：部分写入后失败 ⇒ 停手（fail-closed）。
                -- ⚠ 只对**主** runner 做全局停手：专用实例是隔离域，它 disabled
                --   只该关掉"安全区清选择"这一个功能（否则一个实验功能能把整局 mod 停掉）。
                if R:disabled() then
                    if R==runner then
                        self.disabled=true
                        error('native operation disabled after enemy veto')
                    end
                    return 'DISABLED','SAFE_VETO_RUNNER_DISABLED'
                end
                return ok_v and ok_v.kind or 'FAILED',res_v
            end
            -- ★★ 2026-10-10 安全区：把**引擎自己瞄的雷**也管起来（用户报「没标记时不生效」）★★
            --
            --   根因是结构性的：安全区那道门只在"**我们在驾驶**这颗雷"的路径上跑
            --   （`TakeGate.decide_guidance` 要求 `old.lock / old.titan / old.point`）
            --   ⇒ 玩家什么都没 ping（手雷是引擎自己瞄敌人）时，门**一次都不会被调用**
            --     ⇒ 安全区对这类雷完全无效。这正是用户在实机看到的现象。
            --
            --   本函数是**唯一**会写"非自有 G-60"的地方（与 `run_veto` 同级的例外），
            --   所以边界收得很紧：
            --     · 由菜单开关 `safe_zone_engine_hold` 控制，**默认关** ⇒ 不开＝零行为变化；
            --     · 只在 **state 4**（引擎已起索敌；state 2/3 写 movement 有过崩机前科）；
            --     · 只在引擎**确实选了目标**（`m.selection_id~=0`）且**我们没持有**时；
            --     · 先做**便宜的几何判定**（`blast_safe_hold_td`：TargetData 单读、不 capture），
            --       只有玩家真在圈内才付 `with_observation`（`Search.capture` 很贵）；
            --     · **不建 tracked、不设 lock/titan** ⇒ priority/titan/arrival/disposal
            --       四条接管路径都碰不到它（与 veto 同一套"最小影响面"思路）；
            --     · 玩家一离开就**停止写** ⇒ 引擎自己接管回去（我们不改它的状态）。
            --
            --   机理与已接管路径**完全一致**（绕行点 = 目标几何位置 + 旋转偏移，走
            --   `options.point_target` 这条已在生产使用的写路径）—— 唯一差别是圆心来自
            --   **引擎的选择**（`m.selection_id`）而不是我们的锁。
            --   ⇒ 每次调用都必须留证据，并由日志回答那个**唯一要问的问题**：
            --     "我们抢不抢得过引擎？"
            --       `safe_engine;`      这次写的目标/结果
            --       `safe_engine_kept;` 写下去的点活了 ≥30 帧（抢赢了）
            --       `safe_engine_lost;` 引擎下一帧就把选择抢回去了（抢不赢 ⇒ 这条路走不通）
            --     没有这三条，实验做完了也没法判读。
            local function run_safe_hold(match)
                -- ★★ 每帧都跑（2026-10-10 修正）★★
                --   第一版把调用条件写成 `m.selection_id~=0`，而我们自己写下去的点会让
                --   selection_id 变 0 ⇒ **下一帧起就不满足条件** ⇒ 整条路只在"引擎恰好
                --   重新锁上目标"的那几帧才动作。实机证据（2026-10-10 10:45 那局）：
                --     entity=596  帧 15944→16308（跨度 364 帧）只有 **5** 条 blast_hold
                --     entity=615  帧 20354→21080（跨度 726 帧）只有 **9** 条 blast_hold
                --   ⇒ 压制断断续续，而且"玩家离它多远"这段历史几乎是空白。
                local fp=match.identity_bytes..match.flight_start
                local rec=P.ehq[match.id]
                -- 手雷 id 会被引擎复用 ⇒ 换了飞行就丢掉上一颗的全部状态
                if rec and rec.fp~=fp then
                    P.ehq[match.id]=nil;P.ehp[match.id]=nil
                    P.ehk[match.id]=nil;P.ehx[match.id]=nil
                    P.noexec[match.id]=nil;P.noexec_warn[match.id]=nil
                    P.evv[match.id]=nil;P.evp[match.id]=nil
                    rec=nil
                end
                -- ① 便宜判定：玩家在圈内吗？（TargetData 单读，**不做 capture**）
                -- ★ 取消线距离（菜单可调，默认 3.5 = 实测标定值）
                local cthr=tonumber(env.blast_safe_cancel_dist) or 3.5
                if cthr<1 then cthr=1 elseif cthr>20 then cthr=20 end
                local allow,mysp,pdist=blast_safe_hold_td(match)
                if allow then
                    -- 玩家离开安全区 ⇒ 不再压制，清状态（引擎自己接管回去）
                    P.ehq[match.id]=nil
                    P.noexec[match.id]=nil
                    return
                end
                -- ★★★ 取消**到底生效没有**？（2026-10-10，用户要求把取消线做成设置项）★★★
                --   为什么必须有这一条：取消请求"成功返回"**不等于**引擎兑现了移除 ——
                --   实机 entity=528 在 `safe_cancel;`（成功）之后**又活了 2092 帧（35 秒）**
                --   （`sel_probe` 还在逐帧观察它）。没有这条证据行，用户把取消线从 3.5 调到
                --   8 也只会看到"还是一样炸"，却分不清是"线不够大"还是"移除压根没兑现"。
                --   判据：取消成功之后实体**还在**（本帧门判定它还在圈内 ⇒ 它还活着），
                --   且已过去 ≥120 帧（2 秒；够移除排队+回读好几轮了）⇒ 判定"移除没兑现"。
                --   ⚠ 只打一次（打完清掉计时器）⇒ 不逐帧刷屏。
                if P.ehc[match.id]=='done' and P.ehf[match.id] then
                    local alive=frame-P.ehf[match.id]
                    if alive>=120 then
                        P.ehf[match.id]=nil
                        env.emit('safe_cancel_stale;entity='..match.id
                            ..';alive='..alive
                            ..';thr='..string.format('%.1f',cthr)
                            ..';frame='..frame)
                    end
                end
                -- ② ★★ 它是不是**已经被引擎炸了**？（2026-10-10 补）★★
                --   这类雷我们不接管 ⇒ 没有 tracked ⇒ `note_already_exploded` 永远走不到它
                --   ⇒ 实机上它真炸了，我们日志里**一个字都没有** —— 用户报的"有时候还是会
                --   爆炸"因此**无法证伪**（这也是上一轮判读不出"不够稳定"的原因）。
                --   判据与 priority 预检**同一个**（只读 `arrival:triggered`，一次 ~20 读），
                --   但每 5 帧才采一次（成本 ÷5；爆炸是终态事件，晚 5 帧知道不影响判读）。
                if arrival and frame%5==0 and arrival:triggered(read,match.identity_bytes) then
                    if not P.ehx[match.id] then
                        P.ehx[match.id]=true
                        local v,o=P.hit[match.id],P.tpos[match.id]
                        local dd='dist=-'
                        if v and o then
                            local dx,dy,dz=v[1]-o[1],v[2]-o[2],v[3]-o[3]
                            dd=string.format('dist=%.2f',math.sqrt(dx*dx+dy*dy+dz*dz))
                        end
                        env.emit('safe_engine_exploded;entity='..match.id
                            ..';target='..tostring(match.selection_id)
                            ..';'..dd
                            ..';pushed='..tostring(rec and (frame-rec.frame) or '-')
                            ..';frame='..frame)
                    end
                    P.ehq[match.id]=nil
                    return
                end
                -- ★★ 2026-10-10 站定距离（standoff）：圆心与"离目标多远"**每帧现算** ★★
                --   为什么必须每帧算（实机教训 entity=522）：
                --     · 引擎的引信是**物理接近目标**（不是"记录里选中的是谁"）——
                --       522 在我们的点**还在记录里**（target=0）时于 **2.25 m** 被点火，
                --       上一局 639 是 **2.22 m** ⇒ 两次独立取证一致。
                --     · 而 522 的目标是**会走路的敌人**（食腐蟲 aab438596f5e8fd9）：圆心
                --       原来只在"点被抢回"时才更新（最长 90 帧不刷新）⇒ 敌人正好走进圈里。
                --   ⇒ 圆心每帧现算 + 距离太近就**命令它往外飞**（见下面的 push）。
                --   ⚠ 两次 TargetData 读，**不付 capture**（capture 只在真要写的时候付）。
                local tid=(match.selection_id~=0 and match.selection_id)
                    or (rec and rec.tid) or nil
                -- ★★★ 圆心三源冗余（2026-10-10，用户要求"增加冗余"）★★★
                --   实机事故（2026-10-10 15:31 那局，2981 行日志）：7 例
                --   `arrival_already_exploded` 的雷**一条 `safe_engine;` 都没有** ——
                --   门明明判了"玩家在圈内"（有 `blast_hold;entity=540;player_dist=11.87`），
                --   却没有执行者。根因是下面那句 `if not tid then return end`：
                --     引擎把"要撞的东西"表示成**点**时（`sel_probe` 的 `4|0|1|nil`：
                --     flag=1 但 id=0、resource=nil）⇒ `tid=nil` ⇒ **直接返回**。
                --   而这一类雷在引擎里占多数（540 的 age=17/450/461/319 全在点态），
                --   我们一次都没压过它 ⇒ 它一路飞到引信范围内被点火。
                --   ⇒ 圆心改成**三源**，任一可得就继续（这是"冗余"的本体）：
                --     ① 引擎选中的**实体**位置（最准，每帧现算）
                --     ② 记录里引擎自己的**点**（`record_bytes:sub(0x1d,0x28)`，
                --        与 `old.point` / 绕行判据**同一个偏移**）—— 点态选择时只有它有
                --     ③ 上次已知圆心 `P.tpos`（这一帧读不到也不至于"没有执行者"）
                --   ⚠ ② 必须排除"这个点是我们自己写下去的"：那时它已经是我们的绕行点，
                --     拿它当圆心就会绕着自己转（判据：与 `rec.bytes` 逐字节相同 ⇒ 是我们的）。
                local c,r,csrc
                if tid then
                    local ok2,a,b=pcall(function()
                        local d=TargetData.new(read,base,env.exe)
                        local e=d.entity(tid)
                        local c0=e and target_position(e)
                        if not c0 then return nil end
                        local me=d.entity(match.id)
                        return c0,(me and d.position(me)) or nil
                    end)
                    if ok2 and a then
                        c=a
                        csrc='entity'
                        P.tpos[match.id]=c
                        if b then
                            P.hit[match.id]=b
                            local dx,dy,dz=b[1]-c[1],b[2]-c[2],b[3]-c[3]
                            r=math.sqrt(dx*dx+dy*dy+dz*dz)
                        end
                    end
                end
                if not c and match.selection_flag==1 and match.selection_id==0 then
                    local rb=match.record_bytes
                    local ours=rec and rb and rb:sub(0x1d,0x28)==rec.bytes
                    if rb and not ours then
                        local ok3,p3=pcall(TargetData.vector,rb,0x1c)
                        if ok3 and p3 then
                            c=p3
                            csrc='point'
                            P.tpos[match.id]=c
                        end
                        -- ⚠ 这里**必须顺便把"雷在哪"也读回来**（2026-10-10 实机缺陷）：
                        --   第一版只取圆心 ⇒ `P.hit` 一直空 ⇒ `r=nil` ⇒
                        --     · 贴脸取消**永远不会触发**（它要求 `r<=cthr`）
                        --     · `need_write` 恒真 ⇒ 每帧都写（capture 变贵）
                        --     · `safe_engine;…;r=-` / `safe_engine_exploded;…;dist=-;pushed=-`
                        --       两条诊断全变成 `-`（"雷离目标多远"完全不可知）
                        --   实机取证：`safe_engine;entity=623;target=nil;r=-;…;ok=FAIL;
                        --   why=…explosion already` + `safe_engine_exploded;entity=623;
                        --   dist=-;pushed=-`，而那一刻玩家离雷只有 4.49~5.76 m
                        --   —— 正是最需要取消/推离的一类，却因为 r 未知而**两个机制都够不着**。
                        --   ⇒ 多付一次 TargetData 读（与源① 同量级），换回 r 与两条诊断。
                        local ok4,p4=pcall(function()
                            local d=TargetData.new(read,base,env.exe)
                            local me=d.entity(match.id)
                            return me and d.position(me)
                        end)
                        if ok4 and p4 then
                            P.hit[match.id]=p4
                            local dx,dy,dz=p4[1]-c[1],p4[2]-c[2],p4[3]-c[3]
                            r=math.sqrt(dx*dx+dy*dy+dz*dz)
                        end
                    end
                end
                if not c then
                    local lp=P.tpos[match.id]
                    if lp then c=lp;csrc='last' end
                end
                -- ★ 没有圆心 ⇒ 没有执行者 ⇒ **不许静默**（本项目的老毛病：
                --   诊断被节流掉 = 诊断不存在）。玩家真在圈内的那些帧累加，
                --   连续 ≥30 帧（0.5 s）还没有任何圆心就打一条，每颗只打一次。
                if not c then
                    local n=(P.noexec[match.id] or 0)+1
                    P.noexec[match.id]=n
                    if n>=30 and not P.noexec_warn[match.id] then
                        P.noexec_warn[match.id]=true
                        env.emit('safe_noexec;entity='..match.id
                            ..';reason=NO_CENTER'
                            ..';tid='..tostring(tid)
                            ..';sel='..tostring(match.selection_id)
                            ..';flag='..tostring(match.selection_flag)
                            ..';state='..tostring(match.state)
                            ..';frames='..tostring(n)..';frame='..frame)
                    end
                    return
                end
                P.noexec[match.id]=nil
                -- ★ "雷在哪"独立于圆心（2026-10-10 补）：这一帧读不到位置时，
                --   用上一次读到的位置算 r —— 否则 r=nil 会让 `need_write` 恒真、
                --   每帧都重写（capture 变贵），且 `pushed=` 诊断失去意义。
                if not r then
                    local hp=P.hit[match.id]
                    if hp then
                        local dx,dy,dz=hp[1]-c[1],hp[2]-c[2],hp[3]-c[3]
                        r=math.sqrt(dx*dx+dy*dy+dz*dz)
                    end
                end
                local Rm=tonumber(env.blast_safe_orbit) or 5.0
                if Rm<2 then Rm=2 elseif Rm>20 then Rm=20 end
                if Rm<3.5 then Rm=3.5 end    -- 硬下限：实测引信 ~2.2 m + 余量
                -- 太近（比设定半径近 0.5 m 以上）⇒ **必须写**（往外推），
                -- 否则只要我们的点还在，就一帧都不用写。
                local need_write=(r==nil) or (r<Rm-0.5)
                -- ★★ 贴脸取消（用户拍板 2026-10-10，默认关）★★
                --   ⚠⚠ **实测这条取消防不了爆**（2026-10-10 三次实机）：
                --     `native_disposal` 的移除只对"**寿命已到期**"的雷兑现（那句
                --     `disposal before expiry` 是**功能性前提**，不是策略守门）⇒
                --     `safe_cancel;` 返回成功之后，同一颗雷（id 未复用）还活了
                --     **323 / 430 / 353 帧**（528/577/683，期间引擎还在换目标）；
                --     另外 4 例"取消后 1~6 帧消失"其实是被引擎炸了，不是被移除。
                --     ⇒ 保留它只为取证（用户拍板：先留着当实验，默认关）。
                --   为什么必须有这一条：实机三次取证（**1.76 / 2.22 / 2.25 m**）证明引擎的
                --   引信是**物理接近目标** ⇒ 手雷一旦贴到目标身上，任何"改航向"都救不回来
                --   （entity=507：我们能看见它的第一帧就已经 `r=1.76`，2 帧后引擎点火）。
                --   那一刻只有两种结局：「炸」（你和目标在同一个爆炸球里 ⇒ 你挨炸）或
                --   「取消」（不爆炸 ⇒ 敌人也不掉血，这一发白扔）。用户选了取消。
                --   三个条件**同时**成立才取消（范围收得很紧）：
                --     ① 玩家在这颗雷的安全半径内（上面那道门已经判过 ✔）
                --     ② 雷已经贴到目标：`r <= 3.5`（**按实机标定**，见下）
                --     ③ **目标也在玩家的危险半径内** ⇒ 这一炸必然会打到你
                --        （危险距离就用同一个 `blast_safe_radius`，只保留一个口径）
                --   ⚠ 阈值 2.8 → **3.5**（2026-10-10 第二次实机标定）：
                --     「贴脸往敌人身上丢」的落点实测落在 **2.5~3.0 m** 这一带，而引擎引信
                --     在 ~2.25 m 点火 ⇒ 2.8 太贴：entity=584 在**唯一能动手的那一帧**
                --     `r=2.99`，只高 0.19 m 就漏过取消，16 秒后引擎在别处把它点了火
                --     （`safe_engine_exploded;target=532;dist=35.39` —— 它撞到了**另一个**
                --     目标，而我们的判据只看"离记录里的目标多远"，看不见这种）。
                --     3.5 m 覆盖整个贴脸带，同时仍在"推离能救回来"的范围之外（≥4 m 时不取消）。
                --   ⚠ 用**独立**的 disposal 实例（见 disposal_cancel 的说明）：
                --     取消失败只关掉取消，不许连累寿命回收。
                if disposal_cancel and c and r and mysp and env.blast_safe_cancel==true
                    and P.ehc[match.id]~='done' and r<=cthr then
                    local px,py,pz=mysp[1]-c[1],mysp[2]-c[2],mysp[3]-c[3]
                    local pt=math.sqrt(px*px+py*py+pz*pz)
                    -- ★★ 危险距离用**玩家↔手雷**，不用玩家↔目标 ★★
                    --   2026-10-10 用户纠正原话：「安全区是以手雷为中心，不是以玩家为中心」。
                    --   原来第 3 个条件算的是 `pt`（最近玩家 ↔ **目标**）—— 那是"以目标为中心"，
                    --   与安全区的口径不一致（爆炸发生在**手雷**那里，不在目标原点）。
                    --   ⇒ 改用门已经算好的 `pdist`（|手雷 − 最近玩家|），与 `blast_hold;
                    --   player_dist=` **同一个数** ⇒ 判据与日志口径统一、可互相核对。
                    --   `pt` 仍打进日志（`player_target=`）当参考，但**不参与判据**。
                    --   上限仍是 7 m（实测致死上界 6.47 m + 余量），且受安全区半径约束。
                    --   ⚠ 用**字面量 + 夹取**而不是新增 local：tick 的 xpcall 已正好 60 upvalue，
                    --     多一个 local 会让整份 chunk 编译失败（2026-10-10 刚栽过）。
                    local danger=tonumber(env.blast_safe_radius) or 0
                    if danger>7 then danger=7 end
                    if pdist and pdist<=danger then
                        local already=P.ehc[match.id]
                        local okd,dres,dwhy=pcall(disposal_cancel.step,disposal_cancel,match,
                            jobs_ready,{early_cancel=true})
                        if okd and dres then
                            P.ehc[match.id]='done'
                            P.ehf[match.id]=frame
                            if already~='done' then
                                env.emit('safe_cancel;entity='..match.id
                                    ..';target='..tostring(tid)
                                    ..';r='..string.format('%.2f',r)
                                    -- ★ 2026-10-10 用户纠正口径：判据是**玩家↔手雷**
                                    --   （`player_dist=`，与 blast_hold 同一个数），
                                    --   `player_target=`（玩家↔目标）只作参考、不参与判据。
                                    ..';player_dist='..string.format('%.2f',pdist)
                                    ..';player_target='..string.format('%.2f',pt)
                                    -- ⚠ 把**生效的**阈值也打出来：否则"到底装的哪一版 /
                                    --   菜单调成多少"在日志里查不出来。
                                    ..';thr='..string.format('%.1f',cthr)
                                    ..';frame='..frame)
                            end
                            -- ★★★ 取消成功**不等于**它马上消失（2026-10-10 实机教训）★★★
                            --   `native_disposal` 的原话：「Native removal either sends the
                            --   normal removal RPC or appends the entity index to this existing
                            --   queue; **it does not delete inline**」⇒ 实体还会活几帧。
                            --   而引擎的引信在这期间**照样能点火** —— 实机现场：
                            --     `safe_cancel;entity=512;r=3.49;frame=9286`（取消成功）
                            --     `safe_engine_exploded;entity=512;dist=2.51;frame=9310`
                            --     （**24 帧后**仍在 2.51 m 处被点火：3.49 → 2.51 说明它飞进去了）
                            --   原因：第一版取消后**直接 return** ⇒ 我们停止推离 ⇒ 它自己飞进引信范围。
                            --   ⇒ 取消后**继续压制**（不 return，落到 ④ 照常写推离点），
                            --     直到实体真的从 matches 里消失。
                            P.ehq[match.id]=nil
                        else
                            -- 失败：留证据（一次）并**允许重试**（可能是瞬时 busy）
                            P.ehc[match.id]='fail'
                            if already==nil then
                                env.emit('safe_cancel_failed;entity='..match.id
                                    ..';detail='..tostring(okd and dwhy or dres):sub(1,110)
                                    ..';frame='..frame)
                            end
                        end
                    end
                end
                -- ★★★ 冗余第四层：**清掉引擎的选择**（2026-10-10，用户拍板"做成一个开关"）★★★
                --
                --   原理与前三层**不同**（前三层都是"给这颗雷换一个航向点"）：这里是把
                --   引擎**选中要撞的那个目标**清掉 ⇒ 引信没有可撞的对象。用户原话：
                --   「玩家在圈内且雷已贴到 cthr 以内时，清掉引擎的选择。这个我感觉可以
                --     做成一个开关功能」。
                --
                --   走的是**已审查的**清选择路径 `run_veto`（同一条路 friendly_lock /
                --   运输船过滤在用，不是新写的写内存通道）。
                --   ⚠ **边界（必须先说清楚）**：`run_veto` 内部是 `SelectionVeto.plan`，
                --     它**必须有 resource 才能判**（第 23 行：不在排除表、又在白名单里 ⇒
                --     keep）。而本局 10 例失败现场**全是点式选择**（`sel_probe` 的
                --     `4|0|1|nil`：id=0、resource=nil）⇒ 这条路对它们**不生效**，
                --     那一类由上面的"圆心三源"（把我们自己的点写进去）负责。
                --   ⇒ 两类各自可见：能清的打 `safe_veto;`，点式的打 `safe_veto_point;`
                --     （一次一颗）—— 这样"开关开了到底帮上了哪一类"在日志里能直接数出来。
                --   ⚠ **每帧清**：引擎下一帧就会重新锁上（本局 `safe_engine_lost` 9 次
                --     就是证据）⇒ 只在贴脸窗口（r<=cthr）里逐帧清。`run_veto` 传
                --     quiet=true（否则 `enemy_veto;` 逐帧刷屏），证据行由这里打一次。
                if env.safe_zone_veto_selection==true and c and r and r<=cthr then
                    -- ★★★ 用户要求（2026-10-10）：「清掉引擎的选择**是否可以只应用在
                    --   无标记的情况下**」⇒ 显式再判一次"玩家有没有表达意图" ★★★
                    --
                    --   为什么不能只靠 `gate.drive`：它**确实**覆盖了绝大多数情况
                    --   （`take_gate.decide` 第 84 行：`structure_mark` 或
                    --   `old.lock/titan/point` 或 `point_armed` 任一为真 ⇒ drive=true），
                    --   但有**两条 edge case 会漏** —— 那两条也返回 drive=false：
                    --     · `engine_owns_it`（`native_update_eligible==false`，引擎已交给
                    --       原生更新）
                    --     · `quarantined`（我们被引擎抢写过、已交回原生；而且隔离时会把
                    --       `old.lock/titan/point` 清空 ⇒ `safe_path_open` 反而成立）
                    --   ⇒ 那两种情况下引擎这条路会跑，**哪怕玩家确实标记了东西**。
                    --   ⇒ 这里把不变式钉死：**安全区只碰"玩家没有表达意图"的雷**。
                    --   三源都算"意图"：结构/通用标记、ping 到的单位、TTL 内的空地点。
                    --   ⚠ 跳过也必须可见（否则"开了没效果"与"有标记所以不该清"分不开）。
                    local has_mark=(structure_mark~=nil) or (mark~=nil) or (point_armed==true)
                    if has_mark then
                        if not P.evp[match.id] then
                            P.evp[match.id]=true
                            env.emit('safe_veto_skip;entity='..match.id
                                ..';reason=HAS_MARK'
                                ..';structure_mark='..tostring(structure_mark
                                    and structure_mark.id or '-')
                                ..';unit_mark='..tostring(mark and (mark.id or 'yes') or '-')
                                ..';point_armed='..tostring(point_armed==true or false)
                                ..';r='..string.format('%.2f',r)
                                ..';thr='..string.format('%.1f',cthr)
                                ..';frame='..frame)
                        end
                    elseif match.selection_id~=0 and match.selection_resource then
                        local vk,vw=run_veto(match,match.selection_resource,'safe_zone',
                            P.evv[match.id]~=nil,runner.safe_veto_runner)
                        if not P.evv[match.id] then
                            P.evv[match.id]=true
                            env.emit('safe_veto;entity='..match.id
                                ..';resource='..tostring(match.selection_resource)
                                ..';r='..string.format('%.2f',r)
                                ..';thr='..string.format('%.1f',cthr)
                                ..';result='..tostring(vk)..';why='..tostring(vw)
                                ..';frame='..frame)
                        end
                    elseif not P.evp[match.id] then
                        P.evp[match.id]=true
                        env.emit('safe_veto_skip;entity='..match.id
                            ..';reason=POINT_SELECTION_HAS_NO_RESOURCE'
                            ..';r='..string.format('%.2f',r)
                            ..';thr='..string.format('%.1f',cthr)
                            ..';frame='..frame)
                    end
                end
                -- ③ 我们的点还在记录里吗？**不付 capture**：直接比对那 12 字节
                --   （`selection_flag==1` + `selection_id==0` = 记录里是"点"而不是实体）
                if rec and not need_write then
                    local rb=match.record_bytes
                    if match.selection_id==0 and match.selection_flag==1
                        and rb and rb:sub(0x1d,0x28)==rec.bytes then
                        if (frame-rec.frame)>=30 and not P.ehk[match.id] then
                            P.ehk[match.id]=true
                            env.emit('safe_engine_kept;entity='..match.id
                                ..';frames='..tostring(frame-rec.frame)..';frame='..frame)
                        end
                        return
                    end
                    if match.selection_id==0 and match.selection_flag==0 then
                        -- 引擎把选择释放了（flag=0）⇒ 当前没有目标可撞，**不危险**；
                        --   状态留着：它以后再锁上，我们下一帧就再压。
                        return
                    end
                    env.emit('safe_engine_lost;entity='..match.id
                        ..';sel='..tostring(match.selection_id)
                        ..';flag='..tostring(match.selection_flag)
                        ..';held_for='..tostring(frame-rec.frame)..';frame='..frame)
                end
                -- ④ 需要写：capture + 把瞄准点推到目标外围（与已接管路径**同一套写法**）
                local ref={id=tostring(match.id),generation='safezone-'..match.id,
                    scene='experimental-session'}
                current={ref=ref,match=match}
                local okz,zres,zwhy=pcall(with_observation,ref,function(scope)
                    if not c then return {kind='no_center'} end
                    local R=Rm
                    if r and r<Rm-0.5 then
                        R=r+2.5                      -- 命令它往外飞（追杀曲线切不进来）
                        if R<Rm then R=Rm end
                        if R>20 then R=20 end
                    end
                    local ang=frame*0.01
                    local ox,oy=c[1]+R*math.cos(ang),c[2]+R*math.sin(ang)
                    -- ⚠ `early=true` 必须带上：arrival 内部失败时**不许**永久禁用整段
                    --   （我们写的是**非自有** G-60，竞争概率比自有路径高得多）。
                    return arrival:step(scope,nil,nil,'vanilla',false,nil,nil,
                        {region=env.point_arrival_region,point=true,
                         point_target={ox,oy,c[3]+1.0},early=true})
                end)
                current=nil
                if not P.ehp[match.id] then
                    P.ehp[match.id]=true
                    env.emit('safe_engine;entity='..match.id
                        ..';target='..tostring(match.selection_id~=0
                            and match.selection_id or tid)
                        ..';r='..(r and string.format('%.2f',r) or '-')
                        ..';radius='..string.format('%.1f',Rm)
                        ..';thr='..string.format('%.1f',cthr)
                        ..';ok='..tostring(okz and zres and zres.kind or 'FAIL')
                        ..';detail='..tostring(okz and (zres and (zres.kind or '-') or '-')
                            or zres):sub(1,110)
                        -- ★ 2026-10-10 补：写失败时**必须知道原因**。
                        --   实机 entity=507 那一条只打了 `ok=FAIL;detail=-` —— 因为
                        --   `arrival:step` 失败时返回 `(nil, 原因)`，而原因在**第二个**
                        --   返回值上，我原来把它丢了 ⇒ 只留下一个 "FAIL" 无法归因。
                        --   （已知唯一能返回 nil 的入口是 `if disabled or busy` ⇒
                        --     `ARRIVAL_DISABLED`；这条字段下次直接把名字打出来。）
                        ..';why='..tostring(zwhy):sub(1,60)
                        ..';frame='..frame)
                end
                if okz and zres and zres.kind=='guide' and zres.point_bytes then
                    P.ehq[match.id]={bytes=zres.point_bytes,frame=frame,fp=fp,tid=tid}
                    -- ★★ "谁写了谁负责"（2026-10-10，用户拍板"按建议做"）★★
                    --   实机事故（entity=508，帧 11426~11432）：安全区这一帧写成功
                    --   （`safe_engine;…;ok=guide`）之后，**同一帧**点目标驱动那条路
                    --   拿着"写之前"的观测去调原生 ⇒ `native_search_context.lua:101` 的
                    --   assert 判 `stale observation` ⇒ 连续 4 帧 `skipped;` 白烧。
                    --   ⇒ 记下"本帧这条雷已由安全区写点"，让点目标驱动**这一帧让位**
                    --     （见 point_drive 的条件）。不跨帧保留 ⇒ 不影响下帧正常驱动。
                    P.szw[match.id]=frame
                end
            end
            -- ★ 开关 + 半径 >0 才算"打开"。关着时**一次都不调用** run_safe_hold
            --   ⇒ 不开这个开关 = 与改动前逐字节一致，且**零额外读取**（perf 门盯着）。
            local safe_engine_hold=env.safe_zone_engine_hold==true
                and (tonumber(env.blast_safe_radius) or 0)>0
            for _,m in ipairs(observed.matches) do
                local retired_key=m.identity_bytes..m.flight_start
                -- ★★ 爆炸已触发 ⇒ 视为"完成"（2026-09-29）★★
                --
                -- explosive_context.lua 的两条 assert：
                --   'explosion already requested' / 'secondary explosion pending'
                -- 语义**不是出错**，而是"这颗 G-60 的爆炸已经触发了" ——
                -- 实体还没被引擎移除，但爆炸已发生。旧代码当错误处理 ⇒
                -- 永不标记 retired ⇒ 实体留在 tracked 里被逐帧重试 ⇒
                -- 玩家看到"G-60 长时间盘旋"，直到寿命耗尽。
                --
                -- 抽成 helper 是因为 `arrival_skipped` 有**两个**发射点
                -- （disposal 段 328 行 / arrival 段 727 行）。我第一版只改了后者，
                -- 实机 entity=1205 走的正是前者 ⇒ 修复没生效（arrival_already_exploded=0）。
                -- **同一个判断出现两处，就是我今天反复踩的那类坑。**
                -- ★★ 标定：把这颗手雷**实际在哪炸的**打出来（相对目标原点）★★
                --
                --   这是"**哪一点能稳定拆毁**"的唯一实测依据（2026-10-03，用户要求）：
                --   引擎自己撞进通风口引爆的那次能拆、我们自己下发的那次不能
                --   ⇒ 必须知道两者的**实际偏移**差在哪。
                --   `via=arrival` = 本 mod 调的 explode；`via=engine` = 引擎的撞击/引信。
                --   ⚠ 每颗 G-60 只打一条（`P.hl` 去重）。
                --
                --   ⚠⚠ 必须定义在 `note_already_exploded` **之前**：
                --     Lua 的 `local function` 只在**定义点之后**可见 ——
                --     写在后面时，`note_already_exploded` 里的调用会解析成**全局 nil**
                --     ⇒ 运行时 `attempt to call a nil value`（本项目踩过同类事故，
                --       见 tests/test_lua_upvalue_order.py 的说明）。
                local function note_blast_hit(via)
                    if not (P.site[m.id] and P.hit[m.id] and P.orig[m.id]) then return end
                    if P.hl[m.id] then return end
                    P.hl[m.id]=true
                    local v,o=P.hit[m.id],P.orig[m.id]
                    env.emit(string.format(
                        'blast_hit;entity=%s;target=%s;via=%s;own=%.2f,%.2f,%.2f'
                        ..';origin=%.2f,%.2f,%.2f;delta=%.2f,%.2f,%.2f',
                        -- ⚠ 目标 id 取自 **P.site**（建爆点时写进去的）。
                        --   原来写 `old and old.lock and old.lock.id` —— 而 `old` 是
                        --   下面那段循环里的局部量，在这个 `local function` 里**不可见**
                        --   ⇒ 解析成全局 nil ⇒ 实机 14 条全是 `target=-`，白丢一轮标定数据。
                        --   （本项目的老毛病：诊断字段看着有、其实永远是占位值。）
                        tostring(m.id),tostring(P.site[m.id] or '-'),via,
                        v[1],v[2],v[3],o[1],o[2],o[3],
                        v[1]-o[1],v[2]-o[2],v[3]-o[3]))
                end
                local function note_already_exploded(why)
                    local s=tostring(why)
                    if not (s:find('explosion already requested',1,true)
                            or s:find('secondary explosion pending',1,true)) then
                        return false
                    end
                    -- ★★ 2026-10-10 关键探针（用户拍板）：**引擎引爆时手雷离目标多远？** ★★
                    --   要回答的问题：引擎的引爆判据是「接近目标」还是「一锁定就请求」？
                    --     · 若距离**很近**（几米内）⇒ 是距离触发 ⇒ **绕行方案可行**
                    --       （不靠近就不炸；而且寿命到期只是静默移除、不爆 —— 用户已确认）
                    --     · 若距离**很远** ⇒ 是"锁定即请求" ⇒ 绕行也没用，得换思路
                    --   ⚠ 纯只读，不改行为。只在**第一次**判定爆炸时打（按手雷去重）。
                    if not P.explprobe then P.explprobe={} end
                    if not P.explprobe[m.id] then
                        P.explprobe[m.id]=true
                        local okp,info=pcall(function()
                            -- ⚠⚠ 这里**不能用** `scope` / `old`（2026-10-10 实机事故）★★
                            --   本函数定义在 tick 的**匹配循环**里，而 `scope` 是
                            --   `with_observation` 回调的**形参**、`old` 是 priority 段里的
                            --   局部量 —— 两者在这个作用域里都**不可见** ⇒ 解析成**全局 nil**
                            --   ⇒ 第一版探针实机直接崩在 `attempt to index global 'scope'`
                            --     （只打出 state/age，距离那一半全丢，白丢一轮）。
                            --   （本项目同一类事故的第 N 次 —— 见 note_blast_hit 处的说明。）
                            --   ⇒ 只许用这里真正可见的：`m` / `P`。位置一律取**已经存好的**：
                            --       `P.hit`  = 这颗手雷最后一次已知位置（arrival 段免费取的）
                            --       `P.tpos` = 绕行圆心（= 目标位置，只在安全区生效期间存在）
                            --       `P.orig` = 体内爆点的目标原点
                            local v,o=P.hit[m.id],P.tpos[m.id] or P.orig[m.id]
                            local d='dist=-'
                            if v and o then
                                local dx,dy,dz=v[1]-o[1],v[2]-o[2],v[3]-o[3]
                                d=string.format('dist=%.2f;horiz=%.2f;dz=%.2f',
                                    math.sqrt(dx*dx+dy*dy+dz*dz),math.sqrt(dx*dx+dy*dy),dz)
                            end
                            return d..';detour='..(P.dg[m.id] and 'on' or '-')
                                ..';own='..(v and string.format('%.1f,%.1f,%.1f',v[1],v[2],v[3]) or '-')
                                ..';gp='..(o and string.format('%.1f,%.1f,%.1f',o[1],o[2],o[3]) or '-')
                        end)
                        env.emit('engine_explode_probe;entity='..m.id
                            ..';state='..tostring(m.state)
                            ..';age='..tostring(ArrivalPolicy.elapsed(time,m.flight_start))
                            ..';'..tostring(okp and info or ('ERR:'..tostring(info):sub(1,90))))
                    end
                    retired[m.id]=retired_key
                    release_hold(m.id)
                    env.emit('arrival_already_exploded;entity='..m.id
                        ..';detail=EXPLOSIVE_ALREADY_TRIGGERED')
                    note_blast_hit('engine')
                    return true
                end
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
                        -- ★ 必须同步清持有（2026-09-27 实机事故的直接修复）
                        --   只写 retired 却把 tracked[id].lock/titan 留在原地：
                        --   虫洞实体 id 被引擎复用后，残留锁会把选择写到**另一个**
                        --   实体上，写后回读必然不符 —— 正是 131→132 那次
                        --   "priority setter target mismatch" 的直接时序。
                        release_hold(m.id)
                        -- ★ 失败终点（2026-09-28）：这是**失败样本**唯一的数据来源。
                        -- native_disposal 只 remove 不 explode（见该文件第 1 行），
                        -- 所以每一条 arrival_retired 都是一次**真失败**。
                        -- probe 是 priority 锁定那帧记下的接管时机画像
                        -- （见 native_priority 的 takeover_probe）—— 失败实体也可能
                        -- 锁定过，把那份距离带过来，就能和成功样本直接对比。
                        local probe=Priority.probe_by_entity[m.id]
                        env.emit('arrival_retired;entity='..m.id..';delivery='..result.delivery
                            ..';target='..tostring(held and held.id or (structure_mark and structure_mark.id) or '-')
                            ..';held='..tostring(held and (held.marked_structure and 'mark' or 'sticky') or '-')
                            ..';state='..tostring(m.state)
                            ..';at_lock='..tostring(probe or 'no_lock'))
                    else
                        local why=tostring(reason)
                        env.emit('arrival_skipped;entity='..m.id..';detail='..why)
                        note_already_exploded(why)
                    end
                    if disposal:disabled() then self.disabled=true;error('disposal operation disabled') end
                end
                if tracked[m.id] and m.behavior_id==4 and m.state==4 and not m.native_update_eligible
                    and tracked[m.id].fingerprint==m.identity_bytes..m.flight_start then seen[m.id]=true end
                if m.behavior_id==4 and m.state==4 then diag.state4=diag.state4+1 end
                if m.behavior_id==4 and m.state==4 and m.native_update_eligible then diag.eligible=diag.eligible+1 end
                -- ★ state-3 接管实验：state 3 也放行，但只走 priority（设置目标），
                --   后面的 titan 航点 / arrival 引爆仍要求 state 4（见下方两处门控）。
                --   一旦观测到 flight timer 被动，state3_blocked 永久置起（见失败分支）。
                -- ★ 早期接管：state 2/3 也驱动（只设目标）。
                --   之前只认 state==3，而实机日志里 G-60 是 1→2→4 一闪而过、
                --   采不到 state 3 ⇒ 实验压根没机会跑（用户"仍需敌人在附近"）。
                --   门槛：至少飞够 EARLY_MIN_AGE 帧才碰它 —— 刚出膛那几帧
                --   movement 还没建立，此时写入风险最高（游戏崩过一次）。
                --   state 5 是过期/待回收，也不碰。
                -- ★★★ 早期导航探测（2026-10-01，用户要求"无敌人时也能炸虫洞"）★★★
                --
                -- 目的：回答一个**纯观测**问题 —— G-60 停在 state 2/3（附近无敌人、
                --   引擎没给它目标）时，我们**能不能拿到它的 movement 组件地址**？
                --
                -- 为什么这是分水岭：
                --   · **已实测否掉**的路：state 2/3 用 **setter**（`calls.clear` 设目标）——
                --     v1 实体模式 / v2 点目标模式两轮实验：写入回读一致，但 G-60 行为不变
                --     （停在 state 3 上千帧）⇒ state 2/3 的导航**不读 selection**。
                --   · **还没试过、原理不同**的路：`calls.orbit` —— 它直接写
                --     `movement+0x60`（导航目的地），**不经过 selection**；在 state 4 已被
                --     证明有效（native_minimal 的搜索链路断言 destination 变化）。
                --   · 而 orbit 需要 `pair={entity,state}` 与 movement 地址，**全部来自
                --     `Search.capture`** ⇒ 它能否在早期 state 跑成功，就是分水岭。
                --
                -- 本段特性（三条都很重要）：
                --   ① **纯只读** —— 只有 `env.early_nav_orbit=true` 时才多调一次 orbit；
                --   ② **独立于 take_gate** —— 不碰 allow_state3，不改变任何现有行为
                --      （打开 allow_state3 的已知副作用是 priority 早期 setter 每帧
                --        `pointer bound`，这里完全不走那条路）；
                --   ③ 按 `flight_start` 去重 ⇒ 每颗 G-60 只探一次，不刷屏。
                --   ⚠ 传 `allow_early_state=true` 是**必须的**：否则 capture 会以
                --     'not active state-4 G60' 直接拒绝，那样就分不清"策略拒绝"与
                --     "结构未就绪"了 —— 而后者才是我们要测的。
                if env.early_nav_probe and env.emit and m.behavior_id==4
                    and (m.state==2 or m.state==3) then
                    P.probe=P.probe or {}
                    local pk=m.identity_bytes..m.flight_start
                    if not P.probe[pk] then
                        P.probe[pk]=true
                        local ok_c,cap=pcall(Search.capture,read,base,m,env.engine,
                            {matches={},allow_early_state=true})
                        if not ok_c or type(cap)~='table' then
                            -- 失败原因本身就是证据：
                            --   'missing movement component' ⇒ 早期还没建 movement（mod 侧无解）
                            --   'pointer bound' / 'read bound' ⇒ 结构未就绪
                            --   'native update excluded'      ⇒ 该位为 1（引擎在原生更新）
                            env.emit('early_nav_probe;entity='..m.id..';state='..m.state
                                ..';result=CAPTURE_FAILED;detail='..tostring(cap))
                        else
                            local buf=ffi.new('uint8_t[12]',cap.movement_bytes:sub(0x61,0x6c))
                            local f=ffi.cast('float *',buf)
                            local before=string.format('%.2f,%.2f,%.2f',f[0],f[1],f[2])
                            env.emit('early_nav_probe;entity='..m.id..';state='..m.state
                                ..';result=OK;movement='..string.format('%x',cap.movement_address)
                                ..';path_agent='..tostring(cap.path_agent_present)
                                ..';dest='..before)
                            -- 第二阶段（2026-10-01 用户拍板开启）：用引擎**自己的**
                            --   `orbit` 试写导航目的地 —— 这是本工程唯一的写途径
                            --   （mod 只绑了**读**内存的 API，**没有任何写内存的 API** —— 写一律走引擎函数）。
                            --   回读三件事：destination 是否变化、**path_agent 是否从
                            --   0xffffffff 变成有效值**（后者才是"引擎真的开始导航"
                            --   的信号）、以及调用是否抛错。
                            if env.early_nav_orbit and env.calls and env.calls.orbit then
                                local pair=ffi.new('void *[2]',
                                    {ffi.cast('void *',cap.entity_address),
                                     ffi.cast('void *',cap.state_address)})
                                local ok_o,why=pcall(function()
                                    env.calls.orbit(pair,10.0,2.5,1.2000000476837158)
                                end)
                                local after,agent_after='nil','nil'
                                if ok_o then
                                    local ok_r,raw=pcall(read,cap.movement_address+0x60,12)
                                    if ok_r then
                                        local b2=ffi.new('uint8_t[12]',raw)
                                        local f2=ffi.cast('float *',b2)
                                        after=string.format('%.2f,%.2f,%.2f',f2[0],f2[1],f2[2])
                                    end
                                    local ok_p,pa=pcall(read,cap.movement_address+8,4)
                                    if ok_p then
                                        agent_after=tostring(Layout.u32(pa,0)~=0xffffffff)
                                    end
                                end
                                env.emit('early_nav_orbit;entity='..m.id..';state='..m.state
                                    ..';ok='..tostring(ok_o)..';why='..tostring(why)
                                    ..';before='..before..';after='..after
                                    ..';changed='..tostring(after~=before)
                                    ..';agent_before='..tostring(cap.path_agent_present)
                                    ..';agent_after='..agent_after)
                            end
                        end
                    end
                end
                local early_fp=m.identity_bytes..m.flight_start
                local drive3=env.allow_state3 and not state3_blocked
                    and (m.state==2 or m.state==3)
                    and (state_age[early_fp] or 0)>=EARLY_MIN_AGE
                if drive3 then diag.state3=diag.state3+1;state3_driven[m.id]=true end
                -- ★ 关键证据：我们只在 state 3 设目标，**从不直接改 state**。
                --   所以如果之后这颗 G-60 出现在 state 4，就证明"设置 selection
                --   能让引擎自己推进到 state 4" —— 这正是"无敌人可锁也能直飞虫洞"
                --   能否成立的分水岭。没有这条日志就说明引擎不理我们的 selection。
                if m.state==4 and state3_driven[m.id] then
                    state3_driven[m.id]=nil
                    env.emit('early_promoted;entity='..m.id..';from='..tostring(m.state)
                        ..';frames='..tostring(state_age[early_fp] or 0))
                end
                if m.behavior_id==4 and (m.state==4 or drive3)
                    and m.native_update_eligible and not retired[m.id] then
                    local old=tracked[m.id]
                    local fingerprint=m.identity_bytes..m.flight_start
                    if old and old.fingerprint~=fingerprint then runner:release(old.ref);old=nil;tracked[m.id]=nil end
                    -- ★★ 点目标失效 ⇒ 释放持有（2026-10-01）★★
                    --   标记被引擎淘汰 / TTL 到期 / 玩家改标记 / 玩家标记了虫洞
                    --   （`point_marker` 为 nil）时，本帧就交回引擎，不再往下写。
                    --   放在门控**之前**：否则这一帧 TakeGate 仍会因 old.point 而放行。
                    --   ⚠ 这里用 `held` 而不是直接写 `old.point=…`：本文件有一条静态检查
                    --     （no_unguarded_old_index）要求**每处 `old.` 引用同行带 nil 守卫**，
                    --     而 `old` 在上面可能是 nil（首次遇到这颗 G-60）。语义完全相同。
                    local held=old
                    if held and held.point and not point_marker then
                        held.point=nil
                        if env.emit then
                            env.emit('point_released;entity='..m.id..';frame='..frame)
                        end
                    end
                    -- ★ 门控判定已抽到 g60.take_gate（纯函数，可真跑测试）★
                    -- 详见那里的说明：重构前这些判断内联在 tick 里，
                    -- 仓库 195 个测试一行都跑不到，于是四轮实机事故
                    -- （nil 索引 / diag 未初始化 / upvalue nil / assert 阻断）
                    -- 全部从测试缝隙溜过去。现在它们进入测试覆盖。
                    -- ★★ 引擎选择否决的判据（2026-09-29）★★
                    --   "引擎确实给这颗 G-60 选了目标，且该资源在排除表里"。
                    --   m.selection_resource 由 native_observer:110 在 selection_flag~=0
                    --   时就读好了 ⇒ **零新增读取**。
                    --   本 mod 认领的实体由上面的接管路径处理；这一支只服务
                    --   "完全不认领"的 G-60（门控放在 take_gate 里，见那里的说明）。
                    local veto_resource=m.selection_flag~=0 and m.selection_resource or nil
                    --   开关关掉时直接用 false ⇒ 门控回到 no_mark_no_hold ⇒ 敌人侧
                    --   完全原生（连只读诊断都还会打，但带 vetoed=false，便于确认）。
                    local veto_selected=env.enemy_veto_enabled~=false and veto_resource~=nil
                        and Filter.excluded(veto_resource)
                    -- 只读诊断：每出现一个新"引擎选择"打一条。
                    --   这是**验证身份**用的 —— 用户给的哈希能不能确认是运输船，
                    --   就看追运输船时这里有没有出现它。
                    --   必须进日志节流白名单（诊断被节流掉 = 诊断不存在）。
                    if m.behavior_id==4 and m.state==4 and veto_resource
                        and not veto_seen[veto_resource] and env.emit then
                        veto_seen[veto_resource]=true
                        env.emit('enemy_selection;entity='..m.id..';resource='..veto_resource
                            ..';vetoed='..tostring(veto_selected))
                    end
                    -- ★★ 2026-10-09：TTL 内的一次 ping = **玩家明确意图** ★★
                    --   与"标记"同级，必须能让门控放行。不加这一项时"纯空地 ping"
                    --   永远落到 `no_mark_no_hold` ⇒ 不建 `old` ⇒ ping 路整条不跑
                    --   （用户报「空标记应用失败，无效」的根因）。
                    local ping_take=point_marker~=nil and point_armed==true
                    local gate=TakeGate.decide{
                        behavior_id=m.behavior_id,state=m.state,
                        native_update_eligible=m.native_update_eligible,
                        retired=retired[m.id]~=nil,old=old,
                        structure_mark=structure_mark,allow_early=drive3,
                        selection_vetoed=veto_selected,
                        state_age=state_age[early_fp] or 0,
                        early_min_age=EARLY_MIN_AGE,
                        point_armed=ping_take}
                    if not gate.drive and structure_mark and old then
                        if gate.why=='holding_nothing' or gate.why=='no_mark_no_hold'
                            then diag.held=diag.held+1
                        elseif gate.why=='quarantined' then diag.blocked=diag.blocked+1
                        end
                    end
                    -- ★★ 否决：清掉引擎给这颗**非自有** G-60 选的、我们明确排除的目标 ★★
                    --   （目前只有运输船；见 small_filter 的排除表与 take_gate 的说明）
                    --
                    --   只清不接管 —— 不建 tracked、不设 lock/titan，
                    --   所以 titan / arrival / disposal 三条引导与引爆路径都碰不到它
                    --   （它们一律要求 old.lock 或 old.titan）。这是最小影响面。
                    if gate.veto and not retired[m.id] and runner and not runner:disabled() then
                        run_veto(m,veto_resource,'no_mark')
                    end
                    -- ★★ 2026-10-10 安全区：把"**引擎自己瞄的雷**"也管起来 ★★
                    --   （用户报「没有标记时不生效」—— 根因见 run_safe_hold 的说明）
                    --
                    --   ⚠ 只在**我们不驾驶**这颗雷时才走：`gate.drive` 为真时由上面的
                    --     priority/titan/arrival 三条路负责（绕行也在那里做）——
                    --     两处都写同一颗雷会互相打脸。
                    --   ⚠ `m.selection_id~=0`：引擎确实选了目标。没目标就没得拦，
                    --     而且引擎也不会因为"接近目标"去引爆它。
                    --   ⚠⚠ 但条件必须是"引擎有目标 **或 我们已经压了一个点**"（2026-10-10 修正）★
                    --     第一版只写 `m.selection_id~=0` —— 而我们自己写下去的点会让
                    --     selection_id 变 0 ⇒ **下一帧条件就不成立** ⇒ 整条路只在"引擎
                    --     重新锁上目标"的那几帧才跑（实机：跨度 364 帧只有 5 条 blast_hold）。
                    --     加上 `P.ehq[m.id]` 之后：压制期间**每帧**都在管 —— 每帧只付一次
                    --     便宜的 TargetData 读；我们的点还在记录里就**不重写** ⇒ 不额外 capture。
                    --   ⚠ 我们没持有（`old.lock/titan/point` 全空）才走 —— 这一条是
                    --     上面那条的冗余保险（quarantined 的 old 可能还留着字段）。
                    -- ★★ 冗余第二层（2026-10-10）：把"引擎这条路"的**入口条件放宽** ★★
                    --   原来要求 `m.selection_id~=0`（引擎选中的是**实体**）——
                    --   而实机 7 例失败里，引擎给的全是**点**（`4|0|1|nil`：flag=1、id=0）
                    --   ⇒ 条件不成立 ⇒ `run_safe_hold` 里连圆心都取不到。
                    --   现在改成"引擎**确实选了什么**"（`selection_flag==1`，实体或点都算）。
                    --   ⚠ 仍然保留 `state==4` / `behavior_id==4` / `not gate.drive` /
                    --     `not retired` / 我们没有 lock·titan·point —— 收窄面不变。
                    local safe_path_open=safe_engine_hold and not gate.drive
                        and not (old and (old.lock or old.titan or old.point))
                    if safe_path_open and not retired[m.id]
                        and m.behavior_id==4 and m.state==4
                        and (m.selection_id~=0 or m.selection_flag==1 or P.ehq[m.id]~=nil) then
                        run_safe_hold(m)
                    elseif safe_path_open and P.safehold[m.id]==frame then
                        -- ★★ 冗余第三层：**没有执行者必须可见**（2026-10-10）★★
                        --   门刚判过"玩家在这颗雷的圈内"（`P.safehold` 是本帧盖的），
                        --   而引擎这条路被上面任一条件挡住 ⇒ **这一帧没有任何人在压它**。
                        --   这一类洞正是用户报的"安全区有时候还是会发生引爆"，而它在旧日志里
                        --   **一个字都没有**（诊断被节流掉 = 诊断不存在）。
                        --   ⇒ 连续 ≥30 帧（0.5 s）就报一条，每颗只报一次（不刷屏）。
                        local n=(P.noexec[m.id] or 0)+1
                        P.noexec[m.id]=n
                        if n>=30 and not P.noexec_warn[m.id] then
                            P.noexec_warn[m.id]=true
                            env.emit('safe_noexec;entity='..m.id
                                ..';reason=ENGINE_PATH_GATED'
                                ..';sel='..tostring(m.selection_id)
                                ..';flag='..tostring(m.selection_flag)
                                ..';state='..tostring(m.state)
                                ..';behavior='..tostring(m.behavior_id)
                                ..';retired='..tostring(retired[m.id] and true or false)
                                ..';frames='..tostring(n)..';frame='..frame)
                        end
                    end
                    local abandoned=false
                    local enters=priority~=nil and gate.drive
                    -- ★★ 已爆手雷短路 —— 在**写内存之前**（2026-10-03）★★
                    --
                    -- 实机（13:16 那局）12 次标记**全部**是"锁上即发现已爆"：
                    --   引擎的撞击 / 引信在我们接管之前就把它炸了，实体还要留几帧。
                    --   而我们照样收它 ⇒ 走完整 priority 路径（**含一次 setter 写内存**）
                    --   + 打一条本来不该存在的 `priority_locked`，之后才在 arrival 段
                    --   被 `Explosive.capture` 判成 `explosion already requested`。
                    --
                    -- ⇒ 先只读探一次；已经炸了就按"完成"收尾 —— 与 disposal / arrival /
                    --   引导失败记账共用**同一个** `note_already_exploded`
                    --   （终态：`retired` + `release_hold` + `arrival_already_exploded`）。
                    --
                    -- ⚠ 门控 `not (old and old.lock)`：只在**首次接管**那一帧探。
                    --   已锁定的生存实体每帧走粘性路径，而那时 setter 本来就不写
                    --   （`same_selection` ⇒ 跳过）⇒ 不为它每帧多付一次捕获成本。
                    -- ⚠ 判据用 `arrival:triggered`（= `Explosive.capture` 自己的两条文案），
                    --   **不造轻量判据** —— 假阳性会把一颗健康的手雷提前退休，
                    --   代价远大于现在这点浪费。
                    -- ⚠ 不新增 upvalue：复用已有的 `arrival` / `read`（都已是本函数的 upvalue）
                    --   —— `host:tick` 里那个 pcall 匿名函数的 upvalue 余量已经很紧。
                    --   ⚠ `P.pex` 去重：判过一次就不再重复捕获、也不再重复打日志
                    --     （实机抓到同一颗手雷刷 45 行 —— 见 P 表定义处的根因说明）。
                    --     仍然要把 `enters` 关掉：已爆的手雷**绝不能**被接管写内存。
                    if enters and not retired[m.id] and not (old and old.lock) then
                        if P.pex[m.id] then
                            enters=false
                        else
                            local triggered,why=arrival and arrival:triggered(read,m.identity_bytes)
                            if triggered then
                                P.pex[m.id]=true
                                env.emit('priority_precheck_exploded;entity='..m.id
                                    ..';detail=EXPLOSIVE_ALREADY_TRIGGERED')
                                note_already_exploded(why)
                                enters=false
                            end
                        end
                    end
                    if enters then
                        diag.entered=diag.entered+1
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
                        -- ★ 观测/接管失败熔断（2026-09-28 11:00 实机回归的直接修复）
                        --
                        -- 事故：allow_state3 打开后，日志第 2 行就
                        --     frame_error;pointer bound
                        -- 随后 300+ 帧 `entered=1; locked=0`，priority_locked 一次都没有。
                        -- 原因：with_observation → Search.capture 每帧都失败，
                        -- 而失败只被外层 pcall 吞掉记成 frame_error ——
                        -- **单个 G-60 的观测失败不影响其他实体，所以 mod 不会停手，
                        -- 于是每一帧都重试同一个必然失败的路径，表现为"完全无法接管"**。
                        --
                        -- 处置：同一实体连续失败 OBSERVE_FAIL_LIMIT 次 ⇒
                        -- 放弃它的 tracked 记录并打一行醒目日志。
                        -- 不做全局禁用：其他 G-60 可能观测正常（identity 不同）。
                        if not good then
                            local key=m.id
                            observe_fail[key]=(observe_fail[key] or 0)+1
                            if observe_fail[key]==1 then
                                env.emit('observe_failed;entity='..m.id
                                    ..';detail='..tostring(result))
                            end
                            if observe_fail[key]>=OBSERVE_FAIL_LIMIT then
                                env.emit('observe_give_up;entity='..m.id
                                    ..';after='..observe_fail[key]
                                    ..';detail='..tostring(result))
                                if tracked[m.id] then runner:release(tracked[m.id].ref) end
                                tracked[m.id]=nil
                                observe_fail[key]=nil
                            end
                        else
                            observe_fail[m.id]=nil
                        end
                        -- ★ 早期接管失败（v2 点目标模式）：priority 返回 kind='state3_fail'，
                        --   计入 danger 熔断（连续 STATE3_DANGER_LIMIT 次退回 state-4-only），
                        --   不牵连全局。
                        if good and type(result)=='table' and result.kind=='state3_fail' then
                            state3_danger=state3_danger+1
                            env.emit('state3_danger;entity='..m.id..';count='..state3_danger
                                ..';detail='..tostring(result.detail))
                            if state3_danger>=STATE3_DANGER_LIMIT then
                                state3_blocked=true
                                env.emit('state3_takeover_disabled;entity='..m.id
                                    ..';detail='..tostring(result.detail))
                            end
                            old.lock=nil;old.titan=nil;old.force_search=nil
                            result,good=nil,true
                        end
                        -- ★ state-3 自毁保护：如果这一帧是 state 3 驱动，而失败原因是
                        --   flight timer / behavior / source 变化，说明 state-3 调用真的
                        --   破坏了引擎状态（安全层警告过的那件事）。
                        --   此时**永久退回 state-4-only**，不牵连其余功能。
                        if drive3 and not good and Faults.STATE3_DANGER[tostring(result)] then
                            state3_danger=state3_danger+1
                            env.emit('state3_danger;entity='..m.id..';count='..state3_danger
                                ..';detail='..tostring(result))
                            if state3_danger>=STATE3_DANGER_LIMIT then
                                state3_blocked=true
                                env.emit('state3_takeover_disabled;entity='..m.id
                                    ..';detail='..tostring(result))
                            end
                            if reservations then reservations:release_owner(owner) end
                            old.lock=nil;old.titan=nil;old.force_search=nil
                        end
                        -- 只有**结构性**失败才全局停手；竞争态由 priority 返回
                        -- kind='quarantine' 走下面的分支，只放弃这一颗 G-60。
                        if priority:disabled() and not (good and type(result)=='table'
                            and result.kind=='quarantine') then
                            self.disabled=true;error('priority native operation disabled: '..tostring(reason))
                        end
                        if good and result then
                            if result.kind=='quarantine' then
                                -- ★ 一颗 G-60 放弃：清掉它的锁/航点/预约，本局不再写它。
                                --   其余 G-60 与本局剩余的标记照常接管 —— 上游在这里是
                                --   整个 mod 一起死，实机日志第 132–133 行就是那个后果。
                                old.quarantined=true;old.lock=nil;old.titan=nil;old.force_search=nil
                                old.blocked=nil
                                if reservations then reservations:release_owner(owner) end
                                abandoned=true
                                env.emit('priority_quarantined;entity='..m.id..';detail='..tostring(result.contended))
                                if note_contention() then
                                    self.disabled=true
                                    error('priority contention limit reached: '..tostring(result.contended))
                                end
                            elseif result.kind=='lock' then
                                diag.locked=diag.locked+1
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
                            elseif result.kind=='detonate' and result.early then
                                -- ★ 早期引爆成功（点目标模式 + 到达检测）：
                                --   "无敌人也能炸虫洞"的核心证据。
                                retired[m.id]=retired_key
                                release_hold(m.id)
                                self.applied=self.applied+1
                                env.emit('early_detonated;entity='..m.id..';target='..result.target
                                    ..';distance='..result.distance)
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
                            -- ★ 补上"为什么没锁上"的几何信息（2026-09-28）★
                            -- 过去这行只有 detail 文本，看不出 G-60 当时在哪。
                            -- 实机里 12 次锁定有 8 次没进 titan，必须能区分
                            -- "离虫洞太远来不及" 与 "被门控/预约挡住"，
                            -- 否则只能靠猜。现在附带 state 与剩余寿命。
                            -- 去重：同一颗 G-60 的同一 reason 只打首条
                            -- （逐帧刷屏曾导致过两次误诊）。
                            local sk_reason=tostring(good and reason or result)
                            local sk_key=m.id..'|'..sk_reason
                            if skipped_probe[sk_key]==nil then
                                skipped_probe[sk_key]=true
                                local spent=time>=m.flight_start
                                    and ArrivalPolicy.elapsed(time,m.flight_start) or 0
                                env.emit('priority_skipped;entity='..m.id
                                    ..';detail='..sk_reason
                                    ..';state='..tostring(m.state)
                                    ..';life_left='..tostring(math.max(0,1-spent/ArrivalPolicy.lifetime_ticks)))
                            end
                            if reservations then old.lock=nil;old.force_search=true end
                        end
                    end
                    -- ★★ 兜底 veto（2026-09-30 修复）★★
                    --
                    -- priority 段跑完了 —— 这时才**真正知道**我们有没有接管这颗 G-60。
                    -- 如果**有标记**但**没接管**（标记的是友方 ⇒ NOT_VALID_TARGET、
                    -- 或位置读不到、或超 200m），那么引擎给的"排除表目标"（运输船）
                    -- 就没人清：take_gate 的 veto 分支在结构上被 structure_mark 挡住了。
                    --
                    -- 条件逐条：
                    --   · structure_mark 非 nil —— 为 nil 时走 take_gate 原路径（已覆盖）
                    --   · 未 abandoned —— 已放弃的实体本帧不再写任何东西
                    --   · **没有 lock/titan** —— 持有说明我们正飞向自己的目标，
                    --     此时清选择会破坏自己的锁定（veto 的本意不是这个）
                    --   · 引擎当前选择确实在排除表里
                    --   ★ 2026-10-10 追加（用户第二次报）：引擎当前选择是一个**"不能当
                    --     目标"的单位**（玩家标记了友方）—— 同样必须清掉。实测现象：
                    --     「释放出的手雷会一直锁定标记的友方单位，导致手雷不能被其他代码
                    --      接管」（`selected=true` 会让 ping/点目标那段让位）。
                    --     ⇒ 用**同一套**已审查的"清选择"路径（run_veto），只是理由不同。
                    --   ⚠ `mark_friendly` 是"标记是友方"的本帧旗标 —— 那种情况下
                    --     `structure_mark` 已被置 nil，所以条件里必须带上它。
                    if (structure_mark or mark_friendly) and not abandoned
                        and not (old and (old.lock or old.titan))
                        and env.enemy_veto_enabled~=false
                        and runner and not runner:disabled() then
                        local vr=m.selection_flag~=0 and m.selection_resource or nil
                        local fv=nil
                        if vr and env.friendly_veto_enabled~=false then
                            fv=faction(m.selection_id,vr)
                        end
                        if vr and (Filter.excluded(vr) or fv=='no') then
                            if fv=='no' then
                                local lk='v:'..tostring(m.id)..':'..tostring(m.selection_id)
                                if not P.fkl[lk] then
                                    P.fkl[lk]=true
                                    env.emit('friendly_lock;entity='..m.id
                                        ..';sel='..tostring(m.selection_id)
                                        ..';resource='..tostring(vr)
                                        ..';action=VETO;frame='..frame)
                                end
                                run_veto(m,vr,'friendly_lock')
                            else
                                run_veto(m,vr,'after_priority')
                            end
                        end
                    end
                    local selected=m.selection_flag~=0 and m.selection_id~=Layout.u32(read(base+0x3483c20,4),0)
                    -- ★ 裁剪 A：原上游在此判 excluded —— 被 small_filter 列入的小怪、或不在
                    --   allowlist(泰坦+弱点) 里的敌人，都会触发"清掉引擎选择 + 强制搜索"。
                    --   那是 mod 的"只打指定敌人"行为。恒置 false 后，没有本 mod 认领的
                    --   目标时，G-60 的敌人选择完全交给引擎原生 TargetLock。
                    --   ★ 2026-09-29：认领范围扩到 虫洞 + 吐酸泰坦（见 has_weakpoint）。
                    --     其它敌人（weakpoint_profiles 里那 7 个 head/rear/thorax/
                    --     underside）仍然完全交还引擎。
                    local excluded=false
                    local retry_search=arrival and old and (old.force_search or (old.blocked and not old.lock))
                    if retry_search then old.titan=nil end
                    -- 已放弃(quarantine)的实体本帧不再走任何写入段：本帧 priority 刚写过
                    -- 一次原生 setter，交回引擎时不能又被后面的 titan 段重新写进去。
                    -- ★ 泰坦接管（2026-09-29）
                    --   has_weakpoint 现在也认 titan_profile，所以引擎一旦选中了吐酸泰坦，
                    --   泰坦段就会接管它，把 G-60 引到腹部下方引爆（titan_route RADIUS=12
                    --   与 standoff 都是作者为**泰坦**标定的，与虫洞无关）。
                    --
                    --   `not structure_mark` = 虫洞优先：玩家标记了虫洞时，
                    --   即使引擎选中了泰坦也**不去抢**。
                    --   理由是用户明确的"虫洞优先"，而且虫洞是本 mod 的主要功能；
                    --   泰坦是后来加的附加能力，不该反过来抢主目标。
                    -- ★ 虫洞标记优先于泰坦；但**泰坦标记本身不应阻止泰坦接管** ★
                    -- 原为 `not structure_mark`。一旦标记入口放行泰坦（见 claim_profile），
                    -- 玩家标记泰坦时 structure_mark 就非 nil ⇒ 该条件变 false
                    -- ⇒ 泰坦段永不运行，比"标记被拒"更糟（连引擎自选的机会都没了）。
                    -- 改成只对**虫洞**标记让位。
                    local mark_is_wormhole=structure_mark~=nil and env.structure_profiles~=nil
                        and env.structure_profiles[structure_mark.resource]~=nil
                    -- ★★ 优先级（2026-10-01 用户拍板）★★
                    --   用户定的三档：**虫洞/构筑 > 标记单位 > 空白标记**。
                    --   本处修的是"引擎自选的泰坦/蟑龙 抢走 标记单位"：
                    --   原来只有**虫洞标记**有权力压住泰坦（mark_is_wormhole）⇒
                    --   玩家点名标记了单位、priority 也锁上了，但只要引擎恰好给这颗
                    --   G-60 选中了吐酸泰坦，泰坦段就会覆盖那把锁（标记形同没生效）。
                    --   现在：本 mod 已为它锁定**玩家点名的目标**（old.lock，结构或单位
                    --   都算）⇒ 泰坦让位，由标记目标继续驱动。
                    --   `old.lock` 被释放的条件不变（目标不可用 / 被 quarantine），
                    --   所以这不会让泰坦"永远打不了"。
                    local marked_lock_held=old~=nil and old.lock~=nil
                    -- ★★★ 明确的"ping 地面点"压过**引擎自选**的泰坦（2026-10-05 用户报）★★★
                    --
                    -- 现象（用户原话）：「如果我没标记泰坦，标记了泰坦附近的空地，
                    --   G60 会飞向泰坦而不是飞向空地爆炸」。
                    --
                    -- 根因：`titan_selected`（**引擎自动**给这颗 G-60 选了泰坦）在优先级里
                    --   压住了 ping 点（下面 `point_drive` 有 `and not titan_selected`）
                    --   ⇒ 玩家**明确指定了一个落点**，却被引擎的自动选择否掉。
                    --
                    -- ★ 与 2026-10-01 那条用户裁定**不冲突**：那条是
                    --   「虫洞/构筑 > **标记单位** > 空白标记」，说的是**玩家点名标记的单位**；
                    --   这里的泰坦是**引擎自己挑的**，玩家没点它。两者是不同的事。
                    --
                    -- ⇒ 让位条件（缺一不可）：
                    --   · `point_marker` 非空 **且** `point_armed`（在 TTL 内 = 是新的一次 ping）
                    --   · **不是**玩家点名的那个单位（`m.selection_id==structure_mark.id`）
                    --     —— 玩家点了泰坦本体就该打泰坦；这一条同时避开了
                    --     "长期存活的结构标记把能力挡死"那个老坑（不按"有无标记"判，按"是不是它"判）
                    --   · 不是虫洞标记（虫洞优先级更高，早已由 `mark_is_wormhole` 处理）
                    --   · 这颗 G-60 **还没在跑泰坦航路**（`not (old and old.titan)`）——
                    --     上游原则「已在执行任务的手雷保留其分配」，半路改向等于浪费一颗
                    local mark_is_this_unit=structure_mark~=nil and m.selection_id==structure_mark.id
                    local ping_beats_titan=point_marker~=nil and point_armed==true
                        and not mark_is_wormhole and not mark_is_this_unit
                        and not (old and old.titan)
                    if ping_beats_titan and env.emit and not P.pbt[m.id] then
                        P.pbt[m.id]=true
                        env.emit('point_beats_titan;entity='..m.id
                            ..';titan='..tostring(m.selection_id)
                            ..';slot='..tostring(point_marker.slot)
                            -- ★ 2026-10-10 用户要求：reason 必须与事实一致 ★
                            --   原来恒写 `PLAYER_PING_OVER_ENGINE_SELECTION`，而
                            --   `ping_beats_titan` 的条件（见上面那段）**并不要求引擎有选择**
                            --   ⇒ 实机 4 条 `titan=0`（引擎什么都没选）也写"over engine
                            --   selection" ⇒ 纯误导：判读时会以为"玩家 ping 抢赢了引擎的锁定"。
                            --   ⇒ 按 `titan=` 的实际值分流。
                            --   ⚠ tag 名 `point_beats_titan` **保留不动** —— 它是历史
                            --     grep / 文档 / 白名单的锚点，改名会让旧日志不可比。
                            ..';reason='..(m.selection_id~=0
                                and 'PLAYER_PING_OVER_ENGINE_SELECTION'
                                or 'PLAYER_PING_NO_ENGINE_SELECTION'))
                    end
                    local titan_selected=not abandoned and titan and selected
                        and not retry_search and not mark_is_wormhole and not marked_lock_held
                        and not ping_beats_titan
                        and has_weakpoint(m.selection_resource)
                    -- ★★ 点目标驱动（2026-10-01）★★
                    --   优先级按**每颗 G-60** 判（第一版写成"有结构标记就全局禁用点目标"，
                    --   实机被一个长期存活的结构标记把整个能力挡死 —— 见登记处的说明）：
                    --     ① 这颗 G-60 已被 priority 锁上结构（`old.lock`）⇒ 结构优先，让给结构
                    --     ② **玩家点名标记**的单位（虫洞/标记单位）⇒ 让给它
                    --     ③ 引擎自选的泰坦 —— **只有"没有 armed 的 ping 点"时才优先**
                    --        （2026-10-05：玩家 ping 了落点就听玩家的，见上面 `ping_beats_titan`）
                    --     ④ 其余才轮到 ping 的地面点
                    --   `selected` = 引擎确实给它选了目标（它正在被驱动）；
                    --   `old.point` = 本 mod 已持有 ⇒ 必须继续驱动（否则只写一帧就漂走）。
                    --   · 新接管：需要 `point_armed`（TTL 内）—— 防"顺手 ping 一下"长期劫持
                    --   · 已在引导中的那颗（`old.point`）：**不受 TTL 影响**，继续飞到引爆
                    --
                    -- ★★ 2026-10-09 修正：无敌人时 ping 路有**三道**死锁 ★★
                    --   ⚠ 死锁 1：下面那道 `m.state==4` 门。无敌人时引擎不会置 4（只在
                    --     "候选分数 > 0"时置），而 ping 的是**地面点**、根本不在候选列表里
                    --     ⇒ 整段驱动永远进不去。**第一版把提升写在门里面**（到达段写点之后）
                    --     ⇒ 门永远不开。实机症状完全吻合：ping 到了、`point_marker` 有，
                    --       但一条 `point_taken` 都没有，雷停在 state 3 直到 state 5 过期。
                    --   ⚠ 死锁 2：首次接管要求 `selected`（引擎已给它选了目标）——
                    --     无敌人时引擎没有目标 ⇒ 同样进不去。
                    --   ⚠ 死锁 3（**真正的根因**）：TakeGate 的 `no_mark_no_hold` ——
                    --     纯空地 ping 既无标记、又无旧持有 ⇒ 门控**根本不接管** ⇒
                    --     `old` 永不建立 ⇒ 上面两道门连碰都碰不到。
                    --     ⇒ 已给门控加 `point_armed`（见 take_gate.lua 的说明）。
                    --   ⇒ 对 ping 路放宽成**与结构路同一口径**：TTL 内的 `ping_take`
                    --     就够（不再要求 selected、也不再限定 state 2/3 —— 提升之后
                    --     state 变 4，若还限定 2/3 会让下一帧的驱动分支又选错）。
                    local point_drive=not abandoned and point_marker~=nil
                        and P.szw[m.id]~=frame
                        and not titan_selected and not (old and old.lock)
                        and ((selected and point_armed) or (old and old.point) or ping_take)
                    -- ⚠ `P.szw[m.id]~=frame` = "谁写了谁负责"（2026-10-10）：
                    --   安全区这一帧已经给这条雷写过点 ⇒ 点目标驱动**这一帧让位** ——
                    --   否则它拿"写之前"的观测调原生，会撞 `stale observation`
                    --   （实机 entity=508：连续 4 帧 `skipped;` 白烧）。只判本帧，不跨帧。
                    -- ★★ 先开门、再驱动（必须在下面 `m.state==4` 判断**之前**）★★
                    --   命中「已有观测句柄 + 该驱动 ping 点 + 引擎留在 2/3」⇒ 用 priority 的
                    --   **同一套** promote_state4 打开状态，下一帧 `m.state==4` 才成立。
                    --   ⚠ **必须设 `current`**：`with_observation` 内部断言
                    --     `U.key(ref)==U.key(current.ref)`，不设就抛 `expired observation key`
                    --     ⇒ **整帧后续全部不跑**（2026-10-09 实机栽过：force_lock 0 条 +
                    --       新增一条 frame_error + 驱动段根本没执行）。
                    --     与 priority 段 / run_veto 的用法保持一致（设 current → 调用 → 清）。
                    --   ⚠ promote_state4 自带开关/写前复核/写后回读，失败只记一行、绝不抛异常。
                    if old and point_drive and m.state~=4 and env.force_lock_enabled~=false then
                        current={ref=old.ref,match=m}
                        with_observation(old.ref,function(scope)
                            local o,d=Priority.promote_state4(env,scope,scope.prepared)
                            local fkey='flp:'..tostring(scope.prepared.flight_start)
                                ..':'..tostring(o)
                            if env.emit and not P.flk[fkey] then
                                P.flk[fkey]=true
                                env.emit('force_lock;entity='..m.id..';route=ping_point'
                                    ..';ok='..tostring(o)..';detail='..tostring(d))
                            end
                            return o
                        end)
                        current=nil
                    end
                    -- titan 航点要写 movement 结构；state 3 时它可能还没初始化，
                    -- 所以 state-3 驱动的这一帧不进 titan 段（只让 priority 设目标）。
                    if (not abandoned) and m.state==4
                        and (excluded or titan_selected or point_drive or (old and not selected)) then
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
                            -- ★ 安全区：**必须**在 titan:step 之前判 ——
                            --   它内部会 `calls.explode`，事后拦不住（同 arrival 那条路）。
                            --   玩家在半径内 ⇒ 本帧**不调用** ⇒ 不授权引爆 ⇒ 引擎继续飞。
                            result,status=with_observation(old.ref,function(scope)
                                if not blast_safe_hold(m,scope) then return {kind='safe_hold'} end
                                return titan:step(scope,old.titan)
                            end)
                            if result then
                                local starting=not old.titan or old.titan.cancelled
                                local stage_changed=old.titan and old.titan.route
                                    and result.stage~=old.titan.route.stage
                                -- ★ 安全区拒爆：**保留锁定与航路**，下一帧继续引导
                                --   （清掉的话手雷就放弃目标乱飘了 —— 与 stalled 同一个坑）。
                                if result.kind=='safe_hold' then
                                    self.safe_held=(self.safe_held or 0)+1
                                else
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
                                    release_hold(m.id)
                                    env.emit('arrival_detonated;entity='..m.id..';target='..result.target..';distance='..result.distance
                                        -- ★ 2026-10-02：爆点几何分解（只诊断）——
                                        --   三维 distance 分不清"偏侧"还是"贴脸"，
                                        --   而两者的修法相反（见 native_arrival 处的说明）。
                                        ..';horiz='..tostring(result.horizontal or -1)
                                        ..';dz='..tostring(result.dz or -1))
                                end
                                end   -- /safe_hold 的 else
                            end
                        elseif point_drive then
                            -- ★ 点目标：**本段不写内存** —— 真正的点目标写入在 arrival 段
                            --   （native_arrival 的 `options.point_target`，与泰坦同款写法）。
                            --   这里只做三件事：登记持有 + 交回 runner + 标记"本帧成功"。
                            --
                            --   ★★ 必须给 result 赋值（2026-10-01 实机事故）★★
                            --   分支后面有一段公共的**引导失败熔断**：
                            --       if result then 清零计数 else 记一次失败（fail_count+1）
                            --   第一版没赋值 ⇒ 每帧都被记成失败 ⇒ **30 帧（约 0.5 秒）后
                            --   guide_give_up 把这颗 G-60 退休**，于是在半路停手，
                            --   再也跑不到引爆判定。
                            --   实机日志正是：point_taken → skipped;reason=nil;detail=nil ×30
                            --                 → guide_give_up;after=30（G-60 飞过去了但没炸）。
                            result={kind='point'}
                            old.titan=nil;old.lock=nil
                            local starting=old.point==nil
                            old.point={x=point_marker.x,y=point_marker.y,z=point_marker.z,
                                token=point_marker.token,frame=frame}
                            runner:release(old.ref)
                            if starting and env.emit then
                                env.emit(string.format(
                                    'point_taken;entity=%s;pos=%.2f,%.2f,%.2f;slot=%s;frame=%d',
                                    tostring(m.id),point_marker.x,point_marker.y,point_marker.z,
                                    tostring(point_marker.slot),frame))
                            end
                        else
                            old.titan=nil
                            old.point=nil
                            result,status,detail=runner:step(old.ref)
                        end
                        current=nil
                        if result and result.kind=='search' then
                            self.applied=self.applied+1
                            env.emit('search_applied;entity='..m.id..';selected='..m.selection_id
                                ..';resource='..tostring(m.selection_resource)..';frame='..frame)
                        end
                        -- ★★ 引导失败熔断（2026-09-29）★★
                        --
                        -- 实机：entity=1257 的 titan:step 持续抛 `Titan selection changed`，
                        -- 但失败后 `old.titan` **保留**，下一帧仍满足
                        -- `(old and not selected)` ⇒ 再试 ⇒ 再失败，**无限循环**。
                        -- 期间不写任何 movement 目标，G-60 就挂在泰坦底下不动，
                        -- 直到 30 秒寿命耗尽 —— 用户报的"长时间盘旋"。
                        --
                        -- 与已有的 OBSERVE_FAIL_LIMIT（观测失败熔断）同一思路，
                        -- 但那条只管 with_observation 拿不到窗口；这条管**引导本身失败**。
                        -- 同一实体连续失败 GUIDE_FAIL_LIMIT 次 ⇒ 放弃它：
                        -- 标记 retired + 清持有，停止逐帧重试。
                        -- 不做全局禁用：别的 G-60 可能一切正常（2026-09-28 的教训）。
                        if result then
                            guide_fail[m.id]=nil
                        else
                            self.skipped=self.skipped+1
                            -- ★★ 净空/腹部过低的拒绝 = **等待**，不是"引导失败"（2026-10-02）★★
                            --
                            --   背景：用户「泰坦准备吐酸时腹部会降低 ⇒ 手雷在离腹部极近处
                            --   引爆 ⇒ 炸不死泰坦」+「G60 靠**多部位**伤害杀泰坦，太靠近腹部
                            --   受伤部位会减少」⇒ `titan_standoff_min` 已抬到 2.5（爆距不再缩短）
                            --   ⇒ 腹部过低时 `titan_route` 会**拒绝规划**（那一刻没有安全爆点）。
                            --
                            --   那种拒绝是**暂时的**（吐酸动画结束腹部就抬起来）。但原来它会计入
                            --   `guide_fail`，连着 30 帧（0.5 秒）就 `guide_give_up` 把这颗手雷
                            --   **退休** ⇒ 手雷白扔、一颗都不炸 —— 比"贴着腹部炸"更糟。
                            --   ⇒ 现在：净空类拒绝**不计数**（保留持有、下一帧重试、腹部抬起后
                            --     照常按 2.5 m 爆距引爆）。只打一条日志。
                            --
                            --   ⚠ 用 `guide_fail[m.id]==0` 当作"已在等待"的标记（0 ≠ nil）
                            --     ⇒ 不新增状态、不新增 upvalue（tick 的 upvalue 余量紧张）。
                            --   ⚠ **真正的**引导失败（如 `Titan selection changed`）照旧计数、
                            --     照旧 30 帧退休 —— 那条熔断是 2026-09-29 为"无限循环挂住"加的，
                            --     不能被这里绕过。
                            local waiting=type(status)=='string'
                                and status:find('clearance',1,true)~=nil
                            -- ★★★ 爆炸已触发 ⇒ **完成**，不是失败（2026-10-03）★★★
                            --
                            --   实机取证（2026-10-03 11:29 那局）：实体 16778567 走**泰坦**段
                            --   （`native_titan_aim` 的 `assert(value,why)`）时，`explosive_context`
                            --   的 `'explosion already requested'` 被这条**引导失败记账**当成
                            --   普通失败记了 **30 次** ⇒ 打出 `guide_give_up;after=30`
                            --   —— 一条**假的失败**（那颗手雷其实**已经炸了**）。
                            --
                            --   根因：`note_already_exploded`（把该条件判为"完成"：`retired` +
                            --   `release_hold` + 打 `arrival_already_exploded`）原来只接在
                            --   **disposal 段**与 **arrival 段**，而本段（泰坦/点目标/runner 三条
                            --   引导路径共用的记账处）**没接**。★ 连 `note_already_exploded`
                            --   自己的注释都在警告"同一个判断出现两处" —— 这就是第三处。
                            --
                            --   代价（实测）：多花 **1 秒**（30 次 × 忙档 2 帧 = 60 帧）重试一颗
                            --   已爆的手雷，期间还**持有**它（保持忙档扫描），外加 30 条误导日志。
                            --   终态本来相同（`retired` + `release_hold`）⇒ 功能无害，所以长期未暴露。
                            --   ⇒ 现在统一走**同一个判定函数**（三处共用），并清零计数。
                            --   ⚠ 它在 `if result then` 之后、真失败计数之前 —— 顺序即语义：
                            --     放到后面就等于"已经记了一次失败"。
                            if note_already_exploded(tostring(status or detail)) then
                                guide_fail[m.id]=nil
                            elseif waiting then
                                if guide_fail[m.id]==nil then
                                    env.emit('skipped;entity='..m.id..';reason='..tostring(status)
                                        ..';detail=WAITING_FOR_SAFE_BLAST;fail_count=0')
                                end
                                guide_fail[m.id]=0
                            else
                                local n=(guide_fail[m.id] or 0)+1
                                guide_fail[m.id]=n
                                env.emit('skipped;entity='..m.id..';reason='..tostring(status)
                                    ..';detail='..tostring(detail)..';fail_count='..n
                                    -- ★ 2026-10-10：标明是**哪条路**失败的。
                                    --   实机 entity=508 的 `stale observation` 只写了
                                    --   "原生前置条件失败"，看不出是点目标驱动还是泰坦路
                                    --   ⇒ 判读时只能猜。三条路共用这段记账，必须自报家门。
                                    ..';via='..((old and old.point and 'point')
                                        or (old and old.titan and 'titan') or 'runner')
                                    ..';frame='..tostring(frame))
                                if n>=GUIDE_FAIL_LIMIT then
                                    guide_fail[m.id]=nil
                                    retired[m.id]=retired_key
                                    release_hold(m.id)
                                    env.emit('guide_give_up;entity='..m.id..';after='..n
                                        ..';detail='..tostring((detail~=nil and detail) or status))
                                end
                            end
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
                    --
                    -- state 3 传 region（与 titan 段同一套）：vanilla 的 M.radius=0.8
                    -- 对虫洞太小，实机引爆距离 1.3~2.05。
                    --
                    -- 判定同样走 TakeGate.decide_guidance（纯函数、可测），
                    -- 它同时守住"必须真正持有"和"只允许 state 4 做 aim/explode"。
                    local early_drive=m.state~=4 and drive3
                    local guide=TakeGate.decide_guidance{
                        drive=true,old=old,retired=retired[m.id]~=nil,
                        can_guide=(m.state==4 or early_drive),early=early_drive}
                    if arrival and guide.run then
                        -- Recapture after preceding setters, including the Titan waypoint.
                        local manager=pointer(base+0x3326740)
                        local records=Layout.pointer(read(manager+0x60,8),0)
                        m.record_bytes=read(records+m.index*0x1f8,0x1f8)
                        m.selection_id=Layout.u32(m.record_bytes,0x18);m.selection_flag=m.record_bytes:byte(0x79)
                        current={ref=old.ref,match=m}
                        local ok_arr,result,reason=pcall(with_observation,old.ref,function(scope)
                            local target,blast_point,blast_site
                            -- ★★ 2026-10-10 安全区：这道门**每帧只调一次**（结果下面复用）★★
                            --   ⚠ 门每成立一次就打一条 `blast_hold;` ⇒ 调两次日志翻倍
                            --     （去重表按手雷去重，防不住同一帧的两次调用）。
                            --   返回 true = 允许引爆；false = 玩家在圈内（held）。
                            local held=not blast_safe_hold(m,scope)
                            if old.lock then
                                local d=TargetData.new(read,base,env.exe)
                                local e=d.entity(old.lock.id)
                                if e and (not env.target_allowed or env.target_allowed(e.resource))
                                    and e.identity==old.lock.identity and d.unit(e)==old.lock.unit then
                                    e.validate=d.validate;target=e
                                    -- ★★★ 体内爆点（2026-10-03，巨型构筑者 Bulk Fabricator）★★★
                                    --
                                    -- 见 `compat/blast_sites.lua` 文件头：虫洞的摧毁判定是**距离**
                                    -- （用户实测 <4 m 即摧毁），所以引擎 `aim` 落在原点附近就够；
                                    -- 而巨型构筑者**要求爆炸进入正面红色通风口内部**，
                                    -- 引擎 `aim` 落在实体原点（地表/地下）⇒ 炸在底部**不掉血**
                                    -- （用户实测原话：「会在底部引爆，但不会对其造成伤害」）。
                                    --
                                    -- ⇒ 这一类显式给"**原点 + lift**"的体内点，并按**点目标**交给
                                    --   arrival 段 —— 与 ping 地面点走**同一条已验证过的路径**
                                    --   （`options.point_target`：写 `invalid_id` + 三维坐标，
                                    --     按 `point_arrival_region` 判定到达/引爆）。
                                    -- ⚠ lift 是**唯一需要实机标定**的量（见 compat/blast_sites.lua）。
                                    -- ⚠ 只在 `d.position` 读成功时启用；读不到就退回旧行为（引擎 aim）。
                                    local site=env.blast_sites and env.blast_sites[e.resource]
                                    if site and type(site.lift)=='number' then
                                        local okp,p=pcall(d.position,e)
                                        if okp and p then
                                            -- ★★ 标定档位（2026-10-03，见 compat/blast_sites.lua）★★
                                            --   用户给了关键事实：「通风口只是入口，G60 是穿模进入的，
                                            --   不会受到阻拦」⇒ 手雷能飞进模型内部 ⇒
                                            --   **爆心高度**就是唯一变量 ⇒ 逐颗换档，一局扫出判定区。
                                            --   ⚠ 必须按**手雷**推进（`P.swk[m.id]` 记住这一颗分到的档）；
                                            --     按帧推进的话，同一颗手雷飞行途中会不停换点 ⇒ 等于没测。
                                            --   ⚠ `scan` 缺席 ⇒ 完全退回单一 `site.lift` 的确定性行为。
                                            local blast_lift,sw_i=site.lift,'-'
                                            -- ★ 档位表**优先取本目标自己的**（`site.scan`），缺省才回落全局
                                            --   `BlastSites.scan`（2026-10-04：**多个目标各自标定**是机制的让步，
                                            --   共用一个表会互相污染档号）。向后兼容：老条目没有 `site.scan`。
                                            local scan=site.scan or env.blast_sites.scan
                                            if scan and #scan>0 then
                                                sw_i=P.swk[m.id]
                                                if not sw_i then
                                                    P.swn=P.swn+1
                                                    sw_i=(P.swn-1)%#scan+1
                                                    P.swk[m.id]=sw_i
                                                end
                                                blast_lift=scan[sw_i] or blast_lift
                                            end
                                            blast_point={p[1],p[2],p[3]+blast_lift}
                                            blast_site=site
                                            -- ⚠⚠ 爆点日志的去重键必须**含手雷 id**（2026-10-03 实机发现）：
                                            --   原来只用目标 id ⇒ 同一个目标上的第 2、3 颗
                                            --   **一条 `blast_point` 都不打**，而那正是标定扫描要读的档号
                                            --   （实机那局 445/444/446 只剩 `sweep=1/4/7`，
                                            --     中间 2/3/5/6 档只能靠 `blast_hit` 的 delta 反推补回来）。
                                            local bkg=tostring(m.id)..'|'..tostring(e.id)
                                            P.site[m.id]=tostring(e.id);P.orig[m.id]=p
                                            if env.emit and not P.blast[bkg] then
                                                P.blast[bkg]=true
                                                env.emit(string.format(
                                                    'blast_point;entity=%s;resource=%s;lift=%.2f;sweep=%s'
                                                    ..';origin=%.2f,%.2f,%.2f;point=%.2f,%.2f,%.2f',
                                                    tostring(e.id),e.resource,blast_lift,tostring(sw_i),
                                                    p[1],p[2],p[3],
                                                    blast_point[1],blast_point[2],blast_point[3]))
                                            end
                                        end
                                    end
                                    -- ★★ 2026-10-10 安全区绕行的**圆心**（只在生效期间取）★★
                                    --   · 体内爆点自带圆心（`blast_point` 就是），不重复取；
                                    --   · 普通虫洞/结构锁没有 ⇒ 在这里取一次，供下面注入绕行点。
                                    --   ⚠ 只在 `held` 时取：`target_position` 走
                                    --     `TargetContext.capture`，不便宜，不能进常规每帧路径
                                    --     （perf 门盯着 layout_reads）。
                                    --   ⚠ 取不到就**不假装成功** ⇒ 置 nil，下面会打
                                    --     `blast_detour_nopos;` 并退回"只拦我们自己的引爆"。
                                    if held and not blast_point then
                                        local okc,pc=pcall(target_position,e)
                                        P.tpos[m.id]=(okc and pc) or nil
                                    end
                                end
                            end
                            local titan_point=old.titan and not old.titan.cancelled
                                and not scope.prepared.selection.has_target
                                and scope.prepared.record_bytes:sub(0x1d,0x28)==old.titan.point_bytes
                            -- Titan already evaluated arrival against its live weakpoint.
                            if titan_point then return {kind='guide'} end
                            if has_weakpoint(m.selection_resource) then target=nil end
                            local blocked_selected=old.blocked and old.lock==nil and m.selection_flag==1
                            -- ★ 点目标（2026-10-01）：把 ping 的地面点交给 arrival 段
                            --   写成**点目标选择**（native_arrival 的 options.point_target，
                            --   与泰坦同款写法）并按点判定到达/引爆。
                            --   ⚠ 两种"让位"，与 point_drive 的判据一致（按每颗 G-60 判）：
                            --     · `old.lock` 有值 ⇒ 这颗已锁上结构目标 ⇒ 让给结构
                            --     · 引擎选中泰坦/弱点类 ⇒ 让给泰坦段
                            local point=old.point
                            if point and old.lock then point=nil end
                            if point and has_weakpoint(m.selection_resource) then point=nil end
                            -- 早期驱动：传 titan 同款到达区域 + early 标记
                            -- （early 让 arrival 内部失败不永久禁用，熔断由 state3_danger 管）
                            local arr_opts
                            if blast_point then
                                -- ★ 体内爆点（体内点优先）：与 ping 点目标同一套写法，
                                --   但点是**从已锁定目标算出来的**（见上面的 blast_point），
                                --   而且到达区域用**本目标专用**的紧区域 ——
                                --   默认那套（radius 3 / depth 2 / above 2）是给"ping 空地"
                                --   的宽松值；实测会让爆点落在上方 1.4~1.9 m，
                                --   从而掉出爆炸内半径（4 m）⇒ 拆毁判定不触发。
                                arr_opts={region=(blast_site and blast_site.region)
                                        or env.point_arrival_region,point=true,
                                    point_target=blast_point}
                            elseif point then
                                arr_opts={region=env.point_arrival_region,point=true,
                                    point_target={point.x,point.y,point.z}}
                            elseif early_drive then
                                arr_opts={region=env.titan_arrival_region,early=true}
                            end
                            -- mask_only 原为 `not target`；有点目标时**必须放行**
                            -- （否则 arrival 会走 mask_all 分支、我们一个字节都写不进去）。
                            local mask_only=(old.force_search or blocked_selected) and 'search'
                                or (not target and not point and not blast_point) and true or nil
                            -- ★★ 2026-10-10 安全区第二步：**主动绕行**（用户拍板"让它绕着目标转"）★★
                            --
                            --   为什么"不引爆"不够 —— 实机证据（2026-10-10 那一局）：
                            --     `blast_hold;entity=520;player_dist=10.76;radius=12;frame=10610`
                            --     紧接着就是 `arrival_skipped;…: explosion already requested`
                            --   玩家还在圈内，**引擎自己**把雷点了（整局我们只有 501 一条
                            --   `arrival_detonated`）。引擎在撞击/引信那一刻点的火**拦不住** ——
                            --   这道门只拦得住我们自己的 `calls.explode`。
                            --   ⇒ 唯一杠杆：玩家在圈内时**不让它到目标身上**。
                            --
                            --   为什么这样能拦住引擎：写进去的是**点目标**
                            --   （`invalid_id` + 坐标）⇒ 引擎手里**没有实体可撞** ⇒
                            --   撞击/引信无从触发。entity=501 实测：点目标上悬停 ~340 帧，
                            --   引擎一次都没自行引爆。
                            --
                            --   代价可接受：寿命到期只是**静默移除、不爆炸**
                            --   （`native_disposal.lua` 第 1 行 + 用户确认）⇒ 最坏情况是
                            --   "这颗雷白扔"，绝不会在玩家脸上炸。
                            --
                            --   ⚠ 复用**已在生产使用**的写路径 `options.point_target`
                            --     （ping 空地 / 体内爆点同款，写后回读断言已复核）
                            --     —— 不新增写途径、不碰 SAFETY_LAYER。
                            --   ⚠ 绕行点必须**旋转**：`arrival_policy` 的 stalled 判据是
                            --     "4 秒没进展 ⇒ 转 'search' ⇒ 清锁、手雷乱飘"；旋转让
                            --     `distance(goal,p.goal)>3` 每帧重置进度 ⇒ 永不 stalled。
                            --   ⚠ `early` 必须**继承**：arrival 内部失败时不许永久禁用
                            --     （early 只影响收尾的 disabled 判定，state 2/3 那条路在用）。
                            --   ⚠ 拿不到圆心 ⇒ **不注入**（退回"只拦我们自己"）**且可见**。
                            if held then
                                local c=blast_point or (point and {point.x,point.y,point.z})
                                    or P.tpos[m.id]
                                if c then
                                    local ang=frame*0.01          -- ≈10 秒一圈（60fps）
                                    -- 环绕半径：**菜单可调**（默认 5 m）。
                                    --   ⚠ 读 `env.blast_safe_orbit` 而**不是**写字面量：菜单改的
                                    --     值必须立刻生效，且 `blast_detour;radius=` 打的就是
                                    --     这里实际用的值（三段验证的"真正生效"那一段）。
                                    --   ⚠ 夹到 [2,20]（与菜单滑杆同界）；再抬到**硬下限
                                    --     3.5 m** —— 见下面的站定距离说明。
                                    local R=tonumber(env.blast_safe_orbit) or 5.0
                                    if R<2 then R=2 elseif R>20 then R=20 end
                                    -- ★★ 2026-10-10 站定距离（standoff）★★
                                    --   实机实测：引擎的引信是**物理接近目标**（不是"记录里
                                    --   选中的是谁"）—— 两次独立取证都在 ~2.2 m 点火：
                                    --     entity=639（绕行中）2.22 m；entity=522（我们的点
                                    --     还在记录里、target=0）2.25 m。
                                    --   ⇒ 点目标绕行只能改"它飞去哪"，**解不了引信** ⇒
                                    --     唯一的杠杆是**距离**。
                                    --   而"追一个绕圈的点"这条追杀曲线会**切进圈内**
                                    --   （实机就是掉到 2.25 m）⇒ 只要它离目标比设定半径
                                    --   近，就把目标点放到 `r+2.5`：**命令它往外飞**，
                                    --   曲线就再也切不进去。
                                    --   ⚠ 坐标免费：`own_position_bytes` 本来就读过。
                                    if R<3.5 then R=3.5 end
                                    local okv,v=pcall(TargetData.vector,scope.prepared.own_position_bytes,0)
                                    if okv and v then
                                        local dx,dy,dz=v[1]-c[1],v[2]-c[2],v[3]-c[3]
                                        local r=math.sqrt(dx*dx+dy*dy+dz*dz)
                                        if r<R-0.5 then
                                            local push=r+2.5
                                            if push>R then R=push end
                                            if R>20 then R=20 end
                                        end
                                    end
                                    local ox,oy=c[1]+R*math.cos(ang),c[2]+R*math.sin(ang)
                                    arr_opts={region=env.point_arrival_region,point=true,
                                        point_target={ox,oy,c[3]+1.0},
                                        early=(arr_opts and arr_opts.early) or nil}
                                    -- 绕行点必须**允许写入**（mask_all 分支会把点写整段跳过）
                                    mask_only=nil
                                    if frame-(P.dg[m.id] or -100000)>=60 then
                                        P.dg[m.id]=frame
                                        env.emit('blast_detour;entity='..m.id
                                            ..';center='..string.format('%.2f,%.2f,%.2f',c[1],c[2],c[3])
                                            ..';point='..string.format('%.2f,%.2f,%.2f',ox,oy,c[3]+1.0)
                                            ..';radius='..string.format('%.1f',R)
                                            ..';src='..(blast_point and 'blast'
                                                or (point and 'point') or 'target')
                                            ..';frame='..frame)
                                    end
                                elseif not P.dg_nopos[m.id] then
                                    P.dg_nopos[m.id]=true
                                    env.emit('blast_detour_nopos;entity='..m.id
                                        ..';lock='..tostring(old.lock and old.lock.id or '-')
                                        ..';frame='..frame)
                                end
                            else
                                -- 离开安全区 ⇒ 清掉绕行状态（**必须**：手雷 id 会被引擎复用，
                                --   残留的 tpos/dg 会让下一颗手雷的圆心与诊断张冠李戴）。
                                P.tpos[m.id]=nil;P.dg[m.id]=nil;P.dg_nopos[m.id]=nil
                                -- ⚠⚠ 还必须清掉**锁上的 `point_bytes`**（自查发现的死锁）★
                                --   绕行期间我们给锁写了 point_bytes ⇒ priority 下一帧
                                --   `continued=true` ⇒ **跳过 setter** —— 这正是我们要的
                                --   （别和绕行点打架）。但玩家一离开，记录里还留着那个点、
                                --   锁上也还留着它的字节 ⇒ `continued` **永远**为真 ⇒
                                --   priority 永远不写回实体选择 ⇒ arrival 走实体 aim 时必然撞
                                --   `arrival selected target mismatch`：**每帧失败**，只能等
                                --   `guide_fail` 熔断（30 帧）把这颗雷退休 = 雷白扔。
                                --   （runtime 的 holder 判据第 618 行原文就写着："没有点的锁
                                --     不参与，否则会误判成已拥有自定义航点、把正常的实体选择
                                --     写入也一起跳过" —— 我们正好制造了那个状态。）
                                --   ⇒ 离开的那一刻就清字节：下一帧 `continued` 失败 ⇒ priority
                                --     写回实体选择 ⇒ arrival 恢复。代价只有 **1 帧**
                                --     `arrival_skipped;…arrival selected target mismatch`
                                --     （`mutated` 尚为 false ⇒ 不会 disabled），远小于 30 帧熔断。
                                if old.lock then old.lock.point_bytes=nil end
                            end
                            -- ★ 标定：这颗手雷**当前在哪**（相对坐标由日志侧与 orig 相减）。
                            --   `own_position_bytes` 本来就被 with_observation 读过了 ⇒ 解码免费。
                            --   在 step **之前**取 ⇒ 这一帧若爆了，拿到的就是"爆炸那一帧的位置"。
                            --   ★ 2026-10-10：`held` 时也要取 —— 引擎引爆探针要靠它算
                            --     "引擎点火那一刻，手雷离目标多远"（`P.hit` 对 `P.tpos`）。
                            if blast_point or held then
                                local okv,v=pcall(TargetData.vector,scope.prepared.own_position_bytes,0)
                                if okv then P.hit[m.id]=v end
                            end
                            -- ★★ 2026-10-10 爆炸安全区（用户要求）★★
                            --   玩家在 `blast_safe_radius`(默认 0=关) 球形半径内 ⇒ **不引爆**，
                            --   G-60 继续追踪目标，等玩家离开这个球再炸。
                            --   ⚠ 为什么只能在**调用侧**做：native_arrival 在 SAFETY_LAYER 里
                            --     （只读、不可改），而它在 `action=='detonate'` 时**已经**调了
                            --     `calls.explode` ⇒ 事后再拦来不及。唯一可控的是 `terminal`：
                            --     Policy 的判据是 `terminal and arrived` ⇒ 传 false 就不炸。
                            --   ⚠ 豁免 stalled：不炸会让 G-60 一直"没到达"；arrival_policy 的
                            --     `stalled_seconds` 到了会转 'search' ⇒ **清掉锁定、手雷乱飘**。
                            --     所以安全区生效期间必须**压制** stalled（下一颗/离开后自动恢复）。
                            --   ★ 与 titan 段**共用 `blast_safe_hold`**（同一个门）——
                            --     第一版两处各写一份，结果只拦住 ping 那条路（实机已踩）。
                            --   ★ `held` 就是**上面那次**门调用的结果 —— 这里不再调第二次
                            --     （门每成立一次打一条 `blast_hold;`，调两次日志翻倍）。
                            local terminal=not held
                            return arrival:step(scope,target,nil,'vanilla',terminal,old.arrival_progress,
                                mask_only,arr_opts)
                        end)
                        current=nil
                        -- ⚠ 2026-10-09：这里**曾经**放过 ping 路的提升（在"到达段写点成功之后"）
                        --   —— 那是错的，已移除：整段驱动被上面的 `m.state==4` 挡着，而
                        --   state 4 正是要打开的门 ⇒ 提升写在门里面 ⇒ 门永远不开
                        --   （实机证据：`point_taken` 一条都没有）。提升现在放在**门之前**，
                        --   见 `ping_early` 之后那段。**这里不要再放回去。**
                        if not ok_arr and early_drive then
                            state3_danger=state3_danger+1
                            env.emit('state3_danger;entity='..m.id..';count='..state3_danger
                                ..';stage=arrival;detail='..tostring(ok_arr and reason or result))
                            if state3_danger>=STATE3_DANGER_LIMIT then
                                state3_blocked=true
                                env.emit('state3_takeover_disabled;entity='..m.id
                                    ..';detail=arrival early-state repeated failure')
                            end
                        end
                        if ok_arr and result then
                            if result.kind=='quarantine' then
                                -- ★ 竞争态（2026-09-30，判定见 g60.priority_faults）★
                                --   与 priority 段同一套语义：**只放弃这一颗** G-60 ——
                                --   清掉它的锁/航点/进度并置 old.quarantined，交回引擎原生
                                --   逻辑；其余 G-60 与后续标记照常接管（上游在这里是整个
                                --   mod 一起死，22:10 那局就是那个后果）。
                                --   ⚠ 不置 abandoned：本段在 structure/titan 写入**之后**
                                --     才跑，那两个写入本帧已经发生，置了也没有效果。
                                --     真正生效的是 old.quarantined —— 下一帧
                                --     TakeGate.decide 直接返回 why='quarantined'，不再写它。
                                old.quarantined=true;old.lock=nil;old.titan=nil;old.point=nil
                                old.force_search=nil;old.arrival_progress=nil;old.blocked=nil
                                env.emit('arrival_quarantined;entity='..m.id
                                    ..';detail='..tostring(result.contended))
                                -- 同一帧里**多颗**都竞争态失败 ⇒ 不是单点时序，是我们对引擎
                                -- 状态的理解出问题了 ⇒ 这时停手才对（与 priority 段共用计数）。
                                if note_contention() then
                                    self.disabled=true
                                    error('arrival contention limit reached: '..tostring(result.contended))
                                end
                            else
                                old.arrival_progress=result.progress;old.force_search=nil
                                if result.blocked then old.blocked=result.blocked end
                                -- ★★ 把"我们刚写进记录的那个点"记到锁上（2026-10-05）★★
                                --   为什么要记：`with_observation` 要判"记录里这个点是不是我们自己写的"，
                                --   而**体内爆点**（`blast_point`）是 runtime 每帧现算的，
                                --   锁表里本来没有它的字节 ⇒ 不记的话上游那套
                                --   `guidance_observation` / `continued` 在我们这里永不触发。
                                --   上游靠 `track.titan.point_bytes` 承载，我们靠这里补上。
                                --   ⚠ `result.point_bytes` 只在该帧真的写了点目标时非 nil
                                --     ⇒ 走实体 `aim` 路径时这里会把它**清成 nil**（语义正确：
                                --      "当前记录里没有我们的点"）⇒ priority 下一帧照常写实体选择，
                                --      不会把锁卡在"永远不写"的状态。
                                if old.lock then old.lock.point_bytes=result.point_bytes end
                                -- ★ 点目标的两条诊断（2026-10-01）★
                                --   为什么必须打：点目标的 'guide'/'search' 原本**完全静默**
                                --   （只有 detonate/quarantine 才打日志）⇒ 第一版实机
                                --   "飞过去了但没炸"时日志里只有 point_taken，什么线索都没有。
                                --   · point_stalled：到达判定 4 秒内没满足 ⇒ 交回引擎（要调区域）
                                --   · point_guide  ：每 60 帧报一次当前距离（看它到底靠没靠近）
                                -- ★★ 体内爆点的到达诊断（2026-10-03 17:0x，"低抛炸底部"那局）★★
                                --   **为什么必须加**：那一局那颗"低抛"的手雷
                                --   **一条 `arrival_detonated` 都没有** —— 而下面这段诊断的判据是
                                --   `old.point`（**只覆盖 ping 空地**），体内爆点走的是 `P.site[m.id]`
                                --   ⇒ **完全静默** ⇒ "那颗到底飞到哪了"日志里一个字都没有，只能靠猜。
                                --   ⚠ 复用 `P.pg` 做节流（不新增 local/upvalue；两者 key 都是手雷 id）。
                                -- ★ 2026-10-10 安全区绕行**也必须有到达诊断**：
                                --   绕行生效时目标是每帧现算的旋转点；不报距离就完全看不见
                                --   它到底在绕着转、还是在往目标里钻 —— 而环绕半径 R 正是
                                --   靠这条日志标定的。`dist` = 手雷到**绕行点**的距离。
                                local guide_tag=(old.point and 'point') or (P.site[m.id] and 'blast')
                                    or (P.dg[m.id] and 'detour') or nil
                                if guide_tag then
                                    if result.kind=='search' then
                                        env.emit(guide_tag..'_stalled;entity='..m.id
                                            ..';dist='..tostring(result.distance)..';frame='..frame)
                                    elseif result.kind=='guide' and env.emit then
                                        if frame-(P.pg[m.id] or -1000)>=60 then
                                            P.pg[m.id]=frame
                                            -- 体内爆点额外报"这颗雷现在有多高（相对目标原点）"——
                                            -- 这是**判断"低抛到底是上不去，还是根本没被引导"的唯一依据**。
                                            local oh=''
                                            if P.hit[m.id] and P.orig[m.id] then
                                                local v,o=P.hit[m.id],P.orig[m.id]
                                                oh=';own_z='..string.format('%.2f',v[3])
                                                    ..';origin_z='..string.format('%.2f',o[3])
                                                    ..';above_origin='..string.format('%.2f',v[3]-o[3])
                                            end
                                            env.emit(guide_tag..'_guide;entity='..m.id
                                                ..';dist='..string.format('%.2f',result.distance or -1)
                                                ..oh..';frame='..frame)
                                        end
                                    end
                                end
                                -- ★ 安全区豁免 stalled：不炸本身会让 arrival 判成"卡住"
                                --   （stalled ⇒ 'search'）⇒ 清锁、手雷乱飘 —— 正是安全区
                                --   最容易踩的坑。所以**刚因安全区拒爆过**就**不认这个 search**。
                                if result.kind=='search' then
                                    local held=P.safehold[m.id]
                                    if held and frame-held<=600 then
                                        old.force_search=nil
                                        env.emit('blast_hold_kept;entity='..m.id..';frame='..frame)
                                    else
                                        old.lock=nil;old.titan=nil;old.point=nil
                                    end
                                end
                                if result.kind=='detonate' then
                                    retired[m.id]=retired_key
                                    release_hold(m.id)
                                    env.emit('arrival_detonated;entity='..m.id..';target='..result.target..';distance='..result.distance
                                        -- ★ 2026-10-02：爆点几何分解（只诊断）——
                                        --   三维 distance 分不清"偏侧"还是"贴脸"，
                                        --   而两者的修法相反（见 native_arrival 处的说明）。
                                        ..';horiz='..tostring(result.horizontal or -1)
                                        ..';dz='..tostring(result.dz or -1))
                                    -- ★ 标定：**我们自己**引爆时的实际位置（相对目标原点）
                                    note_blast_hit('arrival')
                                end
                            end
                        else
                            local why=tostring(ok_arr and reason or result)
                            env.emit('arrival_skipped;entity='..m.id..';detail='..why)
                            -- 爆炸已触发 ⇒ 视为完成（说明见 note_already_exploded 定义处）
                            -- 注意这里与 disposal 段共用同一 helper —— 我第一版只改了这一处，
                            -- 实机 entity=1205 走的却是 disposal 段，修复没生效。
                            note_already_exploded(why)
                        end
                    end
                    -- ★ 2026-09-30：竞争态已在 native_arrival 内部转成 kind='quarantine'
                    --   （**不**置 disabled）⇒ 走到这里还 disabled 的只可能是结构性漂移，
                    --   必须停手。`not (…quarantine)` 与 priority 段同款（防御性写法）。
                    if arrival and arrival:disabled()
                        and not (ok_arr and type(result)=='table' and result.kind=='quarantine') then
                        self.disabled=true;error('arrival operation disabled')
                    end
                end
            end
            for id,t in pairs(tracked) do
                if not seen[id] then runner:release(t.ref);tracked[id]=nil end
            end
            local present={};for _,m in ipairs(observed.matches) do present[m.id]=true end
            for id in pairs(retired) do if not present[id] then retired[id]=nil end end
            -- state 停留表只按 fingerprint 增长，做个上限清理避免无限膨胀
            local live={}
            for _,m in ipairs(observed.matches) do live[m.identity_bytes..m.flight_start]=true end
            for fp in pairs(state_key) do
                if not live[fp] then
                    state_key[fp]=nil;state_age[fp]=nil
                    -- 转阶段探针的去重表与 state 表同键（同一个 fp）⇒ 顺手清，不另开循环
                    P.sel[fp]=nil
                end
            end
            -- ★ 链路诊断：只在**状态变化**时打一行。
            --   一眼能看出"标记读到了却没接管"卡在哪一环：
            --     mark=0                  → ping 侧没读到标记（看 structure_ping_unavailable）
            --     g60=0                   → 场上没有可驱动的 G-60（不该 happen，但仍要能看见）
            --     mark>0 且 entered=0     → 门控没放行（held/blocked 会说原因）
            --     entered>0 且 locked=0   → priority 段进了但没锁上（看 priority_skipped 的 detail）
            local status='link;mark='..(structure_mark and tostring(structure_mark.id) or '-')
                ..';mgr='..tostring(diag.manager)..';matched='..diag.total
                ..';saw4='..(saw_state4 and '1' or '0')
                ..';sig=['..diag.sig..']'
                ..';g60='..diag.state4..';eligible='..diag.eligible
                ..';e3='..diag.state3..';blocked3='..(state3_blocked and 1 or 0)
                ..';entered='..diag.entered..';locked='..diag.locked
                ..';held='..diag.held..';quarantined='..diag.blocked
            if status~=last_link_status then
                last_link_status=status
                env.emit(status)
            end
        end,function(e)
            -- ★ 出错时**在栈展开之前**抓调用栈（xpcall 的 handler 才有这个时机）。
            --   放进 P（不新开 local ⇒ 不动 upvalue 预算）。
            P.err_tb=(debug and debug.traceback) and debug.traceback(e,2) or tostring(e)
            return e
        end)
        -- ★ perf 窗口：本帧**跑过 tick 体**（放在 pcall **之后** ⇒ 正常跑完、
        --   提前 return、抛错三种都算"跑过了"）。窗口内的重置在 pcall 之内，
        --   所以窗口最后一帧的这次 +1 会落到下一个窗口（600 帧里差 1，可忽略）。
        P.wframes=P.wframes+1
        if not ok then
            current=nil
            -- ★ 逐条刷屏会把真正的一次性错误埋掉（2026-09-27 实机日志：连续 60 条
            --   `frame_error;detail=…:236: pointer bound` 之后，才跟着那条真正致命的
            --   `priority setter target mismatch`）。启动期 root 指针未初始化会让观测段
            --   连续几十帧失败，那是"还没准备好"，不是"坏了"。
            -- 改成：每种 detail 只打第一条，重复的计入计数，停机时汇总一次。
            -- ★★ 2026-10-09：detail 里**附上调用栈头几帧** ★★
            --   此前只有消息、没有调用者 ⇒ `pointer bound` 无法归因。
            --   栈来自 xpcall 的 handler（见 tick 体收尾处），只在**出错那帧**有效，
            --   用完立刻清掉 —— 否则下一帧的错误会继承上一次的栈（误归因）。
            local detail=tostring(why)
            if P.err_tb then
                -- ⚠ 取帧逻辑必须**跳过前两行**（消息 + `stack traceback:`）并留足帧数：
                --   第一版写成"最多 4 行、再跳过第 1 行" ⇒ 实际只剩 assert/ptr 两帧，
                --   **调用者正好被切掉**（离线用 lua51.dll 实测抓出来的：middle 在第 5 行）。
                local frames={}
                for fl in tostring(P.err_tb):gmatch('[^\n]+') do
                    fl=fl:gsub('^%s+',''):gsub('%s+$','')
                    if fl~='' and fl~='stack traceback:' then frames[#frames+1]=fl end
                end
                P.err_tb=nil
                local tb={}
                for i=2,#frames do            -- frames[1] 是消息本身
                    if #tb>=4 then break end  -- 留 4 帧：assert / ptr / **调用者** / 再上一层
                    tb[#tb+1]=frames[i]
                end
                -- ⚠ 分隔符**不能用模板占位符那种双 at 标记** —— 那是 entry 模板的保留
                --   标记（如 MODULES 占位符），`build.py` 的禁用词表会直接拒绝出包。
                --   而且**注释里也不许写它的字面量**（本工程为此栽过两次，本次又一次）。
                if #tb>0 then detail=detail..' ~~ '..table.concat(tb,' | ') end
            end
            local seen_before=frame_errors[detail] or 0
            frame_errors[detail]=seen_before+1
            self.frame_error_total=(self.frame_error_total or 0)+1
            if seen_before==0 then env.emit('frame_error;detail='..detail) end
        end
    end
    function host:stop() self.disabled=true;release_all() end
    -- 停机时给出 frame_error 汇总：每种 detail 打了几次。
    -- 逐条去重是为了可读性，这里把被折叠掉的次数补回来，信息不丢。
    function host:error_summary()
        local parts={}
        for detail,n in pairs(frame_errors) do parts[#parts+1]=tostring(n)..'x '..detail end
        local ping={}
        for detail,n in pairs(structure_issue_counts) do ping[#ping+1]=tostring(n)..'x '..detail end
        table.sort(parts);table.sort(ping)
        return {kinds=#parts,total=self.frame_error_total or 0,details=table.concat(parts,' | '),
            ping_kinds=#ping,ping_total=#ping>0 and table.concat(ping,' | ') or ''}
    end
    -- ★ 2026-10-10：把 env **暴露给宿主**（`host.env`）。
    --   为什么需要：Mod Options Menu 的回调要改运行期开关（如安全区半径），
    --   而 env 原本只是本闭包内的 local ⇒ 外部拿不到 ⇒ 菜单只能去改一个**不存在的
    --   全局 env**，实机直接 `attempt to index global 'env' (a nil value)`（已踩）。
    --   ⚠ 同一张表 ⇒ 菜单改了，本模块下一帧读到的一定是新值（无需重新 install）。
    host.env=env
    -- ★ 2026-10-10：把 `structure_ping` 也暴露出去（`host.structure_ping`）。
    --   为什么：entry 需要"玩家坐标"，而那要调 `structure_ping:self()`；
    --   但 `structure_ping` 是本模块的局部变量（L321），entry 拿不到。
    --   ⚠ 且**不能在 env 字面量里注入调用** —— 那时 structure_ping 还没构造
    --     （本模块 M.new 的顺序：env → … → structure_ping），会拿到 nil。
    host.structure_ping=structure_ping
    return host
end
-- Runs once after the existing Lua update, before the reviewed native game update.
function M.install(globals,host,on_stop,on_tick)
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
        if not stopped then
            -- ★ 2026-10-10：`on_tick` 是**可选**的第 4 参（向后兼容，默认 nil）。
            --   用途：Mod Options Menu 的**重试注册** —— addon 加载顺序不定，
            --   菜单可能晚于本 mod 出现 ⇒ 必须每帧尝试（参照 Aggro Counter v1.5）。
            --   ⚠ pcall 包住：菜单回调出错绝不能影响主链路。
            if on_tick then pcall(on_tick) end
            host:tick();if host.disabled then stop() end
        end
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
