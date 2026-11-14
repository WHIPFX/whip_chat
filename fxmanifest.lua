fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'whip_chat'
author 'Whippy'
description 'whip-native chat. Drop-in replacement for the stock cfx `chat` resource.'
version '1.1.0'
whip_updates 'WHIPFX/whip_chat'   -- whip_core checks this repository's releases for a newer version

-- The inbound message event is a whip_core SecureEvent.
dependency 'whip_core'

-- Whip.register re-declares the events after a whip_core restart; Whip.core doesn't error while it's down.
shared_script '@whip_core/lib/satellite.lua'

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    -- Copied from whip_core/html/css/ui.css. Loaded first so chat.css can use the tokens.
    'html/css/tokens.css',
    'html/css/chat.css',
    'html/js/chat.js',
    -- Barlow, the chat's face, its own copy (tokens.css): nothing is fetched from the internet.
    'html/fonts/*.woff2',
}

-- Only this resource's own page may call its NUI callbacks.
nui_callback_strict_mode 'true'
