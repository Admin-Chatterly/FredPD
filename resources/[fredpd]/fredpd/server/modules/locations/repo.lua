--- Locations and premises SQL (spec 7.6). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local LOCATION_SELECT <const> = [[
    SELECT l.id, l.agency_id AS agencyId, l.label, l.kind, l.x, l.y, l.z, l.radius,
           l.notes, l.classification, l.created_by AS createdBy,
           UNIX_TIMESTAMP(l.created_at) AS createdAt, UNIX_TIMESTAMP(l.updated_at) AS updatedAt,
           l.version,
           (SELECT COUNT(*) FROM fpd_location_hazards h
             WHERE h.location_id = l.id AND h.cancelled_at IS NULL
               AND (h.expires_at IS NULL OR h.expires_at > CURRENT_TIMESTAMP(3))) AS liveHazards
      FROM fpd_locations l
]]

function Repo.byId(id, agencyId)
    return db().single(LOCATION_SELECT .. ' WHERE l.id = ? AND l.agency_id = ?', { id, agencyId })
end

--- The index, most recently touched first. A term matches anywhere in the
--- address: "alta" finds "12 Alta Street".
---
--- `%`, `_` and `\` are removed from the term rather than escaped, for the
--- reason `persons/repo.lua` gives: an escape clause breaks on a server
--- running `NO_BACKSLASH_ESCAPES`, and none of the three is part of an address.
function Repo.search(agencyId, term, limit)
    local cleaned = term and term:gsub('[%%_\\]', '') or ''

    if cleaned ~= '' then
        return db().query(
            LOCATION_SELECT .. ' WHERE l.agency_id = ? AND l.label LIKE ? ORDER BY l.updated_at DESC LIMIT ?',
            { agencyId, '%' .. cleaned .. '%', limit })
    end

    return db().query(
        LOCATION_SELECT .. ' WHERE l.agency_id = ? ORDER BY l.updated_at DESC LIMIT ?',
        { agencyId, limit })
end

--- Premises this point lies within. The square (bounded by the largest
--- radius a premise may have) lets the index on (agency, x, y) narrow the
--- rows; each premise's own circle then decides, in SQL, so a dense block of
--- addresses can never push the one a call is at past the limit.
function Repo.near(agencyId, x, y, reach)
    return db().query(
        LOCATION_SELECT .. [[ WHERE l.agency_id = ? AND l.x BETWEEN ? AND ? AND l.y BETWEEN ? AND ?
                                AND POW(l.x - ?, 2) + POW(l.y - ?, 2) <= POW(l.radius, 2)
                              ORDER BY POW(l.x - ?, 2) + POW(l.y - ?, 2)
                              LIMIT 20]],
        { agencyId, x - reach, x + reach, y - reach, y + reach, x, y, x, y })
end

--- Premises whose address is exactly this text, ignoring case.
function Repo.byLabel(agencyId, label)
    return db().query(
        LOCATION_SELECT .. ' WHERE l.agency_id = ? AND LOWER(l.label) = LOWER(?) LIMIT 10',
        { agencyId, label })
end

function Repo.create(agencyId, fields, discordId)
    return db().insert(
        [[INSERT INTO fpd_locations (agency_id, label, kind, x, y, z, radius, notes, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, fields.label, fields.kind, fields.x, fields.y, fields.z,
            fields.radius, fields.notes, fields.classification or 'internal', discordId,
        })
end

--- Changes a premise. Only the columns given move; the version is the lock.
function Repo.update(id, agencyId, expectedVersion, fields, discordId)
    local sets, values = {}, {}

    for _, column in ipairs({ 'label', 'kind', 'notes', 'radius', 'x', 'y', 'z' }) do
        if fields[column] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(column)
            values[#values + 1] = fields[column]
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`updated_by` = ?'
    values[#values + 1] = discordId
    sets[#sets + 1] = '`version` = `version` + 1'

    values[#values + 1] = id
    values[#values + 1] = agencyId
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_locations SET %s WHERE id = ? AND agency_id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values)
end

-- -----------------------------------------------------------------------------
-- Hazards
-- -----------------------------------------------------------------------------

local HAZARD_SELECT <const> = [[
    SELECT h.id, h.location_id AS locationId, h.kind, h.note,
           UNIX_TIMESTAMP(h.expires_at) AS expiresAt,
           h.created_by AS createdBy, UNIX_TIMESTAMP(h.created_at) AS createdAt,
           UNIX_TIMESTAMP(h.cancelled_at) AS cancelledAt,
           o.callsign AS createdByCallsign, o.name AS createdByName
      FROM fpd_location_hazards h
      LEFT JOIN fpd_officers o ON o.discord_id = h.created_by AND o.agency_id = h.agency_id
]]

--- Every hazard on a premise, the standing ones first, then the most recent.
function Repo.hazards(locationId, agencyId)
    return db().query(
        HAZARD_SELECT .. [[ WHERE h.location_id = ? AND h.agency_id = ?
                            ORDER BY (h.cancelled_at IS NULL) DESC, h.created_at DESC LIMIT 50]],
        { locationId, agencyId })
end

--- The standing hazards on these premises, for a call card.
function Repo.liveHazards(locationIds, agencyId)
    if #locationIds == 0 then return {} end

    local marks, values = {}, {}
    for index = 1, #locationIds do
        marks[index] = '?'
        values[index] = locationIds[index]
    end
    values[#values + 1] = agencyId

    return db().query(
        (HAZARD_SELECT .. [[ WHERE h.location_id IN (%s) AND h.agency_id = ?
                             AND h.cancelled_at IS NULL
                             AND (h.expires_at IS NULL OR h.expires_at > CURRENT_TIMESTAMP(3))
                           ORDER BY h.created_at DESC]]):format(table.concat(marks, ', ')),
        values)
end

function Repo.hazardById(id, agencyId)
    return db().single(HAZARD_SELECT .. ' WHERE h.id = ? AND h.agency_id = ?', { id, agencyId })
end

function Repo.addHazard(locationId, agencyId, kind, note, days, discordId)
    return db().insert(
        [[INSERT INTO fpd_location_hazards (location_id, agency_id, kind, note, expires_at, created_by)
          VALUES (?, ?, ?, ?, IF(? IS NULL, NULL, DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)), ?)]],
        { locationId, agencyId, kind, note, days, days, discordId })
end

function Repo.cancelHazard(id, agencyId, discordId)
    return db().execute(
        [[UPDATE fpd_location_hazards SET cancelled_at = CURRENT_TIMESTAMP(3), cancelled_by = ?
           WHERE id = ? AND agency_id = ? AND cancelled_at IS NULL]],
        { discordId, id, agencyId })
end

-- -----------------------------------------------------------------------------
-- Keyholders
-- -----------------------------------------------------------------------------

function Repo.keyholders(locationId, agencyId)
    return db().query(
        [[SELECT person_id AS personId, role, UNIX_TIMESTAMP(created_at) AS createdAt
            FROM fpd_location_keyholders WHERE location_id = ? AND agency_id = ?
           ORDER BY FIELD(role, 'owner', 'tenant', 'manager', 'keyholder', 'employee'), person_id]],
        { locationId, agencyId })
end

function Repo.setKeyholder(locationId, agencyId, personId, role, discordId)
    return db().execute(
        [[INSERT INTO fpd_location_keyholders (location_id, agency_id, person_id, role, created_by)
          VALUES (?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE role = VALUES(role)]],
        { locationId, agencyId, personId, role, discordId })
end

function Repo.removeKeyholder(locationId, agencyId, personId)
    return db().execute(
        'DELETE FROM fpd_location_keyholders WHERE location_id = ? AND agency_id = ? AND person_id = ?',
        { locationId, agencyId, personId })
end

-- -----------------------------------------------------------------------------
-- Incident history
-- -----------------------------------------------------------------------------

--- Calls at a premise: within its circle, or giving its address as their
--- location. Newest first, with the columns the CAD access check reads; the
--- caller filters them through `Board.readable`.
function Repo.callsAt(agencyId, location, limit)
    local clauses, values = {}, {}

    if location.x and location.y then
        local reach = tonumber(location.radius) or 30
        clauses[#clauses + 1] = [[(x BETWEEN ? AND ? AND y BETWEEN ? AND ?
                                   AND POW(x - ?, 2) + POW(y - ?, 2) <= POW(?, 2))]]
        for _, value in ipairs({
            location.x - reach, location.x + reach, location.y - reach, location.y + reach,
            location.x, location.y, reach,
        }) do
            values[#values + 1] = value
        end
    end

    clauses[#clauses + 1] = 'LOWER(location_text) = LOWER(?)'
    values[#values + 1] = location.label

    table.insert(values, 1, agencyId)
    values[#values + 1] = limit

    return db().query(
        ([[SELECT id, agency_id AS agencyId, call_number AS callNumber, type, status, disposition,
                  classification, UNIX_TIMESTAMP(received_at) AS receivedAt
             FROM fpd_calls WHERE agency_id = ? AND (%s)
            ORDER BY received_at DESC LIMIT ?]]):format(table.concat(clauses, ' OR ')),
        values)
end

FredPD.Repo.locations = Repo
