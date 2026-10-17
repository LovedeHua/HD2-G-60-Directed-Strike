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
        -- ★★★ 2026-10-14（用户要求）：远距离追踪的接管距离上限 ★★★
        --   ⚠ 2026-10-14 用户实机修正：**只保留结构目标的说明**。
        --     泰坦/蟑龙**不由本项控制** —— 它们走各自专门的链路（泰坦靠**引擎选中**
        --     触发 `titan_selected`，再由泰坦链引导），标记门那个数字管不到它们。
        --     ⇒ 说明里不再提"其他敌人 100 m"，免得说出一个不成立的规则。
        ['max_takeover_distance.label'] = 'Max takeover range: structures (m)',
        ['max_takeover_distance.desc'] =
            'How far away a marked STRUCTURE (bug hole / fabricator / Shrieker nest / Spore Spewer / landed warp ship / broadcast tower) may be and still be taken over. Structures only (default 250). The non-structure range is the separate item below',
        --    ⚠ 用户 2026-10-14 报「现在的都不知道在说谁的放手距离」⇒
        --     上面那个开关撤出菜单后，光看"Release distance"看不出对象是谁。
        --     ⇒ label 里**点名对象**（Titan approach），desc 里补全机制。
        -- ★★★ 2026-10-14（用户最终方案）：接近标记的泰坦后放手 ★★★
        -- ★★★ 2026-10-14（第二轮，用户要求：泰坦与其他敌人合并成一档）★★★
        ['other_takeover_distance.label'] = 'Max takeover range: other targets (m)',
        ['other_takeover_distance.desc'] =
            'How far away a marked non-structure target (Titan / Titan variant / Dragonroach / ordinary enemy ...) may be and still be taken over. Titian family and other enemies share this one value. The structure range above is separate. Default 200',
        ['mark_retain_seconds.label'] = 'Keep marks alive after the icon fades (s)',
        ['mark_retain_seconds.desc'] =
            'A marker icon only lives about 8 s, but a G-60 flying to a distant target can take longer than that. With this above 0 the mod keeps remembering the mark for this many seconds after the icon fades, so you can still throw at it. 600 s is effectively the whole match. 0 = off (default). A mark you cancel yourself (icon vanishes long before its 8 s) is dropped immediately',
        -- ★★★ 2026-10-16 → 2026-10-17：泰坦爆点窗口 —— **两侧文案都已撤掉** ★★★
        --   用户最终要求：「前后没必要调整，去掉相关设置」⇒ 上下（固定 2.4~2.6）与
        --   前后（不做）都**没有菜单项** ⇒ 这里也不能有对应文案。
        --   ⚠ 留着文案会被 `menu_text` 自检判为「有文案、无对应菜单项」（双语守门的既有判据）。
        -- ★★★ 2026-10-14（用户要求「安全区以引爆点为中心」）★★★
        ['blast_safe_lift.label'] = 'Safe zone orbit height',
        ['blast_safe_lift.desc'] =
            'Vertical lift (metres) of the orbit/hold point above the target. With orbit radius 0 the grenade sits directly above the target at this height. NOTE: below 3 m the fuse keep-out pushes it away, so it drifts instead of hovering',
        ['mark_priority_enabled.label'] = 'Priority reassignment',
        ['mark_priority_enabled.desc'] = 'Reassign spare grenades by the priority roster when nothing is marked',
        ['point_target_enabled.label'] = 'Empty-ping point target',
        ['point_target_enabled.desc'] = 'Take over grenades aimed at an empty ping (ground point)',
        ['titan_family.label'] = 'Titan family blast-point tuning',
        ['titan_family.desc'] = 'Blast-point tuning for Bile/Spore Titans, Titan variants and the Dragonroach. One switch for all three chains (Titan, variants, Dragonroach)',
        ['safe_zone_group.label'] = 'Safe zone enforcement',
        ['safe_zone_group.desc'] = 'Engine-aimed grenade hold + clearing the engine selection. WARNING: turning this off removes the fallback for grenades the mod does not drive',
        ['structure_group.label'] = 'Structure takeover',
        ['structure_group.desc'] = 'Long-range takeover for marked structures (bugholes, fabs, nests, landed ships) and their calibrated blast sites',
        ['safe_zone_target_radius.label'] = 'Safe zone radius',
        ['safe_zone_target_radius.desc'] =
            'One radius for the whole safe zone (metres): no detonation while a player is within it of the EXPECTED BLAST POINT, of the G-60 itself, or (for point-blank cancellation) close enough that the blast would hit you. 0 = safe zone off',
        ['blast_safe_orbit.label'] = 'Safe zone orbit radius',
        ['blast_safe_orbit.desc'] =
            'While the safe zone holds the grenade it orbits the target at this radius (metres); larger keeps it further away. 0 = no horizontal orbit: it hovers 2 m above the target (the point carries a +2 m lift)',
        ['friendly_veto_enabled.label'] = 'Clear friendly locks',
        ['friendly_veto_enabled.desc'] =
            'When the engine is locked onto a friendly or neutral unit, clear it so the grenade can be taken over. The ping marker itself cannot be removed',
        ['allow_state3.label'] = 'Early takeover',
        ['allow_state3.desc'] = 'Allow taking over the G-60 early, while it is still in state 2/3',
        -- ★★★ 2026-10-14（用户要求）：自机探针**并进**诊断日志开关 ★★★
        ['diagnostics_enabled.label'] = 'Diagnostic logging (incl. self probe)',
        ['diagnostics_enabled.desc'] =
            'Write high-volume diagnostics to the mod log (perf, sel_probe, link, mark_queue, takeover_probe, selfprobe, ...). Off = quiet log. Evidence lines needed to judge success/failure are ALWAYS kept',
        -- ★★★ 2026-10-14（用户要求）：分配机制的两个上限 ★★★
        ['max_grenades_per_target.label'] = 'Grenades per target (one mark)',
        ['max_grenades_per_target.desc'] =
            'With a single mark on the field, how many G-60s may track that one target at the same time (1 = old behaviour)',
    },
    ['zh-Hans'] = {
        ['mod'] = 'G-60定向打击',
        -- ★★★ 2026-10-14（用户要求）：远距离追踪的接管距离上限 ★★★
        --   ⚠ 2026-10-14 用户实机修正：**只保留结构目标的说明**（泰坦等不由本项控制）。
        --   ⚠ 同日第二轮：距离**合并成两档**后，两个滑块名字太像 ⇒
        --     这条**点名"结构目标"**，与下面那条"其他目标"对称（否则看不出在说谁）。
        ['max_takeover_distance.label'] = '接管距离上限：结构目标（米）',
        ['max_takeover_distance.desc'] =
      '标记的结构目标（虫洞/构筑/尖啸巢/孢子喷涌虫/落地穿梭舰/广播台）离多远之内才接管。只影响这些结构目标（默认250）。非结构目标见下面那一项',
        -- ★★★ 2026-10-14（用户最终方案）：接近标记的泰坦后放手 ★★★
        --   ⚠ 用户同日报「现在的都不知道在说**谁的**放手距离」⇒
        --     上一个开关撤出菜单后，光看"放手距离"看不出对象 ⇒ label 点名对象、
        --     desc 补全"先驱动过去、再放手让链接管"这条机制。
        -- ★★★ 2026-10-14（第二轮，用户要求：泰坦与其他敌人合并成一档）★★★
        ['other_takeover_distance.label'] = '接管距离上限：其他目标（米）',
        ['other_takeover_distance.desc'] =
      '标记的非结构目标（泰坦/泰坦变体/蟑龙/普通敌人等）离多远之内才接管。泰坦家族与其他敌人共用这一个值。上面那个结构距离是另一档。默认200',
        ['mark_retain_seconds.label'] = '图标消失后仍认标记（秒）',
        ['mark_retain_seconds.desc'] =
      '标记图标只活约8秒，而G-60飞远距离目标可能更久。这个值大于0时，图标消失后再保留这么久，你仍然可以扔雷追踪它。600秒约等于整局残留标记。0 =关闭（默认）。注意：你主动取消的标记不算数（图标远早于8秒就消失，立即丢弃）；已在飞的那颗不受影响',
        -- ★★★ 2026-10-16 → 2026-10-17：泰坦爆点窗口 —— **两侧文案都已撤掉** ★★★
        --   用户最终要求「前后没必要调整，去掉相关设置」⇒ 与上方英语侧同理，
        --   没有菜单项就不能有文案（否则 menu_text 自检报错）。
        -- ★★★ 2026-10-14（用户要求「安全区以引爆点为中心」）★★★
        ['blast_safe_lift.label'] = '安全区绕行高度',
        ['blast_safe_lift.desc'] = '绕行/压住点在目标上方的抬升高度（米）。绕行半径为0时，手雷就在这个高度悬停于目标正上方。注意：低于3米会被引信保护推走（实际变成缓振）',
        ['mark_priority_enabled.label'] = '优先级改派',
        ['mark_priority_enabled.desc'] = '无标记时按名册优先级主动改派手雷',
        ['point_target_enabled.label'] = '空ping点目标',
        ['point_target_enabled.desc'] = '空ping（地面点）接管：把手雷引到该点',
        ['titan_family.label'] = '泰坦族引爆点调整',
        ['titan_family.desc'] = '吐酸/孢子泰坦、泰坦变体、蟑龙的引爆点调整。一个开关同时管泰坦、变体、蟑龙三条链',
        ['safe_zone_group.label'] = '安全区压制组',
        ['safe_zone_group.desc'] = '引擎自瞄雷的兜底闸+清掉引擎自己的选中。注意：关掉本组会失去对本mod没接管的雷的兜底',
        ['structure_group.label'] = '结构接管组',
        ['structure_group.desc'] = '标记结构（虫洞/构筑者/尖啸巢/落地飞船）的远距离接管+它们的标定炸点',
        ['safe_zone_target_radius.label'] = '安全区半径',
        ['safe_zone_target_radius.desc'] =
      '整个安全区共用的唯一半径（米）：玩家在此半径内时不引爆。判据包括离预期引爆点、离手雷本体、以及贴脸取消的危险距离（取半径与7的较小值）；0 =整个安全区关闭',
        ['blast_safe_orbit.label'] = '安全区绕行半径',
        ['blast_safe_orbit.desc'] = '安全区生效时手雷绕目标盘旋的半径（米）；越大离目标越远。0 =不水平绕行，改为悬停在目标正上方（高度由安全区绕行高度那一项决定）',
        ['friendly_veto_enabled.label'] = '清除友方锁定',
        ['friendly_veto_enabled.desc'] = '引擎锁着友方/中性单位时把它清掉（手雷才能被接管），无法抹掉游戏里那个ping标记本身',
        ['allow_state3.label'] = '早期接管',
        ['allow_state3.desc'] = '允许在state 2/3早期接管G-60',
        -- ★★★ 2026-10-14（用户要求）：自机探针**并进**诊断日志开关 ★★★
        ['diagnostics_enabled.label'] = '诊断日志（含自机探针）',
        ['diagnostics_enabled.desc'] =
      '把高频诊断写进mod日志（perf、sel_probe、link、mark_queue、takeover_probe、自机探针等）。关掉=日志安静。注意：判断成败所需的证据行永远保留',
        -- ★★★ 2026-10-14（用户要求）：分配机制的两个上限 ★★★
        ['max_grenades_per_target.label'] = '单标记：每目标手雷数',
        ['max_grenades_per_target.desc'] =
            '场上只有1个标记时，允许几颗G-60同时追它（1 =维持原行为）',
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
