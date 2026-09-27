local U = require('g60.util')
local M = {}; M.__index = M
function M.new(api, catalog) return setmetatable({api=api, catalog=catalog}, M) end
function M:profile(e, marked)
    local species = self.catalog[e.kind]
    if not species or (species.marked_only and not marked) then return nil end
    if e.kind ~= 'bug_hole' and e.faction ~= 'terminid' then return nil end
    local p = species.variants[e.variant]
    if type(p) ~= 'table' or p.enabled ~= true or p.entity_resource ~= e.resource
        or type(p.entity_resource) ~= 'string' or p.entity_resource == ''
        or type(p.skeleton) ~= 'string' or p.skeleton == '' or p.skeleton ~= e.skeleton
        or type(p.validation) ~= 'table' or p.validation.status ~= 'live_verified'
        or type(p.validation.evidence) ~= 'string' or p.validation.evidence == ''
        or not U.vector(p.local_offset) then return nil end
    return p
end
function M:resolve(e, projectile, marked)
    local p = self:profile(e, marked)
    if p then
        for _, node in ipairs({p.node or false, p.fallback_node or false}) do
            if type(node) == 'string' and node ~= '' then
                -- Adapter checks node existence and converts the local offset
                -- using the CURRENT node transform, including rotation.
                local pos = U.call(self.api, 'node_point', e, node, p.local_offset,
                    p.preferred_approach, projectile)
                if U.vector(pos) then
                    return {position=pos, mode=e.kind == 'bug_hole' and 'bug_hole' or 'weakpoint',
                        node=node, offset=p.local_offset, evidence=p.validation.evidence}
                end
            end
        end
    end
    -- Never approximate a hole entrance with entity origin or vanilla center.
    if e.kind == 'bug_hole' then return nil, 'BUG_HOLE_POINT_UNVERIFIED' end
    local pos = U.call(self.api, 'vanilla_aim', e, projectile)
    if U.vector(pos) then return {position=pos, mode='vanilla'} end
    return nil, 'AIM_UNAVAILABLE'
end
return M
