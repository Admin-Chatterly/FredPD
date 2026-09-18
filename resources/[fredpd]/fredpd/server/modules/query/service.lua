--- The unified query and hot-file logic (spec 7.2).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/query_spec.lua`).
---
--- One route takes what an officer typed and answers across the registers. Four
--- decisions live here because each of them is a *rule* rather than a query.
---
---   * **What kind of query this is.** Derived from the term where the term can
---     say -- a seventeen-character string that passes the ISO 3779 check digit
---     is a VIN and nothing else -- and given explicitly when it cannot. The
---     type decides which registers are read, which permission each read needs,
---     and what `fpd_query_log.query_type` records.
---   * **Which registers a type reaches.** An explicit type narrows to one; a
---     derived one deliberately widens, because the whole point of a unified
---     query is that an officer with a string in their hand does not have to
---     know which register it belongs to.
---   * **Ranking.** A score per row, computed from the row and the term, so the
---     three registers can be merged into one list. The scale is ordinal and
---     nothing outside the sort reads it.
---   * **Hot-file hits.** Which of a vehicle's live flags, which firearm
---     statuses and which person cautions are the red banner of 7.2. The
---     registers already answer the first two (`Registry.VEHICLE_HOTFILE`,
---     `Registry.FIREARM_HOTFILE`) and this file asks them rather than keeping a
---     second list that would drift.
---
--- ## A hit is a lead, not a fact
---
--- Real hot-file practice is that finding a record is not confirming it: the
--- agency holding the record is asked, and the answer comes back separately.
--- FredPD follows it, because the difference is what an officer is later asked
--- about. So every hit this file shapes carries `confirmed = false` and a
--- reference (`hitType`, `hitId`) that `query.hit.confirm` takes, and a
--- confirmation is bound to the query that raised the lead. Re-running a query
--- raises a fresh, unconfirmed lead -- which is correct: a confirmation is good
--- for the encounter it was taken for, not forever.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Query = {}

--- The registry service, for the VIN test and the two hot-file allowlists.
---
--- Looked up on each call rather than captured at load: a module reaches
--- another module through its `service.lua` (never its repo), and doing it
--- lazily means this file does not care which order the manifest loads them in.
local function registry()
    return FredPD.Modules.registry
end

-- -----------------------------------------------------------------------------
-- Query types (7.2)
-- -----------------------------------------------------------------------------

--- The six kinds of query 7.2 names, spelled as `ck_fpd_query_log_type` spells
--- them.
---
--- The CHECK in migration 0005 is the authority here and it has shipped
--- (invariant 8), so a serial query is logged as `firearm`. 7.2 calls the same
--- thing a "firearm serial", which is why `serial` is accepted as an alias
--- below rather than as a seventh type: two names for one row in the log would
--- split every misuse search in half.
Query.TYPES = {
    person = true, plate = true, vin = true,
    firearm = true, phone = true, address = true,
}

--- What an officer may type as the type, beyond the canonical six.
Query.TYPE_ALIASES = { serial = 'firearm' }

--- The canonical type for a name, or nil when it is not one of ours.
function Query.canonicalType(value)
    if type(value) ~= 'string' then return nil end

    local name = value:lower()

    if Query.TYPES[name] then return name end

    return Query.TYPE_ALIASES[name]
end

--- The three registers a query can read.
Query.SOURCES = { person = true, vehicle = true, firearm = true }

--- The record type each source is known by in the access tables (4.5).
Query.RECORD_TYPE = { person = 'person', vehicle = 'vehicle', firearm = 'firearm' }

--- The permission each query needs (Appendix B, 7.2).
---
--- Keyed by the SOURCE first, because the permission governs which register may
--- be read. `query.phone.run` and `query.address.run` are separate keys in 7.2
--- because "whose number is this" and "who lives here" are different questions
--- from "who is this person" -- but all three are questions about the *name
--- index*, and neither is a licence to read the vehicle or firearm register.
---
--- Keyed the other way round, as this was, `permissionFor('phone', 'vehicle')`
--- answered `query.phone.run`: an officer holding only the phone key could read
--- the vehicle register through a phone-shaped term, and an officer holding
--- `query.vehicle.run` could not read a numeric plate, because a term of digits
--- derives as a phone.
---
--- @param queryType string
--- @param source string
--- @return string permission key
function Query.permissionFor(queryType, source)
    if source == 'vehicle' then return 'query.vehicle.run' end
    if source == 'firearm' then return 'query.firearm.run' end

    -- The name index, read three ways.
    if queryType == 'phone' then return 'query.phone.run' end
    if queryType == 'address' then return 'query.address.run' end

    return 'query.person.run'
end

-- -----------------------------------------------------------------------------
-- The term
-- -----------------------------------------------------------------------------

--- The shortest term worth running. One character matches most of every
--- register and answers nothing (spec 12).
local MIN_TERM <const> = 2

--- How many words of a term are used. Anything past this is a sentence.
local MAX_TOKENS <const> = 4

--- Trims, collapses the whitespace inside, and refuses anything too short.
---
--- `%`, `_` and `\` are removed rather than escaped, for the reason
--- `persons/repo.lua` gives: escaping them needs an `ESCAPE` clause that a
--- server running `NO_BACKSLASH_ESCAPES` refuses, and a search for `%` that
--- matched every record is the failure this avoids.
---
--- @param value any
--- @return string|nil
function Query.normalizeTerm(value)
    if type(value) ~= 'string' then return nil end

    local text = value:gsub('[%%_\\]', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
    if #text < MIN_TERM then return nil end

    return text
end

--- The digits in a term, for the phone branch. `''` when it has none.
function Query.digits(term)
    if type(term) ~= 'string' then return '' end

    return (term:gsub('%D', ''))
end

--- The words of a term, up to `MAX_TOKENS`.
function Query.tokens(term)
    local tokens = {}
    if type(term) ~= 'string' then return tokens end

    for word in term:gmatch('[^ ]+') do
        if #tokens < MAX_TOKENS then tokens[#tokens + 1] = word end
    end

    return tokens
end

-- -----------------------------------------------------------------------------
-- Deriving the type (7.2: "the type is derived where it can be")
-- -----------------------------------------------------------------------------

--- The longest plausible phone number, and the shortest.
local PHONE_MIN <const> = 5
local PHONE_MAX <const> = 15

--- What kind of query this term looks like.
---
--- The order of the tests is the order of how certain each one is:
---
---   1. A **VIN** is arithmetic. Seventeen characters with a check digit that
---      agrees is a VIN and is nothing else, so it is decided first and by the
---      register that owns the definition.
---   2. A term of **digits alone**, of a length a telephone number has, is a
---      phone number. A plate of digits alone is possible, which is why a
---      derived phone query still reads the vehicle register (see `plan`).
---   3. A term whose **first word is a number and which has more words** is an
---      address: `12 Alta Street`. Nothing else starts that way.
---   4. Anything with a **space or no digit in it** is a name.
---   5. What is left is one alphanumeric word: a plate or a firearm serial, and
---      no amount of staring at `GLK17` says which. It is called a plate --
---      the roadside case, and what the vehicle register already calls it --
---      and a derived query of this shape reads all three registers, so a
---      serial typed into the box still finds the weapon. An officer who wants
---      only one of them says so, which is what the explicit type is for.
---
--- @param term string normalized
--- @return string one of `Query.TYPES`
function Query.deriveType(term)
    if type(term) ~= 'string' then return 'person' end

    if registry().isVin(term:upper()) then return 'vin' end

    local digits = Query.digits(term)
    local tokens = Query.tokens(term)

    if term:match('^%d+$') and #digits >= PHONE_MIN and #digits <= PHONE_MAX then
        return 'phone'
    end

    if #tokens > 1 and tokens[1]:match('^%d+$') then return 'address' end

    if #tokens > 1 or not term:match('%d') then return 'person' end

    return 'plate'
end

--- What this query is and which registers it reads.
---
--- An **explicit** type narrows to the one register that can answer it: an
--- officer who says "plate" has told us not to show them people.
---
--- A **derived** type widens, because the derivation is a guess about a string
--- and the officer is holding the object. The widening is deliberate and
--- bounded: a VIN is unambiguous so it stays with the vehicle register, a
--- phone number reads the name index and the vehicle register (a plate can be
--- digits), and the ambiguous alphanumeric case reads all three.
---
--- @param term string normalized
--- @param explicit string|nil already canonicalised
--- @return string queryType, table sources (set), boolean derived
function Query.plan(term, explicit)
    if explicit then
        if explicit == 'person' or explicit == 'phone' or explicit == 'address' then
            return explicit, { person = true }, false
        end

        if explicit == 'firearm' then return explicit, { firearm = true }, false end

        -- plate and vin
        return explicit, { vehicle = true }, false
    end

    local derived = Query.deriveType(term)

    if derived == 'vin' then return derived, { vehicle = true }, true end
    if derived == 'address' then return derived, { person = true }, true end
    if derived == 'phone' then return derived, { person = true, vehicle = true }, true end
    if derived == 'person' then return derived, { person = true }, true end

    return derived, { person = true, vehicle = true, firearm = true }, true
end

--- How the name index is read for a query: by name, by number or by address.
---
--- The three are different WHERE clauses and the repo takes this rather than
--- the type, so a future type that also reads the name index does not have to
--- be added to the SQL in two places.
function Query.personMode(queryType)
    if queryType == 'phone' then return 'phone' end
    if queryType == 'address' then return 'address' end

    return 'name'
end

-- -----------------------------------------------------------------------------
-- Ranking (7.2: "partial matches, ranked")
-- -----------------------------------------------------------------------------

--- What a refused-but-visible record scores.
---
--- A stub carries no fields to score, and it still has to appear: it is the
--- "restricted record -- contact <unit>" line of 4.5. Below every real match
--- and above nothing, which is the only honest place for a row whose contents
--- nobody in this session may read.
Query.STUB_SCORE = 10

--- The order the three registers break a tie in. Alphabetical, and fixed, so
--- the same search always produces the same page.
local KIND_ORDER <const> = { firearm = 1, person = 2, vehicle = 3 }

local function upper(value)
    return type(value) == 'string' and value:upper() or nil
end

local function lower(value)
    return type(value) == 'string' and value:lower() or nil
end

--- A person's name as the index holds it: lower case, one space between parts.
function Query.fullName(row)
    local parts = {}

    for _, field in ipairs({ 'firstName', 'middleName', 'lastName' }) do
        local value = type(row) == 'table' and row[field] or nil
        if type(value) == 'string' and value ~= '' then parts[#parts + 1] = value end
    end

    return table.concat(parts, ' '):lower()
end

--- A phone number with the separators taken out, so `555-0134` and `5550134`
--- are one number. The same normalisation the name index applies in SQL.
local function phoneDigits(value)
    if type(value) ~= 'string' then return '' end

    return (value:gsub('%D', ''))
end

--- Everything a score needs to know about what was typed, computed once.
---
--- @param term string normalized
--- @param queryType string
--- @return table context
function Query.context(term, queryType)
    return {
        type = queryType,
        term = term,
        upper = term:upper(),
        lower = term:lower(),
        digits = Query.digits(term),
        tokens = Query.tokens(term:lower()),
    }
end

--- Does `haystack` contain every token?
local function containsAll(haystack, tokens)
    if type(haystack) ~= 'string' then return false end

    for index = 1, #tokens do
        if not haystack:find(tokens[index], 1, true) then return false end
    end

    return #tokens > 0
end

--- How well one row answers the term, highest first.
---
--- Ordinal, like the name index's own `matchScore`: nothing outside the sort
--- reads the numbers and only their order matters. An exact identifier beats an
--- exact name, which beats a prefix, which beats words in any order, which
--- beats whatever the database matched phonetically -- because a SOUNDEX code
--- agreeing is the weakest evidence in the list, not the strongest.
---
--- A row with no id is a stub and scores `STUB_SCORE`: there is nothing on it
--- to compare.
---
--- @param context table from `Query.context`
--- @param row table a result row carrying `kind`
--- @return number
function Query.score(context, row)
    if type(row) ~= 'table' then return 0 end
    if row.id == nil then return Query.STUB_SCORE end

    if row.kind == 'vehicle' then
        if upper(row.vin) == context.upper then return 100 end
        if upper(row.plate) == context.upper then return 95 end
        if upper(row.plate) and upper(row.plate):find(context.upper, 1, true) == 1 then return 70 end

        return 30
    end

    if row.kind == 'firearm' then
        if upper(row.serial) == context.upper then return 95 end
        if upper(row.serial) and upper(row.serial):find(context.upper, 1, true) == 1 then return 70 end

        return 30
    end

    -- The name index.
    if upper(row.personNumber) == context.upper then return 100 end

    if context.digits ~= '' and phoneDigits(row.phone) == context.digits then return 90 end

    local name = Query.fullName(row)

    if name == context.lower then return 85 end

    if context.type == 'address' and lower(row.address)
        and lower(row.address):find(context.lower, 1, true)
    then
        return 80
    end

    if name:find(context.lower, 1, true) == 1 then return 75 end
    if containsAll(name, context.tokens) then return 60 end

    return 30
end

--- What a row sorts by after its score: the register, then the label, then the
--- id. Three tiebreaks because two rows really can share a score, and a page
--- that reorders itself between two runs of the same query is a page an officer
--- cannot read out over the radio.
function Query.label(row)
    if type(row) ~= 'table' then return '' end

    if row.kind == 'vehicle' then return row.plate or '' end
    if row.kind == 'firearm' then return row.serial or '' end

    local name = Query.fullName(row)

    return name ~= '' and name or (row.personNumber or '')
end

--- Merges the registers into one ranked page.
---
--- The sort is total: score, register, label, id, and finally the order the
--- rows arrived in, so `table.sort` -- which is not stable -- cannot produce
--- two different pages from the same rows.
---
--- @param rows table result rows, each carrying `kind` and `score`
--- @param limit number
--- @return table
function Query.rank(rows, limit)
    if type(rows) ~= 'table' then return {} end

    for index = 1, #rows do rows[index].order = index end

    table.sort(rows, function(left, right)
        if left.score ~= right.score then return left.score > right.score end

        local leftKind = KIND_ORDER[left.kind] or 9
        local rightKind = KIND_ORDER[right.kind] or 9
        if leftKind ~= rightKind then return leftKind < rightKind end

        local leftLabel, rightLabel = Query.label(left), Query.label(right)
        if leftLabel ~= rightLabel then return leftLabel < rightLabel end

        local leftId, rightId = left.id or 0, right.id or 0
        if leftId ~= rightId then return leftId < rightId end

        return left.order < right.order
    end)

    local out = {}

    for index = 1, math.min(#rows, limit) do
        rows[index].order = nil
        out[index] = rows[index]
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Hot-file hits (7.2)
-- -----------------------------------------------------------------------------

--- What kind of thing a hit hangs off, for `fpd_hotfile_confirmations`.
Query.HIT_TYPES = {
    vehicle_flag = true, firearm = true, person_caution = true,
    -- Added with 0012, which widened `ck_fpd_hotfile_confirmations_hit_type`
    -- to match. These two are the sources that most need the confirmation
    -- step, because they are the ones that end with an officer stopping
    -- somebody rather than reading a record.
    efterlysning = true, spaning = true,
}

--- The record each hit type belongs to, so the confirmation route knows which
--- access check to run before it writes anything.
Query.HIT_RECORD_TYPE = {
    vehicle_flag = 'vehicle',
    firearm = 'firearm',
    person_caution = 'person',
    -- These two are their own record type rather than the person or vehicle
    -- they name. An efterlysning carries its own classification -- a wanted
    -- notice can be restricted while the person's file is not -- so the access
    -- check the confirmation route runs has to be against the notice.
    efterlysning = 'efterlysning',
    spaning = 'spaning',
}

--- The person cautions that are a hot-file hit (7.2, "officer-safety
--- cautions").
---
--- `armed`, `violent` and `officer_safety` are what an officer is told before
--- they get out of the car. `gang` is intelligence, not a warning, and
--- `mental_health` is field-gated care information that an officer without
--- `fields.mental_health.view` is not shown at all -- putting either behind a
--- red banner would turn a caution into a reason to treat somebody as a threat,
--- which is the opposite of what both are for.
Query.PERSON_HOTFILE = { armed = true, violent = true, officer_safety = true }

--- A hit, in the shape the interface and the confirmation route share.
---
--- `kind` is a key, never a sentence: the NUI renders `query.hit.<kind>`
--- (invariant 6). `confirmed` is false on every hit this function builds, and
--- that is the whole point -- see the file header.
---
--- @param hitType string one of `Query.HIT_TYPES`
--- @param hitId number the flag, firearm or caution row
--- @param kind string the flag kind, firearm status or caution kind
--- @param recordId number the record the hit is on
local function hit(hitType, hitId, kind, recordId)
    return {
        hitType = hitType,
        hitId = hitId,
        kind = kind,
        recordType = Query.HIT_RECORD_TYPE[hitType],
        recordId = recordId,
        confirmed = false,
    }
end

--- The hits on a vehicle, from the flags the reader is allowed to see.
---
--- Which flag kinds count is `Registry.VEHICLE_HOTFILE`'s answer, asked rather
--- than copied: the register owns the definition and a second list here would
--- be right until the day somebody added a flag kind to one of them.
---
--- @param flags table flag rows, already access-filtered by the caller
--- @param vehicleId number
--- @return table list of hits
function Query.vehicleHits(flags, vehicleId)
    local hits = {}
    if type(flags) ~= 'table' then return hits end

    local hot = registry().VEHICLE_HOTFILE

    for index = 1, #flags do
        local flag = flags[index]

        if type(flag) == 'table' and flag.id and hot[flag.kind] then
            hits[#hits + 1] = hit('vehicle_flag', flag.id, flag.kind, vehicleId)
        end
    end

    return hits
end

--- The hit on a firearm: its status, when the register calls that status hot.
---
--- The hit id is the firearm's own, because the status is a column on it rather
--- than a row of its own. A confirmation therefore points at the weapon, which
--- is what an officer holding it is asking about.
function Query.firearmHits(firearm)
    local hits = {}
    if type(firearm) ~= 'table' or not firearm.id then return hits end

    if registry().FIREARM_HOTFILE[firearm.status] then
        hits[#hits + 1] = hit('firearm', firearm.id, firearm.status, firearm.id)
    end

    return hits
end

--- The hits on a person, from the cautions the reader is allowed to know about.
---
--- The caller has already applied both tests a caution has to pass -- the
--- `fields.<key>.view` gate and the caution's own classification -- so a
--- caution this function never sees is one that never reaches the banner
--- either.
function Query.personHits(cautions, personId)
    local hits = {}
    if type(cautions) ~= 'table' then return hits end

    for index = 1, #cautions do
        local caution = cautions[index]

        if type(caution) == 'table' and caution.id and Query.PERSON_HOTFILE[caution.kind] then
            hits[#hits + 1] = hit('person_caution', caution.id, caution.kind, personId)
        end
    end

    return hits
end

--- The hits from the efterlysningar on a person (7.13).
---
--- **Only the ones that mean "detain this person".** Somebody wanted for
--- delgivning is to be served a document and somebody reported missing is
--- wanted for their own sake; neither is a reason to stop and hold anybody, and
--- a red banner for all three teaches an officer that the banner does not mean
--- what it says.
---
--- The rule lives in the tvångsmedel service, asked rather than copied, for the
--- same reason `vehicleHits` asks the register which flags are hot: the module
--- that owns the concept owns the definition.
---
--- Unlike `personHits`, this takes no record id: the hit hangs off the
--- efterlysning itself rather than off the person, because the notice carries
--- its own classification and the confirmation route checks that.
---
--- @param rows table efterlysningar the reader is allowed to see
--- @param now number epoch seconds
function Query.efterlysningHits(rows, now)
    local hits = {}
    if type(rows) ~= 'table' then return hits end

    local tvang = FredPD.Modules.tvangsmedel

    for index = 1, #rows do
        local row = rows[index]

        if type(row) == 'table' and row.id
            and tvang.detainOnSight(row.grund) and tvang.isLive(row, now) then
            hits[#hits + 1] = hit('efterlysning', row.id, row.grund, row.id)
        end
    end

    return hits
end

--- The hits from the spaningsuppdrag on a person or vehicle (7.13).
---
--- **Only the ones the module itself says are loud enough to interrupt
--- somebody.** `Spaning.bannerFor` returns `alert` for priority 1 and nothing
--- else, and only an `alert` becomes a hot-file hit here -- the rest are shown
--- on the record without stopping anybody.
---
--- That asymmetry is the point. A lookout is an officer saying "look for this
--- van", and if every one of them raised a red banner the banners would stop
--- being read within a shift.
function Query.spaningHits(rows, now)
    local hits = {}
    if type(rows) ~= 'table' then return hits end

    local spaning = FredPD.Modules.spaning

    for index = 1, #rows do
        local row = rows[index]

        if type(row) == 'table' and row.id
            and spaning.needsConfirmation(row) and spaning.isLive(row, now) then
            hits[#hits + 1] = hit('spaning', row.id, row.grund, row.id)
        end
    end

    return hits
end

--- How many rows on a page carry at least one hit, for `fpd_query_log`.
function Query.countHits(rows)
    local count = 0
    if type(rows) ~= 'table' then return count end

    for index = 1, #rows do
        local row = rows[index]
        if type(row) == 'table' and type(row.hits) == 'table' and #row.hits > 0 then
            count = count + 1
        end
    end

    return count
end

-- -----------------------------------------------------------------------------
-- Confirming a hit (7.2)
-- -----------------------------------------------------------------------------

--- What a confirmation can say.
---
--- Three answers, because the real one has three: the agency confirms the
--- record, says it is no longer valid, or cannot be reached in time. Collapsing
--- the last two into "not confirmed" loses the distinction an officer is asked
--- about afterwards -- whether they acted on a lead nobody had answered.
Query.CONFIRM_OUTCOMES = { confirmed = true, not_confirmed = true, unable = true }

--- A confirmation has to point at something.
---
--- The outcome and the hit are checked here; whether the hit is still live, and
--- whether this reader may see the record it sits on, are questions for the
--- database and the access module and are asked in `routes.lua`.
---
--- A confirmation of `confirmed` carries a case number or a written detail, for
--- the same reason a stolen-vehicle flag does: "it came back confirmed" is not
--- an answer to "confirmed against what?".
---
--- @return string|nil error code, table|nil fields
function Query.validateConfirm(input)
    if not Query.HIT_TYPES[input.hitType] then
        return 'invalid', { hitType = 'not_allowed' }
    end

    if type(input.hitId) ~= 'number' then
        return 'invalid', { hitId = 'required' }
    end

    if not Query.CONFIRM_OUTCOMES[input.outcome] then
        return 'invalid', { outcome = 'not_allowed' }
    end

    if input.outcome == 'confirmed'
        and not Query.blankToNull(input.caseNumber)
        and not Query.blankToNull(input.detail)
    then
        return 'invalid', { caseNumber = 'required' }
    end

    return nil
end

--- Trims, and turns an empty string into nil.
---
--- The same helper the registers carry, because an empty box and an absent one
--- mean the same thing to an officer and storing both makes every later query
--- check for two things.
function Query.blankToNull(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:gsub('^%s*(.-)%s*$', '%1')
    if trimmed == '' then return nil end

    return trimmed
end

--- Is a hit still live, given the row it was raised from?
---
--- A flag that has been cleared, a caution that has been cancelled and a
--- firearm that has been recovered are all leads that have gone away between
--- the query and the confirmation, and confirming one would put "confirmed" in
--- the log against something that is no longer true.
---
--- Expiry arrives as a boolean the *database* computed (`expired`), never as a
--- timestamp compared here: a clock comparison belongs where the clock is
--- (invariant 1), and a server's clock and its database's need not agree.
---
--- @param hitType string
--- @param row table the flag, firearm or caution as the repo read it
--- @return boolean
function Query.hitIsLive(hitType, row)
    if type(row) ~= 'table' then return false end
    if row.expired == true or row.expired == 1 then return false end

    if hitType == 'vehicle_flag' then
        return row.clearedAt == nil and registry().VEHICLE_HOTFILE[row.kind] == true
    end

    if hitType == 'firearm' then
        return registry().FIREARM_HOTFILE[row.status] == true
    end

    return row.cancelledAt == nil and Query.PERSON_HOTFILE[row.kind] == true
end

FredPD.Modules.query = Query
