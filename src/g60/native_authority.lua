-- Supported, read-only engine ownership queries. No FFI or native mutation.
-- Ownership is an observation, not an entity lifetime or control lease.
local M={}
function M.inspect(engine,network_index)
    local result={local_ownership_observed=false,control_allowed=false,
        native_lifetime_verified=false,network_entity_index=network_index}
    if type(network_index)~='number' or network_index%1~=0
        or network_index<0 or network_index>=0x7fff then
        result.reason='unsupported network entity index';return result
    end
    local ok,reason=pcall(function()
        assert(type(engine)=='table','missing engine API')
        local network,game=engine.Network,engine.GameSession
        assert(type(network)=='table' and type(game)=='table','missing network API')
        local current,exists,owned=network.game_session,game.game_object_exists,game.game_object_owned
        assert(type(current)=='function' and type(exists)=='function'
            and type(owned)=='function','missing ownership API')
        local session=current()
        assert(session~=nil and session~=false,'no current session')
        -- Never query ownership of a missing object: the native owner lookup
        -- assumes existence and can index its missing-entry sentinel.
        assert(exists(session,network_index)==true,'network object absent')
        assert(owned(session,network_index)==true,'network object not locally owned')
        assert(current()==session,'network session changed')
        assert(exists(session,network_index)==true,'network object disappeared')
        assert(owned(session,network_index)==true,'network ownership changed')
        assert(current()==session,'network session changed')
    end)
    if ok then
        result.local_ownership_observed=true
        result.reason='locally owned at query time; lifetime unverified'
    else
        result.reason=tostring(reason)
    end
    return result
end
return M
