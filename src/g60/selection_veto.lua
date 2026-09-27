-- Minimal pre-guidance policy. Never ranks candidates or invents fresh scores.
-- Native execution still requires the controller's authority/lifetime/phase lease.
local U = require('g60.util')
local Filter = require('g60.small_filter')
local M = {}
function M.plan(s, was_searching, allowed)
    if type(s)~='table' or s.resource~='8e325c933e55bf62' or s.behavior_id~=4 then
        return nil,'NOT_G60'
    end
    if s.active~=true or s.expired~=false or (s.state~=3 and s.state~=4) then
        return nil,'INACTIVE'
    end
    if not U.ref(s.ref) or s.selection_complete~=true then return nil,'INCOMPLETE_SELECTION' end
    -- State 3 already submits native orbit movement before its first selection.
    if s.state==3 then return {kind='keep'},'VANILLA_SEARCH' end
    local selected=s.selected
    if selected~=nil then
        if type(selected)~='table' or not U.ref(selected.ref)
            or selected.ref.scene~=s.ref.scene or type(selected.resource)~='string'
            or #selected.resource~=16 or not selected.resource:match('^[0-9a-f]+$') then
            return nil,'INVALID_SELECTION'
        end
        if not Filter.excluded(selected.resource) and (not allowed or allowed(selected.resource)) then return {kind='keep'},'VANILLA_ALLOWED' end
        return {kind='search',clear_selection=true},'EXCLUDED_SELECTION'
    end
    -- An invalid Entity ID can coexist with an enabled native guidance flag.
    -- Only a backend's full cleared-field check may omit the NULL setter.
    if was_searching then
        return {kind='search',clear_selection=s.selection_cleared~=true},'CONTINUE_SEARCH'
    end
    return {kind='keep'},'VANILLA_SEARCH'
end
return M
