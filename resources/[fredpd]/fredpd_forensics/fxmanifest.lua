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
    'shared/init.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    'client/main.lua',

    -- Bridges first: the sensors ask them what they wrap before reporting.
    'client/bridges/doorlock.lua',

    -- The world half of M3 (spec 8.3, 8.4, 8.10). `report` is the one path to
    -- the core's ingest, so the sensors call it rather than the route.
    'client/report.lua',
    'client/sensors.lua',
    'client/render.lua',
    'client/collect.lua',
    'client/destroy.lua',
}
