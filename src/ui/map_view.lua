-- What the map window shows, from the settings and the forest: the parts shown, the legend rows and the puzzles.
-- Each is worked out once per redraw, which every change to the map starts (MapView.newRedraw).

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local ForestStops = require("src/game/forest_stops")
local RouteChoice = require("src/game/route_choice")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")

local MapView = {}

-- The node legend's two lists, as its rows go.
MapView.LEGEND_LISTS = { ForestFeatures.nodes, ForestFeatures.trinksTasks }

local redraw = {}
function MapView.newRedraw()
    redraw = {}
end

-- Returns what the map should show from the settings.
-- Map sharing mode overrides every setting that disagrees.
function MapView.view()
    if redraw.view ~= nil then return redraw.view end
    local sharing = Settings.mapSharingMode
    local function hides(key) return not sharing and Settings.effective(key) end
    redraw.view = {
        puzzleElements = not sharing and not Settings.effective("hidePuzzleElements"),
        puzzleLegend = not sharing and not Settings.hidePuzzleLegend,
        nodeLegend = sharing or not Settings.hideNodeLegend,
        simpleLegends = not sharing and Settings.simplifiedLegends,
        taskLegend = not hides("hideTaskLegend"), -- the node legend's Trinks' tasks, active or not
        claimedInLegend = not hides("hideClaimedLegend"), -- the node legend's rows of nodes claimed today
        -- A shared map keeps its legend in the frame, so it shows in a screenshot of the map.
        nodeLegendPopped = not sharing and Settings.effective("popOutNodeLegend"),
        puzzleLegendPopped = not sharing and Settings.effective("popOutPuzzleLegend"),
        header = sharing, -- the world, count and friends chat: for sharing only
        nodes = not hides("hideNodes"),
        usedNodes = not hides("hideUsedNodes"),
        unneededPuzzles = not Settings.hideUnneededPuzzles, -- on the map
        unneededPairs = not Settings.effective("hideUnneededPairs"), -- in the puzzle legend
        tasks = not hides("hideTasks"),
        forestNotes = not sharing, -- "Walk to find", and task rows dimmed when not on the task
        outlineAbsent = not sharing and not Settings.effective("hideAbsentMarks"), -- on rows of missing nodes
        mapRoute = not sharing,
        finalRoute = not hides("hideFinalRoute"),
        activeRoute = not hides("hideActiveRoute"),
        playerDot = not sharing,
        entranceSigns = not hides("hideEntranceSigns"),
    }
    return redraw.view
end

-- Returns whether a click on a map icon, sign or legend entry can choose a route: the player is in the forest, and the
-- map is not a shared one, which shows only the final route.
function MapView.canChooseRoute()
    return Forest.isInside and not Settings.mapSharingMode
end

-- Chooses a legend row's, map icon's or entrance sign's route, or drops it on a second click.
function MapView.toggleRoute(key)
    if MapView.canChooseRoute() then RouteChoice.toggle(key) end
end

-- Returns whether the node legend shows a feature's row.
function MapView.legendRowShown(feature)
    if feature.kind == "task" then return MapView.view().taskLegend or Forest.isTaskActive(feature) end
    return MapView.view().claimedInLegend or not Forest.isNodeClaimed(feature.key)
end

-- Returns the node legend's rows shown: { rows, headings (the tasks' heading goes with any task row shown),
-- hiddenKey (the rows left out, claimed nodes and tasks not active, as a string to notice a change by) }.
function MapView.legendRowsShown()
    if redraw.legendRows ~= nil then return redraw.legendRows end
    local rows, taskRows, hidden = 0, 0, {}
    for _, list in ipairs(MapView.LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            if MapView.legendRowShown(feature) then
                rows = rows + 1
                if feature.kind == "task" then taskRows = taskRows + 1 end
            else
                hidden[#hidden + 1] = feature.key
            end
        end
    end
    redraw.legendRows = { rows = rows, headings = taskRows > 0 and #MapView.LEGEND_LISTS or 1,
        hiddenKey = table.concat(hidden, " ") }
    return redraw.legendRows
end

-- Returns whether the node legend shows: by its setting, while it has a row to show. With every node claimed and
-- left out and no task shown, it goes with NAVIGATE, which has nothing left to do, and the map takes its room.
function MapView.nodeLegendShown()
    return MapView.view().nodeLegend and MapView.legendRowsShown().rows > 0
end

-- Returns the puzzles the puzzle legend shows (ForestFeatures.tools), in order.
-- While the legend is hidden nothing is left out, no search is made.
function MapView.shownPuzzles()
    if redraw.shownPuzzles ~= nil then return redraw.shownPuzzles end
    local shown = ForestFeatures.tools
    local shows = MapView.view()
    if shows.puzzleLegend and not shows.unneededPairs and Forest.bounds ~= nil then
        local held = ToolsHeld.held
        local unneeded, needed = ForestStops.mappingPlan(held).unneeded, {}
        for _, entry in ipairs(Forest.found) do
            if entry.feature.isPuzzle and ForestStops.isPuzzleNeeded(entry, held, unneeded) then
                needed[entry.feature.pair] = true
            end
        end
        shown = {}
        for _, toolPair in ipairs(ForestFeatures.tools) do
            if needed[toolPair] then shown[#shown + 1] = toolPair end
        end
    end
    redraw.shownPuzzles = shown
    return shown
end

-- Returns whether the puzzle legend shows: by its setting, while barriers stand and it has a puzzle to show.
function MapView.puzzleLegendShown()
    if redraw.puzzleLegendShown == nil then
        redraw.puzzleLegendShown = MapView.view().puzzleLegend
            and (Forest.bounds == nil or Forest.isSearching or Forest.barriersLeft()) and #MapView.shownPuzzles() > 0
    end
    return redraw.puzzleLegendShown
end

return MapView
