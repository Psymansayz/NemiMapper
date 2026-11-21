-- The alert when a forest has every node kind (9/9 in the scout window) or, by its setting, every kind still
-- unclaimed today, given once per forest entry.
-- The screen flashes green for ALERT_SECONDS, a second on and a second off, through a transparent rectangle.
-- A nearly invisible rectangle takes the mouse's clicks, with the scout window raised above it.
-- Alerts can end early via a button on the scout window.

local Forest = require("src/game/forest")
local Settings = require("src/data/settings")

local FullForestAlert = {}

local SUBSCRIPTION = "nemi_mapper_full_forest"
local LOGIC_TICKS_A_SECOND = 50
local ALERT_SECONDS = 5
local FLASH_SECONDS = 1 -- on this long, then off this long
local FLASH_COLOUR = 0x2ECC4070 -- green, partly see-through
-- A fully transparent rectangle may take no clicks, and one this faint shows nothing.
local BLOCKER_COLOUR = 0x00000001

FullForestAlert.onBlocked = nil   -- called when the blocker goes up (main.lua reopens the scout window over it)
FullForestAlert.onUnblocked = nil -- called when it comes down

local alerted = false -- this forest entry's alert has been given
local flash, blocker = nil, nil -- the rectangles, while shown
local ticks = 0 -- logic ticks since the alert began

local function swallowInput() return false end

-- Returns a rectangle in colour over the whole of pluginLayer.
-- A plugin's component ignores input until enabled, so with takesClicks it is enabled as well as not clickthrough, and
-- swallows clicks, holds and releases.
local function fullScreen(pluginLayer, colour, takesClicks)
    local rectangle = ui.Rectangle.new(pluginLayer)
    rectangle.fill = true
    rectangle.rgba = colour
    rectangle.clickthrough = not takesClicks
    if takesClicks then
        rectangle.enabled = true
        for _, hook in ipairs({ ui.Hook.ONCLICK, ui.Hook.ONHOLD, ui.Hook.ONRELEASE }) do
            rectangle:Subscribe(hook, swallowInput)
        end
    end
    rectangle:SetPos(0, 0)
    rectangle:SetSize(0, 0, 1.0, 1.0) -- the whole plugin layer
    return rectangle
end

function FullForestAlert.isBlocking()
    return blocker ~= nil
end

-- Removes anything shown and gives the mouse back to the game: at the alert's end, through the scout window's
-- button, on leaving or when the plugin stops.
function FullForestAlert.stop()
    Event.Logic.Unsubscribe(SUBSCRIPTION)
    if flash ~= nil then
        flash:Destroy()
        flash = nil
    end
    if blocker ~= nil then
        blocker:Destroy()
        blocker = nil
        FullForestAlert.onUnblocked()
    end
end

local function onLogicTick()
    ticks = ticks + 1
    if ticks >= ALERT_SECONDS * LOGIC_TICKS_A_SECOND then return FullForestAlert.stop() end
    local flashTicks = FLASH_SECONDS * LOGIC_TICKS_A_SECOND
    if flash ~= nil and ticks % flashTicks == 0 then flash.hidden = ticks // flashTicks % 2 == 1 end
end

-- Called when what was found changes. Alerts the first time this forest entry is complete.
function FullForestAlert.check()
    if alerted then return end
    if not (Settings.flashOnFullForest or Settings.blockOnFullForest) then return end
    local kinds, _, missedKinds = Forest.scoutCounts()
    if not Forest.isFull(kinds, missedKinds, Settings.alertOnNeededNodes) then return end
    alerted, ticks = true, 0
    Event.Logic.Subscribe(SUBSCRIPTION, onLogicTick)
    local pluginLayer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if Settings.blockOnFullForest then
        blocker = fullScreen(pluginLayer, BLOCKER_COLOUR, true)
        FullForestAlert.onBlocked()
    end
    if Settings.flashOnFullForest then
        flash = fullScreen(pluginLayer, FLASH_COLOUR, false)
    end
end

-- Re-arms the alert on entering a forest. Leaving the last one stopped its alert.
function FullForestAlert.reset()
    alerted = false
end

return FullForestAlert
