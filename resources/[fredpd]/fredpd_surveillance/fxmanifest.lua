fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_surveillance'
description 'FredPD surveillance: wiretaps, radio monitoring, listening devices, trackers'
author 'Rami'
version '0.0.0'
repository 'https://github.com/Admin-Chatterly/FredPD'

dependencies {
    'ox_lib',
    'pma-voice',
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
}
