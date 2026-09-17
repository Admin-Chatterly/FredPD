--- Motor pool logic (spec 7.31).
---
--- Pure: no natives, no database. The fleet filter is the interesting part —
--- it decides which vehicles an officer is shown and allowed to draw, and it is
--- the kind of rule that is easy to get subtly wrong, so it is testable.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Garage = {}

--- Plates are 8 characters in GTA, and the game upper-cases them.
local PLATE_LENGTH <const> = 8
local PLATE_ALPHABET <const> = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

--- The fleet entries this officer may draw.
---
--- An entry can require an extra permission, a certification, or both. Anything
--- the officer does not satisfy is filtered out rather than shown and refused:
--- a list full of vehicles you cannot take is worse than a short list.
---
--- @param fleet table rows from fpd_fleet
--- @param hasPermission function(permission) -> boolean
--- @param certifications table set of the officer's certifications
--- @return table allowed entries
function Garage.allowedFleet(fleet, hasPermission, certifications)
    local allowed = {}

    for index = 1, #fleet do
        local entry = fleet[index]
        local ok = entry.enabled ~= false

        if ok and entry.permission and not hasPermission(entry.permission) then
            ok = false
        end

        if ok and entry.certification and not certifications[entry.certification] then
            ok = false
        end

        if ok then allowed[#allowed + 1] = entry end
    end

    return allowed
end

--- Finds one fleet entry by model, among those the officer may draw.
---
--- Looking it up in the *filtered* list rather than the full one is what stops a
--- client asking for a model it was never offered: the restriction is applied
--- here, on the server, not by the menu that displayed it (invariant 4).
function Garage.findAllowed(fleet, model, hasPermission, certifications)
    local allowed = Garage.allowedFleet(fleet, hasPermission, certifications)

    for index = 1, #allowed do
        if allowed[index].model == model then return allowed[index] end
    end

    return nil
end

--- Generates an agency plate.
---
--- @param prefix string agency plate prefix, e.g. 'LSPD'
--- @param random function|nil injected for tests
--- @return string
function Garage.generatePlate(prefix, random)
    random = random or math.random

    local plate = (prefix or ''):upper():sub(1, PLATE_LENGTH - 2)
    local remaining = PLATE_LENGTH - #plate

    for _ = 1, remaining do
        local index = random(1, #PLATE_ALPHABET)
        plate = plate .. PLATE_ALPHABET:sub(index, index)
    end

    return plate
end

-- -----------------------------------------------------------------------------
-- Fleet gating (spec 7.31, migration 0003)
-- -----------------------------------------------------------------------------

--- Trims, and turns an empty string into nil.
---
--- An empty gate and an absent one mean the same thing to an administrator, and
--- a column holding `''` must never read as "gated on the empty role", which
--- would take the vehicle away from everyone.
function Garage.blankToNull(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:gsub('^%s*(.-)%s*$', '%1')
    if trimmed == '' then return nil end

    return trimmed
end

--- Does this fleet entry's gating let this officer draw it?
---
--- The rule, in one line: either gate opens the vehicle, and an entry with
--- neither gate is open to anyone who already holds `garage.vehicle.draw`.
---
--- Requiring *both* was the alternative and it is worse in practice: every gated
--- vehicle would then need two pieces of configuration kept in step, and the
--- first one to drift -- a renamed group, a Discord role rebuilt after a server
--- cleanup -- silently takes the vehicle away from the unit that depends on it.
--- One gate satisfied is a deliberate act of configuration either way.
---
--- Both answers are injected as predicates rather than looked up here. The role
--- list comes from the Discord snapshot and the group from the permission cache,
--- and this file holds no natives and no database so that busted can test the
--- rule itself (spec 3.4). Failing closed falls out of that: a predicate that
--- cannot answer -- an unknown group, a member the sync has never seen --
--- returns false, and the vehicle stays gated.
---
--- This narrows access and never widens it. An officer who passes a gate still
--- needs `garage.vehicle.draw`, still needs the entry's own `permission` and
--- `certification`, still needs to be on duty and still needs to be standing at
--- the motor pool.
---
--- @param entry table a row from fpd_fleet
--- @param holdsDiscordRole function(roleId) -> boolean
--- @param satisfiesGroup function(groupKey) -> boolean
--- @return boolean
function Garage.gatingSatisfied(entry, holdsDiscordRole, satisfiesGroup)
    local role = Garage.blankToNull(entry.requiredDiscordRole)
    local group = Garage.blankToNull(entry.requiredGroup)

    -- Ungated, which is most of a fleet. Both columns NULL is the default the
    -- migration adds, so every vehicle that existed before gating stays exactly
    -- as drawable as it was.
    if not role and not group then return true end

    if role and holdsDiscordRole(role) then return true end
    if group and satisfiesGroup(group) then return true end

    return false
end

--- The fleet this officer may actually draw from: `allowedFleet` narrowed again
--- by the gating columns.
---
--- Kept as its own function rather than folded into `allowedFleet` so that the
--- older filter -- permission, certification, enabled -- stays testable on its
--- own, and so the two predicates are only built by callers that have them.
---
--- @param fleet table rows from fpd_fleet
--- @param checks table { hasPermission, certifications, holdsDiscordRole, satisfiesGroup }
--- @return table drawable entries
function Garage.drawableFleet(fleet, checks)
    local allowed = Garage.allowedFleet(fleet, checks.hasPermission, checks.certifications or {})
    local drawable = {}

    for index = 1, #allowed do
        local entry = allowed[index]

        if Garage.gatingSatisfied(entry, checks.holdsDiscordRole, checks.satisfiesGroup) then
            drawable[#drawable + 1] = entry
        end
    end

    return drawable
end

-- -----------------------------------------------------------------------------
-- The fleet editor's input (spec 7.31, [S])
-- -----------------------------------------------------------------------------

--- A spawn name: lower-case letters, digits, underscore and hyphen.
function Garage.isModelName(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[a-z0-9_%-]+$') ~= nil
end

--- A locale key, which is what `label_key` holds -- never a display name
--- (invariant 6).
---
--- The distinction is the whole point of the column: the editor accepts
--- `fleet.cruiser` and the NUI renders whatever `en.json` and `sv.json` say it
--- is. Accepting "Police Cruiser" here would put an English string in the
--- database where no translation can ever reach it, and it would look like it
--- worked -- which is why the shape is enforced rather than trusted. At least
--- two dot-separated segments, no whitespace; segments may be camelCase,
--- because existing keys are (`placement.deleteTitle`).
function Garage.isLocaleKey(value)
    if type(value) ~= 'string' then return false end
    if #value == 0 or #value > 128 then return false end
    if value:find('%.%.') or value:sub(1, 1) == '.' or value:sub(-1) == '.' then return false end

    local segments = 0

    for segment in value:gmatch('[^%.]+') do
        if not segment:match('^[A-Za-z][A-Za-z0-9_]*$') then return false end
        segments = segments + 1
    end

    return segments >= 2
end

--- A permission key in Appendix B's shape: `<area>.<object>[.<action>]`.
function Garage.isPermissionKey(value)
    if type(value) ~= 'string' then return false end
    if #value == 0 or #value > 128 then return false end
    if value:find('%.%.') or value:sub(1, 1) == '.' or value:sub(-1) == '.' then return false end

    local segments = 0

    for segment in value:gmatch('[^%.]+') do
        if not segment:match('^[a-z][a-z0-9_]*$') then return false end
        segments = segments + 1
    end

    return segments >= 2
end

--- A permission group key, as `fpd_permission_groups` stores it.
function Garage.isGroupKey(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- A certification name (7.23).
function Garage.isCertification(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- A Discord role id: a snowflake, so digits only.
---
--- The shape is checked because a role *name* pasted into the field would
--- otherwise be stored happily and then never match anyone -- a vehicle gated
--- to nobody, with nothing in the row to say why.
function Garage.isDiscordRoleId(value)
    return type(value) == 'string' and #value <= 32 and value:match('^%d+$') ~= nil
end

--- Trims what the editor sent, and lower-cases the spawn name.
---
--- `''` is preserved rather than turned into nil, because on an update the two
--- mean different things: an absent field is "leave this alone" and an empty one
--- is "clear this gate". Only the repo turns the empty string into NULL.
function Garage.normalizeFleetInput(input)
    local entry = {}

    local function trim(value)
        if type(value) ~= 'string' then return value end
        return (value:gsub('^%s*(.-)%s*$', '%1'))
    end

    entry.model = input.model ~= nil and trim(input.model):lower() or nil
    entry.labelKey = trim(input.labelKey)
    entry.permission = trim(input.permission)
    entry.certification = input.certification ~= nil and trim(input.certification):lower() or nil
    entry.requiredGroup = input.requiredGroup ~= nil and trim(input.requiredGroup):lower() or nil
    entry.requiredDiscordRole = trim(input.requiredDiscordRole)
    entry.livery = input.livery
    entry.sortOrder = input.sortOrder
    entry.enabled = input.enabled

    return entry
end

--- Validates a normalized fleet entry.
---
--- @param entry table from `normalizeFleetInput`
--- @param required boolean true when adding: model and labelKey must be there
--- @return string|nil error code
--- @return table|nil field -> reason
function Garage.validateFleetInput(entry, required)
    local fields = {}

    -- `model` and `label_key` are NOT NULL, so an empty string is not "clear
    -- this field" for either of them -- it is a missing value.
    if entry.model == nil then
        if required then fields.model = 'required' end
    elseif entry.model == '' then
        fields.model = 'required'
    elseif not Garage.isModelName(entry.model) then
        fields.model = 'not_model'
    end

    if entry.labelKey == nil then
        if required then fields.labelKey = 'required' end
    elseif entry.labelKey == '' then
        fields.labelKey = 'required'
    elseif not Garage.isLocaleKey(entry.labelKey) then
        fields.labelKey = 'not_locale_key'
    end

    -- The rest are nullable: an empty string clears the gate, so only a
    -- non-empty value has a shape to get wrong.
    if entry.permission ~= nil and entry.permission ~= ''
        and not Garage.isPermissionKey(entry.permission)
    then
        fields.permission = 'not_permission_key'
    end

    if entry.certification ~= nil and entry.certification ~= ''
        and not Garage.isCertification(entry.certification)
    then
        fields.certification = 'not_certification'
    end

    if entry.requiredGroup ~= nil and entry.requiredGroup ~= ''
        and not Garage.isGroupKey(entry.requiredGroup)
    then
        fields.requiredGroup = 'not_group_key'
    end

    if entry.requiredDiscordRole ~= nil and entry.requiredDiscordRole ~= ''
        and not Garage.isDiscordRoleId(entry.requiredDiscordRole)
    then
        fields.requiredDiscordRole = 'not_snowflake'
    end

    if next(fields) then return 'invalid', fields end

    return nil
end

FredPD.Modules.garage = Garage
