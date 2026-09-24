--- The tariff editor and licence points (spec 7.11, 0036, ADR-018).

local helper = require('spec.helper')

describe('ordningsbot tariff and licence', function()
    local O

    before_each(function()
        O = helper.load({ 'server/modules/ordningsbot/service' }).Modules.ordningsbot
    end)

    describe('isTariffCode', function()
        it('takes lower-case letters, digits and underscores', function()
            assert.is_true(O.isTariffCode('red_light'))
            assert.is_true(O.isTariffCode('speeding_10'))
        end)

        it('refuses anything else', function()
            assert.is_false(O.isTariffCode('Red Light'))
            assert.is_false(O.isTariffCode(''))
            assert.is_false(O.isTariffCode(('a'):rep(33)))
            assert.is_false(O.isTariffCode(nil))
        end)
    end)

    describe('validateTariff', function()
        it('needs a name for a new code', function()
            local err, fields = O.validateTariff({ code = 'littering', amount = 500 }, nil)
            assert.are.equal('invalid', err)
            assert.are.same({ label = 'required' }, fields)
        end)

        it('lets an existing code keep its name', function()
            assert.is_nil(O.validateTariff({ code = 'noise', amount = 900 }, { labelKey = 'ordningsbot.tariff.noise' }))
        end)

        it('treats a blank name as no name', function()
            local err = O.validateTariff({ code = 'x', label = '   ', amount = 1 }, nil)
            assert.are.equal('invalid', err)
        end)

        it('refuses markup in a label, which ox_lib would render', function()
            for _, label in ipairs({ '![](https://x.example/p.png)', '[link](x)', '<b>x</b>', 'a\nb', 'a`b' }) do
                local _, fields = O.validateTariff({ code = 'x', label = label, amount = 1 }, nil)
                assert.are.same({ label = 'format' }, fields, label)
            end

            assert.is_nil(O.validateTariff({ code = 'x', label = 'Nedskräpning, 21–30 km/h', amount = 1 }, nil))
        end)

        it('bounds the points', function()
            local _, fields = O.validateTariff({ code = 'x', label = 'X', amount = 1, licencePoints = 21 }, nil)
            assert.are.same({ licencePoints = 'too_large' }, fields)
        end)
    end)

    describe('tariffName', function()
        it('names a line in the agency\'s own words with the custom key', function()
            local key, label = O.tariffName({ label = '  Littering ' }, nil)
            assert.are.equal(O.CUSTOM_LABEL_KEY, key)
            assert.are.equal('Littering', label)
        end)

        it('carries an existing name forward when none is given', function()
            local key, label = O.tariffName({}, { labelKey = 'ordningsbot.tariff.noise', label = nil })
            assert.are.equal('ordningsbot.tariff.noise', key)
            assert.is_nil(label)
        end)
    end)

    describe('defaultTariffRows', function()
        it('keeps well-formed lines and skips the rest', function()
            local rows = O.defaultTariffRows({
                { code = 'parking', labelKey = 'ordningsbot.tariff.parking', amount = 800, points = 0 },
                { code = 'Bad Code', labelKey = 'x', amount = 1 },
                { code = 'no_amount', labelKey = 'x' },
                { code = 'too_many', labelKey = 'x', amount = 1, points = 99 },
            })

            assert.are.equal(1, #rows)
            assert.are.equal('parking', rows[1].code)
        end)

        it('answers an empty list for no config', function()
            assert.are.same({}, O.defaultTariffRows(nil))
        end)
    end)

    describe('licenceStanding', function()
        local config = { threshold = 12 }

        it('is valid below three quarters of the threshold', function()
            assert.are.equal('valid', O.licenceStanding(8, config).standing)
        end)

        it('warns from three quarters', function()
            assert.are.equal('warning', O.licenceStanding(9, config).standing)
            assert.are.equal('warning', O.licenceStanding(11, config).standing)
        end)

        it('is revoked at the threshold', function()
            local standing = O.licenceStanding(12, config)
            assert.are.equal('revoked', standing.standing)
            assert.are.equal(12, standing.points)
            assert.are.equal(12, standing.threshold)
        end)

        it('falls back to 12 and never divides by nothing', function()
            assert.are.equal(12, O.licenceStanding(0, {}).threshold)
            assert.are.equal('revoked', O.licenceStanding(1, { threshold = 0 }).standing)
        end)
    end)
end)
