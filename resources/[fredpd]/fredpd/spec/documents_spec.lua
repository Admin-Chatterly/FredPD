--- Printed documents (spec 7.28, ADR-020): the pure part.

local helper = require('spec.helper')

describe('documents service', function()
    local D

    before_each(function()
        D = helper.load({ 'server/modules/documents/service' }).Modules.documents
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
end)
