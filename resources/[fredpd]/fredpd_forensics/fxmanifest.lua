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
}
