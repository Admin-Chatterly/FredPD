--- Vehicle impound SQL (spec 7.15). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `I{YY}-{#####}`.
function Repo.numberPrefix()
    return ('I%s-'):format(os.date('%y')), 5
end

local IMPOUND_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, vehicle_id AS vehicleId,
           plate, model, held_reason_key AS heldReasonKey,
           hold_authorized_by AS holdAuthorizedBy,
           UNIX_TIMESTAMP(hold_authorized_at) AS holdAuthorizedAt,
           fee_per_day AS feePerDay,
           UNIX_TIMESTAMP(impounded_at) AS impoundedAt, impounded_by AS impoundedBy,
           UNIX_TIMESTAMP(released_at) AS releasedAt, released_by AS releasedBy,
           fee_paid AS feePaid, classification, version,
           UNIX_TIMESTAMP(towed_at) AS towedAt, garage_plate AS garagePlate,
           lot_id AS lotId, bay, keys_location AS keysLocation, condition_note AS conditionNote,
           contents, inventory_by AS inventoryBy, UNIX_TIMESTAMP(inventory_at) AS inventoryAt,
           (SELECT o.callsign FROM fpd_officers o
             WHERE o.discord_id = fpd_impound.inventory_by AND o.agency_id = fpd_impound.agency_id
             LIMIT 1) AS inventoryByCallsign
      FROM fpd_impound
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        IMPOUND_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- The most recent open record for a plate -- the one a front-desk lookup by
--- plate means.
function Repo.byPlate(plate, agencyId)
    return FredPD.Core.db.single(
        IMPOUND_SELECT .. [[ WHERE plate = ? AND agency_id = ? AND released_at IS NULL
                              ORDER BY id DESC LIMIT 1]],
        { plate, agencyId })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.held then
        clauses[#clauses + 1] = 'released_at IS NULL'
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        IMPOUND_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY impounded_at DESC LIMIT ?',
        values)
end

--- Resolves a plate against the vehicle registry, for the FK this record
--- carries when it can. `fpd_vehicles.plate` is the vehicle's *current* plate
--- (0005) -- the column this lookup means, not `fpd_vehicle_plates`, which is
--- append-only history of plates a vehicle no longer carries.
local function resolveVehicleId(plate, agencyId)
    local row = FredPD.Core.db.single(
        'SELECT id FROM fpd_vehicles WHERE plate = ? AND agency_id = ?', { plate, agencyId })

    return row and row.id or nil
end

--- Records a new impound, counters-based -- the same shape `court/repo.lua`'s
--- `Repo.decide` uses, including reading the inserted row back after commit.
function Repo.create(input, session)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local vehicleId = resolveVehicleId(input.plate, session.agencyId)

    local values = counters.numberValues(prefix, width, 'impound', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = vehicleId
    values[base + 3] = input.plate
    values[base + 4] = input.model
    values[base + 5] = input.heldReasonKey
    values[base + 6] = input.feePerDay or 0
    values[base + 7] = session.discordId
    values[base + 8] = input.classification or 'internal'
    -- The lot, already checked by the route against the agency's own lots.
    values[base + 9] = input.lotId

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'impound', session.agencyId, nil, { {
            query = [[INSERT INTO fpd_impound
                          (number, agency_id, vehicle_id, plate, model, held_reason_key,
                           fee_per_day, impounded_by, classification, lot_id)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
            values = values,
        } }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        IMPOUND_SELECT .. ' WHERE agency_id = ? AND impounded_by = ? AND plate = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId, input.plate })
end

--- Only a row not already authorized moves -- an authorization, once given,
--- is not retaken here.
function Repo.authorize(id, agencyId, discordId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_impound SET hold_authorized_by = ?, hold_authorized_at = CURRENT_TIMESTAMP(3)
           WHERE id = ? AND agency_id = ? AND hold_authorized_at IS NULL]],
        { discordId, id, agencyId })
end

function Repo.release(id, agencyId, discordId, feePaid, expectedVersion)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_impound
             SET released_at = CURRENT_TIMESTAMP(3), released_by = ?, fee_paid = ?, version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND released_at IS NULL]],
        { discordId, feePaid and 1 or 0, id, agencyId, expectedVersion })
end

--- Records that the tow took the car off the street, and which exact garage
--- row it marked held (migration 0032). Only such a row writes the garage
--- back on release.
function Repo.markTowed(id, agencyId, garagePlate)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_impound SET towed_at = CURRENT_TIMESTAMP(3), garage_plate = ?
           WHERE id = ? AND agency_id = ? AND towed_at IS NULL]],
        { garagePlate, id, agencyId })
end

--- Where a held car stands and what it was found with (0037). Only onto a
--- row still held, at the version the writer read.
---
--- @return number rows affected -- 0 when released meanwhile or stale
function Repo.setInventory(id, agencyId, fields, discordId, expectedVersion)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_impound
             SET lot_id = ?, bay = ?, keys_location = ?, condition_note = ?, contents = ?,
                 inventory_by = ?, inventory_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND released_at IS NULL]],
        {
            fields.lotId, fields.bay, fields.keys, fields.condition, fields.contents,
            discordId, id, agencyId, expectedVersion,
        })
end

--- Is any other impound, in any agency, still holding this garage plate?
--- `owned_vehicles` is shared by every agency, so a cheap hold released in
--- one must not hand back a car another still holds.
function Repo.otherOpenHold(garagePlate, exceptId)
    return FredPD.Core.db.scalar(
        [[SELECT COUNT(*) FROM fpd_impound
           WHERE garage_plate = ? AND released_at IS NULL AND id <> ?]],
        { garagePlate, exceptId }) > 0
end

FredPD.Repo.impound = Repo
