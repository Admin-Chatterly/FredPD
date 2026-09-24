--- Retention (spec 13.3, ADR-021): the plan and the clock.

local helper = require('spec.helper')

describe('retention service', function()
    local R

    before_each(function()
        R = helper.load({ 'server/modules/retention/service' }).Modules.retention
    end)

    it('keeps the defaults when config says nothing', function()
        local plan = R.plan(nil)

        assert.are.equal(365, plan.queryLog)
        assert.are.equal(30, plan.alprReads)
        assert.is_true(plan.lapsedLookouts)
    end)

    it('never lets a typo empty a table: a period below the floor is raised to it', function()
        local plan = R.plan({ queryLog = 3, alprReads = 0 })

        assert.are.equal(30, plan.queryLog)
        assert.are.equal(7, plan.alprReads)
    end)

    it('turns a sweep off with false', function()
        local plan = R.plan({ stops = false, lapsedLookouts = false })

        assert.is_false(plan.stops)
        assert.is_false(plan.lapsedLookouts)
    end)

    it('waits after a start, then runs on the interval', function()
        local started = 1000

        assert.is_false(R.due(nil, started, started + 60, 360, 600))
        assert.is_true(R.due(nil, started, started + 600, 360, 600))
        assert.is_false(R.due(started + 600, started, started + 600 + 3600, 360, 600))
        assert.is_true(R.due(started + 600, started, started + 600 + 360 * 60, 360, 600))
    end)

    it('never runs more often than every quarter hour', function()
        assert.is_false(R.due(0, 0, 60, 1, 0))
        assert.is_true(R.due(0, 0, 15 * 60, 1, 0))
    end)

    it('runs every sweep in a fixed order, each one planned', function()
        local plan = R.plan(nil)
        for _, name in ipairs(R.ORDER) do assert.is_not_nil(plan[name], name) end
    end)
end)

describe('retention repo: bounded deletes', function()
    local sent

    before_each(function()
        helper.load({ 'server/modules/retention/repo' })

        sent = {}
        FredPD.Core = {
            db = {
                query = function() return { { id = 'lspd' }, { id = 'bcso' } } end,
                execute = function(sql, params)
                    sent[#sent + 1] = { sql = sql, params = params }
                    -- The first agency has a backlog of two full batches and a tail.
                    if params[1] == 'lspd' and #sent <= 2 then return 5000 end
                    return 12
                end,
            },
        }
    end)

    it('sweeps each agency through its own index, in batches until one comes back short', function()
        local total = FredPD.Repo.retention.queryLog(365)

        assert.are.equal(5000 + 5000 + 12 + 12, total)
        assert.are.equal(4, #sent)
        assert.are.same({ 'lspd', 365, 5000 }, sent[1].params)
        assert.are.same({ 'bcso', 365, 5000 }, sent[4].params)
        assert.truthy(sent[1].sql:find('agency_id = ?', 1, true))
        assert.truthy(sent[1].sql:find('LIMIT ?', 1, true))
    end)

    it('stops after its batch cap, leaving the rest for the next run', function()
        FredPD.Core.db.query = function() return { { id = 'lspd' } } end
        FredPD.Core.db.execute = function(sql, params)
            sent[#sent + 1] = { sql = sql, params = params }
            return 5000
        end

        FredPD.Repo.retention.alprReads(30)

        assert.are.equal(20, #sent)
    end)

    it('keeps a draft an arrest or a lookout points at, and ages drafts from their last edit', function()
        FredPD.Repo.retention.staleDrafts(180)

        local sql = sent[1].sql
        assert.truthy(sql:find('updated_at <', 1, true))
        assert.truthy(sql:find('fpd_frihetsberovande', 1, true))
        assert.truthy(sql:find('fpd_spaning', 1, true))
        assert.are.same({ 180, 180, 180, 5000 }, sent[1].params)
    end)
end)
