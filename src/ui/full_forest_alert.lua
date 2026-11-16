-- The alert when a forest has every node kind (9/9 in the scout window) or, by its setting, every kind still
-- unclaimed today, given once per forest entry. 
-- The screen flashes green for ALERT_SECONDS, a second on and a second off, through a transparent rectangle
-- A nearly invisible rectangle takes the mouse's clicks, with the scout window raised above it.
-- Alerts can end early via a button on the scout window.

local ForestFeatures = require("src/data/forest_features")
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
-- TEMPORARY, lowered to make the alert easier to test: set back to 9 (every kind) when done.
local KINDS_FOR_ALERT = 6

FullForestAlert.onBlocked = nil   -- called when the blocker goes up (main.lua raises the scout window over it)
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

local function stopListening()
    if flash == nil and blocker == nil then Event.Logic.Unsubscribe(SUBSCRIPTION) end
end

local function removeFlash()
    if flash == nil then return end
    flash:Destroy()
    flash = nil
    stopListening()
end

-- Gives the mouse back to the game, at the alert's end or through stop (the scout window's button, leaving).
function FullForestAlert.unblock()
    if blocker == nil then return end
    blocker:Destroy()
    blocker = nil
    stopListening()
    if FullForestAlert.onUnblocked then FullForestAlert.onUnblocked() end
end

function FullForestAlert.isBlocking()
    return blocker ~= nil
end

local function onLogicTick()
    ticks = ticks + 1
    if ticks >= ALERT_SECONDS * LOGIC_TICKS_A_SECOND then
        removeFlash()
        FullForestAlert.unblock()
        return
    end
    local flashTicks = FLASH_SECONDS * LOGIC_TICKS_A_SECOND
    if flash ~= nil and ticks % flashTicks == 0 then flash.hidden = ticks // flashTicks % 2 == 1 end
end

-- Returns whether the forest should trigger the alert
function FullForestAlert.forestIsComplete(kinds, missedKinds)
    if kinds >= KINDS_FOR_ALERT then return true end
    if not Settings.alertOnNeededNodes then return false end
    local needed = 0
    for _, node in ipairs(ForestFeatures.nodes) do
        if not Forest.isNodeClaimed(node.key) then
            needed = needed + 1
            if (Forest.countOf[node.key] or 0) == 0 and not missedKinds[node.key] then return false end
        end
    end
    return needed > 0
end

-- Called when what was found changes. Alerts the first time this forest entry is complete.
function FullForestAlert.check()
    if alerted or not Forest.isInside then return end
    if not (Settings.flashOnFullForest or Settings.blockOnFullForest) then return end
    local kinds, _, _, missedKinds = Forest.scoutCounts()
    if not FullForestAlert.forestIsComplete(kinds, missedKinds) then return end
    alerted, ticks = true, 0
    Event.Logic.Subscribe(SUBSCRIPTION, onLogicTick)
    local pluginLayer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if Settings.blockOnFullForest then
        blocker = fullScreen(pluginLayer, BLOCKER_COLOUR, true)
        if FullForestAlert.onBlocked then FullForestAlert.onBlocked() end
    end
    if Settings.flashOnFullForest then
        flash = fullScreen(pluginLayer, FLASH_COLOUR, false)
        flash:MoveToFront()
    end
end

-- Re-arms the alert on entering a forest.
function FullForestAlert.reset()
    alerted = false
    FullForestAlert.stop()
end

-- Removes anything shown, on leaving or when the plugin stops.
function FullForestAlert.stop()
    removeFlash()
    FullForestAlert.unblock()
end

return FullForestAlert
