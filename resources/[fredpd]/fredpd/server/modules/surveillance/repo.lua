--- Surveillance SQL (spec 9). Parameterized only (invariant 8).
---
--- Timestamps come back as epoch seconds, because every validity decision in
--- `surveillance/service.lua` is a comparison against `os.time()` -- the same
--- reasoning `tvangsmedel/repo.lua`'s header gives.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `H{YY}-{#####}`.
function Repo.numberPrefix()
    return ('H%s-'):format(os.date('%y')), 5
end

local HAK_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, fu_id AS fuId,
           target_kind AS targetKind, target_id AS targetId, target_label AS targetLabel,
           method, grund, status,
           requested_by AS requestedBy,
           UNIX_TIMESTAMP(requested_at) AS requestedAt,
           decided_by AS decidedBy,
           UNIX_TIMESTAMP(decided_at)   AS decidedAt,
           refused_grund AS refusedGrund, court_ref AS courtRef,
           UNIX_TIMESTAMP(valid_from)   AS validFrom,
           UNIX_TIMESTAMP(valid_until)  AS validUntil,
           UNIX_TIMESTAMP(upphavd_at)   AS upphavdAt,
           upphavd_by AS upphavdBy, upphavd_grund AS upphavdGrund,
           classification, version
      FROM fpd_hak
]]

--- The same columns, minus `court_ref`.
---
--- A list row draws a number, a target, a method and a status; the court's own
--- reference for its beslut is read only from `hak.get`'s detail view, the
--- same projection `tvangsmedel/repo.lua` gives `scope` and `verkstalld_note`.
local HAK_LIST_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, fu_id AS fuId,
           target_kind AS targetKind, target_id AS targetId, target_label AS targetLabel,
           method, grund, status,
           requested_by AS requestedBy,
           UNIX_TIMESTAMP(requested_at) AS requestedAt,
           decided_by AS decidedBy,
           UNIX_TIMESTAMP(decided_at)   AS decidedAt,
           refused_grund AS refusedGrund,
           UNIX_TIMESTAMP(valid_from)   AS validFrom,
           UNIX_TIMESTAMP(valid_until)  AS validUntil,
           UNIX_TIMESTAMP(upphavd_at)   AS upphavdAt,
           upphavd_by AS upphavdBy, upphavd_grund AS upphavdGrund,
           classification, version
      FROM fpd_hak
]]

-- -----------------------------------------------------------------------------
-- The decision
-- -----------------------------------------------------------------------------

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        HAK_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- Every measure for one target that is still live, across every agency, for
--- the spec 14 export -- the same reach `Repo.forTargetAnyAgency` gives
--- `HasSearchWarrant`, and for the same reason: the question a script asks is
--- whether *anything* authorises this, not which department decided it.
function Repo.forTargetAnyAgency(targetKind, targetId)
    return FredPD.Core.db.query(
        HAK_SELECT .. [[ WHERE target_kind = ? AND target_id = ? AND status = 'beviljad'
                          ORDER BY valid_until DESC]],
        { targetKind, targetId })
end

--- The same, keyed by `target_label` -- what a phone number or a location
--- carries instead of an id (0015: neither is a foreign key into anything
--- this suite holds). An exact match: the export exists for a script that
--- already knows the number or the address, not for search.
function Repo.forTargetLabelAnyAgency(targetKind, targetLabel)
    return FredPD.Core.db.query(
        HAK_SELECT .. [[ WHERE target_kind = ? AND target_label = ? AND status = 'beviljad'
                          ORDER BY valid_until DESC]],
        { targetKind, targetLabel })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.fuId then
        clauses[#clauses + 1] = 'fu_id = ?'
        values[#values + 1] = filter.fuId
    end

    if filter.status then
        clauses[#clauses + 1] = 'status = ?'
        values[#values + 1] = filter.status
    end

    if filter.liveOnly then
        clauses[#clauses + 1] = "status = 'beviljad' AND upphavd_at IS NULL AND valid_until > CURRENT_TIMESTAMP(3)"
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        HAK_LIST_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY requested_at DESC LIMIT ?',
        values)
end

--- Records an åklagare's application, number allocated under the counter lock.
function Repo.request(input, session)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'hak', session.agencyId)
    local base = #values

    -- By index: `target_id` and `target_label` are each nil on some requests,
    -- and a nil appended to an oxmysql values list shifts every placeholder
    -- after it.
    values[base + 1] = session.agencyId
    values[base + 2] = input.fuId
    values[base + 3] = input.targetKind
    values[base + 4] = input.targetId
    values[base + 5] = input.targetLabel
    values[base + 6] = input.method
    values[base + 7] = input.grund
    values[base + 8] = session.discordId
    values[base + 9] = input.classification or 'confidential'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'hak', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_hak
                              (number, agency_id, fu_id, target_kind, target_id, target_label,
                               method, grund, requested_by, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?,
                                  ?, ?, ?, ?, ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        HAK_SELECT .. ' WHERE agency_id = ? AND requested_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

--- Grants a request. Only a row still `begard` moves -- a decision, once
--- taken, is not retaken.
function Repo.grant(id, agencyId, discordId, courtRef, validSeconds, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_hak
           SET status = 'beviljad', decided_by = ?, decided_at = CURRENT_TIMESTAMP(3),
               court_ref = ?, valid_from = CURRENT_TIMESTAMP(3),
               valid_until = DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND),
               version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND status = 'begard']],
        { discordId, courtRef, validSeconds, id, agencyId, expectedVersion })
end

function Repo.refuse(id, agencyId, discordId, grund, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_hak
           SET status = 'avslagen', decided_by = ?, decided_at = CURRENT_TIMESTAMP(3),
               refused_grund = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND status = 'begard']],
        { discordId, grund, id, agencyId, expectedVersion })
end

--- Revokes a granted measure early (RB 27:23). Only a `beviljad` row moves.
function Repo.upphav(id, agencyId, discordId, grund, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_hak
           SET status = 'upphavd', upphavd_by = ?, upphavd_at = CURRENT_TIMESTAMP(3),
               upphavd_grund = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND status = 'beviljad']],
        { discordId, grund, id, agencyId, expectedVersion })
end

-- -----------------------------------------------------------------------------
-- Observer sessions
-- -----------------------------------------------------------------------------

function Repo.sessionsFor(hakId)
    return FredPD.Core.db.query(
        [[SELECT id, hak_id AS hakId, observer,
                 UNIX_TIMESTAMP(started_at) AS startedAt,
                 UNIX_TIMESTAMP(ended_at)   AS endedAt,
                 minimization_note AS minimizationNote
            FROM fpd_hak_sessions
           WHERE hak_id = ?
           ORDER BY started_at DESC]],
        { hakId })
end

function Repo.startSession(hakId, discordId)
    return FredPD.Core.db.insert(
        'INSERT INTO fpd_hak_sessions (hak_id, observer) VALUES (?, ?)',
        { hakId, discordId })
end

--- Ends the caller's own open session. Scoped to `observer` so an officer can
--- only close a session they hold -- ending somebody else's would misrecord
--- who was listening when.
function Repo.endSession(sessionId, discordId, note)
    return FredPD.Core.db.execute([[
        UPDATE fpd_hak_sessions
           SET ended_at = CURRENT_TIMESTAMP(3), minimization_note = ?
         WHERE id = ? AND observer = ? AND ended_at IS NULL]],
        { note, sessionId, discordId })
end

-- -----------------------------------------------------------------------------
-- Captures
-- -----------------------------------------------------------------------------

function Repo.interceptsFor(hakId)
    return FredPD.Core.db.query(
        [[SELECT id, hak_id AS hakId, kind,
                 UNIX_TIMESTAMP(occurred_at) AS occurredAt,
                 summary, media_ref AS mediaRef, classification,
                 logged_by AS loggedBy,
                 UNIX_TIMESTAMP(logged_at) AS loggedAt
            FROM fpd_hak_intercepts
           WHERE hak_id = ?
           ORDER BY occurred_at DESC]],
        { hakId })
end

--- Logs a capture. Append-only (0015): there is no update or delete here, by
--- design -- the same reasoning `fpd_frihet_log` and `fpd_call_log` are built
--- on.
function Repo.addIntercept(input, discordId)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_hak_intercepts
              (hak_id, kind, occurred_at, summary, media_ref, classification, logged_by)
          VALUES (?, ?, CURRENT_TIMESTAMP(3), ?, ?, ?, ?)]],
        {
            input.hakId, input.kind, input.summary, input.mediaRef,
            input.classification or 'confidential', discordId,
        })
end

FredPD.Repo.surveillance = Repo
