-- The keybind to open or close the map: the GameKeys bound, in order, unbound until the player binds them on the
-- settings page. Saved as their names, space-separated (Settings.keybindOpenMap).

local Settings = require("src/data/settings")

local Keybinds = {}

local SUBSCRIPTION = "nemi_mapper_keybinds"
local MODIFIER_BITS = { -- a modifier key's bit in a key event's modifiers
    [GameKey.SHIFT] = ModifierKey.SHIFT, [GameKey.CONTROL] = ModifierKey.CONTROL, [GameKey.ALT] = ModifierKey.ALT,
}

Keybinds.onOpenMap = nil -- called when the keybind is pressed (main.lua)
Keybinds.openMapKeys = {} -- the keys bound

-- Returns whether event completes the binding keys: its key is the last, with the others held.
local function completes(keys, event)
    local count = #keys
    if count == 0 or keys[count] ~= event.gameKey then return false end
    local required, pressedBit = 0, MODIFIER_BITS[event.gameKey] or 0
    for _, key in ipairs(keys) do required = required | (MODIFIER_BITS[key] or 0) end
    if ((event.modifiers & ModifierKey.ANY) | pressedBit) ~= (required | pressedBit) then return false end
    for index = 1, count - 1 do
        if MODIFIER_BITS[keys[index]] == nil and not Keyboard.IsGameKeyDown(keys[index]) then return false end
    end
    return true
end

local function onKeyDown(event)
    if event.isRepeat or prettyui.KeybindField.IsCapturing() then return end
    if not Keyboard.IsAvailable() or Keyboard.IsBlocked() then return end
    if completes(Keybinds.openMapKeys, event) then Keybinds.onOpenMap() end
end

local function listen(wanted)
    if wanted then
        Event.KeyDown.Subscribe(SUBSCRIPTION, onKeyDown)
    else
        Event.KeyDown.Unsubscribe(SUBSCRIPTION)
    end
end

-- Returns a binding's keys from its saved text.
-- A name the game no longer has reads as nil, and is left out.
local function keysOf(text)
    local keys = {}
    for name in text:gmatch("%S+") do
        local key = GameKey[name]
        if key ~= nil and key ~= keys[1] and #keys < 2 then keys[#keys + 1] = key end
    end
    return keys
end

-- Binds the keys from the settings, when loaded or restored, and listens if any are bound.
function Keybinds.apply()
    Keybinds.openMapKeys = keysOf(Settings.keybindOpenMap)
    listen(#Keybinds.openMapKeys > 0)
end

-- Binds keys set on the settings page, and returns them as they are saved: by name and space-separated.
function Keybinds.bind(keys)
    Keybinds.openMapKeys = keys
    listen(#keys > 0)
    local names = {}
    for index, key in ipairs(keys) do names[index] = GameKey.FromID(key) end
    return table.concat(names, " ")
end

-- Stops listening, on leaving the game and at shutdown.
function Keybinds.stop()
    listen(false)
end

return Keybinds
