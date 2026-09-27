local U = require('g60.util')
local V = require('g60.validity')
local Memory = require('g60.memory')
local Aim = require('g60.aim')
local Priority = require('g60.priority')
local Logger = require('g60.logger')
local M = {}; M.__index = M
function M.new(api, options)
    options = options or {}
    local catalog = options.catalog or require('g60.catalog')
    return setmetatable({api=api, catalog=catalog, locks={}, seen={},
        aim=Aim.new(api, catalog), logger=Logger.new(options.log, options.log_limit)}, M)
end
function M:set_scene(scene)
    assert(type(scene) == 'string' and scene ~= '', 'scene epoch required')
    if self.scene ~= scene then
        self.scene, self.locks, self.seen = scene, {}, {}
        self.memory = Memory.new(self.api, scene)
        self.logger:emit('scene_reset', {scene=scene})
    end
end
function M:observe_ping(owner, ref, readable, now)
    if not self.memory then return false end
    return self.memory:observe(owner, ref, readable, now)
end
function M:forget_owner(owner)
    if self.memory then self.memory:forget(owner) end
    for key, lock in pairs(self.locks) do
        if lock.owner == owner then self.locks[key] = nil; self.seen[key] = nil end
    end
end
function M:release(ref)
    local key = U.key(ref)
    if key then self.locks[key], self.seen[key] = nil, nil end
end
function M:reset()
    self.scene, self.memory, self.locks, self.seen = nil, nil, {}, {}
end
function M:vanilla(projectile, reason)
    self.logger:emit('fallback', {projectile=projectile.ref.id, reason=reason})
    local ref = U.call(self.api, 'vanilla_target', projectile)
    local e = ref and V.entity(self.api, ref, self.scene)
    if not e or not V.track(self.api, e, projectile, false) then return nil, reason end
    local pos = U.call(self.api, 'vanilla_aim', e, projectile)
    if not U.vector(pos) then return nil, reason end
    local aim = {position=pos, mode='vanilla'}
    return {entity=e, aim=aim, reason='VANILLA', marked=false}
end
function M:select(projectile)
    local e, source = self.memory:get(projectile.owner, projectile)
    local state = self.memory.owners[projectile.owner]
    self.logger:emit('ping', {projectile=projectile.ref.id,
        current=state and state.current, remembered=state and state.last_marked_target,
        source=source})
    if source == 'PING_UNAVAILABLE' then return self:vanilla(projectile, source) end
    if e then
        local aim, failure = self.aim:resolve(e, projectile, true)
        if aim then return {entity=e, aim=aim, marked=true, source=source,
            reason=e.kind == 'bug_hole' and 'PLAYER_MARK_BUG_HOLE' or 'PLAYER_MARK'} end
        return self:vanilla(projectile, failure)
    end
    local rows, failure = Priority.rank(self.api, self.catalog, self.scene, projectile)
    if not rows then return self:vanilla(projectile, failure) end
    for _, row in ipairs(rows) do
        self.logger:emit('candidate', {projectile=projectile.ref.id, target=row.entity.ref,
            kind=row.entity.kind, priority=row.priority, distance2=row.distance, score=row.score})
    end
    for _, row in ipairs(rows) do
        local aim = self.aim:resolve(row.entity, projectile, false)
        if aim then return {entity=row.entity, aim=aim, marked=false,
            reason='AUTO_PRIORITY_' .. string.upper(row.entity.kind)} end
    end
    return self:vanilla(projectile, 'NO_CUSTOM_TARGET')
end
function M:_step(p)
    if type(p) ~= 'table' or not U.ref(p.ref) or not self.scene or p.ref.scene ~= self.scene
        or type(p.owner) ~= 'string' or p.owner == '' then return nil, 'INVALID_PROJECTILE' end
    if U.call(self.api, 'is_g60', p) ~= true then return nil, 'NOT_G60' end
    if p.active ~= true or not U.vector(p.position) then
        self:release(p.ref); return nil, 'INACTIVE_PROJECTILE'
    end
    local key = U.key(p.ref)
    if not self.seen[key] then
        self.seen[key] = true
        self.logger:emit('spawned', {projectile=p.ref, owner=p.owner})
    end
    local lock = self.locks[key]
    if lock and lock.owner == p.owner then
        local e = V.entity(self.api, lock.ref, self.scene)
        if V.track(self.api, e, p, lock.marked) then
            local aim, failure
            if lock.reason == 'VANILLA' then
                local pos = U.call(self.api, 'vanilla_aim', e, p)
                if U.vector(pos) then aim = {position=pos, mode='vanilla'} end
                failure = 'AIM_UNAVAILABLE'
            else
                aim, failure = self.aim:resolve(e, p, lock.marked)
            end
            if aim then
                return {target=U.ref(e.ref), aim=aim, reason=lock.reason,
                    source=lock.source, locked=true}, 'TRACKING'
            end
            -- Preserve entity lock through transient aim failure; no garbage write.
            return nil, failure
        end
        self.logger:emit('target_invalid', {projectile=p.ref.id, target=lock.ref})
        self.logger:emit('reacquiring', {projectile=p.ref.id})
    end
    self.locks[key] = nil
    local choice, failure = self:select(p)
    if not choice then return nil, failure end
    self.locks[key] = {ref=U.ref(choice.entity.ref), owner=p.owner, marked=choice.marked,
        reason=choice.reason, source=choice.source}
    self.logger:emit('selected', {projectile=p.ref.id, target=choice.entity.ref,
        reason=choice.reason, source=choice.source, aim=choice.aim})
    self.logger:emit('target_locked', {projectile=p.ref.id, target=choice.entity.ref})
    return {target=U.ref(choice.entity.ref), aim=choice.aim, reason=choice.reason,
        source=choice.source, locked=true}, 'ACQUIRED'
end
function M:step(projectile)
    local ok, decision, status = pcall(self._step, self, projectile)
    if ok then return decision, status end
    self.logger:emit('fallback', {reason='CORE_ERROR'})
    return nil, 'CORE_ERROR'
end
return M
