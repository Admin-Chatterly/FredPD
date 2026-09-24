--- Ordningsbot and the bill (spec 7.11, 3.8).
---
--- A citation used to be paperwork: the fined player was never asked for the
--- money, and it was marked paid only if an officer remembered to. Now:
---
---   * **Issuing one sends a bill** through the billing bridge, to the person
---     it names or the keeper of the vehicle it names, into the agency's
---     society account. Sent from a thread, because the bridge waits for
---     esx_billing to write the row and the officer should not.
---   * **Paying the bill pays the citation.** A thread checks the outstanding
---     bills every `billing.syncSeconds`; one that has left esx_billing's
---     table was paid, and the citation is marked so, by the server, audited
---     as `ordningsbot.paid` with `automatic = true`. The issuing officer is
---     told if they are on.
---   * **Voiding, contesting or marking it paid by hand withdraws the bill**
---     (`Ordningsbot.withdrawBill`), so nobody pays a fine that no longer
---     stands.

FredPD.Modules = FredPD.Modules or {}

local repo = FredPD.Repo.ordningsbot

local function billing()
    return FredPD.Bridge.billing
end

local Events = {}

--- Bills a citation just issued. Returns at once; the bill follows.
function Events.billCitation(citationId, session)
    if not billing() or not billing().available() then return end

    CreateThread(function()
        local target = repo.billTarget(citationId, session.agencyId)

        -- Nobody a bill can reach: a person or keeper never identified with
        -- an ESX character. The citation stands; it is paid by hand.
        if not target or not target.identifier then return end

        local label = FredPD.t('ordningsbot.bill.label', { number = target.number })

        local billId, why = billing().send({
            identifier = target.identifier,
            sender = session.identifier,
            account = FredPD.Bridge.society.nameFor(session.agencyId),
            label = label,
            amount = target.amount,
        })

        if not billId then
            FredPD.Core.audit.write({
                action = 'ordningsbot.billFailed',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'citation',
                subjectId = tostring(citationId),
                outcome = 'error',
                detail = { reason = why },
            })
            return
        end

        -- Voided or contested while the bill was being written: withdraw it,
        -- audited like every other withdrawal.
        if repo.setBill(citationId, session.agencyId, billId, label) == 0 then
            local withdrawn = billing().cancel(billId, label)

            FredPD.Core.audit.write({
                action = 'ordningsbot.billWithdrawn',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'citation',
                subjectId = tostring(citationId),
                outcome = withdrawn and 'ok' or 'error',
                detail = { billId = billId },
            })
            return
        end

        FredPD.Core.audit.write({
            action = 'ordningsbot.billed',
            discordId = session.discordId,
            agencyId = session.agencyId,
            subjectType = 'citation',
            subjectId = tostring(citationId),
            detail = { billId = billId, amount = target.amount },
        })
    end)
end

--- Withdraws the bill of a citation that no longer stands.
---
--- Called after the citation's own transition, and reads the bill fresh
--- then: a bill recorded between the route's read and its write is still
--- found. Audited either way -- a delete in another resource's money table
--- (ADR-015), or a bill that should have gone and could not, which somebody
--- has to reconcile by hand.
function Events.withdrawBill(citationId, session)
    local bill = repo.billOf(citationId, session.agencyId)
    if not bill or not billing() then return end

    local withdrawn = billing().cancel(bill.billId, bill.billLabel)

    FredPD.Core.audit.write({
        action = 'ordningsbot.billWithdrawn',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = 'citation',
        subjectId = tostring(citationId),
        outcome = withdrawn and 'ok' or 'error',
        detail = { billId = bill.billId },
    })
end

Events.PAGE = 200

--- One pass over the outstanding bills, a page at a time.
function Events.syncPayments()
    local paid = 0
    local afterId = 0

    while true do
        local rows = repo.outstandingBills(afterId, Events.PAGE)
        if #rows == 0 then break end

        local ids = {}
        for index = 1, #rows do ids[index] = rows[index].billId end

        -- nil is "could not ask", which must never read as "all paid".
        local open = billing().outstanding(ids)
        if not open then break end

        for index = 1, #rows do
            local row = rows[index]
            afterId = row.id

            if not open[tonumber(row.billId)]
                and repo.markPaidByBill(row.id, row.agencyId, row.billId) > 0
            then
                paid = paid + 1

                FredPD.Core.audit.write({
                    action = 'ordningsbot.paid',
                    agencyId = row.agencyId,
                    subjectType = 'citation',
                    subjectId = tostring(row.id),
                    detail = { billId = row.billId, automatic = true },
                })

                FredPD.Core.push.notifyWhere(function(other)
                    return other.agencyId == row.agencyId and other.discordId == row.issuedBy
                        and FredPD.Repo.access.mayBeToldOf(other, 'citation', row)
                end, 'ordningsbot.notify.paid', { number = row.number }, { type = 'success' })
            end
        end

        if #rows < Events.PAGE then break end
    end

    return paid
end

FredPD.Modules.ordningsbotBilling = Events

CreateThread(function()
    while true do
        local seconds = (FredPD.Config.server.billing or {}).syncSeconds or 60
        Wait(math.max(15, seconds) * 1000)

        if billing() and billing().available() then
            local ok, err = pcall(Events.syncPayments)
            if not ok then print(('[fredpd] billing sync failed: %s'):format(tostring(err))) end
        end
    end
end)
