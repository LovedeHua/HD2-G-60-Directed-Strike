-- Mod Options Menu 的文案 + **跟随游戏语言**（2026-10-10 用户要求：
--   「mod设置的语言要能跟随游戏语言变化，比如说游戏语言是英语，mod设置显示的也是英语」）。
--
-- 机制（照同工程 Aggro Counter 的 Bingus Text 做法，只保留菜单需要的那部分）：
--   ① 读**游戏自己的 Text Language 设置**（game.dll 设置表 → 索引 → 记录 → 字符串）
--      ⇒ 游戏语言代码（如 `us` / `cn`）⇒ BCP 47 tag；
--   ② 读不到 ⇒ **英语**（fail-safe：宁可显示英语，也不显示键名/空白）。
--      ⚠ **不查 Steam 语言**：那需要**动态符号解析**，而本工程构建器把它列为高危面、
--        一律禁止（见下方说明）。游戏自己的设置本来就是"游戏语言"的权威来源。
--   ⚠ 菜单 API 的 `version>=2` 时 label/description/mod 可以是**函数**，菜单每次打开都会
--     调用 ⇒ **运行期改了语言也能跟上**（不用重开游戏）。`version<2` 只能吃字符串，
--     且按字节上限（label≤64 / description≤400 / mod≤40），装不下就退回英语。
--   ⚠ 全程 pcall + 指针合法性检查：设置表在启动早期可能是空的 ⇒ 那种情况必须安静退回
--     英语。菜单注册在主链路上，这里**绝不能抛错**。
--   ⚠ 本模块**不碰 ffi**（除了 steam 那条被 pcall 包住的分支），也不需要 env：
--     `read`/`base` 由 entry 传进来 ⇒ 可以脱离游戏在离线守门里直接跑。
local M = {}

-- 游戏 Text Language 代码 → BCP 47。
-- ⚠ 我们只出 `en` 与 `zh-Hans` 两套文案：**所有英语变体都归到 `en`**（en-GB/en-US 等
--   显示英语本身就是对的）；其余语言映射到自己的 tag ⇒ 匹配不到翻译 ⇒ 显示英语
--   （这是刻意的 fail-safe，不是漏翻译）。未列出的代码**原样当 tag**，效果相同。
M.CODES = {
    us = 'en', en = 'en', ['en-US'] = 'en', gb = 'en', uk = 'en', ['en-GB'] = 'en',
    au = 'en', ['en-AU'] = 'en', ca = 'en', nz = 'en',
    cn = 'zh-Hans', zh = 'zh-Hans', zhs = 'zh-Hans', ['zh-CN'] = 'zh-Hans',
    ['zh-SG'] = 'zh-Hans', schinese = 'zh-Hans',
    tw = 'zh-Hant', hk = 'zh-Hant', ['zh-TW'] = 'zh-Hant', ['zh-HK'] = 'zh-Hant',
    kr = 'ko', ko = 'ko', jp = 'ja', ja = 'ja', de = 'de', fr = 'fr', it = 'it',
    es = 'es', mx = 'es-419', pl = 'pl', ru = 'ru', br = 'pt-BR', pt = 'pt',
}

-- ⚠⚠ **不用 Steam 语言做退路**（2026-10-10 决定）：同工程的 Bingus Text 会在游戏设置
--   读不到时去 steam_api64.dll 取当前语言，但那需要**动态符号解析**；本工程的构建器把
--   动态符号解析、内存分配与改写类能力**一律禁止**（`scripts/build.py` 的 `assemble()`
--   断言，理由写在它的注释里：「那些才是真正的高危面」）。
--   ⇒ 这里只读**游戏自己的 Text Language 设置**（那本来就是用户要的"游戏语言"），
--     读不到就显示**英语**。少一条退路，但换来"不引入动态符号解析"这条硬边界。
--   ⚠ 注意：连**注释里写出那些符号名**都会被构建器的子串断言拦下（实测被拦过一次）
--     ⇒ 本文件通篇不出现那些名字。

-- 游戏设置表布局（game.dll 相对偏移）。与同工程 Aggro Counter 用的是同一份 dump：
-- 它的 owner/id_map/entities 三个偏移与本工程 d.root 完全一致 ⇒ 同一版本。
-- ⚠ 本项目另有 `game_guards` 校验游戏布局（代码字节比对），布局不匹配时 mod 根本不会加载。
M.GAME = {settings = 0x3326340, index = 705500 + 212, table = 0x37C5650, count = 15}

-- 读游戏 Text Language 的**代码**（如 'us'/'cn'），读不到返回 nil。
-- `read(address,size)` 与 `base`（game.dll 基址）由 entry 提供；全程 pcall。
function M.game_code(read, base)
    local ok, code = pcall(function()
        if type(read) ~= 'function' or type(base) ~= 'number' then return nil end
        local g = M.GAME
        local function load(address, size)
            local fine, bytes = pcall(read, address, size)
            if fine and type(bytes) == 'string' and #bytes == size then return bytes end
        end
        -- 8 字节小端指针，带合法性窗口（0x10000 ~ 2^47）：设置表在启动早期是空的。
        local function pointer(address)
            local bytes = load(address, 8)
            if not bytes then return nil end
            local value = 0
            for k = #bytes, 1, -1 do value = value * 256 + bytes:byte(k) end
            if value >= 65536 and value < 2 ^ 47 then return value end
        end
        local settings = pointer(base + g.settings)
        if not settings then return nil end
        local raw = load(settings + g.index, 4)
        if not raw then return nil end
        local index = 0
        for k = 4, 1, -1 do index = index * 256 + raw:byte(k) end
        if index >= g.count then return nil end
        local record = pointer(base + g.table + 8 * index)
        local text = record and pointer(record + 8)
        if not text then return nil end
        local bytes = load(text, 16) or load(text, 8)
        local found = bytes and bytes:match('^(%a[%a%-]*)%z')
        if found and #found <= 12 then return found end
    end)
    return ok and code or nil
end

-- 解析当前语言 tag：**游戏自己的 Text Language 设置** → 英语。
-- 返回 (tag, 来源)。来源字符串直接进日志（`menu_lang;tag=…;src=game|default`）⇒ 实机可判读。
function M.language(read, base)
    local code = M.game_code(read, base)
    if code then return M.CODES[code] or code, 'game' end
    return 'en', 'default'
end

-- ★★ 文案表 ★★
--   key 规则：`mod`（菜单里那一栏的标题）、`<item>.label`、`<item>.desc`。
--   ⚠ `en` 必须**覆盖每一个键**（守门 M.check 会查）—— 英语客户端绝不能看到中文或键名。
M.TEXT = {
    en = {
        ['mod'] = 'G-60 Directed Strike',
        ['blast_safe_radius.label'] = 'Blast safe zone radius',
        ['blast_safe_radius.desc'] =
            'While a player is within this radius (metres) the G-60 will not detonate and keeps tracking its target. 0 = off',
        ['blast_safe_orbit.label'] = 'Safe zone orbit radius',
        ['blast_safe_orbit.desc'] =
            'While the safe zone holds the grenade it orbits the target at this radius (metres); larger keeps it further away',
        ['safe_zone_engine_hold.label'] = 'Hold engine-aimed G-60s',
        ['safe_zone_engine_hold.desc'] =
            'Experimental: also hold G-60s the engine aimed at enemies while a player is in the safe zone (see safe_engine_* in the log)',
        ['safe_zone_veto_selection.label'] = 'Clear engine selection',
        ['safe_zone_veto_selection.desc'] =
            'Experimental: while a player is in the zone and the grenade is inside the cancel line, clear the engine\'s selected target so the fuse has nothing to hit (see safe_veto_* in the log)',
        ['friendly_veto_enabled.label'] = 'Clear friendly locks',
        ['friendly_veto_enabled.desc'] =
            'When the engine is locked onto a friendly or neutral unit, clear it so the grenade can be taken over. The ping marker itself cannot be removed',
        ['force_lock_enabled.label'] = 'Force takeover with no enemies',
        ['force_lock_enabled.desc'] =
            'Promote the G-60 to a guidable state when no enemy is around (the only memory-write path in this mod)',
        ['allow_state3.label'] = 'Early takeover',
        ['allow_state3.desc'] = 'Allow taking over the G-60 early, while it is still in state 2/3',
        ['self_probe_enabled.label'] = 'Self probe',
        ['self_probe_enabled.desc'] = 'Read-only: log the local player entity and position (diagnostics)',
        ['enemy_veto_enabled.label'] = 'Vehicle veto',
        ['enemy_veto_enabled.desc'] = 'Do not let the G-60 chase the dropship or the Illuminate reinforcement ship',
    },
    ['zh-Hans'] = {
        ['mod'] = 'G-60 定向打击',
        ['blast_safe_radius.label'] = '爆炸安全区半径',
        ['blast_safe_radius.desc'] = '玩家在这个半径（米）内时 G-60 不引爆，继续追踪目标；0=关闭',
        ['blast_safe_orbit.label'] = '安全区绕行半径',
        ['blast_safe_orbit.desc'] = '安全区生效时手雷绕目标盘旋的半径（米）；越大离目标越远',
        ['safe_zone_engine_hold.label'] = '安全区管引擎自瞄的雷',
        ['safe_zone_engine_hold.desc'] = '实验：玩家在安全区内时，连引擎自己瞄敌人的 G-60 也一起压住（看 safe_engine_* 日志判读）',
        ['safe_zone_veto_selection.label'] = '安全区清引擎的选择',
        ['safe_zone_veto_selection.desc'] = '实验：玩家在圈内且手雷已贴到取消线以内时，清掉引擎选中的目标（引信就没有可撞的对象）。看 safe_veto_* 日志判读',
        ['friendly_veto_enabled.label'] = '清除友方锁定',
        ['friendly_veto_enabled.desc'] = '引擎锁着友方/中性单位时把它清掉（手雷才能被接管）—— 无法抹掉游戏里那个 ping 标记本身',
        ['force_lock_enabled.label'] = '无敌人强制接管',
        ['force_lock_enabled.desc'] = '无敌人时把 G-60 提升为可引导状态（本工程唯一的写内存路径）',
        ['allow_state3.label'] = '早期接管',
        ['allow_state3.desc'] = '允许在 state 2/3 早期接管 G-60',
        ['self_probe_enabled.label'] = '自机探针',
        ['self_probe_enabled.desc'] = '只读输出玩家实体与坐标（诊断用）',
        ['enemy_veto_enabled.label'] = '载具否决',
        ['enemy_veto_enabled.desc'] = '不让 G-60 追运输船 / 光能族增援飞船',
    },
}

-- 取一条文案：`lang` 给定就用它，否则用 `M.current`（由 new() 维护）。
-- 任何缺失都**退回英语**；连英语都没有就退回键名（宁可难看，也不能是 nil ⇒ 菜单会崩）。
function M.text(lang, key)
    local pack = M.TEXT[lang or 'en']
    local value = pack and pack[key]
    if value then return value end
    return M.TEXT.en[key] or key
end

-- 一个"跟随游戏语言"的取词器。返回 (tr, resolve)：
--   tr(key[, lang]) —— 取文案；不带 lang 时**每次调用都重新读游戏语言**
--                      （菜单 v2 每次打开都会调用 ⇒ 运行期改语言也能跟上）。
--   resolve()       —— 返回 (tag, 来源)，供日志判读。
function M.new(read, base)
    local function resolve()
        local code = M.game_code(read, base)
        if code then return M.CODES[code] or code, 'game' end
        return 'en', 'default'
    end
    local function tr(key, lang)
        if lang then return M.text(lang, key) end
        return M.text((resolve()), key)
    end
    return tr, resolve
end

-- ★ 自检（离线守门直接跑这个）：
--   ① 英语必须覆盖每一个键（英语客户端绝不能看到中文/键名）；
--   ② 两套文案的**键集合必须一致**（缺一个就是漏翻译）；
--   ③ 英语 label ≤64 字节、desc ≤400 字节（v1 菜单的字节上限；超了会退回英语，
--      而英语本身超了就没得退 ⇒ 必须在这里拦住）。
function M.check()
    local problems = {}
    local function keys(t)
        local out = {}
        for k in pairs(t) do out[#out + 1] = k end
        table.sort(out)
        return out
    end
    for _, k in ipairs(keys(M.TEXT['zh-Hans'])) do
        if not M.TEXT.en[k] then problems[#problems + 1] = 'en missing: ' .. k end
    end
    for _, k in ipairs(keys(M.TEXT.en)) do
        if not M.TEXT['zh-Hans'][k] then problems[#problems + 1] = 'zh-Hans missing: ' .. k end
        local value = M.TEXT.en[k]
        if k:match('%.label$') and #value > 64 then
            problems[#problems + 1] = 'en label too long (' .. #value .. '): ' .. k
        end
        if k:match('%.desc$') and #value > 400 then
            problems[#problems + 1] = 'en desc too long (' .. #value .. '): ' .. k
        end
    end
    return problems
end

return M
