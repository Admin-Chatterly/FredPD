--- Tvångsmedel och efterlysning: the logic (spec 7.12, 7.13).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/tvangsmedel_spec.lua`).
---
--- **`isValid` is the function that matters**, because spec 14 exposes it to
--- other resources as `HasSearchWarrant(targetType, targetId)` and `ox_doorlock`
--- decides whether to open somebody's front door on the answer. Everything
--- about validity is therefore in one place, tested against a fixed clock, and
--- written so that every way of being *invalid* is a separate early return with
--- a name -- a door that opens when it should not is not something to discover
--- from a boolean that was true for the wrong reason.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Tvang = {}

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0011's CHECK constraints)
-- -----------------------------------------------------------------------------

--- The measures. Swedish names, because the distinctions are Swedish:
---
---   * **husrannsakan_reell** (RB 28:1) -- searching a place for something.
---   * **husrannsakan_personell** (RB 28:2) -- searching a place *for a person*,
---     to arrest them. A different decision with a different ground, which is
---     why it is not a flag on the first.
---   * **kroppsvisitation** (RB 28:11) -- searching clothing and what somebody
---     carries.
---   * **kroppsbesiktning** (RB 28:12) -- examining the body itself, including
---     taking samples. A higher threshold than a visitation, and the measure
---     that produces the reference sample the lab compares against.
---   * **beslag** (RB 27:1) -- seizure. Recorded here as a *decision*; the
---     items themselves live in the evidence module, which has held beslag
---     since M3.
local KINDS <const> = {
    'husrannsakan_reell', 'husrannsakan_personell',
    'kroppsvisitation', 'kroppsbesiktning', 'beslag',
}

local IS_KIND <const> = {}
for index = 1, #KINDS do IS_KIND[KINDS[index]] = true end

local TARGETS <const> = { 'person', 'vehicle', 'address' }

local IS_TARGET <const> = {}
for index = 1, #TARGETS do IS_TARGET[TARGETS[index]] = true end

local DECIDERS <const> = { 'fu_ledare', 'aklagare', 'domare' }

local IS_DECIDER <const> = {}
for index = 1, #DECIDERS do IS_DECIDER[DECIDERS[index]] = true end

function Tvang.isKind(value) return IS_KIND[value] == true end
function Tvang.isTarget(value) return IS_TARGET[value] == true end
function Tvang.isDecider(value) return IS_DECIDER[value] == true end

function Tvang.kinds()
    local out = {}
    for index = 1, #KINDS do out[index] = KINDS[index] end
    return out
end

--- Which measures each capacity may decide.
---
--- RB gives the ordinary husrannsakan and kroppsvisitation to the
--- förundersökningsledare, whoever that is. **Kroppsbesiktning is the one held
--- back**: it reaches inside somebody's body, and FredPD requires at least a
--- prosecutor for it rather than letting any FU-ledare decide.
---
--- This is stricter than RB in one respect and deliberately so -- the statute
--- lets an FU-ledare decide it too -- because the alternative on a game server
--- is that the measure which produces a DNA reference sample is available to
--- every officer who can open an investigation. Where the rule is tightened
--- rather than loosened, and the reason is recorded, that is a policy choice a
--- server can live with; the reverse would not be.
local ALLOWED <const> = {
    fu_ledare = {
        husrannsakan_reell = true, husrannsakan_personell = true,
        kroppsvisitation = true, beslag = true,
    },
    aklagare = {
        husrannsakan_reell = true, husrannsakan_personell = true,
        kroppsvisitation = true, kroppsbesiktning = true, beslag = true,
    },
    domare = {
        husrannsakan_reell = true, husrannsakan_personell = true,
        kroppsvisitation = true, kroppsbesiktning = true, beslag = true,
    },
}

--- May this capacity decide this measure?
function Tvang.mayDecide(deciderKind, kind)
    local allowed = ALLOWED[deciderKind]
    if not allowed then return false end

    return allowed[kind] == true
end

-- -----------------------------------------------------------------------------
-- Validity — what spec 14's export answers
-- -----------------------------------------------------------------------------

--- How long a measure may run for, by default, in seconds.
---
--- Not a statutory figure: RB bounds a husrannsakan by its purpose rather than
--- by a clock. A default exists because the alternative is a decision with no
--- end, which is a standing authority to enter somebody's home. A week is long
--- enough for an investigation to act and short enough that a forgotten
--- decision lapses.
Tvang.DEFAULT_VALIDITY = 7 * 24 * 3600

--- Is this measure live right now?
---
--- Every way of being invalid is its own return with a reason, because the
--- caller that matters is a door script and "false" alone is not something
--- anybody can debug at three in the morning.
---
--- **Execution is not one of them.** A measure that has been carried out stays
--- valid: RB allows a husrannsakan to be resumed, and a door that refused the
--- second entry because the first was logged would be enforcing a rule nobody
--- wrote.
---
--- @param row table the measure
--- @param now number epoch seconds
--- @return boolean
--- @return string|nil why not
function Tvang.isValid(row, now)
    if type(row) ~= 'table' then return false, 'not_found' end

    -- Revocation overrides the window, whatever it said.
    if row.upphavdAt then return false, 'upphavd' end

    if row.validFrom and now < row.validFrom then return false, 'not_yet' end

    if row.validUntil and now > row.validUntil then return false, 'expired' end

    return true
end

--- The first live measure for a target, out of a list.
---
--- What the spec 14 export is built on. Returns the measure rather than a
--- boolean so the caller can say *which* decision authorised what it did --
--- a door script that logs the number it opened on is auditable, and one that
--- logs "true" is not.
---
--- @return table|nil
function Tvang.firstValid(rows, now)
    if type(rows) ~= 'table' then return nil end

    for index = 1, #rows do
        if Tvang.isValid(rows[index], now) then return rows[index] end
    end

    return nil
end

--- Does this measure authorise entering a place?
---
--- Both kinds of husrannsakan do; a kroppsvisitation does not, and neither does
--- a beslag decision on its own. The distinction is the whole reason
--- `HasSearchWarrant` cannot simply ask whether any measure exists for the
--- target: a decision to search somebody's pockets is not a decision to enter
--- their flat, and a door script asking the general question would open on one.
function Tvang.authorisesEntry(row)
    if type(row) ~= 'table' then return false end

    return row.kind == 'husrannsakan_reell' or row.kind == 'husrannsakan_personell'
end

-- -----------------------------------------------------------------------------
-- Efterlysning (7.13)
-- -----------------------------------------------------------------------------

--- Why somebody is wanted.
---
--- `anhallen_i_franvaro` is the commonest and is the nearest Swedish equivalent
--- of a US arrest warrant (Appendix A says so): the prosecutor has decided to
--- anhålla somebody who is not present. The decision itself lives in the
--- frihetsberövande chain; this is the consequence that makes them show up on a
--- query.
local GRUNDER <const> = {
    'anhallen_i_franvaro', 'haktad_i_franvaro', 'delgivning',
    'forsvunnen', 'oidentifierad', 'annan',
}

local IS_GRUND <const> = {}
for index = 1, #GRUNDER do IS_GRUND[GRUNDER[index]] = true end

function Tvang.isGrund(value) return IS_GRUND[value] == true end

--- Which grounds mean "detain this person on sight".
---
--- The distinction the hit banner has to make. Somebody wanted for
--- **delgivning** -- to be served a document -- is not somebody to arrest, and
--- an officer shown one red banner for both would eventually treat both the
--- same way. A missing person is the same problem in the other direction: they
--- are wanted *for their own sake*.
local DETAIN_ON_SIGHT <const> = {
    anhallen_i_franvaro = true,
    haktad_i_franvaro = true,
}

function Tvang.detainOnSight(grund)
    return DETAIN_ON_SIGHT[grund] == true
end

--- Is this efterlysning live?
---
--- @return boolean
--- @return string|nil why not
function Tvang.isLive(row, now)
    if type(row) ~= 'table' then return false, 'not_found' end

    if row.cancelledAt then return false, 'cancelled' end

    -- A null expiry means it stands until somebody cancels it, which is the
    -- right default for an anhållen i sin frånvaro: the decision does not
    -- lapse because time passed.
    if row.expiresAt and now > row.expiresAt then return false, 'expired' end

    return true
end

--- The live efterlysningar out of a list, heaviest first.
---
--- Ordered by whether the person is to be detained on sight and then by
--- priority, because the banner shows one line and it has to be the line that
--- changes what the officer does.
function Tvang.liveSorted(rows, now)
    local live = {}

    if type(rows) ~= 'table' then return live end

    for index = 1, #rows do
        if Tvang.isLive(rows[index], now) then live[#live + 1] = rows[index] end
    end

    table.sort(live, function(a, b)
        local aDetain = Tvang.detainOnSight(a.grund)
        local bDetain = Tvang.detainOnSight(b.grund)

        if aDetain ~= bDetain then return aDetain end

        local aPriority = a.priority or 4
        local bPriority = b.priority or 4

        if aPriority ~= bPriority then return aPriority < bPriority end

        -- A stable tiebreak, so two efterlysningar of equal weight do not swap
        -- places between two reads of the same record.
        return (a.id or 0) < (b.id or 0)
    end)

    return live
end

--- Validates a measure a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Tvang.validate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Tvang.isKind(input.kind) then return 'invalid', { kind = 'unknown' } end

    if not Tvang.isTarget(input.targetKind) then
        return 'invalid', { targetKind = 'unknown' }
    end

    if type(input.targetId) ~= 'number' or input.targetId < 1 then
        return 'invalid', { targetId = 'required' }
    end

    -- A husrannsakan is directed at a place. Pointing one at a person is how a
    -- decision to search a flat ends up authorising a search of whoever happens
    -- to be standing in it.
    if Tvang.authorisesEntry(input) and input.targetKind == 'person' then
        return 'invalid', { targetKind = 'not_a_place' }
    end

    -- A kroppsvisitation or kroppsbesiktning is directed at a person, for the
    -- mirror-image reason.
    if (input.kind == 'kroppsvisitation' or input.kind == 'kroppsbesiktning')
        and input.targetKind ~= 'person' then
        return 'invalid', { targetKind = 'not_a_person' }
    end

    if type(input.grund) ~= 'string' or input.grund == '' then
        return 'invalid', { grund = 'required' }
    end

    return nil
end

FredPD.Modules.tvangsmedel = Tvang

return Tvang
