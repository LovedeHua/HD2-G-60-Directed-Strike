-- Exact identities with an installed custom aiming profile, never name/faction guesses.
local M={}
local function resource(key)
    return type(key)=='string' and #key==16 and key:match('^[0-9a-f]+$')~=nil
end
function M.new(titan,profiles)
    assert(type(titan)=='table' and resource(titan.resource),'missing Titan allowlist profile')
    assert(type(profiles)=='table','missing weakpoint allowlist profiles')
    local allowed={[titan.resource]=true}
    for key,profile in pairs(profiles) do
        assert(resource(key) and type(profile)=='table' and profile.resource==key,'allowlist profile identity mismatch')
        allowed[key]=true
    end
    -- Snapshot the keys so later table mutation cannot expand eligibility.
    return function(key) return allowed[key]==true end
end
return M
