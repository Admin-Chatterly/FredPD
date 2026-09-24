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

--- The bill a citation sends (`events.lua`), read at call time: that file
--- loads after this one.
local function bills()
    return FredPD.Modules.ordningsbotBilling
end

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

local function licenceConfig()
    return (FredPD.Config.server.ordningsbot or {}).licence or {}
end

route.define({
    name = 'ordningsbot.tariff.list',
    perm = 'ordningsbot.tariff.view',
    schema = 'OrdningsbotTariffList',
    handler = function(session)
        return {
            tariffs = repo.tariffList(session.agencyId),
            -- The screen draws the editor from this; the edit routes check
            -- the permission again for themselves.
            mayEdit = FredPD.Core.perms.satisfies(session.permissions, 'ordningsbot.tariff.edit'),
            licence = licenceConfig().enabled ~= false,
        }
    end,
})

route.define({
    name = 'ordningsbot.tariff.set',
    perm = 'ordningsbot.tariff.edit',
    schema = 'OrdningsbotTariffSet',
    writes = true,
    audit = 'ordningsbot.tariff.set',
    subjectType = 'ordningsbot_tariff',
    auditDetail = function(input)
        return { code = input.code, amount = input.amount, licencePoints = input.licencePoints or 0 }
    end,
    handler = function(session, input)
        local existing = repo.currentTariff(session.agencyId, input.code)

        local err, fields = service.validateTariff(input, existing)
        if err then return route.refuse(err, fields) end

        local labelKey, label = service.tariffName(input, existing)

        local committed = repo.setTariff(session.agencyId, {
            code = input.code,
            labelKey = labelKey,
            label = label,
            amount = input.amount,
            points = input.licencePoints or 0,
        }, session.discordId)
        if not committed then return route.refuse(FredPD.ErrorCode.CONFLICT) end

        local line = repo.currentTariff(session.agencyId, input.code)
        return { id = line and line.id, tariff = line }
    end,
})

route.define({
    name = 'ordningsbot.tariff.retire',
    perm = 'ordningsbot.tariff.edit',
    schema = 'OrdningsbotTariffRetire',
    writes = true,
    audit = 'ordningsbot.tariff.retired',
    subjectType = 'ordningsbot_tariff',
    auditDetail = function(input) return { code = input.code } end,
    handler = function(session, input)
        if repo.retireTariff(session.agencyId, input.code) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { code = 'unknown' })
        end

        return { code = input.code }
    end,
})

-- -----------------------------------------------------------------------------
-- The shipped catalogue and licence points, for the rest of the server
-- -----------------------------------------------------------------------------

local Tariff = {}

--- Writes the configured catalogue for every agency that has never had a
--- tariff (7.11). Called once at start, after the agencies load.
function Tariff.ensureDefaults()
    local rows = service.defaultTariffRows((FredPD.Config.server.ordningsbot or {}).defaultTariff)
    if #rows == 0 then return end

    for agencyId in pairs(FredPD.Core.agencies.all()) do
        if not repo.hasAnyTariff(agencyId) then
            for _, line in ipairs(rows) do repo.setTariff(agencyId, line, nil) end
            print(('[fredpd] ordningsbot: wrote the default tariff (%d lines) for %s'):format(#rows, agencyId))
        end
    end
end

FredPD.Modules.ordningsbotTariff = Tariff

local Licence = {}

--- The licence standing a reader may see for a person already read through
--- the access check: nil without `ordningsbot.view`, or with licence points
--- turned off. The caller has read the person; this adds only the sum.
---
--- @return table|nil { points, threshold, standing }
function Licence.standingFor(session, personId)
    local config = licenceConfig()
    if config.enabled == false or not personId then return nil end
    if not FredPD.Core.perms.satisfies(session.permissions, 'ordningsbot.view') then return nil end

    local points = repo.licencePoints(session.agencyId, personId, tonumber(config.windowDays) or 365)
    return service.licenceStanding(points, config)
end

FredPD.Modules.ordningsbotLicence = Licence

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'ordningsbot.list',
    perm = 'ordningsbot.view',
    schema = 'OrdningsbotList',
    handler = function(session, input)
        local found = repo.list(session.agencyId, { status = input.status }, input.limit or 100)
        local citations = access.filterSearch(session, ORDNINGSBOT, found)

        -- `unpaid`/`overdue` are read off `dueAt`, not stored (0024's header) --
        -- computed once here, against the same instant, rather than in the
        -- NUI against however stale the officer's clock happens to be.
        local now = os.time()
        for index = 1, #citations do
            local row = citations[index]
            -- A restricted row is a stub (`Access.stub`) with no `status` or
            -- `dueAt` on it at all -- nothing here to compute a payment
            -- status from, and nothing the reader is allowed to learn.
            if row.restricted ~= true then
                row.paymentStatus = service.paymentStatus(row, now)
            end
        end

        return { citations = citations }
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
        row.paymentStatus = service.paymentStatus(row, os.time())

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

        -- Whoever and whatever the fine names must be readable by the officer
        -- writing it, answered as a record that does not exist otherwise: a
        -- citation must not be a way to reach a hidden record (invariant 4),
        -- and its answer carries the person's licence standing.
        if input.personId and not FredPD.Repo.persons.readPerson(session, input.personId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        if input.vehicleId then
            local vehicle = FredPD.Repo.registry.findVehicle(session.agencyId, { id = input.vehicleId })
            if not vehicle or not access.read(session, 'vehicle', vehicle) then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { vehicleId = 'unknown' })
            end
        end

        local row = repo.issue(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- The fined player is asked for the money; paying it pays this.
        bills().billCitation(row.id, session)

        -- What the fine did to the licence, for the officer who wrote it: the
        -- person was already read to be cited, so this tells them nothing new
        -- about who it is.
        local licence = input.personId and tariff.licencePoints > 0
            and Licence.standingFor(session, input.personId) or nil

        return { id = row.id, number = row.number, citation = row, licence = licence }
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

        bills().withdrawBill(row.id, session)

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

        -- Contested goes to court; nobody pays until the court says so.
        bills().withdrawBill(row.id, session)

        return { id = row.id }
    end,
})

route.define({
    name = 'ordningsbot.pay',
    -- Granted alongside `.issue` for the same reason `.contest` is. A billed
    -- citation marks itself paid when its bill is (`events.lua`); this is for
    -- one that sent no bill, or was settled some other way, and gating it
    -- more tightly than the citation's own issuance would make an officer who
    -- wrote the ticket unable to mark it paid at the roadside.
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

        -- Settled some other way: the bill must not be paid a second time.
        bills().withdrawBill(row.id, session)

        return { id = row.id }
    end,
})
