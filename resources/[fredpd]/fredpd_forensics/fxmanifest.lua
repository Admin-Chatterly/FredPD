fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_forensics'
description 'FredPD forensics: in-world evidence generation, scene tools, packaging, destruction mechanics'
author 'Rami'
version '0.0.0'
repository 'https://github.com/Admin-Chatterly/FredPD'

dependencies {
    'ox_lib',
    'ox_target',
    'fredpd',
}

shared_scripts {
    '@ox_lib/init.lua',

    -- This resource's own namespace first, because it sets `FredPD.resource` to
    -- the core's name and the loader two lines below reads the locale files out
    -- of whatever that says. `@fredpd/shared/init.lua` is deliberately *not*
    -- listed: it sets `FredPD.resource` to `GetCurrentResourceName()`, which in
    -- this state is `fredpd_forensics`, and the loader would then look for
    -- `locales/en.json` in a resource that ships none.
    'shared/init.lua',

    -- FiveM gives this resource its own Lua state, so the core's translation
    -- loader has to be loaded into it (invariant 6, spec 5.1). Without these
    -- two the stub `FredPD.t` in `shared/init.lua` -- which answers with the key
    -- -- is what every prompt, notification and progress label in this resource
    -- uses, and an officer is offered `forensics.collect.option` on a casing.
    --
    -- `config/shared.lua` comes first because `locale.lua` ends by calling
    -- `FredPD.loadLocale(FredPD.Config.shared.locale)`: without it that is an
    -- index of a nil field at load, and the resource dies before a single
    -- interaction is registered.
    '@fredpd/config/shared.lua',
    '@fredpd/shared/locale.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    'client/main.lua',

    -- The world half of M3 (spec 8.3, 8.4, 8.10). `report` is the one path to
    -- the core's ingest, so the sensors call it rather than the route.
    --
    -- Three of the orderings below are load-time dependencies rather than
    -- preferences, because the file resolves the table at load and not at call
    -- time: `sensors` takes `report`; `collect` and `destroy` take `render`;
    -- and `destroy` takes the one timed-action gate, which `collect` publishes
    -- -- which is why `collect` must precede it.
    --
    -- `render` is the exception and resolves nothing from the files above it;
    -- it only creates the namespace and publishes `Render`. Its position here
    -- is free, and it sits above its two consumers so the chain reads in one
    -- direction.
    'client/report.lua',
    'client/sensors.lua',
    'client/render.lua',
    'client/collect.lua',
    'client/destroy.lua',

    -- Bridges last, because a bridge reads the sensor and never the other way
    -- round: nothing in `client/sensors.lua` looks at a bridge, while
    -- `client/bridges/doorlock.lua` resolves `FredPDForensics.Client.sensors`
    -- at load and forwards ox_doorlock's event into it. Listed before
    -- `client/sensors.lua`, that table does not exist yet -- `client/main.lua`
    -- defines nothing -- so the bridge indexes nil and takes the resource down
    -- before a single sensor is armed.
    'client/bridges/doorlock.lua',
}
