--- Brottskatalogen (spec 7.10).
---
--- One thing here is worth testing far more than the rest, and the rest of the
--- module leans on it: **`gemensamStraffskala`**, the BrB 26:2 arithmetic for
--- several offences tried together. It is the only calculation in FredPD whose
--- output a prosecutor could be asked to justify in public, and every one of
--- its four rules is the kind that reads correct and is not:
---
---   * a floor that summed instead of taking the heaviest would triple the
---     minimum of three identical charges;
---   * a ceiling that applied the uplift without the sum cap would let two
---     six-month offences reach eighteen months;
---   * applying the eighteen-year cap before the sum cap, rather than after,
---     silently changes the answer for heavy multi-count cases only.
---
--- So the cases below are written from the statute's own worked shapes rather
--- than from the implementation, and each says which rule it is holding down.

local helper = require('spec.helper')

describe('brott', function()
    local brott

    before_each(function()
        brott = helper.load({ 'server/modules/brott/service' }).Modules.brott
    end)

    --- Shorthand: a span in months.
    local function span(min, max, boter)
        return { boter = boter or false, min = min, max = max }
    end

    -- -------------------------------------------------------------------------
    describe('normalisation', function()
        it('upper-cases a code and removes the spaces inside it', function()
            assert.are.equal('BRB-8-1', brott.normalizeCode('  brb-8-1 '))
        end)

        it('treats a blank code as absent', function()
            assert.is_nil(brott.normalizeCode('   '))
            assert.is_nil(brott.normalizeCode(''))
            assert.is_nil(brott.normalizeCode(nil))
            assert.is_nil(brott.normalizeCode(42))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('grader', function()
        it('knows the four brottsbalken grader and nothing else', function()
            assert.is_true(brott.isGrad('ringa'))
            assert.is_true(brott.isGrad('normal'))
            assert.is_true(brott.isGrad('grov'))
            assert.is_true(brott.isGrad('synnerligen_grov'))

            assert.is_false(brott.isGrad('felony'))
            assert.is_false(brott.isGrad(''))
            assert.is_false(brott.isGrad(nil))
        end)

        it('ranks them from lightest to heaviest', function()
            assert.is_true(brott.gradRank('ringa') < brott.gradRank('normal'))
            assert.is_true(brott.gradRank('normal') < brott.gradRank('grov'))
            assert.is_true(brott.gradRank('grov') < brott.gradRank('synnerligen_grov'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('straffskala', function()
        it('reads a catalogue row as a span', function()
            -- Stöld, BrB 8:1 -- "fängelse i högst två år".
            local skala = brott.straffskala({
                boter = 0, fangelse_min_months = 0, fangelse_max_months = 24,
            })

            assert.are.same({ boter = false, min = 0, max = 24 }, skala)
        end)

        it('accepts böter as the 1 MariaDB hands back as well as a boolean', function()
            -- Ringa stöld, BrB 8:2 -- "böter eller fängelse i högst sex månader".
            local fromDb = brott.straffskala({
                boter = 1, fangelse_min_months = 0, fangelse_max_months = 6,
            })
            local fromLua = brott.straffskala({
                boter = true, fangelse_min_months = 0, fangelse_max_months = 6,
            })

            assert.are.same(fromDb, fromLua)
            assert.is_true(fromDb.boter)
        end)

        it('reads an absent ceiling as livstid rather than as zero', function()
            -- Mord, BrB 3:1 -- "fängelse på viss tid, lägst tio och högst
            -- arton år, eller på livstid".
            local skala = brott.straffskala({
                boter = 0, fangelse_min_months = 120, fangelse_max_months = nil,
            })

            assert.are.equal(120, skala.min)
            assert.is_nil(skala.max)
        end)

        it('refuses a span whose floor is above its ceiling', function()
            assert.is_nil(brott.straffskala({
                boter = 0, fangelse_min_months = 24, fangelse_max_months = 6,
            }))
        end)

        it('refuses böter alongside a fängelse floor', function()
            -- No statute reads "böter eller fängelse i lägst sex månader", and
            -- 0008 carries the same CHECK.
            assert.is_nil(brott.straffskala({
                boter = 1, fangelse_min_months = 6, fangelse_max_months = 24,
            }))
        end)

        it('refuses something that is not a row at all', function()
            assert.is_nil(brott.straffskala(nil))
            assert.is_nil(brott.straffskala('BrB 8:1'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('isHeavier', function()
        it('ranks livstid above every fixed term', function()
            assert.is_true(brott.isHeavier(span(120, nil), span(0, 216)))
            assert.is_false(brott.isHeavier(span(0, 216), span(120, nil)))
        end)

        it('ranks by ceiling first', function()
            assert.is_true(brott.isHeavier(span(0, 72), span(6, 24)))
        end)

        it('breaks a tie on ceilings with the floor', function()
            -- Grov stöld ("lägst sex månader och högst sex år") against a
            -- hypothetical offence with the same ceiling and no floor. A
            -- comparison that looked only at ceilings would call these equal.
            assert.is_true(brott.isHeavier(span(6, 72), span(0, 72)))
            assert.is_false(brott.isHeavier(span(0, 72), span(6, 72)))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('gemensam straffskala (BrB 26:2)', function()
        it('leaves a single offence exactly as it is, with no uplift', function()
            -- One charge is not konkurrens. Stöld stays "högst två år" and does
            -- not become three.
            local skala = brott.gemensamStraffskala({ span(0, 24) })

            assert.are.same({ boter = false, min = 0, max = 24 }, skala)
        end)

        it('does not hand back the caller\'s own table', function()
            -- The catalogue's copy must not be mutable through the result.
            local original = span(0, 24)
            local skala = brott.gemensamStraffskala({ original })

            skala.max = 999

            assert.are.equal(24, original.max)
        end)

        it('takes the heaviest floor, not the sum of the floors', function()
            -- Rule 1. Three counts of grov stöld: the floor stays six months.
            local skala = brott.gemensamStraffskala({
                span(6, 72), span(6, 72), span(6, 72),
            })

            assert.are.equal(6, skala.min)
        end)

        it('adds one year when the heaviest ceiling is under four years', function()
            -- Rule 2, first band. Two counts of stöld: ceiling 24, uplift 12,
            -- sum 48 -- so the uplift is what binds.
            local skala = brott.gemensamStraffskala({ span(0, 24), span(0, 24) })

            assert.are.equal(36, skala.max)
        end)

        it('adds two years from four years up to eight', function()
            -- Rule 2, second band. Heaviest 72 months is inside [48, 96).
            local skala = brott.gemensamStraffskala({ span(6, 72), span(6, 72) })

            assert.are.equal(96, skala.max)
        end)

        it('adds four years at eight years and above', function()
            -- Rule 2, third band. Heaviest 96 months, sum 192, cap 216 -- so
            -- the uplift binds again.
            local skala = brott.gemensamStraffskala({ span(0, 96), span(0, 96) })

            assert.are.equal(144, skala.max)
        end)

        it('never exceeds the sum of the individual ceilings', function()
            -- Rule 3, and the case the band table alone gets wrong. Two
            -- offences of "högst sex månader": the band says a year may be
            -- added, which would reach 18 months, but the sum caps it at 12.
            local skala = brott.gemensamStraffskala({ span(0, 6), span(0, 6) })

            assert.are.equal(12, skala.max)
        end)

        it('never exceeds eighteen years', function()
            -- Rule 4 (BrB 26:1). Three counts at fifteen years: sum 540,
            -- uplift would give 228, and the fixed-term ceiling is 216.
            local skala = brott.gemensamStraffskala({
                span(0, 180), span(0, 180), span(0, 180),
            })

            assert.are.equal(brott.MAX_FIXED_MONTHS, skala.max)
            assert.are.equal(216, skala.max)
        end)

        it('applies the sum cap before the eighteen-year cap, not after', function()
            -- The ordering rule. Two offences of "högst ett år": sum 24,
            -- uplift would give 24 as well, and neither is near 216 -- so this
            -- case cannot tell the orders apart. The case that can is one where
            -- the sum is *below* 216 while the uplifted ceiling is above it:
            -- heaviest 204, one other of 6. Sum is 210; uplift would give 252.
            -- Sum-then-cap gives 210. Cap-then-sum would give 210 as well only
            -- because min() is commutative -- so what this actually pins is
            -- that both caps are applied at all, and that the smaller wins.
            local skala = brott.gemensamStraffskala({ span(0, 204), span(0, 6) })

            assert.are.equal(210, skala.max)
            assert.is_true(skala.max <= brott.MAX_FIXED_MONTHS)
        end)

        it('carries livstid through without arithmetic', function()
            -- Mord plus stöld is still livstid; there is nothing to add to an
            -- absent ceiling.
            local skala = brott.gemensamStraffskala({ span(120, nil), span(0, 24) })

            assert.is_nil(skala.max)
            assert.are.equal(120, skala.min)
            assert.is_false(skala.boter)
        end)

        it('keeps böter only when every offence allows it', function()
            local both = brott.gemensamStraffskala({ span(0, 6, true), span(0, 6, true) })
            assert.is_true(both.boter)

            local one = brott.gemensamStraffskala({ span(0, 6, true), span(0, 24, false) })
            assert.is_false(one.boter)
        end)

        it('drops böter as soon as the combined floor leaves zero', function()
            -- Follows from rule 1: a floor above zero means no böter, whatever
            -- the lighter offence allowed on its own.
            local skala = brott.gemensamStraffskala({ span(0, 6, true), span(6, 72, false) })

            assert.are.equal(6, skala.min)
            assert.is_false(skala.boter)
        end)

        it('refuses an empty list rather than inventing a span', function()
            assert.is_nil(brott.gemensamStraffskala({}))
            assert.is_nil(brott.gemensamStraffskala(nil))
        end)

        it('refuses a list with a hole in it', function()
            -- A nil in the middle means a charge whose catalogue row failed to
            -- load. Answering with the span of the rest would understate the
            -- case; failing closed makes the caller deal with it.
            assert.is_nil(brott.gemensamStraffskala({ span(0, 24), nil, span(0, 6) }))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('charge lists', function()
        it('parses ids out of the strings the validator hands over', function()
            assert.are.same({ 4, 9, 12 }, brott.parseIds({ '4', '9', '12' }))
        end)

        it('keeps a repeated id, because counts are what BrB 26:2 works over', function()
            -- The difference from `Evidence.parseIds`, which drops one. Three
            -- counts of grov stöld is three entries of one catalogue id, and
            -- collapsing them would understate the case.
            assert.are.same({ 7, 7, 7 }, brott.parseIds({ '7', '7', '7' }))
        end)

        it('refuses an id that is not a positive whole number', function()
            assert.is_nil(brott.parseIds({ '0' }))
            assert.is_nil(brott.parseIds({ '-3' }))
            assert.is_nil(brott.parseIds({ '2.5' }))
            assert.is_nil(brott.parseIds({ 'BrB 8:1' }))
        end)

        it('refuses an empty list and one over the cap', function()
            local _, empty = brott.parseIds({})
            assert.are.equal('required', empty)

            local _, tooMany = brott.parseIds({ '1', '2', '3' }, 2)
            assert.are.equal('too_many', tooMany)
        end)

        it('expands counts against the distinct rows the repo returned', function()
            -- One `IN` clause answers with each row once; the charge list names
            -- one of them twice.
            local rows = { { id = 7, code = 'BRB-8-4' }, { id = 9, code = 'BRB-8-1' } }
            local charges = brott.expandCharges({ 7, 9, 7 }, rows)

            assert.are.equal(3, #charges)
            assert.are.equal('BRB-8-4', charges[1].code)
            assert.are.equal('BRB-8-1', charges[2].code)
            assert.are.equal('BRB-8-4', charges[3].code)
        end)

        it('refuses to expand a charge whose catalogue row is missing', function()
            -- Another agency's id, or a typo. Dropping it silently would lower
            -- the span with nothing on screen to say why.
            assert.is_nil(brott.expandCharges({ 7, 99 }, { { id = 7 } }))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validate', function()
        --- Removing a field, which an override cannot express as nil.
        ---
        --- `{ balk = nil }` is an empty table: assigning nil stores nothing and
        --- `pairs` never yields the key. The two cases that matter most here --
        --- livstid (an absent ceiling) and an absent citation -- are both
        --- *removals*, so a helper without this sentinel silently tests the
        --- unmodified entry and passes for the wrong reason.
        local NONE <const> = {}

        --- A catalogue entry that should pass, to vary one field at a time.
        local function entry(overrides)
            local base = {
                code = 'BRB-8-1',
                balk = 'BrB', kapitel = 8, paragraf = 1,
                labelKey = 'brott.rubrik.stold',
                grad = 'normal',
                boter = false,
                fangelseMinMonths = 0,
                fangelseMaxMonths = 24,
            }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= NONE and value or nil
            end

            return base
        end

        it('accepts a well-formed entry', function()
            assert.is_nil(brott.validate(entry()))
        end)

        it('requires a code, a rubrik key and a known grad', function()
            assert.are.equal('invalid', brott.validate(entry({ code = '  ' })))
            assert.are.equal('invalid', brott.validate(entry({ labelKey = '' })))
            assert.are.equal('invalid', brott.validate(entry({ grad = 'felony' })))
        end)

        it('refuses a span the straffskala rules reject', function()
            local code, fields = brott.validate(entry({
                fangelseMinMonths = 24, fangelseMaxMonths = 6,
            }))

            assert.are.equal('invalid', code)
            assert.are.equal('straffskala', fields.fangelseMinMonths)
        end)

        it('refuses a fixed term above eighteen years', function()
            -- BrB 26:1. Beyond this the sentence is livstid, which is written
            -- as an absent ceiling rather than as a bigger number.
            local code, fields = brott.validate(entry({ fangelseMaxMonths = 217 }))

            assert.are.equal('invalid', code)
            assert.are.equal('over_max', fields.fangelseMaxMonths)
        end)

        it('accepts livstid, which is an absent ceiling', function()
            assert.is_nil(brott.validate(entry({
                fangelseMinMonths = 120, fangelseMaxMonths = NONE,
            })))
        end)

        it('accepts a citation that is entirely absent', function()
            -- An agency-local code cites no statute; `code` is the citation.
            assert.is_nil(brott.validate(entry({
                balk = NONE, kapitel = NONE, paragraf = NONE,
            })))
        end)

        it('refuses half a citation', function()
            -- A kapitel with no balk renders as a broken reference on every
            -- record that cites the offence, and gets noticed in court.
            local code, fields = brott.validate(entry({ balk = NONE }))

            assert.are.equal('invalid', code)
            assert.are.equal('incomplete_citation', fields.balk)

            assert.are.equal('invalid', brott.validate(entry({ paragraf = NONE })))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('citation', function()
        it('builds the compact legal citation', function()
            assert.are.equal('BrB 8:1', brott.citation({
                balk = 'BrB', kapitel = 8, paragraf = 1,
            }))
        end)

        it('has none for an agency-local code that cites no statute', function()
            assert.is_nil(brott.citation({ balk = nil, kapitel = nil, paragraf = nil }))
            assert.is_nil(brott.citation({ balk = 'BrB', kapitel = 8 }))
            assert.is_nil(brott.citation(nil))
        end)
    end)
end)
