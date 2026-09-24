--- Footage requests (0041). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local SELECT <const> = [[
    SELECT f.id, f.number, f.source, f.camera_id AS cameraId, f.officer_id AS officerId,
           o.callsign AS officerCallsign,
           UNIX_TIMESTAMP(f.window_from) AS windowFrom, UNIX_TIMESTAMP(f.window_to) AS windowTo,
           f.reason, f.fu_id AS fuId, f.status, f.requested_by AS requestedBy,
           UNIX_TIMESTAMP(f.requested_at) AS requestedAt, f.decided_by AS decidedBy,
           UNIX_TIMESTAMP(f.decided_at) AS decidedAt, f.decision_note AS decisionNote,
           f.still_ref AS stillRef, UNIX_TIMESTAMP(f.still_at) AS stillAt,
           f.classification, f.version
      FROM fpd_footage_requests f
      LEFT JOIN fpd_officers o ON o.id = f.officer_id
]]

function Repo.insert(request, session)
    local counters = FredPD.Core.counters
    local prefix, width = FredPD.Modules.camera.numberPrefix(counters.year())

    local values = counters.numberValues(prefix, width, 'footage', session.agencyId)
    local base = #values
    values[base + 1] = session.agencyId
    values[base + 2] = request.source
    values[base + 3] = request.cameraId
    values[base + 4] = request.officerId
    values[base + 5] = request.windowFrom
    values[base + 6] = request.windowTo
    values[base + 7] = request.reason
    values[base + 8] = request.fuId
    values[base + 9] = session.discordId

    local committed = db().transaction(counters.transaction('footage', session.agencyId, nil, {
        {
            query = [[INSERT INTO fpd_footage_requests
                          (number, agency_id, source, camera_id, officer_id, window_from, window_to,
                           reason, fu_id, requested_by)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?),
                              ?, ?, ?)]],
            values = values,
        },
    }))
    if not committed then return nil end

    return db().single(
        'SELECT id, number FROM fpd_footage_requests WHERE agency_id = ? AND requested_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

function Repo.byId(id, agencyId)
    return db().single(SELECT .. ' WHERE f.id = ? AND f.agency_id = ?', { id, agencyId })
end

--- The requests one officer made, or -- for whoever approves them -- all of
--- this agency's, newest first, a page at a time (12.2).
---
--- @return table rows, string|nil nextCursor
function Repo.list(agencyId, discordId, all, status, limit, cursor)
    local where, values = { 'f.agency_id = ?' }, { agencyId }
    if not all then
        where[#where + 1] = 'f.requested_by = ?'
        values[#values + 1] = discordId
    end
    if status then
        where[#where + 1] = 'f.status = ?'
        values[#values + 1] = status
    end
    -- Ids rise with every request, so the id alone orders them newest first.
    local after = FredPD.Core.pagination.decode(cursor, 1)
    if after then
        where[#where + 1] = 'f.id < ?'
        values[#values + 1] = after[1]
    end
    values[#values + 1] = limit + 1

    local rows = db().query(
        SELECT .. ' WHERE ' .. table.concat(where, ' AND ') .. ' ORDER BY f.id DESC LIMIT ?', values)

    local nextCursor = nil
    if #rows > limit then
        rows[limit + 1] = nil
        nextCursor = FredPD.Core.pagination.encode({ rows[limit].id })
    end
    return rows, nextCursor
end

--- This officer's approved requests for a source, for "may I look now".
function Repo.approvedFor(agencyId, discordId, source)
    return db().query(
        SELECT .. [[ WHERE f.agency_id = ? AND f.requested_by = ? AND f.source = ? AND f.status = 'approved'
                     AND f.window_to >= CURRENT_TIMESTAMP(3)
                   ORDER BY f.window_to DESC LIMIT 20]],
        { agencyId, discordId, source })
end

function Repo.decide(id, agencyId, version, approve, discordId, note)
    return db().execute(
        [[UPDATE fpd_footage_requests
             SET status = ?, decided_by = ?, decided_at = CURRENT_TIMESTAMP(3), decision_note = ?,
                 version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND status = 'requested']],
        { approve and 'approved' or 'denied', discordId, note, id, agencyId, version })
end

--- One still per request: a second is refused, not a replacement.
function Repo.setStill(id, agencyId, mediaRef, discordId)
    return db().execute(
        [[UPDATE fpd_footage_requests
             SET still_ref = ?, still_by = ?, still_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND still_ref IS NULL AND status = 'approved']],
        { mediaRef, discordId, id, agencyId })
end

FredPD.Repo.camera = Repo
