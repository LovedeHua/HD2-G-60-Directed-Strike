local M = {}
function M.finite(v)
    return type(v) == 'number' and v == v and v > -math.huge and v < math.huge
end
function M.vector(v)
    return type(v) == 'table' and M.finite(v.x) and M.finite(v.y) and M.finite(v.z)
end
function M.ref(v)
    if type(v) ~= 'table' or type(v.id) ~= 'string' or v.id == ''
        or type(v.generation) ~= 'string' or v.generation == ''
        or type(v.scene) ~= 'string' or v.scene == '' then return nil end
    return {id = v.id, generation = v.generation, scene = v.scene}
end
function M.key(v)
    local r = M.ref(v)
    if not r then return nil end
    -- Length prefixes avoid ambiguity; native 64-bit IDs must remain strings.
    return #r.scene .. ':' .. r.scene .. #r.id .. ':' .. r.id
        .. #r.generation .. ':' .. r.generation
end
function M.distance2(a, b)
    if not M.vector(a) or not M.vector(b) then return math.huge end
    return (a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2
end
function M.call(api, name, ...)
    if type(api[name]) ~= 'function' then return nil, 'missing_' .. name end
    local ok, value, detail = pcall(api[name], api, ...)
    if not ok then return nil, 'error_' .. name end
    return value, detail
end
return M
