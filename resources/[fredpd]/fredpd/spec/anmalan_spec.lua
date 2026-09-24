--- Anmälan och förundersökning (spec 7.7, 7.8).
---
--- Three things here are worth testing more than the rest:
---
---   * **`canApprove`**, because it is the control. An approval an author can
---     grant themselves records that a second person looked when nobody did,
---     in a field that is later read as though somebody had. It is the one rule
---     in the module that no permission may override, so the test says so.
---   * **`isLocked` and the transition map**, because 7.7's locking rule is the
---     thing a supplemental report exists to work around, and a map with one
---     stray entry would make an approved anmälan editable again.
---   * **`parentIsAllowed`**, because it holds a rule the schema cannot:
---     MariaDB refuses a CHECK against an AUTO_INCREMENT column, so a cycle in
---     the tilläggsuppgift chain is refused here or nowhere -- and every read,
---     every snapshot and every print walks that chain.

local helper = require('spec.helper')

describe('anmalan', function()
    local anmalan

    before_each(function()
        anmalan = helper.load({ 'server/modules/anmalan/service' }).Modules.anmalan
    end)

    --- An anmälan row, varying one field at a time.
    local function report(overrides)
        local base = { id = 1, status = 'utkast', createdBy = 'author' }

        for key, value in pairs(overrides or {}) do base[key] = value end
        return base
    end

    -- -------------------------------------------------------------------------
    describe('allowlists', function()
        it('knows the four statuses and nothing else', function()
            assert.is_true(anmalan.isStatus('utkast'))
            assert.is_true(anmalan.isStatus('inlamnad'))
            assert.is_true(anmalan.isStatus('atersand'))
            assert.is_true(anmalan.isStatus('godkand'))

            assert.is_false(anmalan.isStatus('approved'))
            assert.is_false(anmalan.isStatus(nil))
        end)

        it('knows the Swedish roles, which are not the US ones', function()
            assert.is_true(anmalan.isRoll('malsagande'))
            assert.is_true(anmalan.isRoll('misstankt'))
            assert.is_true(anmalan.isRoll('anmalare'))

            assert.is_false(anmalan.isRoll('victim'))
            assert.is_false(anmalan.isRoll('suspect'))
        end)

        it('knows the BrB 23 stages', function()
            assert.is_true(anmalan.isStage('fullbordat'))
            assert.is_true(anmalan.isStage('forsok'))
            assert.is_true(anmalan.isStage('forberedelse'))
            assert.is_true(anmalan.isStage('stampling'))

            assert.is_false(anmalan.isStage('attempted'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('the transition map', function()
        it('submits a draft', function()
            assert.are.equal('inlamnad', anmalan.nextStatus('utkast', 'submit'))
        end)

        it('resubmits a returned one through the same action', function()
            -- An author fixing what the supervisor asked for does the same
            -- thing they did the first time; a separate `resubmit` would be a
            -- second code path doing one job.
            assert.are.equal('inlamnad', anmalan.nextStatus('atersand', 'submit'))
        end)

        it('returns and approves only from inlamnad', function()
            assert.are.equal('atersand', anmalan.nextStatus('inlamnad', 'return'))
            assert.are.equal('godkand', anmalan.nextStatus('inlamnad', 'approve'))

            assert.is_nil(anmalan.nextStatus('utkast', 'approve'))
            assert.is_nil(anmalan.nextStatus('atersand', 'approve'))
        end)

        it('makes godkand terminal', function()
            -- No row for it in the map, so nothing moves an approved anmälan
            -- anywhere. This is 7.7's locking rule as a data structure.
            assert.is_nil(anmalan.nextStatus('godkand', 'submit'))
            assert.is_nil(anmalan.nextStatus('godkand', 'return'))
            assert.is_nil(anmalan.nextStatus('godkand', 'approve'))
        end)

        it('has no transition for an action that does not exist', function()
            assert.is_nil(anmalan.nextStatus('utkast', 'delete'))
            assert.is_nil(anmalan.nextStatus('utkast', 'void'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('canApprove', function()
        it('lets a supervisor approve somebody else\'s submitted anmälan', function()
            assert.is_true(anmalan.canApprove(report({ status = 'inlamnad' }), 'boss', true))
        end)

        it('REFUSES an author approving their own, whatever they hold', function()
            -- The rule the module exists to hold. `true` is the approve grant:
            -- holding it changes nothing here, and there is deliberately no
            -- second permission that would.
            local ok, why = anmalan.canApprove(
                report({ status = 'inlamnad', createdBy = 'author' }), 'author', true)

            assert.is_false(ok)
            assert.are.equal('own_report', why)
        end)

        it('refuses somebody without the grant', function()
            local ok, why = anmalan.canApprove(report({ status = 'inlamnad' }), 'boss', false)

            assert.is_false(ok)
            assert.are.equal('forbidden', why)
        end)

        it('refuses anything that is not submitted', function()
            for _, status in ipairs({ 'utkast', 'atersand', 'godkand' }) do
                local ok, why = anmalan.canApprove(report({ status = status }), 'boss', true)

                assert.is_false(ok)
                assert.are.equal('not_submitted', why)
            end
        end)

        it('checks the grant before the status, so a stranger learns nothing', function()
            -- Somebody with no business approving should be told they may not
            -- approve, not which stage of review the report is at.
            local _, why = anmalan.canApprove(report({ status = 'utkast' }), 'nobody', false)

            assert.are.equal('forbidden', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('canEdit', function()
        it('lets the author edit a draft', function()
            assert.is_true(anmalan.canEdit(report(), 'author', false))
        end)

        it('lets the author edit one that came back', function()
            assert.is_true(anmalan.canEdit(report({ status = 'atersand' }), 'author', false))
        end)

        it('refuses an approved anmälan to everyone, grant or not', function()
            local ok, why = anmalan.canEdit(report({ status = 'godkand' }), 'author', true)

            assert.is_false(ok)
            assert.are.equal('locked', why)
        end)

        it('refuses editing one that is on a supervisor\'s desk', function()
            -- Changing the thing being reviewed while it is being reviewed.
            local ok, why = anmalan.canEdit(report({ status = 'inlamnad' }), 'author', false)

            assert.is_false(ok)
            assert.are.equal('under_review', why)
        end)

        it('refuses somebody else\'s draft without the department grant', function()
            local ok, why = anmalan.canEdit(report(), 'stranger', false)

            assert.is_false(ok)
            assert.are.equal('not_author', why)
        end)

        it('allows somebody else\'s draft with it', function()
            assert.is_true(anmalan.canEdit(report(), 'stranger', true))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('canSubmit', function()
        it('lets the author submit a draft or a returned one', function()
            assert.is_true(anmalan.canSubmit(report(), 'author', false))
            assert.is_true(anmalan.canSubmit(report({ status = 'atersand' }), 'author', false))
        end)

        it('refuses submitting an approved one, and says it is locked', function()
            local ok, why = anmalan.canSubmit(report({ status = 'godkand' }), 'author', false)

            assert.is_false(ok)
            assert.are.equal('locked', why)
        end)

        it('refuses submitting one that is already submitted', function()
            local ok, why = anmalan.canSubmit(report({ status = 'inlamnad' }), 'author', false)

            assert.is_false(ok)
            assert.are.equal('not_submittable', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('parentIsAllowed', function()
        --- A chain expressed as a table: `{ [child] = parent }`.
        local function chainOf(links)
            return function(id) return links[id] end
        end

        it('allows a supplement to a parent with no parent of its own', function()
            assert.is_true(anmalan.parentIsAllowed(2, 1, chainOf({})))
        end)

        it('allows a new row, which has no id yet', function()
            assert.is_true(anmalan.parentIsAllowed(nil, 1, chainOf({})))
        end)

        it('refuses a row parenting itself', function()
            -- The rule MariaDB would not take: it refuses a CHECK against an
            -- AUTO_INCREMENT column, so this is the only place it exists.
            local ok, why = anmalan.parentIsAllowed(1, 1, chainOf({}))

            assert.is_false(ok)
            assert.are.equal('self_parent', why)
        end)

        it('refuses a longer cycle', function()
            -- 3's proposed parent is 2, whose parent is 1, whose parent would
            -- become 3. Not expressible in a CHECK at all.
            local ok, why = anmalan.parentIsAllowed(3, 2, chainOf({ [2] = 1, [1] = 3 }))

            assert.is_false(ok)
            assert.are.equal('cycle', why)
        end)

        it('refuses a cycle that does not pass through the child', function()
            -- Already-broken data. Walking it would not terminate.
            local ok, why = anmalan.parentIsAllowed(9, 1, chainOf({ [1] = 2, [2] = 1 }))

            assert.is_false(ok)
            assert.are.equal('cycle', why)
        end)

        it('refuses a chain deeper than the cap', function()
            local links = {}
            for id = 1, 20 do links[id] = id + 1 end

            local ok, why = anmalan.parentIsAllowed(99, 1, chainOf(links))

            assert.is_false(ok)
            assert.are.equal('too_deep', why)
        end)

        it('refuses a parent that is not an id', function()
            assert.is_false(anmalan.parentIsAllowed(1, nil, chainOf({})))
            assert.is_false(anmalan.parentIsAllowed(1, 'two', chainOf({})))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('stageIsAvailable (BrB 23)', function()
        it('always allows the completed offence', function()
            assert.is_true(anmalan.stageIsAvailable({ forsok = 0, forberedelse = 0 }, 'fullbordat'))
        end)

        it('allows försök only where the statute makes it punishable', function()
            assert.is_true(anmalan.stageIsAvailable({ forsok = 1 }, 'forsok'))
            assert.is_false(anmalan.stageIsAvailable({ forsok = 0 }, 'forsok'))
        end)

        it('allows förberedelse and stämpling together', function()
            -- Brottsbalken names them in the same paragraf of each kapitel.
            assert.is_true(anmalan.stageIsAvailable({ forberedelse = 1 }, 'forberedelse'))
            assert.is_true(anmalan.stageIsAvailable({ forberedelse = 1 }, 'stampling'))
            assert.is_false(anmalan.stageIsAvailable({ forberedelse = 0 }, 'stampling'))
        end)

        it('accepts booleans as well as the 1 MariaDB hands back', function()
            assert.is_true(anmalan.stageIsAvailable({ forsok = true }, 'forsok'))
        end)

        it('refuses a stage that is not one', function()
            assert.is_false(anmalan.stageIsAvailable({ forsok = 1 }, 'attempted'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('groupCharges', function()
        it('groups counts by misstänkt and keeps the rest apart', function()
            local byPerson, loose = anmalan.groupCharges({
                { id = 1, personId = 7 },
                { id = 2, personId = nil },
                { id = 3, personId = 7 },
                { id = 4, personId = 8 },
            })

            assert.are.equal(2, #byPerson[7])
            assert.are.equal(1, #byPerson[8])
            assert.are.equal(1, #loose)
            assert.are.equal(2, loose[1].id)
        end)

        it('treats charges against nobody as ordinary, not as an error', function()
            -- Most anmälningar are written with no suspect at all.
            local byPerson, loose = anmalan.groupCharges({ { id = 1 }, { id = 2 } })

            assert.is_nil(next(byPerson))
            assert.are.equal(2, #loose)
        end)

        it('survives an empty list', function()
            local byPerson, loose = anmalan.groupCharges({})

            assert.is_nil(next(byPerson))
            assert.are.equal(0, #loose)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('the förundersökning lifecycle', function()
        it('runs slutdelgivning before redovisning (RB 23:18a)', function()
            assert.are.equal('slutdelgiven', anmalan.nextFuStatus('inledd', 'slutdelge'))
            assert.are.equal('redovisad', anmalan.nextFuStatus('slutdelgiven', 'redovisa'))

            -- Not straight to the prosecutor: the misstänkt has to have been
            -- given the material first.
            assert.is_nil(anmalan.nextFuStatus('inledd', 'redovisa'))
        end)

        it('allows nedläggning from either open state', function()
            assert.are.equal('nedlagd', anmalan.nextFuStatus('inledd', 'lagg_ned'))
            assert.are.equal('nedlagd', anmalan.nextFuStatus('slutdelgiven', 'lagg_ned'))
        end)

        it('makes both endings terminal', function()
            for _, action in ipairs({ 'slutdelge', 'redovisa', 'lagg_ned' }) do
                assert.is_nil(anmalan.nextFuStatus('nedlagd', action))
                assert.is_nil(anmalan.nextFuStatus('redovisad', action))
            end
        end)

        it('knows which FUs are still running', function()
            assert.is_true(anmalan.fuIsOpen({ status = 'inledd' }))
            assert.is_true(anmalan.fuIsOpen({ status = 'slutdelgiven' }))
            assert.is_false(anmalan.fuIsOpen({ status = 'nedlagd' }))
            assert.is_false(anmalan.fuIsOpen({ status = 'redovisad' }))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('canDecide', function()
        local fu = { status = 'inledd', fuLedare = 'ledare' }

        it('lets the FU-ledare decide', function()
            assert.is_true(anmalan.canDecide(fu, 'ledare', false))
        end)

        it('refuses somebody who is not leading it', function()
            local ok, why = anmalan.canDecide(fu, 'someone', false)

            assert.is_false(ok)
            assert.are.equal('not_ledare', why)
        end)

        it('lets a supervisor with the department grant reassign a stalled one', function()
            assert.is_true(anmalan.canDecide(fu, 'someone', true))
        end)

        it('refuses a decision in a closed FU, even to its ledare', function()
            local ok, why = anmalan.canDecide(
                { status = 'nedlagd', fuLedare = 'ledare' }, 'ledare', true)

            assert.is_false(ok)
            assert.are.equal('fu_closed', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('aklagareIndicated', function()
        it('flags a charge carrying two years or more', function()
            assert.is_true(anmalan.aklagareIndicated({ { min = 0, max = 24 } }))
            assert.is_true(anmalan.aklagareIndicated({ { min = 6, max = 72 } }))
        end)

        it('flags livstid', function()
            assert.is_true(anmalan.aklagareIndicated({ { min = 120, max = nil } }))
        end)

        it('does not flag a light charge', function()
            assert.is_false(anmalan.aklagareIndicated({ { min = 0, max = 6 } }))
            assert.is_false(anmalan.aklagareIndicated({ { min = 0, max = 12 } }))
        end)

        it('flags the set when any one charge reaches it', function()
            assert.is_true(anmalan.aklagareIndicated({
                { min = 0, max = 6 }, { min = 0, max = 36 },
            }))
        end)

        it('does not flag an empty set', function()
            assert.is_false(anmalan.aklagareIndicated({}))
            assert.is_false(anmalan.aklagareIndicated(nil))
        end)
    end)
end)

describe('anmalan drafts', function()
    local anmalan

    before_each(function()
        anmalan = helper.load({ 'server/modules/anmalan/service' }).Modules.anmalan
    end)

    it('starts a report after an arrest, a fine or "report taken"', function()
        assert.is_true(anmalan.dispositionNeedsReport('arrest_made'))
        assert.is_true(anmalan.dispositionNeedsReport('citation_issued'))
        assert.is_true(anmalan.dispositionNeedsReport('report_taken'))
    end)

    it('starts none for a call that turned out to be nothing', function()
        assert.is_false(anmalan.dispositionNeedsReport('unfounded'))
        assert.is_false(anmalan.dispositionNeedsReport('gone_on_arrival'))
        assert.is_false(anmalan.dispositionNeedsReport(nil))
    end)

    it('adds to a report only while it is still the author\'s to edit', function()
        assert.is_true(anmalan.isEditable('utkast'))
        assert.is_true(anmalan.isEditable('atersand'))
        assert.is_false(anmalan.isEditable('inlamnad'))
        assert.is_false(anmalan.isEditable('godkand'))
    end)
end)

describe('anmalan events', function()
    local handlers, state

    before_each(function()
        handlers, state = {}, { created = {}, persons = {}, notified = {}, existing = nil }

        local FredPD = helper.load({ 'server/modules/anmalan/service', 'server/modules/access/service' })
        state.canCreate = true

        FredPD.t = function(key) return key end
        FredPD.Repo = {
            anmalan = {
                forCall = function() return state.existing end,
                create = function(input, session)
                    state.created[#state.created + 1] = { input = input, session = session }
                    return { id = 40, number = 'LSPD-26-000140', title = input.title, callId = input.callId }
                end,
                setPerson = function(anmalanId, personId, roll)
                    state.persons[#state.persons + 1] = { anmalanId = anmalanId, personId = personId, roll = roll }
                end,
            },
            cad = { activeAssignment = function() return state.assignment end },
        }
        FredPD.Core = {
            session = {
                all = function()
                    return { [1] = { agencyId = 'lspd', discordId = '1', permissions = {} } }
                end,
                isStale = function() return false end,
            },
            perms = { satisfies = function() return state.canCreate end },
            audit = { write = function() state.audits = (state.audits or 0) + 1 end },
            push = {
                notifyWhere = function(_predicate, key, params)
                    state.notified[#state.notified + 1] = { key = key, params = params }
                end,
            },
        }

        _G.AddEventHandler = function(name, handler) handlers[name] = handler end
        assert(loadfile('resources/[fredpd]/fredpd/server/modules/anmalan/events.lua'))()
    end)

    after_each(function() _G.AddEventHandler = nil end)

    it('starts a draft after an arrest, with the arrested person as a suspect, on the officer\'s call', function()
        state.assignment = { callId = 12 }

        handlers['fredpd:gripande']({ agencyId = 'lspd', discordId = '1', personId = 3, frihetId = 9 })

        assert.are.equal(12, state.created[1].input.callId)
        assert.are.equal('1', state.created[1].session.discordId)
        assert.are.same({ anmalanId = 40, personId = 3, roll = 'misstankt' }, state.persons[1])
        assert.are.equal('anmalan.notify.draft', state.notified[1].key)
    end)

    it('adds the person to the call\'s open draft instead of starting another', function()
        state.assignment = { callId = 12 }
        state.existing = {
            id = 7, number = 'LSPD-26-000107', status = 'utkast', createdBy = '1', classification = 'internal',
        }

        handlers['fredpd:gripande']({ agencyId = 'lspd', discordId = '1', personId = 3 })

        assert.are.same({}, state.created)
        assert.are.equal(7, state.persons[1].anmalanId)
        assert.are.same({}, state.notified)
    end)

    it('starts a draft when a call is cleared with a report taken', function()
        handlers['fredpd:callCleared']({
            agencyId = 'lspd', discordId = '1', callId = 5, disposition = 'report_taken',
            callNumber = 'C-26-0005', type = 'theft', locationText = 'Grove St',
        })

        assert.are.equal(5, state.created[1].input.callId)
        assert.are.equal('Grove St', state.created[1].input.occurredPlace)
    end)

    it('never adds to another officer\'s draft; starts the officer\'s own', function()
        state.assignment = { callId = 12 }
        state.existing = {
            id = 7, number = 'LSPD-26-000107', status = 'utkast', createdBy = '2', classification = 'internal',
        }

        handlers['fredpd:gripande']({ agencyId = 'lspd', discordId = '1', personId = 3 })

        assert.are.equal(1, #state.created)
        assert.are.equal(40, state.persons[1].anmalanId)
    end)

    it('files the draft no lower than the arrest or the person', function()
        handlers['fredpd:gripande']({
            agencyId = 'lspd', discordId = '1', personId = 3,
            classification = 'internal', personClassification = 'confidential',
        })

        assert.are.equal('confidential', state.created[1].input.classification)
    end)

    it('writes nothing for somebody without the report grant, such as a dispatcher', function()
        state.canCreate = false

        handlers['fredpd:callCleared']({
            agencyId = 'lspd', discordId = '1', callId = 5, disposition = 'report_taken',
        })

        assert.are.same({}, state.created)
    end)

    it('starts nothing for a call cleared as unfounded', function()
        handlers['fredpd:callCleared']({ agencyId = 'lspd', discordId = '1', callId = 5, disposition = 'unfounded' })

        assert.are.same({}, state.created)
    end)
end)
