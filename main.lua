-- Nemi Mapper: An All in one Nemi forest plugin.

local Settings = require("src/data/settings")
local Forest = require("src/game/forest")
local ForestStops = require("src/game/forest_stops")
local ToolsHeld = require("src/game/tools_held")
local RouteChoice = require("src/game/route_choice")
local FinalRoute = require("src/game/final_route")
local WorldNumber = require("src/game/world_number")
local Highlights = require("src/game/highlights")
local MapWindow = require("src/ui/map_window")
local ScoutWindow = require("src/ui/scout_window")
local FullForestAlert = require("src/ui/full_forest_alert")
local SettingsPage = require("src/ui/settings_page")
local RibbonPage = require("src/ui/ribbon_page")
local Keybinds = require("src/ui/keybinds")

local PrettyUI = prettyui

local LOG_PREFIX = "[nemi_mapper] "

local function openWindow(open, ...)
    local opened, openError = pcall(function(...)
        open(PrettyUI, ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP), ...)
    end, ...)
    if not opened then print(LOG_PREFIX .. "a window could not open: " .. tostring(openError)) end
end

local function openMap()
    openWindow(MapWindow.open)
end

local function openScout()
    openWindow(ScoutWindow.open, openMap)
end

local function openSettings()
    openWindow(SettingsPage.openWindow)
end

-- Called when the 9/9 alert blocks the game: opens the scout window, rebuilt with its unblock button.
FullForestAlert.onBlocked = function()
    ScoutWindow.close()
    openScout()
end
FullForestAlert.onUnblocked = ScoutWindow.dropUnblockButton

Keybinds.onOpenMap = function()
    if MapWindow.isOpen() then MapWindow.close() else openMap() end
end

local function loadSettings()
    Settings.load()
    Keybinds.apply()
end
loadSettings()

-- Windows open before entering the forest stay open after leaving it, and the map shows as it did then: its legends'
-- windows alone, while the map was hidden by its X.
local shownBeforeEntering = { scout = false, map = nil }

-- The route chosen, worked out or cut back to the player (cutBack), goes to the world and the map. A change to the
-- forest or the tools held redraws both after it, the route with them (routeDrawnAfter), so each is drawn once.
local routeDrawnAfter = false
RouteChoice.onDrawn = function(cutBack)
    if routeDrawnAfter then return end
    Highlights.showChosen(RouteChoice.drawn, cutBack)
    MapWindow.showRoutes()
end

-- Shows a change in the tools held: the route follows them, then the map and the world's highlights.
local function showHeld()
    routeDrawnAfter = true
    RouteChoice.showHeld()
    routeDrawnAfter = false
    MapWindow.showHeld()
    Highlights.refreshWith(RouteChoice.drawn)
end

Forest.onEntered = function()
    FullForestAlert.reset()
    shownBeforeEntering.scout, shownBeforeEntering.map = ScoutWindow.isOpen(), MapWindow.shownState()
    if Settings.scoutOpensInForest then openScout() end
    if Settings.mapOpensInForest then openMap() end
    if Settings.routeStartsInForest then RouteChoice.startMappingAfterSearch() end
end

Forest.onLeft = function()
    FullForestAlert.stop()
    if not shownBeforeEntering.scout then ScoutWindow.close() end
    MapWindow.restore(shownBeforeEntering.map)
    RouteChoice.forget()
    FinalRoute.forget()
    ScoutWindow.showForest() -- the windows kept open, after those closing have saved their size as it was
    MapWindow.showForestLeft()
    Highlights.clear()
    ForestStops.forget()
    ToolsHeld.forget()
end
-- The tools held are worked out once per step, inventory change and forest change (ToolsHeld.refresh), and what
-- follows them is redrawn only when they change.
Forest.onChanged = function()
    local heldChanged = ToolsHeld.refresh()
    ScoutWindow.showForest()
    routeDrawnAfter = true
    RouteChoice.showForest(heldChanged)
    routeDrawnAfter = false
    MapWindow.showForest()
    Highlights.refreshWith(RouteChoice.drawn)
    FullForestAlert.check()
end
Forest.onMoved = function()
    MapWindow.showPlayer()
    if ToolsHeld.refresh() then return showHeld() end
    RouteChoice.showPlayer()
end
Forest.onMonstersChanged = ScoutWindow.showMonsters
Forest.onNpcMoved = function(entry)
    RouteChoice.showNpcMoved(entry)
    MapWindow.showNpcMoved(entry)
end

Forest.onInventoryChanged = function()
    ToolsHeld.update()
    if ToolsHeld.refresh() then showHeld() end
end

-- What each kind of setting's change refreshes (src/ui/settings_page.lua).
SettingsPage.onChange = {
    map = MapWindow.showSettings,
    header = MapWindow.showHeaderText,
    highlights = Highlights.refresh,
    scout = ScoutWindow.showSettings,
    routes = function() RouteChoice.onDrawn(false) end, -- they only draw the route
    sharing = function()
        -- A shared map shows the final route.
        -- A chosen route would replace it, and NAVIGATE's or SOLVE's would have no button left to turn it off.
        if Settings.mapSharingMode and RouteChoice.isChosen() then RouteChoice.clear() end
        -- The header shows the world, readable only while the friends list is loaded.
        if Settings.mapSharingMode then WorldNumber.read() end
        MapWindow.showSettings()
        ScoutWindow.showSettings()
    end,
}
-- The map's sharing button turns map sharing mode on or off, and the settings pages follow.
MapWindow.onSharingToggled = function() SettingsPage.change("mapSharingMode", not Settings.mapSharingMode) end

-- TEMPORARY (dev only): the probe logs the forest's data from the settings' debug buttons, each change the plugin
-- finds with its server tick, and the tiles walked; the cheats back two more buttons.
-- Unknown names are logged once.
local ForestProbe = require("src/debug/forest_probe")
local DevCheats = require("src/debug/dev_cheats")
ForestProbe.start()
local showChange, showStep = Forest.onChanged, Forest.onMoved
Forest.onChanged = function()
    ForestProbe.logChange()
    showChange()
end
Forest.onMoved = function()
    ForestProbe.noteStep()
    showStep()
end
SettingsPage.addExtras = function(view)
    view:AddDivider()
    view:AddSimpleButton("Debug: log the forest's data", ForestProbe.logForest)
    view:AddSimpleButton("Debug: log the world and minimap components", ForestProbe.logInterfaceComponents)
    view:AddSimpleButton("Debug: log the template square (stand in it)", ForestProbe.logTemplateSquare)
    view:AddSimpleButton("Debug: clear today's node claims (cheat)", DevCheats.clearClaims)
    view:AddSimpleButton("Debug: start or end a Trinks' task (cheat)", DevCheats.toggleTask)
end
for name in pairs(require("src/game/game_ids").unresolved) do print(LOG_PREFIX .. "UNRESOLVED|" .. name) end
WorldNumber.read()
Forest.start()

Event.ContentLayerReady.Subscribe("nemi_mapper_content", function(event)
    local built, buildError = pcall(RibbonPage.build, event.component,
        { openMap = openMap, openScout = openScout, openSettings = openSettings })
    if not built then print(LOG_PREFIX .. "the plugin page failed: " .. tostring(buildError)) end
end)

Event.SettingsLayerReady.Subscribe("nemi_mapper_settings", function(event)
    local built, buildError = pcall(SettingsPage.build, event.component)
    if not built then print(LOG_PREFIX .. "the settings page failed: " .. tostring(buildError)) end
end)

-- Stops what runs only in the game, on leaving it and at shutdown.
local function stopInGame()
    Forest.stop() -- leaving a forest stops its alert
    Highlights.clear()
    Keybinds.stop()
end

Event.GameStateChanged.Subscribe("nemi_mapper_state", function(event)
    if event.newState == GameState.SWITCH_WORLD then WorldNumber.forget() end
    if event.newState == GameState.LOBBY or event.newState == GameState.LOGINSCREEN then
        WorldNumber.forget()
        stopInGame()
        Settings.save()
    elseif event.newState == GameState.GAME
        and (event.oldState == GameState.LOBBY or event.oldState == GameState.LOGINSCREEN) then
        loadSettings()
        Forest.start()
    end
end)

function PluginShutdown()
    Event.ContentLayerReady.Unsubscribe("nemi_mapper_content")
    Event.SettingsLayerReady.Unsubscribe("nemi_mapper_settings")
    ForestProbe.stop()
    Event.GameStateChanged.Unsubscribe("nemi_mapper_state")
    stopInGame()
    MapWindow.close()
    ScoutWindow.close()
    SettingsPage.close()
    Settings.save()
    RibbonPage.close()
end
