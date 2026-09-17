--- Evidence logic (spec 8).
---
--- Two things are worth proving here above everything else: that nothing hidden
--- can reach a client through the shaping functions (8.11), and that a database
--- hit never comes back as an identification (8.1.3). The rest of section 8 is
--- mechanics; those two are the design.

local helper = require('spec.helper')

describe('evidence', function()
    local evidence

    before_each(function()
        evidence = helper.load({ 'server/modules/evidence/service' }).Modules.evidence
    end)

    describe('public', function()
        it('keeps the fields an officer needs', function()
            local out = evidence.public({
                id = 7,
                ref = 'a1b2c3',
                evidenceNumber = 'LSPD-2026-000123',
                type = 'casing',
                packaging = 'envelope',
                sealState = 'sealed',
                status = 'collected',
            })

            assert.are.equal(7, out.id)
            assert.are.equal('LSPD-2026-000123', out.evidenceNumber)
            assert.are.equal('casing', out.type)
            assert.are.equal('sealed', out.sealState)
        end)

        it('never carries the owner or the weapon serial', function()
            -- 8.11. If this test ever fails, an officer can read off whose
            -- blood it is without the lab, and the whole of section 8 is
            -- decoration.
            local out = evidence.public({
                id = 7,
                type = 'blood',
                identifier = 'char1:license:abc',
                ownerIdentifier = 'char1:license:abc',
                weaponSerial = 'SN-0001',
                dnaProfile = 'deadbeef',
            })

            assert.is_nil(out.identifier)
            assert.is_nil(out.ownerIdentifier)
            assert.is_nil(out.weaponSerial)
            assert.is_nil(out.dnaProfile)
        end)

        it('never carries quality', function()
            -- Quality predicts whether the lab will get a profile. Telling the
            -- collecting officer would let them know the answer before the
            -- analysis, which is the metagame 8.11 forbids.
            local out = evidence.public({ id = 7, type = 'blood', quality = 90 })
            assert.is_nil(out.quality)
        end)

        it('is an allowlist, so a new column is hidden until it is named', function()
            local out = evidence.public({ id = 7, somethingAddedLater = 'secret' })
            assert.is_nil(out.somethingAddedLater)
        end)
    end)

    describe('renderData', function()
        it('carries only what is needed to draw it', function()
            local out = evidence.renderData({
                key = 'g:12:4',
                type = 'casing',
                x = 1.0, y = 2.0, z = 3.0,
                model = 'w_ar_carbinerifle_mag1',
                ownerKey = 'char1:license:abc',
                quality = 80,
            })

            assert.are.equal('casing', out.type)
            assert.are.equal(1.0, out.x)
            assert.is_nil(out.ownerKey)
            assert.is_nil(out.quality)
        end)
    end)

    describe('numbering', function()
        it('formats an evidence number', function()
            assert.are.equal('LSPD-2026-000123', evidence.evidenceNumber('lspd', 2026, 123))
        end)

        it('formats a scene number', function()
            assert.are.equal('LSPD-S-2026-0042', evidence.sceneNumber('LSPD', 2026, 42))
        end)

        it('pads so numbers sort lexically', function()
            local first = evidence.evidenceNumber('lspd', 2026, 9)
            local second = evidence.evidenceNumber('lspd', 2026, 10)
            assert.is_true(first < second)
        end)
    end)

    describe('numberPrefix', function()
        --- The repo builds a number inside the INSERT that allocates its
        --- sequence, out of a prefix and a padded number. This is the test that
        --- keeps that assembly honest: if the two ever drift, one agency's
        --- numbering changes shape halfway through a year and nobody notices
        --- until two items share a number.
        local function assembled(kind, agencyShort, year, sequence)
            local prefix, width = evidence.numberPrefix(kind, agencyShort, year)
            return prefix .. ('%0' .. width .. 'd'):format(sequence)
        end

        it('rebuilds exactly what evidenceNumber formats', function()
            for _, sequence in ipairs({ 1, 9, 10, 123, 999999 }) do
                assert.are.equal(
                    evidence.evidenceNumber('lspd', 2026, sequence),
                    assembled('evidence', 'lspd', 2026, sequence)
                )
            end
        end)

        it('rebuilds exactly what sceneNumber formats', function()
            for _, sequence in ipairs({ 1, 42, 9999 }) do
                assert.are.equal(
                    evidence.sceneNumber('bcso', 2027, sequence),
                    assembled('scene', 'bcso', 2027, sequence)
                )
            end
        end)

        it('upper-cases the agency, as the number does', function()
            assert.are.equal('LSPD-2026-', (evidence.numberPrefix('evidence', 'lspd', 2026)))
        end)

        it('has nothing to say about a kind it does not number', function()
            assert.is_nil(evidence.numberPrefix('report', 'lspd', 2026))
        end)
    end)

    describe('parseIds', function()
        it('turns a list of strings into integers', function()
            assert.are.same({ 7, 12 }, evidence.parseIds({ '7', '12' }))
        end)

        it('drops a repeat rather than queueing the same work twice', function()
            assert.are.same({ 7 }, evidence.parseIds({ '7', '7' }))
        end)

        it('refuses the whole list when one entry is not an id', function()
            -- Analysing four of the five items an officer selected, silently,
            -- would be worse than refusing: they would believe the fifth was
            -- tested and come to court saying so.
            assert.is_nil(evidence.parseIds({ '7', 'x' }))
            assert.is_nil(evidence.parseIds({ '7', '2.5' }))
            assert.is_nil(evidence.parseIds({ '7', '0' }))
            assert.is_nil(evidence.parseIds({ '7', '-3' }))
        end)

        it('refuses an empty list and one that is too long', function()
            assert.is_nil(evidence.parseIds({}))
            assert.is_nil(evidence.parseIds({ '1', '2', '3' }, 2))
        end)

        it('refuses anything that is not a list', function()
            assert.is_nil(evidence.parseIds('7'))
            assert.is_nil(evidence.parseIds(nil))
        end)
    end)

    describe('qualityAfter', function()
        it('is untouched at the moment of creation', function()
            assert.are.equal(100, evidence.qualityAfter(100, 0, {}))
        end)

        it('falls with age', function()
            assert.are.equal(90, evidence.qualityAfter(100, 5 * 3600, { decayPerHour = 2 }))
        end)

        it('is hit hard by rain, but only outdoors', function()
            local outside = evidence.qualityAfter(100, 0, { outdoors = true, raining = true })
            local inside = evidence.qualityAfter(100, 0, { outdoors = false, raining = true })

            assert.are.equal(75, outside)
            assert.are.equal(100, inside)
        end)

        it('leaves something behind after cleaning', function()
            -- 8.10: luminol still finds cleaned blood, at a lower yield. A
            -- cleaned scene is a worse scene, not an innocent one.
            local cleaned = evidence.qualityAfter(100, 0, { cleaned = true })

            assert.is_true(cleaned > 0)
            assert.are.equal(25, cleaned)
        end)

        it('never goes below zero or above the cap', function()
            assert.are.equal(0, evidence.qualityAfter(100, 1000 * 3600, {}))
            assert.are.equal(100, evidence.qualityAfter(150, 0, {}))
        end)

        it('treats a negative age as no age at all', function()
            -- A clock that went backwards, or a row stamped slightly ahead of
            -- the server. Ageing by a negative number would *raise* quality,
            -- so the age is clamped rather than the result.
            assert.are.equal(10, evidence.qualityAfter(10, -5, { decayPerHour = 100 }))
        end)
    end)

    describe('shouldMerge', function()
        local function trace(overrides)
            local base = { type = 'blood', ownerKey = 'a', x = 0, y = 0, z = 0 }
            for key, value in pairs(overrides or {}) do base[key] = value end
            return base
        end

        it('merges the same trace from the same person, close together', function()
            assert.is_true(evidence.shouldMerge(trace(), trace({ x = 0.2 }), 0.5))
        end)

        it('does not merge different people', function()
            assert.is_false(evidence.shouldMerge(trace(), trace({ ownerKey = 'b' }), 0.5))
        end)

        it('does not merge different types', function()
            assert.is_false(evidence.shouldMerge(trace(), trace({ type = 'casing' }), 0.5))
        end)

        it('does not merge across the radius', function()
            assert.is_false(evidence.shouldMerge(trace(), trace({ x = 2.0 }), 0.5))
        end)
    end)

    describe('turnaroundSeconds', function()
        it('reads the configured minutes for the analysis', function()
            local config = { analysisMinutes = { dna = 40 } }
            assert.are.equal(40 * 60, evidence.turnaroundSeconds('dna', 'routine', config))
        end)

        it('is shorter at higher priority', function()
            local config = { analysisMinutes = { dna = 40 } }

            assert.are.equal(20 * 60, evidence.turnaroundSeconds('dna', 'expedited', config))
            assert.are.equal(10 * 60, evidence.turnaroundSeconds('dna', 'urgent', config))
        end)

        it('falls back rather than failing on an unconfigured analysis', function()
            assert.are.equal(30 * 60, evidence.turnaroundSeconds('something_new', 'routine', {}))
        end)
    end)

    describe('dnaResult', function()
        it('gives a full profile from a good single-source sample', function()
            assert.are.equal('profile_obtained', evidence.dnaResult(90, 1))
        end)

        it('gives a partial profile from a degraded one', function()
            assert.are.equal('partial_profile', evidence.dnaResult(30, 1))
        end)

        it('gives nothing from a ruined one', function()
            assert.are.equal('no_profile', evidence.dnaResult(5, 1))
        end)

        it('reports a mixture whatever the quality', function()
            assert.are.equal('mixture', evidence.dnaResult(100, 2))
        end)
    end)

    describe('comparisonResult', function()
        it('identifies on a good matching sample', function()
            assert.are.equal('identification', evidence.comparisonResult(true, 90))
        end)

        it('excludes on a good non-matching sample', function()
            assert.are.equal('exclusion', evidence.comparisonResult(false, 90))
        end)

        it('is inconclusive on a poor sample either way', function()
            -- A degraded sample that happens to match is a reason to take a
            -- fresh reference, not a conclusion (8.1.3).
            assert.are.equal('inconclusive', evidence.comparisonResult(true, 30))
            assert.are.equal('inconclusive', evidence.comparisonResult(false, 30))
        end)

        it('is insufficient when there is nothing to compare', function()
            assert.are.equal('insufficient', evidence.comparisonResult(true, 5))
        end)
    end)

    describe('searchResult', function()
        it('returns a candidate, never an identification', function()
            -- 8.1.3 and 8.8. A hit is a lead. If this ever returns
            -- 'identification', an investigation becomes a database lookup and
            -- confirmation stops meaning anything.
            local result = evidence.searchResult(1, 100)

            assert.are.equal('candidate_match', result)
            assert.are_not.equal('identification', result)
        end)

        it('says so when the index has nothing', function()
            assert.are.equal('no_match', evidence.searchResult(0, 100))
        end)

        it('will not search on an unusable sample', function()
            assert.are.equal('insufficient', evidence.searchResult(5, 5))
        end)
    end)

    describe('analysisPublic', function()
        local finished = {
            id = 3,
            requestId = 1,
            evidenceId = 7,
            analysis = 'dna',
            status = 'complete',
            assignedTo = '100000000000000009',
            resultCode = 'profile_obtained',
            observations = 'Extracted from the swab.',
            identifier = 'char1:license:abc',
            dnaProfile = 'deadbeef',
        }

        it('shows the queue without showing the answer', function()
            local out = evidence.analysisPublic(finished, false)

            assert.are.equal('dna', out.analysis)
            assert.are.equal('complete', out.status)
            assert.is_nil(out.resultCode)
            assert.is_nil(out.observations)
        end)

        it('shows the result to a reader cleared for it', function()
            local out = evidence.analysisPublic(finished, true)

            assert.are.equal('profile_obtained', out.resultCode)
        end)

        it('withholds a result that does not exist yet', function()
            -- An analysis in progress has no conclusion. Sending a half-written
            -- one would let an analyst be watched over the shoulder, and would
            -- leak whatever a retry wrote before it was overwritten.
            local out = evidence.analysisPublic({
                id = 3, analysis = 'dna', status = 'in_progress', resultCode = 'profile_obtained',
            }, true)

            assert.is_nil(out.resultCode)
        end)

        it('never carries hidden truth, whoever is reading', function()
            local out = evidence.analysisPublic(finished, true)

            assert.is_nil(out.identifier)
            assert.is_nil(out.dnaProfile)
        end)
    end)

    describe('resultFor', function()
        it('reads DNA off quality alone when the scene was clean', function()
            assert.are.equal('profile_obtained', evidence.resultFor('dna', { quality = 90 }))
            assert.are.equal('partial_profile', evidence.resultFor('dna', { quality = 30 }))
        end)

        it('turns a contaminated scene into a mixture', function()
            -- 8.4: somebody walked the perimeter without protective equipment
            -- and left their own DNA on top of the offender's. A perfect sample
            -- of two people is still a mixture.
            assert.are.equal('mixture', evidence.resultFor('dna', { quality = 100, contaminated = true }))
        end)

        it('identifies a print against the references on file', function()
            assert.are.equal(
                'identification',
                evidence.resultFor('print_comparison', { quality = 90, referenceHits = 1 })
            )
            assert.are.equal(
                'exclusion',
                evidence.resultFor('print_comparison', { quality = 90, referenceHits = 0 })
            )
        end)

        it('never identifies from a database search', function()
            -- 8.1.3 and 8.8, enforced at the one place that chooses the
            -- language: a search produces a lead, and confirming it needs a
            -- fresh reference sample.
            for _, analysis in ipairs({ 'print_search', 'ballistics' }) do
                local hit = evidence.resultFor(analysis, { quality = 100, indexHits = 3 })

                assert.are.equal('candidate_match', hit)
                assert.is_false(evidence.isCourtGrade(hit))
            end
        end)

        it('says GSR is consistent with firing, never that it proves it', function()
            assert.are.equal('candidate_match', evidence.resultFor('gsr', { quality = 80, hasWeapon = true }))
            assert.are.equal('no_match', evidence.resultFor('gsr', { quality = 80, hasWeapon = false }))
        end)

        it('identifies a substance, or admits the sample is gone', function()
            assert.are.equal('identification', evidence.resultFor('drug_id', { quality = 80 }))
            assert.are.equal('insufficient', evidence.resultFor('drug_id', { quality = 5 }))
        end)

        it('treats a missing quality as an unusable sample', function()
            assert.are.equal('no_profile', evidence.resultFor('dna', {}))
            assert.are.equal('insufficient', evidence.resultFor('print_search', nil))
        end)

        it('has no result for an analysis the lab does not run', function()
            assert.is_nil(evidence.resultFor('astrology', { quality = 100 }))
        end)
    end)

    describe('isAnalysis', function()
        it('accepts what the lab performs and nothing else', function()
            assert.is_true(evidence.isAnalysis('dna'))
            assert.is_true(evidence.isAnalysis('ballistics'))
            assert.is_false(evidence.isAnalysis('astrology'))
            assert.is_false(evidence.isAnalysis(''))
        end)
    end)

    describe('isCourtGrade', function()
        it('accepts a direct comparison', function()
            assert.is_true(evidence.isCourtGrade('identification'))
            assert.is_true(evidence.isCourtGrade('exclusion'))
        end)

        it('rejects a database hit and an unfinished analysis', function()
            assert.is_false(evidence.isCourtGrade('candidate_match'))
            assert.is_false(evidence.isCourtGrade('partial_profile'))
            assert.is_false(evidence.isCourtGrade('inconclusive'))
            assert.is_false(evidence.isCourtGrade(nil))
        end)
    end)
end)
