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
           fee_paid AS feePaid, classification, version
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

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'impound', session.agencyId, nil, { {
            query = [[INSERT INTO fpd_impound
                          (number, agency_id, vehicle_id, plate, model, held_reason_key,
                           fee_per_day, impounded_by, classification)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?, ?, ?)]],
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

FredPD.Repo.impound = Repo
