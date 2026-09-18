--- Record-level access: the SQL half (spec 4.5, invariants 4, 8 and 11).
---
--- `service.lua` decides; this file fetches what it decides on, and writes the
--- audit entry afterwards. Nothing here makes an access decision of its own.
---
--- Four rules shape every query below.
---
--- **No table name is ever interpolated.** Access control for every kind of
--- record lives in three generic tables keyed by `(record_type, record_id)` --
--- `fpd_record_compartments`, `fpd_record_grants`, `fpd_record_seals` -- plus
--- `fpd_breakglass`. The classification itself stays a column on the record's
--- own table (spec 13.1), where the owning module selects it as part of its
--- row and passes the row in. So this file never needs to know that a person
--- lives in `fpd_persons`, and there is no dynamic identifier anywhere in it.
---
--- **Everything is parameterized** (invariant 8). The one place SQL is built by
--- string is the `IN (?, ?, ?)` list, which is built out of placeholders and
--- never out of values, and the record type and subject type are checked
--- against fixed allowlists in this file before either reaches a statement.
---
--- **Reads are batched.** A search asks for its compartments, its seals and its
--- grants in three queries however many rows came back, because the alternative
--- is three queries per row and section 12's budget is 150 ms for a search.
---
--- **Restricted reads are audited** (invariant 11), including refusals, and the
--- audit entry records ids and counts -- never the contents of the record.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local function service()
    return FredPD.Modules.access
end

-- -----------------------------------------------------------------------------
-- Allowlists
-- -----------------------------------------------------------------------------

--- The record types that may appear in the generic tables.
---
--- A fixed list in code, not something a caller invents: `record_type` is half
--- of the key that access control hangs on, so a typo in it is a record whose
--- compartments are never found and therefore never enforced. A type missing
--- from here fails loudly at the call instead.
local RECORD_TYPES <const> = {
    person = true, vehicle = true, firearm = true, location = true,
    report = true, case = true, note = true, arrest = true, citation = true,
    warrant = true, bolo = true, evidence = true, scene = true,
    -- 7.12 and 7.13. `efterlysning` is its own type rather than sharing
    -- `warrant` with the coercive measures: the two tables have independent
    -- ids drawn from the same counter, so a grant on one would have opened the
    -- other. `spaning` likewise rather than sharing `bolo`, so the hit that
    -- names it and the record it is checked against agree.
    efterlysning = true, spaning = true,
    lab_request = true, intel_person = true, intel_org = true, intel_note = true,
    intel_case = true, surveillance = true, ia_case = true, uof_report = true,
}

--- Who a grant may be written for. `breakglass` is not here: a break-glass
--- entry is written to `fpd_breakglass` by `Repo.breakglass`, with its reason
--- and its own expiry, and only reaches the service as a grant on the way out.
local SUBJECT_TYPES <const> = { user = true, role = true }

--- How long break-glass access lasts, in minutes (4.5).
local BREAKGLASS_MINUTES <const> = 30

function Repo.isRecordType(recordType)
    return RECORD_TYPES[recordType] == true
end

--- Refuses anything that is not an allowlisted record type.
local function assertRecordType(recordType)
    assert(RECORD_TYPES[recordType], 'unknown record type: ' .. tostring(recordType))

    return recordType
end

--- `?, ?, ?` for a list of n values. Placeholders only -- no value is ever
--- concatenated into a statement (invariant 8).
local function placeholders(count)
    local marks = {}
    for index = 1, count do marks[index] = '?' end

    return table.concat(marks, ',')
end

--- The ids of a list of rows, and the rows keyed by id.
local function indexRows(rows)
    local ids, byId = {}, {}

    for index = 1, #rows do
        local row = rows[index]
        local id = row and row.id

        if id ~= nil then
            ids[#ids + 1] = id
            byId[id] = row
        end
    end

    return ids, byId
end

-- -----------------------------------------------------------------------------
-- Configuration (4.5: the stub policy is configurable per compartment)
-- -----------------------------------------------------------------------------

--- Loads the classification and compartment tables into the pure service.
---
--- Called at boot and after an administrator edits either. A row says whether a
--- record the reader cannot see is hidden or stubbed, and which unit the stub
--- names; the unit is a *key* the NUI translates (invariant 6), never a
--- sentence, which is why the column is `contact_unit` and not a label.
---
--- A failed or empty load leaves the shipped defaults in place rather than an
--- empty policy, because an empty policy table would stub nothing and hide
--- everything -- safe, but it would look like the records had vanished.
function Repo.reloadConfig()
    local compartmentRows = db().query(
        'SELECT `key`, stub_mode AS stubMode, contact_unit AS contactUnit FROM fpd_compartments WHERE enabled = 1'
    )
    local classificationRows = db().query('SELECT `level`, stub_mode AS stubMode FROM fpd_classifications')

    if #compartmentRows == 0 and #classificationRows == 0 then
        print('[fredpd] access: no classification or compartment rows, keeping the shipped policy')
        return
    end

    local compartments, classifications = {}, {}

    for index = 1, #compartmentRows do
        local row = compartmentRows[index]
        compartments[row.key] = { stub = row.stubMode == 'stub', contact = row.contactUnit }
    end

    for index = 1, #classificationRows do
        local row = classificationRows[index]
        classifications[row.level] = { stub = row.stubMode == 'stub' }
    end

    service().configure({
        compartments = #compartmentRows > 0 and compartments or nil,
        classifications = #classificationRows > 0 and classifications or nil,
    })

    print(('[fredpd] access: %d compartments, %d classification policies')
        :format(#compartmentRows, #classificationRows))
end

-- -----------------------------------------------------------------------------
-- The reader
-- -----------------------------------------------------------------------------

--- Builds the reader for a session (invariant 1).
---
--- Clearance and compartments come from the session's Discord-derived
--- permissions. The Discord role ids come from the same snapshot the permission
--- model reads, because a grant may name a role rather than a person -- "the
--- homicide unit may read this file" outlives whoever is in it this month.
---
--- @param session table
--- @param sharedAgencies table|nil agencies whose records this one may read
--- @return table reader
function Repo.reader(session, sharedAgencies)
    local roleIds = FredPD.Core.perms.memberRoles(session.discordId)

    return service().reader(session, {
        roleIds = roleIds,
        sharedAgencies = sharedAgencies,
        -- The database decides expiry (`> NOW(3)` below) and `os.time` decides
        -- it again in the service. Both clocks are this machine's, so they
        -- agree; the grant loader converts with TIMESTAMPDIFF rather than
        -- UNIX_TIMESTAMP so a server running on a non-UTC time zone cannot
        -- disagree with itself about when a grant lapses.
        now = os.time(),
    })
end

-- -----------------------------------------------------------------------------
-- Loading access control onto rows
-- -----------------------------------------------------------------------------

--- Attaches compartments and the sealed flag to every row, in two queries.
---
--- @param recordType string
--- @param rows table list of rows with an `id`
--- @return table the same rows
function Repo.attachControl(recordType, rows)
    assertRecordType(recordType)

    if type(rows) ~= 'table' or #rows == 0 then return rows or {} end

    local ids, byId = indexRows(rows)
    for index = 1, #rows do
        rows[index].compartments = {}
    end

    if #ids == 0 then return rows end

    local values = { recordType }
    for index = 1, #ids do values[#values + 1] = ids[index] end

    local compartmentRows = db().query(
        ([[SELECT record_id AS recordId, compartment
             FROM fpd_record_compartments
            WHERE record_type = ? AND record_id IN (%s)
            ORDER BY compartment]]):format(placeholders(#ids)),
        values
    )

    for index = 1, #compartmentRows do
        local row = byId[compartmentRows[index].recordId]
        if row then
            row.compartments[#row.compartments + 1] = compartmentRows[index].compartment
        end
    end

    -- A seal is a row, not a column: a record is sealed while an unlifted order
    -- exists for it, which is also what makes unsealing an append rather than a
    -- deletion.
    local sealRows = db().query(
        ([[SELECT record_id AS recordId
             FROM fpd_record_seals
            WHERE record_type = ? AND record_id IN (%s) AND lifted_at IS NULL]]):format(placeholders(#ids)),
        values
    )

    for index = 1, #sealRows do
        local row = byId[sealRows[index].recordId]
        if row then row.sealed = true end
    end

    return rows
end

--- Attaches the grants that could let *this* reader in, and no others.
---
--- The filter is in the WHERE clause on purpose. Loading every grant on a
--- record and matching in Lua would put the Discord ids of everyone else with
--- access on a row that is about to be sent to a client; here, a grant written
--- for somebody else never leaves the database.
---
--- @param reader table from `Repo.reader`
--- @param recordType string
--- @param rows table
--- @return table the same rows
function Repo.attachGrants(reader, recordType, rows)
    assertRecordType(recordType)

    if type(rows) ~= 'table' or #rows == 0 then return rows or {} end

    local ids, byId = indexRows(rows)
    for index = 1, #rows do
        rows[index].grants = {}
    end

    if #ids == 0 or not reader.discordId then return rows end

    local roleIds = reader.roleIds or {}
    local values = { recordType }
    for index = 1, #ids do values[#values + 1] = ids[index] end

    local subjectClause = '(g.subject_type = ? AND g.subject_id = ?)'
    values[#values + 1] = 'user'
    values[#values + 1] = reader.discordId

    if #roleIds > 0 then
        subjectClause = subjectClause .. (' OR (g.subject_type = ? AND g.subject_id IN (%s))')
            :format(placeholders(#roleIds))
        values[#values + 1] = 'role'
        for index = 1, #roleIds do values[#values + 1] = tostring(roleIds[index]) end
    end

    local grantRows = db().query(
        ([[SELECT g.record_id AS recordId, g.subject_type AS subjectType, g.subject_id AS subjectId,
                  TIMESTAMPDIFF(SECOND, NOW(3), g.expires_at) AS remaining
             FROM fpd_record_grants g
            WHERE g.record_type = ? AND g.record_id IN (%s)
              AND (g.expires_at IS NULL OR g.expires_at > NOW(3))
              AND (%s)]]):format(placeholders(#ids), subjectClause),
        values
    )

    for index = 1, #grantRows do
        local grant = grantRows[index]
        local row = byId[grant.recordId]

        if row then
            row.grants[#row.grants + 1] = {
                subjectType = grant.subjectType,
                subjectId = grant.subjectId,
                expiresAt = grant.remaining and (reader.now or os.time()) + grant.remaining or nil,
            }
        end
    end

    -- Break-glass: a live entry this reader took on this record is a grant to
    -- them alone, for the half hour it lasts (4.5).
    local breakglassValues = { reader.discordId, recordType }
    for index = 1, #ids do breakglassValues[#breakglassValues + 1] = ids[index] end

    local breakglassRows = db().query(
        ([[SELECT record_id AS recordId, TIMESTAMPDIFF(SECOND, NOW(3), expires_at) AS remaining
             FROM fpd_breakglass
            WHERE discord_id = ? AND record_type = ? AND record_id IN (%s) AND expires_at > NOW(3)]])
            :format(placeholders(#ids)),
        breakglassValues
    )

    for index = 1, #breakglassRows do
        local row = byId[breakglassRows[index].recordId]

        if row then
            row.grants[#row.grants + 1] = {
                subjectType = 'breakglass',
                subjectId = reader.discordId,
                expiresAt = (reader.now or os.time()) + (breakglassRows[index].remaining or 0),
            }
        end
    end

    return rows
end

--- Everything the service needs, on every row.
function Repo.prepare(reader, recordType, rows)
    return Repo.attachGrants(reader, recordType, Repo.attachControl(recordType, rows))
end

-- -----------------------------------------------------------------------------
-- The two functions the rest of the suite calls
-- -----------------------------------------------------------------------------

--- Audits a read of a restricted record (invariant 11).
---
--- The detail says what was read and how it was allowed. It never says what was
--- in it: an audit log that copies the record defeats the access control on the
--- record.
local function auditRead(session, recordType, recordId, outcome, detail)
    FredPD.Core.audit.write({
        action = 'access.read',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        outcome = outcome,
        detail = detail,
    })
end

--- One record, or nil when this session may not read it.
---
--- The caller selects its row however it likes -- it owns the table -- and
--- hands it here before returning it to anybody. The row comes back with its
--- access-control working fields resolved and the grant list stripped.
---
--- @param session table
--- @param recordType string one of the allowlist above
--- @param row table|nil the row as its own repo selected it
--- @param sharedAgencies table|nil
--- @return table|nil row
function Repo.read(session, recordType, row, sharedAgencies)
    if type(row) ~= 'table' then return nil end

    local reader = Repo.reader(session, sharedAgencies)
    Repo.prepare(reader, recordType, { row })

    local restricted = service().isRestricted(row)
    local allowed = service().canRead(reader, row)

    if restricted then
        auditRead(session, recordType, row.id, allowed and 'ok' or 'denied', {
            classification = row.classification,
            sealed = row.sealed == true,
            -- Which door it was opened with. A read allowed by a grant rather
            -- than by clearance is the one an auditor looks at first.
            viaGrant = allowed and (service().grantFor(reader, row) ~= nil) or false,
        })
    end

    if not allowed then return nil end

    -- One row goes through the same shaping as a list, so a single read and a
    -- search can never disagree about what a cleared reader is handed.
    local shaped = service().filterSearchResults(reader, { row })

    return shaped[1]
end

--- A list of rows, shaped by what this session may see (invariant 4).
---
--- This is the function that makes search safe. Rows the reader may not know
--- about are gone from the answer entirely -- no id, no name, no count -- and
--- rows in a stubbed compartment come back as the three-field stub.
---
--- The audit entry is one per search rather than one per row: a query that
--- touched forty restricted records would otherwise write forty rows to an
--- append-only table, and the question an audit answers here ("what did this
--- officer go looking through?") is answered by the list of ids.
---
--- @param session table
--- @param recordType string
--- @param rows table|nil
--- @param sharedAgencies table|nil
--- @return table rows
function Repo.filterSearch(session, recordType, rows, sharedAgencies)
    if type(rows) ~= 'table' or #rows == 0 then return {} end

    local reader = Repo.reader(session, sharedAgencies)
    Repo.prepare(reader, recordType, rows)

    local opened, refused = {}, 0

    for index = 1, #rows do
        local row = rows[index]

        if service().isRestricted(row) then
            if service().canRead(reader, row) then
                opened[#opened + 1] = row.id
            else
                refused = refused + 1
            end
        end
    end

    if #opened > 0 or refused > 0 then
        FredPD.Core.audit.write({
            action = 'access.search',
            discordId = session.discordId,
            agencyId = session.agencyId,
            subjectType = recordType,
            outcome = 'ok',
            detail = { opened = opened, refused = refused },
        })
    end

    return service().filterSearchResults(reader, rows)
end

-- -----------------------------------------------------------------------------
-- Writing access control
-- -----------------------------------------------------------------------------

--- Replaces the compartments on a record.
---
--- One transaction: a record that lost its old compartments and did not gain
--- its new ones is a record anybody can read, and the window in between is
--- exactly when a search would find it.
---
--- Every name is checked against the configured compartments first. An unknown
--- compartment would be enforced (the service hides what it cannot explain) but
--- never displayed, which is a record nobody can open and nobody can fix.
---
--- @return boolean committed
--- @return string|nil reason
function Repo.setCompartments(session, recordType, recordId, names)
    assertRecordType(recordType)

    local wanted = service().nameSet(names)
    local statements = {
        {
            query = 'DELETE FROM fpd_record_compartments WHERE record_type = ? AND record_id = ?',
            values = { recordType, recordId },
        },
    }

    local written = {}

    for name in pairs(wanted) do
        if not service().compartmentPolicy(name) then
            return false, 'unknown_compartment'
        end

        written[#written + 1] = name
        statements[#statements + 1] = {
            query = [[INSERT INTO fpd_record_compartments (record_type, record_id, compartment, created_by)
                      VALUES (?, ?, ?, ?)]],
            values = { recordType, recordId, name, session.discordId },
        }
    end

    table.sort(written)

    local committed = db().transaction(statements)

    if committed then
        FredPD.Core.audit.write({
            action = 'access.compartments.set',
            discordId = session.discordId,
            agencyId = session.agencyId,
            subjectType = recordType,
            subjectId = tostring(recordId),
            detail = { compartments = written },
        })
    end

    return committed
end

--- Grants one user or one Discord role access to one record, until `expiresAt`.
---
--- `expiresAt` is seconds from now, or nil for a grant that does not lapse. The
--- database computes the moment, so a client clock is not involved in when a
--- grant ends (invariant 1).
---
--- @return boolean written
--- @return string|nil reason
function Repo.grant(session, recordType, recordId, subjectType, subjectId, expiresIn)
    assertRecordType(recordType)

    if not SUBJECT_TYPES[subjectType] then return false, 'subject_type' end
    if type(subjectId) ~= 'string' or subjectId == '' then return false, 'subject_id' end

    -- 0 means "no expiry", and it travels instead of nil: a nil in an oxmysql
    -- values list silently shortens the list and shifts every placeholder after
    -- it, which here would write somebody else's id into `granted_by`.
    local seconds = tonumber(expiresIn) or 0

    db().execute(
        [[INSERT INTO fpd_record_grants
              (record_type, record_id, subject_type, subject_id, expires_at, granted_by)
          VALUES (?, ?, ?, ?, IF(? = 0, NULL, DATE_ADD(NOW(3), INTERVAL ? SECOND)), ?)
          ON DUPLICATE KEY UPDATE
              expires_at = VALUES(expires_at),
              granted_by = VALUES(granted_by),
              granted_at = NOW(3)]],
        {
            recordType, recordId, subjectType, subjectId,
            seconds, seconds, session.discordId,
        }
    )

    FredPD.Core.audit.write({
        action = 'access.grant',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        detail = { grantee = subjectId, granteeType = subjectType, expiresIn = expiresIn },
    })

    return true
end

--- Withdraws a grant. Deleting the row is the whole of it: the grant is an
--- allowance, and the audit log keeps the history of it having existed.
function Repo.revoke(session, recordType, recordId, subjectType, subjectId)
    assertRecordType(recordType)

    if not SUBJECT_TYPES[subjectType] then return false, 'subject_type' end

    local affected = db().execute(
        [[DELETE FROM fpd_record_grants
           WHERE record_type = ? AND record_id = ? AND subject_type = ? AND subject_id = ?]],
        { recordType, recordId, subjectType, subjectId }
    )

    FredPD.Core.audit.write({
        action = 'access.revoke',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        detail = { grantee = subjectId, granteeType = subjectType, removed = affected },
    })

    return affected > 0
end

--- Seals a record by court order (4.5).
---
--- An insert, so the order carries who made it, when, and under which case. A
--- second seal on an already-sealed record is refused rather than layered: the
--- unique key is on the live seal, and `IF NOT EXISTS`-style silence would hide
--- that two courts had sealed the same file.
function Repo.seal(session, recordType, recordId, caseNumber, reason)
    assertRecordType(recordType)

    local existing = db().scalar(
        [[SELECT id FROM fpd_record_seals
           WHERE record_type = ? AND record_id = ? AND lifted_at IS NULL LIMIT 1]],
        { recordType, recordId }
    )

    if existing then return false, 'already_sealed' end

    -- `NULLIF(?, '')` is how an absent case number or reason is stored: an empty
    -- string travels and MariaDB makes it NULL, because a nil in an oxmysql
    -- values list shifts every placeholder after it.
    db().insert(
        [[INSERT INTO fpd_record_seals (record_type, record_id, agency_id, case_number, reason, sealed_by)
          VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?)]],
        { recordType, recordId, session.agencyId, caseNumber or '', reason or '', session.discordId }
    )

    FredPD.Core.audit.write({
        action = 'access.seal',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        detail = { caseNumber = caseNumber },
    })

    return true
end

--- Lifts a seal. The row stays and is stamped, because a sealed file that was
--- later unsealed is a thing a court asks about.
function Repo.unseal(session, recordType, recordId, reason)
    assertRecordType(recordType)

    local affected = db().execute(
        [[UPDATE fpd_record_seals
             SET lifted_at = NOW(3), lifted_by = ?, lift_reason = NULLIF(?, '')
           WHERE record_type = ? AND record_id = ? AND lifted_at IS NULL]],
        { session.discordId, reason or '', recordType, recordId }
    )

    FredPD.Core.audit.write({
        action = 'access.unseal',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        outcome = affected > 0 and 'ok' or 'denied',
        detail = { reason = reason },
    })

    return affected > 0
end

--- Break-glass access to one restricted record, for thirty minutes (4.5).
---
--- The reason is required and is stored, because the reason is the control:
--- break-glass is not a permission to read everything, it is a permission to
--- read something now and answer for it afterwards. The entry is audited here;
--- notifying the record's owner and internal affairs happens in the route that
--- calls this, where there is a session to push to.
---
--- A sealed record is deliberately out of reach: a seal is a court order, and
--- an officer's written reason does not overrule one.
---
--- @return boolean taken
--- @return string|nil reason
function Repo.breakglass(session, recordType, recordId, reason)
    assertRecordType(recordType)

    if type(reason) ~= 'string' or #reason:gsub('%s', '') < 10 then
        return false, 'reason_required'
    end

    local sealed = db().scalar(
        [[SELECT id FROM fpd_record_seals
           WHERE record_type = ? AND record_id = ? AND lifted_at IS NULL LIMIT 1]],
        { recordType, recordId }
    )

    if sealed then
        FredPD.Core.audit.denied(session, 'access.breakglass', 'sealed', recordType, tostring(recordId))
        return false, 'sealed'
    end

    db().insert(
        [[INSERT INTO fpd_breakglass
              (discord_id, agency_id, record_type, record_id, reason, expires_at)
          VALUES (?, ?, ?, ?, ?, DATE_ADD(NOW(3), INTERVAL ? MINUTE))]],
        { session.discordId, session.agencyId, recordType, recordId, reason, BREAKGLASS_MINUTES }
    )

    FredPD.Core.audit.write({
        action = 'access.breakglass',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = recordType,
        subjectId = tostring(recordId),
        detail = { reason = reason, minutes = BREAKGLASS_MINUTES },
    })

    return true
end

--- Who currently holds access to a record, for the access panel on a file.
---
--- Read by the owning module behind its own permission. It names grantees, so
--- it is not part of a record's own payload -- `attachGrants` deliberately loads
--- only the reader's own grants for that reason.
function Repo.grantsOn(recordType, recordId)
    assertRecordType(recordType)

    return db().query(
        [[SELECT subject_type AS subjectType, subject_id AS subjectId,
                 granted_by AS grantedBy, granted_at AS grantedAt, expires_at AS expiresAt
            FROM fpd_record_grants
           WHERE record_type = ? AND record_id = ?
           ORDER BY granted_at DESC]],
        { recordType, recordId }
    )
end

FredPD.Repo.access = Repo
