--- Tvångsmedel och efterlysning SQL (spec 7.12, 7.13). Parameterized only
--- (invariant 8).
---
--- Timestamps come back as epoch seconds, because every validity decision in
--- `tvangsmedel/service.lua` is a comparison against `os.time()` and a service
--- that parsed a DATETIME string would parse it differently from the way
--- MariaDB wrote it.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `W{YY}-{#####}`, the format the spec gives for a warrant.
---
--- Shared by both tables. They draw from the same `warrant` counter on purpose:
--- an efterlysning and a husrannsakan are both coercive decisions a court may
--- later be asked about, and one sequence per agency per year is easier to
--- quote than two that interleave.
function Repo.numberPrefix()
    return ('W%s-'):format(os.date('%y')), 5
end

local TVANG_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, kind,
           target_kind AS targetKind, target_id AS targetId,
           target_label AS targetLabel, fu_id AS fuId,
           decided_by AS decidedBy, decider_kind AS deciderKind,
           grund, scope,
           UNIX_TIMESTAMP(valid_from)    AS validFrom,
           UNIX_TIMESTAMP(valid_until)   AS validUntil,
           UNIX_TIMESTAMP(verkstalld_at) AS verkstalldAt,
           verkstalld_by AS verkstalldBy, verkstalld_note AS verkstalldNote,
           UNIX_TIMESTAMP(upphavd_at)    AS upphavdAt,
           upphavd_by AS upphavdBy,
           classification, version
      FROM fpd_tvangsmedel
]]

local EFTER_SELECT <const> = [[
    SELECT e.id, e.agency_id AS agencyId, e.number, e.person_id AS personId,
           e.grund, e.frihet_id AS frihetId, e.fu_id AS fuId,
           e.note, e.priority,
           e.issued_by AS issuedBy,
           UNIX_TIMESTAMP(e.issued_at)    AS issuedAt,
           UNIX_TIMESTAMP(e.expires_at)   AS expiresAt,
           UNIX_TIMESTAMP(e.cancelled_at) AS cancelledAt,
           e.cancelled_by AS cancelledBy, e.cancelled_grund AS cancelledGrund,
           e.classification, e.version,
           p.person_number AS personNumber
      FROM fpd_efterlysning e
      JOIN fpd_persons p ON p.id = e.person_id
]]

--- The same columns, minus `scope` and `verkstalld_note`.
---
--- A tvångsmedel list row is a line in a table: kind, target, ground and
--- validity. Neither field is drawn there -- `Tvang.svelte` reads both only
--- from `tvang.get`'s detail view -- so `tvang.list` fetching them is bytes
--- read from every row in the agency's history to draw fifty that never show
--- them, the same waste 0013 measured and fixed for `handelseforlopp`.
local TVANG_LIST_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, kind,
           target_kind AS targetKind, target_id AS targetId,
           target_label AS targetLabel, fu_id AS fuId,
           decided_by AS decidedBy, decider_kind AS deciderKind,
           grund,
           UNIX_TIMESTAMP(valid_from)    AS validFrom,
           UNIX_TIMESTAMP(valid_until)   AS validUntil,
           UNIX_TIMESTAMP(verkstalld_at) AS verkstalldAt,
           verkstalld_by AS verkstalldBy,
           UNIX_TIMESTAMP(upphavd_at)    AS upphavdAt,
           upphavd_by AS upphavdBy,
           classification, version
      FROM fpd_tvangsmedel
]]

--- The same columns, minus `note`.
---
--- Mirrors `TVANG_LIST_SELECT` for the same reason: `Efterlysning.svelte`
--- reads `note` only from the create form and the detail view, never a row.
local EFTER_LIST_SELECT <const> = [[
    SELECT e.id, e.agency_id AS agencyId, e.number, e.person_id AS personId,
           e.grund, e.frihet_id AS frihetId, e.fu_id AS fuId,
           e.priority,
           e.issued_by AS issuedBy,
           UNIX_TIMESTAMP(e.issued_at)    AS issuedAt,
           UNIX_TIMESTAMP(e.expires_at)   AS expiresAt,
           UNIX_TIMESTAMP(e.cancelled_at) AS cancelledAt,
           e.cancelled_by AS cancelledBy, e.cancelled_grund AS cancelledGrund,
           e.classification, e.version,
           p.person_number AS personNumber
      FROM fpd_efterlysning e
      JOIN fpd_persons p ON p.id = e.person_id
]]

-- -----------------------------------------------------------------------------
-- Tvångsmedel
-- -----------------------------------------------------------------------------

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        TVANG_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- Every measure for one target that has not already expired.
---
--- What the spec 14 export reads, through `idx_fpd_tvang_valid`. The expiry is
--- filtered in SQL because it is indexed and there may be years of lapsed
--- decisions; revocation is left to the service, because `Tvang.isValid` is the
--- one definition of "live" and a second copy of it in a WHERE clause is how
--- the two come to disagree.
function Repo.forTarget(agencyId, targetKind, targetId)
    return FredPD.Core.db.query(
        TVANG_SELECT .. [[ WHERE agency_id = ? AND target_kind = ? AND target_id = ?
                             AND valid_until > CURRENT_TIMESTAMP(3)
                           ORDER BY valid_until DESC]],
        { agencyId, targetKind, targetId })
end

--- Across every agency, for the spec 14 export.
---
--- A door script asking `HasSearchWarrant('address', 12)` has no agency to give
--- and should not need one: the question it is asking is whether *anything*
--- authorises this entry, and a measure decided by one department is not void
--- because a second department exists on the server.
function Repo.forTargetAnyAgency(targetKind, targetId)
    return FredPD.Core.db.query(
        TVANG_SELECT .. [[ WHERE target_kind = ? AND target_id = ?
                             AND valid_until > CURRENT_TIMESTAMP(3)
                           ORDER BY valid_until DESC]],
        { targetKind, targetId })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.kind then
        clauses[#clauses + 1] = 'kind = ?'
        values[#values + 1] = filter.kind
    end

    if filter.fuId then
        clauses[#clauses + 1] = 'fu_id = ?'
        values[#values + 1] = filter.fuId
    end

    if filter.liveOnly then
        clauses[#clauses + 1] = 'upphavd_at IS NULL AND valid_until > CURRENT_TIMESTAMP(3)'
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        TVANG_LIST_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY created_at DESC LIMIT ?',
        values)
end

--- Records a decision, with its number allocated under the counter lock.
function Repo.create(input, session, validSeconds)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'warrant', session.agencyId)
    local base = #values

    -- By index: `fu_id`, `target_label` and `scope` are each nil on some
    -- ordinary decision, and a nil appended to an oxmysql values list shifts
    -- every parameter after it.
    values[base + 1] = session.agencyId
    values[base + 2] = input.kind
    values[base + 3] = input.targetKind
    values[base + 4] = input.targetId
    values[base + 5] = input.targetLabel
    values[base + 6] = input.fuId
    values[base + 7] = session.discordId
    values[base + 8] = input.deciderKind
    values[base + 9] = input.grund
    values[base + 10] = input.scope
    values[base + 11] = validSeconds
    values[base + 12] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'warrant', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_tvangsmedel
                              (number, agency_id, kind, target_kind, target_id,
                               target_label, fu_id, decided_by, decider_kind,
                               grund, scope, valid_from, valid_until, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?,
                                  ?, ?, ?, ?,
                                  ?, ?, CURRENT_TIMESTAMP(3),
                                  DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND), ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        TVANG_SELECT .. ' WHERE agency_id = ? AND decided_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

--- Records that a measure was carried out.
---
--- Deliberately **not** a state change: the measure stays valid, because RB
--- allows a husrannsakan to be resumed. `verkstalld_at IS NULL` in the WHERE
--- keeps the first execution the recorded one, for the same reason
--- `Repo.underratta` does in the frihet module.
function Repo.verkstall(id, agencyId, discordId, note)
    return FredPD.Core.db.execute([[
        UPDATE fpd_tvangsmedel
           SET verkstalld_at = CURRENT_TIMESTAMP(3), verkstalld_by = ?,
               verkstalld_note = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND verkstalld_at IS NULL]],
        { discordId, note, id, agencyId })
end

--- Revokes a measure. Overrides the window from this instant.
function Repo.upphav(id, agencyId, discordId, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_tvangsmedel
           SET upphavd_at = CURRENT_TIMESTAMP(3), upphavd_by = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND upphavd_at IS NULL]],
        { discordId, id, agencyId, expectedVersion })
end

-- -----------------------------------------------------------------------------
-- Efterlysning
-- -----------------------------------------------------------------------------

function Repo.efterlysningById(id, agencyId)
    return FredPD.Core.db.single(
        EFTER_SELECT .. ' WHERE e.id = ? AND e.agency_id = ?', { id, agencyId })
end

--- Every efterlysning on one person that has not been cancelled.
---
--- The hot-file read (7.2), through `idx_fpd_efterlysning_live`. Expiry is left
--- to `Tvang.isLive` rather than filtered here, because a null expiry means
--- "stands until cancelled" and expressing that in SQL alongside the indexed
--- comparison is how the two definitions drift apart.
function Repo.forPerson(personId)
    return FredPD.Core.db.query(
        EFTER_SELECT .. ' WHERE e.person_id = ? AND e.cancelled_at IS NULL ORDER BY e.priority, e.id',
        { personId })
end

function Repo.efterlysningList(agencyId, filter, limit)
    local clauses = { 'e.agency_id = ?' }
    local values = { agencyId }

    if filter.grund then
        clauses[#clauses + 1] = 'e.grund = ?'
        values[#values + 1] = filter.grund
    end

    if not filter.includeCancelled then
        clauses[#clauses + 1] = 'e.cancelled_at IS NULL'

        -- The expiry too, NULL-safe. Left out entirely at first, on the
        -- grounds that a NULL means "stands until lifted" and expressing that
        -- alongside the indexed comparison is how two definitions of "live"
        -- drift apart. Measured at 50k notices, that read every notice the
        -- agency had ever issued -- 56 ms of it -- to draw fifty, because
        -- `cancelled_at IS NULL` alone removes a quarter of the table.
        --
        -- `Tvang.isLive` is still the one definition; this is the same
        -- question asked in SQL so the rows never leave the database, and the
        -- `OR ... IS NULL` is what keeps a prosecutor's standing decision in
        -- the answer.
        clauses[#clauses + 1] = '(e.expires_at IS NULL OR e.expires_at > CURRENT_TIMESTAMP(3))'
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        EFTER_LIST_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY e.priority, e.issued_at DESC LIMIT ?',
        values)
end

function Repo.efterlys(input, session)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'warrant', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.personId
    values[base + 3] = input.grund
    values[base + 4] = input.frihetId
    values[base + 5] = input.fuId
    values[base + 6] = input.note
    values[base + 7] = input.priority or 3
    values[base + 8] = session.discordId
    values[base + 9] = input.expiresInSeconds
    values[base + 10] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'warrant', session.agencyId, nil, {
            {
                -- A null `expiresInSeconds` gives a null expiry, which means
                -- "stands until cancelled". `DATE_ADD` on a NULL interval is
                -- NULL, so the arithmetic carries the intent without a branch.
                query = [[INSERT INTO fpd_efterlysning
                              (number, agency_id, person_id, grund, frihet_id, fu_id,
                               note, priority, issued_by, expires_at, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?,
                                  ?, ?, ?,
                                  DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND), ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        EFTER_SELECT .. ' WHERE e.agency_id = ? AND e.issued_by = ? ORDER BY e.id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

function Repo.cancel(id, agencyId, discordId, grund, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_efterlysning
           SET cancelled_at = CURRENT_TIMESTAMP(3), cancelled_by = ?,
               cancelled_grund = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND cancelled_at IS NULL]],
        { discordId, grund, id, agencyId, expectedVersion })
end

--- Cancels every live efterlysning on a person, for one reason.
---
--- Called when somebody wanted is taken into custody: the gripande is what the
--- efterlysning existed to produce, and leaving it live afterwards means the
--- next officer to run them gets a red banner for somebody already in a cell.
--- 7.13 asks for exactly this ("auto-resolve on arrest").
function Repo.cancelForPerson(personId, discordId, grund)
    return FredPD.Core.db.execute([[
        UPDATE fpd_efterlysning
           SET cancelled_at = CURRENT_TIMESTAMP(3), cancelled_by = ?,
               cancelled_grund = ?, version = version + 1
         WHERE person_id = ? AND cancelled_at IS NULL]],
        { discordId, grund, personId })
end

FredPD.Repo.tvangsmedel = Repo
