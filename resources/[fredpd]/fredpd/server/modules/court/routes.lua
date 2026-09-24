--- Åtal och dom routes (spec 7.20).
---
--- Two decision-makers, and a domare holds `court.referral.review` too --
--- reading the docket a sentence will be read against is part of disposing
--- of it (the seed grants both to `domare`). That overlap is why
--- `court.referral.decide` cannot rely on its own `perm` the way
--- `court.disposition.enter` can: `capacityOf` derives which capacity a
--- session acts in, the same pattern `frihet` and `surveillance` use, and the
--- narrower role -- domare -- wins when a session holds both. A domare who
--- could also file a charge would be a domare who is also the prosecution.
---
--- `frihet.haktning` (0010) already covers the häktningsförhandling's
--- outcome; this module picks up where an FU is redovisad and 0010 has
--- nothing left to say (0016's header argues this at length).

local route = FredPD.Core.route
local repo = FredPD.Repo.court
local service = FredPD.Modules.court
local brott = FredPD.Modules.brott
local anmalan = FredPD.Modules.anmalan
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type. `case` is already allowlisted in `access/repo.lua`
--- and is what a grant on an åtal would be written against.
local ATAL <const> = 'case'

--- The ids of an investigation's anmälningar this session may read. Every
--- suspect and offence the court screen draws from an FU comes from these
--- only: a sealed report's link to a person is itself something the reader
--- may not know (invariant 4).
local function readableReports(session, fuId)
    local underFu = (FredPD.Repo.anmalan.list(session.agencyId, { fuId = fuId, includeSupplements = true }, 100))
    local ids = {}

    for _, row in ipairs(access.filterSearch(session, 'report', underFu)) do
        if row.id then ids[#ids + 1] = row.id end
    end

    return ids
end

--- The misstänkta on those reports this session may read, shaped for a
--- picker: the åklagare chooses the tilltalade from these (spec 7.20).
local function readableSuspects(session, reportIds)
    local out = {}

    for _, personId in ipairs(FredPD.Repo.anmalan.suspectsIn(reportIds, session.agencyId)) do
        local person = FredPD.Repo.persons.readPerson(session, personId)
        if person then
            out[#out + 1] = {
                id = person.id,
                personNumber = person.personNumber,
                firstName = person.firstName,
                lastName = person.lastName,
            }
        end
    end

    return out
end

--- What leaves this module about an åtal: never the bare id of a tilltalade,
--- which the reader may not be allowed to know of. `defendant` carries them
--- when they may.
local function shaped(row)
    if type(row) == 'table' then row.personId = nil end
    return row
end

local function capacityOf(session)
    local perms = session.permissions

    if FredPD.Core.perms.satisfies(perms, 'court.disposition.enter') then return 'domare' end
    if FredPD.Core.perms.satisfies(perms, 'court.referral.review') then return 'aklagare' end

    return nil
end

local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, ATAL, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'court.referral.list',
    perm = 'court.referral.review',
    schema = 'CourtReferralList',
    handler = function(session, input)
        local found = repo.list(session.agencyId, {
            beslut = input.beslut,
            awaitingDisposition = input.awaitingDisposition,
        }, input.limit or 50)

        local rows = access.filterSearch(session, ATAL, found)
        for index = 1, #rows do shaped(rows[index]) end

        return { atal = rows }
    end,
})

--- Redovisade förundersökningar with no charging decision yet -- the
--- åklagare's own queue. Bounded at 25: each candidate costs a second read to
--- confirm no `fpd_atal` row already exists for it (no single query
--- expresses "redovisad and has no row in a different module's table"
--- without reaching into `anmalan`'s own repo at the SQL level, which
--- `court/repo.lua` does not do -- see the module header).
route.define({
    name = 'court.referral.pending',
    perm = 'court.referral.review',
    schema = 'CourtReferralPending',
    handler = function(session)
        local candidates = access.filterSearch(session, 'case',
            (FredPD.Repo.anmalan.fuList(session.agencyId, { status = 'redovisad' }, 25)))
        local pending = {}

        for index = 1, #candidates do
            local fu = candidates[index]

            -- A stubbed FU has no id to decide on; it is left out.
            if fu.id and not repo.byFuId(fu.id, session.agencyId) then
                -- What the åklagare starts from, so the charge sheet is not
                -- retyped: whom the reports name as misstänkt, and what they
                -- report. Both remain choices; the decision checks the first.
                local reports = readableReports(session, fu.id)
                fu.suspects = readableSuspects(session, reports)
                fu.brottIds = FredPD.Repo.anmalan.brottIdsIn(reports, session.agencyId)
                pending[#pending + 1] = fu
            end
        end

        return { forundersokningar = pending }
    end,
})

route.define({
    name = 'court.referral.get',
    perm = 'court.referral.review',
    schema = 'CourtReferralGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        row.charges = repo.charges(row.id)

        -- The tilltalade, when this reader may read them.
        if row.personId then
            local person = FredPD.Repo.persons.readPerson(session, row.personId)
            row.defendant = person and {
                id = person.id, personNumber = person.personNumber,
                firstName = person.firstName, lastName = person.lastName,
            } or nil
        end
        shaped(row)

        -- The straffskala the charges allow, computed the same way
        -- `anmalan/routes.lua` computes one for a report: a domare reads this
        -- before entering a sentence, and it is the server's own answer, not
        -- arithmetic the screen redid.
        local skalor = {}
        for index = 1, #row.charges do
            skalor[index] = brott.straffskala(row.charges[index])
        end
        row.straffskala = #skalor > 0 and brott.gemensamStraffskala(skalor) or nil

        return { atal = row }
    end,
})

-- -----------------------------------------------------------------------------
-- The charging decision
-- -----------------------------------------------------------------------------

route.define({
    name = 'court.referral.decide',
    perm = 'court.referral.review',
    schema = 'CourtReferralDecide',
    writes = true,
    sensitive = true,
    audit = 'court.referral.decided',
    subjectType = ATAL,
    auditDetail = function(input)
        return { fuId = input.fuId, beslut = input.beslut, personId = input.personId }
    end,
    handler = function(session, input)
        if not service.mayDecide(capacityOf(session)) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        local err, fields = service.validateReferral(input)
        if err then return route.refuse(err, fields) end

        local fu = FredPD.Repo.anmalan.fuById(input.fuId, session.agencyId)
        if not fu then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { fuId = 'unknown' }) end

        -- Deciding on an investigation is reading it.
        fu = access.read(session, 'case', fu)
        if not fu then return route.refuse(FredPD.ErrorCode.RESTRICTED) end

        -- Only a redovisad FU has been handed to a prosecutor at all (spec
        -- 7.8): one still open, or already nedlagd, has nothing here to
        -- decide.
        if fu.status ~= 'redovisad' then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { fuId = 'out_of_order' })
        end

        if repo.byFuId(fu.id, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { fuId = 'already_decided' })
        end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local charges = nil

        -- The tilltalade: one of the investigation's misstänkta that this
        -- åklagare can see -- the same list the screen offers -- never a
        -- person the input merely names. With exactly one misstänkt in the
        -- whole FU, and that one visible, it is them; with several, choosing
        -- is required, so a sentence always has somebody to reach.
        if input.beslut == 'atalad' then
            local suspects = readableSuspects(session, readableReports(session, fu.id))

            if input.personId then
                local named = false
                for index = 1, #suspects do
                    if suspects[index].id == input.personId then named = true end
                end
                if not named then
                    return route.refuse(FredPD.ErrorCode.INVALID, { personId = 'not_suspect' })
                end
            elseif #suspects == 1 and FredPD.Repo.anmalan.suspectCountOfFu(fu.id, session.agencyId) == 1 then
                input.personId = suspects[1].id
            elseif #suspects >= 1 then
                -- Several, or one visible among others the reader cannot see:
                -- the åklagare names whom they charge.
                return route.refuse(FredPD.ErrorCode.INVALID, { personId = 'required' })
            end
        else
            input.personId = nil
        end

        if input.beslut == 'atalad' then
            local ids, reason = brott.parseIds(input.brottIds, 25)
            if not ids then return route.refuse(FredPD.ErrorCode.INVALID, { brottIds = reason }) end

            local rows = FredPD.Repo.brott.byIds(ids, session.agencyId)
            local catalogue = brott.expandCharges(ids, rows)
            if not catalogue then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { brottIds = 'unknown' })
            end

            local stages = input.stages or {}
            if #stages > 0 and #stages ~= #ids then
                return route.refuse(FredPD.ErrorCode.INVALID, { stages = 'length_mismatch' })
            end

            charges = {}
            for index = 1, #ids do
                local stage = stages[index] or 'fullbordat'

                if not anmalan.stageIsAvailable(catalogue[index], stage) then
                    return route.refuse(FredPD.ErrorCode.INVALID, { stages = 'stage_unavailable' })
                end

                charges[index] = { brottId = ids[index], stage = stage }
            end
        end

        local row = repo.decide(input, session, charges)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, atal = shaped(row) }
    end,
})

-- -----------------------------------------------------------------------------
-- The disposition
-- -----------------------------------------------------------------------------

route.define({
    name = 'court.disposition.enter',
    perm = 'court.disposition.enter',
    schema = 'CourtDispositionEnter',
    writes = true,
    sensitive = true,
    audit = 'court.disposition.entered',
    subjectType = ATAL,
    auditDetail = function(input, result)
        return {
            disposition = input.disposition,
            jailMinutes = type(result) == 'table' and result.jailMinutes or nil,
        }
    end,
    handler = function(session, input)
        if not service.mayDispose(capacityOf(session)) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        local err, fields = service.validateDisposition(input)
        if err then return route.refuse(err, fields) end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if row.beslut ~= 'atalad' then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { disposition = 'not_atalad' })
        end

        if service.dispositionNeedsSentence(input.disposition) then
            local charges = repo.charges(row.id)
            local skalor = {}

            for index = 1, #charges do
                skalor[index] = brott.straffskala(charges[index])
            end

            local skala = #skalor > 0 and brott.gemensamStraffskala(skalor) or nil
            local ok, why = service.sentenceWithinRange(
                skala, input.sentenceMonths, input.sentenceLivstid == true)

            if not ok then
                return route.refuse(FredPD.ErrorCode.INVALID, { sentenceMonths = why })
            end
        end

        -- The sentence as the jail will serve it, fixed now (ADR-017). Nil
        -- for anything but a custodial sentence on a named tilltalade.
        local jailMinutes = row.personId and service.jailMinutes(
            input.disposition, input.sentenceMonths, input.sentenceLivstid == true,
            FredPD.Config.server.jail) or nil

        if repo.enterDisposition(row.id, session.agencyId, session.discordId, input, input.version,
                                 jailMinutes) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        -- Served in the game, and the officers who worked the case told.
        TriggerEvent('fredpd:sentenced', {
            atalId = row.id,
            agencyId = session.agencyId,
            disposition = input.disposition,
            jailMinutes = jailMinutes,
            judgeSrc = session.src,
        })

        return { id = row.id, jailMinutes = jailMinutes }
    end,
})

-- -----------------------------------------------------------------------------
-- The front desk (7.29)
-- -----------------------------------------------------------------------------

--- What a tilltalad is told about the cases against them, at a front desk: the
--- number, the prosecutor's decision and, once there is one, the verdict and
--- sentence. Never the reasoning, the note or who decided.
---
--- An åtal is read through its förundersökning's access control (it has
--- none of its own here), and one whose investigation is restricted is not
--- shown: the desk is not a way round a seal or a compartment.
---
--- @return table list of { number, beslut, decidedAt, disposition, sentenceMonths, sentenceLivstid, dispositionAt }
function FredPD.Modules.courtForSubject(agencyId, personId)
    if not personId then return {} end

    local out = {}
    for _, row in ipairs(repo.forPerson(agencyId, personId, 25)) do
        local control = access.attachControl('case', { { id = row.fuId, classification = row.classification } })[1]

        if control and not accessRules.isRestricted(control) then
            out[#out + 1] = {
                number = row.number,
                beslut = row.beslut,
                decidedAt = row.decidedAt,
                disposition = row.disposition,
                sentenceMonths = row.sentenceMonths,
                sentenceLivstid = row.sentenceLivstid == 1 or row.sentenceLivstid == true,
                dispositionAt = row.dispositionAt,
            }
        end
    end

    return out
end
