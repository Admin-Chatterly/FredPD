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
            -- Read off the sample and nothing else. 8.2: "a swab says this
            -- person fired something, never what" -- so there is no weapon
            -- serial on a swab's owner row to search against, and a rule that
            -- looked for one answered `no_match` for every swab that can exist.
            assert.are.equal('candidate_match', evidence.resultFor('gsr', { quality = 100 }))
            assert.are.equal('candidate_match', evidence.resultFor('gsr', { quality = 80 }))
            assert.are.equal('insufficient', evidence.resultFor('gsr', { quality = 5 }))
            assert.is_false(evidence.isCourtGrade(evidence.resultFor('gsr', { quality = 100 })))
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

    describe('ownerOf', function()
        it('keeps a person', function()
            local owner = evidence.ownerOf({ owner = { identifier = 'char1:license:abc' } })

            assert.are.equal('char1:license:abc', owner.identifier)
            assert.is_nil(owner.weaponSerial)
        end)

        it('keeps a weapon, which is what a casing carries instead', function()
            local owner = evidence.ownerOf({ owner = { weaponSerial = 'SN-0001' } })

            assert.are.equal('SN-0001', owner.weaponSerial)
            assert.is_nil(owner.identifier)
        end)

        it('has no owner for a trace with neither', function()
            -- `ck_fpd_evidence_owner_one` refuses to store one, and 8.3.4 says
            -- why: the owner of a trace is its source. Answering nil is what
            -- lets the route refuse the collection instead of driving the
            -- insert into the constraint.
            assert.is_nil(evidence.ownerOf({ owner = {} }))
            assert.is_nil(evidence.ownerOf({}))
            assert.is_nil(evidence.ownerOf(nil))
        end)

        it('treats a blank identifier as no identifier', function()
            -- It would pass the CHECK and attribute the trace to nobody, which
            -- is worse than no owner row: the lab would compare the sample
            -- against an empty profile and report an exclusion.
            assert.is_nil(evidence.ownerOf({ owner = { identifier = '   ' } }))
            assert.is_nil(evidence.ownerOf({ owner = { identifier = 7 } }))
        end)

        it('trims what it keeps', function()
            local owner = evidence.ownerOf({ owner = { weaponSerial = ' SN-0001 ' } })

            assert.are.equal('SN-0001', owner.weaponSerial)
        end)
    end)

    describe('canIntake', function()
        it('accepts an item on its way into the property room', function()
            assert.is_true(evidence.canIntake('collected'))
            assert.is_true(evidence.canIntake('in_locker'))
            assert.is_true(evidence.canIntake('checked_out'))
            assert.is_true(evidence.canIntake('at_lab'))
        end)

        it('refuses one whose disposition has been carried out', function()
            -- 8.6: released and destroyed are terminal. An item that has left
            -- does not come back, and the custody chain is append-only, so an
            -- entry written against one could never be corrected.
            assert.is_false(evidence.canIntake('released'))
            assert.is_false(evidence.canIntake('destroyed'))
            assert.is_false(evidence.canIntake('in_property'))
            assert.is_false(evidence.canIntake(nil))
        end)
    end)

    describe('traceIndexFor', function()
        it('files a DNA profile as an unidentified crime-scene trace', function()
            assert.are.equal('dna_trace', evidence.traceIndexFor('dna', 'profile_obtained'))
        end)

        it('files a partial too, because a partial is searchable', function()
            assert.are.equal('dna_trace', evidence.traceIndexFor('dna', 'partial_profile'))
        end)

        it('files nothing when no profile came out of the sample', function()
            -- A mixture is more than one contributor (8.7), and a profile of
            -- two people is a profile of neither.
            assert.is_nil(evidence.traceIndexFor('dna', 'mixture'))
            assert.is_nil(evidence.traceIndexFor('dna', 'no_profile'))
        end)

        it('has nothing to file from an analysis that is already a search', function()
            assert.is_nil(evidence.traceIndexFor('print_search', 'candidate_match'))
            assert.is_nil(evidence.traceIndexFor('ballistics', 'candidate_match'))
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

-- -----------------------------------------------------------------------------
-- The routes (spec 11.5)
-- -----------------------------------------------------------------------------
--
-- `routes.lua` is not pure the way a `service.lua` is, so it is loaded against a
-- fake route registry, a fake repo and a placement test that answers where the
-- player is standing. What the handlers decide -- where a check-out may happen,
-- what may be written into an append-only chain, and what an analyst is told
-- when nothing was written -- is decided in this file and nowhere else, so it is
-- worth a harness rather than a game server.

local function loadInto(path)
    assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(path)))()
end

describe('evidence routes', function()
    local routes, state, printed, realPrint

    --- Only what the handlers under test call. Anything they reach for that is
    --- not here fails loudly rather than answering nil, which is the point: a
    --- handler that starts calling something new shows up as a broken test.
    local function fakeRepo()
        return {
            getEvidence = function(_agencyId, id) return state.items[id] end,
            getScene = function(_agencyId, id) return state.scenes[id] end,
            currentHolder = function() return 'A. Lindqvist' end,
            unprotectedEntries = function() return state.unprotected end,
            latestCaseNumberFor = function() return state.latestCaseNumber end,
            listEvidence = function() return state.listResults end,
            analysesForEvidenceIds = function() return state.analysesForIds end,

            appendCustody = function(entry, discordId)
                state.custody[#state.custody + 1] = { entry = entry, signedBy = discordId }
                return #state.custody
            end,

            setEvidenceStatus = function(_agencyId, id, status, storage, fromStatuses)
                local item = state.items[id]
                if not item then return 0 end

                for index = 1, #fromStatuses do
                    if fromStatuses[index] == item.status then
                        item.status = status
                        item.storageLocation = storage or item.storageLocation
                        return 1
                    end
                end

                return 0
            end,

            insertEvidence = function(_agencyId, input, owner, _discordId)
                state.inserted[#state.inserted + 1] = { input = input, owner = owner }
                return { id = 9, evidenceNumber = 'LSPD-2026-000009', type = input.type }
            end,

            hiddenFacts = function() return state.facts end,
            analysisNotice = function() return state.notice end,
            indexHits = function() return state.indexHits end,
            completeAnalysis = function() return state.completedRows end,
            completionBlocker = function() return state.blocker end,

            indexTraceProfile = function(_agencyId, evidenceId, indexKind, discordId)
                state.indexed[#state.indexed + 1] = {
                    evidenceId = evidenceId, indexKind = indexKind, addedBy = discordId,
                }
                return 1
            end,
        }
    end

    local function analyst()
        return helper.session({ discordId = '100000000000000009' })
    end

    local function call(name, session, input)
        return routes[name].handler(session, input)
    end

    before_each(function()
        state = {
            items = {
                [1] = { id = 1, status = 'in_property', storageLocation = 'vault-1' },
                [2] = { id = 2, status = 'collected' },
                [3] = { id = 3, status = 'released' },
            },
            scenes = {},
            custody = {},
            inserted = {},
            indexed = {},
            notified = {},
            notice = {
                requestedBy = '100000000000000001', caseNumber = 'FU26-00001',
                evidenceNumber = 'LSPD-2026-000001', analysis = 'dna',
            },
            unprotected = 0,
            latestCaseNumber = nil,
            listResults = {},
            analysesForIds = {},
            indexHits = 0,
            completedRows = 1,
            blocker = nil,
            -- Where the player actually is, by placement kind.
            standingAt = {},
            trace = { type = 'blood', quality = 90, owner = { identifier = 'char1:license:abc' } },
            facts = {
                id = 5,
                analysis = 'dna',
                status = 'in_progress',
                assignedTo = '100000000000000009',
                evidenceId = 1,
                quality = 90,
            },
        }

        -- The collect handler writes a line to the console when the generation
        -- pipeline hands it something impossible. Captured so the test output
        -- stays readable, and so the test can prove it was written.
        printed = {}
        realPrint = _G.print
        _G.print = function(line) printed[#printed + 1] = line end

        local FredPD = helper.load({
            'shared/generated/schema',
            'server/modules/evidence/service',
        })

        routes = {}

        FredPD.Config = { server = { lab = { analysisMinutes = { dna = 40 } } } }

        FredPD.Core = {
            route = {
                define = function(definition) routes[definition.name] = definition end,
                refuse = function(code, fields) return { __err = code, fields = fields } end,
            },
            perms = { satisfies = function() return true end },
            placements = {
                playerIsAt = function(_src, placementId, kind)
                    return state.standingAt[kind] == placementId
                end,
            },
            -- Two sessions online: the requester, and the same Discord id
            -- signed on in another agency. Only the first may be told.
            push = {
                notifyWhere = function(predicate, key, params)
                    for _, other in ipairs({
                        helper.session({ src = 2 }),
                        helper.session({ src = 3, agencyId = 'bcso' }),
                    }) do
                        if predicate(other) then
                            state.notified[#state.notified + 1] = {
                                src = other.src, discordId = other.discordId, key = key, params = params,
                            }
                        end
                    end
                end,
            },
        }
        FredPD.t = function(key) return key end

        FredPD.Repo = { evidence = fakeRepo() }
        FredPD.Evidence = { claimTrace = function() return state.trace end }

        loadInto('server/modules/evidence/routes')
    end)

    after_each(function()
        _G.print = realPrint
    end)

    describe('evidence.transfer', function()
        it('refuses a check-out from outside the property room', function()
            -- 8.6 puts check-out at the counter beside intake. Without this an
            -- item can be taken out of the vault from anywhere in the world.
            local result = call('evidence.transfer', helper.session(), {
                id = 1, destination = 'lab', reason = 'Ballistics',
            })

            assert.are.equal('context', result.__err)
            assert.are.equal('required', result.fields.placementId)
            assert.are.equal('in_property', state.items[1].status)
            assert.are.same({}, state.custody)
        end)

        it('refuses a placement the player is not actually standing at', function()
            state.standingAt.property_terminal = 4

            local result = call('evidence.transfer', helper.session(), {
                id = 1, destination = 'court', reason = 'Hearing', placementId = 7,
            })

            assert.are.equal('context', result.__err)
            assert.are.equal('not_allowed', result.fields.placementId)
        end)

        it('checks an item out at the counter', function()
            state.standingAt.property_terminal = 7

            local result = call('evidence.transfer', helper.session(), {
                id = 1, destination = 'lab', reason = 'Ballistics', placementId = 7,
            })

            assert.is_nil(result.__err)
            assert.are.equal('at_lab', result.status)
            assert.are.equal('checkout', state.custody[1].entry.action)
        end)

        it('lets the collecting officer deposit in a locker without one', function()
            -- The other half of 8.6: a temporary locker is where the officer
            -- puts the item before the property room opens, and there is no
            -- counter to stand at when they do it.
            local result = call('evidence.transfer', helper.session(), {
                id = 2, destination = 'locker', reason = 'End of shift',
            })

            assert.is_nil(result.__err)
            assert.are.equal('in_locker', result.status)
            assert.are.equal('deposit', state.custody[1].entry.action)
        end)
    end)

    describe('evidence.intake', function()
        it('refuses a rejection against an item that has been released', function()
            -- The chain is append-only (invariant 11): an entry written against
            -- an item whose disposition has been carried out can never be taken
            -- back, so the state is checked before anything is written.
            local result = call('evidence.intake', helper.session(), {
                id = 3, accepted = false, reason = 'Seal broken', placementId = 1,
            })

            assert.are.equal('conflict', result.__err)
            assert.are.equal('released', result.fields.status)
            assert.are.same({}, state.custody)
        end)

        it('records a rejection against an item that could have been accepted', function()
            local result = call('evidence.intake', helper.session(), {
                id = 2, accepted = false, reason = 'Description does not match', placementId = 1,
            })

            assert.is_false(result.accepted)
            assert.are.equal('intake', state.custody[1].entry.action)
            assert.are.equal('Description does not match', state.custody[1].entry.reason)
            -- A rejection moves nothing.
            assert.are.equal('collected', state.items[2].status)
        end)
    end)

    describe('evidence.collect', function()
        it('refuses a trace nobody left', function()
            -- 8.3.4: the owner of a trace is its source. One with neither a
            -- person nor a weapon is a bug in the generation pipeline, and the
            -- officer is told that rather than shown a server error.
            state.trace = { type = 'blood', quality = 90, owner = {} }

            local result = call('evidence.collect', helper.session(), { traceKey = 'g:12:4' })

            assert.are.equal('invalid', result.__err)
            assert.are.equal('unattributed', result.fields.traceKey)
            assert.are.same({}, state.inserted)
            assert.are.equal(1, #printed)
        end)

        it('collects an attributed trace', function()
            local result = call('evidence.collect', helper.session(), { traceKey = 'g:12:4' })

            assert.is_nil(result.__err)
            assert.are.equal('char1:license:abc', state.inserted[1].owner.identifier)
            -- The type comes from the grid, never from the call (8.3.6).
            assert.are.equal('blood', state.inserted[1].input.type)
        end)

        it("falls back to the officer's own latest case when the call names none", function()
            -- So an officer working a scene alone, or swabbing residue with no
            -- scene open at all, is not retyping the same case number for every
            -- trace they pick up.
            state.latestCaseNumber = 'LSPD-2026-000004'

            call('evidence.collect', helper.session(), { traceKey = 'g:12:4' })

            assert.are.equal('LSPD-2026-000004', state.inserted[1].input.caseNumber)
        end)

        it("prefers an explicit case number over the officer's latest", function()
            state.latestCaseNumber = 'LSPD-2026-000004'

            call('evidence.collect', helper.session(), {
                traceKey = 'g:12:4', caseNumber = 'LSPD-2026-000009',
            })

            assert.are.equal('LSPD-2026-000009', state.inserted[1].input.caseNumber)
        end)

        it("prefers the scene's case number over the officer's latest", function()
            state.latestCaseNumber = 'LSPD-2026-000004'
            state.scenes[7] = { id = 7, status = 'open', caseNumber = 'LSPD-2026-000001' }

            call('evidence.collect', helper.session(), { traceKey = 'g:12:4', sceneId = 7 })

            assert.are.equal('LSPD-2026-000001', state.inserted[1].input.caseNumber)
        end)
    end)

    describe('evidence.list', function()
        before_each(function()
            state.listResults = {
                { id = 1, ref = 'r1', evidenceNumber = 'LSPD-2026-000001', type = 'blood', status = 'collected' },
            }
            state.analysesForIds = {
                {
                    id = 5, requestId = 1, evidenceId = 1, evidenceNumber = 'LSPD-2026-000001',
                    analysis = 'dna', status = 'complete', assignedTo = '100000000000000009',
                    priority = 'normal', caseNumber = 'LSPD-2026-000001',
                    resultCode = 'profile_obtained', observations = 'Matched to reference sample',
                },
            }
        end)

        it('does not fetch analyses when not listing by a case', function()
            local result = call('evidence.list', helper.session(), {})

            assert.is_nil(result.items[1].analyses)
        end)

        it("attaches each item's analyses when listing by case", function()
            local result = call('evidence.list', helper.session(), { caseNumber = 'LSPD-2026-000001' })

            assert.are.equal(1, #result.items[1].analyses)
            assert.are.equal('profile_obtained', result.items[1].analyses[1].resultCode)
        end)

        it("withholds the result from a reader without lab.queue.view, but keeps the queue entry", function()
            FredPD.Core.perms.satisfies = function(_permissions, key) return key ~= 'lab.queue.view' end

            local result = call('evidence.list', helper.session(), { caseNumber = 'LSPD-2026-000001' })

            assert.are.equal('complete', result.items[1].analyses[1].status)
            assert.is_nil(result.items[1].analyses[1].resultCode)
        end)

        it('gives an evidence item with no analyses an empty list, not nil, when listing by case', function()
            state.analysesForIds = {}

            local result = call('evidence.list', helper.session(), { caseNumber = 'LSPD-2026-000001' })

            assert.are.same({}, result.items[1].analyses)
        end)
    end)

    describe('lab.analysis.complete', function()
        it('tells an analyst whose analysis was cancelled, not to keep waiting', function()
            state.completedRows = 0
            state.blocker = { status = 'cancelled', elapsed = 1 }

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('conflict', result.__err)
            assert.are.equal('cancelled', result.fields.status)
            assert.is_nil(result.fields.dueAt)
        end)

        it('tells an analyst who is early to wait', function()
            state.completedRows = 0
            state.blocker = { status = 'in_progress', elapsed = 0 }

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('conflict', result.__err)
            assert.are.equal('not_elapsed', result.fields.dueAt)
        end)

        it('reports a write that should have happened as a server fault', function()
            state.completedRows = 0
            state.blocker = { status = 'in_progress', elapsed = 1 }

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('internal', result.__err)
        end)

        it('reports an analysis that is gone as not found', function()
            state.completedRows = 0
            state.blocker = nil

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('not_found', result.__err)
        end)

        it('files the profile it obtained in the trace index', function()
            -- 8.8: a new crime-scene profile joins the trace index, without a
            -- subject -- that is what makes a later hit a lead and not a
            -- lookup (8.1.3).
            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('profile_obtained', result.resultCode)
            assert.are.equal('dna_trace', state.indexed[1].indexKind)
            assert.are.equal(1, state.indexed[1].evidenceId)
        end)

        it('tells the officer who asked, without the result', function()
            call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal(1, #state.notified)
            assert.are.equal(2, state.notified[1].src)
            assert.are.equal('100000000000000001', state.notified[1].discordId)
            assert.are.equal('lab.notify.completed', state.notified[1].key)
            assert.are.equal('LSPD-2026-000001', state.notified[1].params.item)
            -- A notice says a result exists; it never carries it.
            for _, value in pairs(state.notified[1].params) do
                assert.is_nil(tostring(value):find('profile_obtained', 1, true))
            end
        end)

        it('files nothing when the sample gave no profile', function()
            state.facts.quality = 5

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('no_profile', result.resultCode)
            assert.are.same({}, state.indexed)
        end)

        it('files nothing from an analysis that is itself a search', function()
            state.facts.analysis = 'print_search'
            state.indexHits = 2

            local result = call('lab.analysis.complete', analyst(), { id = 5 })

            assert.are.equal('candidate_match', result.resultCode)
            assert.are.same({}, state.indexed)
        end)
    end)

    describe('where a route may be called from', function()
        it('keeps lab work at the lab terminal', function()
            -- 1.4 limits analysis and technical review to the lab terminal, and
            -- 8.7 makes the turnaround the time an analyst spends at it.
            for _, name in ipairs({ 'lab.analysis.start', 'lab.analysis.complete' }) do
                assert.is_true(routes[name].context.onDuty)
                assert.are.equal('lab_terminal', routes[name].context.accessPoint)
            end
        end)

        it('lets a request be raised from the case it comes from, on duty', function()
            assert.is_true(routes['lab.request.create'].context.onDuty)
            assert.is_nil(routes['lab.request.create'].context.accessPoint)
        end)
    end)

    describe('scene.release', function()
        it('audits the reason the perimeter came down', function()
            -- 8.4 puts a checklist in front of a release and `fpd_scenes` has
            -- no column for it, so the audit log is where it is kept.
            local detail = routes['scene.release'].auditDetail({ id = 1, reason = ' Processed ' })

            assert.are.equal('Processed', detail.reason)
        end)
    end)
end)
