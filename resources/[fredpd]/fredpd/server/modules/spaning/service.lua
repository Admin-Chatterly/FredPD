--- Spaningsuppdrag: the operational lookout (spec 7.13).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/spaning_spec.lua`).
---
--- **This is not efterlysning**, and 0012's header argues the distinction at
--- length. In one line: an efterlysning is a legal status that means *detain
--- this person*, and a spaningsuppdrag is an operational lookout that means
--- *look for this and tell us*. Any officer may raise one, it may name a
--- vehicle, and it always expires.
---
--- The rule worth reading first is `bannerFor`. Everything else here is
--- bookkeeping; that one decides what an officer is told, and getting it wrong
--- in the loud direction is how officers learn to ignore banners.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Spaning = {}

--- How long a lookout runs for by default.
---
--- Seven days. Not a statutory figure -- there is none -- but a lookout that
--- never expires is a banner that stays up until somebody remembers a van from
--- three months ago, and by then the officer reading it has learned that the
--- banners are usually stale. The expiry is what keeps them worth reading.
Spaning.DEFAULT_VALIDITY = 7 * 24 * 3600

--- The longest a lookout may run without being renewed.
Spaning.MAX_VALIDITY = 90 * 24 * 3600

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0012's CHECK constraints)
-- -----------------------------------------------------------------------------

--- What a lookout is for.
---
--- `other` is not a placeholder: a description with no record behind it --
--- "silver estate, no plate seen, three occupants" -- is the commonest lookout
--- there is, and it is the case a foreign key cannot express.
local TARGETS <const> = { 'person', 'vehicle', 'other' }

local IS_TARGET <const> = {}
for index = 1, #TARGETS do IS_TARGET[TARGETS[index]] = true end

function Spaning.isTarget(value) return IS_TARGET[value] == true end

--- Why a lookout was raised, and why it was closed.
---
--- Both are locale keys and neither may be prose: the NUI renders them with
--- `t()`, which prints an unknown key verbatim, so a free string reaches the
--- face of a register every officer with `spaning.view` reads. `spaning.create`
--- is a *patrol* permission — the lowest-privileged write in the module — which
--- is exactly why the set belongs on the server rather than in the browser's
--- dropdown.
local GRUNDER <const> = {
    'iakttagelse', 'efterlyst_fordon', 'stulet_fordon',
    'misstankt_fordon', 'eftersokt_person', 'annan',
}

local IS_GRUND <const> = {}
for index = 1, #GRUNDER do IS_GRUND[GRUNDER[index]] = true end

function Spaning.isGrund(value) return IS_GRUND[value] == true end

local AVSLUTSGRUNDER <const> = { 'gripen', 'omhandertaget', 'aterkallad', 'tiden_ute', 'annan' }

local IS_AVSLUTSGRUND <const> = {}
for index = 1, #AVSLUTSGRUNDER do IS_AVSLUTSGRUND[AVSLUTSGRUNDER[index]] = true end

function Spaning.isAvslutsgrund(value) return IS_AVSLUTSGRUND[value] == true end

function Spaning.targets()
    local out = {}
    for index = 1, #TARGETS do out[index] = TARGETS[index] end
    return out
end

-- -----------------------------------------------------------------------------
-- Liveness
-- -----------------------------------------------------------------------------

--- Is this lookout still running?
---
--- @return boolean
--- @return string|nil why not
function Spaning.isLive(row, now)
    if type(row) ~= 'table' then return false, 'not_found' end

    if row.resolvedAt then return false, 'resolved' end

    -- Unlike an efterlysning, the expiry is not optional: 0012 makes the column
    -- NOT NULL. A row reaching here without one is a row somebody wrote around
    -- the schema, and it fails closed rather than being treated as eternal.
    if not row.expiresAt then return false, 'no_expiry' end

    if now > row.expiresAt then return false, 'expired' end

    return true
end

--- The live lookouts out of a list, most urgent first.
function Spaning.liveSorted(rows, now)
    local live = {}

    if type(rows) ~= 'table' then return live end

    for index = 1, #rows do
        if Spaning.isLive(rows[index], now) then live[#live + 1] = rows[index] end
    end

    table.sort(live, function(a, b)
        local aPriority = a.priority or 4
        local bPriority = b.priority or 4

        if aPriority ~= bPriority then return aPriority < bPriority end

        -- Newer first within a priority: the most recent sighting is the one
        -- worth acting on. Then id, so two lookouts raised in the same
        -- millisecond do not swap places between two reads.
        local aIssued = a.issuedAt or 0
        local bIssued = b.issuedAt or 0

        if aIssued ~= bIssued then return aIssued > bIssued end

        return (a.id or 0) < (b.id or 0)
    end)

    return live
end

-- -----------------------------------------------------------------------------
-- What the officer is told
-- -----------------------------------------------------------------------------

--- How loudly a lookout should be shown.
---
--- Three levels, and the distinction is this module's whole contribution to
--- officer safety:
---
---   * **`alert`** -- a full-width red banner with a confirmation step, the
---     treatment 7.2 gives a hot-file hit. Priority 1 only.
---   * **`notice`** -- shown in the context panel, no banner, no tone.
---   * **`quiet`** -- listed on the record and nowhere else.
---
--- Priority alone decides it, and nothing here ever returns the
--- detain-on-sight treatment: that is `Tvang.detainOnSight`'s to give, and only
--- an efterlysning gets it. The officer raising a lookout chooses how loud it
--- is, and the one thing they cannot do is make it look like a prosecutor's
--- decision to detain.
---
--- The loud direction is the dangerous one. An officer shown a red banner for
--- every "have a look for this van" learns within a shift that red banners are
--- usually nothing, and then misses the one that was a person with a knife.
function Spaning.bannerFor(row)
    if type(row) ~= 'table' then return 'quiet' end

    local priority = row.priority or 4

    if priority <= 1 then return 'alert' end
    if priority <= 3 then return 'notice' end

    return 'quiet'
end

--- Does this lookout need the confirmation step 7.2 requires?
---
--- Only the ones shown as a banner. A confirmation step on something the
--- officer was never interrupted by is a dialog with no question in it.
function Spaning.needsConfirmation(row)
    return Spaning.bannerFor(row) == 'alert'
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a lookout a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Spaning.validate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Spaning.isTarget(input.targetKind) then
        return 'invalid', { targetKind = 'unknown' }
    end

    local hasTarget = type(input.targetId) == 'number' and input.targetId >= 1
    local hasDescription = type(input.description) == 'string'
        and input.description:gsub('%s', '') ~= ''

    -- A lookout has to be for something. 0012 carries the same CHECK; this is
    -- the copy that produces a field error the officer can act on rather than
    -- an SQL one.
    if not hasTarget and not hasDescription then
        return 'invalid', { description = 'required_without_target' }
    end

    -- `other` means "there is no record to point at". An id alongside it would
    -- be an id into nothing, and the banner would try to open a record that
    -- does not exist.
    if input.targetKind == 'other' and hasTarget then
        return 'invalid', { targetId = 'not_allowed' }
    end

    if type(input.grund) ~= 'string' or input.grund == '' then
        return 'invalid', { grund = 'required' }
    end

    -- A key, not prose. The NUI renders it with `t()`.
    if not Spaning.isGrund(input.grund) then
        return 'invalid', { grund = 'not_a_key' }
    end

    if input.priority ~= nil
        and (type(input.priority) ~= 'number'
             or input.priority < 1 or input.priority > 4) then
        return 'invalid', { priority = 'out_of_range' }
    end

    if input.validSeconds ~= nil
        and (input.validSeconds < 3600 or input.validSeconds > Spaning.MAX_VALIDITY) then
        return 'invalid', { validSeconds = 'out_of_range' }
    end

    return nil
end

FredPD.Modules.spaning = Spaning

return Spaning
