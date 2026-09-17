--- Internal police chat (spec 7.26, ADR-007).
---
--- The channel writes into a chat box shared with every other resource and with
--- every player, so the two things worth proving are that a message cannot be
--- dressed up to look like something it is not, and that a civilian never
--- receives one.

local helper = require('spec.helper')

describe('chat', function()
    local chat

    before_each(function()
        chat = helper.load({ 'server/modules/chat/service' }).Modules.chat
    end)

    describe('sanitize', function()
        it('keeps an ordinary message intact', function()
            assert.are.equal('plate 4XYZ123 heading north', chat.sanitize('plate 4XYZ123 heading north'))
        end)

        it('strips FiveM colour codes', function()
            -- Left in, these let a sender paint the chat box or imitate the
            -- server-generated prefix.
            assert.are.equal('urgent', chat.sanitize('^1urgent'))
            assert.are.equal('red and blue', chat.sanitize('^1red ^4and ^5blue'))
        end)

        it('strips GTA text tokens', function()
            assert.are.equal('careful', chat.sanitize('~r~careful~s~'))
        end)

        it('cannot be used to forge another officer\'s prefix', function()
            local forged = chat.sanitize('^5 12-99 | Chief Vega ^0 stand down')

            assert.is_not.matches('%^', forged)
        end)

        it('collapses newlines and control characters into spaces', function()
            -- A multi-line message would otherwise scroll the chat box.
            assert.are.equal('one two', chat.sanitize('one\n\n\ttwo'))
        end)

        it('trims surrounding whitespace', function()
            assert.are.equal('hello', chat.sanitize('   hello   '))
        end)

        it('returns nil when nothing usable is left', function()
            assert.is_nil(chat.sanitize('   '))
            assert.is_nil(chat.sanitize('^1^2^3'))
            assert.is_nil(chat.sanitize(''))
        end)

        it('rejects a non-string', function()
            assert.is_nil(chat.sanitize(nil))
            assert.is_nil(chat.sanitize(42))
        end)

        it('caps an over-long message', function()
            local capped = chat.sanitize(string.rep('a', 900))

            assert.are.equal(512, #capped)
        end)
    end)

    describe('format', function()
        it('builds the prefix from the session, not from the message', function()
            local payload = chat.format(helper.session(), 'on scene')

            assert.are.equal('12-40 | A. Lindqvist', payload.args[1])
            assert.are.equal('on scene', payload.args[2])
        end)

        it('falls back to the name when there is no callsign', function()
            local payload = chat.format(helper.session({ callsign = helper.NONE }), 'on scene')

            assert.are.equal('A. Lindqvist', payload.args[1])
        end)
    end)

    describe('canReceive', function()
        local function grants(...)
            local held = {}
            for _, permission in ipairs({ ... }) do held[permission] = true end

            return function(_session, permission) return held[permission] == true end
        end

        it('delivers to an officer in the same agency', function()
            local recipient = helper.session({ agencyId = 'lspd' })

            assert.is_true(chat.canReceive(recipient, 'lspd', grants('comms.pdchat.view')))
        end)

        it('never delivers to someone without the view permission', function()
            -- The case that matters: a civilian has the same chat box open.
            local civilian = helper.session({ agencyId = 'lspd' })

            assert.is_false(chat.canReceive(civilian, 'lspd', grants()))
        end)

        it('does not cross agencies by default', function()
            local other = helper.session({ agencyId = 'bcso' })

            assert.is_false(chat.canReceive(other, 'lspd', grants('comms.pdchat.view')))
        end)

        it('crosses agencies for someone holding the all-agency permission', function()
            local supervisor = helper.session({ agencyId = 'bcso' })

            assert.is_true(chat.canReceive(
                supervisor, 'lspd', grants('comms.pdchat.view', 'comms.pdchat.all')
            ))
        end)

        it('still refuses the all-agency permission without the view permission', function()
            local recipient = helper.session({ agencyId = 'bcso' })

            assert.is_false(chat.canReceive(recipient, 'lspd', grants('comms.pdchat.all')))
        end)
    end)
end)
