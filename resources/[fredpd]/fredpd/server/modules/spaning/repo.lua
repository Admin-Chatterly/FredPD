--- Spaningsuppdrag SQL (spec 7.13). Parameterized only (invariant 8).
---
--- Timestamps come back as epoch seconds, because every liveness decision in
--- `spaning/service.lua` is a comparison against `os.time()`.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D gives no format for a BOLO, so this follows the warrant shape
--- with its own letter: `S{YY}-{#####}`.
function Repo.numberPrefix()
    return ('S%s-'):format(os.date('%y')), 5
end

local SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number,
           target_kind AS targetKind, target_id AS targetId,
           description, grund, priority,
           beat_id AS beatId, area_note AS areaNote,
           fu_id AS fuId, anmalan_id AS anmalanId,
           issued_by AS issuedBy,
           UNIX_TIMESTAMP(issued_at)   AS issuedAt,
           UNIX_TIMESTAMP(expires_at)  AS expiresAt,
           UNIX_TIMESTAMP(resolved_at) AS resolvedAt,
           resolved_by AS resolvedBy, resolved_grund AS resolvedGrund,
           classification, version
      FROM fpd_spaning
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- The lookouts on one target, for the hot-file check (7.2).
---
--- Across every agency: a query run by one department has to surface a lookout
--- raised by another, or a server with two forces has two blind spots. Resolved
--- rows are filtered in SQL because that is indexed; expiry is left to
--- `Spaning.isLive`, so "live" keeps one definition.
function Repo.forTarget(targetKind, targetId)
    return FredPD.Core.db.query(
        SELECT .. [[ WHERE target_kind = ? AND target_id = ? AND resolved_at IS NULL
                     ORDER BY priority, issued_at DESC]],
        { targetKind, targetId })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.targetKind then
        clauses[#clauses + 1] = 'target_kind = ?'
        values[#values + 1] = filter.targetKind
    end

    if filter.priority then
        clauses[#clauses + 1] = 'priority <= ?'
        values[#values + 1] = filter.priority
    end

    if not filter.includeResolved then
        clauses[#clauses + 1] = 'resolved_at IS NULL AND expires_at > CURRENT_TIMESTAMP(3)'
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY priority, issued_at DESC LIMIT ?',
        values)
end

--- Raises a lookout, number allocated under the counter lock.
function Repo.create(input, session, validSeconds)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'bolo', session.agencyId)
    local base = #values

    -- By index: `target_id`, `beat_id`, `fu_id` and `anmalan_id` are each nil
    -- on an ordinary lookout, and a nil appended to an oxmysql values list
    -- shifts every parameter after it.
    values[base + 1] = session.agencyId
    values[base + 2] = input.targetKind
    values[base + 3] = input.targetId
    values[base + 4] = input.description
    values[base + 5] = input.grund
    values[base + 6] = input.priority or 3
    values[base + 7] = input.beatId
    values[base + 8] = input.areaNote
    values[base + 9] = input.fuId
    values[base + 10] = input.anmalanId
    values[base + 11] = session.discordId
    values[base + 12] = validSeconds
    values[base + 13] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'bolo', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_spaning
                              (number, agency_id, target_kind, target_id, description,
                               grund, priority, beat_id, area_note, fu_id, anmalan_id,
                               issued_by, expires_at, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?,
                                  ?, ?, ?, ?, ?, ?,
                                  ?, DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND), ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        SELECT .. ' WHERE agency_id = ? AND issued_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

function Repo.resolve(id, agencyId, discordId, grund, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_spaning
           SET resolved_at = CURRENT_TIMESTAMP(3), resolved_by = ?,
               resolved_grund = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND resolved_at IS NULL]],
        { discordId, grund, id, agencyId, expectedVersion })
end

--- Resolves every live lookout on one target.
---
--- 7.13's auto-resolve. Called when the thing being looked for turns up: a
--- person is seized, or a vehicle is taken. Across every agency, deliberately
--- -- the van has been found, and a second department's lookout for it is as
--- stale as the first's.
function Repo.resolveForTarget(targetKind, targetId, discordId, grund)
    return FredPD.Core.db.execute([[
        UPDATE fpd_spaning
           SET resolved_at = CURRENT_TIMESTAMP(3), resolved_by = ?,
               resolved_grund = ?, version = version + 1
         WHERE target_kind = ? AND target_id = ? AND resolved_at IS NULL]],
        { discordId, grund, targetKind, targetId })
end

FredPD.Repo.spaning = Repo
