--- Billing bridge: esx_billing (spec 3.8, 7.11).
---
--- The contract, in FredPD's words: *send somebody a bill, and later ask
--- which of the bills sent are still unpaid*. Nothing here knows what a
--- citation is; `ordningsbot` decides who is billed and for what.
---
--- esx_billing exposes `BillPlayerByIdentifier` and returns nothing -- not
--- the bill, not even whether it was written, because its INSERT runs
--- asynchronously. A bill's id is what lets FredPD notice it being paid, so
--- after sending, the bridge finds the row it wrote (`Billing.send` says how,
--- and why the label alone is not enough). A bill that never appears is
--- reported as not sent: a citation must never read as billed -- and later,
--- when "no row" means "paid", as paid -- on the strength of a bill that
--- does not exist.
---
--- esx_billing deletes a bill when it is paid and offers no way to withdraw
--- one, so `cancel` deletes the row itself: a voided citation must not stay
--- payable. That is the one write into another resource's table in this file,
--- and it touches only a row this bridge created.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local Billing = {}

local function config()
    return FredPD.Config.server.billing or {}
end

local function resource()
    return config().resource or 'esx_billing'
end

local function tableName()
    -- Backticked below; a table name cannot be a bound parameter. Restricted
    -- to what a MySQL identifier may be, so a typo in config cannot become SQL.
    local name = config().table or 'billing'
    assert(name:match('^[%w_]+$'), 'billing.table must be a plain table name')
    return name
end

--- Is billing on and esx_billing running?
function Billing.available()
    return config().enabled ~= false and GetResourceState(resource()) == 'started'
end

--- How long to look for a bill esx_billing has just been asked to write.
Billing.FIND_ATTEMPTS = 10
Billing.FIND_INTERVAL_MS = 300

--- A society account, or nothing. esx_billing treats any other account as a
--- bill from one player to another and pays it to the *sender* -- here the
--- issuing officer, which would put every fine in their own pocket.
local function isSociety(account)
    return type(account) == 'string' and account:match('^society_[%w_]+$') ~= nil
end

--- Sends a bill. Yields while it waits for the row, so call it from a thread.
---
--- **Finding the row is the security-relevant half.** Players can write bills
--- too (`esx_billing:sendBill` is a client event), with any label, so a label
--- alone would let a player pre-create a 1 kr bill to themselves carrying the
--- next citation number, pay it, and have the citation read as paid. The row
--- is matched on everything FredPD controls and a player's own bill cannot
--- carry: newer than the table's highest id before sending, from this
--- officer, to this society, for this amount, with this label. Two matches is
--- ambiguous and counts as not sent.
---
--- @param bill table { identifier, sender, account, label, amount }
--- @return number|nil the bill's id
--- @return string|nil why not: unavailable | invalid | failed | not_found
function Billing.send(bill)
    if not Billing.available() then return nil, 'unavailable' end

    -- Before anything is sent: a bad table name must not leave a real bill
    -- behind that nothing tracks.
    local name = tableName()

    local amount = math.floor(tonumber(bill.amount) or 0)
    if type(bill.identifier) ~= 'string' or bill.identifier == ''
        or type(bill.sender) ~= 'string' or bill.sender == ''
        or type(bill.label) ~= 'string' or bill.label == ''
        or not isSociety(bill.account) or amount <= 0
    then
        return nil, 'invalid'
    end

    local floor = tonumber(FredPD.Core.db.scalar(('SELECT COALESCE(MAX(id), 0) FROM `%s`'):format(name))) or 0

    local ok, err = pcall(function()
        exports[resource()]:BillPlayerByIdentifier(
            bill.identifier, bill.sender, bill.account, bill.label, amount)
    end)

    if not ok then
        print(('[fredpd] billing bridge: %s:BillPlayerByIdentifier failed (%s)')
            :format(resource(), tostring(err)))
        return nil, 'failed'
    end

    local query = ([[SELECT id FROM `%s`
        WHERE id > ? AND identifier = ? AND sender = ? AND target_type = 'society'
          AND target = ? AND label = ? AND amount = ?
        ORDER BY id ASC LIMIT 2]]):format(name)
    local values = { floor, bill.identifier, bill.sender, bill.account, bill.label, amount }

    for attempt = 1, Billing.FIND_ATTEMPTS do
        -- A fork whose table lacks one of these columns fails here, after the
        -- bill went out: answered as `failed`, which the caller audits,
        -- rather than a thread that dies silently.
        local found, rows = pcall(FredPD.Core.db.query, query, values)
        if not found then
            print(('[fredpd] billing bridge: could not look for the bill in `%s` (%s)'):format(name, tostring(rows)))
            return nil, 'failed'
        end

        if #rows == 1 then return tonumber(rows[1].id) end
        if #rows > 1 then
            print(('[fredpd] billing bridge: more than one bill matches "%s"; not adopting either'):format(bill.label))
            return nil, 'not_found'
        end

        if attempt < Billing.FIND_ATTEMPTS then Wait(Billing.FIND_INTERVAL_MS) end
    end

    print(('[fredpd] billing bridge: %s did not write the bill "%s" -- is the %s account set up in esx_addonaccount?')
        :format(resource(), tostring(bill.label), tostring(bill.account)))
    return nil, 'not_found'
end

--- Which of these bills are still unpaid.
---
--- Reads through oxmysql directly rather than `Db.query`, which turns a nil
--- result into an empty list: here an empty list means "every bill was paid",
--- and a read that failed must never say that.
---
--- @param ids number[]
--- @return table|nil set of ids still outstanding, nil when the question
---   cannot be answered (so nothing is marked paid on a failed read)
function Billing.outstanding(ids)
    if not Billing.available() then return nil end
    if #ids == 0 then return {} end

    local marks = {}
    for index = 1, #ids do marks[index] = '?' end

    -- Outside the pcall: a misconfigured table name is loud, not "unknown".
    local query = ('SELECT id FROM `%s` WHERE id IN (%s)'):format(tableName(), table.concat(marks, ', '))

    local ok, rows = pcall(function() return MySQL.query.await(query, ids) end)
    if not ok or type(rows) ~= 'table' then return nil end

    local open = {}
    for index = 1, #rows do open[tonumber(rows[index].id)] = true end

    return open
end

--- Withdraws a bill that has not been paid. Deletes only the row that is
--- still this bill -- same id *and* label, to this society -- so a stale id
--- after esx_billing's table was truncated cannot delete somebody else's.
---
--- @return boolean true when the bill was there and is gone
function Billing.cancel(id, label)
    if not Billing.available() or not id or type(label) ~= 'string' then return false end

    local query = ("DELETE FROM `%s` WHERE id = ? AND label = ? AND target_type = 'society'"):format(tableName())

    local ok, affected = pcall(function() return FredPD.Core.db.execute(query, { id, label }) end)

    return ok and (affected or 0) > 0
end

--- Startup check (spec 3.8). Missing esx_billing is a warning: citations
--- still work, they are only not billed.
function Billing.verify()
    if config().enabled == false then return false end

    if GetResourceState(resource()) ~= 'started' then
        print(('[fredpd] billing bridge: %s is not started. Citations will not send bills; mark them paid by hand.')
            :format(resource()))
        return false
    end

    return true
end

FredPD.Bridge.billing = Billing
