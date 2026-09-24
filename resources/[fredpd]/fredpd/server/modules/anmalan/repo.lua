--- Anmälan och förundersökning SQL (spec 7.7, 7.8). Parameterized only
--- (invariant 8).
---
--- Three things here are transactions rather than statements, and each is a
--- transaction because the alternative has a failure mode that is silent:
---
---   * **`create`** allocates the record number under the counter lock
---     (ADR-012) in the same transaction as the insert, so a number handed out
---     to a row that was never written is impossible.
---   * **`transition`** moves the status and writes the version snapshot
---     together. A version table the service is trusted to write to separately
---     is a version table with gaps in it exactly where somebody took a
---     shortcut -- and those gaps are in the approvals.
---   * **`replaceCharges`** deletes and re-inserts the charge list as one unit,
---     so an anmälan is never briefly left with half its charges while another
---     session reads it.
---
--- There is **no delete path**, for an anmälan or for an FU. 7.7 says an
--- approved report is amended by a tilläggsuppgift and never edited; a delete
--- route would be the way around that, so it does not exist.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `{AGENCY}-{YY}-{######}`.
---
--- The prefix and the width live with the module that owns the record, the way
--- `Evidence.numberPrefix` does, so there is one definition of each format.
function Repo.anmalanPrefix(agencyId)
    return ('%s-%s-'):format(agencyId, os.date('%y')), 6
end

--- Appendix D: `{AGENCY}-C{YY}-{#####}`.
function Repo.fuPrefix(agencyId)
    return ('%s-C%s-'):format(agencyId, os.date('%y')), 5
end

local ANMALAN_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, parent_id AS parentId,
           fu_id AS fuId, call_id AS callId, title, status,
           handelseforlopp, occurred_at AS occurredAt, occurred_place AS occurredPlace,
           created_by AS createdBy, created_at AS createdAt,
           submitted_by AS submittedBy, submitted_at AS submittedAt,
           returned_by AS returnedBy, returned_at AS returnedAt,
           returned_note AS returnedNote,
           approved_by AS approvedBy, approved_at AS approvedAt,
           classification, version, updated_at AS updatedAt
      FROM fpd_anmalan
]]

--- The same columns, minus the händelseförlopp.
---
--- A list row is a line in a table: a number, a title, a status and a date.
--- `handelseforlopp` is the full Tiptap document -- kilobytes of editor JSON per
--- report -- and shipping fifty of them to draw fifty *titles* is the whole of
--- section 12's "never send the body to draw the list".
---
--- It is not only the wire. MariaDB has to read every matching row before it
--- can take the newest fifty, so the column is read for the agency's entire
--- history, not for the page: at 50k anmälningar that is 480 ms against 2.7 ms
--- with the blob left out (0013 carries the measurements and the index that
--- made the rest of the difference).
---
--- Deliberately a second constant rather than a column list assembled per call.
--- A caller that could choose its columns is a caller that can ask for the blob
--- by accident, and `anmalan.get` -- the one place the body *is* wanted -- has
--- `ANMALAN_SELECT` right there.
local ANMALAN_LIST_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, parent_id AS parentId,
           fu_id AS fuId, call_id AS callId, title, status,
           occurred_at AS occurredAt, occurred_place AS occurredPlace,
           created_by AS createdBy, created_at AS createdAt,
           submitted_by AS submittedBy, submitted_at AS submittedAt,
           returned_by AS returnedBy, returned_at AS returnedAt,
           returned_note AS returnedNote,
           approved_by AS approvedBy, approved_at AS approvedAt,
           classification, version, updated_at AS updatedAt,
           -- Cursor-only. `created_at` above is a DATETIME string, the shape
           -- this list has always sent; the keyset comparison needs a plain
           -- integer, and this column exists for that alone -- stripped off
           -- every row before it leaves `Repo.list` (spec 12.2).
           UNIX_TIMESTAMP(created_at) AS createdAtEpoch
      FROM fpd_anmalan
]]

local FU_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, title, status,
           fu_ledare AS fuLedare, ledare_kind AS ledareKind,
           intel_case_id AS intelCaseId,
           opened_by AS openedBy, opened_at AS openedAt,
           closed_by AS closedBy, closed_at AS closedAt,
           closed_reason AS closedReason, closed_note AS closedNote,
           classification, version, updated_at AS updatedAt,
           -- Cursor-only, for `Repo.fuList`'s keyset WHERE and nothing else
           -- (spec 12.2) -- the same reasoning `ANMALAN_LIST_SELECT`'s own
           -- `createdAtEpoch` gives, except FU has no separate list SELECT to
           -- keep it off of `fu.get`'s response, so it rides along there too.
           UNIX_TIMESTAMP(opened_at) AS openedAtEpoch
      FROM fpd_forundersokning
]]

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        ANMALAN_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.byNumber(number, agencyId)
    return FredPD.Core.db.single(
        ANMALAN_SELECT .. ' WHERE agency_id = ? AND number = ?', { agencyId, number })
end

--- The parent of one anmälan, as a bare id.
---
--- Exists for `Anmalan.parentIsAllowed`, which walks the chain and needs one
--- hop at a time. Deliberately not a join: the walk is bounded at
--- `Anmalan.MAX_CHAIN` and a recursive CTE here would be a second definition of
--- a rule the service already owns.
function Repo.parentOf(id, agencyId)
    return FredPD.Core.db.scalar(
        'SELECT parent_id FROM fpd_anmalan WHERE id = ? AND agency_id = ?',
        { id, agencyId })
end

--- The list behind the Records screen.
---
--- Filters are applied in SQL where they are indexed (`idx_fpd_anmalan_status`,
--- `idx_fpd_anmalan_author`) and the access check happens afterwards in the
--- route, through `access.filterSearch` -- which is invariant 4's order, not a
--- convenience: a LIMIT applied before the access filter would return a short
--- page and tell the reader there was no more.
--- Keyset-paginated on `(created_at, id)` descending (spec 12.2).
---
--- @param cursor string|nil the previous page's `nextCursor`
--- @return table rows
--- @return string|nil nextCursor set only when a further page exists
function Repo.list(agencyId, filter, limit, cursor)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        clauses[#clauses + 1] = 'status = ?'
        values[#values + 1] = filter.status
    end

    if filter.createdBy then
        clauses[#clauses + 1] = 'created_by = ?'
        values[#values + 1] = filter.createdBy
    end

    if filter.fuId then
        clauses[#clauses + 1] = 'fu_id = ?'
        values[#values + 1] = filter.fuId
    end

    -- Tilläggsuppgifter are hidden from the top-level list by default: they
    -- belong under their parent, and a flat list mixing them in reads as
    -- duplicates of reports the officer has already seen.
    if not filter.includeSupplements then
        clauses[#clauses + 1] = 'parent_id IS NULL'
    end

    local after = FredPD.Core.pagination.decode(cursor, 2)
    if after then
        clauses[#clauses + 1] =
            '(UNIX_TIMESTAMP(created_at) < ? OR (UNIX_TIMESTAMP(created_at) = ? AND id < ?))'
        values[#values + 1], values[#values + 1], values[#values + 1] = after[1], after[1], after[2]
    end

    values[#values + 1] = limit + 1

    local rows = FredPD.Core.db.query(
        ANMALAN_LIST_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY created_at DESC, id DESC LIMIT ?',
        values)

    local nextCursor = nil
    if #rows > limit then
        rows[limit + 1] = nil
        local last = rows[limit]
        nextCursor = FredPD.Core.pagination.encode({ last.createdAtEpoch, last.id })
    end

    -- `createdAtEpoch` was only ever for the line above.
    for index = 1, #rows do rows[index].createdAtEpoch = nil end

    return rows, nextCursor
end

--- The tilläggsuppgifter under one anmälan.
---
--- A list too, so it reads without the bodies. A supplement's own body arrives
--- through `anmalan.get` when somebody opens it -- which is also where its
--- access check is written down, and 4.5 wants that check on the record being
--- read rather than inherited from its parent.
function Repo.supplements(anmalanId, agencyId)
    return FredPD.Core.db.query(
        ANMALAN_LIST_SELECT .. ' WHERE parent_id = ? AND agency_id = ? ORDER BY created_at',
        { anmalanId, agencyId })
end

--- The charges on an anmälan, with the catalogue row each cites.
---
--- Joined rather than fetched separately, because a charge is meaningless
--- without its offence and every caller wants both. `b.*` is the version the
--- charge was written under, not the current one -- which is 7.10's rule
--- arriving here: the join is on `brott_id`, an immutable version row.
function Repo.charges(anmalanId)
    return FredPD.Core.db.query([[
        SELECT ab.id, ab.anmalan_id AS anmalanId, ab.brott_id AS brottId,
               ab.person_id AS personId, ab.stage, ab.note,
               b.code, b.version AS brottVersion, b.balk, b.kapitel, b.paragraf,
               b.label_key AS labelKey, b.grad, b.boter,
               b.fangelse_min_months AS fangelseMinMonths,
               b.fangelse_max_months AS fangelseMaxMonths
          FROM fpd_anmalan_brott ab
          JOIN fpd_brott b ON b.id = ab.brott_id
         WHERE ab.anmalan_id = ?
         ORDER BY ab.id]], { anmalanId })
end

function Repo.personer(anmalanId)
    return FredPD.Core.db.query([[
        SELECT ap.person_id AS personId, ap.roll, ap.note,
               p.person_number AS personNumber
          FROM fpd_anmalan_personer ap
          JOIN fpd_persons p ON p.id = ap.person_id
         WHERE ap.anmalan_id = ?
         ORDER BY ap.roll, ap.person_id]], { anmalanId })
end

--- The history of one anmälan: who signed what, and when.
---
--- **Without the snapshots.** Each one is the whole report as it read at that
--- transition -- charges, people and the händelseförlopp, denormalised on
--- purpose (see `Repo.transition`) -- so a report that has been returned and
--- resubmitted a few times carries tens of kilobytes per row, and a history
--- panel that lists "Inlämnad · 14:02 · Andersson" needs none of it.
---
--- `MAX_VERSIONS` bounds it because nothing else does: 7.7 keeps every version
--- forever and a report that a supervisor keeps sending back grows a row each
--- time. The newest are the ones somebody is looking for, and the rest are
--- still in the table for the audit that wants them.
---
--- Reading one snapshot back is a route that does not exist yet. When it does
--- it takes `(anmalanId, version)` and returns one row -- not this list with
--- the column added, which is how the payload gets back in.
local MAX_VERSIONS <const> = 50

function Repo.versions(anmalanId, limit)
    return FredPD.Core.db.query([[
        SELECT id, version, status, signed_by AS signedBy, signed_at AS signedAt
          FROM fpd_anmalan_versions
         WHERE anmalan_id = ?
         ORDER BY version DESC
         LIMIT ?]], { anmalanId, math.min(limit or MAX_VERSIONS, MAX_VERSIONS) })
end

-- -----------------------------------------------------------------------------
-- Writes
-- -----------------------------------------------------------------------------

--- Creates an anmälan and allocates its number in one transaction (ADR-012).
---
--- Returns the number rather than the id, because the number is what the
--- officer sees and what the next read is by. The id is fetched back with it:
--- `db.transaction` answers whether it committed, not what it inserted, so the
--- row is read by its unique `(agency_id, number)` afterwards.
function Repo.create(input, session)
    local prefix, width = Repo.anmalanPrefix(session.agencyId)
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'report', session.agencyId)

    -- The five values the number subquery consumes come first, because the
    -- number is the first column. The rest are written **by index** rather than
    -- appended, the way `Repo.createScene` does: `parent_id`, `fu_id` and
    -- `call_id` are nil on most anmälningar, and a nil appended to an oxmysql
    -- values list fills nothing and shifts every parameter after it -- which
    -- here would write the title into `call_id` and fail on a type nobody
    -- would connect to the missing field.
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.parentId
    values[base + 3] = input.fuId
    values[base + 4] = input.callId
    values[base + 5] = input.title
    values[base + 6] = input.handelseforlopp
    values[base + 7] = input.occurredAt
    values[base + 8] = input.occurredPlace
    values[base + 9] = session.discordId
    values[base + 10] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'report', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_anmalan
                              (number, agency_id, parent_id, fu_id, call_id, title,
                               handelseforlopp, occurred_at, occurred_place,
                               created_by, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?,
                                  ?, ?, ?, ?, ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    -- The number the counter had when the transaction ran. Read back rather
    -- than computed, because computing it would be a second implementation of
    -- the format and they would drift.
    return FredPD.Core.db.single(
        ANMALAN_SELECT .. ' WHERE agency_id = ? AND created_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

--- The columns an edit may write, and nothing else.
---
--- An allowlist rather than the input's keys, so a column name can never come
--- from a client (invariant 8). `status` is absent on purpose: a status moves
--- through `transition` and nowhere else, which is what keeps the version
--- snapshot and the status in step.
local UPDATABLE <const> = {
    title = 'title',
    handelseforlopp = 'handelseforlopp',
    occurredAt = 'occurred_at',
    occurredPlace = 'occurred_place',
    classification = 'classification',
    fuId = 'fu_id',
}

local UPDATE_ORDER <const> = {
    'title', 'handelseforlopp', 'occurredAt', 'occurredPlace', 'classification', 'fuId',
}

--- Updates the body of an anmälan, with optimistic locking.
---
--- The `version` in the WHERE is what turns "two officers edited the same draft"
--- into a refusal the second one can see, rather than a silent overwrite. A
--- zero row count means the version moved, which the route answers as
--- `conflict`.
function Repo.update(id, agencyId, input, expectedVersion)
    local assignments, values = {}, {}

    for index = 1, #UPDATE_ORDER do
        local field = UPDATE_ORDER[index]

        if input[field] ~= nil then
            assignments[#assignments + 1] = ('`%s` = ?'):format(UPDATABLE[field])
            values[#values + 1] = input[field]
        end
    end

    if #assignments == 0 then return 0 end

    assignments[#assignments + 1] = '`version` = `version` + 1'

    values[#values + 1] = id
    values[#values + 1] = agencyId
    values[#values + 1] = expectedVersion

    return FredPD.Core.db.execute(
        ('UPDATE fpd_anmalan SET %s WHERE id = ? AND agency_id = ? AND version = ?')
            :format(table.concat(assignments, ', ')),
        values)
end

--- The columns each transition stamps, beyond the status itself.
---
--- A table rather than three near-identical statements, so the set of
--- transitions here and the set in `Anmalan.nextStatus` can be read against
--- each other.
local STAMPS <const> = {
    inlamnad = { by = 'submitted_by', at = 'submitted_at' },
    atersand = { by = 'returned_by', at = 'returned_at' },
    godkand  = { by = 'approved_by', at = 'approved_at' },
}

--- Moves the status and writes the version snapshot, together.
---
--- The snapshot is the whole anmälan as it read at that moment, including its
--- charges and its people, denormalised on purpose: the point of a version is
--- to answer "what did this say when it was approved", and a version that
--- pointed at live rows would answer with what those rows say now.
---
--- @param id number
--- @param agencyId string
--- @param toStatus string from `Anmalan.nextStatus`
--- @param discordId string who made the transition
--- @param snapshot string the JSON body, built by the route
--- @param expectedVersion number
--- @param note string|nil the supervisor's reason, for a return
--- @return boolean committed
function Repo.transition(id, agencyId, toStatus, discordId, snapshot, expectedVersion, note)
    local stamp = STAMPS[toStatus]
    assert(stamp, 'no stamp for status: ' .. tostring(toStatus))

    local sets = {
        '`status` = ?',
        ('`%s` = ?'):format(stamp.by),
        ('`%s` = CURRENT_TIMESTAMP(3)'):format(stamp.at),
        '`version` = `version` + 1',
    }

    local values = { toStatus, discordId }

    -- Only a return carries a note, and it is cleared on the way back out:
    -- a returned_note still sitting on an approved anmälan reads as though the
    -- supervisor had objected to the version they approved.
    if toStatus == 'atersand' then
        sets[#sets + 1] = '`returned_note` = ?'
        values[#values + 1] = note
    elseif toStatus == 'inlamnad' then
        sets[#sets + 1] = '`returned_note` = NULL'
    end

    values[#values + 1] = id
    values[#values + 1] = agencyId
    values[#values + 1] = expectedVersion

    return FredPD.Core.db.transaction({
        {
            query = ('UPDATE fpd_anmalan SET %s WHERE id = ? AND agency_id = ? AND version = ?')
                :format(table.concat(sets, ', ')),
            values = values,
        },
        {
            -- The version number is read from the row the statement above just
            -- bumped, inside the same transaction, so a snapshot can never be
            -- filed under a version that does not exist.
            query = [[INSERT INTO fpd_anmalan_versions
                          (anmalan_id, version, status, snapshot, signed_by)
                      SELECT a.id, a.version, a.status, ?, ?
                        FROM fpd_anmalan a
                       WHERE a.id = ? AND a.agency_id = ?]],
            values = { snapshot, discordId, id, agencyId },
        },
    })
end

--- Replaces the charge list as one unit.
---
--- Delete-then-insert rather than a diff: a charge row carries no state of its
--- own -- no approval, no timestamp anybody reads -- so there is nothing for a
--- diff to preserve, and one transaction is simpler to be sure of than a
--- three-way merge. In one transaction, so another session never reads an
--- anmälan with half its charges.
function Repo.replaceCharges(anmalanId, charges, discordId)
    local statements = {
        {
            query = 'DELETE FROM fpd_anmalan_brott WHERE anmalan_id = ?',
            values = { anmalanId },
        },
    }

    for index = 1, #charges do
        local charge = charges[index]

        statements[#statements + 1] = {
            query = [[INSERT INTO fpd_anmalan_brott
                          (anmalan_id, brott_id, person_id, stage, note, created_by)
                      VALUES (?, ?, ?, ?, ?, ?)]],
            values = {
                anmalanId, charge.brottId, charge.personId,
                charge.stage or 'fullbordat', charge.note, discordId,
            },
        }
    end

    return FredPD.Core.db.transaction(statements)
end

function Repo.setPerson(anmalanId, personId, roll, note, discordId)
    return FredPD.Core.db.execute([[
        INSERT INTO fpd_anmalan_personer (anmalan_id, person_id, roll, note, created_by)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE note = VALUES(note)]],
        { anmalanId, personId, roll, note, discordId })
end

function Repo.removePerson(anmalanId, personId, roll)
    return FredPD.Core.db.execute(
        'DELETE FROM fpd_anmalan_personer WHERE anmalan_id = ? AND person_id = ? AND roll = ?',
        { anmalanId, personId, roll })
end

-- -----------------------------------------------------------------------------
-- Förundersökningen
-- -----------------------------------------------------------------------------

function Repo.fuById(id, agencyId)
    return FredPD.Core.db.single(
        FU_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- Keyset-paginated on `(opened_at, id)` descending (spec 12.2).
---
--- @param cursor string|nil the previous page's `nextCursor`
--- @return table rows
--- @return string|nil nextCursor set only when a further page exists
function Repo.fuList(agencyId, filter, limit, cursor)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        clauses[#clauses + 1] = 'status = ?'
        values[#values + 1] = filter.status
    end

    if filter.fuLedare then
        clauses[#clauses + 1] = 'fu_ledare = ?'
        values[#values + 1] = filter.fuLedare
    end

    local after = FredPD.Core.pagination.decode(cursor, 2)
    if after then
        clauses[#clauses + 1] =
            '(UNIX_TIMESTAMP(opened_at) < ? OR (UNIX_TIMESTAMP(opened_at) = ? AND id < ?))'
        values[#values + 1], values[#values + 1], values[#values + 1] = after[1], after[1], after[2]
    end

    values[#values + 1] = limit + 1

    local rows = FredPD.Core.db.query(
        FU_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY opened_at DESC, id DESC LIMIT ?',
        values)

    local nextCursor = nil
    if #rows > limit then
        rows[limit + 1] = nil
        local last = rows[limit]
        nextCursor = FredPD.Core.pagination.encode({ last.openedAtEpoch, last.id })
    end

    return rows, nextCursor
end

--- Opens a förundersökning, number allocated under the counter lock.
function Repo.fuCreate(input, session)
    local prefix, width = Repo.fuPrefix(session.agencyId)
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'case', session.agencyId)

    -- By index, for the reason `Repo.create` gives: `intel_case_id` is nil on
    -- every FU that did not come out of intelligence work, which is most of
    -- them.
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.title
    values[base + 3] = input.fuLedare or session.discordId
    values[base + 4] = input.ledareKind or 'polis'
    values[base + 5] = input.intelCaseId
    values[base + 6] = session.discordId
    values[base + 7] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'case', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_forundersokning
                              (number, agency_id, title, fu_ledare, ledare_kind,
                               intel_case_id, opened_by, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?, ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        FU_SELECT .. ' WHERE agency_id = ? AND opened_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

--- Moves an FU to one of its two endings, or to slutdelgiven.
---
--- The closing statuses stamp `closed_by` and `closed_at`, which
--- `ck_fpd_fu_closed` requires -- so a nedläggning with nobody's name on it
--- fails at the database rather than being caught here and nowhere else.
function Repo.fuTransition(id, agencyId, toStatus, discordId, reason, note, expectedVersion)
    local sets = { '`status` = ?', '`version` = `version` + 1' }
    local values = { toStatus }

    if toStatus == 'nedlagd' or toStatus == 'redovisad' then
        sets[#sets + 1] = '`closed_by` = ?'
        sets[#sets + 1] = '`closed_at` = CURRENT_TIMESTAMP(3)'
        sets[#sets + 1] = '`closed_reason` = ?'
        sets[#sets + 1] = '`closed_note` = ?'

        values[#values + 1] = discordId
        values[#values + 1] = reason
        values[#values + 1] = note
    end

    values[#values + 1] = id
    values[#values + 1] = agencyId
    values[#values + 1] = expectedVersion

    return FredPD.Core.db.execute(
        ('UPDATE fpd_forundersokning SET %s WHERE id = ? AND agency_id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values)
end

--- Reassigns the investigation, and with it the capacity it is led in.
---
--- Both columns together: a police FU-ledare replaced by an åklagare changes
--- what decisions may be taken in the investigation (0010 reads `ledare_kind`),
--- and setting the person without the capacity would leave the row claiming a
--- prosecutor is leading it as a police officer.
function Repo.fuAssign(id, agencyId, fuLedare, ledareKind, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_forundersokning
           SET fu_ledare = ?, ledare_kind = ?, version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ?]],
        { fuLedare, ledareKind, id, agencyId, expectedVersion })
end

--- The open förundersökning a call's anmälan belongs to, by number, for the
--- evidence an officer collects while working that call (8.4, 7.8).
function Repo.openFuNumberForCall(agencyId, callId)
    if not callId then return nil end

    return FredPD.Core.db.scalar(
        [[SELECT f.number FROM fpd_anmalan a
            JOIN fpd_forundersokning f ON f.id = a.fu_id AND f.agency_id = a.agency_id
           WHERE a.agency_id = ? AND a.call_id = ? AND f.status IN ('inledd', 'slutdelgiven')
           ORDER BY a.id DESC LIMIT 1]],
        { agencyId, callId })
end

--- The most recently opened förundersökning this officer leads that is
--- still open, by number.
function Repo.latestOpenFuNumberLedBy(agencyId, discordId)
    return FredPD.Core.db.scalar(
        [[SELECT number FROM fpd_forundersokning
           WHERE agency_id = ? AND fu_ledare = ? AND status IN ('inledd', 'slutdelgiven')
           ORDER BY opened_at DESC LIMIT 1]],
        { agencyId, discordId })
end

--- A förundersökning by its number, with the columns an access check reads
--- (classification, agency). Nil when the number is not an FU's.
function Repo.fuByNumber(agencyId, number)
    return FredPD.Core.db.single(
        FU_SELECT .. ' WHERE agency_id = ? AND number = ? LIMIT 1', { agencyId, number })
end

--- The förundersökningsledare of an investigation, by its number, for a
--- notice about evidence filed under it. Discord id; never returned to a
--- client.
function Repo.fuLeaderByNumber(agencyId, number)
    return FredPD.Core.db.scalar(
        'SELECT fu_ledare FROM fpd_forundersokning WHERE agency_id = ? AND number = ? LIMIT 1',
        { agencyId, number })
end

FredPD.Repo.anmalan = Repo
