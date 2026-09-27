-- Exact resources only. Unknown variants retain vanilla eligibility.
local U = require('g60.util')
local M = {}
local excluded = {
    ['51eea86bf6997e4e']=true, ['9a8a3aae287b230c']=true,
    ['aab438596f5e8fd9']=true, ['72a83e49ced6db3d']=true,
    ['3d0e03e2d574e1ca']=true, ['5ca832447445c0ba']=true,
    ['be39e313a1e46bb9']=true,
    ['672f7da17f3ba34a']=true, -- Impaler tentacle; aim at the separate body resource.
    ['a1f37bf2a40fbde4']=true, -- Hive Guard (cha_warrior_plus), explicitly requested.
}
function M.excluded(resource) return excluded[resource] == true end
local function resource(value)
    return type(value)=='string' and #value==16 and value:match('^[0-9a-f]+$')~=nil
end
function M.plan(snapshot, was_searching)
    if type(snapshot)~='table' or snapshot.resource~='8e325c933e55bf62'
        or snapshot.behavior_id~=4 then return nil,'NOT_G60' end
    if snapshot.active~=true or snapshot.expired~=false
        or (snapshot.state~=3 and snapshot.state~=4) then return nil,'INACTIVE' end
    if not U.ref(snapshot.ref) or type(snapshot.candidates)~='table'
        or snapshot.complete~=true or snapshot.aliased~=false then return nil,'INCOMPLETE' end
    local selected=snapshot.selected
    if selected~=nil then
        if type(selected)~='table' or not U.ref(selected.ref) or not resource(selected.resource)
            or selected.ref.scene~=snapshot.ref.scene then return nil,'INVALID_SELECTION' end
        if not excluded[selected.resource] then return {kind='keep'},'VANILLA_ALLOWED' end
    elseif not was_searching then
        return {kind='keep'},'VANILLA_SEARCH'
    end
    -- Existing trace scores alone do not establish freshness. This must be
    -- supplied by a verified runtime adapter, never inferred from score >= 0.
    if snapshot.scores_current~=true then return nil,'STALE_SCORES' end
    local best, seen, count = nil, {}, 0
    for index,row in pairs(snapshot.candidates) do
        count=count+1
        if type(index)~='number' or index%1~=0 or index<1 or index>51
            or type(row)~='table' or not U.ref(row.ref) or not resource(row.resource)
            or row.ref.scene~=snapshot.ref.scene or not U.finite(row.score) then
            return nil,'INCOMPLETE_CANDIDATE'
        end
        local key=U.key(row.ref)
        if seen[key] then return nil,'ALIASED_CANDIDATE' end
        seen[key]=true
        if row.score<0 then return nil,'SCORE_NOT_READY' end
    end
    for index=1,count do
        local row=snapshot.candidates[index]
        if not row then return nil,'SPARSE_CANDIDATES' end
        if not excluded[row.resource] and row.score>0 and (not best or row.score>best.score) then
            best=row
        end
    end
    if best then
        return {kind='retarget',target=U.ref(best.ref)},'ALLOWED_CANDIDATE'
    end
    return {kind='search',clear_selection=selected~=nil},'NO_ALLOWED_CANDIDATE'
end
return M
