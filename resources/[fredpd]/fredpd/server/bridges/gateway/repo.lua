--- The gateway outbox SQL (spec 3.7). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- @param kind string e.g. 'pdf.render'
--- @param payload table encoded as JSON
--- @return integer id
function Repo.enqueue(kind, payload)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_gateway_outbox (kind, payload) VALUES (?, ?)]],
        { kind, json.encode(payload) })
end

function Repo.remove(id)
    FredPD.Core.db.execute('DELETE FROM fpd_gateway_outbox WHERE id = ?', { id })
end

function Repo.recordFailure(id, reason)
    FredPD.Core.db.execute(
        [[UPDATE fpd_gateway_outbox
             SET attempts = attempts + 1, last_error = ?, last_attempt_at = CURRENT_TIMESTAMP(3)
           WHERE id = ?]],
        { reason, id })
end

--- Rows still worth retrying: under the attempt cap, and created within the
--- age cutoff.
--- @param maxAttempts integer
--- @param cutoffEpoch integer
function Repo.pending(maxAttempts, cutoffEpoch)
    local rows = FredPD.Core.db.query(
        [[SELECT id, kind, payload
            FROM fpd_gateway_outbox
           WHERE attempts < ? AND created_at >= FROM_UNIXTIME(?)
           ORDER BY id]],
        { maxAttempts, cutoffEpoch })

    for index = 1, #rows do
        local ok, decoded = pcall(json.decode, rows[index].payload)
        rows[index].payload = ok and decoded or {}
    end

    return rows
end

--- Rows that have exhausted their attempts or aged out -- given up on, not
--- retried again (the module header explains why).
function Repo.dropStale(maxAttempts, cutoffEpoch)
    FredPD.Core.db.execute(
        [[DELETE FROM fpd_gateway_outbox WHERE attempts >= ? OR created_at < FROM_UNIXTIME(?)]],
        { maxAttempts, cutoffEpoch })
end

FredPD.Repo.gatewayOutbox = Repo
