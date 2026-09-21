--- Ordningsbot routes (spec 7.11).
---
--- The tariff list (`ordningsbot.tariff.list`) is not access-filtered --
--- see `repo.lua`'s `Repo.tariffList` for why, the same reasoning
--- `brott/routes.lua`'s `brott.list` gives for the offence catalogue. Every
--- read of a citation itself goes through `access.read`/`access.filterSearch`
--- exactly the way `court/routes.lua` reads an åtal, because a citation
--- names a person or a vehicle and invariant 4 makes no exception for one
--- that happens to be a small record.
---
--- `ordningsbot.void`, `.contest` and `.pay` share one shape: read the row
--- through `readable()`, ask `service.mayTransition` whether the move from
--- its current status is legal, and let `repo`'s own `WHERE status =
--- 'issued'` be the thing that actually stops a race -- the route's check is
--- what turns a conflict into a field-level refusal instead of a bare
--- `CONFLICT`, not the only thing enforcing it.

local route = FredPD.Core.route
local repo = FredPD.Repo.ordningsbot
local service = FredPD.Modules.ordningsbot
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type. `citation` is already allowlisted in
--- `access/repo.lua`.
local ORDNINGSBOT <const> = 'citation'

local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, ORDNINGSBOT, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

-- -----------------------------------------------------------------------------
-- The tariff
-- -----------------------------------------------------------------------------

route.define({
    name = 'ordningsbot.tariff.list',
    perm = 'ordningsbot.tariff.view',
    schema = 'OrdningsbotTariffList',
    handler = function(session)
        return { tariffs = repo.tariffList(session.agencyId) }
    end,
})

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'ordningsbot.list',
    perm = 'ordningsbot.view',
    schema = 'OrdningsbotList',
    handler = function(session, input)
        local found = repo.list(session.agencyId, { status = input.status }, input.limit or 100)

        return { citations = access.filterSearch(session, ORDNINGSBOT, found) }
    end,
})

route.define({
    name = 'ordningsbot.get',
    perm = 'ordningsbot.view',
    schema = 'OrdningsbotGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        -- The tariff version this citation was actually issued under, so the
        -- screen shows what it cost then, not what the code costs now
        -- (0019's header, `Repo.tariffById` never filters on `retiredAt`).
        row.tariff = repo.tariffById(row.tariffId, session.agencyId)

        return { citation = row }
    end,
})

-- -----------------------------------------------------------------------------
-- Issuing
-- -----------------------------------------------------------------------------

route.define({
    name = 'ordningsbot.issue',
    perm = 'ordningsbot.issue',
    schema = 'OrdningsbotIssue',
    writes = true,
    sensitive = true,
    audit = 'ordningsbot.issued',
    subjectType = ORDNINGSBOT,
    auditDetail = function(input) return { tariffId = input.tariffId } end,
    handler = function(session, input)
        local err, fields = service.validateIssue(input)
        if err then return route.refuse(err, fields) end

        local tariff = repo.tariffById(input.tariffId, session.agencyId)
        if not tariff then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { tariffId = 'unknown' }) end

        -- The tariff cited has to be the current version: citing a retired
        -- one would issue a fine under an amount an operator has already
        -- superseded, which is the exact defect 0019's versioning exists to
        -- prevent on the read side and must also refuse on the write side.
        if tariff.retiredAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { tariffId = 'retired' })
        end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local row = repo.issue(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, citation = row }
    end,
})

-- -----------------------------------------------------------------------------
-- The lifecycle: void, contest, pay
-- -----------------------------------------------------------------------------

route.define({
    name = 'ordningsbot.void',
    perm = 'ordningsbot.void',
    schema = 'OrdningsbotVoid',
    writes = true,
    sensitive = true,
    audit = 'ordningsbot.voided',
    subjectType = ORDNINGSBOT,
    auditDetail = function(input) return { id = input.id, voidReasonKey = input.voidReasonKey } end,
    handler = function(session, input)
        local err, fields = service.validateVoid(input)
        if err then return route.refuse(err, fields) end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if not service.mayTransition(row.status, 'void') then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'not_issued' })
        end

        if repo.void(row.id, session.agencyId, session.discordId, input.voidReasonKey, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

route.define({
    name = 'ordningsbot.contest',
    -- A defendant contesting is recorded by whoever takes the call or the
    -- paperwork -- an officer's own citation and a supervisor's alike -- so
    -- this is granted alongside `ordningsbot.issue` rather than reserved for
    -- a separate court-side role: 7.11 makes contesting an intake step
    -- ("goes to court"), not the disposition itself. The disposition is
    -- `court.disposition.enter` (0016), a different permission entirely.
    perm = 'ordningsbot.contest',
    schema = 'OrdningsbotContest',
    writes = true,
    sensitive = true,
    audit = 'ordningsbot.contested',
    subjectType = ORDNINGSBOT,
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if not service.mayTransition(row.status, 'contested') then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'not_issued' })
        end

        if repo.markContested(row.id, session.agencyId, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

route.define({
    name = 'ordningsbot.pay',
    -- Granted alongside `.issue` for the same reason `.contest` is: this
    -- screen is the only place a payment is recorded until a billing bridge
    -- exists (see the migration header and `repo.lua`'s `Repo.markPaid`),
    -- and gating it more tightly than the citation's own issuance would make
    -- an officer who wrote the ticket unable to mark it paid at the roadside.
    perm = 'ordningsbot.pay',
    schema = 'OrdningsbotPay',
    writes = true,
    sensitive = true,
    audit = 'ordningsbot.paid',
    subjectType = ORDNINGSBOT,
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if not service.mayTransition(row.status, 'paid') then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'not_issued' })
        end

        if repo.markPaid(row.id, session.agencyId, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
