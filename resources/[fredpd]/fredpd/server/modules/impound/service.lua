--- Vehicle impound: the fee clock and the release gate (spec 7.15).
---
--- Pure: no natives, no database, so busted exercises it outside FXServer
--- (`spec/impound_spec.lua`).
---
--- **`Impound.feeOwed` is the function that matters.** Everything else here is
--- an allowlist or a two-branch gate; this is the arithmetic that decides
--- what a vehicle owner is actually asked to pay, and it is written as pure
--- arithmetic on epoch seconds so busted can pin it against fixed instants the
--- same way `spec/frihet_spec.lua` pins RB 24:12 and 24:13 -- a day miscounted
--- here is not a typo to shrug off, it is money.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Impound = {}

-- -----------------------------------------------------------------------------
-- Allowlist (mirroring 0020's `ck_fpd_impound_reason`)
-- -----------------------------------------------------------------------------

local HELD_REASONS <const> = {
    'investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other',
}

local IS_HELD_REASON <const> = {}
for index = 1, #HELD_REASONS do IS_HELD_REASON[HELD_REASONS[index]] = true end

function Impound.isHeldReason(value) return IS_HELD_REASON[value] == true end

--- Only an investigative or evidence hold needs an investigator's
--- authorization before release (spec 7.15) -- a car towed for expired tags
--- or left abandoned waits on nothing but its fee.
function Impound.needsAuthorization(heldReasonKey)
    return heldReasonKey == 'investigative' or heldReasonKey == 'evidence'
end

-- -----------------------------------------------------------------------------
-- The fee
-- -----------------------------------------------------------------------------

local SECONDS_PER_DAY <const> = 86400

--- Whole days held, from `impoundedAt` to `until_`, rounded up, with a floor
--- of one day.
---
--- A vehicle released ten minutes after it was towed still occupied a bay for
--- part of a day, and the department's storage cost for that day is the same
--- as if it sat the whole day -- so a partial day is never free, and every
--- fraction rounds up rather than down.
---
--- @param impoundedAt number epoch seconds
--- @param until_ number epoch seconds, >= impoundedAt
--- @return number whole days, minimum 1
local function daysHeld(impoundedAt, until_)
    local elapsed = until_ - impoundedAt
    if elapsed <= 0 then return 1 end

    return math.max(1, math.ceil(elapsed / SECONDS_PER_DAY))
end

--- What is owed on this row right now (or, once released, what was owed at
--- release -- the bill does not keep growing after the vehicle left).
---
--- @param row table `impoundedAt`, `releasedAt` (nil while held), `feePerDay`
--- @param now number epoch seconds, ignored once the row carries a `releasedAt`
--- @return number integer fee owed
function Impound.feeOwed(row, now)
    local until_ = row.releasedAt or now
    local days = daysHeld(row.impoundedAt, until_)

    return days * (row.feePerDay or 0)
end

-- -----------------------------------------------------------------------------
-- The release gate
-- -----------------------------------------------------------------------------

--- May this impound be released?
---
--- Two independent gates, checked in the order a front-desk officer would
--- actually hit them: the fee first (the common case, and the one paid at the
--- counter), authorization second (only ever relevant for the two hold kinds
--- that need one).
---
--- @return boolean
--- @return string|nil reasonCode
function Impound.mayRelease(row, feePaid)
    if not feePaid then return false, 'fee_unpaid' end

    if Impound.needsAuthorization(row.heldReasonKey) and not row.holdAuthorizedAt then
        return false, 'not_authorized'
    end

    return true
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- @return string|nil code
--- @return table|nil fields
function Impound.validateCreate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.plate) ~= 'string' or #input.plate < 1 or #input.plate > 16 then
        return 'invalid', { plate = 'required' }
    end

    if not Impound.isHeldReason(input.heldReasonKey) then
        return 'invalid', { heldReasonKey = 'not_a_key' }
    end

    if input.feePerDay ~= nil then
        if type(input.feePerDay) ~= 'number' or input.feePerDay < 0 or input.feePerDay ~= math.floor(input.feePerDay) then
            return 'invalid', { feePerDay = 'invalid' }
        end
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Impound.validateAuthorize(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.id) ~= 'number' or input.id < 1 then
        return 'invalid', { id = 'required' }
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Impound.validateRelease(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.id) ~= 'number' or input.id < 1 then
        return 'invalid', { id = 'required' }
    end

    if type(input.version) ~= 'number' or input.version < 1 then
        return 'invalid', { version = 'required' }
    end

    return nil
end

--- Is the car on the street the model the garage row says that plate was
--- issued to? Both are GTA model hashes; one side may have been stored signed
--- and the other read unsigned, so they are compared modulo 2^32. Anything
--- that is not a number cannot be vouched for and answers false.
function Impound.sameModel(stored, onStreet)
    local a, b = tonumber(stored), tonumber(onStreet)
    if not a or not b or a ~= math.floor(a) or b ~= math.floor(b) then return false end

    return a % 4294967296 == b % 4294967296
end

-- -----------------------------------------------------------------------------
-- The lot (0037)
-- -----------------------------------------------------------------------------

--- An agency's lots, numbered in the order they were placed: a lot has no
--- name of its own (a placement is named by a locale key), so "lot 2" is what
--- the screen and the tow both call it.
---
--- @param placements table id -> placement, as the placement cache holds them
--- @param usable fun(placement): boolean whether this agency may use it
--- @return table list of { id, number, x, y, z }
function Impound.lots(placements, usable)
    local list = {}

    for _, placement in pairs(placements or {}) do
        if placement.kind == 'impound_lot' and placement.enabled ~= false and placement.enabled ~= 0
            and usable(placement)
        then
            list[#list + 1] = { id = placement.id, x = placement.x, y = placement.y, z = placement.z }
        end
    end

    table.sort(list, function(a, b) return a.id < b.id end)
    for index, lot in ipairs(list) do lot.number = index end

    return list
end

--- The lot nearest a position, or nil when the agency has none.
function Impound.nearestLot(lots, at)
    if not at then return nil end

    local best, bestDistance = nil, math.huge
    for _, lot in ipairs(lots) do
        local dx, dy, dz = lot.x - at.x, lot.y - at.y, (lot.z or 0) - (at.z or 0)
        local distance = dx * dx + dy * dy + dz * dz
        if distance < bestDistance then best, bestDistance = lot, distance end
    end

    return best
end

--- Is this id one of the agency's lots?
function Impound.isLot(lots, id)
    for _, lot in ipairs(lots) do
        if lot.id == id then return true end
    end

    return false
end

--- A free-text field trimmed, nil when it says nothing.
function Impound.text(value)
    if type(value) ~= 'string' then return nil end
    local trimmed = value:match('^%s*(.-)%s*$')
    return trimmed ~= '' and trimmed or nil
end

FredPD.Modules.impound = Impound

return Impound
