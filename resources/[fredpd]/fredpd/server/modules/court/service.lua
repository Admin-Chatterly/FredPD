--- Åtal och dom: the charging decision and the disposition (spec 7.20).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/court_spec.lua`).
---
--- Two capacities, the same split `frihet` and `surveillance` use: the
--- åklagare decides whether to charge at all (`court.referral.review`), and
--- only a domare may enter a disposition (`court.disposition.enter`). Neither
--- reaches inside the other's decision -- `mayDecide` and `mayDispose` are
--- separate functions on purpose, so a route cannot collapse them into one
--- check and quietly let a prosecutor sentence their own charge.
---
--- **`sentenceWithinRange` is the function that matters.** A domare entering
--- a term outside what `Brott.gemensamStraffskala` allows for the charges on
--- the row is not a typo to shrug off; it is a sentence with no statutory
--- basis, and the whole reason this module reads `brott/service.lua` rather
--- than trusting whatever number arrives.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Court = {}

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0016's CHECK constraints)
-- -----------------------------------------------------------------------------

local BESLUT <const> = { 'atalad', 'ej_atal' }

local IS_BESLUT <const> = {}
for index = 1, #BESLUT do IS_BESLUT[BESLUT[index]] = true end

function Court.isBeslut(value) return IS_BESLUT[value] == true end

local DISPOSITIONS <const> = { 'guilty', 'not_guilty', 'dismissed', 'plea' }

local IS_DISPOSITION <const> = {}
for index = 1, #DISPOSITIONS do IS_DISPOSITION[DISPOSITIONS[index]] = true end

function Court.isDisposition(value) return IS_DISPOSITION[value] == true end

--- Why a referral was declined, as a locale key (invariant 6). The NUI
--- renders it with `t()`, the same reasoning `Tvang.isTvangGrund` gives.
local BESLUT_GRUNDER <const> = {
    'otillrackliga_bevis', 'ej_brott', 'preskriberat', 'annan',
}

local IS_BESLUT_GRUND <const> = {}
for index = 1, #BESLUT_GRUNDER do IS_BESLUT_GRUND[BESLUT_GRUNDER[index]] = true end

function Court.isBeslutGrund(value) return IS_BESLUT_GRUND[value] == true end

-- -----------------------------------------------------------------------------
-- Who may take each decision
-- -----------------------------------------------------------------------------

function Court.mayDecide(capacity)
    return capacity == 'aklagare'
end

function Court.mayDispose(capacity)
    return capacity == 'domare'
end

-- -----------------------------------------------------------------------------
-- The sentence
-- -----------------------------------------------------------------------------

--- Is this sentence one the charges on the row could actually carry?
---
--- Reads `Brott.gemensamStraffskala` over the same charges the route attached
--- (spec 7.20's own "sentence calculator", `court.sentence.calculate` in
--- Appendix B) rather than trusting the months a domare typed. Livstid is
--- checked as its own case: a `skala` with `max == nil` means the offences
--- carry it, and only then may `sentenceLivstid` be true.
---
--- @param skala table|nil from `Brott.gemensamStraffskala`
--- @param months number|nil
--- @param livstid boolean
--- @return boolean
--- @return string|nil why not
function Court.sentenceWithinRange(skala, months, livstid)
    if not skala then return false, 'no_charges' end

    if livstid then
        if skala.max ~= nil then return false, 'not_available' end
        return true
    end

    if type(months) ~= 'number' then return false, 'required' end
    if months < (skala.min or 0) then return false, 'below_min' end
    if skala.max ~= nil and months > skala.max then return false, 'above_max' end

    return true
end

--- Whether a disposition needs a sentence at all.
---
--- `guilty` and `plea` are convictions and take one; `not_guilty` and
--- `dismissed` end the case with nobody sentenced, and a sentence attached to
--- either would be read as a conviction that never happened.
function Court.dispositionNeedsSentence(disposition)
    return disposition == 'guilty' or disposition == 'plea'
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a charging decision a route is about to write.
---
--- @return string|nil code
--- @return table|nil fields
function Court.validateReferral(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.fuId) ~= 'number' or input.fuId < 1 then
        return 'invalid', { fuId = 'required' }
    end

    if not Court.isBeslut(input.beslut) then
        return 'invalid', { beslut = 'unknown' }
    end

    if input.beslut == 'ej_atal' then
        if type(input.beslutGrund) ~= 'string' or input.beslutGrund == '' then
            return 'invalid', { beslutGrund = 'required' }
        end

        -- A key, not prose. The NUI renders it with `t()`.
        if not Court.isBeslutGrund(input.beslutGrund) then
            return 'invalid', { beslutGrund = 'not_a_key' }
        end
    else
        -- `atalad` without at least one charge is a prosecution of nothing.
        if type(input.brottIds) ~= 'table' or #input.brottIds == 0 then
            return 'invalid', { brottIds = 'required' }
        end
    end

    return nil
end

--- Checks a disposition a route is about to write.
---
--- The sentence range check is not here: it needs `Brott.gemensamStraffskala`
--- computed from the row's own charges, which only the route has fetched.
--- This is the shape check the schema cannot express -- a sentence given for
--- an acquittal, or none given for a conviction.
---
--- @return string|nil code
--- @return table|nil fields
function Court.validateDisposition(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Court.isDisposition(input.disposition) then
        return 'invalid', { disposition = 'unknown' }
    end

    local needsSentence = Court.dispositionNeedsSentence(input.disposition)
    local hasSentence = input.sentenceLivstid == true or type(input.sentenceMonths) == 'number'

    if needsSentence and not hasSentence then
        return 'invalid', { sentenceMonths = 'required' }
    end

    if not needsSentence and hasSentence then
        return 'invalid', { sentenceMonths = 'not_allowed' }
    end

    return nil
end

FredPD.Modules.court = Court

return Court
