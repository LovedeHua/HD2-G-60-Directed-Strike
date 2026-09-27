-- SYNTHETIC ONLY: none of these identifiers/nodes are game resources.
local U = require('g60.util')
local Core = require('g60.core')
local F = {}
function F.ref(id, generation, scene)
    return {id=tostring(id), generation=generation or '1', scene=scene or 'mission-1'}
end
function F.new(options)
    local a = {entities={}, pool={}, events={}, scan_count=0, node_calls=0}
    function a:resolve(ref) return self.entities[U.key(ref)] end
    function a:is_g60(p) return p.resource == 'fixture:g60' end
    function a:can_track(p,e,marked) return not e.out_of_range and not e.lost end
    function a:candidates(p) self.scan_count=self.scan_count+1; return self.pool end
    function a:vanilla_target(p) return self.vanilla end
    function a:vanilla_aim(e,p) return e.vanilla end
    function a:vanilla_score(p,e) return e.score end
    function a:node_point(e,node,offset,approach,p)
        self.node_calls=self.node_calls+1
        local pos = e.nodes and e.nodes[node]
        if not pos then return nil end
        -- Fixture rotates local X into world Y to detect world-offset mistakes.
        return {x=pos.x-offset.y, y=pos.y+offset.x, z=pos.z+offset.z}
    end
    function a:add(id,kind,x,faction)
        local r = F.ref(id)
        local e = {ref=r, kind=kind, faction=faction or 'terminid', variant='fixture-variant',
            resource='fixture:' .. kind, skeleton='fixture-skeleton', position={x=x or 1,y=0,z=0},
            vanilla={x=x or 1,y=0,z=2}, active=true, alive=true, destroyed=false,
            exists=true, hostile=true, targetable=true}
        self.entities[U.key(r)]=e; self.pool[#self.pool+1]=r
        return e
    end
    options=options or {}
    options.log=options.log or function(row) a.events[#a.events+1]=row end
    local c=Core.new(a, options); c:set_scene('mission-1')
    c:observe_ping('owner-1',nil,true,0)
    return a,c
end
function F.projectile(id,owner)
    return {ref=F.ref(id or 'projectile-1'), owner=owner or 'owner-1', active=true,
        position={x=0,y=0,z=0},resource='fixture:g60'}
end
function F.catalog(kind)
    local catalog={}
    for k,v in pairs(require('g60.catalog')) do
        catalog[k]={auto_priority=v.auto_priority, marked_only=v.marked_only, variants={}}
    end
    catalog[kind].variants['fixture-variant']={enabled=true,entity_resource='fixture:' .. kind,
        skeleton='fixture-skeleton',node='fixture-node',fallback_node='fixture-fallback',
        local_offset={x=1,y=0,z=0},preferred_approach='fixture-approach',
        validation={status='live_verified',evidence='SYNTHETIC TEST ONLY'}}
    return catalog
end
return F
