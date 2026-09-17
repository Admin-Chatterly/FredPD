--- Motor pool SQL (spec 7.31). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- The fleet a draw menu works from: enabled entries only.
---
--- The gating columns are selected here as well as in `fleetAll`. They are not
--- decoration on the editor screen: `garage.fleet` and `garage.draw` evaluate
--- them on every call, and a column that never leaves the database is a rule
--- that is configured and never enforced.
function Repo.fleetFor(agencyId)
    local rows = FredPD.Core.db.query(
        [[SELECT id, model, label_key AS labelKey, permission, certification, livery, enabled,
                 required_group AS requiredGroup, required_discord_role AS requiredDiscordRole
            FROM fpd_fleet
           WHERE agency_id = ? AND enabled = 1
           ORDER BY sort_order, model]],
        { agencyId }
    )

    for index = 1, #rows do
        rows[index].enabled = rows[index].enabled == 1 or rows[index].enabled == true
    end

    return rows
end

--- Records a draw or a return.
---
--- A vehicle out for a whole shift is visible to command, which is the reason
--- this log exists at all (spec 7.31).
function Repo.log(action, session, model, plate, placementId)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_motorpool_log (action, agency_id, discord_id, model, plate, placement_id)
          VALUES (?, ?, ?, ?, ?, ?)]],
        { action, session.agencyId, session.discordId, model, plate, placementId }
    )
end

--- The most recent motor pool event for a plate, whether a draw or a return.
---
--- The caller needs both: a plate whose latest event is a `return` has already
--- been handed back, and must not be returnable again. Filtering to draws here
--- would hide that and let one plate be returned repeatedly -- each call writing
--- another log row and releasing the vehicle from the society again.
function Repo.latestEvent(agencyId, plate)
    return FredPD.Core.db.single(
        [[SELECT id, action, model, discord_id AS discordId, occurred_at AS occurredAt
            FROM fpd_motorpool_log
           WHERE agency_id = ? AND plate = ?
           ORDER BY id DESC
           LIMIT 1]],
        { agencyId, plate }
    )
end

-- -----------------------------------------------------------------------------
-- The fleet editor (spec 7.31, migration 0003)
-- -----------------------------------------------------------------------------

--- Every column the editor reads back. `fleetFor` above selects all of these but
--- `sort_order`, which the draw menu has no use for -- it consumes the order,
--- not the number behind it -- and it never sees a disabled row at all.
local FLEET_COLUMNS <const> = [[
    id, model, label_key AS labelKey, permission, certification, livery,
    sort_order AS sortOrder, enabled,
    required_group AS requiredGroup, required_discord_role AS requiredDiscordRole
]]

--- oxmysql hands back TINYINT(1) as a number on some drivers and a boolean on
--- others; the NUI checkbox needs one answer.
local function normalize(rows)
    for index = 1, #rows do
        rows[index].enabled = rows[index].enabled == 1 or rows[index].enabled == true
    end

    return rows
end

--- The whole fleet for an agency, disabled entries included.
---
--- That is the difference from `fleetFor`: the editor has to show what is
--- switched off, because "switched off" is a state an administrator sets and
--- has to be able to find again. A row missing from the editor looks deleted.
function Repo.fleetAll(agencyId)
    return normalize(FredPD.Core.db.query(
        ([[SELECT %s FROM fpd_fleet
            WHERE agency_id = ?
            ORDER BY sort_order, model]]):format(FLEET_COLUMNS),
        { agencyId }
    ))
end

--- One entry, scoped to the agency.
---
--- Every editor route looks a row up this way before touching it, so an id from
--- another agency's motor pool reads as "not found" rather than as somebody
--- else's vehicle (invariant 4). The agency comes from the session, never from
--- input (invariant 1).
function Repo.fleetEntry(agencyId, id)
    return FredPD.Core.db.single(
        ([[SELECT %s FROM fpd_fleet WHERE agency_id = ? AND id = ?]]):format(FLEET_COLUMNS),
        { agencyId, id }
    )
end

--- The entry holding a spawn name, for the unique `(agency_id, model)` check.
function Repo.fleetEntryByModel(agencyId, model)
    return FredPD.Core.db.single(
        ([[SELECT %s FROM fpd_fleet WHERE agency_id = ? AND model = ?]]):format(FLEET_COLUMNS),
        { agencyId, model }
    )
end

--- Adds a fleet entry.
---
--- `NULLIF(?, '')` is how a nullable column is written as NULL: a `nil` in an
--- oxmysql values list silently shortens the list and shifts every placeholder
--- after it, so an empty string travels instead and MariaDB stores NULL.
--- `livery` is an integer, so `-1` is the same sentinel in its own type.
function Repo.addFleet(agencyId, entry)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_fleet
              (agency_id, model, label_key, permission, certification, livery,
               sort_order, enabled, required_group, required_discord_role)
          VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, -1), ?, ?,
                  NULLIF(?, ''), NULLIF(?, ''))]],
        {
            agencyId,
            entry.model,
            entry.labelKey,
            entry.permission or '',
            entry.certification or '',
            entry.livery or -1,
            entry.sortOrder or 0,
            entry.enabled == false and 0 or 1,
            entry.requiredGroup or '',
            entry.requiredDiscordRole or '',
        }
    )
end

--- The only columns an update may write, each with the expression it is written
--- with.
---
--- The column name comes from this table and never from input (invariant 8):
--- input decides *whether* a column is written, never *which*. Anything the
--- editor sends that is not listed here is ignored, the same way the schema
--- drops a key the route never declared.
local FLEET_WRITABLE <const> = {
    { field = 'model', sql = '`model` = ?' },
    { field = 'labelKey', sql = '`label_key` = ?' },
    { field = 'permission', sql = [[`permission` = NULLIF(?, '')]] },
    { field = 'certification', sql = [[`certification` = NULLIF(?, '')]] },
    { field = 'livery', sql = '`livery` = NULLIF(?, -1)' },
    { field = 'sortOrder', sql = '`sort_order` = ?' },
    { field = 'enabled', sql = '`enabled` = ?' },
    { field = 'requiredGroup', sql = [[`required_group` = NULLIF(?, '')]] },
    { field = 'requiredDiscordRole', sql = [[`required_discord_role` = NULLIF(?, '')]] },
}

--- Updates only the fields present.
---
--- @return number|nil rows affected, or nil when the request named no column at
---   all. The two are worth telling apart: zero rows is "nothing changed",
---   which a no-op UPDATE also returns, while nil is a request with nothing in
---   it -- a form the editor should never have submitted.
function Repo.updateFleet(agencyId, id, entry)
    local sets, values = {}, {}

    for index = 1, #FLEET_WRITABLE do
        local column = FLEET_WRITABLE[index]
        local value = entry[column.field]

        if value ~= nil then
            if type(value) == 'boolean' then value = value and 1 or 0 end

            sets[#sets + 1] = column.sql
            values[#values + 1] = value
        end
    end

    if #sets == 0 then return nil end

    values[#values + 1] = agencyId
    values[#values + 1] = id

    return FredPD.Core.db.execute(
        ('UPDATE fpd_fleet SET %s WHERE agency_id = ? AND id = ?'):format(table.concat(sets, ', ')),
        values
    )
end

--- Removes a fleet entry.
---
--- Nothing cascades from here: `fpd_motorpool_log` has no foreign key onto the
--- fleet, deliberately, so deleting a vehicle from the list never erases the
--- record of who drew one (spec 7.31).
function Repo.removeFleet(agencyId, id)
    return FredPD.Core.db.execute(
        'DELETE FROM fpd_fleet WHERE agency_id = ? AND id = ?',
        { agencyId, id }
    )
end

FredPD.Repo.garage = Repo
