--- Console diagnostics for an operator (spec 3.8, ADR-025).
---
--- Server console only: these read state the MDT cannot show about another
--- player, and print it in the console's own language like every other line
--- FredPD prints there. They change nothing.

--- `fredpd_duty <server id>`: what every duty source says about one player,
--- for "I cannot go on duty". Server console only (txAdmin's live console
--- included): an operator's diagnostic, in the console's own language like
--- every other line FredPD prints there, and it reads duty and nothing else.
RegisterCommand('fredpd_duty', function(source, args)
    if source ~= 0 then return end

    local target = tonumber(args[1])
    if not target or GetPlayerName(target) == nil then
        print('[fredpd] usage: fredpd_duty <server id>')
        return
    end

    local onDuty, decidedBy = FredPD.Bridge.policejob.isOnDuty(target)
    print(('[fredpd] duty for %s (%d): %s, decided by %s'):format(
        GetPlayerName(target), target, onDuty and 'ON duty' or 'OFF duty', decidedBy or 'nothing (no source answered)'))
    for _, answer in ipairs(FredPD.Bridge.policejob.dutySources(target)) do
        local said = answer.onDuty == nil and 'cannot say' or (answer.onDuty and 'on duty' or 'off duty')
        print(('    %-18s %s'):format(answer.source, said))
    end
end, true)
