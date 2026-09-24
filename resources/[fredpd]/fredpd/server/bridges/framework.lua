--- Framework bridge: ESX (es_extended).
---
--- Spec 3.8. Bridges are the only place that names another resource, so when
--- the server swaps framework this file is the diff and nothing else moves.
---
--- What the bridge is allowed to supply: identity and context -- who this
--- player's character is, what job they hold, whether they are on duty.
---
--- What it must never supply: permissions. ESX job grades grant nothing in
--- FredPD (invariant 2). Jobs and duty are only *context conditions* layered on
--- top of a permission that a Discord role already granted (spec 4.3).

FredPD.Bridge = FredPD.Bridge or {}

local Framework = {}

local ESX

--- Resolves the ESX shared object once the resource is up.
local function core()
    if ESX then return ESX end
    if GetResourceState('es_extended') ~= 'started' then return nil end

    ESX = exports['es_extended']:getSharedObject()
    return ESX
end

--- The character behind a server id.
---
--- `identifier` is the ESX character identifier (`char1:license:…` on a
--- multi-character server, the bare licence otherwise). It is the key FredPD
--- binds a roster entry to (spec 4.1).
---
--- @param src number server id
--- @return table|nil character
function Framework.getCharacter(src)
    local esx = core()
    if not esx then return nil end

    local player = esx.GetPlayerFromId(src)
    if not player then return nil end

    return {
        identifier = player.identifier,
        firstName = player.get('firstName') or '',
        lastName = player.get('lastName') or '',
        job = player.getJob().name,
        grade = player.getJob().grade,
        -- ESX has no duty concept of its own; servers model it as a job or a
        -- metadata flag. Treated as context only, never as a grant.
        onDuty = player.get('onDuty') == true,
    }
end

--- What the character's own ID card says: name, date of birth and sex, as
--- the framework stores them. Raw -- `FredPD.Modules.field.personFields`
--- decides what is usable -- and read only for a player the officer is
--- standing next to (`field.person.resolve`).
---
--- ESX keeps these as player variables its identity resource sets
--- (`dateofbirth`, `sex`); a fork that names them differently reads as nil,
--- which registers the person with a name only.
---
--- @param src number server id
--- @return table|nil { identifier, firstName, lastName, dateOfBirth, sex }
function Framework.getIdentity(src)
    local esx = core()
    if not esx then return nil end

    local player = esx.GetPlayerFromId(src)
    if not player then return nil end

    return {
        identifier = player.identifier,
        firstName = player.get('firstName'),
        lastName = player.get('lastName'),
        dateOfBirth = player.get('dateofbirth'),
        sex = player.get('sex'),
    }
end

--- Sets duty state, when the server models it (spec 7.1, configurable).
--- Returns false when the server has no duty concept, so the caller can tell
--- "refused" apart from "not applicable".
--- @param src number
--- @param onDuty boolean
--- @return boolean handled
function Framework.setDuty(src, onDuty)
    local esx = core()
    if not esx then return false end

    local player = esx.GetPlayerFromId(src)
    if not player then return false end

    player.set('onDuty', onDuty)
    return true
end

--- The Discord identifier for a player, read on the server and never accepted
--- from a client (invariant 1, spec 4.1).
--- @param src number
--- @return string|nil discordId without the `discord:` prefix
function Framework.getDiscordId(src)
    local identifier = GetPlayerIdentifierByType(src, 'discord')
    if not identifier then return nil end

    return (identifier:gsub('^discord:', ''))
end

-- -----------------------------------------------------------------------------
-- Reading ESX's own tables directly
-- -----------------------------------------------------------------------------
--
-- Everything above calls only ESX's exported API -- `esx.GetPlayerFromId`, a
-- player's own `.get`/`.getJob()` -- because a resource's schema is a property
-- of which fork a server runs and not of FredPD (the same reason
-- `appearance.gloves`, config/server.lua, ships empty rather than guessed).
-- That holds for the *currently connected* player. It has no answer for "does
-- this citizen already exist" or "what vehicles does ESX already know about",
-- because ESX exports nothing for an offline character or the vehicle table
-- as a whole -- there is no API call these two functions could make instead.
--
-- So they read the tables directly, and the column names are
-- `config.server.esxData`'s to say, not this file's: the defaults match
-- es_extended / ESX Legacy, which is what `framework.lua` already assumes
-- everywhere else, and a fork that renamed a column changes the setting
-- rather than this code. `esxData.enabled = false` turns both functions into
-- an empty result, never an error -- a server whose columns do not match yet
-- should see no suggestions, not a broken query.
--
-- Invariant 8 still holds: every *value* a term can influence travels as a
-- `?` placeholder, exactly as everywhere else. What is interpolated with
-- `%s` below is table and column *names*, which SQL has no placeholder for
-- at all -- and which come only from `config/server.lua`, a file the
-- operator edits, never from a client or from the searched term.

local function esxData()
    return FredPD.Config.server.esxData or {}
end

--- Citizens matching a name fragment, read straight from ESX's character
--- table -- online or not, which `Framework.getCharacter` cannot answer since
--- it only knows the currently connected player.
---
--- Prefilling a new person record from this is what "citizens fetched from
--- the character database" means in practice: the officer picks the real
--- character instead of retyping a name FredPD has no way to check against
--- anything.
---
--- @param term string already trimmed and at least two characters
--- @param limit number
--- @return table rows: { identifier, firstName, lastName, dateOfBirth, phone }
function Framework.searchCharacters(term, limit)
    local config = esxData().characters
    if not config or esxData().enabled == false then return {} end

    local likeTerm = '%' .. term .. '%'

    local ok, rows = pcall(function()
        return FredPD.Core.db.query(
            ([[SELECT `%s` AS identifier, `%s` AS firstName, `%s` AS lastName,
                      `%s` AS dateOfBirth, `%s` AS phone
                 FROM `%s`
                WHERE `%s` LIKE ? OR `%s` LIKE ? OR `%s` LIKE ?
                ORDER BY `%s`, `%s`
                LIMIT ?]]):format(
                config.identifier, config.firstName, config.lastName,
                config.dateOfBirth, config.phone, config.table,
                config.firstName, config.lastName, config.identifier,
                config.lastName, config.firstName
            ),
            { likeTerm, likeTerm, likeTerm, limit or 8 }
        )
    end)

    if not ok then
        print(('[fredpd] esxData.characters: query failed against `%s` -- check the column names '
            .. 'in config/server.lua match your framework fork. (%s)')
            :format(config.table, tostring(rows)))
        return {}
    end

    return rows
end

--- Vehicles matching a plate or owner fragment, read straight from ESX's
--- vehicle-ownership table.
---
--- `model` comes back exactly as that table stores it -- a hash number on
--- most modern ESX forks, since a vehicle's properties are stored as ESX
--- itself serialised them, not as the human-readable spawn name `fpd_fleet`
--- and `vehicle.register` use. That is not resolved here: turning a model
--- hash back into a display name needs a hash-to-name table this server's
--- own vehicle pool defines, which is exactly the kind of guess
--- `appearance.gloves` explains why FredPD does not make. The plate and the
--- owner are read plainly either way, which is most of what a registration
--- prefill needs.
---
--- @param term string already trimmed and at least two characters
--- @param limit number
--- @return table rows: { plate, owner, model }
function Framework.searchOwnedVehicles(term, limit)
    local config = esxData().vehicles
    if not config or esxData().enabled == false then return {} end

    local likeTerm = '%' .. term .. '%'
    local modelExpr = config.vehicleJson
        and ('JSON_UNQUOTE(JSON_EXTRACT(`%s`, \'$.model\'))'):format(config.vehicleColumn)
        or ('`%s`'):format(config.vehicleColumn)

    local ok, rows = pcall(function()
        return FredPD.Core.db.query(
            ([[SELECT `%s` AS plate, `%s` AS owner, %s AS model
                 FROM `%s`
                WHERE `%s` LIKE ? OR `%s` LIKE ?
                ORDER BY `%s`
                LIMIT ?]]):format(
                config.plate, config.owner, modelExpr, config.table,
                config.plate, config.owner, config.plate
            ),
            { likeTerm, likeTerm, limit or 8 }
        )
    end)

    if not ok then
        print(('[fredpd] esxData.vehicles: query failed against `%s` -- check the column names '
            .. 'in config/server.lua match your framework fork. (%s)')
            :format(config.table, tostring(rows)))
        return {}
    end

    return rows
end

--- Startup check (spec 3.8): fail loudly and early, not on first use.
--- The owner of one plate, read from ESX's vehicle-ownership table, for a
--- plate FredPD's own register has never seen (`field.vehicle.resolve`).
---
--- Matched by equality on the plate column (its primary key on ESX, so an
--- index seek, never a scan): the plate exactly as the game draws it, trimmed,
--- and as FredPD stores it. ESX forks store one of those three.
---
--- @param drawn string the plate as `GetVehicleNumberPlateText` returned it
--- @param plate string the same plate normalised (upper-case, no spaces)
--- @return table|nil { plate, owner }
function Framework.ownedVehicleByPlate(drawn, plate)
    local config = esxData().vehicles
    if not config or esxData().enabled == false then return nil end

    local raw = tostring(drawn or plate)
    local trimmed = raw:match('^%s*(.-)%s*$')

    local ok, row = pcall(function()
        return FredPD.Core.db.single(
            ([[SELECT `%s` AS plate, `%s` AS owner
                 FROM `%s`
                WHERE `%s` IN (?, ?, ?)
                LIMIT 1]]):format(config.plate, config.owner, config.table, config.plate),
            { raw, trimmed, plate }
        )
    end)

    if not ok then
        print(('[fredpd] esxData.vehicles: plate lookup failed against `%s` -- check the column names in config/server.lua. (%s)')
            :format(config.table, tostring(row)))
        return nil
    end

    return row
end

--- The one owned vehicle a plate on the street belongs to, exactly (spec
--- 7.15, ADR-016), for the impound tow.
---
--- Stricter than `ownedVehicleByPlate`, because what follows is a write:
--- matched on the plate as drawn and trimmed only -- never the normalised
--- form, which would let "AB 123" reach somebody else's "AB123" -- and nil
--- when that is not exactly one row. The model comes back too, so the caller
--- can check the car it is looking at is the car that plate was issued to:
--- a plate on the street is whatever the car's owning client set it to.
---
--- @param drawn string the plate as `GetVehicleNumberPlateText` returned it
--- @return table|nil { plate (as stored), owner, model }
function Framework.ownedVehicleExact(drawn)
    local config = esxData().vehicles
    if not config or esxData().enabled == false or type(drawn) ~= 'string' then return nil end

    local trimmed = drawn:match('^%s*(.-)%s*$')
    if trimmed == '' then return nil end

    local modelExpr = config.vehicleJson
        and ('JSON_UNQUOTE(JSON_EXTRACT(`%s`, \'$.model\'))'):format(config.vehicleColumn)
        or ('`%s`'):format(config.vehicleColumn)

    local ok, rows = pcall(function()
        return FredPD.Core.db.query(
            ([[SELECT `%s` AS plate, `%s` AS owner, %s AS model
                 FROM `%s` WHERE `%s` IN (?, ?) AND BINARY `%s` IN (?, ?) LIMIT 2]]):format(
                config.plate, config.owner, modelExpr, config.table, config.plate, config.plate),
            -- The plain IN finds the row by the primary key; BINARY then drops
            -- what the default collation matched case- or space-insensitively.
            { drawn, trimmed, drawn, trimmed })
    end)

    if not ok or type(rows) ~= 'table' or #rows ~= 1 then return nil end

    return rows[1]
end

--- Sets whether an owned vehicle is in its owner's garage, on the one row
--- `ownedVehicleExact` named, and only from the state `guard` allows --
--- `{ is = v }` or `{ isnt = v }` -- so a car somebody already took out, or
--- put back, is left as it is.
---
--- The one write FredPD makes into ESX's own tables (ADR-016). Column and
--- values are config; nil `stored` turns it off.
---
--- @return boolean true when the row changed
function Framework.setVehicleStored(plate, value, guard)
    local config = esxData().vehicles
    if not config or esxData().enabled == false or not config.stored or value == nil or not plate then
        return false
    end

    local query = ('UPDATE `%s` SET `%s` = ? WHERE `%s` = ? AND BINARY `%s` = ?')
        :format(config.table, config.stored, config.plate, config.plate)
    local values = { value, plate, plate }

    if guard and guard.is ~= nil then
        query = query .. (' AND `%s` = ?'):format(config.stored)
        values[#values + 1] = guard.is
    elseif guard and guard.isnt ~= nil then
        query = query .. (' AND `%s` <> ?'):format(config.stored)
        values[#values + 1] = guard.isnt
    end

    local ok, affected = pcall(function() return FredPD.Core.db.execute(query, values) end)

    if not ok then
        print(('[fredpd] esxData.vehicles: could not set `%s` for %s (%s)')
            :format(config.stored, plate, tostring(affected)))
        return false
    end

    return (affected or 0) > 0
end

--- The server id of the character with this identifier, if they are on.
--- @return number|nil
function Framework.sourceOf(identifier)
    local esx = core()
    if not esx or type(identifier) ~= 'string' then return nil end

    local player = esx.GetPlayerFromIdentifier(identifier)
    return player and player.source or nil
end

--- Calls `handler(src, identifier)` whenever a character finishes loading.
--- ESX's own event, named here and nowhere else.
function Framework.onCharacterLoaded(handler)
    AddEventHandler('esx:playerLoaded', function(src, player)
        local identifier = type(player) == 'table' and player.identifier or nil
        if type(src) == 'number' and identifier then handler(src, identifier) end
    end)
end

--- Every table and column name `esxData` interpolates, checked once at
--- startup rather than halfway through a write.
local function verifyIdentifiers()
    local data = esxData()

    for _, section in ipairs({ data.characters, data.vehicles }) do
        if type(section) == 'table' then
            for key, value in pairs(section) do
                if type(value) == 'string' and not value:match('^[%w_]+$') then
                    error(('[fredpd] esxData.%s = %q is not a plain table or column name'):format(key, value))
                end
            end
        end
    end
end

function Framework.verify()
    verifyIdentifiers()

    if GetResourceState('es_extended') ~= 'started' then
        error('[fredpd] framework bridge: es_extended is not started.')
    end

    if not core() then
        error('[fredpd] framework bridge: es_extended is started but did not return a shared object.')
    end
end

FredPD.Bridge.framework = Framework
