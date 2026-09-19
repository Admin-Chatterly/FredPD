--- Frihetsberövande (spec 7.9).
---
--- The clocks are what this file is for.
---
--- **RB 24:12** is the one that is easy to get almost right: a
--- häktningsframställan must reach the court *senast klockan tolv tredje dagen
--- efter anhållningsbeslutet*. That is a wall-clock noon, not seventy-two
--- hours, and the difference is not academic -- depending on the hour of the
--- anhållande the two readings differ by up to twelve hours in either
--- direction. An implementation that added 72 hours would show a wrong number
--- on a countdown nobody would think to check, and would be found out only when
--- a detention was challenged.
---
--- So the cases below fix a concrete anhållande and assert the exact instant
--- the statute gives, computed independently of the implementation.
---
--- **RB 24:13** is the simple one -- four dygn really is 96 hours -- and it is
--- tested mostly to pin that the two rules have not been given each other's
--- arithmetic.

local helper = require('spec.helper')

describe('frihet', function()
    local frihet

    before_each(function()
        frihet = helper.load({ 'server/modules/frihet/service' }).Modules.frihet
    end)

    --- An instant, given as UTC parts, as epoch seconds.
    ---
    --- Built with the module's own `timegm` so the test and the code agree on
    --- what "14:00 UTC on the 9th" means without the test having to know the
    --- machine's timezone.
    local function utc(year, month, day, hour, min)
        return frihet.timegm({
            year = year, month = month, day = day,
            hour = hour, min = min or 0, sec = 0,
        })
    end

    --- Everything below runs at UTC+0, so the local noon of RB 24:12 is a noon
    --- the test can write down. The offset is a parameter precisely so this is
    --- possible; a server in Europe/Stockholm passes its own.
    local UTC <const> = 0

    -- -------------------------------------------------------------------------
    describe('the chain', function()
        it('knows its five stages and nothing else', function()
            assert.is_true(frihet.isStatus('gripen'))
            assert.is_true(frihet.isStatus('anhallen'))
            assert.is_true(frihet.isStatus('framstalld'))
            assert.is_true(frihet.isStatus('haktad'))
            assert.is_true(frihet.isStatus('frigiven'))

            assert.is_false(frihet.isStatus('arrested'))
            assert.is_false(frihet.isStatus('booked'))
        end)

        it('runs gripande, anhållande, framställan, häktning in order', function()
            assert.are.equal('anhallen', frihet.nextStatus('gripen', 'anhall'))
            assert.are.equal('framstalld', frihet.nextStatus('anhallen', 'framstall'))
            assert.are.equal('haktad', frihet.nextStatus('framstalld', 'hakta'))
        end)

        it('refuses a häktning that skips the anhållande', function()
            -- Not a permissions problem: a detention with no legal basis.
            assert.is_nil(frihet.nextStatus('gripen', 'hakta'))
            assert.is_nil(frihet.nextStatus('gripen', 'framstall'))
        end)

        it('allows release from every open stage', function()
            -- The commonest outcome at the first stage is a release, not an
            -- anhållande: a release path that only existed at the end would
            -- leave it unrecordable.
            for _, status in ipairs({ 'gripen', 'anhallen', 'framstalld', 'haktad' }) do
                assert.are.equal('frigiven', frihet.nextStatus(status, 'frigiv'))
            end
        end)

        it('has no way out of frigiven', function()
            -- Somebody arrested again is a new chain with its own clocks, not a
            -- reopening of one whose deadlines have already expired.
            for action in pairs({ anhall = 1, framstall = 1, hakta = 1, frigiv = 1 }) do
                assert.is_nil(frihet.nextStatus('frigiven', action))
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('who decides (RB)', function()
        it('gives anhållande and framställan to the åklagare', function()
            assert.are.equal('aklagare', frihet.deciderFor('anhall'))
            assert.are.equal('aklagare', frihet.deciderFor('framstall'))
        end)

        it('gives häktning to the domare', function()
            assert.are.equal('domare', frihet.deciderFor('hakta'))
        end)

        it('lets anybody release', function()
            -- A frihetsberövande that should end must be able to end at once,
            -- without waiting for the right rank to be online.
            assert.is_nil(frihet.deciderFor('frigiv'))
        end)

        it('refuses an officer anhållande somebody', function()
            local ok, why = frihet.canDecide({ status = 'gripen' }, 'anhall', 'polis')

            assert.is_false(ok)
            assert.are.equal('wrong_capacity', why)
        end)

        it('lets the åklagare anhålla', function()
            assert.is_true(frihet.canDecide({ status = 'gripen' }, 'anhall', 'aklagare'))
        end)

        it('lets an officer release', function()
            assert.is_true(frihet.canDecide({ status = 'gripen' }, 'frigiv', 'polis'))
        end)

        it('refuses any decision once the person is released', function()
            local ok, why = frihet.canDecide({ status = 'frigiven' }, 'anhall', 'aklagare')

            assert.is_false(ok)
            assert.are.equal('already_released', why)
        end)

        it('checks the transition before the capacity', function()
            -- A häktning from `gripen` is refused as impossible rather than as
            -- somebody's missing rank: the first is the real objection.
            local _, why = frihet.canDecide({ status = 'gripen' }, 'hakta', 'polis')

            assert.are.equal('out_of_order', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('RB 24:12 — noon on the third day', function()
        it('is noon three days later, not seventy-two hours', function()
            -- Anhållande Monday 9 March 2026 at 14:00. The third day after is
            -- Thursday the 12th, so the deadline is Thursday 12:00 -- which is
            -- 70 hours away, not 72.
            local anhallen = utc(2026, 3, 9, 14, 0)
            local expected = utc(2026, 3, 12, 12, 0)

            local deadlines = frihet.deadlines(
                { status = 'anhallen', anhallenAt = anhallen }, anhallen, UTC)

            assert.are.equal(expected, deadlines.framstallan.at)
            assert.are.equal(70 * 3600, deadlines.framstallan.remaining)
        end)

        it('is further away for a morning anhållande than for an evening one', function()
            -- The asymmetry a 72-hour implementation erases. 08:00 gives 76
            -- hours; 22:00 the same day gives 62.
            local morning = utc(2026, 3, 9, 8, 0)
            local evening = utc(2026, 3, 9, 22, 0)

            local a = frihet.deadlines({ anhallenAt = morning }, morning, UTC)
            local b = frihet.deadlines({ anhallenAt = evening }, evening, UTC)

            assert.are.equal(76 * 3600, a.framstallan.remaining)
            assert.are.equal(62 * 3600, b.framstallan.remaining)

            -- Both land on the same instant: the same noon.
            assert.are.equal(a.framstallan.at, b.framstallan.at)
        end)

        it('crosses a month boundary without month arithmetic', function()
            -- 30 March + 3 days is 2 April. `os.time` normalises the overflow.
            local anhallen = utc(2026, 3, 30, 9, 0)

            local deadlines = frihet.deadlines({ anhallenAt = anhallen }, anhallen, UTC)

            assert.are.equal(utc(2026, 4, 2, 12, 0), deadlines.framstallan.at)
        end)

        it('reports a passed deadline as passed', function()
            local anhallen = utc(2026, 3, 9, 14, 0)
            local later = utc(2026, 3, 12, 12, 1)

            local deadlines = frihet.deadlines({ anhallenAt = anhallen }, later, UTC)

            assert.is_true(deadlines.framstallan.passed)
            assert.is_true(deadlines.framstallan.remaining < 0)
        end)

        it('stops counting once the framställan has been made', function()
            -- The deadline was met; a countdown against it afterwards is noise.
            local anhallen = utc(2026, 3, 9, 14, 0)

            local deadlines = frihet.deadlines({
                anhallenAt = anhallen,
                framstallanAt = utc(2026, 3, 10, 9, 0),
            }, anhallen, UTC)

            assert.is_nil(deadlines.framstallan)
        end)

        it('has no framställan deadline before there is an anhållande', function()
            local deadlines = frihet.deadlines(
                { status = 'gripen', gripenAt = utc(2026, 3, 9, 14, 0) },
                utc(2026, 3, 9, 15, 0), UTC)

            assert.is_nil(deadlines.framstallan)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('RB 24:13 — four dygn', function()
        it('is ninety-six hours from the gripande', function()
            local gripen = utc(2026, 3, 9, 14, 0)

            local deadlines = frihet.deadlines(
                { status = 'gripen', gripenAt = gripen }, gripen, UTC)

            assert.are.equal(gripen + 96 * 3600, deadlines.forhandling.at)
            assert.are.equal(96 * 3600, deadlines.forhandling.remaining)
        end)

        it('runs from the anhållande when there was no gripande', function()
            -- Somebody anhållen i sin frånvaro who presents themselves.
            local anhallen = utc(2026, 3, 9, 14, 0)

            local deadlines = frihet.deadlines({ anhallenAt = anhallen }, anhallen, UTC)

            assert.are.equal(anhallen + 96 * 3600, deadlines.forhandling.at)
        end)

        it('stops once the person has been häktad', function()
            local gripen = utc(2026, 3, 9, 14, 0)

            local deadlines = frihet.deadlines({
                gripenAt = gripen, haktadAt = utc(2026, 3, 11, 10, 0),
            }, gripen, UTC)

            assert.is_nil(deadlines.forhandling)
        end)

        it('is not given RB 24:12\'s arithmetic', function()
            -- The two rules produce different instants for the same start, and
            -- this is the assertion that catches them being swapped.
            local at = utc(2026, 3, 9, 14, 0)

            local deadlines = frihet.deadlines(
                { gripenAt = at, anhallenAt = at }, at, UTC)

            assert.are_not.equal(deadlines.framstallan.at, deadlines.forhandling.at)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('nextDeadline', function()
        it('shows the nearer of the two', function()
            local at = utc(2026, 3, 9, 14, 0)
            -- framställan noon on the 12th (70h), förhandling 96h.
            local key = frihet.nextDeadline({ gripenAt = at, anhallenAt = at }, at, UTC)

            assert.are.equal('framstallan', key)
        end)

        it('shows a passed deadline ahead of a nearer pending one', function()
            -- A missed deadline is not something to show second.
            local gripen = utc(2026, 3, 9, 0, 0)
            local anhallen = utc(2026, 3, 9, 0, 0)
            -- Past the noon on the 12th, but still inside the 96 hours? No --
            -- 96h from midnight on the 9th is midnight on the 13th, and the
            -- noon was on the 12th. So at 13:00 on the 12th the first has
            -- passed and the second has not.
            local now = utc(2026, 3, 12, 13, 0)

            local key, deadline = frihet.nextDeadline(
                { gripenAt = gripen, anhallenAt = anhallen }, now, UTC)

            assert.are.equal('framstallan', key)
            assert.is_true(deadline.passed)
        end)

        it('has nothing to show for a released chain with both stages done', function()
            local at = utc(2026, 3, 9, 14, 0)

            local key = frihet.nextDeadline({
                gripenAt = at, anhallenAt = at,
                framstallanAt = at, haktadAt = at,
            }, at, UTC)

            assert.is_nil(key)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('heldFor', function()
        it('grows while the person is held', function()
            local gripen = utc(2026, 3, 9, 14, 0)

            assert.are.equal(3600, frihet.heldFor({ gripenAt = gripen }, gripen + 3600))
        end)

        it('stops at the release rather than growing forever', function()
            local gripen = utc(2026, 3, 9, 14, 0)
            local row = { gripenAt = gripen, frigivenAt = gripen + 7200 }

            assert.are.equal(7200, frihet.heldFor(row, gripen + 999999))
        end)

        it('has no answer before anything happened', function()
            assert.is_nil(frihet.heldFor({}, 1))
            assert.is_nil(frihet.heldFor(nil, 1))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('needsAttention', function()
        it('flags a chain whose deadline has passed', function()
            local anhallen = utc(2026, 3, 9, 14, 0)
            local now = utc(2026, 3, 12, 13, 0)

            assert.is_true(frihet.needsAttention({ anhallenAt = anhallen }, now, UTC))
        end)

        it('flags one inside the warning window', function()
            local anhallen = utc(2026, 3, 9, 14, 0)
            -- Two hours before the noon on the 12th.
            local now = utc(2026, 3, 12, 10, 0)

            assert.is_true(frihet.needsAttention({ anhallenAt = anhallen }, now, UTC))
        end)

        it('does not flag one with days to run', function()
            local anhallen = utc(2026, 3, 9, 14, 0)

            assert.is_false(frihet.needsAttention({ anhallenAt = anhallen }, anhallen, UTC))
        end)

        it('does not flag a chain with no live deadline', function()
            assert.is_false(frihet.needsAttention({ status = 'frigiven' }, 1, UTC))
        end)
    end)
end)
