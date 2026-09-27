local U = require('g60.util')
local V = require('g60.validity')
local M = {}
function M.rank(api, catalog, scene, projectile)
    local candidates = U.call(api, 'candidates', projectile)
    if type(candidates) ~= 'table' then return nil, 'CANDIDATES_UNAVAILABLE' end
    local rows, seen, all_scores = {}, {}, true
    for _, ref in ipairs(candidates) do
        local key = U.key(ref)
        local e = key and not seen[key] and V.entity(api, ref, scene)
        if key then seen[key] = true end
        if e and V.track(api, e, projectile, false) then
            local spec = e.faction == 'terminid' and catalog[e.kind]
            if spec and spec.auto_priority then
                local score = U.call(api, 'vanilla_score', projectile, e)
                all_scores = all_scores and U.finite(score)
                rows[#rows+1] = {entity=e, priority=spec.auto_priority, key=key,
                    distance=U.distance2(projectile.position, e.position), score=score}
            end
        end
    end
    table.sort(rows, function(a,b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        -- Scores are normalized by the adapter: greater means preferable.
        if all_scores and a.score ~= b.score then return a.score > b.score end
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.key < b.key
    end)
    return rows
end
return M
