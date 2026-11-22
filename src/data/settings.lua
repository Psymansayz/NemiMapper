-- The settings, saved in PersistentDB (shared by every client in this install). Switches are booleans, numbers
-- are integers within their range, texts are strings and colours are 0xRRGGBBAA integers.
-- Window places and sizes are integers, or nil until first moved.

local Settings = {}

-- Each switch's key and default. A switch under another counts only while that one is on, and one with offWhen only
-- while that one is off, as the settings page shows them.
local SWITCHES = {
    -- General
    { "scoutOpensInForest", false },  -- open the scout window on entering a forest
    { "mapOpensInForest", true },     -- open the map on entering a forest
    { "routeStartsInForest", true },  -- press NAVIGATE on entering a forest
    -- Map
    { "mapSharingMode", false },      -- see src/ui/map_view.lua's view()
    { "simplifiedLegends", false },   -- the legends show only the node and key pictures
    { "hideUsedNodes", true },        -- hide the nodes claimed today
    { "hideNodes", false,             --   and the unclaimed ones too
        under = "hideUsedNodes" },
    { "hideTasks", true },            -- hide the Traitor and plant icons when not on their task
    { "hideUnneededPuzzles", true },  -- hide the keys and doors on the map that no route to an unclaimed node needs
    { "hidePuzzleElements", false,    --   and every other key and door on the map too
        under = "hideUnneededPuzzles" },
    { "hideEntranceSigns", false },   -- hide the OTOT and KANATAH signs at the forest's openings
    -- Node legend
    { "hideNodeLegend", false },      -- hide the node and task legend beside the map
    { "popOutNodeLegend", false,      -- put the node legend in its own window
        offWhen = "hideNodeLegend" },
    { "hideTaskLegend", true,         -- leave Trinks' tasks out of the node legend, except the active one
        offWhen = "hideNodeLegend" },
    { "hideClaimedLegend", true,      -- leave the nodes claimed today out of the node legend
        offWhen = "hideNodeLegend" },
    { "hideAbsentMarks", false,       -- no red or brown on the rows of nodes missing from this forest
        offWhen = "hideNodeLegend" },
    -- Keys and doors
    { "hidePuzzleLegend", true },     -- hide the puzzle legend under the map
    { "popOutPuzzleLegend", false,    -- put the puzzle legend in its own window
        offWhen = "hidePuzzleLegend" },
    { "hideUnneededPairs", true,      -- leave the puzzles not needed, done or absent out of the puzzle legend
        offWhen = "hidePuzzleLegend" },
    -- Routes on the map
    { "hideFinalRoute", false },      -- no route from the entrance past every node to the exit
    { "hideActiveRoute", false },     -- do not draw the chosen route on the map
    { "alwaysShowTarget", true },     -- the chosen route's stops keep their icons even when another setting hides them
    -- Game world
    { "hideRouteInWorld", false },    -- do not draw the chosen route on the ground
    { "hideTargetBeam", false },      -- no beam of light over the chosen route's target
    { "highlightInWorld", true },     -- 3D boxes in the world around...
    { "highlightNodes", true,         --   ...the nodes not claimed today
        under = "highlightInWorld" },
    { "highlightUsedNodes", false,    --   ...the nodes claimed today too
        under = "highlightNodes" },
    { "highlightTasks", true,         --   ...the current task's target (the Traitor or the Pahtli plant)
        under = "highlightInWorld" },
    { "highlightPuzzles", true,       --   ...the keys and doors on the way to a node, until the door opens
        under = "highlightInWorld" },
    { "highlightUnneededPuzzles", false, -- ...and the others too
        under = "highlightPuzzles" },
    { "highlightTarget", true,        --   ...the chosen route's stops
        under = "highlightInWorld" },
    -- Scouting
    { "flashOnFullForest", false },   -- flash the screen green for 5 s on a 9/9 forest
    { "blockOnFullForest", false },   -- block game clicks on a 9/9 forest for 5 s or until dismissed
    { "alertOnNeededNodes", false },  -- the alert comes once every node still unclaimed today is in the forest
}
-- Each saved text field's default.
local STRINGS = {
    headerText = "FC: FC Nemi", -- the map header's right-hand text, as on the map pack's maps
    keybindOpenMap = "",
}

Settings.numbers = {
    -- 0 is opaque, 100 invisible.
    highlightTransparency = { default = 44, min = 0, max = 100, under = "highlightInWorld" },
}

local COLOURS = {
    prayerColour = 0x2F6FD6FF,
    farmingColour = 0xB4F03CFF,
    miningColour = 0x7A4A24FF,
    dungeoneeringColour = 0x1FA392FF,
    tasksColour = 0xF2E05AFF, -- yellow
}

-- Each setting's parent and offWhen setting, by key.
Settings.under, Settings.offWhen = {}, {}
for _, switch in ipairs(SWITCHES) do
    Settings.under[switch[1]], Settings.offWhen[switch[1]] = switch.under, switch.offWhen
end
for key, number in pairs(Settings.numbers) do Settings.under[key] = number.under end

-- Returns whether a setting takes effect: every setting it is under is on, and its offWhen setting is off.
function Settings.isEnabled(key)
    if Settings.offWhen[key] ~= nil and Settings[Settings.offWhen[key]] then return false end
    local parent = Settings.under[key]
    while parent ~= nil do
        if not Settings[parent] then return false end
        parent = Settings.under[parent]
    end
    return true
end

-- Returns whether a switch is on and takes effect.
function Settings.effective(key)
    return Settings[key] and Settings.isEnabled(key)
end

-- Each window's top-left corner and size
local PLACES = {}
for _, window in ipairs({ "map", "scout", "settings", "nodeLegend", "puzzleLegend" }) do
    for _, part in ipairs({ "X", "Y", "Width", "Height" }) do PLACES[#PLACES + 1] = window .. part end
end

-- Resets all settings to their defaults. Window placements are kept.
function Settings.reset()
    for _, switch in ipairs(SWITCHES) do Settings[switch[1]] = switch[2] end
    for key, number in pairs(Settings.numbers) do Settings[key] = number.default end
    for key, default in pairs(STRINGS) do Settings[key] = default end
    for key, default in pairs(COLOURS) do Settings[key] = default end
end

local function savedInteger(settingKey)
    local savedValue = PersistentDB:GetInt(settingKey)
    return savedValue ~= nil and savedValue >= 0 and savedValue or nil
end

-- Returns text without angle brackets.
-- The game reads them as markup in a shown text, and a tag like <img=-1> crashes the client.
function Settings.withoutTags(text)
    return (text:gsub("[<>]", ""))
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
    for key, default in pairs(STRINGS) do
        Settings[key] = Settings.withoutTags(PersistentDB:GetString(key) or default)
    end
    for key, default in pairs(COLOURS) do
        local saved = savedInteger(key)
        Settings[key] = saved == nil and default or (saved & 0xFFFFFF) << 8 | 0xFF
    end
end

-- Called only on shutdown/leaving the game
function Settings.save()
    for _, switch in ipairs(SWITCHES) do PersistentDB:SetInt(switch[1], Settings[switch[1]] and 1 or 0) end
    for key in pairs(Settings.numbers) do PersistentDB:SetInt(key, Settings[key]) end
    for key in pairs(STRINGS) do PersistentDB:SetString(key, Settings[key]) end
    for key in pairs(COLOURS) do PersistentDB:SetInt(key, Settings[key] >> 8) end
    for _, key in ipairs(PLACES) do PersistentDB:SetInt(key, Settings[key] or -1) end
end

return Settings
