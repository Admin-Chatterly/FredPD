--- The statements an åtal with charges sends (court/repo.lua, Repo.decide).
---
--- Every charge row is an INSERT into a table with its own AUTO_INCREMENT, so
--- `LAST_INSERT_ID()` in any charge after the first names the charge before
--- it, not the åtal. The parent id has to be captured once, straight after the
--- åtal's own INSERT, and every charge has to use that.

local helper = require('spec.helper')

describe('court repo: an åtal with several charges', function()
    local sent

    before_each(function()
        helper.load({ 'server/modules/court/repo' })

        sent = nil
        FredPD.Core = {
            agencies = { get = function() return { shortName = 'LSPD' } end },
            db = {
                transaction = function(statements)
                    sent = statements
                    return true
                end,
                single = function() return { id = 7 } end,
                query = function() return {} end,
            },
            counters = {
                numberSql = function() return 'CONCAT(?, LPAD(?, ?, ?))' end,
                numberValues = function(prefix, width) return { prefix, 1, width, '0' } end,
                transaction = function(_, _, _, statements) return statements end,
            },
        }
    end)

    it('captures the åtal id once and files every charge against it', function()
        FredPD.Repo.court.decide(
            { fuId = 4, beslut = 'atal', personId = 1 },
            { agencyId = 'lspd', discordId = '1' },
            { { brottId = 11, stage = 'fullbordat' }, { brottId = 12, stage = 'forsok' } })

        assert.is_not_nil(sent)
        assert.truthy(sent[1].query:find('INSERT INTO fpd_atal', 1, true))
        assert.are.equal('SET @fpd_atal = LAST_INSERT_ID()', sent[2].query)

        local charges = 0
        for index = 3, #sent do
            if sent[index].query:find('fpd_atal_brott', 1, true) then
                charges = charges + 1
                assert.truthy(sent[index].query:find('@fpd_atal', 1, true))
                assert.falsy(sent[index].query:find('LAST_INSERT_ID', 1, true))
            end
        end

        assert.are.equal(2, charges)
    end)
end)
