-- 只读几何诊断：G-60 距"当前标记虫洞爆点"的水平/垂直距离。
--
-- 为什么需要它（2026-09-28 实机）：
--   日志里 12 次 priority_locked 只有 3 次真正引爆，5 次被 arrival_retired
--   **静默移除**（native_disposal 只 remove 不 explode —— 见该文件第 1 行）。
--   但过去所有日志行都不带"当时离虫洞多远"，于是判别成败只能靠猜：
--     猜 orbit 环绕半径 2.5m   → 被 early_probe 的 76m/18m/14m 否掉
--     猜"需要附近有敌人"        → 被 flight expired 证据否掉
--     猜进场绕行太远            → 被成功案例"从背面接近照样成功"否掉
--   三次都错。所以必须让数据自己说话。
--
-- ★ 设计约束（重要）★
--   这个模块**不自己读内存**。G-60 的坐标由 Search.capture 读出并放进
--   `own_position_bytes`（见 native_search_context.lua:128），我们只做算术。
--   原因：那份坐标依赖一个**开放寻址哈希表**（hash_index，search_context:69-87），
--   自己重算等于复制安全层代码 —— 一旦布局猜错就是静默读错位置，
--   比拿不到数据更糟（我第一版就写了 `id*4` 的错误索引，验证时才发现）。
--
--   同理本模块**零 ffi 依赖**，因此可以在测试环境（lupa）里真跑验证。
--
-- ★ 覆盖盲区（汇报时必须照实说）★
--   那 195 个测试跑的是 g60/core.lua 的**纯 Lua 策略层**，跑不到 runtime
--   与本模块的调用链。本模块的纯几何部分（decode/gap/describe）能被
--   tests/test_priority_fault_isolation.py 第 ⑧ 组**真跑**验证；
--   但"runtime 是否在正确时机调用它"只能靠结构断言 + 实机日志。
--   ⇒ 不要说"测试验证了诊断正确"，要说"几何计算已验证，链路待实机确认"。
local M={}

-- 从 12 字节 position buffer 解出坐标。非法/非有限值一律返回 nil。
--
-- 用 string.unpack("<f",...) 而不是手写位运算：**手写 f32 我写错过两次**
--   （符号位判断对无符号整数恒真、指数掩码算错），而且这种 bug 只在
--   特定字节值上发作 —— 实机坐标恰好含 0x5c，直接解出垃圾数据还"看起来有值"。
--   教训与 hash_index 同类：能复用成熟实现就别自己重写底层。
function M.decode(position_bytes)
    if type(position_bytes)~='string' or #position_bytes~=12 then return nil end
    local x,y,z=string.unpack('<fff',position_bytes)
    if not (x and y and z) then return nil end
    -- nan / inf 判定。不要用 math.type 做类型门禁：Lua 5.5 里
    -- math.type(1.5)=='float'（不是 'number'），会误杀所有正常值。
    if x~=x or y~=y or z~=z then return nil end
    if math.abs(x)==math.huge or math.abs(y)==math.huge
        or math.abs(z)==math.huge then return nil end
    if math.abs(x)>1e6 or math.abs(y)>1e6 or math.abs(z)>1e6 then return nil end
    return {x,y,z}
end

-- G-60 相对目标点的水平/垂直/直线距离。任一输入缺失即返回 nil。
function M.gap(own,point)
    if not own or not point then return nil end
    for k=1,3 do
        if type(own[k])~='number' or type(point[k])~='number' then return nil end
    end
    local dx,dy,dz=own[1]-point[1],own[2]-point[2],own[3]-point[3]
    return {horiz=math.sqrt(dx*dx+dy*dy),dz=dz,
        flat=math.sqrt(dx*dx+dy*dy+dz*dz)}
end

-- generate 日志后缀。geo 为 nil 时返回空串（避免 `;horiz=nil` 这种脏输出）。
function M.describe(geo)
    if not geo then return '' end
    return ';horiz='..tostring(geo.horiz)..';dz='..tostring(geo.dz)
        ..';flat='..tostring(geo.flat)
end

-- 便捷组合：position buffer + 目标点 → 日志后缀。
function M.report(position_bytes,point)
    return M.describe(M.gap(M.decode(position_bytes),point))
end

return M
