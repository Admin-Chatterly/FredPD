--- Dispatch (CAD) logic (spec 7.16, 7.17, Appendix D).
---
--- Six decisions, and none of them can be checked by looking at a running
--- server. Four are arithmetic that is either exactly right or quietly wrong:
--- the queue order, the distance sort behind a recommendation, the welfare
--- timer, and a call number at midnight. The other two are geometry, where
--- "quietly wrong" means a beat that stops tagging calls along one edge and
--- looks like a district nobody patrols.
---
--- The two assertions worth reading first are the boundary cases. A point on
--- the edge between two districts, and a point exactly on a vertex, are the
--- positions a ray cast answers by accident -- and a boundary that belongs to
--- neither beat is a call that lands nowhere, in the middle of the map, absent
--- from every per-beat report.

local helper = require('spec.helper')

describe('cad', function()
    local cad

    before_each(function()
        -- The generated schema comes first: the service reads its vocabularies
        -- from `FredPD.UnitStatus` and friends rather than hand-copying a
        -- status list that could drift from the database's CHECK.
        cad = helper.load({
            'shared/generated/schema',
            'server/modules/cad/service',
        }).Modules.cad
    end)

    -- -------------------------------------------------------------------------
    -- Configuration
    -- -------------------------------------------------------------------------

    describe('settings', function()
        it('merges a server override without losing the rest', function()
            local config = cad.settings({ welfareSeconds = { en_route = 600 } })

            assert.are.equal(600, config.welfareSeconds.en_route)
            -- The documented default survives a server adding a second status.
            assert.are.equal(20 * 60, config.welfareSeconds.on_scene)
            assert.are.equal(3, config.recommendLimit)
        end)

        it('never mutates the defaults', function()
            local config = cad.settings({ recommendLimit = 9 })

            assert.are.equal(9, config.recommendLimit)
            assert.are.equal(3, cad.defaults.recommendLimit)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Call numbers (Appendix D)
    -- -------------------------------------------------------------------------

    describe('call numbers', function()
        --- 18 September 2026, 09:00 UTC.
        local september <const> = 1789722000

        it('scopes the counter to the day, not the year', function()
            -- The whole reason 0007 widened `fpd_counters.year` to MEDIUMINT:
            -- a call restarts daily, so its scope key is six digits and does
            -- not fit the SMALLINT every other sequence uses.
            assert.are.equal(260918, cad.dayKey(september))
            assert.are.equal(260919, cad.dayKey(september + 86400))
        end)

        it('reads the day in UTC, because the timestamps are', function()
            -- 23:30 UTC on the 18th is the 19th in Stockholm. `received_at` is
            -- stamped by the database in UTC (13.1), so the day key has to be
            -- UTC too, or every call taken after ten at night would print a
            -- number naming the wrong day.
            assert.are.equal(260918, cad.dayKey(september + (14 * 3600) + (30 * 60)))
        end)

        it('gives the format Appendix D gives', function()
            assert.are.equal('260918-0042', cad.callNumber(260918, 42))
            assert.are.equal('260918-0001', cad.callNumber(260918, 1))
        end)

        it('keeps the leading zero of a January day key', function()
            -- 5 January 2026 is day key 260105, and as a bare number it would
            -- print as `26105-0001` -- a different day, six characters instead
            -- of seven, sorting between September and October.
            assert.are.equal('260105-0001', cad.callNumber(260105, 1))
        end)

        it('builds the same number the INSERT does', function()
            -- The database concatenates the prefix with the padded counter
            -- inside the INSERT (`Counters.numberSql`), so nothing can slip
            -- between reading the sequence and using it. This proves the two
            -- ways of building the number agree byte for byte.
            local prefix, width = cad.callNumberPrefix(260918)

            assert.are.equal('260918-', prefix)
            assert.are.equal(4, width)
            assert.are.equal(cad.callNumber(260918, 7), prefix .. ('%04d'):format(7))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The pending queue (7.16)
    -- -------------------------------------------------------------------------

    describe('the pending queue', function()
        local function call(id, priority, receivedAtUnix, status)
            return {
                id = id,
                priority = priority,
                receivedAtUnix = receivedAtUnix,
                status = status or 'pending',
            }
        end

        it('stacks by priority first and age second', function()
            local queue = cad.stackQueue({
                call(1, 3, 1000),
                call(2, 1, 3000),
                call(3, 3, 2000),
                call(4, 2, 4000),
            })

            local order = {}
            for index = 1, #queue do order[index] = queue[index].id end

            assert.are.same({ 2, 4, 1, 3 }, order)
        end)

        it('puts a new P1 above a P3 that has waited an hour', function()
            -- The rule somebody will open a bug report about. A priority is a
            -- statement about what is happening to a person, and an hour does
            -- not turn a noise complaint into a stabbing.
            local old = call(1, 3, 1000)
            local fresh = call(2, 1, 1000 + 3600)

            assert.is_true(cad.aheadInQueue(fresh, old))
            assert.is_false(cad.aheadInQueue(old, fresh))
        end)

        it('puts the older of two calls at the same priority first', function()
            local older = call(1, 2, 1000)
            local newer = call(2, 2, 1200)

            assert.is_true(cad.aheadInQueue(older, newer))
            assert.is_false(cad.aheadInQueue(newer, older))
        end)

        it('drops closed calls out of the queue', function()
            -- The same test `queue_priority` makes in SQL, restated for a set
            -- that has not been through the database yet.
            local queue = cad.stackQueue({
                call(1, 1, 1000, 'cleared'),
                call(2, 3, 2000, 'pending'),
                call(3, 1, 1500, 'cancelled'),
                call(4, 2, 3000, 'on_scene'),
            })

            assert.are.equal(2, #queue)
            assert.are.equal(4, queue[1].id)
            assert.are.equal(2, queue[2].id)
        end)

        it('orders a tie deterministically instead of raising', function()
            -- Two calls raised in the same millisecond at the same priority
            -- compare equal in both directions without the id tie-break, and
            -- `table.sort` may then raise "invalid order function for sorting".
            local first = call(10, 2, 1000)
            local second = call(11, 2, 1000)

            assert.is_true(cad.aheadInQueue(first, second))
            assert.is_false(cad.aheadInQueue(second, first))
        end)

        it('sinks a row with no priority rather than passing it off as a P4', function()
            local malformed = call(1, nil, 1000)
            local routine = call(2, 4, 5000)

            assert.is_true(cad.aheadInQueue(routine, malformed))
        end)

        it('orders rows that carry only a formatted timestamp', function()
            -- `DATETIME(3)` renders as `YYYY-MM-DD HH:MM:SS.mmm`, which sorts
            -- chronologically as text. Every repo read supplies the epoch
            -- beside it; this is the fallback for a row from anywhere else.
            local older = { id = 1, priority = 2, receivedAt = '2026-09-18 08:00:00.000', status = 'pending' }
            local newer = { id = 2, priority = 2, receivedAt = '2026-09-18 09:30:00.000', status = 'pending' }

            assert.is_true(cad.aheadInQueue(older, newer))
        end)

        it('does not reorder the caller\'s own list', function()
            local calls = { call(1, 3, 1000), call(2, 1, 2000) }

            cad.stackQueue(calls)

            assert.are.equal(1, calls[1].id)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Recommending units (7.16)
    -- -------------------------------------------------------------------------

    describe('recommending units', function()
        local now <const> = 1789722000

        local function unit(officerId, x, y, overrides)
            local row = {
                officerId = officerId,
                callsign = ('3A-%d'):format(officerId),
                status = 'available',
                x = x,
                y = y,
                positionAtUnix = now,
            }

            for key, value in pairs(overrides or {}) do
                row[key] = value ~= helper.NONE and value or nil
            end

            return row
        end

        it('offers the closest free units, nearest first', function()
            local recommended = cad.recommendUnits({
                unit(1, 300, 0),
                unit(2, 50, 0),
                unit(3, 120, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(3, #recommended)
            assert.are.same({ 2, 3, 1 }, {
                recommended[1].officerId, recommended[2].officerId, recommended[3].officerId,
            })
            assert.are.equal(50, recommended[1].distance)
        end)

        it('ignores height, because a unit on the overpass is not closer', function()
            -- 2D on purpose: forty metres of altitude is not forty metres of
            -- driving, and including z would rank the overpass above the car
            -- at street level that can actually get there.
            local recommended = cad.recommendUnits({
                unit(1, 0, 100, { z = 400 }),
            }, { x = 0, y = 0, z = 0 }, { now = now })

            assert.are.equal(100, recommended[1].distance)
        end)

        it('does not offer a unit that is on a call', function()
            -- The half a distance sort gets wrong: the unit standing at the
            -- shooting two streets away is by definition the nearest one to the
            -- next call on that street.
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { status = 'on_scene', onCallId = 55, onCallPriority = 1 }),
                unit(2, 900, 0),
            }, { x = 0, y = 0 }, { now = now, callPriority = 2 })

            assert.are.equal(1, #recommended)
            assert.are.equal(2, recommended[1].officerId)
        end)

        it('does not offer a unit that says available while still on a call', function()
            -- `fpd_units.status` is the unit's own word and `fpd_call_units` is
            -- the live row; when they disagree, somebody is standing at a call
            -- expecting that unit.
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { status = 'available', onCallId = 55 }),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(0, #recommended)
        end)

        it('offers a unit on a lesser call, ranked below every free one', function()
            -- A unit taking a report two hundred metres from a shots-fired call
            -- is the right answer and dispatch knows it -- but it is a decision
            -- to interrupt something, so it never outranks a free car.
            local recommended = cad.recommendUnits({
                unit(1, 200, 0, { status = 'on_scene', onCallId = 7, onCallPriority = 4 }),
                unit(2, 1500, 0),
            }, { x = 0, y = 0 }, { now = now, callPriority = 1 })

            assert.are.equal(2, #recommended)
            assert.are.equal(2, recommended[1].officerId)
            assert.is_nil(recommended[1].divertFromCallId)
            assert.are.equal(1, recommended[2].officerId)
            assert.are.equal(7, recommended[2].divertFromCallId)
        end)

        it('will not divert a unit for a call of equal urgency', function()
            -- Swapping a unit between two P2s leaves the first call with nobody
            -- and gains nothing.
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { status = 'en_route', onCallId = 7, onCallPriority = 2 }),
            }, { x = 0, y = 0 }, { now = now, callPriority = 2 })

            assert.are.equal(0, #recommended)
        end)

        it('will not divert a unit when the new call has no priority yet', function()
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { status = 'en_route', onCallId = 7, onCallPriority = 4 }),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(0, #recommended)
        end)

        it('never offers a unit in distress or out of service', function()
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { status = 'emergency' }),
                unit(2, 20, 0, { status = 'out_of_service' }),
                unit(3, 30, 0, { status = 'off_duty' }),
                unit(4, 40, 0, { status = 'transporting' }),
                unit(5, 50, 0, { status = 'at_station' }),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(1, #recommended)
            assert.are.equal(5, recommended[1].officerId)
        end)

        it('ranks a guessed position behind every known one', function()
            local recommended = cad.recommendUnits({
                unit(1, 10, 0, { positionAtUnix = now - 900 }),
                unit(2, 800, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(2, recommended[1].officerId)
            assert.is_false(recommended[1].stale)
            assert.are.equal(1, recommended[2].officerId)
            assert.is_true(recommended[2].stale)
        end)

        it('leaves out a unit whose position is unknown', function()
            -- Not sorted to the end at distance zero, which is where a nil
            -- would land it. "We do not know where they are" is for a person to
            -- decide about, not something to present as "closest".
            local recommended = cad.recommendUnits({
                unit(1, helper.NONE, helper.NONE, { positionAtUnix = helper.NONE }),
                unit(2, 500, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(1, #recommended)
            assert.are.equal(2, recommended[1].officerId)
        end)

        it('stops at the configured number of suggestions', function()
            local units = {}
            for index = 1, 8 do units[index] = unit(index, index * 10, 0) end

            assert.are.equal(3, #cad.recommendUnits(units, { x = 0, y = 0 }, { now = now }))
            assert.are.equal(5, #cad.recommendUnits(units, { x = 0, y = 0 }, { now = now, limit = 5 }))
        end)

        it('breaks a distance tie on the officer id, so two dispatchers agree', function()
            local recommended = cad.recommendUnits({
                unit(9, 0, 100),
                unit(4, 100, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(4, recommended[1].officerId)
            assert.are.equal(9, recommended[2].officerId)
        end)

        it('offers one unit once, however many board rows it has', function()
            -- The board is units joined to what they are live on, so a unit live
            -- on two calls is two rows. `Repo.assignUnits` is what stops that
            -- happening, and this is the second lock on the same door: two of
            -- the three "closest available" slots filled by one callsign is a
            -- dispatcher sending a car that is already on its way.
            local recommended = cad.recommendUnits({
                unit(1, 50, 0),
                unit(1, 50, 0),
                unit(2, 900, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(2, #recommended)
            assert.are.equal(1, recommended[1].officerId)
            assert.are.equal(2, recommended[2].officerId)
        end)

        it('keeps the best-ranked row of a unit that has two', function()
            -- The list is already sorted when the duplicates are dropped, so the
            -- row that survives is the one that ranked highest -- a free row
            -- rather than a divertible one, and a known position rather than a
            -- guess. The other way round it would report a unit as busier or
            -- further away than it is.
            local recommended = cad.recommendUnits({
                unit(1, 400, 0, { positionAtUnix = now - 900 }),
                unit(1, 400, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(1, #recommended)
            assert.is_false(recommended[1].stale)
        end)

        it('still fills the list when a duplicate would have taken a slot', function()
            -- The limit counts units, not rows: dropping a duplicate must not
            -- cost the dispatcher the third suggestion.
            local recommended = cad.recommendUnits({
                unit(1, 10, 0),
                unit(1, 10, 0),
                unit(2, 20, 0),
                unit(3, 30, 0),
            }, { x = 0, y = 0 }, { now = now })

            assert.are.equal(3, #recommended)
            assert.are.same({ 1, 2, 3 }, {
                recommended[1].officerId, recommended[2].officerId, recommended[3].officerId,
            })
        end)
    end)

    -- -------------------------------------------------------------------------
    -- What a unit is doing when a call stops being theirs (7.16)
    -- -------------------------------------------------------------------------

    describe('the status a call gives back', function()
        --- The three reasons, which are three different events and not three
        --- spellings of one. They were two until a review found the removal
        --- path carrying the closure's rule. Read through a function rather
        --- than a local list because `cad` is reloaded in `before_each`.
        local function reasons()
            return { cad.CALL_ENDED, cad.CALL_RELEASED, cad.CALL_DIVERTED }
        end

        it('takes back the statuses the call itself put the unit in', function()
            for _, status in ipairs({ 'en_route', 'on_scene' }) do
                assert.are.equal('available', cad.statusAfterCall(status), status)

                for _, reason in ipairs(reasons()) do
                    assert.are.equal(
                        'available', cad.statusAfterCall(status, reason), status .. ' ' .. reason)
                end
            end
        end)

        it('leaves a unit that moved on under its own steam alone', function()
            -- `transporting` is a prisoner in the back of the car. A call
            -- closing behind that unit must not report them as available, and
            -- `busy` is the same fact with paperwork instead of a prisoner.
            for _, status in ipairs({ 'busy', 'transporting', 'at_station', 'out_of_service' }) do
                assert.is_nil(cad.statusAfterCall(status), status)

                for _, reason in ipairs(reasons()) do
                    assert.is_nil(cad.statusAfterCall(status, reason), status .. ' ' .. reason)
                end
            end
        end)

        it('frees an officer whose own emergency call has been cleared', function()
            -- `emergency` is on neither `SELF_SET_UNIT_STATUSES` nor
            -- `SUPERVISOR_UNIT_STATUSES`: the officer cannot stand themselves
            -- down and a supervisor cannot do it for them, so `enums.ts` says
            -- clearing one is done by clearing the call. If the end of a call
            -- did not take the status back, the officer who pressed panic would
            -- read as in distress for the rest of the shift -- and `isFree`
            -- excludes `emergency`, so nothing would recommend them again.
            --
            -- The closure is also the only one of the three events that has
            -- established anything: `ck_fpd_calls_panic_ack` will not let a
            -- panic call close until a supervisor has acknowledged it.
            assert.are.equal('available', cad.statusAfterCall('emergency', cad.CALL_ENDED))
        end)

        it('will not let a call the unit is merely off clear a distress flag', function()
            -- The defect this pair of assertions is here for. Releasing is a
            -- dispatcher taking a unit off a call that stays open, and
            -- diverting is them sending it to a second one; neither establishes
            -- that the officer has stopped needing help, and neither closes the
            -- panic call, which is still sitting in the queue unacknowledged.
            -- Clearing the flag on either path takes the one row that says
            -- somebody needs help now off the board, silently, and restarts the
            -- welfare timer that would have asked about them.
            assert.is_nil(cad.statusAfterCall('emergency', cad.CALL_RELEASED))
            assert.is_nil(cad.statusAfterCall('emergency', cad.CALL_DIVERTED))
        end)

        it('never reports a unit that is not working as freed', function()
            assert.is_nil(cad.statusAfterCall('off_duty'))
            assert.is_nil(cad.statusAfterCall('available'))
            assert.is_nil(cad.statusAfterCall(nil))
        end)

        it('hands the repo a list that agrees with the predicate', function()
            -- The SQL cannot call `statusAfterCall` per row, so one statement
            -- binds this list instead. Two spellings of one rule is how the
            -- list and the predicate drift apart the next time a status is
            -- added, and this is what notices.
            for _, reason in ipairs(reasons()) do
                local statuses, freed = cad.statusesClearedByCall(reason)

                assert.are.equal('available', freed)
                assert.is_true(#statuses > 0)

                for _, status in ipairs(statuses) do
                    assert.are.equal(freed, cad.statusAfterCall(status, reason), status)
                end

                for _, status in pairs(FredPD.UnitStatus) do
                    local listed = false
                    for _, member in ipairs(statuses) do
                        if member == status then listed = true end
                    end

                    assert.are.equal(
                        listed, cad.statusAfterCall(status, reason) ~= nil, status)
                end
            end
        end)

        it('hands out a copy, so a caller cannot edit the rule', function()
            local statuses = cad.statusesClearedByCall(cad.CALL_ENDED)
            statuses[1] = 'off_duty'

            assert.are_not.equal('off_duty', cad.statusesClearedByCall(cad.CALL_ENDED)[1])
        end)

        it('hands the closure a longer list than the other two', function()
            -- The claim the SQL depends on, stated once: `clearCall` binds one
            -- more status than `releaseUnits` and the divert do, and that one
            -- is the distress flag. Before the reasons were split, all three
            -- statements bound the same list and a dispatcher taking a unit off
            -- an open call stood down a panic that was still in the queue.
            local function names(reason)
                local listed = {}

                for _, status in ipairs(cad.statusesClearedByCall(reason)) do
                    listed[status] = true
                end

                return listed
            end

            assert.is_true(names(cad.CALL_ENDED).emergency)
            assert.is_nil(names(cad.CALL_RELEASED).emergency)
            assert.is_nil(names(cad.CALL_DIVERTED).emergency)
        end)

        it('reads an unknown reason as the rule that cannot lose a panic', function()
            -- The fallback points at `RELEASED` rather than `ENDED`, which is
            -- the opposite of what it did while every list held the same
            -- statuses. A flag wrongly kept is the loudest row on the board and
            -- somebody radios that unit within a minute; a flag wrongly taken
            -- down looks exactly like a unit that is fine. A typo gets the
            -- visible failure.
            assert.is_nil(cad.statusAfterCall('emergency', 'typo'))
            assert.are.equal('available', cad.statusAfterCall('on_scene', 'typo'))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The welfare timer (7.16)
    -- -------------------------------------------------------------------------

    describe('the welfare check', function()
        local now <const> = 1789722000

        local function onScene(minutes, overrides)
            local row = {
                status = 'on_scene',
                callsign = '3A-12',
                statusSinceUnix = now - (minutes * 60),
            }

            for key, value in pairs(overrides or {}) do
                row[key] = value ~= helper.NONE and value or nil
            end

            return row
        end

        it('says nothing about a unit inside the threshold', function()
            assert.is_false(cad.needsWelfareCheck(onScene(19), now))
        end)

        it('prompts once a unit has been on scene past the threshold', function()
            assert.is_true(cad.needsWelfareCheck(onScene(20), now))
            assert.is_true(cad.needsWelfareCheck(onScene(90), now))
        end)

        it('watches only the statuses the server configured', function()
            -- A unit that has been `busy` for an hour is doing paperwork.
            assert.is_false(cad.needsWelfareCheck({
                status = 'busy', statusSinceUnix = now - 7200,
            }, now))

            local config = cad.settings({ welfareSeconds = { busy = 30 * 60 } })

            assert.is_true(cad.needsWelfareCheck({
                status = 'busy', statusSinceUnix = now - 7200,
            }, now, config))
        end)

        it('does not prompt again inside the repeat window', function()
            -- The board is polled every few seconds, so without this the one
            -- unit that needs checking on is buried under its own alerts.
            assert.is_false(cad.needsWelfareCheck(onScene(40, { promptedAtUnix = now - 60 }), now))
            assert.is_true(cad.needsWelfareCheck(onScene(40, { promptedAtUnix = now - 900 }), now))
        end)

        it('prompts once when the server turns the repeat off', function()
            local config = cad.settings({ welfareRepeatSeconds = 0 })

            assert.is_true(cad.needsWelfareCheck(onScene(40), now, config))
            assert.is_false(cad.needsWelfareCheck(onScene(40, { promptedAtUnix = now - 1 }), now, config))
        end)

        it('says nothing about a unit whose stamp is missing', function()
            assert.is_false(cad.needsWelfareCheck(onScene(40, { statusSinceUnix = helper.NONE }), now))
        end)

        it('reads a backwards clock as a fresh status rather than a negative age', function()
            assert.are.equal(0, cad.statusAge({ statusSinceUnix = now + 500 }, now))
        end)

        it('floors the minutes the prompt reads out', function()
            -- The dispatcher checks the number against the timestamp on the
            -- call card, so 21 minutes and 50 seconds is 21.
            assert.are.equal(21, cad.welfareMinutes(onScene(21, {
                statusSinceUnix = now - (21 * 60) - 50,
            }), now))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Beats (7.17)
    -- -------------------------------------------------------------------------

    describe('bounding boxes', function()
        --- A 100 x 60 rectangle with one corner away from the origin.
        local rectangle <const> = { { 0, 0 }, { 100, 0 }, { 100, 60 }, { 0, 60 } }

        it('is the extent of the polygon', function()
            local box = cad.boundingBox(rectangle)

            assert.are.same({ minX = 0, minY = 0, maxX = 100, maxY = 60 }, box)
        end)

        it('handles a polygon on the negative side of the map', function()
            -- Los Santos is mostly negative on one axis or the other.
            local box = cad.boundingBox({ { -400, -900 }, { -100, -950 }, { -250, -700 } })

            assert.are.same({ minX = -400, minY = -950, maxX = -100, maxY = -700 }, box)
        end)

        it('refuses anything that is not a polygon', function()
            -- Two points are a line and a line contains nothing, which is what
            -- `ck_fpd_beats_polygon` says in the database.
            assert.is_nil(cad.boundingBox({ { 0, 0 }, { 10, 10 } }))
            assert.is_nil(cad.boundingBox({ { 0, 0 }, { 10, 10 }, { 'x', 4 } }))
            assert.is_nil(cad.boundingBox('not a polygon'))
        end)

        it('rejects a point outside it before any ray is cast', function()
            local box = cad.boundingBox(rectangle)

            assert.is_true(cad.boxContains(box, 50, 30))
            assert.is_false(cad.boxContains(box, 101, 30))
            assert.is_false(cad.boxContains(box, 50, -1))
        end)

        it('never rejects a point on its own edge', function()
            -- A box that excluded its boundary would make the polygon's own
            -- boundary handling unreachable.
            local box = cad.boundingBox(rectangle)

            assert.is_true(cad.boxContains(box, 0, 0))
            assert.is_true(cad.boxContains(box, 100, 60))
        end)
    end)

    describe('point in polygon', function()
        local rectangle <const> = { { 0, 0 }, { 100, 0 }, { 100, 60 }, { 0, 60 } }
        --- A concave polygon: a square with a bite taken out of the right side.
        local concave <const> = {
            { 0, 0 }, { 100, 0 }, { 100, 100 },
            { 60, 100 }, { 60, 40 }, { 40, 40 }, { 40, 100 }, { 0, 100 },
        }

        it('contains the points inside it', function()
            assert.is_true(cad.polygonContains(rectangle, 50, 30))
            assert.is_true(cad.polygonContains(rectangle, 0.5, 0.5))
        end)

        it('excludes the points outside it', function()
            assert.is_false(cad.polygonContains(rectangle, 150, 30))
            assert.is_false(cad.polygonContains(rectangle, -0.5, 30))
            assert.is_false(cad.polygonContains(rectangle, 50, 61))
        end)

        it('counts a point on an edge as inside', function()
            -- The assertion this whole file exists for. A ray cast answers the
            -- boundary by accident -- a horizontal edge one way, a vertical edge
            -- the other -- and a boundary that belongs to neither of two
            -- adjacent beats is a call that lands nowhere.
            assert.is_true(cad.polygonContains(rectangle, 50, 0), 'on the horizontal edge')
            assert.is_true(cad.polygonContains(rectangle, 50, 60), 'on the far horizontal edge')
            assert.is_true(cad.polygonContains(rectangle, 0, 30), 'on the vertical edge')
            assert.is_true(cad.polygonContains(rectangle, 100, 30), 'on the far vertical edge')
        end)

        it('counts a point on a vertex as inside', function()
            for index = 1, #rectangle do
                local point = rectangle[index]

                assert.is_true(
                    cad.polygonContains(rectangle, point[1], point[2]),
                    ('vertex %d'):format(index)
                )
            end
        end)

        it('counts a point on a diagonal edge as inside', function()
            -- The case where the cross-product test does the work: a diagonal
            -- is neither the horizontal nor the vertical the crossing rule
            -- special-cases.
            local triangle = { { 0, 0 }, { 100, 100 }, { 0, 100 } }

            assert.is_true(cad.polygonContains(triangle, 50, 50))
            assert.is_true(cad.polygonContains(triangle, 25, 25))
            assert.is_false(cad.polygonContains(triangle, 50, 49))
        end)

        it('is not fooled by the bite out of a concave beat', function()
            assert.is_true(cad.polygonContains(concave, 20, 80))
            assert.is_true(cad.polygonContains(concave, 80, 80))
            assert.is_true(cad.polygonContains(concave, 50, 20))
            -- Inside the bounding box, outside the polygon: the notch.
            assert.is_false(cad.polygonContains(concave, 50, 80))
        end)

        it('is right for a ray that passes exactly through a vertex', function()
            -- A ray along y = 40 leaves the notch's two inner corners exactly on
            -- it. Counted once per edge, the answer flips; the half-open
            -- crossing rule is what stops that.
            assert.is_true(cad.polygonContains(concave, 20, 40))
            assert.is_true(cad.polygonContains(concave, 80, 40))
        end)

        it('refuses a polygon with fewer than three vertices or a bad one', function()
            assert.is_false(cad.polygonContains({ { 0, 0 }, { 10, 10 } }, 5, 5))
            assert.is_false(cad.polygonContains({ { 0, 0 }, { 10, 0 }, { 'x', 10 } }, 5, 5))
            assert.is_false(cad.polygonContains(rectangle, nil, 5))
        end)
    end)

    describe('tagging a call with its beat', function()
        --- A district covering the west half of a square, and a beat inside it.
        local function beat(id, polygon, precedence, overrides)
            local row = {
                id = id,
                code = ('B%d'):format(id),
                polygon = polygon,
                precedence = precedence,
                enabled = 1,
            }

            local box = cad.boundingBox(polygon)

            row.minX, row.minY, row.maxX, row.maxY = box.minX, box.minY, box.maxX, box.maxY

            for key, value in pairs(overrides or {}) do
                row[key] = value ~= helper.NONE and value or nil
            end

            return row
        end

        local district <const> = beat(1, { { 0, 0 }, { 200, 0 }, { 200, 200 }, { 0, 200 } }, 0)
        local inner <const> = beat(2, { { 50, 50 }, { 100, 50 }, { 100, 100 }, { 50, 100 } }, 10)

        it('answers the polygon that contains the point', function()
            assert.are.equal(district, cad.beatFor({ district, inner }, 150, 150))
        end)

        it('prefers the most specific polygon where they overlap', function()
            -- A district is a large polygon with a low precedence and a beat is
            -- a small one inside it with a higher one, so one routine answers
            -- both questions.
            assert.are.equal(inner, cad.beatFor({ district, inner }, 75, 75))
            assert.are.equal(inner, cad.beatFor({ inner, district }, 75, 75))
        end)

        it('answers nothing for a position outside every beat', function()
            assert.is_nil(cad.beatFor({ district, inner }, 900, 900))
        end)

        it('ignores a beat that has been taken out of use', function()
            -- `fpd_beats.enabled` is how a beat goes out of use without being
            -- deleted: deleting one would quietly untag every call it ever held
            -- (`fk_fpd_calls_beat` is ON DELETE SET NULL).
            local retired = beat(3, { { 50, 50 }, { 100, 50 }, { 100, 100 }, { 50, 100 } }, 20, {
                enabled = 0,
            })

            assert.are.equal(inner, cad.beatFor({ district, inner, retired }, 75, 75))
        end)

        it('sends a shared border to exactly one beat, the same one every time', function()
            -- Two districts that meet on x = 100 both contain a point on the
            -- line (a point on an edge is inside), so without a stated
            -- tie-break the winner would be whichever the query returned first
            -- -- a call that changes beat between two readings of the same map.
            local west = beat(4, { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } }, 5)
            local east = beat(5, { { 100, 0 }, { 200, 0 }, { 200, 100 }, { 100, 100 } }, 5)

            assert.are.equal(west, cad.beatFor({ west, east }, 100, 50))
            assert.are.equal(west, cad.beatFor({ east, west }, 100, 50))
        end)

        it('never leaves a point on a shared border untagged', function()
            local west = beat(6, { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } }, 5)
            local east = beat(7, { { 100, 0 }, { 200, 0 }, { 200, 100 }, { 100, 100 } }, 5)

            for step = 0, 100, 10 do
                assert.is_not_nil(
                    cad.beatFor({ west, east }, 100, step),
                    ('border at y = %d'):format(step)
                )
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Closing a call, and the log (7.16, 7.16.1)
    -- -------------------------------------------------------------------------

    describe('closing a call', function()
        it('clears a call that was worked', function()
            local status, messageKey = cad.closureFor('arrest_made')

            assert.are.equal('cleared', status)
            assert.are.equal('cad.log.cleared', messageKey)
        end)

        it('cancels a call that did not happen', function()
            -- A duplicate of another call, or one the caller stood down, did
            -- not happen: counting it as cleared inflates every workload report
            -- by the calls nobody went to. 7.16.1 says the same thing about the
            -- log line.
            for _, disposition in ipairs({ 'duplicate', 'cancelled' }) do
                local status, messageKey = cad.closureFor(disposition)

                assert.are.equal('cancelled', status)
                assert.are.equal('cad.log.cancelled', messageKey)
            end
        end)
    end)

    describe('the narrative log', function()
        it('carries no key for a note, because the text is the content', function()
            -- `ck_fpd_call_log_content` requires the body on a note and the key
            -- on everything else.
            assert.is_nil(cad.logMessageKey('note'))
        end)

        it('names the resource when a call was raised by an export', function()
            assert.are.equal('cad.log.created', cad.logMessageKey('created'))
            assert.are.equal('cad.log.created_external', cad.logMessageKey('created', { external = true }))
        end)

        it('distinguishes a unit that attached itself from one that was sent', function()
            assert.are.equal('cad.log.unit_joined', cad.logMessageKey('unit_joined'))
            assert.are.equal(
                'cad.log.self_assigned',
                cad.logMessageKey('unit_joined', { selfAssigned = true })
            )
        end)

        it('follows the disposition when the call closes', function()
            assert.are.equal(
                'cad.log.cleared',
                cad.logMessageKey('cleared', { disposition = 'report_taken' })
            )
            assert.are.equal(
                'cad.log.cancelled',
                cad.logMessageKey('cleared', { disposition = 'duplicate' })
            )
        end)

        it('has a key for every entry type the database accepts', function()
            -- `ck_fpd_call_log_type` is the list, and a line whose key is
            -- missing renders as a raw key in front of a dispatcher. Every
            -- value below is also a locale key in both locale files.
            local expected = {
                created = 'cad.log.created',
                note = nil,
                dispatched = 'cad.log.dispatched',
                unit_joined = 'cad.log.unit_joined',
                unit_left = 'cad.log.unit_left',
                lead_changed = 'cad.log.lead_changed',
                unit_status = 'cad.log.unit_status',
                call_status = 'cad.log.call_status',
                linked = 'cad.log.linked',
                unlinked = 'cad.log.unlinked',
                cleared = 'cad.log.cleared',
            }

            for _, entryType in pairs(FredPD.CallLogKind) do
                assert.are.equal(expected[entryType], cad.logMessageKey(entryType), entryType)
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    -- What the assignment writes (7.16)
    -- -------------------------------------------------------------------------

    --- The four statements nothing else can check.
    ---
    --- "A unit is on one call at a time" is not a property of any one function
    --- and not something a key in 0007 can express -- `uq_fpd_call_units_live`
    --- is `(call_id, discord_id, active)`, which says a unit is on a *given*
    --- call once. It is a property of the statement list `assignUnits` sends,
    --- so that list is what is asserted here: the repo is loaded over a database
    --- stub that records what it was asked to run, the way `persons_spec` does
    --- it, and the assertions are about the SQL and the values together.
    ---
    --- The three rules that follow it are the same kind of claim. A status the
    --- call gave back, a log line that is not written when the write it
    --- describes changed nothing, and a `status_since` a repeated key press does
    --- not restamp: each of them is one predicate in one statement, invisible
    --- from anywhere else, and each of them was wrong in a different direction
    --- before this spec existed.
    describe('what the assignment writes', function()
        local repo, db

        --- The database stub: it answers nothing and remembers everything.
        local function makeDb()
            local fake = { statements = {}, transactions = {} }

            local function record(sql, values)
                fake.statements[#fake.statements + 1] = { sql = sql, values = values or {} }
            end

            function fake.query(sql, values)
                record(sql, values)

                return {}
            end

            function fake.single(sql, values)
                record(sql, values)

                return fake.row
            end

            function fake.scalar(sql, values)
                record(sql, values)

                return nil
            end

            function fake.execute(sql, values)
                record(sql, values)

                return 1
            end

            function fake.insert(sql, values)
                record(sql, values)

                return 1
            end

            function fake.transaction(statements)
                fake.transactions[#fake.transactions + 1] = statements

                for index = 1, #statements do
                    record(statements[index].query, statements[index].values)
                end

                return true
            end

            return fake
        end

        before_each(function()
            -- `json` is a FiveM runtime global rather than a Lua one, and the
            -- repo encodes `message_args` with it. Sorted keys, so an assertion
            -- can name the string it expects.
            _G.json = {
                encode = function(value)
                    if type(value) ~= 'table' then return tostring(value) end

                    local keys = {}
                    for key in pairs(value) do keys[#keys + 1] = key end
                    table.sort(keys)

                    local parts = {}
                    for index = 1, #keys do
                        parts[index] = ('"%s":"%s"')
                            :format(keys[index], tostring(value[keys[index]]))
                    end

                    return '{' .. table.concat(parts, ',') .. '}'
                end,
                decode = function(text) return text end,
            }

            helper.load({
                'shared/generated/schema',
                'server/modules/cad/service',
                'server/modules/cad/repo',
            })

            db = makeDb()
            repo = FredPD.Repo.cad

            FredPD.Core = {
                db = db,
                counters = {
                    numberSql = function() return 'CONCAT(?, LPAD(?, ?, ?))' end,
                    numberValues = function(prefix, width) return { prefix, 1, width, '0' } end,
                    transaction = function(_, _, _, statements) return statements end,
                },
            }
        end)

        --- Every statement whose SQL contains `fragment`, in the order sent.
        local function statementsWith(fragment)
            local found = {}

            for index = 1, #db.statements do
                if db.statements[index].sql:find(fragment, 1, true) then
                    found[#found + 1] = db.statements[index]
                end
            end

            return found
        end

        local function statementWith(fragment)
            return statementsWith(fragment)[1]
        end

        --- Where in the order a statement matching `fragment` was sent.
        local function positionOf(fragment)
            for index = 1, #db.statements do
                if db.statements[index].sql:find(fragment, 1, true) then return index end
            end

            return nil
        end

        --- How many `?` a statement carries.
        local function placeholders(sql)
            local count = 0

            for _ in sql:gmatch('%?') do count = count + 1 end

            return count
        end

        --- Is `value` among a statement's bound values?
        local function binds(statement, value)
            for index = 1, placeholders(statement.sql) do
                if statement.values[index] == value then return true end
            end

            return false
        end

        local function unit(overrides)
            local row = {
                officerId = 41,
                discordId = '100000000000000041',
                callsign = '3A-12',
            }

            for key, value in pairs(overrides or {}) do
                row[key] = value ~= helper.NONE and value or nil
            end

            return row
        end

        local function actor()
            return { officerId = 7, discordId = '100000000000000007', callsign = 'DISP-1' }
        end

        -- ---------------------------------------------------------------------
        -- A unit is on one call
        -- ---------------------------------------------------------------------

        describe('a unit on one call', function()
            it('closes whatever else the unit was live on', function()
                -- The case that makes this not theoretical: an officer already
                -- working a call presses panic, and `unit.emergency` assigns
                -- them to their own P1. Without this they are live on both, the
                -- board draws them twice, and the call they walked away from
                -- still counts a unit, so no dispatcher re-dispatches it.
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local release = statementWith('AND active = 1 AND call_id <> ?')

                assert.is_not_nil(release)
                assert.is_not_nil(release.sql:find('UPDATE fpd_call_units', 1, true))
                assert.is_not_nil(release.sql:find('left_at = CURRENT_TIMESTAMP(3)', 1, true))
                -- The lead flag goes with it, or the abandoned call still says
                -- somebody is in charge of it.
                assert.is_not_nil(release.sql:find('is_lead = 0', 1, true))
                assert.are.same({ 'lspd', '100000000000000041', 90 }, release.values)
            end)

            it('leaves the call it is joining alone', function()
                -- `call_id <> ?` and never `call_id = ?`: closing the row for
                -- the call being joined would turn the `already_assigned`
                -- refusal `uq_fpd_call_units_live` produces into a silent
                -- re-join, which is a second `unit_joined` line on a call the
                -- unit never left.
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local release = statementWith('AND active = 1 AND call_id <> ?')

                assert.is_nil(release.sql:find('call_id = ?', 1, true))
            end)

            it('says so on the call the unit is walking away from', function()
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local line = statementWith('FROM fpd_call_units cu')

                assert.is_not_nil(line)
                assert.is_not_nil(line.sql:find('INSERT INTO fpd_call_log', 1, true))
                -- The call the line is filed against comes from the row, so it
                -- is the abandoned call and never the one being joined.
                assert.is_not_nil(line.sql:find('SELECT cu.agency_id, cu.call_id', 1, true))
                assert.is_true(binds(line, 'cad.log.unit_left'))
                assert.is_true(binds(line, 'unit_left'))
                assert.is_true(binds(line, '{"callsign":"3A-12"}'))
            end)

            it('writes the line and the status before closing the row', function()
                -- Both read the live assignment. After the close there is
                -- nothing left to read, so the order is the whole of it.
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local line = positionOf('FROM fpd_call_units cu')
                local status = positionOf('UPDATE fpd_units')
                local release = positionOf('AND active = 1 AND call_id <> ?')

                assert.is_true(line < release)
                assert.is_true(status < release)
            end)

            it('takes back the status the abandoned call put them in', function()
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local status = statementWith('UPDATE fpd_units')

                assert.is_true(binds(status, 'available'))
                assert.is_true(binds(status, 'en_route'))
                assert.is_true(binds(status, 'on_scene'))
                -- Diverting is not the end of a call, so it may not stand an
                -- officer in distress down (`Cad.statusAfterCall`).
                assert.is_false(binds(status, 'emergency'))
            end)

            it('leaves the status of a unit that was on nothing alone', function()
                -- Without the EXISTS this would free a unit sitting at
                -- `on_scene` with no assignment at all -- overwriting a status
                -- they chose because somebody dispatched them somewhere.
                repo.assignUnits('lspd', 90, { unit() }, { actor = actor() })

                local status = statementWith('UPDATE fpd_units')

                assert.is_not_nil(status.sql:find('EXISTS', 1, true))
                assert.is_not_nil(status.sql:find('cu.call_id <> ?', 1, true))
            end)

            it('does it for every unit of a dispatch, in one transaction', function()
                repo.assignUnits('lspd', 90, {
                    unit(),
                    unit({ officerId = 42, discordId = '100000000000000042', callsign = '3A-13' }),
                }, { actor = actor() })

                assert.are.equal(1, #db.transactions)
                assert.are.equal(2, #statementsWith('AND active = 1 AND call_id <> ?'))
            end)

            it('ends no values list in a nil', function()
                -- The header's rule, and the one the read-back in `createCall`
                -- broke: a trailing nil shortens the list oxmysql receives, so
                -- the placeholders and the values stop lining up.
                repo.assignUnits('lspd', 90, { unit({ officerId = helper.NONE }) }, {
                    actor = { discordId = '100000000000000007' },
                })

                for index = 1, #db.statements do
                    local statement = db.statements[index]
                    local last = placeholders(statement.sql)

                    if last > 0 then
                        assert.is_not_nil(statement.values[last], statement.sql)
                    end
                end
            end)
        end)

        -- ---------------------------------------------------------------------
        -- Taking a unit off a call
        -- ---------------------------------------------------------------------

        describe('releasing a unit', function()
            it('gives the unit its status back', function()
                -- Before this, `releaseUnits` stamped `left_at` and touched
                -- `fpd_units` not at all, so a unit a dispatcher took off a call
                -- read `on_scene` for the rest of the shift, at a scene it was
                -- not at, with the welfare timer counting from when it arrived.
                repo.releaseUnits('lspd', 90, { unit() }, actor())

                local status = statementWith('UPDATE fpd_units')

                assert.is_not_nil(status)
                assert.is_true(binds(status, 'available'))
                assert.is_true(binds(status, '100000000000000041'))
            end)

            it('gives back what the call put them in, and nothing else', function()
                repo.releaseUnits('lspd', 90, { unit() }, actor())

                local status = statementWith('UPDATE fpd_units')

                assert.is_true(binds(status, 'en_route'))
                assert.is_true(binds(status, 'on_scene'))
            end)

            it('leaves a live panic raised when the call stays open', function()
                -- The defect: this statement asked `statusesClearedByCall` for
                -- `CALL_ENDED`, so it bound `emergency` and cleared it. Neither
                -- caller ends the call -- a dispatcher pulling a unit off one
                -- (`call.dispatch`) leaves it open, and `events.signOff` is a
                -- unit going home from a call that still needs somebody -- so
                -- an officer with a live panic had their distress flag taken
                -- down because their name moved on a board, while their own P1
                -- sat in the queue unacknowledged.
                repo.releaseUnits('lspd', 90, { unit() }, actor())
                local released = statementWith('UPDATE fpd_units')

                db.statements = {}
                repo.clearCall('lspd', 90, { status = 'cleared', disposition = 'report_taken' },
                    { unit() }, actor())
                local cleared = statementsWith('UPDATE fpd_units')[1]

                -- The two statements are the same rule under two reasons, and
                -- the distress flag is the whole of the difference: clearing
                -- the call is the one event that establishes the emergency is
                -- over, because a panic call cannot close unacknowledged.
                assert.is_false(binds(released, 'emergency'))
                assert.is_true(binds(cleared, 'emergency'))

                for _, status in ipairs({ 'en_route', 'on_scene' }) do
                    assert.are.equal(binds(cleared, status), binds(released, status), status)
                end
            end)

            it('binds exactly the statuses its WHERE names', function()
                -- The list is built into the SQL as placeholders and bound
                -- beside it, so a list that shortened without the `IN (…)`
                -- shortening with it would bind a status into the agency slot.
                repo.releaseUnits('lspd', 90, { unit() }, actor())

                local status = statementWith('UPDATE fpd_units')
                local listed = select(2, status.sql:gsub('%?', ''))

                -- One for the freed status, one each for the agency and the
                -- unit, and the rest are the statuses the WHERE lists.
                assert.are.equal(#status.values, listed)
                assert.are.equal('available', status.values[1])
            end)

            it('writes neither the line nor the status when nobody was released', function()
                -- A release that closed no row describes nothing that happened.
                -- `fpd_call_log` is append-only, so a "unit left" line about a
                -- unit that was never on the call is one nothing can take back.
                repo.releaseUnits('lspd', 90, { unit() }, actor())

                local guarded = statementsWith('@fpd_changed > 0')

                assert.are.equal(2, #guarded)
                assert.is_not_nil(statementWith('SET @fpd_changed = ROW_COUNT()'))
                assert.is_true(
                    positionOf('UPDATE fpd_call_units') < positionOf('SET @fpd_changed'))
            end)
        end)

        -- ---------------------------------------------------------------------
        -- Clearing a call
        -- ---------------------------------------------------------------------

        describe('clearing a call', function()
            local function clear(units)
                repo.clearCall('lspd', 90, {
                    status = 'cleared',
                    disposition = 'report_taken',
                    note = 'Code 4.',
                }, units or { unit() }, actor())
            end

            it('stands an officer in distress down with their own call', function()
                -- 7.16's emergency button sets `emergency`, and nothing else can
                -- take it off: it is on neither self-set list nor the supervisor
                -- one. A clear that named only `en_route` and `on_scene` left
                -- the officer who pressed panic in distress on the board
                -- indefinitely -- and `Cad.isFree` excludes `emergency`, so they
                -- were never recommended for anything again.
                clear()

                local status = statementsWith('UPDATE fpd_units')[1]

                assert.is_true(binds(status, 'emergency'))
                assert.is_true(binds(status, 'available'))
            end)

            it('captures the close before anything reads it', function()
                clear()

                assert.are.equal(1, positionOf('UPDATE fpd_calls'))
                assert.are.equal(2, positionOf('SET @fpd_changed = ROW_COUNT()'))
            end)

            it('writes no log line on a call somebody else cleared', function()
                -- The doc said every other statement here was written so that
                -- losing the race costs nothing, and two of them were
                -- unconditional inserts into an append-only log: the second
                -- dispatcher to press Clear wrote a second "cleared" line, and
                -- their note under it, onto a call that was already closed.
                clear()

                local lines = statementsWith('INSERT INTO fpd_call_log')

                assert.are.equal(2, #lines)

                for index = 1, #lines do
                    assert.is_not_nil(lines[index].sql:find('@fpd_changed > 0', 1, true))
                end
            end)

            it('frees no unit and closes no assignment when it lost the race', function()
                clear()

                for _, fragment in ipairs({ 'UPDATE fpd_call_units', 'UPDATE fpd_units' }) do
                    local statement = statementWith(fragment)

                    assert.is_not_nil(statement.sql:find('@fpd_changed > 0', 1, true), fragment)
                end
            end)
        end)

        -- ---------------------------------------------------------------------
        -- Reporting progress
        -- ---------------------------------------------------------------------

        describe('reporting progress', function()
            it('does not restamp the timer for a status the unit already holds', function()
                -- 7.16's welfare check is the one alert written for a unit that
                -- has gone quiet. `setUnitStatus` has carried this guard from
                -- the start; `call.status` is the second path to the same two
                -- statuses, and without it an officer pressing "On scene" every
                -- nineteen minutes defeats the check entirely.
                repo.reportProgress('lspd', 90, 'on_scene', unit())

                local status = statementWith('UPDATE fpd_units')

                assert.is_not_nil(status.sql:find('AND status <> ?', 1, true))
                assert.are.same(
                    { 'on_scene', 'lspd', 41, 'on_scene' }, status.values)
            end)

            it('writes one line per press that changed something', function()
                repo.reportProgress('lspd', 90, 'on_scene', unit())

                local line = statementWith('INSERT INTO fpd_call_log')

                assert.is_not_nil(line.sql:find('u.status <> ?', 1, true))
                -- Before the UPDATE, or the guard is false on every press
                -- including the one that changed something.
                assert.is_true(positionOf('INSERT INTO fpd_call_log')
                    < positionOf('UPDATE fpd_units'))
            end)

            it('still advances the call, which is idempotent on its own', function()
                -- A unit that set `on_scene` off the call and then reports
                -- arriving on it has not changed status, and the call still has
                -- to be stamped.
                repo.reportProgress('lspd', 90, 'on_scene', unit())

                local advance = statementWith('UPDATE fpd_calls')

                assert.is_not_nil(advance.sql:find('COALESCE(on_scene_at', 1, true))
                assert.is_nil(advance.sql:find('@fpd_changed', 1, true))
            end)

            it('refuses a status that is not a rung of the ladder', function()
                assert.is_false(repo.reportProgress('lspd', 90, 'busy', unit()))
                assert.are.equal(0, #db.statements)
            end)
        end)

        -- ---------------------------------------------------------------------
        -- Reading a call back after raising it
        -- ---------------------------------------------------------------------

        describe('reading a raised call back', function()
            it('binds a dense values list, with nothing missing from the middle', function()
                -- The header's rule, broken: the old read-back wrote
                -- `created_by <=> ?` and bound nil for it, which on the export
                -- path left a hole at index 3 and a nullable value at the end.
                -- `#` on a table with a hole is undefined in Lua, and what
                -- oxmysql then receives is a list with the wrong number of
                -- parameters for the placeholders in the query.
                db.row = { id = 91, callNumber = '260918-0001' }

                repo.createCall('lspd', {
                    type = 'alarm',
                    priority = 3,
                    source = 'export',
                    sourceResource = 'alarm_script',
                }, nil)

                local read = statementWith('FROM fpd_calls WHERE')

                for index = 1, placeholders(read.sql) do
                    assert.is_not_nil(read.values[index], index)
                end

                assert.are.equal(placeholders(read.sql), #read.values)
            end)

            it('matches a NULL column with IS NULL rather than a bound nil', function()
                db.row = { id = 91, callNumber = '260918-0001' }

                repo.createCall('lspd', {
                    type = 'alarm',
                    priority = 3,
                    source = 'export',
                    sourceResource = 'alarm_script',
                }, nil)

                local read = statementWith('FROM fpd_calls WHERE')

                assert.is_nil(read.sql:find('<=>', 1, true))
                assert.is_not_nil(read.sql:find('created_by IS NULL', 1, true))
                -- No location was given, so that column is NULL too.
                assert.is_not_nil(read.sql:find('location_text IS NULL', 1, true))
                assert.are.same({ 'lspd', 'alarm', 'alarm_script' }, read.values)
            end)

            it('scopes a call with an author to that author', function()
                db.row = { id = 91, callNumber = '260918-0001' }

                repo.createCall('lspd', { type = 'disturbance', priority = 3 }, {
                    discordId = '100000000000000007',
                })

                local read = statementWith('FROM fpd_calls WHERE')

                assert.is_not_nil(read.sql:find('created_by = ?', 1, true))
                -- The resource and the location are the export path's scope and
                -- have no business narrowing a call an officer raised.
                assert.is_nil(read.sql:find('source_resource', 1, true))
                assert.are.same({ 'lspd', 'disturbance', '100000000000000007' }, read.values)
            end)
        end)

        -- ---------------------------------------------------------------------
        -- The call a unit is on
        -- ---------------------------------------------------------------------

        describe('the call a unit is on', function()
            it('answers the same one twice', function()
                -- `assignUnits` keeps this to one row, so the ORDER BY is what
                -- happens when it is not: without one, `LIMIT 1` hands
                -- `logUnitStatus` whichever row the storage engine reached
                -- first, and an officer's status line lands on an arbitrary one
                -- of two calls.
                repo.activeAssignment('lspd', '100000000000000041')

                local read = statementWith('FROM fpd_call_units cu')

                assert.is_not_nil(read.sql:find('ORDER BY cu.joined_at DESC, cu.id DESC', 1, true))
                assert.is_not_nil(read.sql:find('LIMIT 1', 1, true))
            end)
        end)
    end)
end)
