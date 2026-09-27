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
    return api
end
return M
