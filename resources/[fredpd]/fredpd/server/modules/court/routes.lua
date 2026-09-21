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

--- Which legal capacity this session acts in, for the one route
--- (`court.referral.decide`) where holding the read permission is not
--- enough. Derived from permissions, never sent -- a client that could name
--- its own capacity could file its own charge.
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

        return { atal = access.filterSearch(session, ATAL, found) }
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
        local candidates = FredPD.Repo.anmalan.fuList(session.agencyId, { status = 'redovisad' }, 25)
        local pending = {}

        for index = 1, #candidates do
            local fu = candidates[index]

            if not repo.byFuId(fu.id, session.agencyId) then
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
        return { fuId = input.fuId, beslut = input.beslut }
    end,
    handler = function(session, input)
        if not service.mayDecide(capacityOf(session)) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        local err, fields = service.validateReferral(input)
        if err then return route.refuse(err, fields) end

        local fu = FredPD.Repo.anmalan.fuById(input.fuId, session.agencyId)
        if not fu then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { fuId = 'unknown' }) end

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

        return { id = row.id, number = row.number, atal = row }
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
    auditDetail = function(input)
        return { disposition = input.disposition }
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

        if repo.enterDisposition(row.id, session.agencyId, session.discordId, input, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
