--- Vehicle and firearm registry SQL (spec 7.4, 7.5). Parameterized only
--- (invariant 8).
---
--- Four rules shape every statement below.
---
--- **Nothing here decides who may read a row.** Every read returns the row with
--- its access-control columns (`id`, `agency_id`, `classification`) selected,
--- and `routes.lua` hands it to the access module before it reaches a client
--- (invariant 4). A function in this file that filtered by classification
--- itself would be a second, quieter copy of the access model, and the first
--- time the two disagreed the quieter one would win.
---
--- **No column name is ever taken from input.** Updates build their SET list
--- from a fixed allowlist in this file; a field the allowlist does not name
--- cannot be written, whatever the client sends. The only things ever
--- concatenated into a statement are `?` placeholders and text read out of that
--- allowlist -- never a value.
---
--- **No nil ever reaches a values list.** A nil appended to a Lua list appends
--- nothing, so the next value takes its slot and every placeholder after it
--- reads the wrong parameter. Optional columns travel as `''` or `0` and
--- `NULLIF` turns them back into NULL in the database.
---
--- **The VIN is generated here and written once** (7.4, invariant 1). There is
--- no statement in this file that sets `vin` on an existing row, and no
--- function that accepts one. `uq_fpd_vehicles_vin` is the backstop; the
--- re-draw loop below is what stops the backstop ever being needed.
---
--- **A history row and the row it describes are written together.** A plate
--- change that moved the vehicle but did not close the old plate's period, or a
--- transfer that moved a firearm without an event, is a register that cannot
--- answer the question it exists to answer. Both go through `db.transaction`,
--- and the statements that follow the versioned write are conditioned so they
--- land only if it did -- `db.transaction` reports whether it committed, never
--- how many rows each statement touched, so the condition is the control and a
--- verification read afterwards is what the caller is told.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local function service()
    return FredPD.Modules.registry
end

--- `?, ?, ?` for a list of n values. Placeholders only: no value is ever
--- concatenated into a statement (invariant 8).
local function placeholders(count)
    local marks = {}
    for index = 1, count do marks[index] = '?' end

    return table.concat(marks, ',')
end

-- =============================================================================
-- Vehicles (7.4)
-- =============================================================================

--- `agency_id` is selected on every row because the access module reads it
--- (4.5, cross-agency sharing), and `classification` because it is the level
--- the read rule compares against.
---
--- The owner is returned as an id, never as a joined name. A person's file has
--- its own classification and its own compartments, and a name reached through
--- a vehicle record would arrive having passed none of them -- which is exactly
--- the shape of leak invariant 4 is written about. The NUI asks `person.get`
--- for the name and is refused there if it must be.
local VEHICLE_COLUMNS <const> = [[
    v.id, v.agency_id AS agencyId, v.plate, v.vin, v.model,
    v.colour, v.colour_secondary AS colourSecondary,
    v.owner_person_id AS ownerPersonId, v.owner_identifier AS ownerIdentifier,
    v.registration_status AS registrationStatus, v.registration_expires AS registrationExpires,
    v.insurance_status AS insuranceStatus, v.insurance_expires AS insuranceExpires,
    v.classification, v.version,
    v.created_by AS createdBy, v.created_at AS createdAt,
    v.updated_by AS updatedBy, v.updated_at AS updatedAt
]]

--- Fields an officer may change on a vehicle, and the column each one writes.
---
--- A fixed allowlist, in code. `plate` is absent because a plate change is a
--- history event and goes through `changePlate`; `vin` is absent because a VIN
--- is written once at registration and never again (7.4); `agency_id`,
--- `version` and the audit columns are absent because they are the server's.
---
--- A list rather than a map, so the order is the list's and the same edit
--- always produces the same statement. `blank` is the value that means "clear
--- this column"; see `setClause` for why it is not simply nil.
local VEHICLE_UPDATABLE <const> = {
    { field = 'model', column = 'model', blank = '' },
    { field = 'colour', column = 'colour', blank = '' },
    { field = 'colourSecondary', column = 'colour_secondary', blank = '' },
    { field = 'ownerPersonId', column = 'owner_person_id', blank = 0 },
    { field = 'ownerIdentifier', column = 'owner_identifier', blank = '' },
    { field = 'registrationStatus', column = 'registration_status', blank = '' },
    { field = 'registrationExpires', column = 'registration_expires', blank = '' },
    { field = 'insuranceStatus', column = 'insurance_status', blank = '' },
    { field = 'insuranceExpires', column = 'insurance_expires', blank = '' },
    { field = 'classification', column = 'classification', blank = '' },
}

--- Builds a SET clause from an allowlist. Returns nil when nothing was named.
---
--- Shared by both registers because getting it wrong in either is the same
--- mistake: a column name that came from a client. Both the column name and the
--- blank sentinel are read out of the allowlist above, which is code; the value
--- is the only thing from the officer and it is always a parameter (invariant 8).
---
--- **No nil ever reaches the values list.** An empty field means "clear this
--- column", and the obvious way to write that -- appending nil -- does not work
--- in Lua: `values[#values + 1] = nil` appends nothing, so the next value lands
--- in the slot the nil was meant to fill and every placeholder after it reads
--- the wrong parameter. The sentinel travels instead and `NULLIF` turns it back
--- into NULL in the database, where the comparison is the server's own.
---
--- @param allowed table list of { field, column, blank }
--- @param input table
--- @return string|nil clause, table values
local function setClause(allowed, input)
    local sets, values = {}, {}

    for index = 1, #allowed do
        local entry = allowed[index]
        local value = input[entry.field]

        if value ~= nil then
            sets[#sets + 1] = ('`%s` = NULLIF(?, %s)')
                :format(entry.column, entry.blank == 0 and '0' or "''")
            values[#values + 1] = value
        end
    end

    if #sets == 0 then return nil, values end

    return table.concat(sets, ', '), values
end

--- One vehicle, by id, plate or VIN. Agency-scoped from the session.
---
--- The row is returned as it stands: the caller runs it past the access module
--- before anybody sees it.
---
--- @param agencyId string from the session, never from input (invariant 1)
--- @param selector table { id } | { plate } | { vin }
--- @return table|nil
function Repo.findVehicle(agencyId, selector)
    if selector.id then
        return db().single(
            ([[SELECT %s FROM fpd_vehicles v WHERE v.agency_id = ? AND v.id = ?]])
                :format(VEHICLE_COLUMNS),
            { agencyId, selector.id }
        )
    end

    if selector.plate then
        return db().single(
            ([[SELECT %s FROM fpd_vehicles v WHERE v.agency_id = ? AND v.plate = ?]])
                :format(VEHICLE_COLUMNS),
            { agencyId, selector.plate }
        )
    end

    if selector.vin then
        return db().single(
            ([[SELECT %s FROM fpd_vehicles v WHERE v.agency_id = ? AND v.vin = ?]])
                :format(VEHICLE_COLUMNS),
            { agencyId, selector.vin }
        )
    end

    return nil
end

--- Vehicles matching a term, before access filtering.
---
--- The term is a plate fragment or a whole VIN. `%term%` rather than a
--- leading-anchored prefix: `uq_fpd_vehicles_plate` can serve
--- `plate LIKE 'term%'` as an index seek and cannot serve a leading
--- wildcard, so this trades that seek for a full scan on every plate search --
--- deliberately, because an officer who only remembers a few characters from
--- the middle of a plate is common enough that "no results" for a real plate
--- is worse than a slower query. `fpd_vehicles` is small enough per agency
--- that the scan still sits inside the 150 ms budget of section 12.
---
--- @param filter table { term, ownerPersonId, ownerIdentifier, limit }
--- @return table rows
function Repo.searchVehicles(agencyId, filter)
    local where = { 'v.agency_id = ?' }
    local values = { agencyId }

    if filter.term then
        where[#where + 1] = '(v.plate LIKE ? OR v.vin = ?)'
        values[#values + 1] = '%' .. filter.term .. '%'
        values[#values + 1] = filter.term
    end

    if filter.ownerPersonId then
        where[#where + 1] = 'v.owner_person_id = ?'
        values[#values + 1] = filter.ownerPersonId
    end

    if filter.ownerIdentifier then
        where[#where + 1] = 'v.owner_identifier = ?'
        values[#values + 1] = filter.ownerIdentifier
    end

    values[#values + 1] = filter.limit or 75

    return db().query(
        ([[SELECT %s FROM fpd_vehicles v
            WHERE %s
            ORDER BY v.plate
            LIMIT ?]]):format(VEHICLE_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

--- A VIN nothing in this agency is using yet (7.4, invariant 1).
---
--- Drawn, not derived: a VIN computed from the plate or the owner would make
--- the identity of a vehicle guessable from public facts, which is the opposite
--- of what a vehicle identification number is for.
---
--- The loop re-draws on a collision. With 33 characters over 16 free positions
--- a collision is not going to happen; the loop is here because "is not going to
--- happen" is not a constraint, and because the failure it prevents -- a unique
--- key violation surfacing to an officer as an internal error while registering
--- a car -- is ugly out of all proportion to five lines of code.
---
--- @return string|nil vin, nil when eight draws all collided
function Repo.generateVin(agencyId)
    for _ = 1, 8 do
        local vin = service().generateVin()

        local taken = db().scalar(
            'SELECT id FROM fpd_vehicles WHERE agency_id = ? AND vin = ? LIMIT 1',
            { agencyId, vin }
        )

        if not taken then return vin end
    end

    return nil
end

--- Registers a vehicle and opens its plate history.
---
--- One transaction, because the two are one fact: a vehicle whose current plate
--- has no open period in `fpd_vehicle_plates` has a history that starts
--- nowhere, and the plate history is what answers "what was this car wearing in
--- March?" -- the question the table exists for.
---
--- The history row finds the vehicle by its VIN rather than by
--- `LAST_INSERT_ID()`: the VIN is unique, it was generated here, and the link
--- is then explicit and survives anybody reordering these statements later.
--- (The same reasoning as the evidence module's `ref`.)
---
--- @return table|nil row, string|nil reason
function Repo.registerVehicle(agencyId, input, discordId)
    local existing = db().scalar(
        'SELECT id FROM fpd_vehicles WHERE agency_id = ? AND plate = ? LIMIT 1',
        { agencyId, input.plate }
    )

    if existing then return nil, 'plate_taken' end

    local vin = Repo.generateVin(agencyId)
    if not vin then return nil, 'vin_exhausted' end

    local committed = db().transaction({
        {
            -- Every optional column travels as a sentinel and is turned back
            -- into NULL by `NULLIF`. A nil in an oxmysql values list appends
            -- nothing, so the next value would land in its slot and shift every
            -- placeholder after it -- here, an owner id into a registration
            -- status. Nothing below may be nil.
            query = [[INSERT INTO fpd_vehicles
                          (agency_id, plate, vin, model, colour, colour_secondary,
                           owner_person_id, owner_identifier,
                           registration_status, registration_expires,
                           insurance_status, insurance_expires,
                           classification, created_by, updated_by)
                      VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''),
                              NULLIF(?, 0), NULLIF(?, ''),
                              ?, NULLIF(?, ''),
                              ?, NULLIF(?, ''),
                              ?, ?, ?)]],
            values = {
                agencyId, input.plate, vin,
                input.model or '', input.colour or '', input.colourSecondary or '',
                input.ownerPersonId or 0, input.ownerIdentifier or '',
                input.registrationStatus or 'valid', input.registrationExpires or '',
                input.insuranceStatus or 'none', input.insuranceExpires or '',
                input.classification or 'internal', discordId, discordId,
            },
        },
        {
            query = [[INSERT INTO fpd_vehicle_plates
                          (agency_id, vehicle_id, plate, held_from, reason, created_by)
                      SELECT v.agency_id, v.id, v.plate, NOW(3), NULLIF(?, ''), ?
                        FROM fpd_vehicles v
                       WHERE v.agency_id = ? AND v.vin = ?]],
            values = { input.reason or '', discordId, agencyId, vin },
        },
    })

    if not committed then return nil, 'write_failed' end

    return Repo.findVehicle(agencyId, { vin = vin })
end

--- Updates the fields named, checks the version, bumps it.
---
--- The version is in the WHERE clause, so a stale edit touches no rows and the
--- route reports a conflict rather than silently overwriting somebody's work
--- (spec 3.5).
---
--- @return number affected
function Repo.updateVehicle(agencyId, id, expectedVersion, input, discordId)
    local clause, values = setClause(VEHICLE_UPDATABLE, input)
    if not clause then return 0 end

    values[#values + 1] = discordId
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ([[UPDATE fpd_vehicles
              SET %s, `updated_by` = ?, `version` = `version` + 1
            WHERE agency_id = ? AND id = ? AND version = ?]]):format(clause),
        values
    )
end

--- Changes a vehicle's plate and records the change (7.4, plate history).
---
--- Three statements, one transaction, each conditioned so that none of them can
--- land without the others:
---
---   1. close the open period, only while the vehicle still carries the version
---      the officer edited;
---   2. move the plate, on the same version condition -- this is the optimistic
---      lock, and `updated_at` moves with it;
---   3. open a new period, only if the vehicle now carries the new plate *and*
---      no open period exists. The second half of that condition is what makes
---      a lost race harmless: the officer whose update did not land finds the
---      winner's period already open and writes nothing.
---
--- `db.transaction` answers only whether it committed, so the verification read
--- afterwards is what the caller is told -- and it distinguishes a vehicle that
--- is gone from one somebody else edited first.
---
--- @return boolean changed, string|nil reason
function Repo.changePlate(agencyId, vehicleId, expectedVersion, plate, reason, discordId)
    local holder = db().single(
        'SELECT id FROM fpd_vehicles WHERE agency_id = ? AND plate = ? LIMIT 1',
        { agencyId, plate }
    )

    if holder and holder.id ~= vehicleId then return false, 'plate_taken' end

    local committed = db().transaction({
        {
            query = [[UPDATE fpd_vehicle_plates p
                        JOIN fpd_vehicles v ON v.id = p.vehicle_id AND v.agency_id = p.agency_id
                         SET p.held_until = NOW(3)
                       WHERE p.vehicle_id = ? AND p.agency_id = ?
                         AND p.held_until IS NULL AND v.version = ?]],
            values = { vehicleId, agencyId, expectedVersion },
        },
        {
            query = [[UPDATE fpd_vehicles
                         SET plate = ?, updated_by = ?, version = version + 1
                       WHERE agency_id = ? AND id = ? AND version = ?]],
            values = { plate, discordId, agencyId, vehicleId, expectedVersion },
        },
        {
            query = [[INSERT INTO fpd_vehicle_plates
                          (agency_id, vehicle_id, plate, held_from, reason, created_by)
                      SELECT v.agency_id, v.id, v.plate, NOW(3), NULLIF(?, ''), ?
                        FROM fpd_vehicles v
                       WHERE v.agency_id = ? AND v.id = ? AND v.plate = ?
                         AND NOT EXISTS (SELECT 1 FROM fpd_vehicle_plates h
                                          WHERE h.vehicle_id = v.id AND h.held_until IS NULL)]],
            values = { reason or '', discordId, agencyId, vehicleId, plate },
        },
    })

    if not committed then return false, 'write_failed' end

    local row = db().single(
        'SELECT plate, version FROM fpd_vehicles WHERE agency_id = ? AND id = ?',
        { agencyId, vehicleId }
    )

    if not row then return false, 'not_found' end
    if row.plate ~= plate or row.version ~= expectedVersion + 1 then return false, 'conflict' end

    return true
end

--- Every plate this vehicle has worn, newest first.
---
--- The open period (`held_until IS NULL`) is the current plate, which is also
--- on the vehicle row; both are returned rather than one being derived from the
--- other, because the history is evidence and the vehicle row is a summary.
function Repo.plateHistory(agencyId, vehicleId)
    return db().query(
        [[SELECT id, plate, held_from AS heldFrom, held_until AS heldUntil,
                 reason, created_by AS createdBy, created_at AS createdAt
            FROM fpd_vehicle_plates
           WHERE agency_id = ? AND vehicle_id = ?
           ORDER BY COALESCE(held_from, created_at) DESC, id DESC]],
        { agencyId, vehicleId }
    )
end

--- Flags in force on a vehicle (7.4).
---
--- "In force" is a cleared-at of NULL and an expiry that has not passed. Both
--- are evaluated by the database rather than in Lua: the expiry is the point of
--- the column, and a server whose clock and whose database disagree should
--- believe the database.
---
--- Each row carries its own `classification`: a BOLO can be more sensitive than
--- the vehicle it is on, so the caller filters these through the access module
--- as well (4.5, "attachments ... can be stricter").
local FLAG_COLUMNS <const> = [[
    f.id, f.agency_id AS agencyId, f.vehicle_id AS vehicleId, f.kind, f.detail,
    f.case_number AS caseNumber, f.classification, f.expires_at AS expiresAt,
    f.created_by AS createdBy, f.created_at AS createdAt
]]

function Repo.liveFlags(agencyId, vehicleId)
    return db().query(
        ([[SELECT %s FROM fpd_vehicle_flags f
            WHERE f.agency_id = ? AND f.vehicle_id = ?
              AND f.cleared_at IS NULL AND (f.expires_at IS NULL OR f.expires_at > NOW(3))
            ORDER BY f.created_at DESC, f.id DESC]]):format(FLAG_COLUMNS),
        { agencyId, vehicleId }
    )
end

--- Every flag a vehicle has ever carried, cleared and expired ones included.
function Repo.flagHistory(agencyId, vehicleId)
    return db().query(
        ([[SELECT %s, f.cleared_at AS clearedAt, f.cleared_by AS clearedBy
             FROM fpd_vehicle_flags f
            WHERE f.agency_id = ? AND f.vehicle_id = ?
            ORDER BY f.created_at DESC, f.id DESC]]):format(FLAG_COLUMNS),
        { agencyId, vehicleId }
    )
end

--- Live flags for several vehicles at once, for the hot-file check on a search
--- result (7.2).
---
--- One query however many rows came back. The alternative is one query per row,
--- and the search budget in section 12 is 150 ms for the whole answer.
---
--- @param ids table vehicle ids the reader is already allowed to see
--- @return table vehicleId -> list of rows
function Repo.liveFlagsFor(agencyId, ids)
    local byVehicle = {}
    if type(ids) ~= 'table' or #ids == 0 then return byVehicle end

    local values = { agencyId }
    for index = 1, #ids do values[#values + 1] = ids[index] end

    local rows = db().query(
        ([[SELECT %s FROM fpd_vehicle_flags f
            WHERE f.agency_id = ? AND f.vehicle_id IN (%s)
              AND f.cleared_at IS NULL AND (f.expires_at IS NULL OR f.expires_at > NOW(3))
            ORDER BY f.created_at DESC, f.id DESC]])
            :format(FLAG_COLUMNS, placeholders(#ids)),
        values
    )

    for index = 1, #rows do
        local row = rows[index]
        local list = byVehicle[row.vehicleId] or {}

        list[#list + 1] = row
        byVehicle[row.vehicleId] = list
    end

    return byVehicle
end

--- Puts a flag on a vehicle (7.4): stolen, wanted, BOLO.
---
--- `expiresIn` is seconds from now and the database computes the moment, so no
--- client clock is involved in when a flag lapses (invariant 1). Zero means it
--- does not lapse, and travels as a zero rather than as nil: a nil in an
--- oxmysql values list shortens the list and shifts every placeholder after it.
---
--- @return number flag id
function Repo.addFlag(agencyId, vehicleId, input, discordId)
    local seconds = tonumber(input.expiresIn) or 0

    return db().insert(
        [[INSERT INTO fpd_vehicle_flags
              (agency_id, vehicle_id, kind, detail, case_number, classification,
               expires_at, created_by)
          VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?,
                  IF(? = 0, NULL, DATE_ADD(NOW(3), INTERVAL ? SECOND)), ?)]],
        {
            agencyId, vehicleId, input.kind, input.detail or '', input.caseNumber or '',
            input.classification or 'internal', seconds, seconds, discordId,
        }
    )
end

--- One flag, so the route can check access on the vehicle it hangs off before
--- touching it.
function Repo.flagById(agencyId, flagId)
    return db().single(
        ([[SELECT %s, f.cleared_at AS clearedAt FROM fpd_vehicle_flags f
            WHERE f.agency_id = ? AND f.id = ?]]):format(FLAG_COLUMNS),
        { agencyId, flagId }
    )
end

--- Clears a flag. The row stays and is stamped: a vehicle that was reported
--- stolen and later found is a thing a court asks about, and a DELETE would
--- leave nothing to answer with.
function Repo.clearFlag(agencyId, flagId, discordId)
    return db().execute(
        [[UPDATE fpd_vehicle_flags
             SET cleared_at = NOW(3), cleared_by = ?
           WHERE agency_id = ? AND id = ? AND cleared_at IS NULL]],
        { discordId, agencyId, flagId }
    )
end

-- =============================================================================
-- Firearms (7.5)
-- =============================================================================

--- `assigned_officer` is a Discord id (an agency-issued weapon, 7.5), and it is
--- returned as the id rather than as a name for the same reason a vehicle's
--- owner is: a personnel record has its own access control.
local FIREARM_COLUMNS <const> = [[
    f.id, f.agency_id AS agencyId, f.serial, f.make, f.model, f.type, f.calibre,
    f.status, f.owner_person_id AS ownerPersonId, f.owner_identifier AS ownerIdentifier,
    f.assigned_officer AS assignedOfficer, f.classification, f.version,
    f.created_by AS createdBy, f.created_at AS createdAt,
    f.updated_by AS updatedBy, f.updated_at AS updatedAt
]]

--- Fields an officer may change on a firearm, and the column each one writes.
---
--- `serial` is absent: the serial is the weapon's identity and changing it
--- would rewrite the ownership history's subject underneath it. A weapon whose
--- serial was wrong is registered again and the wrong record retired.
--- `status`, `owner_person_id` and `assigned_officer` are absent too -- each of
--- those is an event in the life of the firearm (7.5) and goes through the
--- function that writes the matching `fpd_firearm_events` row.
local FIREARM_UPDATABLE <const> = {
    { field = 'make', column = 'make', blank = '' },
    { field = 'model', column = 'model', blank = '' },
    { field = 'type', column = 'type', blank = '' },
    { field = 'calibre', column = 'calibre', blank = '' },
    { field = 'classification', column = 'classification', blank = '' },
}

--- One firearm, by id or serial. Agency-scoped from the session.
function Repo.findFirearm(agencyId, selector)
    if selector.id then
        return db().single(
            ([[SELECT %s FROM fpd_firearms f WHERE f.agency_id = ? AND f.id = ?]])
                :format(FIREARM_COLUMNS),
            { agencyId, selector.id }
        )
    end

    if selector.serial then
        return db().single(
            ([[SELECT %s FROM fpd_firearms f WHERE f.agency_id = ? AND f.serial = ?]])
                :format(FIREARM_COLUMNS),
            { agencyId, selector.serial }
        )
    end

    return nil
end

--- Firearms matching a term, before access filtering.
---
--- Serial fragment, for the same trade as the plate search above.
---
--- @param filter table { term, ownerPersonId, status, assignedOfficer, limit }
function Repo.searchFirearms(agencyId, filter)
    local where = { 'f.agency_id = ?' }
    local values = { agencyId }

    if filter.term then
        where[#where + 1] = 'f.serial LIKE ?'
        values[#values + 1] = '%' .. filter.term .. '%'
    end

    if filter.ownerPersonId then
        where[#where + 1] = 'f.owner_person_id = ?'
        values[#values + 1] = filter.ownerPersonId
    end

    if filter.ownerIdentifier then
        where[#where + 1] = 'f.owner_identifier = ?'
        values[#values + 1] = filter.ownerIdentifier
    end

    if filter.status then
        where[#where + 1] = 'f.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.assignedOfficer then
        where[#where + 1] = 'f.assigned_officer = ?'
        values[#values + 1] = filter.assignedOfficer
    end

    values[#values + 1] = filter.limit or 75

    return db().query(
        ([[SELECT %s FROM fpd_firearms f
            WHERE %s
            ORDER BY f.serial
            LIMIT ?]]):format(FIREARM_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

--- Registers a firearm and opens its ownership history (7.5).
---
--- One transaction: a firearm with no `register` event has an ownership history
--- that starts nowhere, and the history is what a trace reads (7.5, 8.9). The
--- event row finds the firearm by its serial, which is unique within the agency.
---
--- The serial comes from the officer, and that is not a breach of invariant 1:
--- it is stamped on a physical object and read off it, the way a VIN would be
--- if the vehicle had one before the registry did. Everything the *server*
--- authors -- who registered it, when, the event, the id -- is authored here.
---
--- @return table|nil row, string|nil reason
function Repo.registerFirearm(agencyId, input, discordId)
    local existing = db().scalar(
        'SELECT id FROM fpd_firearms WHERE agency_id = ? AND serial = ? LIMIT 1',
        { agencyId, input.serial }
    )

    if existing then return nil, 'serial_taken' end

    local status = input.status or 'registered'

    local committed = db().transaction({
        {
            -- Sentinels and `NULLIF` again, for the reason `registerVehicle`
            -- spells out: a nil here would shift every placeholder after it.
            query = [[INSERT INTO fpd_firearms
                          (agency_id, serial, make, model, type, calibre, status,
                           owner_person_id, owner_identifier, assigned_officer,
                           classification, created_by, updated_by)
                      VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''),
                              NULLIF(?, ''), ?,
                              NULLIF(?, 0), NULLIF(?, ''), NULLIF(?, ''),
                              ?, ?, ?)]],
            values = {
                agencyId, input.serial,
                input.make or '', input.model or '', input.type or '', input.calibre or '',
                status,
                input.ownerPersonId or 0, input.ownerIdentifier or '',
                input.assignedOfficer or '',
                input.classification or 'internal', discordId, discordId,
            },
        },
        {
            query = [[INSERT INTO fpd_firearm_events
                          (agency_id, firearm_id, event, to_person_id, to_party,
                           case_number, reason, recorded_by)
                      SELECT f.agency_id, f.id, ?, f.owner_person_id, NULLIF(?, ''),
                             NULLIF(?, ''), NULLIF(?, ''), ?
                        FROM fpd_firearms f
                       WHERE f.agency_id = ? AND f.serial = ?]],
            values = {
                status == 'agency_issued' and 'issued' or 'register',
                input.ownerParty or '', input.caseNumber or '', input.reason or '',
                discordId, agencyId, input.serial,
            },
        },
    })

    if not committed then return nil, 'write_failed' end

    return Repo.findFirearm(agencyId, { serial = input.serial })
end

function Repo.updateFirearm(agencyId, id, expectedVersion, input, discordId)
    local clause, values = setClause(FIREARM_UPDATABLE, input)
    if not clause then return 0 end

    values[#values + 1] = discordId
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ([[UPDATE fpd_firearms
              SET %s, `updated_by` = ?, `version` = `version` + 1
            WHERE agency_id = ? AND id = ? AND version = ?]]):format(clause),
        values
    )
end

--- Moves a firearm to a new keeper and records the transfer (7.5).
---
--- The event is written *before* the update, on the condition that the firearm
--- still carries the version the officer edited. That order is deliberate:
---
---   * the event's `from_person_id` is read from the row, so it has to be read
---     while the row still holds the old owner;
---   * the condition is the same one the update checks, so an officer working
---     from a stale version writes neither the event nor the change. With the
---     update first, the loser of a race would find the version already bumped
---     to the value its own event condition was looking for and would append a
---     second, phantom transfer to the history.
---
--- Both statements are in one transaction, so the row is locked for the whole
--- of it and no third party can move between them.
---
--- @return boolean transferred, string|nil reason
function Repo.transferFirearm(agencyId, id, expectedVersion, input, discordId)
    local committed = db().transaction({
        {
            query = [[INSERT INTO fpd_firearm_events
                          (agency_id, firearm_id, event, from_person_id, to_person_id,
                           from_party, to_party, case_number, reason, recorded_by)
                      SELECT f.agency_id, f.id, 'transfer', f.owner_person_id, NULLIF(?, 0),
                             NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?
                        FROM fpd_firearms f
                       WHERE f.agency_id = ? AND f.id = ? AND f.version = ?]],
            values = {
                input.toPersonId or 0,
                input.fromParty or '', input.toParty or '',
                input.caseNumber or '', input.reason or '', discordId,
                agencyId, id, expectedVersion,
            },
        },
        {
            query = [[UPDATE fpd_firearms
                         SET owner_person_id = NULLIF(?, 0), owner_identifier = NULLIF(?, ''),
                             assigned_officer = NULL, status = 'registered',
                             updated_by = ?, version = version + 1
                       WHERE agency_id = ? AND id = ? AND version = ?]],
            values = {
                input.toPersonId or 0, input.toIdentifier or '', discordId,
                agencyId, id, expectedVersion,
            },
        },
    })

    if not committed then return false, 'write_failed' end

    local row = db().single(
        'SELECT version FROM fpd_firearms WHERE agency_id = ? AND id = ?',
        { agencyId, id }
    )

    if not row then return false, 'not_found' end
    if row.version ~= expectedVersion + 1 then return false, 'conflict' end

    return true
end

--- Reports a firearm lost, stolen, seized, destroyed or recovered (7.5).
---
--- Same shape and same ordering as a transfer, and for the same reason: the
--- status is a field, but the report is an event, and a register that kept the
--- field without the event could say a weapon is stolen and not say when
--- anybody was told.
---
--- @return boolean changed, string|nil reason
function Repo.setFirearmStatus(agencyId, id, expectedVersion, input, discordId)
    local event = service().statusEvent(input.status)
    if not event then return false, 'status' end

    local committed = db().transaction({
        {
            query = [[INSERT INTO fpd_firearm_events
                          (agency_id, firearm_id, event, from_person_id,
                           case_number, reason, recorded_by)
                      SELECT f.agency_id, f.id, ?, f.owner_person_id,
                             NULLIF(?, ''), NULLIF(?, ''), ?
                        FROM fpd_firearms f
                       WHERE f.agency_id = ? AND f.id = ? AND f.version = ?]],
            values = {
                event, input.caseNumber or '', input.reason or '', discordId,
                agencyId, id, expectedVersion,
            },
        },
        {
            query = [[UPDATE fpd_firearms
                         SET status = ?, updated_by = ?, version = version + 1
                       WHERE agency_id = ? AND id = ? AND version = ?]],
            values = { input.status, discordId, agencyId, id, expectedVersion },
        },
    })

    if not committed then return false, 'write_failed' end

    local row = db().single(
        'SELECT version, status FROM fpd_firearms WHERE agency_id = ? AND id = ?',
        { agencyId, id }
    )

    if not row then return false, 'not_found' end
    if row.version ~= expectedVersion + 1 or row.status ~= input.status then
        return false, 'conflict'
    end

    return true
end

--- Issues an agency weapon to an officer, or takes it back (7.5, duty weapons).
---
--- `assignedOfficer` is a Discord id and comes from the caller, which passes
--- the officer being issued to -- never the session's own id, because a
--- quartermaster issues weapons to other people.
---
--- The status stays `agency_issued` on a return: it says whose weapon this is,
--- not whether somebody is carrying it, and a returned duty weapon is still the
--- agency's. Who has it is `assigned_officer`, which a return clears.
---
--- @param assignedOfficer string|nil nil returns the weapon to the armoury
--- @return boolean changed, string|nil reason
function Repo.assignFirearm(agencyId, id, expectedVersion, assignedOfficer, input, discordId)
    local issuing = assignedOfficer ~= nil

    local committed = db().transaction({
        {
            query = [[INSERT INTO fpd_firearm_events
                          (agency_id, firearm_id, event, to_party, case_number, reason, recorded_by)
                      SELECT f.agency_id, f.id, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?
                        FROM fpd_firearms f
                       WHERE f.agency_id = ? AND f.id = ? AND f.version = ?]],
            values = {
                issuing and 'issued' or 'returned', assignedOfficer or '',
                input.caseNumber or '', input.reason or '', discordId,
                agencyId, id, expectedVersion,
            },
        },
        {
            query = [[UPDATE fpd_firearms
                         SET assigned_officer = NULLIF(?, ''), status = 'agency_issued',
                             updated_by = ?, version = version + 1
                       WHERE agency_id = ? AND id = ? AND version = ?]],
            values = { assignedOfficer or '', discordId, agencyId, id, expectedVersion },
        },
    })

    if not committed then return false, 'write_failed' end

    local row = db().single(
        'SELECT version FROM fpd_firearms WHERE agency_id = ? AND id = ?',
        { agencyId, id }
    )

    if not row then return false, 'not_found' end
    if row.version ~= expectedVersion + 1 then return false, 'conflict' end

    return true
end

--- The ownership history: every event, oldest first (7.5).
---
--- Oldest first because this is a chain and a chain is read from its start --
--- the same order a trace report prints (7.5, eTrace-style), which is what
--- makes "first purchaser" the first line rather than something to scroll to.
function Repo.firearmEvents(agencyId, firearmId)
    return db().query(
        [[SELECT id, event, occurred_at AS occurredAt,
                 from_person_id AS fromPersonId, to_person_id AS toPersonId,
                 from_party AS fromParty, to_party AS toParty,
                 case_number AS caseNumber, reason, recorded_by AS recordedBy
            FROM fpd_firearm_events
           WHERE agency_id = ? AND firearm_id = ?
           ORDER BY occurred_at, id]],
        { agencyId, firearmId }
    )
end

--- The vehicles and firearms registered to one person are read by the persons
--- module (`linkedVehicles`, `linkedFirearms`), which owns that page and runs
--- the rows past the access module itself. There is no second copy of those
--- queries here: two readers of the same rows is how two answers to one
--- question start.

-- =============================================================================
-- The query log (7.2)
-- =============================================================================

--- Records a query: who, what, when (7.2).
---
--- Everything identifying comes from the session (invariant 1). `resultCount`
--- is the number of rows the reader was *allowed* to see, counted after access
--- filtering, so the log cannot be used to work out how many records were
--- hidden -- which would be the same leak the filtering exists to prevent.
---
--- `restricted` means the query opened a restricted record and the officer gave
--- a reason for it. A query that reached restricted data without one is refused
--- before anything is disclosed, and the access module has already written its
--- own audit entry for the attempt (invariant 11); this table is the officer's
--- query history, not a second audit log.
--- Nothing in the values list may be nil. A nil in an oxmysql values list
--- silently shortens the list and shifts every placeholder after it, which here
--- would write an officer id into the query type. `officer_id`, `identifier`
--- and `access_point` are all legitimately absent -- a terminal session with no
--- character bound, an access point the session does not record yet -- so a
--- sentinel travels and MariaDB turns it back into NULL.
function Repo.logQuery(session, entry)
    db().insert(
        [[INSERT INTO fpd_query_log
              (agency_id, discord_id, officer_id, identifier, query_type, term,
               access_point, restricted, reason, case_number, result_count, hit_count)
          VALUES (?, ?, NULLIF(?, 0), NULLIF(?, ''), ?, ?, NULLIF(?, ''), ?,
                  NULLIF(?, ''), NULLIF(?, ''), ?, ?)]],
        {
            session.agencyId,
            session.discordId,
            session.officerId or 0,
            session.identifier or '',
            entry.queryType,
            entry.term,
            session.accessPoint or '',
            entry.restricted and 1 or 0,
            entry.reason or '',
            entry.caseNumber or '',
            entry.resultCount or 0,
            entry.hitCount or 0,
        }
    )
end

--- Reading the query log back is the query module's (`query.log`, 7.2), not
--- this one's: it spans every kind of query, not just the two registers, and
--- one table with two readers is how two answers to the same question start.

FredPD.Repo.registry = Repo
