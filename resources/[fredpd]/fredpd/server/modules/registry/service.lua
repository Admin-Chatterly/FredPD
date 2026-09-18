--- Vehicle and firearm registry logic (spec 7.4, 7.5).
---
--- Pure: no natives, no database, no locale lookups, so busted exercises it
--- outside FXServer (`spec/registry_spec.lua`).
---
--- What lives here is everything about the two registers that is a *rule*
--- rather than a query:
---
---   * **The VIN.** Generated here, never accepted from input (invariant 1).
---     A VIN is a permanent identity for a vehicle; a client that could choose
---     one could give a stolen car the identity of a clean one, which is the
---     oldest trick in vehicle crime and would work perfectly against a
---     registry that believed the client. The generator follows ISO 3779 --
---     seventeen characters, no I, O or Q, and a check digit in position nine --
---     so a typo'd VIN read off a dashboard fails arithmetic rather than
---     silently opening the wrong file.
---   * **Normalisation.** A plate is stored upper-case with the spaces removed
---     and a serial the same way, so `abc 123` and `ABC123` are one plate and
---     an officer who types a serial in lower case still finds the weapon.
---   * **The allowlists.** Flag kinds, firearm statuses and the event each
---     status change writes. They mirror the CHECK constraints in migration
---     0005, in code, because a value that reaches the database and is refused
---     there surfaces as an internal error rather than as a field error the
---     officer can act on.
---   * **Hot-file logic** (7.2): which of a vehicle's live flags and which of a
---     firearm's statuses constitute a hit that must be shown in red.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Registry = {}

-- -----------------------------------------------------------------------------
-- Normalisation
-- -----------------------------------------------------------------------------

--- Trims, and turns an empty string into nil.
---
--- An empty text field and an absent one mean the same thing to an officer, and
--- storing both makes every later query check for two things.
function Registry.blankToNull(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:gsub('^%s*(.-)%s*$', '%1')
    if trimmed == '' then return nil end

    return trimmed
end

--- Plates: upper-case, inner whitespace removed.
---
--- The same normalisation the intelligence module applies, deliberately: a
--- plate read off an ALPR camera, typed into a query and stored on a record
--- must compare equal in all three places or the hot-file check misses.
function Registry.normalizePlate(value)
    local plate = Registry.blankToNull(value)
    if not plate then return nil end

    return (plate:upper():gsub('%s+', ''))
end

--- Serials: upper-case, whitespace removed, same reasoning as a plate.
function Registry.normalizeSerial(value)
    local serial = Registry.blankToNull(value)
    if not serial then return nil end

    return (serial:upper():gsub('%s+', ''))
end

--- A search term: trimmed, upper-cased, nil when it is too short to be useful.
---
--- Two characters is the floor. One character matches most of the register and
--- costs a full scan, so it is refused rather than answered badly (spec 12).
function Registry.searchTerm(value)
    local term = Registry.blankToNull(value)
    if not term or #term < 2 then return nil end

    return (term:upper():gsub('%s+', ''))
end

-- -----------------------------------------------------------------------------
-- The VIN (7.4: "generated once and stored")
-- -----------------------------------------------------------------------------

Registry.VIN_LENGTH = 17

--- The ISO 3779 alphabet. I, O and Q are absent from it on purpose: they are
--- indistinguishable from 1 and 0 on a stamped plate, and a registry whose
--- identifiers cannot be read aloud over a radio is not much of a registry.
local VIN_ALPHABET <const> = '0123456789ABCDEFGHJKLMNPRSTUVWXYZ'

--- Position of the check digit, counting from one.
local VIN_CHECK_POSITION <const> = 9

--- The standard transliteration: every letter counts as a number.
local VIN_VALUES <const> = {
    A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, H = 8,
    J = 1, K = 2, L = 3, M = 4, N = 5, P = 7, R = 9,
    S = 2, T = 3, U = 4, V = 5, W = 6, X = 7, Y = 8, Z = 9,
}

--- The positional weights, in order.
local VIN_WEIGHTS <const> = { 8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2 }

--- The value one character contributes, or nil when it is not a VIN character.
local function vinValue(character)
    local digit = character:match('^%d$')
    if digit then return tonumber(digit) end

    return VIN_VALUES[character]
end

--- The check digit for a seventeen-character VIN.
---
--- The character already sitting in position nine is ignored, which is what
--- lets the generator below compute the digit for a VIN it is still building.
---
--- @param vin string
--- @return string|nil one character, `X` for a remainder of ten
function Registry.vinCheckDigit(vin)
    if type(vin) ~= 'string' or #vin ~= Registry.VIN_LENGTH then return nil end

    local sum = 0

    for index = 1, Registry.VIN_LENGTH do
        if index ~= VIN_CHECK_POSITION then
            local value = vinValue(vin:sub(index, index))
            if not value then return nil end

            sum = sum + value * VIN_WEIGHTS[index]
        end
    end

    local remainder = sum % 11

    return remainder == 10 and 'X' or tostring(remainder)
end

--- Is this a well-formed VIN, check digit included?
---
--- Used on a *query* term, never on a write: nothing about a stored VIN is ever
--- taken from input, so this exists to tell a VIN query apart from a plate
--- query, and to reject a mistyped one before it reaches the database.
function Registry.isVin(value)
    if type(value) ~= 'string' or #value ~= Registry.VIN_LENGTH then return false end
    if value:match('[^0-9A-HJ-NPR-Z]') then return false end

    local expected = Registry.vinCheckDigit(value)

    return expected ~= nil and value:sub(VIN_CHECK_POSITION, VIN_CHECK_POSITION) == expected
end

--- Generates a VIN (invariant 1).
---
--- `random` is injected so the spec can drive the generator deterministically
--- and assert the check digit; it defaults to `math.random`, which is the Lua
--- standard library rather than a native and so keeps this file loadable in
--- busted.
---
--- Sixteen characters are drawn from the alphabet and the seventeenth -- the
--- one in position nine -- is computed, so every VIN this function returns
--- satisfies `isVin`. Collisions are the caller's problem: the repo re-draws
--- against the unique index, which is the only authority on what is already
--- taken.
---
--- @param random function|nil `(min, max) -> integer`
--- @return string
function Registry.generateVin(random)
    random = random or math.random

    local characters = {}

    for index = 1, Registry.VIN_LENGTH do
        local pick = random(1, #VIN_ALPHABET)
        characters[index] = VIN_ALPHABET:sub(pick, pick)
    end

    -- Whatever was drawn for position nine is replaced by the check digit.
    characters[VIN_CHECK_POSITION] = '0'

    local vin = table.concat(characters)
    characters[VIN_CHECK_POSITION] = Registry.vinCheckDigit(vin)

    return table.concat(characters)
end

-- -----------------------------------------------------------------------------
-- Allowlists (mirroring the CHECK constraints in migration 0005)
-- -----------------------------------------------------------------------------

--- Flags a vehicle can carry (7.4).
Registry.VEHICLE_FLAGS = {
    stolen = true, wanted = true, bolo = true,
    impounded = true, evidence_hold = true, uninsured = true,
}

--- The flags that are a hot-file hit (7.2). A vehicle that is impounded or
--- uninsured is a matter for the officer to read; one that is stolen, wanted or
--- the subject of a BOLO is a matter for the red banner.
Registry.VEHICLE_HOTFILE = { stolen = true, wanted = true, bolo = true }

Registry.REGISTRATION_STATUS = {
    valid = true, expired = true, suspended = true, revoked = true, unregistered = true,
}

Registry.INSURANCE_STATUS = { valid = true, expired = true, none = true }

--- Firearm statuses (7.5).
Registry.FIREARM_STATUS = {
    registered = true, lost = true, stolen = true,
    seized = true, destroyed = true, agency_issued = true,
}

--- The statuses that are a hot-file hit on a serial query (7.5).
Registry.FIREARM_HOTFILE = { lost = true, stolen = true }

Registry.FIREARM_TYPES = {
    pistol = true, revolver = true, rifle = true,
    shotgun = true, smg = true, other = true,
}

--- Every event the ownership history records (7.5).
Registry.FIREARM_EVENTS = {
    register = true, transfer = true, lost = true, stolen = true,
    recovered = true, seized = true, destroyed = true,
    issued = true, returned = true,
}

Registry.CLASSIFICATIONS = {
    open = true, internal = true, restricted = true, confidential = true, secret = true,
}

--- The event a status change writes into the ownership history.
---
--- Reporting a firearm lost or stolen is not an edit of a field, it is an event
--- in the life of the weapon (7.5), and the history is what a trace reads. A
--- status with no event of its own -- `registered`, reached by recovering a
--- weapon that was lost -- writes `recovered`, because that is what happened.
---
--- @param status string
--- @return string|nil event, nil when the status is not one of ours
function Registry.statusEvent(status)
    if not Registry.FIREARM_STATUS[status] then return nil end

    if status == 'registered' then return 'recovered' end
    if status == 'agency_issued' then return 'issued' end

    return status
end

-- -----------------------------------------------------------------------------
-- Hot-file checks (7.2)
-- -----------------------------------------------------------------------------

--- The hit kinds among a vehicle's live flags, in a stable order.
---
--- Keys, never sentences: the NUI renders `registry.flag.<kind>` (invariant 6).
---
--- @param flags table|nil rows with a `kind`
--- @return table list of kinds
function Registry.vehicleHits(flags)
    local hits = {}
    if type(flags) ~= 'table' then return hits end

    local seen = {}

    for index = 1, #flags do
        local flag = flags[index]
        local kind = type(flag) == 'table' and flag.kind or flag

        if type(kind) == 'string' and Registry.VEHICLE_HOTFILE[kind] and not seen[kind] then
            seen[kind] = true
            hits[#hits + 1] = kind
        end
    end

    table.sort(hits)

    return hits
end

--- The hit kinds on a firearm: its status, when that status is a hot one.
function Registry.firearmHits(firearm)
    local hits = {}
    if type(firearm) ~= 'table' then return hits end

    if Registry.FIREARM_HOTFILE[firearm.status] then
        hits[#hits + 1] = firearm.status
    end

    return hits
end

-- -----------------------------------------------------------------------------
-- Searching
-- -----------------------------------------------------------------------------

--- What kind of query a term is, for `fpd_query_log.query_type` (7.2).
---
--- A seventeen-character term that passes the check digit is a VIN; anything
--- else typed into the vehicle registry is a plate.
function Registry.queryType(term)
    return Registry.isVin(term) and 'vin' or 'plate'
end

--- How many rows to ask the database for when the officer wants `limit`.
---
--- Access filtering happens after the query and removes rows the reader may not
--- know about, so a page fetched at exactly `limit` comes back short. Over-fetch
--- and trim (the access module says as much: a caller that pages must
--- over-fetch, because it is never told how many rows were dropped).
---
--- @param limit number|nil
--- @param default number|nil
--- @return number window, number limit
function Registry.fetchWindow(limit, default)
    local wanted = math.floor(tonumber(limit) or default or 25)

    if wanted < 1 then wanted = 1 end
    if wanted > 100 then wanted = 100 end

    return math.min(wanted * 3, 300), wanted
end

--- Cuts a filtered list back to the page the officer asked for.
function Registry.trim(rows, limit)
    if type(rows) ~= 'table' then return {} end
    if #rows <= limit then return rows end

    local out = {}
    for index = 1, limit do out[index] = rows[index] end

    return out
end

--- Did this result reach restricted data (7.2)?
---
--- A stub is not a disclosure: the reader learns a record exists and nothing
--- else, which is the point of a stub. What needs a reason is a restricted
--- record the reader actually *opened*, so only rows with contents are counted.
---
--- `isRestricted` is injected rather than required, because it belongs to the
--- access module and this file is pure.
---
--- @param rows table rows as the access module shaped them
--- @param isRestricted function `(row) -> boolean`
--- @return boolean
function Registry.opensRestricted(rows, isRestricted)
    if type(rows) ~= 'table' or type(isRestricted) ~= 'function' then return false end

    for index = 1, #rows do
        local row = rows[index]

        -- A stub carries no id. Anything with one is a record that was opened.
        if type(row) == 'table' and row.id ~= nil and isRestricted(row) then
            return true
        end
    end

    return false
end

-- -----------------------------------------------------------------------------
-- Validation beyond what a schema expresses
-- -----------------------------------------------------------------------------

--- A flag needs a kind the register knows and, for a hot one, something to
--- point at: a case number or a written detail.
---
--- The reason a stolen-vehicle flag must say where it came from is the hit
--- confirmation step (7.2). An officer who stops a car on a hit has to be able
--- to confirm it against something, and "it was flagged" is not something.
---
--- @return string|nil error code, table|nil fields
function Registry.validateFlag(input)
    if not Registry.VEHICLE_FLAGS[input.kind] then
        return 'invalid', { kind = 'not_allowed' }
    end

    if Registry.VEHICLE_HOTFILE[input.kind]
        and not Registry.blankToNull(input.caseNumber)
        and not Registry.blankToNull(input.detail)
    then
        return 'invalid', { caseNumber = 'required' }
    end

    if input.classification ~= nil and not Registry.CLASSIFICATIONS[input.classification] then
        return 'invalid', { classification = 'not_allowed' }
    end

    return nil
end

--- A transfer moves a firearm to somebody. Exactly one of a person on file and
--- a named party outside it, because "transferred to nobody" is how a weapon
--- disappears from a register while staying in circulation.
function Registry.validateTransfer(input)
    local hasPerson = type(input.toPersonId) == 'number'
    local hasParty = Registry.blankToNull(input.toParty) ~= nil

    if not hasPerson and not hasParty then
        return 'invalid', { toPersonId = 'required' }
    end

    return nil
end

--- A status change needs a status we know and, when it takes the weapon out of
--- circulation, a reason somebody signed for.
function Registry.validateStatus(input)
    if not Registry.FIREARM_STATUS[input.status] then
        return 'invalid', { status = 'not_allowed' }
    end

    local needsReason = input.status == 'lost' or input.status == 'stolen'
        or input.status == 'destroyed' or input.status == 'seized'

    if needsReason
        and not Registry.blankToNull(input.reason)
        and not Registry.blankToNull(input.caseNumber)
    then
        return 'invalid', { reason = 'required' }
    end

    return nil
end

FredPD.Modules.registry = Registry
