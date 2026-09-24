--- The link diagram (spec 10.6): only what the reader may see, and only the
--- lines between two things on the board.

local helper = require('spec.helper')

describe('intel board', function()
    local I

    before_each(function()
        I = helper.load({ 'server/modules/intel/service' }).Modules.intel
    end)

    it('draws only the lines whose both ends are on the board', function()
        local board = I.boardGraph(
            { { id = 1, name = 'A' }, { id = 2, name = 'B' } },
            { { id = 10, name = 'Crew' } },
            {
                { personId = 1, orgId = 10, role = 'Boss', isConfirmed = 1 },
                -- A member the reader may not see: the line would name them.
                { personId = 3, orgId = 10, role = 'Driver', isConfirmed = 1 },
                -- An organisation the reader may not see.
                { personId = 2, orgId = 11, role = nil, isConfirmed = 0 },
            },
            {
                { personId = 1, associateId = 2, relationship = 'Cousins', isConfirmed = 0 },
                { personId = 1, associateId = 3, relationship = 'Hidden', isConfirmed = 1 },
            })

        assert.are.equal(1, #board.memberships)
        assert.is_true(board.memberships[1].isConfirmed)
        assert.are.equal(1, #board.associates)
        assert.is_false(board.associates[1].isConfirmed)
        assert.is_false(board.truncated)
    end)

    it('cuts a board past its cap and says so', function()
        local persons = {}
        for id = 1, I.BOARD_PERSON_CAP + 1 do persons[id] = { id = id } end

        local board = I.boardGraph(persons, {}, {}, {})
        assert.are.equal(I.BOARD_PERSON_CAP, #board.persons)
        assert.is_true(board.truncated)
    end)

    it('carries no classification or record detail onto the board', function()
        local board = I.boardGraph({ { id = 1, name = 'A', classification = 'secret', description = 'x' } }, {}, {}, {})
        assert.is_nil(board.persons[1].classification)
        assert.is_nil(board.persons[1].description)
    end)
end)
