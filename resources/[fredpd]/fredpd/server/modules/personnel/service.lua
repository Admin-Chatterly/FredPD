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
