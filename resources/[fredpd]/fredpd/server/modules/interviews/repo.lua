--- Field interviews and stop data SQL (spec 7.14). Parameterized only.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local FI_SELECT <const> = [[
    SELECT f.id, f.agency_id AS agencyId, f.person_id AS personId, f.vehicle_id AS vehicleId,
           f.call_id AS callId, f.reason, f.narrative, f.location_text AS locationText,
           f.classification, f.created_by AS createdBy, UNIX_TIMESTAMP(f.created_at) AS createdAt,
           o.callsign AS createdByCallsign, o.name AS createdByName,
           c.call_number AS callNumber
      FROM fpd_fi_cards f
      LEFT JOIN fpd_officers o ON o.discord_id = f.created_by AND o.agency_id = f.agency_id
      LEFT JOIN fpd_calls c ON c.id = f.call_id AND c.agency_id = f.agency_id
]]

function Repo.fiById(id, agencyId)
    return db().single(FI_SELECT .. ' WHERE f.id = ? AND f.agency_id = ?', { id, agencyId })
end

--- Cards, newest first: about a person (as subject or associate), about a
--- vehicle, by one officer, or all of them.
function Repo.fiList(agencyId, filter, limit)
    local clauses, values = { 'f.agency_id = ?' }, { agencyId }

    if filter.personId then
        clauses[#clauses + 1] = [[(f.person_id = ? OR EXISTS (SELECT 1 FROM fpd_fi_associates a
                                    WHERE a.fi_id = f.id AND a.person_id = ?))]]
        values[#values + 1] = filter.personId
        values[#values + 1] = filter.personId
    end

    if filter.vehicleId then
        clauses[#clauses + 1] = 'f.vehicle_id = ?'
        values[#values + 1] = filter.vehicleId
    end

    if filter.createdBy then
        clauses[#clauses + 1] = 'f.created_by = ?'
        values[#values + 1] = filter.createdBy
    end

    values[#values + 1] = limit

    return db().query(
        FI_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ') .. ' ORDER BY f.created_at DESC LIMIT ?',
        values)
end

function Repo.fiAssociates(fiId)
    return db().query('SELECT person_id AS personId FROM fpd_fi_associates WHERE fi_id = ? ORDER BY person_id',
        { fiId })
end

--- A card, then its associates.
---
--- The card is inserted on its own so its id comes back from the insert
--- itself: reading back "this officer's newest card" names the wrong one when
--- the same officer writes two at once. Associates follow in one
--- transaction; if that fails the card is taken back out rather than left
--- behind without the people it was written about.
---
--- @return number|nil the card's id
function Repo.fiCreate(agencyId, fields, associateIds, discordId)
    local id = db().insert(
        [[INSERT INTO fpd_fi_cards (agency_id, person_id, vehicle_id, call_id, reason, narrative,
                                    location_text, x, y, z, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, fields.personId, fields.vehicleId, fields.callId, fields.reason, fields.narrative,
            fields.locationText, fields.x, fields.y, fields.z, fields.classification or 'internal', discordId,
        })
    if not id then return nil end
    if #associateIds == 0 then return id end

    local statements = {}
    for _, personId in ipairs(associateIds) do
        statements[#statements + 1] = {
            query = 'INSERT INTO fpd_fi_associates (fi_id, person_id) VALUES (?, ?)',
            values = { id, personId },
        }
    end

    if db().transaction(statements) then return id end

    db().execute('DELETE FROM fpd_fi_cards WHERE id = ? AND agency_id = ?', { id, agencyId })
    return nil
end

-- -----------------------------------------------------------------------------
-- The people and vehicles a page of cards or stops names
-- -----------------------------------------------------------------------------

local function placeholders(count)
    return string.rep('?', count, ', ')
end

--- Persons by id, agency-scoped, with what the access check needs, for one
--- `filterSearch` over a whole page rather than one read per row.
function Repo.personsByIds(agencyId, ids)
    if #ids == 0 then return {} end

    local values = { agencyId }
    for index = 1, #ids do values[index + 1] = ids[index] end

    return db().query(
        ([[SELECT p.id, p.agency_id AS agencyId, p.person_number AS personNumber,
                  p.first_name AS firstName, p.last_name AS lastName, p.classification
             FROM fpd_persons p WHERE p.agency_id = ? AND p.id IN (%s)]]):format(placeholders(#ids)),
        values)
end

--- Vehicles by id, the same way.
function Repo.vehiclesByIds(agencyId, ids)
    if #ids == 0 then return {} end

    local values = { agencyId }
    for index = 1, #ids do values[index + 1] = ids[index] end

    return db().query(
        ([[SELECT v.id, v.agency_id AS agencyId, v.plate, v.model, v.classification
             FROM fpd_vehicles v WHERE v.agency_id = ? AND v.id IN (%s)]]):format(placeholders(#ids)),
        values)
end

-- -----------------------------------------------------------------------------
-- Stops
-- -----------------------------------------------------------------------------

local STOP_SELECT <const> = [[
    SELECT s.id, s.agency_id AS agencyId, s.kind, s.reason, s.search, s.result,
           s.person_id AS personId, s.vehicle_id AS vehicleId, s.call_id AS callId,
           s.classification, s.created_by AS createdBy, UNIX_TIMESTAMP(s.created_at) AS createdAt,
           o.callsign AS createdByCallsign, v.plate
      FROM fpd_stops s
      LEFT JOIN fpd_officers o ON o.discord_id = s.created_by AND o.agency_id = s.agency_id
      LEFT JOIN fpd_vehicles v ON v.id = s.vehicle_id AND v.agency_id = s.agency_id
]]

function Repo.stopCreate(agencyId, fields, discordId)
    return db().insert(
        [[INSERT INTO fpd_stops (agency_id, kind, reason, search, result, person_id, vehicle_id, call_id,
                                 x, y, z, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, fields.kind, fields.reason, fields.search, fields.result, fields.personId,
            fields.vehicleId, fields.callId, fields.x, fields.y, fields.z, discordId,
        })
end

function Repo.stopList(agencyId, filter, limit)
    local clauses, values = { 's.agency_id = ?' }, { agencyId }

    if filter.createdBy then
        clauses[#clauses + 1] = 's.created_by = ?'
        values[#values + 1] = filter.createdBy
    end

    values[#values + 1] = limit

    return db().query(
        STOP_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ') .. ' ORDER BY s.created_at DESC LIMIT ?',
        values)
end

FredPD.Repo.interviews = Repo
