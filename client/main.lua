-- ============================================
-- whip_chat — client
--
-- Drop-in replacement for the stock cfx `chat` resource. Event names, export names and NUI
-- message types match stock on purpose: other resources call `chat:addMessage` and must not
-- notice the swap.
--
-- The text field lives in whip_core (the player capsule turns into it while T is held); this
-- resource owns the message log, the suggestion and mode lists, and everything that sends or
-- runs a line.
-- ============================================

local RESOURCE = GetCurrentResourceName()

--- Command and argument hints, in first-seen order. `_suggestionOrder` is the display list;
--- `_suggestionIndex` maps name -> position so re-offering the whole command set stays cheap.
local _suggestionOrder = {}
local _suggestionIndex = {}

--- Chat modes (`/me`, OOC, radio...), registered by satellites through `chat:addMode`.
local _modes = {}

--- True while whip_core's composer is open for chat, so only chat's own lines come back here.
local _composerOpen = false

local HIDE_WHEN_ACTIVE = 0
local HIDE_ALWAYS_SHOW = 1
local HIDE_ALWAYS_HIDE = 2

--- Each mode as /toggleChat (F6) announces it.
local HIDE_NAMES = {
    [HIDE_WHEN_ACTIVE] = 'new messages show, then fade away',
    [HIDE_ALWAYS_SHOW] = 'always on screen',
    [HIDE_ALWAYS_HIDE] = 'hidden',
}

-- Has the page reported in?
local chatLoaded = false

local hideState   = tonumber(GetResourceKvpString('whip_chat:hideState') or '') or HIDE_WHEN_ACTIVE
local isFirstHide = true
--- The player's chosen state while a screen, the pause menu or a fade forces chat hidden; -1 when nothing forces it.
local preForceState = -1

--- The visibility the player chose, not the forced "hidden".
local function chosenHideState()
    if preForceState ~= -1 then return preForceState end
    return hideState
end

--- Set the player's visibility choice (F6, /toggleChat, Server Settings). Saved in KVP; while chat is
--- forced hidden it becomes the state to return to.
local function chooseHideState(state)
    if preForceState ~= -1 then preForceState = state else hideState = state end
    isFirstHide = false
    SetResourceKvp('whip_chat:hideState', tostring(state))
end

-- ============================================
-- Outbound: everything that puts something on screen
-- ============================================

local function addMessage(message)
    if type(message) == 'string' then
        message = { args = { message } }
    end
    if type(message) ~= 'table' then return end

    SendNUIMessage({ type = 'ON_MESSAGE', message = message })
end

exports('addMessage', addMessage)

--- Record one suggestion. An existing name is replaced in place: the full command set is re-offered on
--- every resource start/stop, so appending would duplicate entries and reorder the list.
--- Key-mapping commands (`+name` / `-name`, run on key press and release) are never offered.
local function recordSuggestion(name, help, params)
    if type(name) ~= 'string' or name == '' then return end
    if name:find('^/?[+-]') then return end

    local entry = { name = name, help = help or '', params = params or nil }
    local at = _suggestionIndex[name]

    if at then
        _suggestionOrder[at] = entry
    else
        _suggestionOrder[#_suggestionOrder + 1] = entry
        _suggestionIndex[name] = #_suggestionOrder
    end
end

local function addSuggestion(name, help, params)
    recordSuggestion(name, help, params)
end

exports('addSuggestion', addSuggestion)

--- Chat size relative to whip's other panels: 1 = same size, 1.2 = a fifth bigger. The page already
--- scales to the resolution, so this is taste only.
exports('SetChatScale', function(scale)
    SendNUIMessage({ type = 'ON_SET_SCALE', scale = tonumber(scale) or 1 })
end)

-- ============================================
-- Stock event surface
--
-- Net events so the server can trigger them too (TriggerClientEvent('chat:addMessage', src, ...)).
-- ============================================

RegisterNetEvent('chat:addMessage', addMessage)
RegisterNetEvent('chat:addSuggestion', addSuggestion)

RegisterNetEvent('chat:addSuggestions', function(list)
    if type(list) ~= 'table' then return end

    -- Stock accepts one suggestion (a table with `name`) or a list of them.
    if list.name then
        recordSuggestion(list.name, list.help, list.params)
        return
    end

    for _, s in ipairs(list) do
        if type(s) == 'table' then recordSuggestion(s.name, s.help, s.params) end
    end
end)

RegisterNetEvent('chat:removeSuggestion', function(name)
    local at = _suggestionIndex[name]
    if not at then return end

    table.remove(_suggestionOrder, at)
    _suggestionIndex[name] = nil

    -- Shift every later index down, or the next recordSuggestion overwrites the wrong entry.
    for n, i in pairs(_suggestionIndex) do
        if i > at then _suggestionIndex[n] = i - 1 end
    end
end)

RegisterNetEvent('chat:addTemplate', function(id, html)
    SendNUIMessage({ type = 'ON_TEMPLATE_ADD', template = { id = id, html = html } })
end)

RegisterNetEvent('chat:addMode', function(mode)
    if type(mode) ~= 'table' or type(mode.name) ~= 'string' then return end

    for i, m in ipairs(_modes) do
        if m.name == mode.name then _modes[i] = mode; return end
    end
    _modes[#_modes + 1] = mode
end)

RegisterNetEvent('chat:removeMode', function(name)
    -- Accepts a bare name or a mode table, as stock does.
    local target = type(name) == 'table' and name.name or name

    for i, m in ipairs(_modes) do
        if m.name == target then table.remove(_modes, i); return end
    end
end)

RegisterNetEvent('chat:clear', function()
    SendNUIMessage({ type = 'ON_CLEAR' })
end)

--- Deprecated; kept for old resources. Use chat:addMessage.
RegisterNetEvent('chatMessage', function(author, color, text)
    local args = { text }
    if author and author ~= '' then
        table.insert(args, 1, author)
    end
    SendNUIMessage({
        type = 'ON_MESSAGE',
        message = { color = color, multiline = true, args = args },
    })
end)

--- Server console output mirrored to the client, e.g. from `sv_echo`.
RegisterNetEvent('__cfx_internal:serverPrint', function(msg)
    print(msg)
    SendNUIMessage({
        type = 'ON_MESSAGE',
        message = { templateId = 'print', multiline = true, args = { msg }, mode = '_global' },
    })
end)

-- ============================================
-- Inbound: the player pressed Enter
-- ============================================

--- A line the player typed into the capsule.
---
--- This runs text as a command, so it trusts its caller completely. Its only caller is whip_core's
--- composer, which origin-checks the NUI request (whip_core/client/composer.lua) before calling
--- here. Keep it a file local: never export it or give it a second caller.
---
--- @param message string The raw line, already non-empty and length-capped by the composer
--- @param mode string|nil The chat mode that was active, or nil for plain say
local function OnComposerSubmit(message, mode)
    _composerOpen = false
    SendNUIMessage({ type = 'ON_SET_ACTIVE', active = false })

    message = tostring(message or '')
    if #message == 0 then return end

    if message:sub(1, 1) == '/' then
        -- Only a slash runs anything. Commands with no client handler go to the server, where ACE
        -- decides; `__cfx_internal:commandFallback` catches what nothing claims.
        ExecuteCommand(message:sub(2))
    else
        -- Message and mode only: the server sets the author from the source.
        TriggerServerEvent('whip_chat:messageEntered', message, mode)
    end
end

-- ============================================
-- Command suggestions
-- ============================================

local function refreshCommands()
    if not GetRegisteredCommands then return end

    for _, command in ipairs(GetRegisteredCommands()) do
        -- Client-side commands; the server sends its own list (server/main.lua).
        if IsAceAllowed(('command.%s'):format(command.name)) and command.name ~= 'toggleChat' then
            -- Never overwrite an entry that already has real help text with an empty one.
            if not _suggestionIndex['/' .. command.name] then
                recordSuggestion('/' .. command.name, '')
            end
        end
    end
end

RegisterNUICallback('loaded', function(_, cb)
    chatLoaded = true

    TriggerServerEvent('whip_chat:init')
    refreshCommands()

    addSuggestion('/toggleChat', 'Cycle chat visibility', {
        { name = 'state', help = 'whenactive | visible | hidden' },
    })
    addSuggestion('/clearchat', 'Clear your chat messages (only on your screen)')
    -- A server command, offered here because the server's list is off (server/main.lua, SUGGESTIONS).
    addSuggestion('/global', 'Message every player on the server', {
        { name = 'message', help = 'what to say' },
    })

    -- Push the saved state now that the page exists.
    SendNUIMessage({
        type = 'ON_SCREEN_STATE_CHANGE',
        hideState = hideState,
        fromUserInteraction = false,
    })

    cb('ok')
end)

-- Debounced: start/stop fire once per resource, so a boot would otherwise refresh dozens of times.
local refreshArmed = false
local function armCommandRefresh()
    if refreshArmed then return end
    refreshArmed = true
    CreateThread(function()
        Wait(1000)
        refreshArmed = false
        if chatLoaded then refreshCommands() end
    end)
end

AddEventHandler('onClientResourceStart', armCommandRefresh)
AddEventHandler('onClientResourceStop', armCommandRefresh)

-- ============================================
-- Visibility
-- ============================================

RegisterCommand('toggleChat', function(_, args)
    local state = args and args[1]
    local want

    if state == 'visible' then
        want = HIDE_ALWAYS_SHOW
    elseif state == 'hidden' then
        want = HIDE_ALWAYS_HIDE
    elseif state == 'whenactive' then
        want = HIDE_WHEN_ACTIVE
    else
        -- Cycle from the player's choice, not from a forced "hidden".
        want = (chosenHideState() + 1) % 3
    end
    chooseHideState(want)

    -- Announce the change: the mode is saved, and a stray F6 is otherwise silent. A notification, so
    -- it shows in the hidden mode too.
    Whip.core:Notify(('Chat: %s (F6 changes it)'):format(HIDE_NAMES[want] or tostring(want)), 'info', 5000)
end, false)

-- The same three states on the pause menu's Server Settings page. The value stays in this resource's KVP.
Whip.playerSetting({
    key = 'chat.visibility', group = 'Chat & voice', type = 'choice', label = 'Chat messages',
    help = 'New messages show, then fade away; stay on screen; or chat is hidden. F6 changes it too.',
    options = {
        { value = HIDE_WHEN_ACTIVE, label = 'Fade away' },
        { value = HIDE_ALWAYS_SHOW, label = 'Stay on screen' },
        { value = HIDE_ALWAYS_HIDE, label = 'Hidden' },
    },
    default = HIDE_WHEN_ACTIVE,
    get = function() return chosenHideState() end,
    set = function(state)
        state = math.floor(tonumber(state) or HIDE_WHEN_ACTIVE)
        if HIDE_NAMES[state] then chooseHideState(state) end
    end,
})

-- F6, not stock's L: whip_core binds L to vehicle lock.
RegisterKeyMapping('toggleChat', 'Toggle chat visibility', 'keyboard', 'F6')

--- Empty this player's own message log. Nobody else's chat changes, and messages that arrive afterwards show as
--- usual. The same as the stock `chat:clear` event, as a command.
RegisterCommand('clearchat', function()
    SendNUIMessage({ type = 'ON_CLEAR' })
end, false)

--- Failsafe for "chat has my keyboard": hands the controls back without depending on chat state.
--- Usable from the F8 console.
RegisterCommand('resetchat', function()
    _composerOpen = false

    -- whip_core holds the keyboard, so ask it to close first; then release locally anyway in case
    -- whip_core is what broke.
    Whip.core:CloseComposer()
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'ON_SET_ACTIVE', active = false })

    print('[whip_chat] composer closed and NUI focus released.')
    print('[whip_chat] if that did not help, try /resetcomposer — the text field belongs to '
        .. 'whip_core and that is its own escape hatch.')
end, false)

-- ============================================
-- Is any whip UI open? — pushed, not polled
-- ============================================
--
-- Chat won't open over a whip screen and hides while one is up. whip_core pushes the state; this is
-- a local copy. Seeded on register (and again after a core restart) because an event only reports
-- changes.
local uiOpen = false

AddEventHandler('whip_core:ui:stateChanged', function(e)
    uiOpen = (e and e.open) and true or false
end)

Whip.register(function()
    -- IsAnyScreenOpen, which a progress bar alone does not count for: one should not hide chat.
    uiOpen = Whip.core:IsAnyScreenOpen() == true
end)

-- ============================================
-- Opening — a bound key, not a polled control
-- ============================================
--
-- `+whip_chat` on key down opens the composer; `-whip_chat` on key up gives it the keyboard.
-- Taking focus on the press would type the "t" into the field. Nothing else reads the chat key:
-- two routes for one press would fire twice.

--- Open chat: the capsule's field for T, or whip's pad keyboard (`onPad`, the wheel's Chat below).
---@param onPad boolean
local function openChat(onPad)
    -- The flag can outlive the composer (a whip_core restart or /resetcomposer ends it without
    -- onCancel), so confirm with whip_core before refusing to open.
    if _composerOpen then
        if Whip.core:IsComposerOpen() == true then return end
        _composerOpen = false
        SendNUIMessage({ type = 'ON_SET_ACTIVE', active = false })
    end

    -- Not over a whip screen, the pause menu or a fade. The wheel's Chat asks afresh: the wheel
    -- itself was a screen a moment ago and the push may not have landed.
    local screenUp = uiOpen
    if onPad then screenUp = Whip.core:IsAnyScreenOpen() == true end
    if screenUp or IsPauseMenuActive() or IsScreenFadedOut() then return end

    -- Whip.core returns false if whip_core is down, where a direct export call would raise and
    -- break the key binding.
    local opened = Whip.core:OpenComposer({
        placeholder = 'Say something, or / for a command',
        maxLength   = 256,

        -- A snapshot at open time is fresh enough.
        modes       = _modes,
        suggestions = _suggestionOrder,

        -- Keyboard is taken on key release (see -whip_chat). The wheel holds no key, so it takes it at once.
        deferFocus  = not onPad,

        -- On a controller: whip's pad keyboard, with the line in its own window above the keys.
        pad         = onPad,
        title       = onPad and 'Chat' or nil,

        onSubmit    = OnComposerSubmit,
        onCancel    = function()
            _composerOpen = false
            SendNUIMessage({ type = 'ON_SET_ACTIVE', active = false })
        end,

        -- PageUp/PageDown scroll our log; our page has no keyboard while the composer does, so
        -- whip_core forwards them.
        onScroll    = function(delta)
            SendNUIMessage({ type = 'ON_SCROLL', delta = delta })
        end,
    })

    if not opened then return end
    _composerOpen = true

    -- Show the log while composing, so the player can see what they reply to.
    SendNUIMessage({ type = 'ON_SET_ACTIVE', active = true })
end

RegisterCommand('+whip_chat', function() openChat(false) end, false)

RegisterCommand('-whip_chat', function()
    if not _composerOpen then return end

    -- Keyboard focus only, never the cursor: the player can keep looking around while typing.
    -- Suggestions are picked with Tab and the arrow keys.
    Whip.core:FocusComposer()
end, false)

RegisterKeyMapping('+whip_chat', 'Open Chat', 'keyboard', 'T')

-- Chat on the F1 wheel while a controller is in use (a pad has no T). Opens whip's pad keyboard;
-- Done sends as Enter would. Offered while downed too. Re-added through Whip.register after a
-- whip_core restart.
Whip.register(function()
    local ok, why = exports.whip_core:AddAction({
        id          = 'chat',
        at          = { radial = true },
        label       = 'Chat',
        icon        = 'talk',
        description = 'Type a message, or / for a command',
        require     = { alive = false },
        canInteract = function() return exports.whip_core:IsControllerActive() == true end,
        onSelect    = function() openChat(true) end,
    })
    if not ok then print('[whip_chat] could not put Chat on the wheel: ' .. tostring(why)) end
end)

-- ============================================
-- Screen state
-- ============================================
--
-- The pause menu and screen fades have no events, so they are polled, five times a second.

CreateThread(function()
    SetTextChatEnabled(false)
    SetNuiFocus(false, false)

    local lastPushedState = -1

    while true do
        Wait(200)

        -- ---- Forced hiding ----
        if chatLoaded then
            -- Hidden over whip screens too: chat can't be opened there, so showing it is just clutter.
            local forceHide = IsScreenFadedOut() or IsPauseMenuActive() or uiOpen
            local restored  = false

            if hideState ~= HIDE_ALWAYS_HIDE then
                if forceHide then
                    preForceState = hideState
                    hideState = HIDE_ALWAYS_HIDE
                end
            elseif not forceHide and preForceState ~= -1 then
                hideState = preForceState
                preForceState = -1
                restored = true
            end

            if hideState ~= lastPushedState then
                lastPushedState = hideState
                SendNUIMessage({
                    type = 'ON_SCREEN_STATE_CHANGE',
                    hideState = hideState,
                    fromUserInteraction = not forceHide and not isFirstHide and not restored,
                })
                isFirstHide = false
            end
        end
    end
end)

--- Warn if the page never calls home: NUI callbacks are broken and no message will ever show.
CreateThread(function()
    Wait(15000)
    if chatLoaded then return end

    print('[whip_chat] WARNING: the chat page has not reported in after 15s.')
    print('[whip_chat] NUI callbacks are not reaching Lua, so chat messages will not show.')
    print('[whip_chat] Check the fetch URL in html/js/chat.js: the callback host is '
        .. 'https://<resource>/<name>, NOT the origin the page is served from.')
end)

--- Another chat on this client: said in F8, where someone looking at two chat boxes looks. The same test as
--- server/main.lua, whose console line has the fix.
local function isOtherChat(res)
    if res == RESOURCE then return false end
    if res == 'chat' then return true end
    for i = 0, (GetNumResourceMetadata(res, 'provide') or 0) - 1 do
        if GetResourceMetadata(res, 'provide', i) == 'chat' then return true end
    end
    return false
end

local function warnOtherChat(res)
    print(('^1[whip_chat] %s is another chat, running beside whip_chat: every message shows twice and T opens both.'
        .. ' The server console says how to take it out^0'):format(res))
end

for i = 0, GetNumResources() - 1 do
    local res = GetResourceByFindIndex(i)
    if res and GetResourceState(res) == 'started' and isOtherChat(res) then warnOtherChat(res) end
end

AddEventHandler('onClientResourceStart', function(res)
    if isOtherChat(res) then warnOtherChat(res) end
end)

-- whip_core closes our composer itself when we stop; only our own state needs resetting.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end

    _composerOpen = false

    SetNuiFocus(false, false)
    SetTextChatEnabled(true)
end)
