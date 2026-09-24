--- Civilian mode (spec 7.29): what a front desk accepts.

local helper = require('spec.helper')

describe('civilian service', function()
    local C
    local NOW <const> = 1790000000

    before_each(function()
        C = helper.load({ 'server/modules/civilian/service' }).Modules.civilian
    end)

    it('takes a stolen-property report, cleaned', function()
        local report = C.validateReport({
            kind = 'stolen_property',
            description = '  My bicycle was taken from the rack.  ',
            place = 'Vespucci Beach',
            property = 'Red bike, frame WH-44812',
            occurredAt = NOW - 3600,
        }, NOW)

        assert.are.equal('My bicycle was taken from the rack.', report.description)
        assert.are.equal('Red bike, frame WH-44812', report.property)
        assert.are.equal(NOW - 3600, report.occurredAt)
    end)

    it('keeps no property on a complaint', function()
        local report = C.validateReport({
            kind = 'complaint', description = 'The officer would not give his number.', property = 'x',
        }, NOW)

        assert.is_nil(report.property)
    end)

    it('refuses an unknown kind, a description too short to act on, and a date that cannot be', function()
        local _, fields = C.validateReport({ kind = 'murder', description = 'long enough text' }, NOW)
        assert.are.same({ kind = 'unknown' }, fields)

        _, fields = C.validateReport({ kind = 'complaint', description = 'rude' }, NOW)
        assert.are.same({ description = 'too_short' }, fields)

        _, fields = C.validateReport({ kind = 'complaint', description = 'long enough text', occurredAt = NOW + 86400 }, NOW)
        assert.are.same({ occurredAt = 'out_of_range' }, fields)

        _, fields = C.validateReport({ kind = 'complaint', description = 'long enough text', occurredAt = NOW - 400 * 86400 }, NOW)
        assert.are.same({ occurredAt = 'out_of_range' }, fields)
    end)

    it('strips control characters but keeps line breaks, and counts Swedish letters as one', function()
        local report = C.validateReport({
            kind = 'complaint', description = 'Första raden\nandra\0 raden\27[31m', place = ('å'):rep(300),
        }, NOW)

        assert.are.equal('Första raden\nandra raden[31m', report.description)
        assert.are.equal(191, utf8.len(report.place))
    end)

    it('sends a complaint to internal affairs, not to the shift', function()
        assert.are.equal('ia.case.view', C.readPermission('complaint'))
        assert.are.equal('ia.case.manage', C.handlePermission('complaint'))
        assert.are.equal('public.report.view', C.readPermission('stolen_property'))
        assert.are.equal('public.report.handle', C.handlePermission('stolen_property'))
    end)

    it('numbers a report the Appendix D way', function()
        local prefix, width = C.numberPrefix('lspd', 2026)
        assert.are.equal('LSPD-M26-', prefix)
        assert.are.equal(6, width)
    end)
end)
