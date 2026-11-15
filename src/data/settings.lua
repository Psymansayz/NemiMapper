-- The settings, saved in PersistentDB (shared by every client in this install). Switches are booleans, numbers
-- are integers within their range and texts are strings.
-- Window places and sizes are integers, or nil until first moved.

local Settings = {}

-- Each switch's key and default, in the order the settings page shows them.
local SWITCHES = {
    -- General
    { "scoutOpensInForest", false },  -- open the scout window on entering a forest
    { "mapOpensInForest", true },     -- open the map on entering a forest
    { "routeStartsInForest", true },  -- press NAVIGATE on entering a forest
    -- Map
    { "mapSharingMode", false },      -- see src/ui/map_window.lua's view()
    { "simplifiedLegends", false },   -- the legends show only the node and key pictures
    { "hideUsedNodes", true },        -- hide the nodes claimed today
    { "hideNodes", false },           --   and the unclaimed ones too
    { "hideTasks", true },            -- hide the Traitor and plant icons when not on their task
    { "hideUnneededPuzzles", true },  -- hide the keys and doors on the map that no route to an unclaimed node needs
    { "hidePuzzleElements", false },  --   and every other key and door on the map too
    { "hideEntranceSigns", false },   -- hide the OTOT and KANATAH signs at the forest's openings
    -- Node legend
    { "hideNodeLegend", false },      -- hide the node and task legend beside the map
    { "popOutNodeLegend", false },    -- put the node legend in its own window
    { "hideTaskLegend", true },       -- leave Trinks' tasks out of the node legend, except the active one
    { "hideClaimedLegend", true },    -- leave the nodes claimed today out of the node legend
    { "hideAbsentMarks", false },     -- no red or brown on the rows of nodes missing from this forest
    -- Keys and doors
    { "hidePuzzleLegend", true },     -- hide the puzzle legend under the map
    { "popOutPuzzleLegend", false },  -- put the puzzle legend in its own window
    { "hideUnneededPairs", true },    -- leave the puzzles not needed, done or absent out of the puzzle legend
    -- Routes on the map
    { "hideFinalRoute", false },      -- no route from the entrance past every node to the exit
    { "hideActiveRoute", false },     -- do not draw the chosen route on the map
    { "alwaysShowTarget", true },     -- the chosen route's target keeps its icon even when another setting hides it
    -- Game world
    { "hideRouteInWorld", false },    -- do not draw the chosen route on the ground
    { "hideTargetBeam", false },      -- no beam of light over the chosen route's target
    { "highlightInWorld", true },     -- 3D boxes in the world around...
    { "highlightNodes", true },       --   ...the nodes not claimed today
    { "highlightUsedNodes", false },  --   ...the nodes claimed today too
    { "highlightTasks", true },       --   ...the current task's target (the Traitor or the Pahtli plant)
    { "highlightPuzzles", true },     --   ...the keys and doors on the way to a node, until the door opens
    { "highlightUnneededPuzzles", false }, --   ...and the others too
    { "highlightTarget", true },      --   ...the chosen route's target
    -- Scouting
    { "flashOnFullForest", false },   -- flash the screen green for 5 s on a 9/9 forest
    { "blockOnFullForest", false },   -- block game clicks on a 9/9 forest for 5 s or until dismissed
    { "alertOnNeededNodes", false },  -- the alert comes once every node still unclaimed today is in the forest
}
-- Each saved text's default. headerText is a text field on the settings page;
-- a keybind is saved as its keys' names (GameKey constants), space-separated, "" when unbound.
local STRINGS = {
    headerText = "FC: FC Nemi", -- the map header's right-hand text, as on the map pack's maps
    keybindOpenMap = "",
}
-- Each is a slider on the settings page.
Settings.numbers = {
    -- 0 is opaque, 100 invisible. At 44 the box sides have the fill the boxes were designed around (FILL_ALPHA).
    highlightTransparency = { default = 44, min = 0, max = 100 },
}
-- Each window's top-left corner and size.
local PLACES = {
    "mapX", "mapY", "mapWidth", "mapHeight", "scoutX", "scoutY", "scoutWidth", "scoutHeight",
    "settingsX", "settingsY", "settingsWidth", "settingsHeight",
    "nodeLegendX", "nodeLegendY", "nodeLegendWidth", "nodeLegendHeight", "puzzleLegendX", "puzzleLegendY",
    "puzzleLegendWidth", "puzzleLegendHeight",
}

-- Resets all settings to their defaults. Window placements are kept.
function Settings.reset()
    for _, switch in ipairs(SWITCHES) do Settings[switch[1]] = switch[2] end
    for key, number in pairs(Settings.numbers) do Settings[key] = number.default end
    for key, default in pairs(STRINGS) do Settings[key] = default end
end

-- Returns settingKey's saved integer, or nil if unsaved or negative (-1 marks an unset place).
local function savedInteger(settingKey)
    local savedValue = PersistentDB:GetInt(settingKey)
    return savedValue ~= nil and savedValue >= 0 and savedValue or nil
end

function Settings.load()
    for _, switch in ipairs(SWITCHES) do
        local saved = savedInteger(switch[1])
        Settings[switch[1]] = saved == nil and switch[2] or saved == 1
    end
    for key, number in pairs(Settings.numbers) do
        local saved = savedInteger(key)
        Settings[key] = saved == nil and number.default or math.max(number.min, math.min(number.max, saved))
    end
    for _, key in ipairs(PLACES) do Settings[key] = savedInteger(key) end
    for key, default in pairs(STRINGS) do Settings[key] = PersistentDB:GetString(key) or default end
end

Settings.reset()

-- Called on shutdown and on leaving the game (main.lua).
function Settings.save()
    for _, switch in ipairs(SWITCHES) do PersistentDB:SetInt(switch[1], Settings[switch[1]] and 1 or 0) end
    for key in pairs(Settings.numbers) do PersistentDB:SetInt(key, Settings[key]) end
    for key in pairs(STRINGS) do PersistentDB:SetString(key, Settings[key]) end
    for _, key in ipairs(PLACES) do PersistentDB:SetInt(key, Settings[key] or -1) end
end

return Settings
