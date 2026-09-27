local U = require('g60.util')
local M = {}
function M.entity(api, ref, scene)
    if not U.ref(ref) or ref.scene ~= scene then return nil end
    local e = U.call(api, 'resolve', U.ref(ref))
    if type(e) ~= 'table' or U.key(e.ref) ~= U.key(ref)
        or e.exists ~= true or e.active ~= true or e.destroyed ~= false
        or (e.kind ~= 'bug_hole' and e.alive ~= true)
        or not U.vector(e.position) then return nil end
    if e.kind ~= 'bug_hole' and (e.hostile ~= true or e.targetable ~= true) then return nil end
    return e
end
function M.track(api, e, projectile, marked)
    if not e or (e.kind == 'bug_hole' and not marked) then return false end
    -- This callback validates original range, guidance, visibility/target-lost
    -- constraints; never substitute a guessed range or widen other weapons.
    return U.call(api, 'can_track', projectile, e, marked) == true
end
return M
