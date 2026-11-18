-- Nemi Mapper: An All in one Nemi forest plugin.

local Settings = require("src/data/settings")
local Forest = require("src/game/forest")
local ForestStops = require("src/game/forest_stops")
local ToolsHeld = require("src/game/tools_held")
local WorldNumber = require("src/game/world_number")
local Highlights = require("src/game/highlights")
local MapWindow = require("src/ui/map_window")
local ScoutWindow = require("src/ui/scout_window")
local WindowPlace = require("src/ui/window_place")
local FullForestAlert = require("src/ui/full_forest_alert")
local StatusText = require("src/ui/status_text")
local Colours = require("src/ui/colours")
local ForestFeatures = require("src/data/forest_features")

local PrettyUI = prettyui

local LOG_PREFIX = "[nemi_mapper] "

local pageView, settingsView = nil, nil
local settingsWindow = nil
local openSettings, forgetControls 

-- Forgets the settings window once its interface is gone.
local function forgetClosedSettingsWindow()
    if settingsWindow ~= nil and ui.Interfaces:GetInterface(settingsWindow.interfaceID) == nil then
        forgetControls(settingsWindow)
        settingsWindow = nil
    end
end

local function isSettingsWindowOpen()
    forgetClosedSettingsWindow()
    return settingsWindow ~= nil
end

local function openWindow(open, ...)
    local opened, openError = pcall(function(...)
        open(PrettyUI, ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP), ...)
    end, ...)
    if not opened then print(LOG_PREFIX .. "a window could not open: " .. tostring(openError)) end
end

local function openMap()
    openWindow(MapWindow.open)
end

-- Opens the map hidden, for route guidance, which runs in the map window and needs it open.
local function openMapHidden()
    openWindow(MapWindow.open, true)
end

local function openScout()
    openWindow(ScoutWindow.open, openMap)
end

-- Called when the 9/9 alert blocks the game: opens the scout window with its unblock button.
FullForestAlert.onBlocked = function()
    openScout()
    ScoutWindow.showBlocking(true)
end
FullForestAlert.onUnblocked = function() ScoutWindow.showBlocking(false) end

-- The keybinds, unbound until the player binds them on the settings page. There is one, to open or close the map.
local KEYBIND_SUBSCRIPTION = "nemi_mapper_keybinds"
local keybindsListening = false
local function toggleMap()
    if MapWindow.isShown() then MapWindow.hideOrClose() else openMap() end
end
local keybinds = { -- by setting key: the GameKeys bound, in order, and what a press does
    keybindOpenMap = { keys = {}, onPress = toggleMap },
}
local MODIFIER_BITS = { -- a modifier key's bit in a key event's modifiers
    [GameKey.SHIFT] = ModifierKey.SHIFT, [GameKey.CONTROL] = ModifierKey.CONTROL, [GameKey.ALT] = ModifierKey.ALT,
}

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
    if event.isRepeat or PrettyUI.KeybindField.IsCapturing() then return end
    if not Keyboard.IsAvailable() or Keyboard.IsBlocked() then return end
    for _, keybind in pairs(keybinds) do
        if completes(keybind.keys, event) then return keybind.onPress() end
    end
end

local function setKeybindsListening(wanted)
    if wanted == keybindsListening then return end
    keybindsListening = wanted
    if wanted then
        Event.KeyDown.Subscribe(KEYBIND_SUBSCRIPTION, onKeyDown)
    else
        Event.KeyDown.Unsubscribe(KEYBIND_SUBSCRIPTION)
    end
end

-- Listens while any keybind is bound.
local function listenForKeybinds()
    local wanted = false
    for _, keybind in pairs(keybinds) do wanted = wanted or #keybind.keys > 0 end
    setKeybindsListening(wanted)
end

local function lookUpGameKey(name) return GameKey[name] end

-- Returns a saved binding's keys, in the format to save them.
local function keybindKeysOf(text)
    local keys, seen = {}, {}
    for name in text:gmatch("%S+") do
        local found, key = pcall(lookUpGameKey, name)
        if found and type(key) == "number" and key >= 0 and not seen[key] and #keys < 2 then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

-- Returns the keys as they are saved, by name and space-separated.
local function keybindTextOf(keys)
    local names = {}
    for index, key in ipairs(keys) do names[index] = GameKey.FromID(key) end
    return table.concat(names, " ")
end

-- Sets the keybinds from the settings, when loaded or restored, and listens if any is bound.
local function applyKeybinds()
    for setting, keybind in pairs(keybinds) do keybind.keys = keybindKeysOf(Settings[setting]) end
    listenForKeybinds()
end

local function loadSettings()
    Settings.load()
    applyKeybinds()
end
loadSettings()

-- On entering, route guidance starts after the forest's search ends
local guidanceWaiting = false
-- Windows open before entering the forest stay open after leaving it.
local openBeforeEntering = { scout = false, map = false }

Forest.onEntered = function()
    FullForestAlert.reset()
    openBeforeEntering.scout, openBeforeEntering.map = ScoutWindow.isOpen(), MapWindow.isOpen()
    if Settings.scoutOpensInForest then openScout() end
    if Settings.mapOpensInForest then
        openMap()
    elseif Settings.routeStartsInForest then
        openMapHidden()
    end
    guidanceWaiting = Settings.routeStartsInForest
end

Forest.onLeft = function()
    guidanceWaiting = false
    FullForestAlert.stop()
    if not openBeforeEntering.scout then ScoutWindow.close() end
    if not openBeforeEntering.map or not MapWindow.isShown() then MapWindow.close() end
    ScoutWindow.showForest() -- the windows kept open, after those closing have saved their size as it was
    MapWindow.showForestLeft()
    Highlights.clear()
    ForestStops.forget()
    ToolsHeld.forget()
end
Forest.onChanged = function()
    WorldNumber.read()
    ScoutWindow.showForest()
    MapWindow.showForest()
    Highlights.refresh()
    FullForestAlert.check()
    if guidanceWaiting and not Forest.isSearching then
        guidanceWaiting = false
        MapWindow.startMapping()
    end
end
Forest.onMoved = function()
    ToolsHeld.update(Forest.playerTile)
    MapWindow.showPlayer()
    Highlights.followPlayer()
end
Forest.onMonstersChanged = ScoutWindow.showMonsters
Forest.onNpcMoved = MapWindow.showNpcMoved

Forest.onInventoryChanged = function()
    ToolsHeld.update(Forest.playerTile)
    MapWindow.showInventory()
    Highlights.followPlayer()
end

Forest.start()

-- The plugin's two hub pages. The ribbon page and the settings page.
local SECTION_COLOUR = Colours.GOLD
local SECTION_FONT = require("src/game/game_ids").resolve("Font", "CINZEL_18PT_BOLD") or id.Font.CINZEL_13PT_BOLD
local SECTION_HEIGHT = 30 -- room for the 18pt heading
local PARAGRAPH_GAP = 18 -- a blank line between the settings' how-to paragraphs
local INDENT = 30 -- per level of sub-setting
local PAGE_PADDING = 14 -- PrettyUI's padding on each side
local COLUMN_GAP = 8 -- PrettyUI's gap before an inline control (the info icon)
local SCROLLBAR_WIDTH = 18 -- PrettyUI's scrollbar plus its gap
local WINDOW_EDGE_WIDTH = 16 -- a PrettyUI window is this much wider than its content
local SLIDER_LEAST_WIDTH = 160 -- narrower sliders are hard to set precisely
local ROW_GAP = 2 -- PrettyUI's default gap of 8 spreads the settings too far apart

local function mapChanged() MapWindow.showSettings() end
local function headerChanged() MapWindow.showHeaderText() end
local function sharingChanged()
    MapWindow.showSettings()
    ScoutWindow.showSettings()
end
local function highlightsChanged() Highlights.refresh() end
local function routesChanged() MapWindow.showRoutes() end
local function scoutChanged() ScoutWindow.showSettings() end
local settingRows = {
    { section = "General" },
    { key = "scoutOpensInForest", name = "Open the scout window automatically",
        info = "When you enter a forest. The scout window states the number and type of nodes found in the forest." },
    { key = "mapOpensInForest", name = "Open the map automatically",
        info = "When you enter a forest. The map shows its nodes, keys, doors and routes, and guides you to "
            .. "whatever you click on it." },
    { key = "routeStartsInForest", name = "Start navigation automatically",
        info = "When you enter a forest. Guides you to every unclaimed node, opening the doors in the way." },
    { section = "Map" },
    { key = "simplifiedLegends", name = "Simplified legends", onChange = mapChanged,
    info = "Only shows the node pictures, larger, without names or skill symbols." },
    { key = "hideUsedNodes", name = "Hide claimed nodes", onChange = mapChanged },
    { key = "hideNodes", name = "Hide unclaimed nodes too", under = "hideUsedNodes", onChange = mapChanged },
    { key = "hideTasks", name = "Hide Trinks' tasks while not on task", onChange = mapChanged,
    info = "Hide the Traitor and the Pahtli plant when they are not needed for your current task." },
    { key = "hideUnneededPuzzles", name = "Hide keys and doors you don't need", onChange = mapChanged,
    info = "Hide doors not on the way to any unclaimed node, and their keys." },
    { key = "hidePuzzleElements", name = "Hide all keys and doors", under = "hideUnneededPuzzles",
    onChange = mapChanged },
    { key = "hideEntranceSigns", name = "Hide the entrance signs", onChange = mapChanged,
    info = "Hide the OTOT and KANATAH signs at the forest's openings." },
    { key = "mapSharingMode", name = "Map sharing mode", onChange = sharingChanged,
        info = "Makes the map look like the maps shared by FC Nemi, with a header showing the world and node "
            .. "count, the full node legend, every node and the final route. Keys and doors, NAVIGATE, your "
            .. "position and what you have claimed today are hidden. It overrides any setting that disagrees." },
    { key = "headerText", text = true, name = "Header text in map sharing mode", onChange = headerChanged },
    { section = "Node legend" },
    { key = "hideNodeLegend", name = "Hide the node legend", onChange = mapChanged,
        info = "Hides the list of nodes and Trinks' tasks beside the map, with the NAVIGATE button." },
    { key = "popOutNodeLegend", name = "Separate node legend window", offWhen = "hideNodeLegend",
        onChange = mapChanged },
    { key = "hideTaskLegend", name = "Hide Trinks' tasks while not on task",
        offWhen = "hideNodeLegend", onChange = mapChanged,
        info = "Hides the rows for the Traitor and the Pahtli plant while you are not on their respective tasks." },
    { key = "hideClaimedLegend", name = "Hide claimed nodes", offWhen = "hideNodeLegend",
        onChange = mapChanged, info = "Hides rows for nodes you have claimed today." },
    { key = "hideAbsentMarks", name = "Hide the red highlight on unclaimed missing nodes",
        offWhen = "hideNodeLegend", onChange = mapChanged,
        info = "The rows for nodes missing from this forest are shaded red while unclaimed today." },
    { section = "Keys and doors" },
    { key = "hidePuzzleLegend", name = "Hide the puzzle legend", onChange = mapChanged,
        info = "The list of keys and doors under the map, with the SOLVE button." },
    { key = "popOutPuzzleLegend", name = "Separate puzzle legend window", offWhen = "hidePuzzleLegend",
        onChange = mapChanged },
    { key = "hideUnneededPairs", name = "Hide the ones you don't need", offWhen = "hidePuzzleLegend",
        onChange = mapChanged,
        info = "Hides puzzles whose door is missing, opened, or is not on the way to any unclaimed node." },
    { section = "Routes on the map" },
    { key = "hideFinalRoute", name = "Hide the final route", onChange = routesChanged,
        info = "A route from the entrance past every node to the exit ignoring doors, only shown while no route is "
            .. "chosen." },
    { key = "hideActiveRoute", name = "Hide the chosen route", onChange = routesChanged },
    { key = "alwaysShowTarget", name = "Always show the chosen route's stops on the map", onChange = mapChanged,
        info = "Every key, door, node or task the route will visit, even when another setting hides it." },
    { section = "Game world" },
    { key = "hideRouteInWorld", name = "Hide the chosen route on the ground", onChange = routesChanged },
    { key = "hideTargetBeam", name = "Hide the loot beam over the chosen route's target",
        onChange = highlightsChanged },
    { key = "highlightInWorld", name = "Draw 3D boxes", onChange = highlightsChanged,
        info = "Draws 3D boxes around whatever is ticked below." },
    { key = "highlightNodes", name = "Unclaimed nodes", under = "highlightInWorld",
        onChange = highlightsChanged },
    { key = "highlightUsedNodes", name = "Claimed nodes too", under = "highlightNodes", onChange = highlightsChanged },
    { key = "highlightTasks", name = "The current Trinks' task target", under = "highlightInWorld",
        info = "The Traitor or the Pahtli plant, while you are on their respective tasks.",
        onChange = highlightsChanged },
    { key = "highlightPuzzles", name = "Keys and doors you need", under = "highlightInWorld",
        onChange = highlightsChanged,
        info = "Doors on the way to an unclaimed node, and their keys. A door is boxed until opened, its key "
            .. "until you hold it." },
    { key = "highlightUnneededPuzzles", name = "The ones you don't need too", under = "highlightPuzzles",
        onChange = highlightsChanged, info = "Doors not on the way to any unclaimed node, and their keys." },
    { key = "highlightTarget", name = "The chosen route's stops", under = "highlightInWorld",
        onChange = highlightsChanged },
    { key = "highlightTransparency", name = "Box transparency", slider = true, under = "highlightInWorld",
        onChange = highlightsChanged },
    { section = "Scouting" },
    { key = "flashOnFullForest", name = "Flash the screen green on a 9/9 forest",
        info = "For 5 seconds, once all nine kinds of node are found." },
    { key = "blockOnFullForest", name = "Block game clicks on a 9/9 forest",
        info = "For 5 seconds, or until you press \"Unblock the game\" in the scout window. The keyboard still "
            .. "works." },
    { key = "alertOnNeededNodes", name = "Alert on every node you still need instead", onChange = scoutChanged,
        info = "Trigger alerts when the forest has every node you have not claimed today, rather than only when "
            .. "all 9 are present." },
    { section = "Keybinds" },
    { key = "keybindOpenMap", name = "Open or close the map", keybind = true },
}

local pageControls = {} -- setting key -> what shows it on whichever pages are built (see keepControl)

-- Shows a setting's value on every page that has it, after a change elsewhere (another page, the map's sharing
-- button or a restore).
local function showSetting(key, source)
    forgetClosedSettingsWindow()
    local controls = pageControls[key]
    if controls == nil then return end
    for _, kept in ipairs(controls) do
        if kept.control ~= source then kept.show() end
    end
end

local function rowOf(key)
    for _, row in ipairs(settingRows) do
        if row.key == key then return row end
    end
end

local function depthOf(row)
    local depth = 0
    while row.under ~= nil do
        depth, row = depth + 1, rowOf(row.under)
    end
    return depth
end

-- Returns the left edge of an indented sub-setting, or nil for a top-level one.
local function indentOf(row)
    return row.under ~= nil and PAGE_PADDING + depthOf(row) * INDENT or nil
end

-- Returns whether a setting can be changed: every setting above it is on and its offWhen setting is off.
local function isEnabled(row)
    if row.offWhen ~= nil and Settings[row.offWhen] then return false end
    while row.under ~= nil do
        if not Settings[row.under] then return false end
        row = rowOf(row.under)
    end
    return true
end

local function showsTicked(row)
    return Settings[row.key] and isEnabled(row)
end

local function showEnabledStates()
    forgetClosedSettingsWindow()
    for _, other in ipairs(settingRows) do
        local controls = pageControls[other.key]
        if controls ~= nil and (other.under ~= nil or other.offWhen ~= nil) then
            local disabled = not isEnabled(other)
            for _, kept in ipairs(controls) do
                kept.show()
                if kept.disabled ~= disabled then
                    kept.disabled = disabled
                    kept.setDisabled(disabled)
                end
            end
        end
    end
end

local function keepControl(view, row, control, show, setDisabled)
    local kept = {
        page = view, control = control, show = show, setDisabled = setDisabled, disabled = not isEnabled(row),
    }
    local controls = pageControls[row.key]
    if controls == nil then
        controls = {}
        pageControls[row.key] = controls
    end
    controls[#controls + 1] = kept
    return kept
end

local function changeSetting(row, value, source)
    Settings[row.key] = value
    showSetting(row.key, source)
    if row.onChange then row.onChange() end
end

-- Called when map sharing mode is turned on or off from the map window's title bar: the pages follow.
MapWindow.onSharingToggled = function() changeSetting(rowOf("mapSharingMode"), not Settings.mapSharingMode) end

local INFO_ICON_SIZE = 21 -- the game's info icon at its native size, which fits a checkbox row (22)

-- Adds a setting's info icon after its name, on the same line, showing text as a tooltip. A click on it does nothing.
local function addInfoIcon(view, text)
    view:AddSpriteButton("INFO", function() end, {
        inline = true, size = INFO_ICON_SIZE, tooltip = { text = text, maxWidth = 320 },
    })
end

-- Adds a slider row: the name and value above the slider, the info icon after the name.
local function addSlider(view, row)
    local number = Settings.numbers[row.key]
    local x = indentOf(row)
    local function labelText() return row.name .. ": " .. Settings[row.key] .. "%" end
    local labelShown = labelText()
    local label = view:AddText({ text = labelShown, x = x, marginBottom = 0 })
    local function showLabel()
        local text = labelText()
        if text ~= labelShown then
            labelShown = text
            label.content = text
        end
    end
    if row.info ~= nil then addInfoIcon(view, row.info) end
    local slider
    -- A slider is as wide as its row, so an indented one would overrun the right edge.
    -- Its width is anchored to the view's, less its indent, so it also follows a resize.
    slider = view:AddSlider({
        min = number.min, max = number.max, step = 1, value = Settings[row.key], x = x, marginBottom = ROW_GAP,
        width = x and -(x + PAGE_PADDING) or nil, widthAnchor = x and 1.0 or nil,
        disabled = not isEnabled(row),
        onChange = function(_, value)
            changeSetting(row, value, slider)
            showLabel()
        end,
    })
    local kept = keepControl(view, row, slider, function()
        slider:SetValue(Settings[row.key], false)
        showLabel()
    end, function(disabled) slider:SetDisabled(disabled) end)
    -- Re-places the thumb for the track's current width by silently setting the value away and back.
    function kept.relayout()
        local value = Settings[row.key]
        slider:SetValue(value == number.min and number.max or number.min, false)
        slider:SetValue(value, false)
    end
end

-- A text setting's row has the name and info on one line and the field under them.
local TEXT_FIELD_WIDTH = 240
local TEXT_LONGEST = 40 -- the most characters a text setting holds
local function addTextRow(view, row)
    view:AddText({ text = row.name, marginBottom = 0 })
    if row.info ~= nil then addInfoIcon(view, row.info) end
    local field
    field = view:AddTextField({
        text = Settings[row.key], width = TEXT_FIELD_WIDTH, marginBottom = ROW_GAP, maxLength = TEXT_LONGEST,
        onChange = function(_, _, text) changeSetting(row, text, field) end,
    })
    keepControl(view, row, field, function() field:SetText(Settings[row.key], false) end)
end

local KEYBIND_LABEL_WIDTH, KEYBIND_FIELD_WIDTH = 220, 160
local function addKeybindRow(view, row)
    local keybind = keybinds[row.key]
    view:AddText({ text = row.name, width = KEYBIND_LABEL_WIDTH, marginBottom = ROW_GAP })
    if row.info ~= nil then addInfoIcon(view, row.info) end
    local field
    field = view:AddKeybindField({
        value = keybind.keys, defaultValue = {}, inline = true, width = KEYBIND_FIELD_WIDTH, marginBottom = ROW_GAP,
        onChange = function(_, keys)
            keybind.keys = keys
            listenForKeybinds()
            changeSetting(row, keybindTextOf(keys), field)
        end,
    })
    keepControl(view, row, field, function() field:SetValue(keybind.keys, false) end)
end

-- Adds a setting's row: a checkbox, or the row's slider, text or keybind control.
local function addSetting(view, row)
    if row.slider then return addSlider(view, row) end
    if row.text then return addTextRow(view, row) end
    if row.keybind then return addKeybindRow(view, row) end
    local choices = { { text = row.name, value = row.key, selected = showsTicked(row) } }
    local checkbox
    checkbox = view:AddCheckboxButton(choices, {
        width = PrettyUI.CheckboxButton.getSize(choices), marginBottom = ROW_GAP,
        x = indentOf(row), disabled = not isEnabled(row),
        tickCursor = config.Cursor.CURSOR_BLANK, crossCursor = config.Cursor.CURSOR_BLANK,
        onChange = function(_, _, _, selected)
            changeSetting(row, selected, checkbox)
            showEnabledStates() -- the settings under this one, or off while it is on
        end,
    })
    keepControl(view, row, checkbox, function() checkbox:SetSelected(row.key, showsTicked(row), false) end,
        function(disabled) checkbox:SetDisabled(disabled) end)
    if row.info ~= nil then addInfoIcon(view, row.info) end
end

local function newView(pluginLayer, layout)
    return PrettyUI.SimpleView.new(pluginLayer, {
        width = pluginLayer.width, height = pluginLayer.height, scrollable = true, layout = layout,
    })
end

-- Forgets the controls of a page or window that is gone; other pages keep theirs.
forgetControls = function(view)
    for key, controls in pairs(pageControls) do
        for index = #controls, 1, -1 do
            if controls[index].page == view then table.remove(controls, index) end
        end
        if #controls == 0 then pageControls[key] = nil end
    end
end

local function closeView(view)
    if view ~= nil then
        forgetControls(view)
        pcall(function() view:Destroy() end)
    end
    return nil
end

-- The day's status on the ribbon page
local DAILY_COMPLETE_COLOUR, DAILY_INCOMPLETE_COLOUR = Colours.GREEN, Colours.GOLD
local UNCLAIMED_COLOUR = Colours.RED | 0xFF
local DAILY_LINE_HEIGHT = 22
-- The hub's page is narrow, so the ribbon page keeps PrettyUI's padding small and indents nothing.
local PAGE_LAYOUT = { paddingLeft = 4, paddingRight = 4, startY = 6 }
local PAGE_TEXT_FONT = id.Font.MUSEO_SANS_15PT_REGULAR -- PrettyUI's text font
-- Returns the width of a node name's column on the ribbon page: the widest name, measured, plus a gap.
local function nodeColumnWidth()
    local font, widest = config.Font.FromID(PAGE_TEXT_FONT), 0
    for _, node in ipairs(ForestFeatures.nodesInRotation) do
        widest = math.max(widest, font:GetStringWidth(node.name))
    end
    return widest + 8
end
local pageStatus = nil -- the page's status lines while the page exists, by name (a node's is its key)

-- Returns a task's progress, each part as counted: "Airut 2/5, freed 1/5".
local function progressText(task)
    local parts = {}
    for index, part in ipairs(task.parts) do parts[index] = part.what .. " " .. part.count .. "/" .. part.of end
    return table.concat(parts, ", ")
end

local function showDailyStatus()
    local claimed, nodes = Forest.readClaimedToday(), #ForestFeatures.nodes
    StatusText.set(pageStatus.nodes, "Nodes claimed: " .. claimed .. "/" .. nodes,
        claimed >= nodes and DAILY_COMPLETE_COLOUR or DAILY_INCOMPLETE_COLOUR)
    for _, node in ipairs(ForestFeatures.nodesInRotation) do
        StatusText.set(pageStatus[node.key], node.name,
            Forest.isNodeClaimed(node.key) and DAILY_COMPLETE_COLOUR or UNCLAIMED_COLOUR)
    end
    local done, tasksADay = Forest.tasksDoneToday(), ForestFeatures.tasksADay
    StatusText.set(pageStatus.tasks, "Trinks' tasks: " .. done .. "/" .. tasksADay,
        done >= tasksADay and DAILY_COMPLETE_COLOUR or DAILY_INCOMPLETE_COLOUR)
    local task = Forest.currentTask()
    StatusText.set(pageStatus.task, "Task: " .. (task and (task.name .. (task.done and " (done)" or "")) or "none"))
    StatusText.set(pageStatus.progress, task and not task.done and progressText(task) or "")
end

local DAILY_SUBSCRIPTION = "nemi_mapper_daily"
local function onInventoryUpdated(event)
    if event.inv.id == config.Inv.INV.id then showDailyStatus() end
end
local function followBackpack()
    if pageStatus ~= nil and Forest.taskCountsItems() then
        Event.InventoryUpdated.Subscribe(DAILY_SUBSCRIPTION, onInventoryUpdated)
    else
        Event.InventoryUpdated.Unsubscribe(DAILY_SUBSCRIPTION)
    end
end
local function onDailyVariable(event)
    local claimsBase, questBase, tasksDoneBase = Forest.dailyVariableIDs()
    local sent = event.var.id
    if sent == questBase then followBackpack() end
    if sent == claimsBase or sent == questBase or sent == tasksDoneBase then showDailyStatus() end
end

local function buildPage(pluginLayer)
    pageView = newView(pluginLayer, PAGE_LAYOUT)
    pageView:AddTitle("Nemi Mapper")
    pageView:AddText("A window open before you enter the forest stays open after you leave it.")
    pageView:AddSimpleButton("Open the map", openMap)
    pageView:AddSimpleButton("Open the scout window", openScout)
    pageView:AddSimpleButton("Open the settings", openSettings)
    pageStatus = {}
    local function addStatusLine(name, options)
        options.text, options.height, options.maxLines = "", DAILY_LINE_HEIGHT, 1
        if options.marginBottom == nil then options.marginBottom = 0 end
        pageStatus[name] = StatusText.new(pageView:AddText(options))
    end
    addStatusLine("nodes", { marginTop = 8 })
    -- The nodes go two to a row while the page is wide enough, one a row when not.
    -- The first of a row starts a line and the second follows it inline.
    local columnWidth = nodeColumnWidth()
    local pageWidth = pluginLayer.width - PAGE_LAYOUT.paddingLeft - PAGE_LAYOUT.paddingRight
    local twoColumns = pageWidth >= columnWidth * 2 + COLUMN_GAP
    for index, node in ipairs(ForestFeatures.nodesInRotation) do
        addStatusLine(node.key, { inline = twoColumns and index % 2 == 0, width = columnWidth })
    end
    addStatusLine("tasks", { marginTop = 8 })
    addStatusLine("task", {})
    addStatusLine("progress", {})
    showDailyStatus()
    Event.VarTransmit.Subscribe(DAILY_SUBSCRIPTION, onDailyVariable)
    followBackpack()
end

local function closePage()
    if pageStatus ~= nil then
        Event.VarTransmit.Unsubscribe(DAILY_SUBSCRIPTION)
        Event.InventoryUpdated.Unsubscribe(DAILY_SUBSCRIPTION)
    end
    pageView, pageStatus = closeView(pageView), nil
end

-- Restores every setting's default, shows it on every page and applies it to the windows and highlights.
local function resetSettings()
    Settings.reset()
    applyKeybinds()
    for _, row in ipairs(settingRows) do
        if row.key ~= nil then showSetting(row.key) end
    end
    showEnabledStates()
    MapWindow.showSettings()
    ScoutWindow.showSettings()
    Highlights.refresh()
end

local RESTORE_TEXT = "Restore the default settings"
local BUTTON_EXTRA_WIDTH = 16 

local function addRestoreButton(view)
    local width = PrettyUI.SimpleButton.getSize(RESTORE_TEXT) + BUTTON_EXTRA_WIDTH
    view:AddSimpleButton(RESTORE_TEXT, resetSettings,
        { x = -math.floor(width / 2), xAnchor = 0.5, width = width, marginTop = 16 })
end

-- Adds every setting to the hub's settings page or the settings window
local function addAllSettings(view)
    view:AddText("In a Nemi Forest, the scout window quickly identifies the nodes present in the forest and the map "
        .. "shows the nodes, keys and doors. Click anything on the map or in its legends to be guided to it.")
    view:AddText({ text = "NAVIGATE guides you to every node you have not claimed today, taking the keys and opening "
        .. "the doors in the way. SOLVE guides you through every key and door to open the forest fully.",
        marginTop = PARAGRAPH_GAP })
    for _, row in ipairs(settingRows) do
        if row.section ~= nil then
            view:AddText({ text = row.section, colour = SECTION_COLOUR, font = SECTION_FONT, height = SECTION_HEIGHT,
                marginBottom = ROW_GAP, marginTop = 8 })
        else
            addSetting(view, row)
        end
    end
    addRestoreButton(view)
end

local function buildSettingsPage(pluginLayer)
    settingsView = newView(pluginLayer) -- the hub shows the title
    addAllSettings(settingsView)
end

-- PrettyUI places a slider's thumb only when its value is set, so after a resize the thumb no longer matches the
-- value. After each resize step the window's sliders are set again for SLIDER_LAYOUT_FRAMES frames, by when the
-- anchored tracks have their new width; Draw is subscribed only for those frames.
-- Fixed in prettyUI 1.4.0, so this can go when that is released.
local SLIDER_LAYOUT_SUBSCRIPTION = "nemi_mapper_slider_layout"
local SLIDER_LAYOUT_FRAMES = 2
local sliderLayoutFramesLeft = 0
local function stopLayingOutSliders()
    if sliderLayoutFramesLeft <= 0 then return end
    sliderLayoutFramesLeft = 0
    Event.Draw.Unsubscribe(SLIDER_LAYOUT_SUBSCRIPTION)
end
local function layOutSliders()
    sliderLayoutFramesLeft = sliderLayoutFramesLeft - 1
    if sliderLayoutFramesLeft <= 0 then Event.Draw.Unsubscribe(SLIDER_LAYOUT_SUBSCRIPTION) end
    if not isSettingsWindowOpen() then return stopLayingOutSliders() end
    for _, controls in pairs(pageControls) do
        for _, kept in ipairs(controls) do
            if kept.relayout ~= nil and kept.page == settingsWindow then kept.relayout() end
        end
    end
end
local function layOutSlidersSoon()
    if sliderLayoutFramesLeft <= 0 then Event.Draw.Subscribe(SLIDER_LAYOUT_SUBSCRIPTION, layOutSliders) end
    sliderLayoutFramesLeft = SLIDER_LAYOUT_FRAMES
end

-- Saves the window's position and size and forgets its controls, however it closes.
local function releaseSettingsWindow()
    stopLayingOutSliders()
    WindowPlace.remember(settingsWindow.root, "settings")
    forgetControls(settingsWindow)
    settingsWindow = nil
end

local function settingsWidthNeeded()
    local widest = 0
    for _, row in ipairs(settingRows) do
        if row.section == nil then
            local left = PAGE_PADDING + depthOf(row) * INDENT
            local width = row.slider and SLIDER_LEAST_WIDTH or row.text and TEXT_FIELD_WIDTH
                or row.keybind and KEYBIND_LABEL_WIDTH + COLUMN_GAP + KEYBIND_FIELD_WIDTH
                    + (row.info ~= nil and COLUMN_GAP + INFO_ICON_SIZE or 0)
                or PrettyUI.CheckboxButton.getSize({ { text = row.name, value = row.key } })
                + (row.info ~= nil and COLUMN_GAP + INFO_ICON_SIZE or 0)
            widest = math.max(widest, left + width)
        end
    end
    return widest + PAGE_PADDING + SCROLLBAR_WIDTH + WINDOW_EDGE_WIDTH
end

-- A plugin cannot open its own settings page in the hub, so the ribbon page's button opens the same settings in a
-- window.
local SETTINGS_WINDOW_WIDTH, SETTINGS_WINDOW_HEIGHT = 480, 640
local SETTINGS_WINDOW_MINIMUM_HEIGHT = 200 -- the minimum width comes from settingsWidthNeeded
openSettings = function()
    if isSettingsWindowOpen() then return settingsWindow:Show() end
    openWindow(function(_, pluginLayer)
        local minimumWidth = settingsWidthNeeded()
        local width = math.max(minimumWidth, Settings.settingsWidth or SETTINGS_WINDOW_WIDTH)
        width = math.min(width, pluginLayer.width)
        local height = math.min(Settings.settingsHeight or SETTINGS_WINDOW_HEIGHT, pluginLayer.height)
        local x, y = WindowPlace.position(pluginLayer, width, height, Settings.settingsX, Settings.settingsY)
        settingsWindow = PrettyUI.Window.new(pluginLayer, {
            title = "Nemi Mapper settings", x = x, y = y, width = width, height = height, scrollable = true,
            resizable = true, minWidth = minimumWidth, minHeight = SETTINGS_WINDOW_MINIMUM_HEIGHT,
            destroyOnClose = true, onClose = releaseSettingsWindow, -- its X button destroys it
        })
        addAllSettings(settingsWindow)
        -- PrettyUI's resize handle calls SetSize on every step of a drag.
        local setWindowSize = settingsWindow.SetSize
        settingsWindow.SetSize = function(resizedWindow, newWidth, newHeight)
            setWindowSize(resizedWindow, newWidth, newHeight)
            layOutSlidersSoon()
        end
    end)
end

local function closeSettingsWindow()
    if not isSettingsWindowOpen() then return end
    local window = settingsWindow
    releaseSettingsWindow()
    window:Destroy()
end

Event.ContentLayerReady.Subscribe("nemi_mapper_content", function(event)
    closePage()
    local built, buildError = pcall(buildPage, event.component)
    if not built then
        pageStatus = nil -- the page's variables are followed only once it is whole
        print(LOG_PREFIX .. "the plugin page failed: " .. tostring(buildError))
    end
end)

Event.SettingsLayerReady.Subscribe("nemi_mapper_settings", function(event)
    settingsView = closeView(settingsView)
    local built, buildError = pcall(buildSettingsPage, event.component)
    if not built then print(LOG_PREFIX .. "the settings page failed: " .. tostring(buildError)) end
end)

Event.GameStateChanged.Subscribe("nemi_mapper_state", function(event)
    if event.newState == GameState.SWITCH_WORLD then WorldNumber.forget() end
    if event.newState == GameState.LOBBY or event.newState == GameState.LOGINSCREEN then
        WorldNumber.forget()
        Forest.stop()
        FullForestAlert.stop()
        Highlights.clear()
        setKeybindsListening(false)
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
    Event.GameStateChanged.Unsubscribe("nemi_mapper_state")
    setKeybindsListening(false)
    Forest.stop()
    FullForestAlert.stop()
    Highlights.clear()
    MapWindow.close()
    ScoutWindow.close()
    closeSettingsWindow()
    Settings.save()
    closePage()
    settingsView = closeView(settingsView)
end
