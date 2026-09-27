-- Configuration identity only. A native adapter must read/revalidate these fields.
-- This does not prove ownership, liveness, generation, or a writable target slot.
local M = {}
M.resource = '8e325c933e55bf62'
M.behavior_id = 4
local function hash(value)
    if type(value) ~= 'string' or #value ~= 16 or value:find('[^%x]') then return nil end
    return value:lower()
end
function M.matches(snapshot)
    return type(snapshot) == 'table'
        and hash(snapshot.resource) == M.resource
        and hash(snapshot.unit_resource) == M.resource
        and snapshot.behavior_id == M.behavior_id
        and type(snapshot.components) == 'table'
        and snapshot.components.throwable == true
        and snapshot.components.explosive == true
end
return M
