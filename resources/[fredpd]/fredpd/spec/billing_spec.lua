--- The billing bridge and the citation's bill (spec 3.8, 7.11), against a
--- faked esx_billing.
---
--- What matters most here is the direction of every failure. A citation
--- whose bill leaves esx_billing's table is marked **paid**, so anything that
--- makes a bill look absent when it is not -- a failed read, a bill that was
--- never written -- would mark a fine paid that nobody paid. Each of those
--- paths is pinned below to answer "unknown", never "gone".

local helper = require('spec.helper')

--- esx_billing, faked: `bills` is its table, keyed by id, and
--- `BillPlayerByIdentifier` writes a society bill into it the way the real
--- resource does -- unless told to write nothing, or to write late.
local function fakeWorld(state)
    _G.GetResourceState = function(name)
        return state.started[name] and 'started' or 'missing'
    end
    _G.Wait = function()
        state.waits = state.waits + 1
        -- esx_billing's insert is asynchronous: a late write lands during
        -- the bridge's first wait, not before its first look.
        if state.pendingWrite then
            state.pendingWrite()
            state.pendingWrite = nil
        end
    end
    _G.CreateThread = function(fn) fn() end
    _G.exports = setmetatable({}, {
        __index = function(_, name)
            if name ~= 'esx_billing' then error('No such export resource ' .. name) end
            return {
                BillPlayerByIdentifier = function(_, identifier, sender, account, label, amount)
                    if state.billFails then error('esx_billing exploded') end
                    state.sent[#state.sent + 1] = {
                        identifier = identifier, sender = sender,
                        account = account, label = label, amount = amount,
                    }
                    if state.writeNothing then return end

                    local function write()
                        state.nextId = state.nextId + 1
                        state.bills[state.nextId] = {
                            identifier = identifier, sender = sender, target_type = 'society',
                            target = account, label = label, amount = amount,
                        }
                    end

                    if state.writeLate then state.pendingWrite = write else write() end
                end,
            }
        end,
    })
    _G.MySQL = {
        query = {
            await = function(query, values)
                if state.readFails then error('lost connection') end
                if state.readNil then return nil end
                assert(query:find('FROM `billing`', 1, true), query)
                local rows = {}
                for index = 1, #values do
                    if state.bills[values[index]] then rows[#rows + 1] = { id = values[index] } end
                end
                return rows
            end,
        },
    }
end

local function fakeDb(state)
    return {
        scalar = function(query)
            assert(query:find('MAX(id)', 1, true), query)
            local highest = 0
            for id in pairs(state.bills) do highest = math.max(highest, id) end
            return highest
        end,
        query = function(query, values)
            assert(query:find('FROM `billing`', 1, true), query)
            local floor, identifier, sender, target, label, amount = table.unpack(values)
            local ids = {}
            for id, bill in pairs(state.bills) do
                if id > floor and bill.identifier == identifier and bill.sender == sender
                    and bill.target_type == 'society' and bill.target == target
                    and bill.label == label and bill.amount == amount
                then
                    ids[#ids + 1] = id
                end
            end
            table.sort(ids)
            local rows = {}
            for index = 1, math.min(2, #ids) do rows[index] = { id = ids[index] } end
            return rows
        end,
        execute = function(query, values)
            assert(query:find('DELETE FROM `billing`', 1, true), query)
            local bill = state.bills[values[1]]
            if not bill or bill.label ~= values[2] or bill.target_type ~= 'society' then return 0 end
            state.bills[values[1]] = nil
            return 1
        end,
    }
end

local function newState()
    return {
        started = { esx_billing = true },
        sent = {}, bills = {}, nextId = 40, waits = 0,
    }
end

local BILL <const> = {
    identifier = 'char1:abc', sender = 'char1:cop', account = 'society_lspd',
    label = 'Ordningsbot LSPD-T26-000001', amount = 1500,
}

local function copy(overrides)
    local out = {}
    for key, value in pairs(BILL) do out[key] = value end
    for key, value in pairs(overrides or {}) do out[key] = value end
    return out
end

describe('billing bridge', function()
    local Billing, state

    before_each(function()
        state = newState()
        fakeWorld(state)
        local ns = helper.load({ 'server/bridges/billing' })
        ns.Config = { server = { billing = { enabled = true } } }
        ns.Core = { db = fakeDb(state) }
        Billing = ns.Bridge.billing
    end)

    it('sends a bill and answers the row esx_billing wrote', function()
        local id = Billing.send(copy())

        assert.are.equal(41, id)
        assert.are.equal('society_lspd', state.sent[1].account)
        assert.are.equal(1500, state.sent[1].amount)
    end)

    it('waits for a bill esx_billing writes late', function()
        state.writeLate = true

        assert.are.equal(41, Billing.send(copy()))
        assert.is_true(state.waits > 0)
    end)

    it('never adopts a bill a player wrote with the same label', function()
        -- `esx_billing:sendBill` is a client event: a player can pre-create
        -- a 1 kr bill to themselves carrying the next citation number. If the
        -- bridge adopted it, paying it would mark the real fine paid.
        state.bills[40] = {
            identifier = 'char1:abc', sender = 'char1:abc', target_type = 'player',
            target = 'char1:abc', label = BILL.label, amount = 1,
        }
        state.writeLate = true

        assert.are.equal(41, Billing.send(copy()))
    end)

    it('does not adopt a matching bill older than the one it sent', function()
        state.bills[40] = {
            identifier = 'char1:abc', sender = 'char1:cop', target_type = 'society',
            target = 'society_lspd', label = BILL.label, amount = 1500,
        }
        state.writeNothing = true

        local id, why = Billing.send(copy())

        assert.is_nil(id)
        assert.are.equal('not_found', why)
    end)

    it('does not claim a bill esx_billing never wrote', function()
        -- A missing society account makes esx_billing return without writing.
        -- The citation must not then look billed, or -- worse -- paid.
        state.writeNothing = true

        local id, why = Billing.send(copy())

        assert.is_nil(id)
        assert.are.equal('not_found', why)
        assert.is_true(state.waits > 0)
    end)

    it('reports a failed export as not sent', function()
        state.billFails = true

        local id, why = Billing.send(copy())

        assert.is_nil(id)
        assert.are.equal('failed', why)
    end)

    it('refuses to bill nobody, or nothing', function()
        assert.are.equal('invalid', select(2, Billing.send(copy({ identifier = '' }))))
        assert.are.equal('invalid', select(2, Billing.send(copy({ amount = 0 }))))
        assert.are.equal('invalid', select(2, Billing.send(copy({ sender = '' }))))
        assert.are.equal(0, #state.sent)
    end)

    it('refuses an account that would pay the fine to the officer', function()
        -- esx_billing pays a non-society bill to its sender.
        assert.are.equal('invalid', select(2, Billing.send(copy({ account = 'police' }))))
        assert.are.equal(0, #state.sent)
    end)

    it('answers unavailable without esx_billing, and never calls it', function()
        state.started.esx_billing = nil

        local id, why = Billing.send(copy())

        assert.is_nil(id)
        assert.are.equal('unavailable', why)
        assert.is_nil(Billing.outstanding({ 41 }))
        assert.is_false(Billing.verify())
    end)

    it('says which bills are still outstanding', function()
        state.bills[41] = { label = 'x' }
        state.bills[43] = { label = 'y' }

        local open = Billing.outstanding({ 41, 42, 43 })

        assert.is_true(open[41])
        assert.is_nil(open[42])
        assert.is_true(open[43])
    end)

    it('answers unknown, not "all paid", when the read fails or returns nothing', function()
        state.readFails = true
        assert.is_nil(Billing.outstanding({ 41 }))

        state.readFails = nil
        state.readNil = true
        assert.is_nil(Billing.outstanding({ 41 }))
    end)

    it('withdraws only the bill it sent', function()
        state.bills[41] = { label = 'mine', target_type = 'society' }
        state.bills[42] = { label = 'somebody else', target_type = 'society' }

        assert.is_true(Billing.cancel(41, 'mine'))
        assert.is_nil(state.bills[41])
        -- A stale id pointing at another bill (esx_billing's table truncated)
        -- deletes nothing.
        assert.is_false(Billing.cancel(42, 'mine'))
        assert.is_not_nil(state.bills[42])
    end)

    it('refuses a table name that is not a plain identifier', function()
        FredPD.Config.server.billing.table = 'billing; DROP TABLE users'

        assert.has_error(function() Billing.outstanding({ 41 }) end)
        assert.has_error(function() Billing.send(copy()) end)
        assert.are.equal(0, #state.sent)
    end)
end)

describe('citation bills', function()
    local Events, state, citations, audits, notices

    local function fakeRepo()
        return {
            billTarget = function(id)
                local row = citations[id]
                if not row or row.status ~= 'issued' or row.billId then return nil end
                return { id = id, number = row.number, amount = 1500, identifier = row.identifier }
            end,
            setBill = function(id, _, billId, label)
                local row = citations[id]
                if row.status ~= 'issued' or row.billId then return 0 end
                row.billId = billId
                row.billLabel = label
                return 1
            end,
            billOf = function(id)
                local row = citations[id]
                if not row or not row.billId then return nil end
                return { billId = row.billId, billLabel = row.billLabel }
            end,
            outstandingBills = function(afterId, limit)
                local ids = {}
                for id, row in pairs(citations) do
                    if row.status == 'issued' and row.billId and id > afterId then ids[#ids + 1] = id end
                end
                table.sort(ids)
                local out = {}
                for index = 1, math.min(limit, #ids) do
                    local id = ids[index]
                    out[index] = { id = id, agencyId = 'lspd', number = citations[id].number,
                                   issuedBy = '1', billId = citations[id].billId, classification = 'internal' }
                end
                return out
            end,
            markPaidByBill = function(id, _, billId)
                local row = citations[id]
                if row.status ~= 'issued' or row.billId ~= billId then return 0 end
                row.status = 'paid'
                return 1
            end,
        }
    end

    before_each(function()
        state = newState()
        fakeWorld(state)
        citations = {}
        audits = {}
        notices = 0

        local ns = helper.load({ 'server/bridges/billing' })
        ns.Config = { server = { billing = { enabled = true } } }
        ns.Core = {
            db = fakeDb(state),
            audit = { write = function(entry) audits[#audits + 1] = entry end },
            push = {
                notifyWhere = function(predicate)
                    if predicate({ agencyId = 'lspd', discordId = '1' }) then notices = notices + 1 end
                end,
            },
        }
        ns.Repo = {
            ordningsbot = fakeRepo(),
            access = { mayBeToldOf = function() return state.mayBeTold ~= false end },
        }
        ns.Bridge.society = { nameFor = function(agency) return 'society_' .. agency end }
        ns.t = function(key, params) return key .. ':' .. (params and params.number or '') end

        local chunk = assert(loadfile('resources/[fredpd]/fredpd/server/modules/ordningsbot/events.lua'))
        -- The sync loop is a thread that never returns: not started here,
        -- the test drives each pass itself.
        _G.CreateThread = function() end
        chunk()
        _G.CreateThread = function(fn) fn() end

        Events = ns.Modules.ordningsbotBilling
    end)

    local session = { agencyId = 'lspd', discordId = '1', identifier = 'char1:cop' }

    it('bills the citation and records which bill', function()
        citations[7] = { status = 'issued', number = 'LSPD-T26-000007', identifier = 'char1:abc' }

        Events.billCitation(7, session)

        assert.are.equal(41, citations[7].billId)
        assert.are.equal('ordningsbot.bill.label:LSPD-T26-000007', citations[7].billLabel)
        assert.are.equal('society_lspd', state.sent[1].account)
        assert.are.equal('char1:cop', state.sent[1].sender)
        assert.are.equal('ordningsbot.billed', audits[#audits].action)
    end)

    it('does not bill a citation that names nobody a bill can reach', function()
        citations[7] = { status = 'issued', number = 'N', identifier = nil }

        Events.billCitation(7, session)

        assert.are.equal(0, #state.sent)
        assert.is_nil(citations[7].billId)
    end)

    it('audits a bill that could not be sent, with who issued it', function()
        citations[7] = { status = 'issued', number = 'N', identifier = 'char1:abc' }
        state.writeNothing = true

        Events.billCitation(7, session)

        assert.are.equal('ordningsbot.billFailed', audits[#audits].action)
        assert.are.equal('1', audits[#audits].discordId)
    end)

    it('withdraws the bill of a citation voided while it was being sent', function()
        citations[7] = { status = 'issued', number = 'N', identifier = 'char1:abc' }
        local send = FredPD.Bridge.billing.send
        FredPD.Bridge.billing.send = function(bill)
            citations[7].status = 'void'
            return send(bill)
        end

        Events.billCitation(7, session)

        assert.is_nil(citations[7].billId)
        assert.is_nil(state.bills[41])
    end)

    it('marks a citation paid when its bill has gone, and tells the officer', function()
        citations[7] = { status = 'issued', number = 'N', billId = 41 }
        citations[8] = { status = 'issued', number = 'M', billId = 42 }
        state.bills[42] = { label = 'M' }

        assert.are.equal(1, Events.syncPayments())
        assert.are.equal('paid', citations[7].status)
        assert.are.equal('issued', citations[8].status)
        assert.are.equal(1, notices)
        assert.is_true(audits[#audits].detail.automatic)
    end)

    it('does not tell an officer who may no longer know of the citation', function()
        citations[7] = { status = 'issued', number = 'N', billId = 41 }
        state.mayBeTold = false

        assert.are.equal(1, Events.syncPayments())
        assert.are.equal(0, notices)
    end)

    it('checks every outstanding bill, not only the oldest page', function()
        Events.PAGE = 2
        for id = 1, 5 do citations[id] = { status = 'issued', number = tostring(id), billId = 100 + id } end
        state.bills[101] = { label = '1' }

        assert.are.equal(4, Events.syncPayments())
        assert.are.equal('issued', citations[1].status)
        assert.are.equal('paid', citations[5].status)
    end)

    it('marks nothing paid when esx_billing cannot be read', function()
        citations[7] = { status = 'issued', number = 'N', billId = 41 }
        state.readFails = true

        assert.are.equal(0, Events.syncPayments())
        assert.are.equal('issued', citations[7].status)
    end)

    it('withdraws the bill it reads fresh, and audits it', function()
        citations[7] = { status = 'void', number = 'N', billId = 41, billLabel = 'mine' }
        state.bills[41] = { label = 'mine', target_type = 'society' }

        Events.withdrawBill(7, session)

        assert.is_nil(state.bills[41])
        assert.are.equal('ordningsbot.billWithdrawn', audits[#audits].action)
        assert.are.equal('ok', audits[#audits].outcome)
    end)

    it('audits a bill it could not withdraw as an error', function()
        citations[7] = { status = 'void', number = 'N', billId = 41, billLabel = 'mine' }

        Events.withdrawBill(7, session)

        assert.are.equal('error', audits[#audits].outcome)
    end)
end)
