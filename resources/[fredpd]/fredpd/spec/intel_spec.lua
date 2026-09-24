--- Intelligence logic (spec 10).
---
--- The rules PD-Span kept in Postgres triggers and functions. Two of them are
--- worth testing above the rest: the pair ordering, because getting it wrong
--- draws one relationship as two on the link chart, and the merge, because
--- getting it wrong attributes one person's intelligence to another.

local helper = require('spec.helper')

describe('intel', function()
    local intel

    before_each(function()
        intel = helper.load({ 'server/modules/intel/service' }).Modules.intel
    end)

    describe('blankToNull', function()
        it('trims', function()
            assert.are.equal('Marko', intel.blankToNull('  Marko  '))
        end)

        it('turns an empty field into nil', function()
            -- An empty string and an absent value mean the same thing to an
            -- officer; storing both makes every later query check for two.
            assert.is_nil(intel.blankToNull(''))
            assert.is_nil(intel.blankToNull('   '))
        end)

        it('rejects a non-string', function()
            assert.is_nil(intel.blankToNull(nil))
            assert.is_nil(intel.blankToNull(42))
        end)
    end)

    describe('normalizePlate', function()
        it('upper-cases', function()
            assert.are.equal('ABC123', intel.normalizePlate('abc123'))
        end)

        it('removes inner spacing, so one plate is one plate', function()
            assert.are.equal('ABC123', intel.normalizePlate(' abc 123 '))
        end)

        it('returns nil for a blank plate', function()
            assert.is_nil(intel.normalizePlate('  '))
            assert.is_nil(intel.normalizePlate(nil))
        end)
    end)

    describe('normalizeTags', function()
        it('lower-cases, so the tag bar does not split one tag in two', function()
            assert.are.same({ 'narkotika' }, intel.normalizeTags({ 'Narkotika' }))
        end)

        it('de-duplicates, case-insensitively', function()
            assert.are.same({ 'vapen' }, intel.normalizeTags({ 'Vapen', 'vapen', ' VAPEN ' }))
        end)

        it('preserves the order they were entered in', function()
            assert.are.same({ 'a', 'b', 'c' }, intel.normalizeTags({ 'a', 'b', 'c' }))
        end)

        it('drops blanks', function()
            assert.are.same({ 'a' }, intel.normalizeTags({ 'a', '', '   ' }))
        end)

        it('caps the count', function()
            local many = {}
            for index = 1, 50 do many[index] = 'tag' .. index end

            assert.are.equal(12, #intel.normalizeTags(many))
        end)

        it('caps the length of a single tag', function()
            assert.are.equal(64, #intel.normalizeTags({ string.rep('x', 200) })[1])
        end)

        it('returns an empty list for a non-table', function()
            assert.are.same({}, intel.normalizeTags(nil))
            assert.are.same({}, intel.normalizeTags('narkotika'))
        end)
    end)

    describe('orderPair', function()
        it('puts the lower id first, whichever way round it is given', function()
            local low, high = intel.orderPair(7, 3)
            assert.are.equal(3, low)
            assert.are.equal(7, high)

            low, high = intel.orderPair(3, 7)
            assert.are.equal(3, low)
            assert.are.equal(7, high)
        end)

        it('refuses a person associated with themselves', function()
            local low, _, err = intel.orderPair(5, 5)

            assert.is_nil(low)
            assert.are.equal('self', err)
        end)

        it('refuses a non-number', function()
            local low, _, err = intel.orderPair('5', 6)

            assert.is_nil(low)
            assert.are.equal('type', err)
        end)
    end)

    describe('displayName', function()
        it('prefers the name', function()
            assert.are.equal('Marko', intel.displayName({ name = 'Marko', alias = 'Slim' }))
        end)

        it('falls back to the alias', function()
            assert.are.equal('Slim', intel.displayName({ alias = 'Slim' }))
        end)

        it('returns nil rather than a label when there is neither', function()
            -- PD-Span generated "Okänd" in the database. A label belongs in the
            -- locale files, so this returns nil and the interface renders the key.
            assert.is_nil(intel.displayName({ description = 'tall, scar on left cheek' }))
            assert.is_nil(intel.displayName(nil))
        end)
    end)

    describe('redactSource', function()
        local function note(source)
            return { id = 1, body = 'seen at the docks', source = source, confidence = 'high' }
        end

        it('withholds a protected source from a reader without clearance', function()
            local safe = intel.redactSource(note('informant'), false)

            assert.is_nil(safe.source)
            assert.is_true(safe.sourceProtected)
        end)

        it('withholds wiretap and surveillance too', function()
            assert.is_nil(intel.redactSource(note('wiretap'), false).source)
            assert.is_nil(intel.redactSource(note('surveillance'), false).source)
        end)

        it('keeps the intelligence itself readable', function()
            -- Withholding the intelligence would defeat a shared register. What
            -- is withheld is where it came from.
            local safe = intel.redactSource(note('informant'), false)

            assert.are.equal('seen at the docks', safe.body)
            assert.are.equal('high', safe.confidence)
        end)

        it('shows a protected source to a reader with clearance', function()
            assert.are.equal('informant', intel.redactSource(note('informant'), true).source)
        end)

        it('leaves an unprotected source alone', function()
            assert.are.equal('patrol', intel.redactSource(note('patrol'), false).source)
            assert.are.equal('tip', intel.redactSource(note('tip'), false).source)
        end)

        it('does not mutate the original row', function()
            -- The same row may be handed to several recipients with different
            -- clearance; redacting in place would leak the first decision.
            local original = note('informant')
            intel.redactSource(original, false)

            assert.are.equal('informant', original.source)
        end)
    end)

    describe('searchTerm', function()
        it('lower-cases and trims', function()
            assert.are.equal('marko', intel.searchTerm('  Marko '))
        end)

        it('refuses a term too short to be worth a scan', function()
            assert.is_nil(intel.searchTerm('a'))
            assert.is_nil(intel.searchTerm(''))
            assert.is_nil(intel.searchTerm(nil))
        end)
    end)

    describe('score', function()
        it('ranks exact above prefix above anywhere', function()
            assert.is_true(intel.score('marko', 'marko') > intel.score('marko petrov', 'marko'))
            assert.is_true(intel.score('marko petrov', 'marko') > intel.score('petrov marko', 'marko'))
        end)

        it('scores nothing when there is no match', function()
            assert.are.equal(0, intel.score('marko', 'zzz'))
            assert.are.equal(0, intel.score(nil, 'marko'))
            assert.are.equal(0, intel.score('marko', ''))
        end)
    end)

    describe('mergePlan', function()
        local keep = {
            id = 1, name = 'Marko', alias = nil, description = 'tall',
            photo_path = nil, status = 'unknown',
        }
        local drop = {
            id = 2, name = 'Marko Petrov', alias = 'Slim', description = 'scar on left cheek',
            photo_path = 'people/2/photo.jpg', status = 'warrant',
        }

        it('keeps what the surviving record already has', function()
            assert.are.equal('Marko', intel.mergePlan(keep, drop).name)
        end)

        it('fills blanks from the record being folded in', function()
            local merged = intel.mergePlan(keep, drop)

            assert.are.equal('Slim', merged.alias)
            assert.are.equal('people/2/photo.jpg', merged.photoPath)
        end)

        it('concatenates both descriptions rather than losing one', function()
            assert.are.equal('tall\n\nscar on left cheek', intel.mergePlan(keep, drop).description)
        end)

        it('keeps a single description when only one side has it', function()
            assert.are.equal('tall', intel.mergePlan(keep, { id = 2, status = 'poi' }).description)
        end)

        it('yields an unknown status to a real one', function()
            assert.are.equal('warrant', intel.mergePlan(keep, drop).status)
        end)

        it('does not downgrade a real status to the other record\'s', function()
            local decided = { id = 1, name = 'Marko', status = 'cleared' }

            assert.are.equal('cleared', intel.mergePlan(decided, drop).status)
        end)

        it('refuses to merge a record into itself', function()
            local merged, err = intel.mergePlan(keep, keep)

            assert.is_nil(merged)
            assert.are.equal('same', err)
        end)

        it('refuses when either record is missing', function()
            assert.is_nil(intel.mergePlan(keep, nil))
            assert.is_nil(intel.mergePlan(nil, drop))
        end)
    end)

    describe('validateNote', function()
        it('requires a body', function()
            local err, fields = intel.validateNote({ body = '   ' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.body)
        end)

        it('accepts a note attached to nothing at all', function()
            -- That is how a tip is logged before anyone knows who it concerns.
            assert.is_nil(intel.validateNote({ body = 'black van seen twice on Alta' }))
        end)
    end)

    describe('validateEvidence', function()
        it('accepts a link on a record', function()
            assert.is_nil(intel.validateEvidence({ url = 'https://medal.tv/clip/1', personId = 1 }))
        end)

        it('refuses both a file and a link', function()
            local err = intel.validateEvidence({
                url = 'https://medal.tv/clip/1', storagePath = 'a/b.png', personId = 1,
            })

            assert.are.equal('invalid', err)
        end)

        it('refuses neither', function()
            assert.are.equal('invalid', intel.validateEvidence({ personId = 1 }))
        end)

        it('refuses a link that is not http', function()
            local err, fields = intel.validateEvidence({ url = 'javascript:alert(1)', personId = 1 })

            assert.are.equal('invalid', err)
            assert.are.equal('not_http', fields.url)
        end)

        it('refuses evidence that hangs on nothing', function()
            local err, fields = intel.validateEvidence({ url = 'https://medal.tv/clip/1' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.target)
        end)
    end)

    -- 4.5: a link to a record the reader may not read is left off, because
    -- the link itself says who is tied to whom.
    describe('linkedRecords', function()
        it('names each linked record once, with its classification', function()
            local records = intel.linkedRecords({
                { orgId = 3, orgClassification = 'secret' },
                { orgId = 3, orgClassification = 'secret' },
                { orgId = 4, orgClassification = 'internal' },
            }, 'orgId', 'orgClassification')

            assert.are.same({
                { id = 3, classification = 'secret' },
                { id = 4, classification = 'internal' },
            }, records)
        end)

        it('skips rows that link to nothing on that side', function()
            -- A case link to an organisation, asked about its person.
            local records = intel.linkedRecords({ { personId = nil, orgId = 9 } }, 'personId', 'personClassification')
            assert.are.same({}, records)
        end)
    end)

    describe('keepLinked', function()
        local rows = {
            { id = 1, personId = 10 },
            { id = 2, personId = 11 },
            { id = 3, orgId = 20 },
        }

        it('keeps the rows whose linked record is readable, in order', function()
            local kept = intel.keepLinked(rows, 'personId', { [11] = true })
            assert.are.same({ { id = 2, personId = 11 }, { id = 3, orgId = 20 } }, kept)
        end)

        it('drops every link when nothing is readable, leaving no gap', function()
            local kept = intel.keepLinked(rows, 'personId', {})
            assert.are.equal(1, #kept)
            assert.are.equal(3, kept[1].id)
        end)

        it('judges each side in its own pass', function()
            local kept = intel.keepLinked(intel.keepLinked(rows, 'personId', { [10] = true }), 'orgId', {})
            assert.are.same({ { id = 1, personId = 10 } }, kept)
        end)
    end)

    describe('tagCounts', function()
        local uses = {
            { tag = 'narkotika', id = 1 },
            { tag = 'narkotika', id = 2 },
            { tag = 'vapen', id = 2 },
            { tag = 'operation-x', id = 3 },
        }

        it('counts only the notes the reader may read', function()
            local tags = intel.tagCounts(uses, { [1] = true, [2] = true })
            assert.are.same({ { tag = 'narkotika', uses = 2 }, { tag = 'vapen', uses = 1 } }, tags)
        end)

        it('never names a tag used only on a note the reader may not read', function()
            for _, entry in ipairs(intel.tagCounts(uses, { [1] = true })) do
                assert.are_not.equal('operation-x', entry.tag)
            end
        end)

        it('orders by use, then name, and stops at the limit', function()
            local tags = intel.tagCounts(uses, { [1] = true, [2] = true, [3] = true }, 2)
            assert.are.same({ { tag = 'narkotika', uses = 2 }, { tag = 'operation-x', uses = 1 } }, tags)
        end)
    end)
end)
