--- Input validation against the generated schemas (spec 3.5).
---
--- The route layer runs this before a handler sees anything. It returns a
--- *cleaned* table containing only the fields the schema declares, so a handler
--- can never receive a key it did not ask for -- which is how a client smuggles
--- `officerId` or `agencyId` into an input it does not own (invariant 1).
---
--- Pure logic, no natives: unit-tested with busted.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Validate = {}

--- True when `value` appears in `list`.
local function contains(list, value)
    for index = 1, #list do
        if list[index] == value then return true end
    end

    return false
end

--- Checks one value against one field spec.
--- @return boolean ok
--- @return string|nil reason a short machine-readable code, for `fields`
--- @return any coerced
local function checkField(spec, value)
    if spec.type == 'string' then
        if type(value) ~= 'string' then return false, 'type' end

        local length = #value
        if spec.min and length < spec.min then return false, 'too_short' end
        if spec.max and length > spec.max then return false, 'too_long' end

        return true, nil, value
    end

    if spec.type == 'number' or spec.type == 'integer' then
        -- A numeric string is a client that did not serialize properly, not a
        -- number. Accepting it would make the type declaration meaningless.
        if type(value) ~= 'number' then return false, 'type' end
        if value ~= value then return false, 'type' end -- NaN
        if value == math.huge or value == -math.huge then return false, 'type' end

        if spec.type == 'integer' and math.floor(value) ~= value then
            return false, 'not_integer'
        end

        if spec.min and value < spec.min then return false, 'too_small' end
        if spec.max and value > spec.max then return false, 'too_large' end

        return true, nil, value
    end

    if spec.type == 'boolean' then
        if type(value) ~= 'boolean' then return false, 'type' end
        return true, nil, value
    end

    if spec.type == 'enum' then
        if type(value) ~= 'string' then return false, 'type' end
        if not contains(spec.values, value) then return false, 'not_allowed' end
        return true, nil, value
    end

    if spec.type == 'string[]' then
        if type(value) ~= 'table' then return false, 'type' end

        -- A table with any non-array key is an object, not a list. JSON turns an
        -- empty array and an empty object into the same Lua table, so only a
        -- non-empty one can be told apart -- and a wrong shape must not slip
        -- through as an empty list.
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        if count ~= #value then return false, 'type' end

        if spec.maxItems and #value > spec.maxItems then return false, 'too_many' end

        local cleaned = {}

        for index = 1, #value do
            local entry = value[index]
            if type(entry) ~= 'string' then return false, 'type' end
            if spec.maxLength and #entry > spec.maxLength then return false, 'too_long' end

            cleaned[index] = entry
        end

        return true, nil, cleaned
    end

    -- An unknown type in the schema is a generator bug, and failing closed is
    -- the only safe answer.
    return false, 'unknown_type'
end

--- Validates `input` against the schema registered under `schemaName`.
---
--- @param schemaName string a key in FredPD.Schema
--- @param input any what the client sent
--- @return table|nil cleaned only the declared fields, when valid
--- @return table|nil fields field name -> reason, when not
function Validate.check(schemaName, input)
    local schema = FredPD.Schema and FredPD.Schema[schemaName]
    if not schema then
        return nil, { _schema = 'unknown' }
    end

    -- A missing body is an empty one: a schema with no required fields should
    -- accept a call with no arguments.
    if input == nil then input = {} end
    if type(input) ~= 'table' then
        return nil, { _input = 'type' }
    end

    local cleaned = {}
    local fields = nil

    for name, spec in pairs(schema) do
        local value = input[name]

        if value == nil then
            if spec.required then
                fields = fields or {}
                fields[name] = 'required'
            end
        else
            local ok, reason, coerced = checkField(spec, value)

            if ok then
                cleaned[name] = coerced
            else
                fields = fields or {}
                fields[name] = reason
            end
        end
    end

    if fields then return nil, fields end

    return cleaned, nil
end

FredPD.Core.validate = Validate
