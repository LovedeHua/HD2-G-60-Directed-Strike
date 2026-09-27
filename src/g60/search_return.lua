-- Control protocol only: no FFI, engine binding, guessed pointers or timers.
-- The current installable addon does not import this module.
local U = require('g60.util')
local Filter = require('g60.small_filter')
local Veto = require('g60.selection_veto')
local M = {}; M.__index=M
local function token(v) return type(v)=='string' and v~='' end
function M.new(adapter, options)
    return setmetatable({adapter=adapter,mode=(options or {}).mode or 'rank_candidates',
        searching={},disabled=false},M)
end
function M:release(ref)
    local key=U.key(ref)
    if key then self.searching[key]=nil end
end
function M:reset()
    self.searching={};self.scene=nil;self.disabled=false
end
function M:step(ref)
    if self.disabled then return nil,'CONTROL_DISABLED' end
    if self.mode~='rank_candidates' and self.mode~='selected_veto' then
        return nil,'UNSUPPORTED_CONTROL_MODE'
    end
    local key=U.key(ref)
    if not key then return nil,'INVALID_REF' end
    if self.scene~=ref.scene then self.scene=ref.scene;self.searching={} end
    local api=self.adapter
    if type(api)~='table' or type(api.acquire)~='function' or type(api.apply)~='function' then
        return nil,'RUNTIME_ADAPTER_UNAVAILABLE'
    end
    -- Acquire must supply a same-callback lease with proven local authority,
    -- native-call ABI/lifetime and scheduling. Live read-only snapshots do not.
    local ok,lease=pcall(api.acquire,api,U.ref(ref))
    if not ok or type(lease)~='table' or type(lease.snapshot)~='table' then
        return nil,'LEASE_UNAVAILABLE'
    end
    local s=lease.snapshot
    if U.key(s.ref)~=key or lease.authority~=true or lease.lifetime~=true
        or lease.callsite~=true or not token(lease.token)
        or not token(lease.timer_bytes) or not token(lease.deadline_bytes)
        or lease.snapshot.state==nil then return nil,'UNVERIFIED_LEASE' end
    -- Lua's after-update wrapper precedes the native behavior update in the
    -- captured engine path. It must never masquerade as an after-behavior lease.
    -- These fields need backend evidence, not booleans copied from static reports.
    if self.mode=='selected_veto' then
        if lease.phase~='before_native_update' or lease.single_behavior_step~=true
            or lease.selection_stable_until_guidance~=true then
            return nil,'UNVERIFIED_GUIDANCE_WINDOW'
        end
    elseif lease.phase~='after_behavior_update' then
        return nil,'WRONG_CONTROL_PHASE'
    end
    local planner=self.mode=='selected_veto' and Veto or Filter
    local planned,plan,reason=pcall(planner.plan,s,self.searching[key]==true)
    if not planned then return nil,'INVALID_SNAPSHOT' end
    if not plan then
        if reason=='INACTIVE' or reason=='NOT_G60' then self.searching[key]=nil end
        return nil,reason
    end
    if plan.kind=='keep' then self.searching[key]=nil;return plan,reason end
    -- apply owns revalidation + the complete native operation. A search must
    -- replace the movement point as well as clear selection. Retarget must
    -- update guidance, not merely copy the chosen Entity ID.
    local expected_token,expected_timer,expected_deadline,expected_state =
        lease.token,lease.timer_bytes,lease.deadline_bytes,s.state
    local expected_kind,expected_target=plan.kind,U.ref(plan.target)
    local applied,receipt=pcall(api.apply,api,lease,plan)
    if applied and type(receipt)=='table' and receipt.status=='stale' then
        -- Contract: stale means no mutation happened.
        if receipt.mutated==false then return nil,'STALE_LEASE' end
    end
    if not applied or type(receipt)~='table' or receipt.status~='applied'
        or receipt.token~=expected_token or receipt.timer_bytes~=expected_timer
        or receipt.deadline_bytes~=expected_deadline or receipt.state~=expected_state
        or receipt.movement_updated~=true or receipt.transitions_used~=false
        or (expected_kind=='search' and receipt.selection_cleared~=true)
        or (expected_kind=='retarget' and U.key(receipt.target)~=U.key(expected_target)) then
        -- Never repeat a partial operation or restart the flight timeout.
        self.disabled=true
        return nil,'CONTROL_POSTCONDITION_FAILED'
    end
    self.searching[key]=expected_kind=='search' or nil
    return {kind=expected_kind,target=expected_target},
        expected_kind=='search' and 'SEARCH_MOVEMENT_APPLIED' or 'RETARGET_APPLIED'
end
return M
