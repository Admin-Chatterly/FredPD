--- Evidence, custody and lab SQL (spec 8). Parameterized only (invariant 8).
---
--- Two rules shape every query in this file.
---
--- **Nothing here selects hidden truth into a shape a route returns.** The
--- owner, the biometric profiles and the barrel signatures are read by exactly
--- one function, `hiddenFacts`, whose result exists to be turned into a result
--- code and thrown away (8.1, 8.11). Every other read names its columns, and
--- none of them names those tables. There is no `SELECT *` in this file for
--- that reason.
---
--- **Record numbers are allocated by the database, in the statement that uses
--- them.** The sequence is a `MAX` over the numbers that already exist for this
--- agency and year, read inside the same INSERT, so two officers collecting at
--- the same moment cannot be handed the same number. The unique index is the
--- backstop; this is what stops it being hit (invariant 1).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local function service()
    return FredPD.Modules.evidence
end

-- -----------------------------------------------------------------------------
-- Numbering
-- -----------------------------------------------------------------------------

--- The prefix and sequence width for this agency's numbers, this year.
---
--- The short name comes from the agency cache, never from input: it is half of
--- a record number, and a client that could choose it could write a number that
--- belongs to another agency.
---
--- @param kind string 'evidence' or 'scene'
--- @param agencyId string
--- @return string prefix
--- @return number width
local function numberPrefix(kind, agencyId)
    local agency = FredPD.Core.agencies.get(agencyId)
    local short = agency and agency.shortName or agencyId
    local year = tonumber(os.date('%Y'))

    return service().numberPrefix(kind, short, year)
end

--- A fresh opaque reference for an item (8.1.2).
---
--- 128 bits of randomness, and deliberately not derived from anything about the
--- owner: an item's metadata travels to clients inside ox_inventory, so a
--- reference that encoded who left the trace -- however well hashed -- would be
--- the leak the whole of section 8 is built to prevent.
local function newRef()
    local characters = {}

    for index = 1, 32 do
        characters[index] = ('%x'):format(math.random(0, 15))
    end

    return table.concat(characters)
end

-- -----------------------------------------------------------------------------
-- Scenes (8.4)
-- -----------------------------------------------------------------------------

local SCENE_COLUMNS <const> = [[
    s.id, s.scene_number AS sceneNumber, s.case_number AS caseNumber,
    s.x, s.y, s.z, s.radius, s.status,
    s.created_by AS createdBy, s.created_at AS createdAt,
    s.released_by AS releasedBy, s.released_at AS releasedAt
]]

--- Opens a scene and gives it its number.
---
--- `INSERT ... SELECT` over a derived table rather than a read followed by a
--- write: the `MAX` and the insert are one statement, so the sequence cannot be
--- taken twice. An aggregate with no `GROUP BY` returns exactly one row even
--- when the table is empty, which is what makes the first scene of the year
--- number 1 rather than inserting nothing.
---
--- Both conditions on the sequence scan are deliberate. The prefix carries the
--- agency and the year, so it is the real filter; `agency_id` keeps the scan on
--- this agency's rows even if a short name ever contained a LIKE wildcard, which
--- could then only widen the MAX and skip a number, never repeat one.
---
--- @return number|nil scene id
function Repo.createScene(agencyId, input, discordId)
    local prefix, width = numberPrefix('scene', agencyId)

    return db().insert(
        [[INSERT INTO fpd_scenes
              (scene_number, agency_id, case_number, x, y, z, radius, created_by)
          SELECT CONCAT(?, LPAD(COALESCE(MAX(existing.sequence), 0) + 1, ?, '0')),
                 ?, ?, ?, ?, ?, ?, ?
            FROM (SELECT CAST(SUBSTRING_INDEX(scene_number, '-', -1) AS UNSIGNED) AS sequence
                    FROM fpd_scenes
                   WHERE agency_id = ? AND scene_number LIKE ?) AS existing]],
        {
            prefix, width,
            agencyId, input.caseNumber, input.x, input.y, input.z, input.radius, discordId,
            agencyId, prefix .. '%',
        }
    )
end

function Repo.getScene(agencyId, id)
    return db().single(
        ([[SELECT %s FROM fpd_scenes s WHERE s.agency_id = ? AND s.id = ?]]):format(SCENE_COLUMNS),
        { agencyId, id }
    )
end

--- Releases a scene, once.
---
--- The `status = 'open'` in the WHERE clause is what makes it once: a second
--- release affects no rows and the route reports a conflict, rather than
--- overwriting who released it and when.
function Repo.releaseScene(agencyId, id, discordId)
    return db().execute(
        [[UPDATE fpd_scenes
             SET status = 'released', released_by = ?, released_at = CURRENT_TIMESTAMP(3)
           WHERE agency_id = ? AND id = ? AND status = 'open']],
        { discordId, agencyId, id }
    )
end

function Repo.listScenes(agencyId, filter)
    local where = { 's.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        where[#where + 1] = 's.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.caseNumber then
        where[#where + 1] = 's.case_number = ?'
        values[#values + 1] = filter.caseNumber
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT %s,
                  (SELECT COUNT(*) FROM fpd_evidence e WHERE e.scene_id = s.id) AS evidenceCount,
                  (SELECT COUNT(*) FROM fpd_scene_entries n WHERE n.scene_id = s.id) AS entryCount
             FROM fpd_scenes s
            WHERE %s
            ORDER BY s.created_at DESC
            LIMIT ?]]):format(SCENE_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

--- How many people walked into the perimeter without protective equipment.
---
--- Contamination is computed from the entry log rather than stored on the item,
--- so an officer who tramples a scene after collection still shows up in the
--- lab result of everything taken from it (8.4).
function Repo.unprotectedEntries(sceneId)
    if not sceneId then return 0 end

    return db().scalar(
        'SELECT COUNT(*) FROM fpd_scene_entries WHERE scene_id = ? AND protected = 0',
        { sceneId }
    ) or 0
end

-- -----------------------------------------------------------------------------
-- Evidence (8.2, 8.5)
-- -----------------------------------------------------------------------------

--- Columns a client may be shown, named one by one.
---
--- `quality` is absent, and so is anything from `fpd_evidence_owner`. The route
--- still puts every row through `service.public()`; this is the same rule
--- enforced a second time, at the point where a careless `SELECT *` would
--- otherwise be the whole leak.
local EVIDENCE_COLUMNS <const> = [[
    e.id, e.ref, e.evidence_number AS evidenceNumber, e.type, e.packaging,
    e.seal_state AS sealState, e.marker_number AS markerNumber, e.description,
    e.case_number AS caseNumber, e.scene_id AS sceneId,
    e.collected_at AS collectedAt, e.storage_location AS storageLocation, e.status
]]

--- Writes an item, its hidden owner and the first link in its custody chain.
---
--- One transaction, because the three are one fact: an item with no owner row
--- can never be analysed, and an item with no custody row has a chain that
--- starts nowhere -- which is exactly the defect that makes evidence
--- inadmissible (8.6). Rolling all three back together is the only outcome that
--- leaves the database describing something that could have happened.
---
--- The owner and custody rows find the item by its `ref` rather than
--- `LAST_INSERT_ID()`: the reference is unique and generated here, so the link
--- is explicit and survives anyone reordering these statements later.
---
--- @param agencyId string
--- @param input table shaped by the route, never by the client
--- @param owner table { identifier, weaponSerial } -- hidden truth (8.1)
--- @param discordId string the collecting officer, from the session
--- @return table|nil the inserted row, public columns only
function Repo.insertEvidence(agencyId, input, owner, discordId)
    local prefix, width = numberPrefix('evidence', agencyId)
    local ref = newRef()

    local committed = db().transaction({
        {
            query = [[INSERT INTO fpd_evidence
                          (ref, evidence_number, agency_id, scene_id, case_number, type,
                           packaging, marker_number, description, quality, collected_by, status)
                      SELECT ?,
                             CONCAT(?, LPAD(COALESCE(MAX(existing.sequence), 0) + 1, ?, '0')),
                             ?, ?, ?, ?, ?, ?, ?, ?, ?, 'collected'
                        FROM (SELECT CAST(SUBSTRING_INDEX(evidence_number, '-', -1) AS UNSIGNED)
                                       AS sequence
                                FROM fpd_evidence
                               WHERE agency_id = ? AND evidence_number LIKE ?) AS existing]],
            values = {
                ref,
                prefix, width,
                agencyId, input.sceneId, input.caseNumber, input.type,
                input.packaging, input.markerNumber, input.description, input.quality, discordId,
                agencyId, prefix .. '%',
            },
        },

        {
            query = [[INSERT INTO fpd_evidence_owner (evidence_id, identifier, weapon_serial)
                      SELECT id, ?, ? FROM fpd_evidence WHERE ref = ?]],
            values = { owner.identifier, owner.weaponSerial, ref },
        },

        {
            query = [[INSERT INTO fpd_custody_log
                          (evidence_id, action, from_party, to_party, reason, signed_by)
                      SELECT id, 'collect', ?, ?, ?, ? FROM fpd_evidence WHERE ref = ?]],
            values = { input.fromParty, discordId, input.reason, discordId, ref },
        },
    })

    if not committed then return nil end

    return db().single(
        ([[SELECT %s FROM fpd_evidence e WHERE e.ref = ?]]):format(EVIDENCE_COLUMNS),
        { ref }
    )
end

function Repo.getEvidence(agencyId, id)
    return db().single(
        ([[SELECT %s FROM fpd_evidence e WHERE e.agency_id = ? AND e.id = ?]])
            :format(EVIDENCE_COLUMNS),
        { agencyId, id }
    )
end

--- The property room list. Every filter is optional; combining them narrows.
function Repo.listEvidence(agencyId, filter)
    local where = { 'e.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        where[#where + 1] = 'e.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.type then
        where[#where + 1] = 'e.type = ?'
        values[#values + 1] = filter.type
    end

    if filter.sceneId then
        where[#where + 1] = 'e.scene_id = ?'
        values[#values + 1] = filter.sceneId
    end

    if filter.caseNumber then
        where[#where + 1] = 'e.case_number = ?'
        values[#values + 1] = filter.caseNumber
    end

    if filter.search then
        where[#where + 1] = '(e.evidence_number LIKE ? OR LOWER(e.description) LIKE ?)'
        values[#values + 1] = '%' .. filter.search .. '%'
        values[#values + 1] = '%' .. filter.search .. '%'
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT %s FROM fpd_evidence e
            WHERE %s
            ORDER BY e.collected_at DESC
            LIMIT ?]]):format(EVIDENCE_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

--- How many of these ids are this agency's evidence.
---
--- Used to refuse a lab request naming an item that belongs to somebody else,
--- before anything is written (invariant 4).
function Repo.countEvidenceIn(agencyId, ids)
    if #ids == 0 then return 0 end

    local placeholders, values = {}, { agencyId }

    for index = 1, #ids do
        placeholders[index] = '?'
        values[#values + 1] = ids[index]
    end

    return db().scalar(
        ('SELECT COUNT(*) FROM fpd_evidence WHERE agency_id = ? AND id IN (%s)')
            :format(table.concat(placeholders, ',')),
        values
    ) or 0
end

--- Moves an item between states, and only from the states that allow it.
---
--- The column names are fixed in this query; `status` and `storageLocation` are
--- values, never identifiers, and the set of statuses a caller may ask for is
--- an allowlist in the route. The `IN` on the current status is the other half:
--- it is what makes an item checked out to court un-intakeable without somebody
--- checking it back in first.
---
--- @param fromStatuses table list of statuses this move is legal from
function Repo.setEvidenceStatus(agencyId, id, status, storageLocation, fromStatuses)
    local placeholders = {}

    -- Positional assignment, not `#values + 1`: `storageLocation` is often nil,
    -- and appending after a nil would silently fill its slot and shift every
    -- parameter after it by one.
    local values = { status, storageLocation, agencyId, id }

    for index = 1, #fromStatuses do
        placeholders[index] = '?'
        values[4 + index] = fromStatuses[index]
    end

    return db().execute(
        ([[UPDATE fpd_evidence
              SET status = ?, storage_location = COALESCE(?, storage_location)
            WHERE agency_id = ? AND id = ? AND status IN (%s)]])
            :format(table.concat(placeholders, ',')),
        values
    )
end

-- -----------------------------------------------------------------------------
-- Chain of custody (8.6)
-- -----------------------------------------------------------------------------

--- Appends to the chain. There is no update and no delete anywhere in this file
--- for `fpd_custody_log`, and there must never be one: a custody record that can
--- be edited afterwards is worth nothing in court.
---
--- @param entry table { evidenceId, action, fromParty, toParty, reason }
--- @param discordId string the signature, from the session (8.6)
function Repo.appendCustody(entry, discordId)
    return db().insert(
        [[INSERT INTO fpd_custody_log
              (evidence_id, action, from_party, to_party, reason, signed_by)
          VALUES (?, ?, ?, ?, ?, ?)]],
        { entry.evidenceId, entry.action, entry.fromParty, entry.toParty, entry.reason, discordId }
    )
end

--- The whole chain for an item, oldest first, because that is the order it is
--- read aloud in.
function Repo.custodyFor(evidenceId)
    return db().query(
        [[SELECT id, action, from_party AS fromParty, to_party AS toParty,
                 reason, signed_by AS signedBy, occurred_at AS occurredAt
            FROM fpd_custody_log
           WHERE evidence_id = ?
           ORDER BY occurred_at, id]],
        { evidenceId }
    )
end

--- Who holds the item now, according to the chain rather than according to the
--- client asking to move it.
function Repo.currentHolder(evidenceId)
    return db().scalar(
        'SELECT to_party FROM fpd_custody_log WHERE evidence_id = ? ORDER BY occurred_at DESC, id DESC LIMIT 1',
        { evidenceId }
    )
end

-- -----------------------------------------------------------------------------
-- The lab (8.7)
-- -----------------------------------------------------------------------------

--- Creates a request and every analysis it asks for, in one transaction.
---
--- The analyses are one multi-row INSERT so they can all use `LAST_INSERT_ID()`:
--- inside a single statement it still holds the value the previous statement
--- set, which is the request that was just written. Splitting them into one
--- statement per row would make the second row point at the first analysis
--- instead.
---
--- @param pairsList table list of { evidenceId, analysis }
--- @return number|nil request id
function Repo.createLabRequest(agencyId, input, pairsList, discordId)
    if #pairsList == 0 then return nil end

    local rows, values = {}, {}

    for index = 1, #pairsList do
        rows[index] = '(LAST_INSERT_ID(), ?, ?)'
        values[#values + 1] = pairsList[index].evidenceId
        values[#values + 1] = pairsList[index].analysis
    end

    local committed = db().transaction({
        {
            query = [[INSERT INTO fpd_lab_requests
                          (agency_id, case_number, priority, justification, requested_by)
                      VALUES (?, ?, ?, ?, ?)]],
            values = { agencyId, input.caseNumber, input.priority, input.justification, discordId },
        },
        {
            query = ('INSERT INTO fpd_lab_analyses (request_id, evidence_id, analysis) VALUES %s')
                :format(table.concat(rows, ', ')),
            values = values,
        },
    })

    if not committed then return nil end

    -- Read back rather than returned by the transaction, which reports only
    -- whether it committed. Scoped to the officer who just wrote it: one Discord
    -- account holds one session, so nobody else can have interleaved a request
    -- under this signature.
    return db().scalar(
        [[SELECT id FROM fpd_lab_requests
           WHERE agency_id = ? AND requested_by = ?
           ORDER BY id DESC LIMIT 1]],
        { agencyId, discordId }
    )
end

local ANALYSIS_COLUMNS <const> = [[
    a.id, a.request_id AS requestId, a.evidence_id AS evidenceId,
    a.analysis, a.status, a.assigned_to AS assignedTo,
    a.started_at AS startedAt, a.due_at AS dueAt, a.completed_at AS completedAt,
    a.result_code AS resultCode, a.observations,
    r.priority, r.case_number AS caseNumber,
    e.evidence_number AS evidenceNumber
]]

--- The queue, agency-scoped through the request the analysis belongs to.
---
--- Urgent before expedited before routine, then oldest first, which is the order
--- a lab actually works in. The join onto `fpd_evidence` reaches for the
--- evidence number and nothing else -- never the owner table beside it.
function Repo.labQueue(agencyId, filter)
    local where = { 'r.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        where[#where + 1] = 'a.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.analysis then
        where[#where + 1] = 'a.analysis = ?'
        values[#values + 1] = filter.analysis
    end

    if filter.mine then
        where[#where + 1] = 'a.assigned_to = ?'
        values[#values + 1] = filter.mine
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT %s
             FROM fpd_lab_analyses a
             JOIN fpd_lab_requests r ON r.id = a.request_id
             JOIN fpd_evidence e ON e.id = a.evidence_id
            WHERE %s
            ORDER BY FIELD(r.priority, 'urgent', 'expedited', 'routine'), r.requested_at, a.id
            LIMIT ?]]):format(ANALYSIS_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

function Repo.getAnalysis(agencyId, id)
    return db().single(
        ([[SELECT %s
             FROM fpd_lab_analyses a
             JOIN fpd_lab_requests r ON r.id = a.request_id
             JOIN fpd_evidence e ON e.id = a.evidence_id
            WHERE r.agency_id = ? AND a.id = ?]]):format(ANALYSIS_COLUMNS),
        { agencyId, id }
    )
end

function Repo.analysesForEvidence(agencyId, evidenceId)
    return db().query(
        ([[SELECT %s
             FROM fpd_lab_analyses a
             JOIN fpd_lab_requests r ON r.id = a.request_id
             JOIN fpd_evidence e ON e.id = a.evidence_id
            WHERE r.agency_id = ? AND a.evidence_id = ?
            ORDER BY a.id]]):format(ANALYSIS_COLUMNS),
        { agencyId, evidenceId }
    )
end

--- Takes an analysis off the queue and starts its clock.
---
--- `due_at` is written as a timestamp rather than counted down in memory, so a
--- restart does not reset every timer in the lab (8.7). The `status = 'queued'`
--- condition makes starting it twice impossible, which is also what stops two
--- analysts claiming the same work.
function Repo.startAnalysis(agencyId, id, discordId, turnaroundSeconds)
    local committed = db().transaction({
        {
            query = [[UPDATE fpd_lab_analyses a
                        JOIN fpd_lab_requests r ON r.id = a.request_id
                         SET a.status = 'in_progress',
                             a.assigned_to = ?,
                             a.started_at = CURRENT_TIMESTAMP(3),
                             a.due_at = CURRENT_TIMESTAMP(3) + INTERVAL ? SECOND
                       WHERE a.id = ? AND a.status = 'queued' AND r.agency_id = ?]],
            values = { discordId, turnaroundSeconds, id, agencyId },
        },
        {
            query = [[UPDATE fpd_lab_requests
                         SET status = 'in_progress'
                       WHERE id = (SELECT request_id FROM fpd_lab_analyses WHERE id = ?)
                         AND agency_id = ? AND status = 'queued']],
            values = { id, agencyId },
        },
    })

    if not committed then return 0 end

    return db().scalar(
        [[SELECT COUNT(*) FROM fpd_lab_analyses a
            JOIN fpd_lab_requests r ON r.id = a.request_id
           WHERE a.id = ? AND r.agency_id = ? AND a.status = 'in_progress' AND a.assigned_to = ?]],
        { id, agencyId, discordId }
    ) or 0
end

--- Everything needed to compute a result, and nothing that may be returned.
---
--- This is the only function in FredPD that reads `fpd_evidence_owner`,
--- `fpd_biometrics` and `fpd_weapon_signatures`. Its result is hidden truth
--- (8.1): the route turns it into a result code and drops it. Nothing derived
--- from these columns may be put in a response, an audit detail or a push.
function Repo.hiddenFacts(agencyId, analysisId)
    return db().single(
        [[SELECT a.id, a.analysis, a.status, a.evidence_id AS evidenceId,
                 a.due_at AS dueAt, a.assigned_to AS assignedTo,
                 e.quality, e.scene_id AS sceneId,
                 o.identifier, o.weapon_serial AS weaponSerial,
                 b.dna_profile AS dnaProfile, b.fingerprint AS fingerprint,
                 w.barrel_signature AS barrelSignature
            FROM fpd_lab_analyses a
            JOIN fpd_lab_requests r ON r.id = a.request_id
            JOIN fpd_evidence e ON e.id = a.evidence_id
            LEFT JOIN fpd_evidence_owner o ON o.evidence_id = e.id
            LEFT JOIN fpd_biometrics b ON b.identifier = o.identifier
            LEFT JOIN fpd_weapon_signatures w ON w.serial = o.weapon_serial
           WHERE r.agency_id = ? AND a.id = ?]],
        { agencyId, analysisId }
    )
end

--- How many entries in an index carry this profile (8.8).
---
--- Equality on an opaque value: the comparison happens in the database and only
--- the count comes back, so no profile is ever in a Lua variable that a response
--- could accidentally carry. Expunged entries (`removed_at`) do not count --
--- that is what expungement means.
---
--- @param referencesOnly boolean true counts only entries that name a subject,
---   which is the difference between comparing against a reference and
---   searching the unsolved traces
function Repo.indexHits(agencyId, indexKind, profile, referencesOnly)
    if not profile then return 0 end

    local query = [[SELECT COUNT(*) FROM fpd_forensic_index
                     WHERE agency_id = ? AND index_kind = ? AND profile = ? AND removed_at IS NULL]]

    if referencesOnly then
        query = query .. ' AND identifier IS NOT NULL'
    end

    return db().scalar(query, { agencyId, indexKind, profile }) or 0
end

--- Files the profile a DNA analysis obtained in the trace index (8.8).
---
--- The profile is copied from `fpd_biometrics` to `fpd_forensic_index` inside
--- the statement, so the value never exists in a Lua variable and cannot be
--- carried into a response by accident -- the same rule `indexHits` follows in
--- the other direction.
---
--- What goes in is an *unidentified* crime-scene profile: `identifier` is left
--- NULL deliberately, because a trace entry that named its subject would turn
--- every later search into a lookup and make confirmation meaningless (8.1.3,
--- 8.8). The entry is tied to the item it came from, which is what gives the
--- profile its provenance and what the CHECK on the table requires.
---
--- Idempotent: an item already in the index is not filed twice, so a second
--- analysis of the same sample -- or a retry -- adds nothing.
---
--- @param indexKind string from `service.traceIndexFor`, never from input
--- @return number rows written
function Repo.indexTraceProfile(agencyId, evidenceId, indexKind, discordId)
    return db().execute(
        [[INSERT INTO fpd_forensic_index (index_kind, profile, evidence_id, agency_id, added_by)
          SELECT ?, b.dna_profile, e.id, e.agency_id, ?
            FROM fpd_evidence e
            JOIN fpd_evidence_owner o ON o.evidence_id = e.id
            JOIN fpd_biometrics b ON b.identifier = o.identifier
           WHERE e.id = ? AND e.agency_id = ?
             AND NOT EXISTS (SELECT 1 FROM fpd_forensic_index x
                              WHERE x.evidence_id = e.id
                                AND x.index_kind = ?
                                AND x.removed_at IS NULL)]],
        { indexKind, discordId, evidenceId, agencyId, indexKind }
    )
end

--- Why a completion wrote nothing.
---
--- `completeAnalysis` has three conditions in one UPDATE -- the row is this
--- agency's, it is still in progress, and its timer has elapsed -- so zero rows
--- alone does not say which of them failed. Asking afterwards is the only way
--- to tell an analyst whose work was cancelled from one who is early, and the
--- elapsed test is evaluated by the database so it is the same clock the UPDATE
--- used rather than a second opinion from Lua.
---
--- @return table|nil { status, elapsed } or nil when the analysis is not ours
function Repo.completionBlocker(agencyId, analysisId)
    return db().single(
        [[SELECT a.status,
                 (a.due_at IS NOT NULL AND a.due_at <= CURRENT_TIMESTAMP(3)) AS elapsed
            FROM fpd_lab_analyses a
            JOIN fpd_lab_requests r ON r.id = a.request_id
           WHERE r.agency_id = ? AND a.id = ?]],
        { agencyId, analysisId }
    )
end

--- Records the result and closes the request when nothing is left outstanding.
---
--- `due_at <= CURRENT_TIMESTAMP(3)` is in the WHERE clause rather than checked
--- in Lua on purpose: the turnaround is the mechanic (8.7, 4), and the database
--- is the only clock that cannot be argued with. An analyst whose timer has not
--- elapsed updates no rows and is told the analysis is not ready.
function Repo.completeAnalysis(agencyId, id, resultCode, observations)
    local committed = db().transaction({
        {
            query = [[UPDATE fpd_lab_analyses a
                        JOIN fpd_lab_requests r ON r.id = a.request_id
                         SET a.status = 'complete',
                             a.completed_at = CURRENT_TIMESTAMP(3),
                             a.result_code = ?,
                             a.observations = ?
                       WHERE a.id = ? AND a.status = 'in_progress'
                         AND a.due_at IS NOT NULL AND a.due_at <= CURRENT_TIMESTAMP(3)
                         AND r.agency_id = ?]],
            values = { resultCode, observations, id, agencyId },
        },
        {
            -- The correlated NOT EXISTS reads `fpd_lab_analyses`, which the
            -- statement above has already updated inside this transaction, so
            -- the analysis just completed is not counted as outstanding.
            query = [[UPDATE fpd_lab_requests r
                         SET r.status = 'complete'
                       WHERE r.id = (SELECT request_id FROM fpd_lab_analyses WHERE id = ?)
                         AND r.agency_id = ?
                         AND NOT EXISTS (SELECT 1 FROM fpd_lab_analyses o
                                          WHERE o.request_id = r.id
                                            AND o.status IN ('queued', 'in_progress'))]],
            values = { id, agencyId },
        },
    })

    if not committed then return 0 end

    return db().scalar(
        [[SELECT COUNT(*) FROM fpd_lab_analyses a
            JOIN fpd_lab_requests r ON r.id = a.request_id
           WHERE a.id = ? AND r.agency_id = ? AND a.status = 'complete' AND a.result_code = ?]],
        { id, agencyId, resultCode }
    ) or 0
end

FredPD.Repo.evidence = Repo
