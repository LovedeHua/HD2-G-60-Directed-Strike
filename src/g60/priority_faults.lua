-- 故障域判定：把「瞬时竞争」和「版本漂移」分开。
--
-- 2026-09-27 实机事故的根因。上游（以及本工程此前）的收尾只有一句
--   `if mutated then disabled=true end`
-- setter 写完回读一旦不符，整个 priority 段永久停手；runtime 紧接着又
--   `if priority:disabled() then self.disabled=true; error(...)`
-- 把整个 mod 永久停手。实机日志第 131–133 行：
--   arrival_detonated;entity=834;target=520        第 5 次成功引爆
--   frame_error;detail=…: priority setter target mismatch
--   disabled;applied=0                             之后整局 applied 归零
--
-- 但「回读不符」不是内存布局漂移。它的含义只是「我们把 id 和只读观测到的元数据
-- 交给了原生 setter，回读时看到的已经不是我们写的那份」，现实原因有两个，都不危险：
--   1. 引擎的原生 TargetLock 在同一帧后写覆盖了同一块 record（多颗 G-60 同场）；
--   2. clear 的效果落到 record 上有延迟，同帧回读看到的是旧值。
-- 我们写进去的参数本身合法（实体 id + 观测元数据），不会破坏内存。
--
-- 真正的版本漂移是另一批消息：scope/read/identity/record 前缀被换、Unit 索引越界、
-- 指针越界 —— 那些继续乱写才会让游戏崩，必须保持全局 fail-closed。
--
-- ★ 2026-09-30：同样的收尾（`if mutated then disabled=true end`）当时**只治了 priority，
--   漏了 arrival**（`native_arrival.lua`）。结果同一类瞬时竞争在 arrival 段把整局打死了
--   —— 见 M.COMPETITIVE 处的详细事故记录。现在两条链路共用这一份判定。
local M={}

-- 竞争态：只放弃**这一颗** G-60，交回引擎；不动全局 disabled。
M.COMPETITIVE={
    ['priority setter target mismatch']=true,
    ['priority setter metadata mismatch']=true,
    -- ★★ 2026-09-30 实机事故：arrival 段也有同族问题，补齐（此前只治了 priority）★★
    --
    -- 事故现场（22:10 那局）：`entity=4194657` 在 proximity 抑制块里回读不符
    --     arrival_skipped;…:2348: arrival proximity suppression failed
    -- 而该块在断言**前**已 `mutated=true` ⇒ `native_arrival` 的收尾
    -- `if mutated and not early then disabled=true end` 把 arrival 段永久关掉
    -- ⇒ 下一帧 runtime `if arrival:disabled() then error('arrival operation disabled')`
    -- ⇒ on_fatal：`disabled;applied=49` + `close()` —— **整局 mod 停手、日志当场关闭**
    -- （症状：用户报"虫洞标记失效了一次"；日志从此不再增长，而游戏仍在跑）。
    --
    -- 为什么这两条属于**竞争态**（与上面两条同型）：
    --   · `arrival proximity suppression failed` —— `calls.clear(pair,raw)` 写回后回读；
    --     `raw` 是 record **自身字节的副本**、只把一个 uint32 清零 ⇒ 参数合法。
    --     不符的现实原因同上：引擎原生 TargetLock 同帧后写覆盖，或 clear 落盘有延迟。
    --   · `arrival clear failed` —— `calls.clear(pair,nil)` 后回读 selection 应为
    --     invalid；同帧被引擎重新选中即不符。形状完全一致（写 + 回读）。
    -- 两条的重试都**不危险**（写的是观测到的合法值），所以只跳过这一颗。
    ['arrival proximity suppression failed']=true,
    ['arrival clear failed']=true,

    -- ★★ 2026-10-01 实机事故：`arrival trigger changed` 本来被**误**归为 fail-closed ★★
    --
    -- 当时的理由（写在下面"有意不列入"里）是"它在 `explode(...)` 之后" ——
    -- **这条理由是错的**。它在引爆分支的**最开头**：
    --     if action=='detonate' then
    --         assert(… ,'arrival trigger changed')      ← 这里，explode 之前
    --         mutated=true
    --         scope.calls.explode(…)                    ← explode 在这之后
    -- 真正在 explode 之后的是 `arrival request not committed` 与
    -- `arrival request changed flight state`（那两条确实必须 fail-closed）。
    --
    -- 后果（用户报"又出现失效情况了"，日志末三行）：
    --     arrival_skipped;entity=577;…:2727: arrival trigger changed
    --     frame_error;…:6586: arrival operation disabled
    --     disabled;applied=0            ← 整局 mod 停手、日志当场关闭
    -- 为什么会走到 `disabled=true`：点目标路径**在引爆判定之前**就要写 record
    -- （把 ping 的地面点写成点目标选择）⇒ 本帧 `mutated` 已经为 true ⇒
    -- `if mutated and not early then disabled=true end` 把 arrival 段永久关掉。
    -- 而这次断言本身就是**假警报**（参照系取错，详见 native_arrival 的
    -- `flight_reference`），既没写坏内存也没发过爆炸请求 —— 重试完全安全。
    --
    -- 所以它属于竞争态：失败时**只放弃这一颗** G-60，下一帧照常重试/重接管。
    ['arrival trigger changed']=true,

    -- ⚠ 有意**不**列入竞争态（保持 fail-closed，逐个评估的结论）：
    --   · `arrival request not committed` / `arrival request changed flight state`
    --     —— 都在 `explode(...)` **之后**，失败时爆炸请求可能已经发出；
    --     重试会重复触发引爆，风险等级与"写后回读不符"不同，不能混进来。
    --   · `arrival source changed` / `arrival behavior changed` / `arrival preflight changed` /
    --     `arrival aim observation changed` —— 两次读之间 record 变了，属于**行为观测**漂移。
    --   · `arrival changed flight timer` / `arrival orbit changed timer` —— 飞行计时器被动，
    --     是真正的行为异常（上游明确警告过别重置它），必须停手。
    --   · `arrival ABI` / `arrival call ABI` / `arrival source` / `arrival scope unavailable` /
    --     `arrival experimental scope` —— 结构性校验，属于版本漂移。
}

-- 同一帧里多颗 G-60 全部竞争态失败，说明不是单点时序而是我们对引擎状态的理解
-- 出问题了 —— 这时停手才是对的。实机同场最多 2 颗在飞，所以 4 不会误触发。
M.CONTENTION_LIMIT=4

function M.competitive(message)
    local s=tostring(message)
    if M.COMPETITIVE[s] then return true end
    -- ★★ pcall 捕获的 error **带 `chunkname:line: ` 前缀** ★★
    -- 2026-09-28 实机闪退前一刻的日志：
    --   ...:2293: priority setter target mismatch
    -- 而我这里只匹配了裸消息 ⇒ 拦截失败 ⇒ 走了 `disabled=true` ⇒ 整局死亡。
    -- （同一处 bug 在 00:36 那轮就暴露过一次，当时没修，转去查别的了。）
    -- 现在先按 `^.-:%d+: ` 剥掉位置前缀再精确比对 —— 仍然是精确匹配，
    -- 不用模糊包含，避免把别的消息误判成竞争态。
    local stripped=s:match('^.-:%d+:%s*(.*)$')
    return stripped~=nil and M.COMPETITIVE[stripped]==true
end

-- ★ state-3 接管实验（2026-09-28）
--
-- 现象：附近没有敌人可锁时，G-60 一直停在 state 3（起飞/搜索），
--       而整条链路（runtime 入口 / priority 断言 / Minimal 断言）都只认 state 4
--       ⇒ 我们永远接管不了 ⇒ "标记了虫洞但 G-60 不飞过去"。
--
-- 能不能让 G-60 进入 state 4？思路是：`clear(pair, data)` 本身就是设置 selection
-- 的 setter —— 在 state 3 就把虫洞设成目标，引擎看到有目标就可能推进到 state 4。
--
-- 风险（安全层的原话必须尊重）：native_minimal 写着
--   "Never call the state-3 transition, which resets the flight timer."
-- 但那句警告的是**别用 state-3 那组参数**去调 orbit；我们用的仍是上游那组
-- (10.0, 2.5, 1.2)，而且 priority 的 check() 每次调用都会校验 flight timer
-- (record:sub(0x189,0x190))——**一旦被重置，断言立刻失败**。
--
-- 所以这个实验是"可自毁"的：
--   · state 3 时**只设目标**，不做 titan 航点、不做 arrival 引爆（那两套要 movement
--     结构就绪，state 3 时可能还没初始化）；
--   · 一旦观测到 flight timer / behavior 变化，就**永久禁用 state-3 路径**，
--     退回原来的 state-4-only 行为，而不是让整个 mod 停手。
M.ALLOW_STATE3=false          -- 由 entry 的 env.allow_state3 打开
M.STATE3_DANGER={
    ['priority behavior or flight timer changed']=true,
    ['priority source changed']=true,
    ['priority source mismatch']=true,
    ['priority point setter mismatch']=true,
}

return M
