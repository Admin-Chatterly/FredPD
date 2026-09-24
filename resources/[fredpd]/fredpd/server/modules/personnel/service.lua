--- Personnel: roster detail, equipment, certifications and the disciplinary
--- file (spec 7.22-7.24).
---
--- Pure: no natives, no database, so busted exercises it outside FXServer
--- (`spec/personnel_spec.lua`).
---
--- **Rank grants nothing.** ADR-010 settled that FXServer only ever reads the
--- Discord guild; nothing here writes a role back, and nothing here treats a
--- Discord role as a permission by itself (invariant 2). `division` is a
--- roster label a supervisor sets from this screen, not a permission source.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Personnel = {}

-- -----------------------------------------------------------------------------
-- Allowlists
--
-- Equipment and certifications are locale keys, rendered with `t()` by the
-- NUI -- so, like `Tvang.isTvangGrund` and `Court.isBeslutGrund`, the server
-- checks them against a closed list rather than trusting a client-side one.
-- A free-text item name would print verbatim through `t()` the day it does
-- not match a key, which is the exact defect that review found in four other
-- modules before this one.
-- -----------------------------------------------------------------------------

local EQUIPMENT_ITEMS <const> = {
    'sidearm', 'taser', 'vest', 'radio', 'bodycam', 'laptop', 'less_lethal', 'other',
}

local IS_EQUIPMENT_ITEM <const> = {}
for index = 1, #EQUIPMENT_ITEMS do IS_EQUIPMENT_ITEM[EQUIPMENT_ITEMS[index]] = true end

function Personnel.isEquipmentItem(value) return IS_EQUIPMENT_ITEM[value] == true end

local CERTIFICATIONS <const> = {
    'fto', 'firearms_instructor', 'evoc', 'k9_handler', 'swat', 'crisis_negotiator',
    'motor_unit', 'air_unit', 'field_training', 'breach',
}

local IS_CERTIFICATION <const> = {}
for index = 1, #CERTIFICATIONS do IS_CERTIFICATION[CERTIFICATIONS[index]] = true end

function Personnel.isCertification(value) return IS_CERTIFICATION[value] == true end

local DISCIPLINE_CATEGORIES <const> = {
    'conduct', 'use_of_force', 'policy', 'performance', 'complaint_external',
}

local IS_DISCIPLINE_CATEGORY <const> = {}
for index = 1, #DISCIPLINE_CATEGORIES do IS_DISCIPLINE_CATEGORY[DISCIPLINE_CATEGORIES[index]] = true end

function Personnel.isDisciplineCategory(value) return IS_DISCIPLINE_CATEGORY[value] == true end

local DISCIPLINE_OUTCOMES <const> = {
    'unfounded', 'exonerated', 'sustained_counseled', 'sustained_written',
    'sustained_suspension', 'sustained_termination',
}

local IS_DISCIPLINE_OUTCOME <const> = {}
for index = 1, #DISCIPLINE_OUTCOMES do IS_DISCIPLINE_OUTCOME[DISCIPLINE_OUTCOMES[index]] = true end

function Personnel.isDisciplineOutcome(value) return IS_DISCIPLINE_OUTCOME[value] == true end

-- -----------------------------------------------------------------------------
-- Certification usable as a context condition (spec 7.23)
-- -----------------------------------------------------------------------------

--- Whether a certification row is currently in force: not revoked, and not
--- past its own expiry when it has one.
function Personnel.certificationIsActive(row, now)
    if row.revokedAt then return false end
    if row.expiresAt and row.expiresAt <= now then return false end

    return true
end

-- -----------------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------------

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateRosterUpdate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if input.badgeNumber ~= nil and (type(input.badgeNumber) ~= 'string' or #input.badgeNumber > 16) then
        return 'invalid', { badgeNumber = 'too_long' }
    end

    if input.division ~= nil and (type(input.division) ~= 'string' or #input.division > 64) then
        return 'invalid', { division = 'too_long' }
    end

    if input.callsign ~= nil and not Personnel.isCallsign(input.callsign) then
        return 'invalid', { callsign = 'callsign_format' }
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- Callsigns
--
-- `fpd_units.callsign` is NOT NULL, so an officer without one never reaches the
-- unit board. Every officer used to need a supervisor to type one in, and
-- nothing in the interface could -- so after the first officer, nobody did.
-- They are generated now, and a supervisor can still change one.
-- -----------------------------------------------------------------------------

--- Letters, digits, hyphens and spaces, 1-16 characters, not blank. Tight on
--- purpose: it is printed on the board, on the map and in radio text.
function Personnel.isCallsign(value)
    if type(value) ~= 'string' then return false end
    if #value < 1 or #value > 16 then return false end
    if value:match('^%s') or value:match('%s$') then return false end

    return value:match('^[%w%- ]+$') ~= nil
end

--- Fills `{prefix}` and `{n}` in a callsign format. A function replacement
--- rather than a string one, so a `%` in either value is text, not a pattern.
function Personnel.formatCallsign(format, prefix, n)
    local out = tostring(format or '{prefix}-{n}')
    out = out:gsub('{prefix}', function() return tostring(prefix or '') end)
    out = out:gsub('{n}', function() return tostring(n) end)

    return out
end

--- The first callsign of the configured format nobody on the roster holds.
---
--- @param format string e.g. '{prefix}-{n}'
--- @param prefix string e.g. 'LSPD' or '1-ADAM'
--- @param start number first sequence number tried
--- @param taken table set of callsigns already in use, compared case-insensitively
--- @return string|nil callsign, nil when the format cannot produce a valid free one
function Personnel.nextCallsign(format, prefix, start, taken)
    local lowered = {}
    for callsign in pairs(taken or {}) do lowered[tostring(callsign):lower()] = true end

    local first = math.max(0, math.floor(tonumber(start) or 1))

    for n = first, first + 9999 do
        local candidate = Personnel.formatCallsign(format, prefix, n)

        if not Personnel.isCallsign(candidate) then return nil end
        if not lowered[candidate:lower()] then return candidate end
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateEquipmentAssign(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Personnel.isEquipmentItem(input.itemKey) then
        return 'invalid', { itemKey = 'not_a_key' }
    end

    if input.serial ~= nil and (type(input.serial) ~= 'string' or #input.serial > 64) then
        return 'invalid', { serial = 'too_long' }
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateCertificationIssue(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Personnel.isCertification(input.certKey) then
        return 'invalid', { certKey = 'not_a_key' }
    end

    if input.expiresAt ~= nil and type(input.expiresAt) ~= 'number' then
        return 'invalid', { expiresAt = 'type' }
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateLoadoutCreate(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.name) ~= 'string' or input.name:gsub('%s', '') == '' or #input.name > 191 then
        return 'invalid', { name = 'required' }
    end

    if type(input.itemKeys) ~= 'table' or #input.itemKeys == 0 then
        return 'invalid', { itemKeys = 'required' }
    end

    local seen = {}
    for index = 1, #input.itemKeys do
        local key = input.itemKeys[index]

        if not Personnel.isEquipmentItem(key) then
            return 'invalid', { itemKeys = 'not_a_key' }
        end

        if seen[key] then return 'invalid', { itemKeys = 'duplicate' } end
        seen[key] = true
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateSetLoadout(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if type(input.officerId) ~= 'number' or input.officerId < 1 then
        return 'invalid', { officerId = 'required' }
    end

    -- `loadoutId` absent means "unassign"; the value itself is checked
    -- against the catalogue by the route, the same way a tariff id is.
    if input.loadoutId ~= nil and (type(input.loadoutId) ~= 'number' or input.loadoutId < 1) then
        return 'invalid', { loadoutId = 'invalid' }
    end

    return nil
end

-- -----------------------------------------------------------------------------
-- Issue gates (0027): a Discord role or permission group required to issue
-- one equipment item or certification key, beyond the base
-- `personnel.equipment.manage`/`personnel.certification.manage` grant --
-- the identical shape `Garage.gatingSatisfied` already gives a fleet entry.
-- -----------------------------------------------------------------------------

local ISSUE_KINDS <const> = { equipment = true, certification = true }

function Personnel.isIssueKind(value) return ISSUE_KINDS[value] == true end

--- A permission group key, the same shape `Garage.isGroupKey` checks.
function Personnel.isGroupKey(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- A Discord role id (a snowflake), the same shape `Garage.isDiscordRoleId`
--- checks -- stored and compared as text since a JSON decoder is entitled to
--- hand a bare number back for one.
function Personnel.isDiscordRoleId(value)
    return type(value) == 'string' and #value <= 32 and value:match('^%d+$') ~= nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateIssueGateSet(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Personnel.isIssueKind(input.kind) then
        return 'invalid', { kind = 'not_a_key' }
    end

    local knownKey = (input.kind == 'equipment' and Personnel.isEquipmentItem(input.itemKey))
        or (input.kind == 'certification' and Personnel.isCertification(input.itemKey))
    if not knownKey then
        return 'invalid', { itemKey = 'not_a_key' }
    end

    -- A row with neither column set would gate nothing while still
    -- occupying the unique slot for this key (0027's own header) -- refused
    -- here with a field error rather than left to the database's CHECK.
    if not input.requiredGroup and not input.requiredDiscordRole then
        return 'invalid', { _input = 'gate_required' }
    end

    if input.requiredGroup ~= nil and not Personnel.isGroupKey(input.requiredGroup) then
        return 'invalid', { requiredGroup = 'not_group_key' }
    end

    if input.requiredDiscordRole ~= nil and not Personnel.isDiscordRoleId(input.requiredDiscordRole) then
        return 'invalid', { requiredDiscordRole = 'not_snowflake' }
    end

    return nil
end

--- Whether this session's gate-checking predicates satisfy a gate row.
---
--- One gate satisfied is enough, and no gate row at all means "open to
--- anyone who already holds the base permission" -- the identical rule
--- `Garage.gatingSatisfied` applies to a fleet entry, for the identical
--- reason: requiring *both* would mean every gated key needs two pieces of
--- configuration kept in step, and the first one to drift silently takes
--- the item away from the officer who is supposed to have it.
---
--- @param gate table|nil { requiredGroup, requiredDiscordRole }
--- @param holdsDiscordRole function(roleId) -> boolean
--- @param satisfiesGroup function(groupKey) -> boolean
--- @return boolean
function Personnel.gatingSatisfied(gate, holdsDiscordRole, satisfiesGroup)
    if not gate then return true end

    local role = gate.requiredDiscordRole
    local group = gate.requiredGroup

    if not role and not group then return true end
    if role and holdsDiscordRole(role) then return true end
    if group and satisfiesGroup(group) then return true end

    return false
end

-- -----------------------------------------------------------------------------
-- Duty-based auto issue (0026)
-- -----------------------------------------------------------------------------

--- Which of a loadout's items are not already open on this officer -- the
--- arithmetic behind auto-issue on duty-on, kept pure so busted can pin it
--- without a database (`Repo.applyDutyChange` is the caller).
---
--- A shift that starts with a radio already open (never returned from the
--- one before, or issued by hand) gets one radio, not two: the diff is
--- against what is actually open, never against what was auto-issued last
--- time.
---
--- @param loadoutItemKeys table item_key strings the loadout carries
--- @param openItemKeys table item_key strings already open on the officer
--- @return table item_key strings still to issue
function Personnel.itemsToIssue(loadoutItemKeys, openItemKeys)
    local open = {}
    for index = 1, #openItemKeys do open[openItemKeys[index]] = true end

    local out = {}
    for index = 1, #loadoutItemKeys do
        local key = loadoutItemKeys[index]
        if not open[key] then out[#out + 1] = key end
    end

    return out
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateDisciplineOpen(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Personnel.isDisciplineCategory(input.category) then
        return 'invalid', { category = 'not_a_key' }
    end

    if type(input.summary) ~= 'string' or #input.summary == 0 then
        return 'invalid', { summary = 'required' }
    end

    return nil
end

--- @return string|nil code
--- @return table|nil fields
function Personnel.validateDisciplineClose(input)
    if type(input) ~= 'table' then return 'invalid', { _input = 'type' } end

    if not Personnel.isDisciplineOutcome(input.outcomeKey) then
        return 'invalid', { outcomeKey = 'not_a_key' }
    end

    return nil
end

FredPD.Modules.personnel = Personnel

return Personnel
