--- Retention SQL (spec 13.3, ADR-021). Every statement is a fixed string;
--- the only values are day counts from `Retention.plan`, bound as interval
--- lengths (invariant 8). None of these ever touches `fpd_audit_log`
--- (invariant 11).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

--- The Discord-id column's stand-in for a sweep: `ck_fpd_spaning_resolved`
--- needs somebody, and the sweep is nobody.
local SYSTEM_ACTOR <const> = 'system:retention'

--- Rows per DELETE, and DELETEs per sweep per run. A first run on an install
--- that has kept a year of query logs would otherwise be one statement
--- holding locks on the table every search writes to; what is left over
--- goes on the next run.
local BATCH <const> = 5000
local MAX_BATCHES <const> = 20

--- Runs a `... LIMIT ?` DELETE until it comes back short.
local function batched(sql, params)
    local total = 0
    local bound = { table.unpack(params) }
    bound[#bound + 1] = BATCH

    for _ = 1, MAX_BATCHES do
        local affected = db().execute(sql, bound) or 0
        total = total + affected
        if affected < BATCH then break end
    end

    return total
end

--- Every agency, for the sweeps whose tables are indexed `(agency_id, time)`:
--- without the agency the range is not the index's, and the DELETE scans.
local function agencyIds()
    local ids = {}
    for index, row in ipairs(db().query('SELECT id FROM fpd_agencies', {}) or {}) do ids[index] = row.id end
    return ids
end

--- `batched` once per agency, the agency id bound first.
local function perAgency(sql, params)
    local total = 0
    for _, agencyId in ipairs(agencyIds()) do
        total = total + batched(sql, { agencyId, table.unpack(params) })
    end
    return total
end

--- 7.13: a lookout whose window ran out, never resolved otherwise.
function Repo.lapsedLookouts()
    return db().execute(
        [[UPDATE fpd_spaning
             SET resolved_at = CURRENT_TIMESTAMP(3), resolved_by = ?, resolved_grund = 'tiden_ute',
                 version = version + 1
           WHERE resolved_at IS NULL AND expires_at <= CURRENT_TIMESTAMP(3)]],
        { SYSTEM_ACTOR })
end

function Repo.queryLog(days)
    return perAgency(
        [[DELETE FROM fpd_query_log
           WHERE agency_id = ? AND created_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY) LIMIT ?]],
        { days })
end

function Repo.alprReads(days)
    return perAgency(
        [[DELETE FROM fpd_alpr_reads
           WHERE agency_id = ? AND read_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY) LIMIT ?]],
        { days })
end

--- A draft anmälan its author walked away from: `utkast`, not a
--- tilläggsuppgift, and old. One with a supervisor's return pending is not
--- a draft nobody wants (the gateway sweep's own reasoning, kept).
---
--- Nor one that has a tilläggsuppgift of its own: `fk_fpd_anmalan_parent`
--- is RESTRICT (0009), and a single such row in the set would fail the whole
--- DELETE on every run for ever. The parents are read through a derived
--- table, which is how MariaDB lets a DELETE look at its own table.
function Repo.staleDrafts(days)
    return batched(
        [[DELETE FROM fpd_anmalan
           WHERE status = 'utkast' AND parent_id IS NULL AND returned_at IS NULL
             AND created_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)
             AND id NOT IN (SELECT parent_id FROM (
                 SELECT DISTINCT parent_id FROM fpd_anmalan WHERE parent_id IS NOT NULL) AS parents)
           LIMIT ?]],
        { days })
end

--- Who listened, when: the telemetry ages out, the decision (`fpd_hak`) never.
function Repo.surveillanceSessions(days)
    return batched(
        [[DELETE FROM fpd_hak_sessions
           WHERE ended_at IS NOT NULL AND ended_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)
           LIMIT ?]],
        { days })
end

--- Stop data (7.14) is statistics; past its period the rows add nothing
--- the counts already said.
function Repo.stops(days)
    return perAgency(
        [[DELETE FROM fpd_stops
           WHERE agency_id = ? AND created_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY) LIMIT ?]],
        { days })
end

--- Uploads begun and never committed (ADR-019), oldest first.
function Repo.abandonedUploads(days, limit)
    return db().query(
        [[SELECT media_ref AS mediaRef FROM fpd_media
           WHERE status = 'pending' AND created_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)
           ORDER BY created_at LIMIT ?]],
        { days, limit })
end

--- Only rows still pending: one committed since the read is not abandoned.
function Repo.forgetUpload(mediaRef)
    return db().execute("DELETE FROM fpd_media WHERE media_ref = ? AND status = 'pending'", { mediaRef })
end

FredPD.Repo.retention = Repo
