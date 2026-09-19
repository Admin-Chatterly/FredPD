--- Boot for the forensics resource. M3 fills in the generation pipeline,
--- scenes, packaging and custody enforcement (spec 8).

AddEventHandler('onResourceStart', function(resource)
    if resource ~= FredPDForensics.resource then return end

    if GetResourceState('fredpd') ~= 'started' then
        error('[fredpd_forensics] fredpd is not started. Start the core resource first.')
    end

    print(('[fredpd_forensics] %s started'):format(FredPDForensics.version))
end)
