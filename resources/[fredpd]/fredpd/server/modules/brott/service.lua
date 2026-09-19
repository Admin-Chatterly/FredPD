--- Brottskatalogen: offence logic (spec 7.10).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/brott_spec.lua`).
---
--- What lives here is everything about the catalogue that is a *rule* rather
--- than a query:
---
---   * **The straffskala.** A Swedish offence carries a span, not a number:
---     whether böter is available, a floor in months, and a ceiling in months
---     that may be absent entirely (livstid). Every comparison and every total
---     below works in months, because a calculation that mixes years and months
---     gets one conversion wrong exactly once and then reads plausibly forever.
---   * **Brottskonkurrens** (BrB 26:2). What the span becomes when somebody is
---     charged with several offences at once. This is the one piece of
---     arithmetic in the module that an officer will be asked to justify, so it
---     is written to the statute rather than to intuition -- see below.
---   * **The allowlists.** Grader, and the balkar a code may cite. They mirror
---     the CHECK constraints in migration 0008, in code, because a value that
---     reaches the database and is refused there surfaces as an internal error
---     rather than as a field error the officer can act on.
---
--- What is deliberately *not* here: any notion of a recommended or typical
--- sentence. The span is the law; where inside it a sentence lands is the
--- court's, and a number this module invented would be quoted as though it
--- were not invented.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Brott = {}

-- -----------------------------------------------------------------------------
-- Units
-- -----------------------------------------------------------------------------

--- Everything in this module is months.
---
--- Not an arbitrary choice: brottsbalken itself writes the short spans in
--- months ("fängelse i högst sex månader") and the long ones in years, so one
--- of the two has to be the storage unit and months is the one that represents
--- both without a fraction.
Brott.MONTHS_PER_YEAR = 12

--- The ceiling on a fixed-term fängelse sentence (BrB 26:1).
---
--- Eighteen years. A gemensam straffskala computed below can reach it and must
--- never exceed it; beyond this the only sentence is livstid, which is a
--- different thing rather than a larger number.
Brott.MAX_FIXED_MONTHS = 18 * 12

--- Livstid is the absence of a ceiling, not a very large one.
---
--- Represented as `nil` throughout, and given a name so the intent reads at
--- every call site that has to branch on it.
Brott.LIVSTID = nil

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring 0008's CHECK constraints)
-- -----------------------------------------------------------------------------

--- The grader brottsbalken uses, from lightest to heaviest.
---
--- Ordered, because a charging screen lists them in this order and because
--- `Brott.isHeavier` compares them. A grad is a property of *this* instance of
--- the offence -- ringa stöld and grov stöld are separate catalogue rows, each
--- with its own span -- so this list names the rows, it does not modify them.
local GRADER <const> = { 'ringa', 'normal', 'grov', 'synnerligen_grov' }

local GRAD_RANK <const> = {}
for index = 1, #GRADER do GRAD_RANK[GRADER[index]] = index end

function Brott.grader()
    local out = {}
    for index = 1, #GRADER do out[index] = GRADER[index] end
    return out
end

function Brott.isGrad(value)
    return GRAD_RANK[value] ~= nil
end

--- Rank of a grad, or nil when it is not one. For ordering a charge list.
function Brott.gradRank(value)
    return GRAD_RANK[value]
end

-- -----------------------------------------------------------------------------
-- Normalisation
-- -----------------------------------------------------------------------------

--- Trims, and turns an empty string into nil.
---
--- The same reasoning as `Registry.blankToNull`: an empty text field and an
--- absent one mean the same thing, and storing both makes every later query
--- check for two things.
function Brott.blankToNull(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:gsub('^%s*(.-)%s*$', '%1')
    if trimmed == '' then return nil end

    return trimmed
end

--- An offence code: upper-cased, inner whitespace removed.
---
--- `brb-8-1`, `BrB 8 1` and `BRB-8-1` are one code. Codes are compared in three
--- places -- the catalogue, an anmälan's charge list and a seed file -- and a
--- code that compares unequal between them is an offence that silently cannot
--- be charged.
function Brott.normalizeCode(value)
    local code = Brott.blankToNull(value)
    if not code then return nil end

    return (code:upper():gsub('%s+', ''))
end

-- -----------------------------------------------------------------------------
-- The straffskala
-- -----------------------------------------------------------------------------

--- Builds a straffskala from a catalogue row, or nil when the row is not one.
---
--- Accepts the column names 0008 uses, so a repo row goes straight in.
---
--- @param row table  { boter, fangelse_min_months, fangelse_max_months }
--- @return table|nil { boter = boolean, min = number, max = number|nil }
function Brott.straffskala(row)
    if type(row) ~= 'table' then return nil end

    local min = tonumber(row.fangelse_min_months) or 0
    local max = tonumber(row.fangelse_max_months)

    -- A floor above the ceiling is the one shape that is not a span. 0008
    -- refuses it too; this is the copy that produces a field error rather than
    -- an SQL one.
    if max and min > max then return nil end

    if min < 0 or (max and max < 0) then return nil end

    -- MariaDB hands a TINYINT(1) back as a number, and a hand-written table may
    -- carry a boolean. Both mean the same thing here.
    local boter = row.boter == true or row.boter == 1

    -- "Böter eller fängelse i lägst sex månader" is not a sentence any statute
    -- contains: once there is a fängelse floor, böter is off the table. 0008
    -- carries the same CHECK.
    if boter and min > 0 then return nil end

    return { boter = boter, min = min, max = max }
end

--- Is this span heavier than that one?
---
--- Livstid outranks every fixed term. Below that it is the ceiling that
--- decides, and the floor only breaks a tie: "fängelse i lägst sex månader och
--- högst sex år" is heavier than "fängelse i högst sex år", and a comparison
--- that looked only at ceilings would call them equal and pick whichever came
--- first in the list.
---
--- @return boolean
function Brott.isHeavier(a, b)
    if not b then return true end
    if not a then return false end

    -- Livstid: nil max.
    if a.max == nil and b.max == nil then return (a.min or 0) > (b.min or 0) end
    if a.max == nil then return true end
    if b.max == nil then return false end

    if a.max ~= b.max then return a.max > b.max end

    return (a.min or 0) > (b.min or 0)
end

--- The heaviest span in a list, and its index.
---
--- @param skalor table list of straffskalor
--- @return table|nil heaviest
--- @return number|nil index
function Brott.heaviest(skalor)
    local best, bestIndex

    for index = 1, #skalor do
        local candidate = skalor[index]

        if candidate and Brott.isHeavier(candidate, best) then
            best, bestIndex = candidate, index
        end
    end

    return best, bestIndex
end

-- -----------------------------------------------------------------------------
-- Brottskonkurrens (BrB 26:2)
-- -----------------------------------------------------------------------------

--- How far the heaviest ceiling may be exceeded when several offences are tried
--- together, per BrB 26:2 andra stycket.
---
--- The statute gives three bands, by the heaviest individual ceiling:
---
---   under four years      -> may be exceeded by one year
---   four to under eight   -> by two years
---   eight years or more   -> by four years
---
--- Written as a table rather than a chain of ifs so the bands can be read
--- against the statute at a glance, which is the only way anybody will ever
--- check them.
local KONKURRENS_BANDS <const> = {
    { under = 4 * 12, add = 1 * 12 },
    { under = 8 * 12, add = 2 * 12 },
    { under = math.huge, add = 4 * 12 },
}

--- The uplift in months for a given heaviest ceiling.
function Brott.konkurrensUplift(heaviestMax)
    if heaviestMax == nil then return 0 end

    for index = 1, #KONKURRENS_BANDS do
        local band = KONKURRENS_BANDS[index]
        if heaviestMax < band.under then return band.add end
    end

    return 0
end

--- The gemensam straffskala for several offences tried together (BrB 26:2).
---
--- Four rules, all from the statute, and the order matters:
---
---   1. **The floor is the heaviest of the floors.** "Straffet får inte
---      understiga det svåraste av de lägsta straffen." Not the sum: three
---      offences each carrying a six-month minimum still have a six-month
---      floor.
---   2. **The ceiling is the heaviest ceiling plus the uplift** from the band
---      table above.
---   3. **But never more than the sum of the individual ceilings.** Two
---      offences of "högst sex månader" cannot reach eighteen months merely
---      because the band says a year may be added; the sum caps it at twelve.
---   4. **And never more than eighteen years** (BrB 26:1), which is where a
---      fixed term stops being available at all.
---
--- Livstid short-circuits the whole thing: if any offence carries it, the
--- gemensam skala carries it, and there is no arithmetic to do.
---
--- Böter survives only if *every* offence allows it. One offence with a
--- fängelse floor takes böter off the table for the whole set, which follows
--- from rule 1 -- the floor is no longer zero.
---
--- @param skalor table list of straffskalor from `Brott.straffskala`
--- @return table|nil { boter, min, max } or nil when the list is empty
function Brott.gemensamStraffskala(skalor)
    if type(skalor) ~= 'table' or #skalor == 0 then return nil end

    local heaviest = Brott.heaviest(skalor)
    if not heaviest then return nil end

    local floor = 0
    local sum = 0
    local boter = true
    local livstid = false

    for index = 1, #skalor do
        local skala = skalor[index]
        if not skala then return nil end

        if (skala.min or 0) > floor then floor = skala.min end
        if not skala.boter then boter = false end

        if skala.max == nil then
            livstid = true
        else
            sum = sum + skala.max
        end
    end

    -- A single offence is not konkurrens: it keeps its own span exactly, with
    -- no uplift. Returned as a fresh table so a caller cannot mutate the
    -- catalogue's copy through it.
    if #skalor == 1 then
        return { boter = skalor[1].boter, min = skalor[1].min, max = skalor[1].max }
    end

    if livstid then
        return { boter = false, min = floor, max = Brott.LIVSTID }
    end

    local ceiling = heaviest.max + Brott.konkurrensUplift(heaviest.max)

    -- Rule 3, then rule 4. In that order: the sum is a fact about these
    -- offences and the eighteen-year cap is a fact about Swedish sentencing,
    -- and applying the statutory cap first would let the sum push back above it.
    if ceiling > sum then ceiling = sum end
    if ceiling > Brott.MAX_FIXED_MONTHS then ceiling = Brott.MAX_FIXED_MONTHS end

    -- The floor cannot end up above the ceiling. It can only happen with a
    -- catalogue row whose own span is reversed, which 0008 refuses and
    -- `Brott.straffskala` refuses -- so reaching this is a bug rather than an
    -- input, and it fails closed rather than returning an impossible span.
    if floor > ceiling then return nil end

    return { boter = boter and floor == 0, min = floor, max = ceiling }
end

-- -----------------------------------------------------------------------------
-- Citation
-- -----------------------------------------------------------------------------

--- The legal citation for a catalogue row: `BrB 8:1`.
---
--- An identifier rather than prose, and treated the way spec 6.2 treats plates
--- and serials: it is the same string in Swedish and in English, it is read
--- aloud and typed back, and it is not something a translator should be asked
--- to render. The offence's *rubrik* is the translated half, and that is a
--- locale key on the row (`label_key`).
---
--- Returns nil for a row that cites no statute -- an agency-local code -- where
--- `code` itself is the citation.
---
--- @param row table { balk, kapitel, paragraf }
--- @return string|nil
function Brott.citation(row)
    if type(row) ~= 'table' then return nil end

    local balk = Brott.blankToNull(row.balk)
    local kapitel = tonumber(row.kapitel)
    local paragraf = tonumber(row.paragraf)

    if not balk or not kapitel or not paragraf then return nil end

    return ('%s %d:%d'):format(balk, kapitel, paragraf)
end

-- -----------------------------------------------------------------------------
-- Charge lists
-- -----------------------------------------------------------------------------

--- Parses the id list a charge set arrives as.
---
--- The validator has no integer-list type, so ids arrive as strings and are
--- bounded here -- the same arrangement `Evidence.parseIds` uses and for the
--- same reason.
---
--- **It does not deduplicate, and that is the point.** `Evidence.parseIds`
--- drops a repeated id because the same item queued for the same analysis twice
--- is a double charge to the lab. Here the opposite holds: three counts of grov
--- stöld is three entries of one catalogue id, it is an ordinary charge set,
--- and collapsing it to one would understate the case in exactly the
--- calculation BrB 26:2 exists to perform. A deduplicating parser here would
--- produce a lower gemensam straffskala than the law gives, silently, on the
--- multi-count cases that are the only ones where the rule matters at all.
---
--- @param list table the raw string list
--- @param max number|nil how many counts one record may carry
--- @return table|nil ids, duplicates preserved and in order
--- @return string|nil reason
function Brott.parseIds(list, max)
    if type(list) ~= 'table' then return nil, 'type' end
    if #list == 0 then return nil, 'required' end
    if max and #list > max then return nil, 'too_many' end

    local ids = {}

    for index = 1, #list do
        local id = tonumber(list[index])

        if not id or id ~= math.floor(id) or id < 1 then
            return nil, 'not_integer'
        end

        ids[index] = id
    end

    return ids
end

--- Lines a charge list up against the catalogue rows fetched for it.
---
--- `repo.byIds` answers with distinct rows, because that is what one `IN`
--- clause returns; a charge list may name the same offence several times. This
--- maps the one onto the other, so the result has one span per *count* rather
--- than one per offence.
---
--- Returns nil when an id has no row, which means a charge naming a catalogue
--- entry that is not in this agency's catalogue. Dropping it silently would
--- lower the span with nothing on screen to say why.
---
--- @param ids table from `Brott.parseIds`, duplicates preserved
--- @param rows table distinct catalogue rows
--- @return table|nil one row per count, in the order the ids were given
function Brott.expandCharges(ids, rows)
    if type(ids) ~= 'table' or type(rows) ~= 'table' then return nil end

    local byId = {}
    for index = 1, #rows do byId[rows[index].id] = rows[index] end

    local out = {}

    for index = 1, #ids do
        local row = byId[ids[index]]
        if not row then return nil end

        out[index] = row
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- Checks a catalogue entry a route is about to write.
---
--- The schema (`packages/schema`) has already checked types, lengths and
--- unknown keys by the time a handler runs. What is left is the cross-field
--- reasoning the schema cannot express: whether these particular numbers form a
--- straffskala, and whether the statutory citation is complete or absent rather
--- than half-filled.
---
--- Returns an error code and a field map, the same shape
--- `Placements.validate` returns, so a route can hand it straight to
--- `route.refuse` and the officer sees which field to fix.
---
--- @return string|nil code
--- @return table|nil fields
function Brott.validate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Brott.normalizeCode(input.code) then
        return 'invalid', { code = 'required' }
    end

    if not Brott.isGrad(input.grad) then
        return 'invalid', { grad = 'unknown' }
    end

    -- The span. `straffskala` folds every rule about the three penalty columns
    -- into one answer, so the route and the database cannot disagree about what
    -- a valid one is.
    local skala = Brott.straffskala({
        boter = input.boter,
        fangelse_min_months = input.fangelseMinMonths,
        fangelse_max_months = input.fangelseMaxMonths,
    })

    if not skala then
        return 'invalid', { fangelseMinMonths = 'straffskala' }
    end

    -- A fixed term above eighteen years is not something brottsbalken can
    -- express (BrB 26:1): beyond it the sentence is livstid, which is written
    -- as an absent ceiling rather than as a bigger number.
    if skala.max and skala.max > Brott.MAX_FIXED_MONTHS then
        return 'invalid', { fangelseMaxMonths = 'over_max' }
    end

    -- A citation is all three parts or none. Half of one -- a kapitel with no
    -- balk -- renders as a broken reference on every record that cites the
    -- offence, and it is the kind of thing that is only noticed in court.
    local parts = 0
    if Brott.blankToNull(input.balk) then parts = parts + 1 end
    if input.kapitel ~= nil then parts = parts + 1 end
    if input.paragraf ~= nil then parts = parts + 1 end

    if parts ~= 0 and parts ~= 3 then
        return 'invalid', { balk = 'incomplete_citation' }
    end

    if not Brott.blankToNull(input.labelKey) then
        return 'invalid', { labelKey = 'required' }
    end

    return nil
end

FredPD.Modules.brott = Brott

return Brott
