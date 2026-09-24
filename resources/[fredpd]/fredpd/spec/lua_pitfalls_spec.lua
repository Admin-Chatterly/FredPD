--- Lua mistakes that pass every other check and fail only at runtime.
---
--- `t[#t + 1], t[#t + 1] = a, b` looks like two appends. In Lua every index in
--- a multiple assignment is worked out before anything is assigned, so both
--- land in the same slot and the list gains one value, not two. Seven cursor
--- pages (anmalan, FU, spaning, tvångsmedel, the query log) sent fewer values
--- than their SQL had placeholders, so every "load more" failed, and nothing
--- noticed: busted fakes the database, and the mock NUI never runs Lua.

describe('lua pitfalls', function()
    it('the language does what this spec says it does', function()
        local t = { 'x' }
        t[#t + 1], t[#t + 1] = 'a', 'b'
        assert.are.equal(2, #t)
    end)

    it('no file appends twice in one multiple assignment', function()
        local offenders = {}
        local listing = assert(io.popen('find resources -name "*.lua" -not -path "*/spec/*"'))

        for path in listing:lines() do
            local number = 0
            for line in io.lines(path) do
                number = number + 1
                local code = line:gsub('%-%-.*$', '')
                for name in code:gmatch('([%w_%.]+)%[#[%w_%.]+ %+ 1%]%s*,') do
                    if code:find(name .. '[#' .. name .. ' + 1]', 1, true) then
                        offenders[#offenders + 1] = ('%s:%d'):format(path, number)
                        break
                    end
                end
            end
        end
        listing:close()

        assert.are.same({}, offenders)
    end)
end)
