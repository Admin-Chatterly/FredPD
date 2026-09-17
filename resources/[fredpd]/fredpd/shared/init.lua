--- The one global this resource defines. Everything else hangs off it, so
--- luacheck can treat any other new global as the mistake it usually is.
FredPD = FredPD or {}

FredPD.resource = GetCurrentResourceName()
FredPD.version = GetResourceMetadata(FredPD.resource, 'version', 0) or '0.0.0'

--- Server environment: 'development', 'staging' or 'production'.
--- Read from a `set` convar so it never reaches a client.
function FredPD.env()
    return GetConvar('fredpd:env', 'development')
end

function FredPD.isProduction()
    return FredPD.env() == 'production'
end
