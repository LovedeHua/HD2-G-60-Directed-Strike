-- Local-player allocation only; these keys are observations, not lifetime leases.
local M={}
local function identity(bytes)
    assert(type(bytes)=='string' and #bytes==24,'reservation identity required')
    -- Activity flags may change while the same entity still exists.
    return bytes:sub(1,20)
end
function M.owner(match) return identity(match.identity_bytes) end
function M.new()
    local targets={}
    local api={}
    function api:reset() targets={} end
    function api:reconcile(matches)
        -- Only call after a complete accepted observation, never after a failed
        -- read, skipped update, or a list filtered down to guidable projectiles.
        local present={}
        for _,m in ipairs(matches) do present[M.owner(m)]=true end
        for key,owner in pairs(targets) do if not present[owner] then targets[key]=nil end end
    end
    function api:available(owner,target)
        local held=targets[identity(target)]
        return held==nil or held==owner
    end
    function api:claim(owner,target)
        local key=identity(target)
        assert(targets[key]==nil or targets[key]==owner,'target already reserved')
        targets[key]=owner
    end
    -- ★ 放弃某颗 G-60 时必须把它名下**所有**预约都还回去（2026-09-27）。
    -- 预约是 target -> owner 的正向映射，没有 owner 侧的释放口；一旦放弃一颗 G-60
    -- 却留着它的预约，那个虫洞对所有其他 owner 的 available() 都返回 false ——
    -- 表现为"这个虫洞从此再也接管不了"，比原来的全局停手更难查。
    function api:release_owner(owner)
        for key,held in pairs(targets) do if held==owner then targets[key]=nil end end
    end
    return api
end
return M
