--- Record-level access (spec 4.5, invariant 4).
---
--- Every read in the suite passes through here, so this file decides what an
--- officer may see. It is pure -- no natives, no database, no locale lookups --
--- for one reason: the rules below are the security model, and a security model
--- that can only be exercised by starting a game server is a security model
--- nobody exercises. `spec/access_spec.lua` runs every branch of it in busted.
---
--- The model, from 4.5:
---
---   * A **classification** is a level on one ordered scale:
---     open < internal < restricted < confidential < secret.
---   * A **compartment** is a need-to-know group (`narcotics`, `sources`, ...).
---     Compartments are not a scale. They are ANDed: a record in three of them
---     needs a reader in all three.
---   * A record also has an **owning agency**, **explicit grants** (per user or
---     per Discord role, with an expiry) and a **sealed** flag (court-sealed).
---
--- The read rule: clearance >= classification AND membership in every
--- compartment on the record -- or an explicit, unexpired grant. A sealed
--- record is refused to everyone without the seal-break permission.
---
--- Three rules shape the code beyond that:
---
---   1. **Every unknown fails closed.** An unrecognised classification, an
---      unconfigured compartment, a malformed grant and a missing reader all
---      deny. The failure mode of the other direction is disclosure.
---   2. **Hidden means absent.** A record the reader may not know exists does
---      not appear in a result -- not as an id, not as a placeholder, not as a
---      count, and not as a second return value that says how many were
---      dropped. `filterSearchResults` therefore returns exactly one value.
---   3. **A stub is built, never redacted.** `Access.stub` constructs a fresh
---      table with three fields. Deleting fields from a record would leak the
---      next column somebody adds to it.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Access = {}

-- -----------------------------------------------------------------------------
-- The scale
-- -----------------------------------------------------------------------------

--- Classification levels in order, lowest first. Must stay in step with
--- `FredPD.Classification` in the generated schema (spec 4.5).
Access.LEVELS = { 'open', 'internal', 'restricted', 'confidential', 'secret' }

local RANK <const> = { open = 1, internal = 2, restricted = 3, confidential = 4, secret = 5 }

--- What a record is classified as when its row says nothing.
---
--- `internal` rather than `open`: a record that reached the database without a
--- classification is a bug in whatever wrote it, and the safe reading of a bug
--- is "not public".
local DEFAULT_CLASSIFICATION <const> = 'internal'

--- What a reader is cleared for when no `clearance.<level>` permission is held.
---
--- `open` is the floor of the scale, not an absence of one: it lets a reader
--- with no clearance at all see records that are open by definition, and
--- nothing else. Anything internal or above needs the permission.
local DEFAULT_CLEARANCE <const> = 'open'

--- Permission keys that carry clearance and compartment membership (Appendix B).
local CLEARANCE_PREFIX <const> = 'clearance.'
local COMPARTMENT_PREFIX <const> = 'compartment.'

--- The permission that opens a court-sealed record.
Access.SEAL_PERMISSION = 'records.seal.view'

--- The permission that lets a reader take break-glass access (4.5). Holding it
--- grants nothing by itself: it lets the reader *create* a break-glass grant,
--- with a written reason, which then reaches this module as an ordinary
--- unexpired grant like any other.
Access.BREAKGLASS_PERMISSION = 'records.breakglass'

--- The rank of a classification level, or nil when it is not one.
---
--- nil is a real answer and every caller must treat it as "refuse". A level
--- this module does not recognise is either a typo or a level somebody removed
--- from the configuration while records still carry it; in both cases the
--- records stay shut until somebody fixes it.
---
--- @param level string|nil
--- @return number|nil
function Access.clearanceRank(level)
    if type(level) ~= 'string' then return nil end

    return RANK[level]
end

--- True when `level` is one of the five.
function Access.isLevel(level)
    return Access.clearanceRank(level) ~= nil
end

-- -----------------------------------------------------------------------------
-- Configuration (4.5: "per compartment ... configurable")
-- -----------------------------------------------------------------------------

--- Whether a record the reader cannot see is hidden or shown as a stub, per
--- compartment, and which unit the stub tells them to contact.
---
--- `contact` is a *key*, never a sentence: the NUI renders
--- `access.unit.<contact>` (invariant 6). Nothing in this file is user-facing
--- text and nothing in it may become user-facing text.
---
--- The defaults below are what FredPD ships with; `fpd_compartments` overrides
--- them at boot through `Access.configure`. `intelligence` and `sources` are
--- hidden rather than stubbed because for those two the *existence* of the
--- record is the sensitive part: a stub reading "contact the intelligence unit"
--- on a person's file tells a reader that person is of intelligence interest,
--- which is the one fact a covert register must not publish.
local DEFAULT_COMPARTMENTS <const> = {
    internal_affairs = { stub = true, contact = 'internal_affairs' },
    narcotics = { stub = true, contact = 'narcotics' },
    homicide = { stub = true, contact = 'homicide' },
    intelligence = { stub = false },
    sources = { stub = false },
}

--- The same choice for a record denied on its classification alone, per level.
---
--- `secret` is hidden: everything below it may say "there is a record here and
--- it is not for you", which is how a records unit works, but a secret record
--- that announces itself in every search is not secret.
local DEFAULT_CLASSIFICATION_POLICY <const> = {
    open = { stub = true },
    internal = { stub = true },
    restricted = { stub = true },
    confidential = { stub = true },
    secret = { stub = false },
}

local config = {
    compartments = DEFAULT_COMPARTMENTS,
    classifications = DEFAULT_CLASSIFICATION_POLICY,

    --- Who a stub tells the reader to contact when no compartment names anyone.
    defaultContact = 'records',

    --- Court-sealed records are hidden by default. A seal is a court order that
    --- the record is not to be disclosed, and a stub is a disclosure that it
    --- exists. Configurable because some agencies run the opposite practice.
    sealedStub = false,
}

--- Replaces the parts of the configuration that are named.
---
--- Called once at boot by `repo.lua` with what `fpd_compartments` and
--- `fpd_classifications` hold, and by the spec with whatever a test needs.
--- Anything not named keeps the shipped default, so a half-filled table cannot
--- quietly widen access.
---
--- @param values table|nil { compartments, classifications, defaultContact, sealedStub }
function Access.configure(values)
    values = values or {}

    if type(values.compartments) == 'table' then config.compartments = values.compartments end
    if type(values.classifications) == 'table' then config.classifications = values.classifications end
    if type(values.defaultContact) == 'string' then config.defaultContact = values.defaultContact end
    if type(values.sealedStub) == 'boolean' then config.sealedStub = values.sealedStub end
end

--- Restores the shipped defaults. For tests and for a failed configuration
--- reload, which must fall back to something closed rather than to nothing.
function Access.resetConfiguration()
    config = {
        compartments = DEFAULT_COMPARTMENTS,
        classifications = DEFAULT_CLASSIFICATION_POLICY,
        defaultContact = 'records',
        sealedStub = false,
    }
end

--- The policy for one compartment, or nil when nobody has configured it.
function Access.compartmentPolicy(name)
    if type(name) ~= 'string' then return nil end

    return config.compartments[name]
end

--- Every compartment the configuration knows about, sorted.
function Access.compartmentNames()
    local names = {}
    for name in pairs(config.compartments) do names[#names + 1] = name end
    table.sort(names)

    return names
end

-- -----------------------------------------------------------------------------
-- Readers
-- -----------------------------------------------------------------------------

--- Turns a list, a set, or nothing into a set of names.
---
--- Rows arrive as `{ 'narcotics', 'homicide' }` from a join and as
--- `{ narcotics = true }` from a session, and both mean the same thing.
---
--- @param value table|nil
--- @return table set of strings
function Access.nameSet(value)
    local set = {}
    if type(value) ~= 'table' then return set end

    for key, entry in pairs(value) do
        if type(key) == 'number' then
            -- A list: either of plain strings or of join rows.
            local name = type(entry) == 'table' and (entry.compartment or entry.name) or entry
            if type(name) == 'string' then set[name] = true end
        elseif entry then
            set[key] = true
        end
    end

    return set
end

--- Sorts a set into a list, so anything derived from one is deterministic.
local function sortedKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)

    return out
end

--- The highest clearance a permission set carries.
---
--- Exact keys only. `Perms.satisfies` honours a wildcard in a grant, and that
--- is right for `rms.person.*`; it is wrong here, because it would make
--- `clearance.*` -- or a careless `*` -- silently equal to secret clearance for
--- everyone holding it. A clearance is a deliberate act, so it must be spelled
--- out. Appendix B says as much: `clearance.<level>` is a pattern, and the
--- permission editor does not offer it as a key.
---
--- @param permissions table|nil set of permission keys
--- @return string the level; `open` when none is held
function Access.clearanceOf(permissions)
    if type(permissions) ~= 'table' then return DEFAULT_CLEARANCE end

    local best = DEFAULT_CLEARANCE

    for index = 1, #Access.LEVELS do
        local level = Access.LEVELS[index]
        if permissions[CLEARANCE_PREFIX .. level] and RANK[level] > RANK[best] then
            best = level
        end
    end

    return best
end

--- The compartments a permission set puts its holder in.
function Access.compartmentsOf(permissions)
    local held = {}
    if type(permissions) ~= 'table' then return held end

    for key, granted in pairs(permissions) do
        if granted and type(key) == 'string' then
            local name = key:match('^' .. COMPARTMENT_PREFIX .. '([a-z][a-z0-9_]*)$')
            if name then held[name] = true end
        end
    end

    return held
end

--- Builds the reader every function below takes, from a session (spec 4.6).
---
--- The session is the truth (invariant 1): clearance, compartments and agency
--- come from Discord-derived permissions the server computed, never from route
--- input. `extra` carries what the session does not hold yet -- the reader's
--- Discord role ids, for role grants; the agencies their own agency shares with;
--- and `now`, so a test can decide what time it is.
---
--- @param session table
--- @param extra table|nil { roleIds, sharedAgencies, now }
--- @return table reader
function Access.reader(session, extra)
    session = session or {}
    extra = extra or {}

    local permissions = session.permissions or {}

    -- A session that already carries clearance and compartments (4.6) wins;
    -- otherwise both are derived from the permission set, which is the same
    -- Discord-derived data by another route.
    local compartments = Access.nameSet(session.compartments)
    if next(compartments) == nil then
        compartments = Access.compartmentsOf(permissions)
    end

    return {
        discordId = session.discordId,
        agencyId = session.agencyId,
        clearance = session.clearance or Access.clearanceOf(permissions),
        compartments = compartments,
        sealBreak = permissions[Access.SEAL_PERMISSION] == true,
        roleIds = extra.roleIds or {},
        sharedAgencies = Access.nameSet(extra.sharedAgencies),
        now = extra.now,
    }
end

--- What time it is for this decision.
---
--- A reader carrying `now` decides for itself, which is what makes grant expiry
--- testable without waiting. `os.time` is the Lua standard library rather than
--- a native, so this file stays loadable in busted.
local function nowFor(reader)
    return reader.now or os.time()
end

-- -----------------------------------------------------------------------------
-- Records
-- -----------------------------------------------------------------------------

--- True for the several shapes MariaDB and oxmysql answer a boolean with.
local function truthy(value)
    return value == true or value == 1
end

--- The access control on a record, in one shape.
---
--- Accepts a row as any repo hands it over: camelCase from a column alias,
--- snake_case from a raw select, compartments as a list or a set, grants absent
--- entirely. Everything missing takes the closed default.
---
--- @param record table|nil
--- @return table { agencyId, classification, compartments (set), sealed, grants }
function Access.control(record)
    if type(record) ~= 'table' then
        return { classification = DEFAULT_CLASSIFICATION, compartments = {}, sealed = true, grants = {} }
    end

    return {
        agencyId = record.agencyId or record.agency_id,
        classification = record.classification or DEFAULT_CLASSIFICATION,
        compartments = Access.nameSet(record.compartments),
        sealed = truthy(record.sealed) or truthy(record.is_sealed),
        grants = type(record.grants) == 'table' and record.grants or {},
    }
end

--- Is this a record whose reads are audited (invariant 11)?
---
--- Anything above `internal`, anything in a compartment, and anything sealed.
--- The audit log is the only place a legitimate-looking read of a sensitive
--- record can later be questioned, so the test is deliberately generous.
function Access.isRestricted(record)
    local control = Access.control(record)

    if control.sealed then return true end
    if next(control.compartments) ~= nil then return true end

    local rank = Access.clearanceRank(control.classification)

    -- An unrecognised classification counts as restricted: it is refused
    -- everywhere else, and a refusal is worth logging.
    return rank == nil or rank > RANK.internal
end

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

--- Does this reader hold one of the roles a grant names?
local function holdsRole(reader, subjectId)
    local roles = reader.roleIds
    if type(roles) ~= 'table' or subjectId == nil then return false end

    local wanted = tostring(subjectId)

    for index = 1, #roles do
        if tostring(roles[index]) == wanted then return true end
    end

    return false
end

--- The grant that lets this reader in, or nil.
---
--- A grant is an override of the classification and compartment rules together
--- (4.5: "... or an explicit grant"), which is what makes it worth an expiry:
--- an investigator lent a file for a week is not thereby cleared for the
--- compartment it sits in.
---
--- Expiry is compared against the reader's clock. A grant with no expiry never
--- expires, which is legitimate -- a case owner's own grant -- and a grant
--- whose expiry has passed is not a grant at all.
---
--- @param reader table
--- @param record table
--- @return table|nil the matching grant
function Access.grantFor(reader, record)
    if type(reader) ~= 'table' then return nil end

    local grants = Access.control(record).grants
    local now = nowFor(reader)

    for index = 1, #grants do
        local grant = grants[index]

        if type(grant) == 'table' then
            local subjectType = grant.subjectType or grant.subject_type
            local subjectId = grant.subjectId or grant.subject_id
            local expiresAt = grant.expiresAt or grant.expires_at

            local matches = false

            if subjectType == 'user' or subjectType == 'breakglass' then
                -- A user grant is keyed by Discord id, which is the identity
                -- FredPD grants anything on (invariant 2). A nil on either side
                -- must never match: an anonymous grant would be a grant to
                -- everyone.
                matches = reader.discordId ~= nil and subjectId ~= nil
                    and tostring(subjectId) == tostring(reader.discordId)
            elseif subjectType == 'role' then
                matches = holdsRole(reader, subjectId)
            end

            if matches and (expiresAt == nil or (type(expiresAt) == 'number' and expiresAt > now)) then
                return grant
            end
        end
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- The read rule (4.5)
-- -----------------------------------------------------------------------------

--- May this reader's agency see a record owned by `agencyId` at all?
---
--- A record with no owning agency belongs to whoever is reading it -- the
--- generic tables allow it and code tables (the penal code, classifications)
--- are stored that way. Anything with an owner is this agency's, or explicitly
--- shared with it (4.5, cross-agency sharing), or invisible.
---
--- @param reader table
--- @param agencyId string|nil the record's owning agency
--- @return boolean
function Access.agencyAllows(reader, agencyId)
    if agencyId == nil then return true end
    if type(reader) ~= 'table' then return false end
    if reader.agencyId == agencyId then return true end

    local shared = reader.sharedAgencies
    return type(shared) == 'table' and shared[agencyId] == true
end

--- Compartments on the record that the reader is not in, sorted.
---
--- @return table list of compartment names; empty when the reader is in all of them
function Access.missingCompartments(reader, record)
    local control = Access.control(record)
    local held = type(reader) == 'table' and reader.compartments or {}
    local missing = {}

    for name in pairs(control.compartments) do
        if not held[name] then missing[#missing + 1] = name end
    end

    table.sort(missing)

    return missing
end

--- May this reader read this record's contents?
---
--- The order of the tests is the order in which they refuse, and it matters:
---
---   1. A seal beats everything. A court order not to disclose is not overcome
---      by clearance, by a compartment, or by a grant somebody wrote before the
---      court sealed the file -- only by the seal-break permission.
---   2. An agency that does not own the record and has not been shared it sees
---      nothing. Cross-agency sharing is configured per data type (4.5) and the
---      caller resolves it into `reader.sharedAgencies`; unshared is the default
---      because the wrong default here is one department reading another's.
---   3. A grant, if there is a live one, ends the matter. It is the documented
---      override of both remaining rules.
---   4. Otherwise: clearance >= classification AND every compartment.
---
--- @param reader table
--- @param record table
--- @return boolean
function Access.canRead(reader, record)
    if type(reader) ~= 'table' or type(record) ~= 'table' then return false end

    local control = Access.control(record)

    if control.sealed then
        return reader.sealBreak == true
    end

    if not Access.agencyAllows(reader, control.agencyId) then return false end

    if Access.grantFor(reader, record) then return true end

    local required = Access.clearanceRank(control.classification)
    local held = Access.clearanceRank(reader.clearance) or RANK[DEFAULT_CLEARANCE]

    -- A classification nobody recognises is refused rather than guessed at.
    if required == nil or held < required then return false end

    return #Access.missingCompartments(reader, record) == 0
end

-- -----------------------------------------------------------------------------
-- What a refused reader is shown (4.5, "restricted stubs")
-- -----------------------------------------------------------------------------

--- Does a policy table say "show a stub"? Anything unconfigured says no.
local function stubAllowed(policy)
    return type(policy) == 'table' and policy.stub == true
end

--- 'full', 'stub' or 'hidden'.
---
--- A refused record is hidden unless something positively says it may be
--- stubbed, and the strictest compartment wins: a record in both `narcotics`
--- (stubbed) and `sources` (hidden) is hidden, because the reader who sees the
--- stub learns the record exists, and `sources` is configured precisely so that
--- nobody learns that.
---
--- @return string 'full' | 'stub' | 'hidden'
function Access.visibility(reader, record)
    if Access.canRead(reader, record) then return 'full' end
    if type(reader) ~= 'table' or type(record) ~= 'table' then return 'hidden' end

    local control = Access.control(record)

    if control.sealed then
        return config.sealedStub and 'stub' or 'hidden'
    end

    -- Another agency's record is not ours to advertise, not even as a stub.
    if not Access.agencyAllows(reader, control.agencyId) then return 'hidden' end

    local missing = Access.missingCompartments(reader, record)

    if #missing > 0 then
        for index = 1, #missing do
            -- An unconfigured compartment has no policy, so `stubAllowed` is
            -- false and the record is hidden. That is the right way round: a
            -- compartment somebody invented in the database and never described
            -- must not default to announcing itself.
            if not stubAllowed(Access.compartmentPolicy(missing[index])) then
                return 'hidden'
            end
        end

        return 'stub'
    end

    -- Refused on classification alone.
    return stubAllowed(config.classifications[control.classification]) and 'stub' or 'hidden'
end

--- The minimal safe shape for a record the reader may know exists but not read.
---
--- Built from nothing, field by field. There is no id here, no name, no number,
--- no date, no classification and no agency: everything a stub carries is
--- either constant or a unit to ring up. A reader who can pair a stub with an
--- id can count records, correlate two searches and confirm a hunch about who
--- is in a file -- which is the leak this whole module exists to prevent.
---
--- `contact` is a key for `access.unit.<contact>`, never a sentence
--- (invariant 6). It comes from the compartment that blocked the read when the
--- caller knows which one that was, so the reader is sent to the unit that can
--- actually help, and falls back to the records unit.
---
--- @param record table
--- @param blockedBy table|nil compartment names from `missingCompartments`
--- @return table { restricted, recordType, contact }
function Access.stub(record, blockedBy)
    local contact

    local candidates = blockedBy
    if type(candidates) ~= 'table' or #candidates == 0 then
        candidates = sortedKeys(Access.control(record).compartments)
    end

    for index = 1, #candidates do
        local policy = Access.compartmentPolicy(candidates[index])
        if policy and policy.contact then
            contact = policy.contact
            break
        end
    end

    local recordType = type(record) == 'table' and record.recordType or nil

    return {
        restricted = true,
        recordType = type(recordType) == 'string' and recordType or nil,
        contact = contact or config.defaultContact,
    }
end

--- The access-control working fields, which never leave the server.
---
--- `grants` names the Discord ids and role ids of everybody else who has been
--- let into the record. A reader cleared for the record is not thereby cleared
--- for the list of who else is.
local function withoutGrants(row)
    if type(row) ~= 'table' or row.grants == nil then return row end

    local copy = {}
    for key, value in pairs(row) do
        if key ~= 'grants' then copy[key] = value end
    end

    return copy
end

--- Shapes a list of rows by what this reader may see (invariant 4).
---
--- This is the function that makes search safe, and it has one hard rule:
--- **a hidden row leaves no trace.** It is not in the list, there is no gap
--- where it was, and nothing about it is returned alongside the list -- which
--- is why this returns exactly one value and never a count of what it dropped.
--- A caller that needs to know how many rows it asked for against how many came
--- back can subtract, and a caller that pages must over-fetch; neither is a
--- reason to hand the reader a number that means "there is something here you
--- are not allowed to know about".
---
--- @param reader table
--- @param rows table|nil list of rows carrying their own access control
--- @return table rows, each either the row itself or a stub
function Access.filterSearchResults(reader, rows)
    local out = {}
    if type(rows) ~= 'table' then return out end

    for index = 1, #rows do
        local row = rows[index]
        local visibility = Access.visibility(reader, row)

        if visibility == 'full' then
            out[#out + 1] = withoutGrants(row)
        elseif visibility == 'stub' then
            out[#out + 1] = Access.stub(row, Access.missingCompartments(reader, row))
        end
    end

    return out
end

FredPD.Modules.access = Access
