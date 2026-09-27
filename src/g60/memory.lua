local U = require('g60.util')
local V = require('g60.validity')
local M = {}; M.__index = M
function M.new(api, scene)
    return setmetatable({api = api, scene = scene, owners = {}}, M)
end
function M:observe(owner, ref, readable, now)
    if type(owner) ~= 'string' or owner == '' then return false end
    local s = self.owners[owner] or {}
    self.owners[owner] = s
    s.readable, s.current = readable == true, nil
    if s.readable and ref then
        local e = V.entity(self.api, ref, self.scene)
        if e then
            s.current = U.ref(ref)
            s.last_marked_target = U.ref(ref)
            s.last_marked_target_id = ref.id
            s.last_marked_target_type = e.kind
            s.last_mark_time = U.finite(now) and now or nil
        end
    end
    return true
end
function M:get(owner, projectile)
    local s = self.owners[owner]
    -- Unreadable differs from a successfully read empty/UI-expired ping.
    if not s or not s.readable then return nil, 'PING_UNAVAILABLE' end
    local ref = s.current or s.last_marked_target
    local e = ref and V.entity(self.api, ref, self.scene)
    if e and V.track(self.api, e, projectile, true) then
        return e, s.current and 'current' or 'remembered'
    end
    s.current, s.last_marked_target = nil, nil
    s.last_marked_target_id, s.last_marked_target_type, s.last_mark_time = nil, nil, nil
    return nil, 'NO_VALID_MARK'
end
function M:forget(owner) self.owners[owner] = nil end
return M
