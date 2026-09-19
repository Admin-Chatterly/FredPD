--- The one global this resource defines. Everything else hangs off it, so
--- luacheck can treat any other new global as the mistake it usually is.
FredPD = FredPD or {}

FredPD.resource = GetCurrentResourceName()
FredPD.version = GetResourceMetadata(FredPD.resource, 'version', 0) or '0.0.0'

--- Server environment: 'development', 'staging' or 'production'.
---
--- Comes from `config/shared.lua`, which has already resolved any convar
--- override. It is read on both sides -- the client uses it to decide how
--- loudly to report a failed route -- so it lives in the shared config rather
--- than the server one. The environment's *name* is not a secret; what it
--- gates is.
function FredPD.env()
    return FredPD.Config.shared.env
end

function FredPD.isProduction()
    return FredPD.env() == 'production'
end
