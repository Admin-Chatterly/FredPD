--- Reports from the public (0040). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local SELECT <const> = [[
    SELECT id, number, kind, reporter_person_id AS reporterPersonId, reporter_name AS reporterName,
           UNIX_TIMESTAMP(occurred_at) AS occurredAt, place, description, property, status,
           handled_by AS handledBy, UNIX_TIMESTAMP(handled_at) AS handledAt, handled_note AS handledNote,
           anmalan_id AS anmalanId, version, UNIX_TIMESTAMP(created_at) AS createdAt
      FROM fpd_public_reports
]]

--- Files a report and gives it its number, in one transaction with the
--- counter (13.1). Read back by reporter and newest, under the route's own
--- per-player lock.
function Repo.insert(report, agencyId, shortName)
    local counters = FredPD.Core.counters
    local prefix, width = FredPD.Modules.civilian.numberPrefix(shortName, counters.year())

    local values = counters.numberValues(prefix, width, 'public_report', agencyId)
    local base = #values
    values[base + 1] = agencyId
    values[base + 2] = report.kind
    values[base + 3] = report.reporterIdentifier
    values[base + 4] = report.reporterPersonId
    values[base + 5] = report.reporterName
    values[base + 6] = report.occurredAt
    values[base + 7] = report.place
    values[base + 8] = report.description
    values[base + 9] = report.property

    local committed = db().transaction(counters.transaction('public_report', agencyId, nil, {
        {
            query = [[INSERT INTO fpd_public_reports
                          (number, agency_id, kind, reporter_identifier, reporter_person_id, reporter_name,
                           occurred_at, place, description, property)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), ?, ?, ?)]],
            values = values,
        },
    }))
    if not committed then return nil end

    return db().single(
        [[SELECT id, number FROM fpd_public_reports
           WHERE agency_id = ? AND reporter_identifier = ? ORDER BY id DESC LIMIT 1]],
        { agencyId, report.reporterIdentifier })
end

--- What one member of the public has handed in: the number, the kind and
--- where it stands -- never who handled it.
function Repo.mine(agencyId, identifier, limit)
    return db().query(
        [[SELECT number, kind, status, UNIX_TIMESTAMP(created_at) AS createdAt
            FROM fpd_public_reports
           WHERE agency_id = ? AND reporter_identifier = ?
           ORDER BY created_at DESC LIMIT ?]],
        { agencyId, identifier, limit })
end

--- How many this character handed in over the last day: a front desk takes a
--- few, not a flood.
function Repo.countToday(agencyId, identifier)
    return db().scalar(
        [[SELECT COUNT(*) FROM fpd_public_reports
           WHERE agency_id = ? AND reporter_identifier = ?
             AND created_at >= DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL 1 DAY)]],
        { agencyId, identifier }) or 0
end

--- The inbox: the kinds this officer may read, newest first.
function Repo.inbox(agencyId, kinds, status, limit)
    if #kinds == 0 then return {} end

    local marks = {}
    local values = { agencyId }
    for index, kind in ipairs(kinds) do
        marks[index] = '?'
        values[#values + 1] = kind
    end

    local clause = ''
    if status then
        clause = ' AND status = ?'
        values[#values + 1] = status
    end
    values[#values + 1] = limit

    return db().query(
        SELECT .. ' WHERE agency_id = ? AND kind IN (' .. table.concat(marks, ', ') .. ')' .. clause
            .. ' ORDER BY created_at DESC LIMIT ?',
        values)
end

function Repo.byId(id, agencyId)
    return db().single(SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- Closes a report, once: a stale version or one already closed changes
--- nothing.
function Repo.handle(id, agencyId, version, outcome, discordId, note, anmalanId)
    return db().execute(
        [[UPDATE fpd_public_reports
             SET status = ?, handled_by = ?, handled_at = CURRENT_TIMESTAMP(3), handled_note = ?,
                 anmalan_id = ?, version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND status = 'received']],
        { outcome, discordId, note, anmalanId, id, agencyId, version })
end

FredPD.Repo.civilian = Repo
