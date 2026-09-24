--- Printed documents (spec 7.28, ADR-020): the pure part.

local helper = require('spec.helper')

describe('documents service', function()
    local D

    before_each(function()
        D = helper.load({ 'server/modules/access/service', 'server/modules/documents/service' }).Modules.documents
    end)

    it('turns plain text into an editor document of paragraphs, never HTML', function()
        local doc = D.textToDoc('First line.\r\n\r\n  Second <b>line</b>.  \n')

        assert.are.equal('doc', doc.type)
        assert.are.equal(2, #doc.content)
        assert.are.equal('Second <b>line</b>.', doc.content[2].content[1].text)
    end)

    it('cuts a long document at the limit and says it did', function()
        local doc = D.textToDoc(('a'):rep(50) .. '\n' .. ('b'):rep(50))
        local bounded, cut = D.bounded(doc, 60)

        assert.is_true(cut)
        assert.are.equal(('a'):rep(50), bounded.content[1].content[1].text)
        assert.are.equal(('b'):rep(10) .. '…', bounded.content[2].content[1].text)
    end)

    it('leaves a short document whole', function()
        local _, cut = D.bounded(D.textToDoc('short'), 60)
        assert.is_false(cut)
    end)

    it('numbers a document the Appendix D way', function()
        local prefix, width = D.numberPrefix('lspd', 2026)
        assert.are.equal('LSPD-D26-', prefix)
        assert.are.equal(6, width)
    end)

    it('names a person the way a printed page does', function()
        assert.are.equal('Doe, John (P-000431)',
            D.personLine({ firstName = 'John', lastName = 'Doe', personNumber = 'P-000431' }))
        assert.is_nil(D.personLine(nil))
    end)

    it('keeps a printer per kind, registered by the module that owns the record', function()
        local printer = function() return { title = 'x' } end
        D.register('citation', printer)

        assert.are.equal(printer, D.printerFor('citation'))
        assert.is_nil(D.printerFor('evidence'))
    end)

    it('cuts a copy and leaves the document it was given whole, for the PDF', function()
        local doc = D.textToDoc(('a'):rep(100))
        D.bounded(doc, 10)

        assert.are.equal(('a'):rep(100), doc.content[1].content[1].text)
    end)

    it('counts and cuts characters, never half of a Swedish letter', function()
        local bounded, cut = D.bounded(D.textToDoc(('ö'):rep(20)), 5)

        assert.is_true(cut)
        assert.are.equal(('ö'):rep(5) .. '…', bounded.content[1].content[1].text)

        local _, whole = D.bounded(D.textToDoc(('ö'):rep(5)), 5)
        assert.is_false(whole)
    end)

    it('prints a time from seconds, milliseconds, a string or a fraction', function()
        local expected = os.date('%Y-%m-%d %H:%M', 1727186520)

        assert.are.equal(expected, D.moment(1727186520))
        assert.are.equal(expected, D.moment(1727186520000))
        assert.are.equal(expected, D.moment('1727186520.123'))
        assert.are.equal(expected, D.moment(1727186520.5))
        assert.are.equal('', D.moment(nil))
        assert.are.equal('', D.moment('soon'))
    end)

    describe('which copies a record may have', function()
        it('lets an internal record go to paper and PDF', function()
            local rule = D.copyRule({ classification = 'internal' }, {})

            assert.is_true(rule.paper)
            assert.is_true(rule.pdf)
            assert.is_false(rule.restricted)
        end)

        it('keeps a classified record off paper, and its PDF behind the export permission', function()
            local rule = D.copyRule({ classification = 'secret' }, {})

            assert.are.equal('classified', rule.paper)
            assert.are.equal('export_restricted', rule.pdf)
            assert.is_true(D.copyRule({ classification = 'secret' }, { mayExportRestricted = true }).pdf)
        end)

        it('never lets a compartment, a seal or a break-glass read onto paper, whatever the ceiling', function()
            local open = { paperCeiling = 'secret', mayExportRestricted = true }

            assert.are.equal('compartmented', D.copyRule({ classification = 'internal', compartments = { 'sources' } }, open).paper)
            assert.are.equal('compartmented', D.copyRule({ classification = 'internal', sealed = true }, open).paper)
            assert.are.equal('breakglass', D.copyRule({ classification = 'restricted' },
                { paperCeiling = 'secret', breakglass = true }).paper)
        end)

        it('raises the paper ceiling only as far as config says', function()
            assert.is_true(D.copyRule({ classification = 'restricted' }, { paperCeiling = 'restricted' }).paper)
            assert.are.equal('classified', D.copyRule({ classification = 'confidential' }, { paperCeiling = 'restricted' }).paper)
        end)

        it('fails closed on a record with no classification it recognises', function()
            local rule = D.copyRule({ classification = 'whatever' }, { mayExportRestricted = true })

            assert.are.equal('unclassified', rule.paper)
            assert.are.equal('unclassified', rule.pdf)
            assert.are.equal('unclassified', D.copyRule(nil, {}).paper)
        end)
    end)
end)
