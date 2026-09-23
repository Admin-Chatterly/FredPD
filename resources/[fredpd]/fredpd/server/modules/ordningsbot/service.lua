--- Ordningsbot: on-the-spot fixed-penalty citations (spec 7.11).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/ordningsbot_spec.lua`).
---
--- **`isVoidReason` is checked server-side, never trusted from a client key.**
--- This codebase already found the same bug -- a free-text or unchecked reason
--- key rendered verbatim through `t()` the day it does not match one -- in
--- four other modules before this one (`Court.isBeslutGrund`,
--- `Personnel.isDisciplineCategory` and its siblings). The fix is the same
--- closed allowlist every time.
---
--- **`mayTransition` is the whole lifecycle in one function.** A citation
--- moves exactly once, from `issued` to `paid`, `contested` or `void`
--- (Appendix E). There is no move out of any of those three: `paid -> void`
--- is not a transition this module resolves (a wrongly-paid fine is a refund
--- process, not a status flip) and `contested -> paid` is not either --
--- resolving a contest is 7.20's `fpd_atal` disposition, not a second verdict
--- mechanism invented here. `ordningsbot/repo.lua` guards every write with
--- `WHERE status = 'issued'` so the database enforces the same rule this
--- function states.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Ordningsbot = {}

-- -----------------------------------------------------------------------------
-- Allowlists
-- -----------------------------------------------------------------------------

local VOID_REASONS <const> = {
    'issued_in_error', 'identity_mistake', 'duplicate', 'other',
}

local IS_VOID_REASON <const> = {}
for index = 1, #VOID_REASONS do IS_VOID_REASON[VOID_REASONS[index]] = true end

function Ordningsbot.isVoidReason(value) return IS_VOID_REASON[value] == true end

-- -----------------------------------------------------------------------------
-- The lifecycle (Appendix E: Issued -> Paid, Contested or Void)
-- -----------------------------------------------------------------------------

local LEGAL_TRANSITIONS <const> = {
    issued = { paid = true, contested = true, void = true },
}

--- Whether moving a citation from `fromStatus` to `toStatus` is a move this
--- module allows at all.
---
--- @param fromStatus string
--- @param toStatus string
--- @return boolean
function Ordningsbot.mayTransition(fromStatus, toStatus)
    local allowed = LEGAL_TRANSITIONS[fromStatus]
    return allowed ~= nil and allowed[toStatus] == true
end

-- -----------------------------------------------------------------------------
-- Payment status (0024): overdue is read, never stored
-- -----------------------------------------------------------------------------

--- Splits `issued` into `unpaid` or `overdue` against `dueAt`. `paid`,
--- `contested` and `void` are terminal (see the module header) and pass
--- through unchanged -- there is no database column for this, and no fifth
--- value `mayTransition` needs to know about: it is arithmetic on the two
--- fields a row already carries, the same "computed from dates, not timers"
--- shape `impound/service.lua`'s `Impound.feeOwed` takes for the impound fee.
---
--- @param row table `status`, `dueAt` (epoch seconds)
--- @param now number epoch seconds
--- @return string 'unpaid'|'overdue'|'paid'|'contested'|'void'
function Ordningsbot.paymentStatus(row, now)
    if row.status ~= 'issued' then return row.status end

    return (now >= row.dueAt) and 'overdue' or 'unpaid'
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a citation a route is about to write.
---
--- The schema has already checked `tariffId`'s type and range; what is left
--- is the cross-field rule the schema cannot express -- at least one of
--- `personId`/`vehicleId`, the same "not both may be absent" shape
--- `ck_fpd_ordningsbot_subject` enforces in the database.
---
--- @return string|nil code
--- @return table|nil fields
function Ordningsbot.validateIssue(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.tariffId) ~= 'number' or input.tariffId < 1 then
        return 'invalid', { tariffId = 'required' }
    end

    local hasPerson = type(input.personId) == 'number' and input.personId >= 1
    local hasVehicle = type(input.vehicleId) == 'number' and input.vehicleId >= 1

    if not hasPerson and not hasVehicle then
        return 'invalid', { _input = 'subject_required' }
    end

    return nil
end

--- Checks a void a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Ordningsbot.validateVoid(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.voidReasonKey) ~= 'string' or input.voidReasonKey == '' then
        return 'invalid', { voidReasonKey = 'required' }
    end

    -- A key, not prose. The NUI renders it with `t()`.
    if not Ordningsbot.isVoidReason(input.voidReasonKey) then
        return 'invalid', { voidReasonKey = 'not_a_key' }
    end

    return nil
end

FredPD.Modules.ordningsbot = Ordningsbot

return Ordningsbot
