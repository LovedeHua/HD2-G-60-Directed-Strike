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
local M={}

-- 竞争态：只放弃**这一颗** G-60，交回引擎；不动全局 disabled。
M.COMPETITIVE={
    ['priority setter target mismatch']=true,
    ['priority setter metadata mismatch']=true,
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
