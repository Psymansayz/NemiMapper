-- The settings: the hub's settings page and the same settings in a window, opened from the ribbon page as a plugin
-- cannot open its own settings page in the hub. Each control shows its setting's value on every page that has it.

local Settings = require("src/data/settings")
local Keybinds = require("src/ui/keybinds")
local WindowPlace = require("src/ui/window_place")
local StatusText = require("src/ui/status_text")

local SettingsPage = {}

local SECTION_COLOUR = StatusText.GOLD
local SECTION_FONT = id.Font.CINZEL_18PT_BOLD
local SECTION_HEIGHT = 30 -- room for the 18pt heading
local PARAGRAPH_GAP = 18 -- a blank line between the settings' how-to paragraphs
local INDENT = 30 -- per level of sub-setting
local PAGE_PADDING = 14 -- PrettyUI's padding on each side
local COLUMN_GAP = 8 -- PrettyUI's gap before an inline control (the info icon)
local SCROLLBAR_WIDTH = 18 -- PrettyUI's scrollbar plus its gap
local SLIDER_LEAST_WIDTH = 160 -- narrower sliders are hard to set precisely
local ROW_GAP = 2 -- PrettyUI's default gap of 8 spreads the settings too far apart

-- What each kind of setting's change refreshes, by the rows' onChange names (main.lua); each is called with nothing.
SettingsPage.onChange = {}
SettingsPage.addExtras = nil -- called with each view after its settings, for more buttons (main.lua)

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
    { key = "simplifiedLegends", name = "Simplified legends", onChange = "map",
    info = "Only shows the node pictures, larger, without names or skill symbols." },
    { key = "hideUsedNodes", name = "Hide claimed nodes", onChange = "map" },
    { key = "hideNodes", name = "Hide unclaimed nodes too", onChange = "map" },
    { key = "hideTasks", name = "Hide Trinks' tasks while not on task", onChange = "map",
    info = "Hide the Traitor and the Pahtli plant when they are not needed for your current task." },
    { key = "hideUnneededPuzzles", name = "Hide keys and doors you don't need", onChange = "map",
    info = "Hide doors not on the way to any unclaimed node, and their keys." },
    { key = "hidePuzzleElements", name = "Hide all keys and doors", onChange = "map" },
    { key = "hideEntranceSigns", name = "Hide the entrance signs", onChange = "map",
    info = "Hide the OTOT and KANATAH signs at the forest's openings." },
    { key = "mapSharingMode", name = "Map sharing mode", onChange = "sharing",
        info = "Makes the map look like the maps shared by FC Nemi, with a header showing the world and node "
            .. "count, the full node legend, every node and the final route. Keys and doors, NAVIGATE, your "
            .. "position and what you have claimed today are hidden. It overrides any setting that disagrees." },
    { key = "headerText", text = true, name = "Header text in map sharing mode", onChange = "header" },
    { section = "Node legend" },
    { key = "hideNodeLegend", name = "Hide the node legend", onChange = "map",
        info = "Hides the list of nodes and Trinks' tasks beside the map, with the NAVIGATE button." },
    { key = "popOutNodeLegend", name = "Separate node legend window", onChange = "map" },
    { key = "hideTaskLegend", name = "Hide Trinks' tasks while not on task", onChange = "map",
        info = "Hides the rows for the Traitor and the Pahtli plant while you are not on their respective tasks." },
    { key = "hideClaimedLegend", name = "Hide claimed nodes", onChange = "map",
        info = "Hides rows for nodes you have claimed today." },
    { key = "hideAbsentMarks", name = "Hide the red highlight on unclaimed missing nodes", onChange = "map",
        info = "The rows for nodes missing from this forest are shaded red while unclaimed today." },
    { section = "Keys and doors" },
    { key = "hidePuzzleLegend", name = "Hide the puzzle legend", onChange = "map",
        info = "The list of keys and doors under the map, with the SOLVE button." },
    { key = "popOutPuzzleLegend", name = "Separate puzzle legend window", onChange = "map" },
    { key = "hideUnneededPairs", name = "Hide the ones you don't need", onChange = "map",
        info = "Hides puzzles whose door is missing, opened, or is not on the way to any unclaimed node." },
    { section = "Routes on the map" },
    { key = "hideFinalRoute", name = "Hide the final route", onChange = "routes",
        info = "A route from the entrance past every node to the exit ignoring doors, only shown while no route is "
            .. "chosen." },
    { key = "hideActiveRoute", name = "Hide the chosen route", onChange = "routes" },
    { key = "alwaysShowTarget", name = "Always show the chosen route's stops on the map", onChange = "map",
        info = "Every key, door, node or task the route will visit, even when another setting hides it." },
    { section = "Game world" },
    { key = "hideRouteInWorld", name = "Hide the chosen route on the ground", onChange = "routes" },
    { key = "hideTargetBeam", name = "Hide the loot beam over the chosen route's target", onChange = "highlights" },
    { key = "highlightInWorld", name = "Draw 3D boxes", onChange = "highlights",
        info = "Draws 3D boxes around whatever is ticked below." },
    { key = "highlightNodes", name = "Unclaimed nodes", onChange = "highlights" },
    { key = "highlightUsedNodes", name = "Claimed nodes too", onChange = "highlights" },
    { key = "highlightTasks", name = "The current Trinks' task target", onChange = "highlights",
        info = "The Traitor or the Pahtli plant, while you are on their respective tasks." },
    { key = "highlightPuzzles", name = "Keys and doors you need", onChange = "highlights",
        info = "Doors on the way to an unclaimed node, and their keys. A door is boxed until opened, its key "
            .. "until you hold it." },
    { key = "highlightUnneededPuzzles", name = "The ones you don't need too", onChange = "highlights",
        info = "Doors not on the way to any unclaimed node, and their keys." },
    { key = "highlightTarget", name = "The chosen route's stops", onChange = "highlights" },
    { key = "highlightTransparency", name = "Box transparency", slider = true, onChange = "highlights" },
    { section = "Scouting" },
    { key = "flashOnFullForest", name = "Flash the screen green on a 9/9 forest",
        info = "For 5 seconds, once all nine kinds of node are found." },
    { key = "blockOnFullForest", name = "Block game clicks on a 9/9 forest",
        info = "For 5 seconds, or until you press \"Unblock the game\" in the scout window. The keyboard still "
            .. "works." },
    { key = "alertOnNeededNodes", name = "Alert on every node you still need instead", onChange = "scout",
        info = "Trigger alerts when the forest has every node you have not claimed today, rather than only when "
            .. "all 9 are present." },
    { section = "Node colors" },
    { key = "prayerColour", name = "Prayer", colour = true, onChange = "colours" },
    { key = "farmingColour", name = "Farming", colour = true, onChange = "colours" },
    { key = "miningColour", name = "Mining", colour = true, onChange = "colours" },
    { key = "dungeoneeringColour", name = "Dungeoneering", colour = true, onChange = "colours" },
    { key = "tasksColour", name = "Trinks' tasks", colour = true, onChange = "colours" },
    { section = "Keybinds" },
    { key = "keybindOpenMap", name = "Open or close the map", keybind = true },
}

-- Each row by its setting's key, and each row's depth under the top-level settings (Settings.under).
local rowOf = {}
for _, row in ipairs(settingRows) do
    if row.key ~= nil then
        rowOf[row.key] = row
        local parent = Settings.under[row.key]
        row.depth = parent ~= nil and rowOf[parent].depth + 1 or 0
    end
end

local settingsView, settingsWindow = nil, nil
local controlsOf = {} -- page or window -> setting key -> what shows the setting there (see keepControl)

-- Forgets the settings window once its interface is gone.
local function forgetClosedSettingsWindow()
    if settingsWindow ~= nil and ui.Interfaces:GetInterface(settingsWindow.interfaceID) == nil then
        controlsOf[settingsWindow] = nil
        settingsWindow = nil
    end
end

local function isSettingsWindowOpen()
    forgetClosedSettingsWindow()
    return settingsWindow ~= nil
end

-- Shows a setting's value on every page that has it, after a change elsewhere (another page, the map's sharing
-- button or a restore).
local function showSetting(key, source)
    forgetClosedSettingsWindow()
    for _, controls in pairs(controlsOf) do
        local kept = controls[key]
        if kept ~= nil and kept.control ~= source then kept.show() end
    end
end

-- Returns the left edge of an indented sub-setting, or nil for a top-level one.
local function indentOf(row)
    return row.depth > 0 and PAGE_PADDING + row.depth * INDENT or nil
end

local function showsTicked(row)
    return Settings.effective(row.key)
end

local function showEnabledStates()
    forgetClosedSettingsWindow()
    for _, row in ipairs(settingRows) do
        if row.key ~= nil and (Settings.under[row.key] ~= nil or Settings.offWhen[row.key] ~= nil) then
            local disabled = not Settings.isEnabled(row.key)
            for _, controls in pairs(controlsOf) do
                local kept = controls[row.key]
                if kept ~= nil then
                    kept.show()
                    if kept.disabled ~= disabled then
                        kept.disabled = disabled
                        kept.setDisabled(disabled)
                    end
                end
            end
        end
    end
end

local function keepControl(view, row, control, show, setDisabled)
    local kept = { control = control, show = show, setDisabled = setDisabled,
        disabled = not Settings.isEnabled(row.key) }
    controlsOf[view] = controlsOf[view] or {}
    controlsOf[view][row.key] = kept
    return kept
end

local function changeSetting(row, value, source)
    Settings[row.key] = value
    showSetting(row.key, source)
    if row.onChange then SettingsPage.onChange[row.onChange]() end
end

-- Changes a setting from elsewhere (the map's sharing button): the pages follow.
function SettingsPage.change(key, value)
    changeSetting(rowOf[key], value)
end

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
    local label = StatusText.new(view:AddText({ text = "", x = x, marginBottom = 0 }))
    local function showLabel() StatusText.set(label, row.name .. ": " .. Settings[row.key] .. "%") end
    showLabel()
    if row.info ~= nil then addInfoIcon(view, row.info) end
    local slider
    -- A slider is as wide as its row, so an indented one would overrun the right edge.
    -- Its width is anchored to the view's, less its indent, so it also follows a resize.
    slider = view:AddSlider({
        min = number.min, max = number.max, step = 1, value = Settings[row.key], x = x, marginBottom = ROW_GAP,
        width = x and -(x + PAGE_PADDING) or nil, widthAnchor = x and 1.0 or nil,
        disabled = not Settings.isEnabled(row.key),
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
        onChange = function(_, _, text)
            local plain = Settings.withoutTags(text)
            if plain ~= text then field:SetText(plain, false) end
            changeSetting(row, plain, field)
        end,
    })
    keepControl(view, row, field, function() field:SetText(Settings[row.key], false) end)
end

-- A keybind or colour row has its name in a column of this width, its control after it on the same line.
local LABEL_WIDTH = 220
local KEYBIND_FIELD_WIDTH = 160
local function addKeybindRow(view, row)
    view:AddText({ text = row.name, width = LABEL_WIDTH, marginBottom = ROW_GAP })
    if row.info ~= nil then addInfoIcon(view, row.info) end
    local field
    field = view:AddKeybindField({
        value = Keybinds.openMapKeys, defaultValue = {}, inline = true, width = KEYBIND_FIELD_WIDTH,
        marginBottom = ROW_GAP,
        onChange = function(_, keys) changeSetting(row, Keybinds.bind(keys), field) end,
    })
    keepControl(view, row, field, function() field:SetValue(Keybinds.openMapKeys, false) end)
end

-- A colour row's swatch opens PrettyUI's colour picker, and its Accept sets the colour.
local COLOUR_SWATCH_SIZE = 24 -- PrettyUI's default
local function addColourRow(view, row)
    view:AddText({ text = row.name, width = LABEL_WIDTH, marginBottom = ROW_GAP })
    local picker
    picker = view:AddColourPicker({
        value = Settings[row.key], inline = true, size = COLOUR_SWATCH_SIZE, marginBottom = ROW_GAP,
        windowTitle = row.name .. " colour",
        onChange = function(_, colour) changeSetting(row, colour, picker) end,
    })
    keepControl(view, row, picker, function() picker:SetValue(Settings[row.key], false) end)
end

-- Adds a setting's row: a checkbox, or the row's slider, text, keybind or colour control.
local function addSetting(view, row)
    if row.slider then return addSlider(view, row) end
    if row.text then return addTextRow(view, row) end
    if row.keybind then return addKeybindRow(view, row) end
    if row.colour then return addColourRow(view, row) end
    local choices = { { text = row.name, value = row.key, selected = showsTicked(row) } }
    local checkbox
    checkbox = view:AddCheckboxButton(choices, {
        width = prettyui.CheckboxButton.getSize(choices), marginBottom = ROW_GAP,
        x = indentOf(row), disabled = not Settings.isEnabled(row.key),
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

-- Restores every setting's default, shows it on every page and applies it to the windows and highlights.
local function resetSettings()
    Settings.reset()
    Keybinds.apply()
    for _, row in ipairs(settingRows) do
        if row.key ~= nil then showSetting(row.key) end
    end
    showEnabledStates()
    SettingsPage.onChange.sharing()
    -- the colours' change also redraws the route and the highlights
    SettingsPage.onChange.colours()
end

local RESTORE_TEXT = "Restore the default settings"
local BUTTON_EXTRA_WIDTH = 16

-- Adds every setting to the hub's settings page or the settings window.
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
    local restoreWidth = prettyui.SimpleButton.getSize(RESTORE_TEXT) + BUTTON_EXTRA_WIDTH
    view:AddSimpleButton(RESTORE_TEXT, resetSettings,
        { x = -math.floor(restoreWidth / 2), xAnchor = 0.5, width = restoreWidth, marginTop = 16 })
    if SettingsPage.addExtras ~= nil then SettingsPage.addExtras(view) end
end

local function closeView(view)
    if view ~= nil then
        controlsOf[view] = nil
        pcall(function() view:Destroy() end)
    end
    return nil
end

-- Builds the hub's settings page on its layer, replacing the last one built.
function SettingsPage.build(pluginLayer)
    settingsView = closeView(settingsView)
    -- the hub shows the title
    settingsView = prettyui.SimpleView.new(pluginLayer, {
        categoryID = "auto", width = pluginLayer.width, height = pluginLayer.height, scrollable = true,
    })
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
    for _, kept in pairs(controlsOf[settingsWindow]) do
        if kept.relayout ~= nil then kept.relayout() end
    end
end

-- Saves the window's position and size and forgets its controls, however it closes.
local function releaseSettingsWindow()
    stopLayingOutSliders()
    WindowPlace.remember(settingsWindow.root, "settings")
    controlsOf[settingsWindow] = nil
    settingsWindow = nil
end

local function settingsWidthNeeded()
    local widest = 0
    for _, row in ipairs(settingRows) do
        if row.section == nil then
            local width
            if row.slider then
                width = SLIDER_LEAST_WIDTH
            elseif row.text then
                width = TEXT_FIELD_WIDTH
            elseif row.colour then
                width = LABEL_WIDTH + COLUMN_GAP + COLOUR_SWATCH_SIZE
            else
                width = row.keybind and LABEL_WIDTH + COLUMN_GAP + KEYBIND_FIELD_WIDTH
                    or prettyui.CheckboxButton.getSize({ { text = row.name, value = row.key } })
                if row.info ~= nil then width = width + COLUMN_GAP + INFO_ICON_SIZE end
            end
            widest = math.max(widest, PAGE_PADDING + row.depth * INDENT + width)
        end
    end
    return widest + PAGE_PADDING + SCROLLBAR_WIDTH + WindowPlace.EDGE_WIDTH
end

local SETTINGS_WINDOW_WIDTH, SETTINGS_WINDOW_HEIGHT = 480, 640
local SETTINGS_WINDOW_MINIMUM_HEIGHT = 200 -- the minimum width comes from settingsWidthNeeded

-- Opens the settings window, or brings it to the front if open.
function SettingsPage.openWindow(PrettyUI, pluginLayer)
    if isSettingsWindowOpen() then return settingsWindow:Show() end
    local minimumWidth = settingsWidthNeeded()
    local x, y, width, height = WindowPlace.restore(pluginLayer, "settings", SETTINGS_WINDOW_WIDTH,
        SETTINGS_WINDOW_HEIGHT, minimumWidth)
    settingsWindow = PrettyUI.Window.new(pluginLayer, {
        categoryID = "auto", title = "Nemi Mapper settings", x = x, y = y, width = width, height = height,
        scrollable = true, resizable = true, minWidth = minimumWidth, minHeight = SETTINGS_WINDOW_MINIMUM_HEIGHT,
        destroyOnClose = true, onClose = releaseSettingsWindow, -- its X button destroys it
    })
    addAllSettings(settingsWindow)
    -- PrettyUI's resize handle calls SetSize on every step of a drag.
    local setWindowSize = settingsWindow.SetSize
    settingsWindow.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        if sliderLayoutFramesLeft <= 0 then Event.Draw.Subscribe(SLIDER_LAYOUT_SUBSCRIPTION, layOutSliders) end
        sliderLayoutFramesLeft = SLIDER_LAYOUT_FRAMES
    end
end

-- Closes the settings window and the hub's page, at shutdown.
function SettingsPage.close()
    if isSettingsWindowOpen() then
        local window = settingsWindow
        releaseSettingsWindow()
        window:Destroy()
    end
    settingsView = closeView(settingsView)
end

return SettingsPage
