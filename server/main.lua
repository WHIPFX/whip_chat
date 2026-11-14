-- ============================================
-- whip_chat — server
--
-- Routing, hooks, modes and command suggestions. Export names and the message shape match stock
-- cfx chat. Differences from stock:
--
--   1. Typed messages go through whip_core's SecureEvent: length cap and rate limit.
--   2. The client sends only the message and the mode; the server sets the author.
--   3. The author is the character name, or the account name before a character is loaded.
--   4. A message reaches players within network range (Config.NetworkRange); /global reaches everyone.
-- ============================================

local RESOURCE = GetCurrentResourceName()

local MAX_MESSAGE_LEN = 256   -- must match MAX_LENGTH in html/js/chat.js

-- Server-side command suggestions are off: the sweep (players × commands × ACE checks) ran on every
-- resource start. Client-side suggestions still reach the composer. Set true to send them again.
local SUGGESTIONS = false

local hooks   = {}   -- ['<resource>:<id>'] = { fn, resource } — see registerMessageHook
local modes   = {}   -- [name] = modeData

--- Forward declaration: the `whip_chat:init` handler below calls it before its definition.
local refreshCommandsFor

-- ============================================
-- Helpers
-- ============================================

--- The name a message is attributed to: the loaded character, else the account name (players at the
--- character screen can still talk).
local function displayName(source)
    if source == 0 then return 'console' end

    -- Whip.core returns false when whip_core is down, so chat still works.
    local name = Whip.core:GetPlayerFullName(source)
    if type(name) == 'string' and name ~= '' then
        return name
    end

    return GetPlayerName(source) or 'unknown'
end

local function playersAllowedBy(seObject)
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        if IsPlayerAceAllowed(id, seObject) then
            out[#out + 1] = id
        end
    end
    return out
end

--- Default recipients: players within network range of the speaker and in the same routing bucket.
--- Everyone (-1) from the console or when whip_core can't answer. A speaker with no ped sees only
--- their own line.
---@param source number
---@return number|table
local function nearbyTarget(source)
    if source == 0 then return -1 end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return { source } end
    local list = Whip.core:GetPlayersInRange(GetEntityCoords(ped))
    if type(list) ~= 'table' then return -1 end
    -- Same bucket: a player at the character screen sits in a bucket of their own.
    local bucket = GetPlayerRoutingBucket(source)
    local out = {}
    for _, id in ipairs(list) do
        if GetPlayerRoutingBucket(id) == bucket then out[#out + 1] = id end
    end
    return out
end

--- Send one chat line to a list of players, packed once (TriggerClientEvent packs per call).
---@param ids table
---@param outMessage table
local function sendTo(ids, outMessage)
    if #ids == 0 then return end
    local payload = msgpack.pack_args(outMessage)
    local len = payload:len()
    for _, id in ipairs(ids) do TriggerClientEventInternal('chat:addMessage', id, payload, len) end
end

--- Clean a line typed as a command the way SecureEvent cleans typed chat: strip control characters,
--- cut to MAX_MESSAGE_LEN without splitting a UTF-8 character. nil if nothing is left.
---@param text string
---@return string|nil
local function cleanLine(text)
    text = tostring(text or ''):sub(1, MAX_MESSAGE_LEN):gsub('[%z\1-\8\11\12\14-\31]', '')
    -- If the cut split the last character, walk back over continuation bytes (at most 3) to its lead.
    local n = #text
    local j = n
    while j > 1 and j > n - 3 do
        local b = text:byte(j)
        if b < 0x80 or b >= 0xC0 then break end
        j = j - 1
    end
    local lead = n > 0 and text:byte(j) or 0
    local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    if n > 0 and j + need - 1 > n then text = text:sub(1, j - 1) end
    if text:match('^%s*$') then return nil end
    return text
end

local function clientModeObject(modeData)
    return {
        name        = modeData.name,
        displayName = modeData.displayName,
        color       = modeData.color or '#fff',
        isChannel   = modeData.isChannel,
        isGlobal    = modeData.isGlobal,
    }
end

-- ============================================
-- Exports — the stock surface
-- ============================================

--- addMessage(message) broadcasts; addMessage(target, message) sends to one player.
exports('addMessage', function(target, message)
    if message == nil then
        message = target
        target  = -1
    end
    if target == nil or message == nil then return end

    TriggerClientEvent('chat:addMessage', target, message)
end)

--- Register a hook that sees every routed message and may rewrite, reroute or cancel it.
--- hook(source, message, ref) where ref has updateMessage/cancel/setRouting/setSeObject.
---
--- Keyed `<your resource>:<id>`: registering the same key again replaces it, so re-registering from
--- Whip.register is safe. `id` is only needed to hold two hooks.
---@param hook function
---@param id string|nil
---@return boolean ok, string|nil why
exports('registerMessageHook', function(hook, id)
    -- `hook ~= nil`, not a type check: a function passed through an export is not type 'function'.
    -- Hooks are pcall'd when a message routes.
    if hook == nil then return false, 'registerMessageHook needs a function' end

    local resource = GetInvokingResource() or GetCurrentResourceName()
    hooks[resource .. ':' .. tostring(id or 'default')] = { fn = hook, resource = resource }
    return true
end)

--- Register a chat mode (a channel, an OOC lane, a radio frequency).
---
--- A name held by another running resource is refused with the owner named. The same resource
--- registering its mode again replaces it.
---@param modeData table  { name, displayName, cb, seObject? }
---@return boolean ok, string|nil why
exports('registerMode', function(modeData)
    local resource = GetInvokingResource() or GetCurrentResourceName()   -- first, before anything else
    if type(modeData) ~= 'table' then return false, 'registerMode takes a table: { name, displayName, cb }' end
    if not modeData.name then return false, 'a chat mode needs a name' end
    if not modeData.displayName then return false, ('chat mode "%s" needs a displayName'):format(tostring(modeData.name)) end
    if modeData.cb == nil then return false, ('chat mode "%s" needs a cb'):format(tostring(modeData.name)) end

    local held = modes[modeData.name]
    if held and held.resource and held.resource ~= resource and GetResourceState(held.resource) == 'started' then
        return false, ('chat mode "%s" belongs to %s'):format(tostring(modeData.name), held.resource)
    end

    modeData.resource = resource
    modes[modeData.name] = modeData

    local clObj = clientModeObject(modeData)

    if not modeData.seObject then
        TriggerClientEvent('chat:addMode', -1, clObj)
    else
        for _, id in ipairs(playersAllowedBy(modeData.seObject)) do
            TriggerClientEvent('chat:addMode', id, clObj)
        end
    end

    return true
end)

-- ============================================
-- Routing
-- ============================================

--- `global`: to everyone (/global, /say) rather than the players near the speaker.
local function routeMessage(source, message, mode, fromConsole, global)
    local author = displayName(source)
    if global and source ~= 0 then author = '[Global] ' .. author end

    local outMessage = {
        color     = { 255, 255, 255 },
        multiline = true,
        args      = { message },
        mode      = mode,
    }

    if author ~= '' then
        outMessage.args = { author, message }
    end

    -- A mode the sender isn't allowed is dropped silently, before hooks run, so a hook can't watch a
    -- channel it shouldn't see.
    local modeData = mode and modes[mode] or nil
    if modeData and modeData.seObject and not IsPlayerAceAllowed(source, modeData.seObject) then
        return
    end

    local canceled = false

    -- nil = the default (nearbyTarget, or -1 when global). A hook may set one server id, or a list
    -- of ids via setSeObject.
    ---@type number|string|table|nil
    local routingTarget = nil

    local ref = {
        updateMessage = function(patch)
            if type(patch) ~= 'table' then return end
            for k, v in pairs(patch) do
                if k == 'template' then
                    outMessage.template = v:gsub('%{%}', outMessage.template or '@default')
                elseif k == 'params' then
                    outMessage.params = outMessage.params or {}
                    for pk, pv in pairs(v) do outMessage.params[pk] = pv end
                else
                    outMessage[k] = v
                end
            end
        end,
        cancel      = function() canceled = true end,
        setSeObject = function(object) routingTarget = playersAllowedBy(object) end,
        setRouting  = function(target) routingTarget = target end,
    }

    -- pcall: one broken satellite hook must not take chat down. Errors are printed.
    for _, hook in pairs(hooks) do
        if hook.fn then
            local ok, err = pcall(hook.fn, source, outMessage, ref)
            if not ok then
                print(('[whip_chat] message hook from "%s" errored: %s')
                    :format(tostring(hook.resource), tostring(err)))
            end
        end
    end

    if modeData then
        local ok, err = pcall(modeData.cb, source, outMessage, ref)
        if not ok then
            print(('[whip_chat] mode "%s" callback errored: %s'):format(tostring(mode), tostring(err)))
            return
        end
    end

    if canceled then return end

    -- The documented server-side hook: CancelEvent() here stops delivery.
    TriggerEvent('chatMessage', source, #outMessage.args > 1 and outMessage.args[1] or '',
        outMessage.args[#outMessage.args])

    if not WasEventCanceled() then
        if routingTarget == nil then routingTarget = global and -1 or nearbyTarget(source) end
        if type(routingTarget) ~= 'table' then
            TriggerClientEvent('chat:addMessage', routingTarget, outMessage)
        else
            sendTo(routingTarget, outMessage)
        end
    end

    if not fromConsole then
        -- One line in the log: line breaks in a message could forge console lines.
        print(('%s^7%s: %s^7'):format(
            author,
            modeData and (' (' .. modeData.displayName .. ')') or '',
            (tostring(message):gsub('[\r\n]', ' '))))
    end
end

exports('routeMessage', routeMessage)

-- ============================================
-- Inbound from the client
-- ============================================

--- The inbound events, declared through Whip.register so they come back after a whip_core restart.
local function RegisterWithWhip()
    -- Three messages back to back, then one per 400 ms. requirePlayer = false: chat works at the
    -- character screen. whileDead: chat works while dead.
    exports.whip_core:SecureEvent('whip_chat:messageEntered', {
        whileDead = true,
        rateLimit     = 400,
        burst         = 3,
        requirePlayer = false,
        params = {
            { 'message', 'string', MAX_MESSAGE_LEN },
            { 'mode',    'string', 32, '' },
        },
    }, function(source, _, message, mode)
        if mode == '' then mode = nil end
        routeMessage(source, message, mode, false)
    end)

    exports.whip_core:SecureEvent('whip_chat:init', {
        whileDead = true,
        rateLimit     = 1000,
        requirePlayer = false,
    }, function(source)
        if SUGGESTIONS then refreshCommandsFor(source) end

        for _, modeData in pairs(modes) do
            if not modeData.seObject or IsPlayerAceAllowed(source, modeData.seObject) then
                TriggerClientEvent('chat:addMode', source, clientModeObject(modeData))
            end
        end
    end)
end

Whip.register(RegisterWithWhip)

--- The same allowance typed chat gets: three back to back, then one per 400ms.
local FALLBACK_INTERVAL_MS, FALLBACK_BURST = 400, 3
local _fallbackBucket = {}   -- [src] = { tokens, at }

local function fallbackAllowed(src)
    local now = GetGameTimer()
    local b = _fallbackBucket[src]
    if not b then
        b = { tokens = FALLBACK_BURST, at = now }
        _fallbackBucket[src] = b
    end
    local refill = (now - b.at) // FALLBACK_INTERVAL_MS
    if refill >= 1 then
        b.tokens = math.min(FALLBACK_BURST, b.tokens + refill)
        b.at = now
    end
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

AddEventHandler('playerDropped', function() _fallbackBucket[source] = nil end)

--- A /command nothing handled is echoed as chat, as stock does, so a typo is visible. Rate-limited,
--- length-capped and logged like typed chat.
AddEventHandler('__cfx_internal:commandFallback', function(command)
    local src = source
    CancelEvent()
    if src ~= 0 and not fallbackAllowed(src) then return end
    local text = cleanLine('/' .. tostring(command):sub(1, MAX_MESSAGE_LEN))
    if not text then return end
    routeMessage(src, text, nil, src == 0)
end)

-- ============================================
-- Command suggestions
-- ============================================

--- Send a player the commands they are allowed to run.
---@param player number|string  server id
refreshCommandsFor = function(player)
    if not GetRegisteredCommands then return end

    local out = {}
    for _, command in ipairs(GetRegisteredCommands()) do
        local allowed = IsPlayerAceAllowed(player, ('command.%s'):format(command.name))
        -- whip_core's admin commands are open to FiveM's ACE and check their own permission, so ask
        -- whip_core which ACE each one needs.
        if allowed and command.resource == 'whip_core' then
            local ok, ace = pcall(function() return exports.whip_core:GetCommandAce(command.name) end)
            if ok and type(ace) == 'string' then allowed = IsPlayerAceAllowed(player, ace) end
        end
        if allowed then
            out[#out + 1] = { name = '/' .. command.name, help = '' }
        end
    end

    TriggerClientEvent('chat:addSuggestions', player, out)
end

--- Re-send suggestions when resources start. Debounced: one sweep covers every start in the window.
local suggestionsSweepArmed = false
AddEventHandler('onServerResourceStart', function()
    if not SUGGESTIONS or suggestionsSweepArmed then return end
    suggestionsSweepArmed = true
    CreateThread(function()
        Wait(1000)
        suggestionsSweepArmed = false
        for _, id in ipairs(GetPlayers()) do
            refreshCommandsFor(id)
        end
    end)
end)

-- ============================================
-- Built-in commands and notices
-- ============================================

-- /say: a server notice. The console, and whip.devtools with developer mode on (Whip.command's dev gate).
Whip.command('say', { dev = true, whileDead = true }, function(source, _, rawCommand)
    local text = cleanLine(tostring(rawCommand or ''):sub(5))
    if text then routeMessage(source, text, nil, true, true) end
end)

--- /global <message>: to every player. Same rate limit and cleaning as typed chat. The line is cut
--- before any pattern runs on it (a command line can be ~64 KB).
--- Only with a character loaded: at the character screen the message would go out under the account's name, which a
--- player sets to anything they like (another character's name, "Admin"), and reach everyone.
RegisterCommand('global', function(source, _, rawCommand)
    if source ~= 0 and not fallbackAllowed(source) then return end
    if source ~= 0 and Whip.core:IsPlayerLoaded(source) ~= true then
        -- With whip_core stopped there is no character to ask about, and no toast: said in chat instead.
        if GetResourceState('whip_core') ~= 'started' then
            TriggerClientEvent('chat:addMessage', source, { args = { '/global needs whip_core, which is not running' } })
        else
            Whip.core:NotifyPlayer(source, 'Pick a character first: /global goes out under their name', 'error')
        end
        return
    end
    local raw = tostring(rawCommand or ''):sub(1, MAX_MESSAGE_LEN + 64)
    local text = raw:match('^%S+%s+(.*%S)')
    text = text and cleanLine(text)
    if not text then return end
    routeMessage(source, text, nil, source == 0, true)
end, false)

AddEventHandler('playerJoining', function()
    if GetConvarInt('chat_showJoins', 1) == 0 then return end
    TriggerClientEvent('chatMessage', -1, '', { 255, 255, 255 },
        '^2* ' .. (GetPlayerName(source) or 'someone') .. ' joined.')
end)

AddEventHandler('playerDropped', function(reason)
    if GetConvarInt('chat_showQuits', 1) == 0 then return end
    TriggerClientEvent('chatMessage', -1, '', { 255, 255, 255 },
        '^2* ' .. (GetPlayerName(source) or 'someone') .. ' left (' .. tostring(reason) .. ')')
end)

-- ============================================
-- Another chat beside this one
-- ============================================

--- A second chat answers the same events and opens on T as well: every line shows twice, in two chat boxes, and its
--- text box takes the keyboard from whip's. Stock cfx chat is `chat`; a replacement says `provide 'chat'` in its
--- fxmanifest.lua. client/main.lua has the same test.
local function isOtherChat(res)
    if res == RESOURCE then return false end
    if res == 'chat' then return true end
    for i = 0, (GetNumResourceMetadata(res, 'provide') or 0) - 1 do
        if GetResourceMetadata(res, 'provide', i) == 'chat' then return true end
    end
    return false
end

local function warnOtherChat(res)
    print(('^1[whip_chat] %s is another chat, running beside whip_chat: every message shows twice, in two chat boxes,'
        .. ' and T opens both, so typing can get stuck^0'):format(res))
    print(('^1[whip_chat] fix: type "stop %s" in this console, and take "ensure %s" out of server.cfg (if it still'
        .. ' starts, put "stop %s" after "ensure whip_chat")^0'):format(res, res, res))
end

-- Whichever starts first: the ones already running now, the rest as they start.
for i = 0, GetNumResources() - 1 do
    local res = GetResourceByFindIndex(i)
    if res and GetResourceState(res) == 'started' and isOtherChat(res) then warnOtherChat(res) end
end

AddEventHandler('onResourceStart', function(res)
    if isOtherChat(res) then warnOtherChat(res) end
end)

-- ============================================
-- Teardown
-- ============================================

--- A stopped resource's hooks and modes go with it.
AddEventHandler('onResourceStop', function(stopped)
    if stopped == RESOURCE then return end

    for key, hook in pairs(hooks) do
        if hook.resource == stopped then hooks[key] = nil end
    end

    for name, modeData in pairs(modes) do
        if modeData.resource == stopped then
            TriggerClientEvent('chat:removeMode', -1, { name = name })
            modes[name] = nil
        end
    end
end)
