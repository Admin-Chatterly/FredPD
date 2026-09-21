--- Åtal och dom SQL (spec 7.20). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `A{YY}-{#####}`.
function Repo.numberPrefix()
    return ('A%s-'):format(os.date('%y')), 5
end

local ATAL_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, fu_id AS fuId,
           beslut, beslut_grund AS beslutGrund,
           decided_by AS decidedBy,
           UNIX_TIMESTAMP(decided_at) AS decidedAt,
           disposition,
           sentence_months AS sentenceMonths, sentence_livstid AS sentenceLivstid,
           disposition_note AS dispositionNote,
           disposition_by AS dispositionBy,
           UNIX_TIMESTAMP(disposition_at) AS dispositionAt,
           classification, version
      FROM fpd_atal
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        ATAL_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.byFuId(fuId, agencyId)
    return FredPD.Core.db.single(
        ATAL_SELECT .. ' WHERE fu_id = ? AND agency_id = ?', { fuId, agencyId })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.beslut then
        clauses[#clauses + 1] = 'beslut = ?'
        values[#values + 1] = filter.beslut
    end

    if filter.awaitingDisposition then
        clauses[#clauses + 1] = "beslut = 'atalad' AND disposition IS NULL"
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        ATAL_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY decided_at DESC LIMIT ?',
        values)
end

--- The charges on an åtal, with the catalogue row each cites -- the same
--- shape `anmalan/repo.lua`'s `Repo.charges` gives the anmälan's own list.
function Repo.charges(atalId)
    return FredPD.Core.db.query([[
        SELECT ab.id, ab.atal_id AS atalId, ab.brott_id AS brottId, ab.stage,
               b.code, b.version AS brottVersion, b.balk, b.kapitel, b.paragraf,
               b.label_key AS labelKey, b.grad, b.boter,
               b.fangelse_min_months AS fangelseMinMonths,
               b.fangelse_max_months AS fangelseMaxMonths
          FROM fpd_atal_brott ab
          JOIN fpd_brott b ON b.id = ab.brott_id
         WHERE ab.atal_id = ?
         ORDER BY ab.id]], { atalId })
end

--- Records a charging decision, with its charges (when `atalad`) in the same
--- transaction: an åtal briefly holding no charges is a prosecution of
--- nothing, and `LAST_INSERT_ID()` inside oxmysql's transaction wrapper
--- (each statement runs on the one connection, in order) is what lets the
--- charge rows reference a parent id this statement list never sees handed
--- back.
---
--- @param charges table|nil list of { brottId, stage } -- nil or empty for
---   an `ej_atal` decision
function Repo.decide(input, session, charges)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'atal', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.fuId
    values[base + 3] = input.beslut
    values[base + 4] = input.beslutGrund
    values[base + 5] = session.discordId
    values[base + 6] = input.classification or 'internal'

    local statements = {
        {
            query = [[INSERT INTO fpd_atal
                          (number, agency_id, fu_id, beslut, beslut_grund,
                           decided_by, classification)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?)]],
            values = values,
        },
    }

    for index = 1, #(charges or {}) do
        local charge = charges[index]

        statements[#statements + 1] = {
            query = [[INSERT INTO fpd_atal_brott (atal_id, brott_id, stage)
                      VALUES (LAST_INSERT_ID(), ?, ?)]],
            values = { charge.brottId, charge.stage },
        }
    end

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'atal', session.agencyId, nil, statements))

    if not committed then return nil end

    return FredPD.Core.db.single(
        ATAL_SELECT .. ' WHERE agency_id = ? AND decided_by = ? AND fu_id = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, session.discordId, input.fuId })
end

--- Enters a disposition. Only a row still awaiting one (`disposition IS
--- NULL`) moves -- a verdict, once entered, is not retaken here.
function Repo.enterDisposition(id, agencyId, discordId, input, expectedVersion)
    return FredPD.Core.db.execute([[
        UPDATE fpd_atal
           SET disposition = ?, sentence_months = ?, sentence_livstid = ?,
               disposition_note = ?, disposition_by = ?, disposition_at = CURRENT_TIMESTAMP(3),
               version = version + 1
         WHERE id = ? AND agency_id = ? AND version = ? AND disposition IS NULL]],
        {
            input.disposition, input.sentenceMonths, input.sentenceLivstid and 1 or 0,
            input.note, discordId, id, agencyId, expectedVersion,
        })
end

FredPD.Repo.court = Repo
