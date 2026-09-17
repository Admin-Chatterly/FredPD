fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd'
description 'FredPD core: sessions, permissions, records, dispatch, property room, lab, court, personnel, NUI host'
author 'Rami'
version '0.0.0'
repository 'https://github.com/Admin-Chatterly/FredPD'

dependencies {
    'ox_lib',
    'oxmysql',
    'es_extended',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config/shared.lua',
    'shared/init.lua',
    'shared/generated/schema.lua',
    'shared/locale.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- Server-only. Never list this in files {}: it carries the gateway secret
    -- and anything else a client must not see (invariant 7).
    'config/server.lua',
    'server/bridges/framework.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'locales/*.json',
}
