--- Boot for the surveillance resource. M5 fills in interception methods,
--- warrant gating and the sweeper (spec 9).

AddEventHandler('onResourceStart', function(resource)
    if resource ~= FredPDSurveillance.resource then return end

    if GetResourceState('fredpd') ~= 'started' then
        error('[fredpd_surveillance] fredpd is not started. Start the core resource first.')
    end

    print(('[fredpd_surveillance] %s started'):format(FredPDSurveillance.version))
end)
