--- Record numbering (spec 13.1, Appendix D).
---
--- These tests are about one defect and the shape that fixes it. Before
--- `fpd_counters` existed, a record number was `MAX(sequence) + 1` read inside
--- the INSERT that used it, over the table being inserted into -- atomic under
--- REPEATABLE READ, a race under READ COMMITTED, and the isolation level is the
--- operator's to choose. So the assertions below are not about formatting. They
--- are about the four statements that make an allocation safe under every
--- isolation level, and about their order.
---
--- A test that only checked "a number comes out" would have passed against the
--- broken version too.

local helper = require('spec.helper')

describe('counters', function()
    local counters

    before_each(function()
        counters = helper.load({ 'server/core/counters' }).Core.counters
    end)

    --- The statements a caller would hand to `db.transaction`.
    local function allocation(statements)
        return counters.transaction('scene', 'lspd', 2026, statements or {})
    end

    --- How many `?` placeholders a statement carries.
    local function placeholders(query)
        local count = 0
        for _ in query:gmatch('%?') do count = count + 1 end

        return count
    end

    describe('kinds', function()
        it('refuses a kind nobody has declared', function()
            -- A typo'd kind would allocate its own sequence and look fine right
            -- up until two records shared a number, so it fails at the call.
            assert.has_error(function()
                counters.numberValues('W2026-', 5, 'wrrant', 'lspd', 2026)
            end)
        end)

        it('names the kind it refused', function()
            local ok, err = pcall(counters.transaction, 'nonsense', 'lspd', 2026, {})

            assert.is_false(ok)
            assert.is_truthy(tostring(err):find('nonsense', 1, true))
        end)

        it('knows the kinds the suite allocates', function()
            for _, kind in ipairs({ 'person', 'report', 'case', 'warrant', 'bolo', 'scene', 'evidence' }) do
                assert.is_true(counters.isKind(kind))
            end
        end)
    end)

    describe('the number expression', function()
        it('takes exactly as many values as it has placeholders', function()
            -- The two are written in different functions and used in one
            -- statement. If they ever drift, every parameter after the number
            -- shifts by one and a record is written with somebody else's data
            -- in it -- silently, because the types mostly still fit.
            local values = counters.numberValues('LSPD-S-2026-', 4, 'scene', 'lspd', 2026)

            assert.are.equal(placeholders(counters.numberSql()), #values)
        end)

        it('passes the prefix, the width and the counter key in that order', function()
            local values = counters.numberValues('LSPD-2026-', 6, 'evidence', 'lspd', 2026)

            assert.are.same({ 'LSPD-2026-', 6, 'lspd', 'evidence', 2026 }, values)
        end)

        it('reads the counter and nothing else', function()
            -- The point of the rewrite: the number comes from a primary-key
            -- lookup on fpd_counters, not from a scan of the table being
            -- written to (spec 12).
            local sql = counters.numberSql()

            assert.is_truthy(sql:find('fpd_counters', 1, true))
            assert.is_nil(sql:find('MAX(', 1, true))
            assert.is_nil(sql:find('LIKE', 1, true))
        end)

        it('defaults the year rather than writing a NULL into the key', function()
            local values = counters.numberValues('P-', 6, 'person', 'lspd')

            assert.are.equal(counters.year(), values[5])
        end)

        it('allows a sequence that is not year-scoped', function()
            -- A master person number is `P-{######}` with no year in it, so it
            -- counts in one unbroken sequence per agency.
            local values = counters.numberValues('P-', 6, 'person', 'lspd', counters.YEARLESS)

            assert.are.equal(0, values[5])
        end)
    end)

    describe('the transaction', function()
        local function queries(statements)
            local out = {}
            for index = 1, #statements do out[index] = statements[index].query end

            return out
        end

        it('seeds, locks, writes and bumps, in that order', function()
            local caller = { { query = 'INSERT INTO fpd_scenes (scene_number) VALUES (x)', values = {} } }
            local sql = queries(allocation(caller))

            assert.are.equal(4, #sql)
            assert.is_truthy(sql[1]:find('INSERT INTO fpd_counters', 1, true))
            assert.is_truthy(sql[2]:find('FOR UPDATE', 1, true))
            assert.is_truthy(sql[3]:find('fpd_scenes', 1, true))
            assert.is_truthy(sql[4]:find('next_value + 1', 1, true))
        end)

        it('locks before the caller reads the counter', function()
            -- The whole fix. A read before the lock is a consistent read under
            -- READ COMMITTED, which is where two officers get the same number.
            local sql = queries(allocation({ { query = 'INSERT INTO fpd_scenes', values = {} } }))
            local lock, read

            for index = 1, #sql do
                if sql[index]:find('FOR UPDATE', 1, true) then lock = index end
                if sql[index]:find('fpd_scenes', 1, true) then read = index end
            end

            assert.is_truthy(lock)
            assert.is_truthy(read)
            assert.is_true(lock < read)
        end)

        it('seeds with ON DUPLICATE KEY UPDATE and never with INSERT IGNORE', function()
            -- Not a style preference. INSERT IGNORE takes a *shared* lock on the
            -- duplicate; the FOR UPDATE that follows would have to upgrade it,
            -- and two transactions each holding S and waiting for X deadlock.
            local seed = allocation()[1].query

            assert.is_truthy(seed:find('ON DUPLICATE KEY UPDATE', 1, true))
            assert.is_nil(seed:find('INSERT IGNORE', 1, true))
        end)

        it('keys the seed, the lock and the bump on the same counter row', function()
            -- One row, locked once. Three statements that disagreed about which
            -- row they meant would take the lock on one and allocate from
            -- another, which is the original race with more steps.
            local statements = allocation()

            for _, index in ipairs({ 1, 2, #statements }) do
                assert.are.same({ 'lspd', 'scene', 2026 }, statements[index].values)
            end
        end)

        it("keeps the caller's statements in the order they were given", function()
            local caller = {
                { query = 'INSERT INTO fpd_evidence', values = {} },
                { query = 'INSERT INTO fpd_evidence_owner', values = {} },
                { query = 'INSERT INTO fpd_custody_log', values = {} },
            }

            local sql = queries(counters.transaction('evidence', 'lspd', 2026, caller))

            assert.are.equal(6, #sql)
            assert.is_truthy(sql[3]:find('fpd_evidence', 1, true))
            assert.is_truthy(sql[4]:find('fpd_evidence_owner', 1, true))
            assert.is_truthy(sql[5]:find('fpd_custody_log', 1, true))
        end)

        it('does not mutate the list it was given', function()
            local caller = { { query = 'INSERT INTO fpd_scenes', values = {} } }

            counters.transaction('scene', 'lspd', 2026, caller)

            assert.are.equal(1, #caller)
        end)
    end)
end)
