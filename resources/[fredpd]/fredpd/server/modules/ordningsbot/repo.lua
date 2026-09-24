--- Ordningsbot SQL (spec 7.11). Parameterized only (invariant 8).
---
--- Two things mirror `brott/repo.lua`, deliberately:
---
---   * **The tariff has no UPDATE.** An amount change is `retire` plus
---     `create`, in one transaction, the same shape `Repo.createVersion`
---     uses -- see `Repo.setTariff`.
---   * **`fpd_ordningsbot_tariff.current_marker`** is the same
---     generated-column trick 0008 uses for `fpd_brott`: a database
---     constraint, not a rule the service layer merely promises to keep.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

-- -----------------------------------------------------------------------------
-- Numbering
-- -----------------------------------------------------------------------------

--- Appendix D: `{AGENCY}-T{YY}-{######}`.
---
--- The short name comes from the agency cache (`core/agencies.lua`), never
--- from input: it is half of a record number, and a client that could choose
--- it could write a number that belongs to another agency -- the same
--- reasoning `evidence/repo.lua`'s `numberPrefix` gives.
---
--- @param agencyId string
--- @return string prefix
--- @return number width
function Repo.numberPrefix(agencyId)
    local agency = FredPD.Core.agencies.get(agencyId)
    local short = agency and agency.shortName or agencyId

    return ('%s-T%s-'):format(tostring(short):upper(), os.date('%y')), 6
end

-- -----------------------------------------------------------------------------
-- The tariff (the versioned catalogue)
-- -----------------------------------------------------------------------------

local TARIFF_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, code, label_key AS labelKey, label, amount,
           licence_points AS licencePoints, version,
           UNIX_TIMESTAMP(effective_from) AS effectiveFrom,
           UNIX_TIMESTAMP(retired_at) AS retiredAt
      FROM fpd_ordningsbot_tariff
]]

--- The current (non-retired) version of one tariff code.
function Repo.currentTariff(agencyId, code)
    return db().single(
        TARIFF_SELECT .. ' WHERE agency_id = ? AND code = ? AND retired_at IS NULL',
        { agencyId, code })
end

--- One tariff row by id, whatever version it is and whether or not it is
--- current.
---
--- A citation cites a version by id and must keep rendering after that
--- version is retired, so this deliberately does not filter on
--- `retired_at` -- the same reasoning `brott/repo.lua`'s `Repo.byId` gives.
function Repo.tariffById(id, agencyId)
    return db().single(TARIFF_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

--- Every current tariff in an agency's catalogue, for the fine-selection
--- screen. Not access-filtered: a tariff is a public-within-department
--- catalogue, the same posture `brott/routes.lua`'s `brott.list` takes for
--- offences.
function Repo.tariffList(agencyId)
    return db().query(
        TARIFF_SELECT .. ' WHERE agency_id = ? AND retired_at IS NULL ORDER BY code',
        { agencyId })
end

--- The version number a new version of this code would take.
---
--- Read inside the same transaction as the insert that uses it -- see
--- `setTariff`, never on its own.
local NEXT_VERSION_SQL <const> =
    [[(SELECT COALESCE(MAX(t.version), 0) + 1 FROM fpd_ordningsbot_tariff t
        WHERE t.agency_id = ? AND t.code = ?)]]

local TARIFF_INSERT_SQL <const> = [[
    INSERT INTO fpd_ordningsbot_tariff (agency_id, code, version, label_key, label, amount, licence_points,
                                        created_by)
    VALUES (?, ?, ]] .. NEXT_VERSION_SQL .. [[, ?, ?, ?, ?, ?)
]]

--- Retires the current version of a tariff code (if there is one) and writes
--- a new one, in one transaction.
---
--- Both statements have to commit together: the unique index on
--- `current_marker` allows exactly one live version per code, so retiring
--- first and inserting second is not a preference, it is the only order that
--- commits (`brott/repo.lua`'s `Repo.createVersion` makes the identical
--- argument).
---
--- @param line table { code, labelKey, label, amount, points }
--- @param discordId string|nil nil for the shipped catalogue
--- @return boolean committed
function Repo.setTariff(agencyId, line, discordId)
    return db().transaction({
        {
            query = [[UPDATE fpd_ordningsbot_tariff SET retired_at = CURRENT_TIMESTAMP(3)
                       WHERE agency_id = ? AND code = ? AND retired_at IS NULL]],
            values = { agencyId, line.code },
        },
        {
            query = TARIFF_INSERT_SQL,
            values = {
                agencyId, line.code, agencyId, line.code, line.labelKey, line.label, line.amount,
                line.points or 0, discordId,
            },
        },
    })
end

--- Takes a code out of the catalogue. Citations already issued under it keep
--- the version they cite (0019).
---
--- @return number rows affected -- 0 when the code had no current version
function Repo.retireTariff(agencyId, code)
    return db().execute(
        [[UPDATE fpd_ordningsbot_tariff SET retired_at = CURRENT_TIMESTAMP(3)
           WHERE agency_id = ? AND code = ? AND retired_at IS NULL]],
        { agencyId, code })
end

--- Has this agency ever had a tariff at all? Retired lines count: an agency
--- that emptied its own catalogue did so on purpose.
function Repo.hasAnyTariff(agencyId)
    return (db().scalar('SELECT COUNT(*) FROM fpd_ordningsbot_tariff WHERE agency_id = ?', { agencyId }) or 0) > 0
end

-- -----------------------------------------------------------------------------
-- Licence points (0036)
-- -----------------------------------------------------------------------------

--- The citations counting against a person's licence, with their points:
--- naming them, still issued or paid, younger than the window. Void and
--- contested ones do not count. Rows, not a sum: the caller runs them past
--- the access check, because a citation the reader may not see must not count
--- toward a total they can (ADR-018).
function Repo.licenceCitations(agencyId, personId, windowDays)
    return db().query(
        [[SELECT o.id, o.agency_id AS agencyId, o.classification, t.licence_points AS licencePoints
            FROM fpd_ordningsbot o
            JOIN fpd_ordningsbot_tariff t ON t.id = o.tariff_id AND t.agency_id = o.agency_id
           WHERE o.agency_id = ? AND o.person_id = ? AND o.status IN ('issued', 'paid')
             AND t.licence_points > 0
             AND o.issued_at >= DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)
           LIMIT 200]],
        { agencyId, personId, windowDays })
end

-- -----------------------------------------------------------------------------
-- The citation
-- -----------------------------------------------------------------------------

local CITATION_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, tariff_id AS tariffId,
           person_id AS personId, vehicle_id AS vehicleId,
           issued_by AS issuedBy, UNIX_TIMESTAMP(issued_at) AS issuedAt,
           status, UNIX_TIMESTAMP(due_at) AS dueAt,
           void_reason_key AS voidReasonKey, voided_by AS voidedBy,
           UNIX_TIMESTAMP(voided_at) AS voidedAt,
           UNIX_TIMESTAMP(paid_at) AS paidAt,
           UNIX_TIMESTAMP(contested_at) AS contestedAt,
           UNIX_TIMESTAMP(billed_at) AS billedAt,
           classification, version
      FROM fpd_ordningsbot
]]

function Repo.byId(id, agencyId)
    return db().single(CITATION_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        clauses[#clauses + 1] = 'status = ?'
        values[#values + 1] = filter.status
    end

    values[#values + 1] = limit

    return db().query(
        CITATION_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY issued_at DESC LIMIT ?',
        values)
end

--- Writes a citation and gives it its number.
---
--- The number comes from `fpd_counters` under a row lock, in the same
--- transaction as the INSERT that uses it (spec 13.1, `core/counters.lua`),
--- exactly the shape `court/repo.lua`'s `Repo.decide` uses.
---
--- @param input table shaped by the route: tariffId, personId, vehicleId,
---   classification
--- @param session table the issuing officer's session
--- @return table|nil the inserted row
function Repo.issue(input, session)
    local counters = FredPD.Core.counters
    local prefix, width = Repo.numberPrefix(session.agencyId)

    local values = counters.numberValues(prefix, width, 'citation', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.tariffId
    values[base + 3] = input.personId
    values[base + 4] = input.vehicleId
    values[base + 5] = session.discordId
    values[base + 6] = input.classification or 'internal'
    -- The payment window as it stands right now, written onto the row -- see
    -- 0024's migration header for why this is never re-derived later.
    values[base + 7] = FredPD.Config.server.ordningsbot.paymentWindowDays

    local committed = db().transaction(counters.transaction('citation', session.agencyId, nil, {
        {
            query = [[INSERT INTO fpd_ordningsbot
                          (number, agency_id, tariff_id, person_id, vehicle_id,
                           issued_by, classification, due_at)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?,
                              DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? DAY))]],
            values = values,
        },
    }))

    if not committed then return nil end

    -- Read back rather than returned by the transaction, which reports only
    -- whether it committed -- the same reasoning `court/repo.lua`'s
    -- `Repo.decide` and `evidence/repo.lua`'s `insertEvidence` give. Scoped
    -- to the officer who just wrote it and the tariff cited, which is as
    -- distinguishing a pair as this row has without inventing an opaque
    -- reference the way evidence needs one.
    return db().single(
        CITATION_SELECT
            .. ' WHERE agency_id = ? AND issued_by = ? AND tariff_id = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId, input.tariffId })
end

--- Marks a citation paid. Only a citation still `issued` moves -- see the
--- module header for why there is no move out of `paid` back to anything
--- else.
---
--- The manual path: a billed citation is marked paid by `markPaidByBill`
--- when its bill is (migration 0031).
---
--- @return number rows affected -- 0 means the row was not `issued`, or the
---   version given is stale
function Repo.markPaid(id, agencyId, expectedVersion)
    return db().execute(
        [[UPDATE fpd_ordningsbot
             SET status = 'paid', paid_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND status = 'issued']],
        { id, agencyId, expectedVersion })
end

--- Marks a citation contested. What happens to the contest itself is
--- 7.20's `fpd_atal` disposition, not a second verdict mechanism here -- see
--- the module header.
---
--- @return number rows affected
function Repo.markContested(id, agencyId, expectedVersion)
    return db().execute(
        [[UPDATE fpd_ordningsbot
             SET status = 'contested', contested_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND status = 'issued']],
        { id, agencyId, expectedVersion })
end

--- Voids a citation, once, with a reason.
---
--- @return number rows affected
function Repo.void(id, agencyId, discordId, voidReasonKey, expectedVersion)
    return db().execute(
        [[UPDATE fpd_ordningsbot
             SET status = 'void', void_reason_key = ?, voided_by = ?,
                 voided_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND status = 'issued']],
        { voidReasonKey, discordId, id, agencyId, expectedVersion })
end

-- -----------------------------------------------------------------------------
-- The bill (spec 7.11, migration 0031)
-- -----------------------------------------------------------------------------

--- Who a citation bills and for how much, resolved in one read: the person
--- it names, or, for a vehicle alone, the vehicle's registered keeper. The
--- amount is the tariff version the citation cites, never the current one.
---
--- @return table|nil { id, agencyId, number, amount, identifier }
function Repo.billTarget(id, agencyId)
    return db().single(
        [[SELECT o.id, o.agency_id AS agencyId, o.number, t.amount,
                 COALESCE(p.identifier, v.owner_identifier) AS identifier
            FROM fpd_ordningsbot o
            JOIN fpd_ordningsbot_tariff t ON t.id = o.tariff_id
            LEFT JOIN fpd_persons p ON p.id = o.person_id AND p.agency_id = o.agency_id
            LEFT JOIN fpd_vehicles v ON v.id = o.vehicle_id AND v.agency_id = o.agency_id
           WHERE o.id = ? AND o.agency_id = ? AND o.status = 'issued' AND o.bill_id IS NULL]],
        { id, agencyId })
end

--- Records the bill sent. Only onto a citation still `issued` and not yet
--- billed: 0 rows means it was voided or contested while the bill was being
--- written, and the caller withdraws the bill.
function Repo.setBill(id, agencyId, billId, label)
    return db().execute(
        [[UPDATE fpd_ordningsbot SET bill_id = ?, bill_label = ?, billed_at = CURRENT_TIMESTAMP(3)
           WHERE id = ? AND agency_id = ? AND status = 'issued' AND bill_id IS NULL]],
        { billId, label, id, agencyId })
end

--- The bill a citation sent, read fresh. Used after a void, contest or manual
--- payment, so a bill recorded between the route's read and its write is
--- still withdrawn.
function Repo.billOf(id, agencyId)
    return db().single(
        [[SELECT bill_id AS billId, bill_label AS billLabel
            FROM fpd_ordningsbot WHERE id = ? AND agency_id = ? AND bill_id IS NOT NULL]],
        { id, agencyId })
end

--- Billed citations still waiting on payment, a page at a time by id, so a
--- backlog of fines nobody pays never starves the newer ones of a check.
function Repo.outstandingBills(afterId, limit)
    return db().query(
        [[SELECT id, agency_id AS agencyId, number, issued_by AS issuedBy,
                 bill_id AS billId, classification
            FROM fpd_ordningsbot
           WHERE status = 'issued' AND bill_id IS NOT NULL AND id > ?
           ORDER BY id ASC LIMIT ?]],
        { afterId, limit })
end

--- Marks a citation paid because its bill was. Keyed on the bill as well as
--- the citation, so a citation whose bill changed under the check is left.
function Repo.markPaidByBill(id, agencyId, billId)
    return db().execute(
        [[UPDATE fpd_ordningsbot
             SET status = 'paid', paid_at = CURRENT_TIMESTAMP(3), version = version + 1
           WHERE id = ? AND agency_id = ? AND bill_id = ? AND status = 'issued']],
        { id, agencyId, billId })
end

FredPD.Repo.ordningsbot = Repo
