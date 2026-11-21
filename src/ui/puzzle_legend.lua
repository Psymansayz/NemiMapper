-- The map's puzzle legend: a cell per key and the door it opens, with the SOLVE button, which plans a route through
-- every key and door. It sits under the map or in its own window.
-- Its functions take the map window's parts (map).

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local RouteChoice = require("src/game/route_choice")
local ToolsHeld = require("src/game/tools_held")
local ComponentWrites = require("src/ui/component_writes")
local MapWidgets = require("src/ui/map_widgets")
local MapView = require("src/ui/map_view")

local PuzzleLegend = {}

local setBox, setBoxes = ComponentWrites.setBox, ComponentWrites.setBoxes
local setHidden, setAllHidden = ComponentWrites.setHidden, ComponentWrites.setAllHidden
local view = MapView.view

local HEIGHT = 66
local SIMPLE_HEIGHT = 40 -- with no names under the pictures
-- Simplified, the paths icon stands for SOLVE's word, so the button is a square column for it.
PuzzleLegend.SOLVE_WIDTH, PuzzleLegend.SIMPLE_SOLVE_WIDTH = 72, SIMPLE_HEIGHT
PuzzleLegend.SIMPLE_PAIR_LEAST_WIDTH = 40 -- a cell holding only its key's picture
PuzzleLegend.HEIGHT_CHANGE = HEIGHT - SIMPLE_HEIGHT -- what simplifying takes off its height
local SOLVE_INSET = 2 -- the SOLVE button's inset within its column
local LARGEST_SIMPLE_ICON_SCALE = 2

-- Returns the legend's height.
function PuzzleLegend.height()
    return view().simpleLegends and SIMPLE_HEIGHT or HEIGHT
end

-- Builds a cell per puzzle and the SOLVE button in content. overlay is made between them when given, as the SOLVE
-- button goes over it.
function PuzzleLegend.build(map, content, makeOverlay)
    map.puzzlePairs, map.pairOf = {}, {}
    for _, toolPair in ipairs(ForestFeatures.tools) do
        local pair = { toolPair = toolPair }
        local function cannotRoute() return not pair.canRoute end
        -- A click draws the route and another drops it.
        pair.cell = MapWidgets.addCell(content, function() MapView.toggleRoute(toolPair.source.key) end, cannotRoute)
        pair.source = MapWidgets.addIcon(content, toolPair.source.key)
        pair.barrier = MapWidgets.addIcon(content, toolPair.barrier.key)
        pair.label = MapWidgets.addText(content, MapWidgets.SMALL_FONT, MapWidgets.TEXT_COLOUR, ui.AlignMode.CENTRE,
            toolPair.tool)
        pair.outline = MapWidgets.addOutline(content, toolPair.colour)
        pair.hover = MapWidgets.addHover(content, pair.cell, cannotRoute)
        map.puzzlePairs[#map.puzzlePairs + 1] = pair
        map.pairOf[toolPair] = pair
    end
    makeOverlay()
    -- The plan needs the player in the forest, so the button does nothing outside it.
    map.solveButton = MapWidgets.addButton(content, "SOLVE", function()
        if Forest.isInside then RouteChoice.togglePlan("solve") end
    end)
end

-- Returns the puzzles shown, marking the keys held whose cells show their doors' pictures in a simplified legend, as
-- a string to notice a change by.
function PuzzleLegend.shownKey(map)
    local held = view().simpleLegends and map.puzzleShown and ToolsHeld.held or {}
    local keys = {}
    for _, toolPair in ipairs(MapView.shownPuzzles()) do
        local key = toolPair.source.key
        keys[#keys + 1] = held[key] and key .. "*" or key
    end
    return table.concat(keys, " ")
end

-- Shows each puzzle's counts: dimmed when absent or done, its key's hint to walk nearer while the key is unseen, and
-- named by its key until the key is held, then by the door it opens.
function PuzzleLegend.showCounts(map)
    local isMapped, simple = Forest.bounds ~= nil, view().simpleLegends
    local keyUnseen, held = {}, ToolsHeld.held
    for _, toolPair in ipairs(Forest.keysUnseen()) do keyUnseen[toolPair] = true end
    for _, pair in ipairs(map.puzzlePairs) do
        local toolPair = pair.toolPair
        local count = (Forest.countOf[toolPair.source.key] or 0) + (Forest.countOf[toolPair.barrier.key] or 0)
        local isDone = Forest.doorsGone[toolPair.barrier.key] == true
        -- A puzzle absent from this forest, or done, is dimmed and ignores clicks, as does any outside the forest.
        local isDimmed = isMapped and (count == 0 or isDone)
        pair.canRoute = not isDimmed and MapView.canChooseRoute()
        -- A barrier seen without its key means the key is far off, so the label says to walk nearer.
        local isUnseen = keyUnseen[toolPair] == true
        if pair.isDimmed ~= isDimmed or pair.isKeyUnseen ~= isUnseen then
            MapWidgets.setDimmed(isDimmed, pair.barrier)
            MapWidgets.setDimmed(isDimmed or isUnseen, pair.source)
        end
        pair.isDimmed, pair.isKeyUnseen = isDimmed, isUnseen
        local name = held[toolPair.source.key] and toolPair.barrier.name or toolPair.tool
        MapWidgets.showLabel(pair.label, pair, isUnseen, isUnseen and MapWidgets.KEY_UNSEEN_TEXT or name, isDimmed)
        -- Simplified, the label is only the unseen key's hint.
        if simple then setHidden(pair.label, not (map.puzzleShown and pair.isShown and isUnseen)) end
    end
end

-- Outlines the cell whose route is drawn, and shows SOLVE pressed or not.
function PuzzleLegend.showStates(map)
    for _, pair in ipairs(map.puzzlePairs) do
        setHidden(pair.outline, not map.puzzleShown or not pair.isShown
            or pair.toolPair.source.key ~= RouteChoice.keyChosen())
    end
    MapWidgets.showButton(map.solveButton, RouteChoice.isPlanChosen("solve"))
end

-- Lays the legend out in box ({ left, top, width, height }), keeping its columns in box for its overlay.
function PuzzleLegend.layout(map, box)
    local showsPuzzle, top, height = map.puzzleShown, box.top, box.height
    local simple = view().simpleLegends
    -- The pictures take the height above the names (40 in the frame), or all of it when simplified.
    local iconHeight = simple and height - 8 or math.max(40, height - MapWidgets.TEXT_HEIGHT - 6)
    box.simple, box.arrowY = simple, top + 4 + iconHeight / 2
    local solveWidth = simple and PuzzleLegend.SIMPLE_SOLVE_WIDTH or PuzzleLegend.SOLVE_WIDTH
    -- Only the puzzles shown take a cell; the others are hidden.
    local shownPairs = {}
    for _, toolPair in ipairs(MapView.shownPuzzles()) do shownPairs[#shownPairs + 1] = map.pairOf[toolPair] end
    map.shownPairsKey = PuzzleLegend.shownKey(map)
    local isShown = {}
    for _, pair in ipairs(shownPairs) do isShown[pair] = true end
    for _, pair in ipairs(map.puzzlePairs) do
        pair.isShown = isShown[pair] == true
        if not pair.isShown then setAllHidden(true, pair.cell, pair.source, pair.barrier, pair.label, pair.outline) end
    end
    -- A simplified cell shows its key's picture, or its door's while the key is held, matching the full legend's name.
    local held = ToolsHeld.held
    box.pairCount = math.max(1, #shownPairs)
    box.pairWidth = (box.width - MapWidgets.EDGE - solveWidth) / box.pairCount
    box.cellsRight = box.left + box.width - solveWidth
    local cellsRight = box.cellsRight
    for index, pair in ipairs(shownPairs) do
        local cellLeft = math.floor(box.left + (index - 1) * box.pairWidth)
        local cellRight = index < box.pairCount and math.floor(box.left + index * box.pairWidth) or cellsRight
        local middle = box.left + (index - 0.5) * box.pairWidth
        local iconBox = math.min(math.max(54, iconHeight), box.pairWidth / 2 - 12)
        local showsDoorAlone = simple and held[pair.toolPair.source.key] == true
        setHidden(pair.cell, not showsPuzzle)
        setHidden(pair.source, not showsPuzzle or showsDoorAlone)
        setHidden(pair.barrier, not showsPuzzle or (simple and not showsDoorAlone))
        setHidden(pair.label, not showsPuzzle or (simple and not pair.isKeyUnseen))
        -- inside the legend's 1-pixel border, like the node rows, so the border shows
        local cellStart = index == 1 and cellLeft + 1 or cellLeft
        setBox(pair.cell, cellStart, top + 1, cellRight - cellStart, height - 2)
        setBoxes(pair.outline, pair.hover, cellLeft + 1, top + 1, cellRight - cellLeft - 2, height - 2)
        if not pair.hover.hidden then pair.hover.hidden = true end
        if simple then
            local width = box.pairWidth - 12
            local icon, key = pair.source, pair.toolPair.source.key
            if showsDoorAlone then icon, key = pair.barrier, pair.toolPair.barrier.key end
            MapWidgets.setIconIn(icon, key, middle - width / 2, top + 4, width, iconHeight, LARGEST_SIMPLE_ICON_SCALE)
        else
            MapWidgets.setIconIn(pair.source, pair.toolPair.source.key, middle - 10 - iconBox, top + 4, iconBox,
                iconHeight, 1)
            MapWidgets.setIconIn(pair.barrier, pair.toolPair.barrier.key, middle + 10, top + 4, iconBox, iconHeight, 1)
        end
        -- Simplified, the label is only the unseen key's hint, over the middle of the cell, wrapping onto two lines
        -- as the cell is narrow.
        local labelLines = simple and 2 or 1
        if pair.label.maxLines ~= labelLines then pair.label.maxLines = labelLines end
        if simple then
            setBox(pair.label, cellLeft + 2, top + 1, cellRight - cellLeft - 4, height - 2)
        else
            setBox(pair.label, middle - box.pairWidth / 2, top + height - MapWidgets.TEXT_HEIGHT - 1, box.pairWidth,
                MapWidgets.TEXT_HEIGHT)
        end
    end
    local solveButton = map.solveButton
    MapWidgets.showButtonParts(solveButton, showsPuzzle, simple)
    -- inset in its column, clear of the border and divider
    MapWidgets.setButtonBox(solveButton, cellsRight + SOLVE_INSET, top + SOLVE_INSET, solveWidth - SOLVE_INSET * 2,
        height - SOLVE_INSET * 2)
    map.puzzleBox = box
end

-- Draws the legend's border, a divider before each column but the first and before SOLVE, and each cell's arrow.
function PuzzleLegend.drawOverlay(canvas, box)
    canvas:AddOutline(box.left, box.top, box.width, box.height, 1, MapWidgets.FRAME_LINE_COLOUR)
    for index = 1, box.pairCount do
        local lineX = index < box.pairCount and math.floor(box.left + index * box.pairWidth) or box.cellsRight
        canvas:AddLine(lineX, box.top + MapWidgets.LEGEND_LINE_INSET, lineX,
            box.top + box.height - MapWidgets.LEGEND_LINE_INSET, 1, MapWidgets.FRAME_LINE_COLOUR)
        if not box.simple then
            local arrowX = math.floor(box.left + (index - 0.5) * box.pairWidth)
            local arrowY = math.floor(box.arrowY)
            canvas:AddTriangle(arrowX - 5, arrowY - 6, arrowX + 6, arrowY, arrowX - 5, arrowY + 6,
                MapWidgets.TEXT_COLOUR)
        end
    end
end

return PuzzleLegend
