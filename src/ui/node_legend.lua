-- The map's node legend: a row per node and Trinks' task, under their headings, with the NAVIGATE button, which
-- plans a route through every node not claimed today. It sits beside the map or in its own window.
-- Its functions take the map window's parts (map).

local ForestFeatures = require("src/data/forest_features")
local IconSizes = require("src/data/icon_sizes")
local Forest = require("src/game/forest")
local RouteChoice = require("src/game/route_choice")
local Colours = require("src/ui/colours")
local ComponentWrites = require("src/ui/component_writes")
local MapWidgets = require("src/ui/map_widgets")
local MapView = require("src/ui/map_view")

local NodeLegend = {}

local setBox, setBoxes = ComponentWrites.setBox, ComponentWrites.setBoxes
local setHidden, setAllHidden = ComponentWrites.setHidden, ComponentWrites.setAllHidden
local view = MapView.view

-- The legend's width follows the map's, as on the pack's frame (280 beside 685), within limits. Its fonts follow it.
NodeLegend.TO_MAP = 0.41
NodeLegend.MINIMUM_WIDTH, NodeLegend.MAXIMUM_WIDTH = 110, 320
NodeLegend.BUTTON_HEIGHT = 30 -- the NAVIGATE button, at the legend's foot
local HEADING_PADDING = 6 -- above and below a legend heading
local LARGEST_ICON_SCALE = 1.25
-- Simplified legends show only the pictures, which may grow to this many times their size.
local LARGEST_SIMPLE_ICON_SCALE = 2
local SIMPLE_ICON_INSET = 2 -- the gap kept round a simplified row's picture, inside the row's outline
local NAME_TO_ROW = 0.5 -- a name's font is at most this share of its row, so it grows with the legend
-- PrettyUI's window background, tiled behind the legend row of a node absent from this forest but claimed today, so
-- it stands apart from the red rows still to claim.
local WINDOW_BACKGROUND_SPRITE = id.Sprite.RS3_MODAL_WINDOW_CONTENT_TILE
local MISSING_COLOUR = Colours.RED | 0x70 -- translucent red over a node absent from this forest but unclaimed today
local KEY_UNSEEN_NAME = MapWidgets.KEY_UNSEEN_TEXT:upper() -- on a legend row, whose names are upper case

-- Returns the bold fonts of these sizes as { id, size }, largest first, ending with the 11pt font (regular, as the
-- game has no 11pt bold).
-- Legend headings and names use the largest that fits.
local function boldFonts(sizes)
    local fonts = {}
    for _, size in ipairs(sizes) do
        fonts[#fonts + 1] = { id = id.Font["MUSEO_SANS_" .. size .. "PT_BOLD"], size = size }
    end
    fonts[#fonts + 1] = { id = MapWidgets.SMALL_FONT, size = 11 }
    return fonts
end
local HEADING_FONTS = boldFonts({ 27, 24, 21, 19, 17, 15, 13 })
local NAME_FONTS = boldFonts({ 24, 21, 19, 17, 15, 13 })

local TITLES = { "SKILL NODES", "TRINKS' TASKS" }
local NAMES = {} -- every row's name, upper case as shown
for _, list in ipairs(MapView.LEGEND_LISTS) do
    for _, feature in ipairs(list) do NAMES[#NAMES + 1] = feature.name:upper() end
end

-- Returns width rounded up, between leastWidth and the legend's greatest width.
function NodeLegend.clampedWidth(width, leastWidth)
    return math.max(leastWidth, math.min(NodeLegend.MAXIMUM_WIDTH, math.ceil(width)))
end

-- Returns the legend's least width; a simplified one is as wide as its NAVIGATE button, inside its border.
function NodeLegend.minimumWidth()
    if not view().simpleLegends then return NodeLegend.MINIMUM_WIDTH end
    return NodeLegend.BUTTON_HEIGHT + 2
end

-- Returns the legend's heading height at a legend's width, and the heading font that fits it.
function NodeLegend.heading(legendWidth)
    local font = MapWidgets.fittingFont(HEADING_FONTS, TITLES, math.max(1, legendWidth - 16))
    return view().simpleLegends and 0 or font.size + HEADING_PADDING * 2, font
end

-- Returns a simplified legend's width: its widest picture at the rows' height.
local function simpleWidthFor(legendHeight, rowCount)
    rowCount = math.max(1, rowCount or #NAMES)
    local rowHeight = (legendHeight - (view().mapRoute and NodeLegend.BUTTON_HEIGHT or 0)) / rowCount
    local widest = 0
    for _, list in ipairs(MapView.LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            local size = IconSizes[feature.key]
            local scale = math.min((rowHeight - SIMPLE_ICON_INSET * 2) / size.height, LARGEST_SIMPLE_ICON_SCALE)
            widest = math.max(widest, size.width * scale)
        end
    end
    return NodeLegend.clampedWidth(widest + SIMPLE_ICON_INSET * 2, NodeLegend.minimumWidth())
end

-- Returns the legend's width when in its own window.
function NodeLegend.poppedWidth(legendHeight)
    if view().simpleLegends then return simpleWidthFor(legendHeight, MapView.legendRowsShown().rows) end
    return NodeLegend.clampedWidth(legendHeight * NodeLegend.TO_MAP, NodeLegend.MINIMUM_WIDTH)
end

-- Returns the legend's width in the frame beside a map of mapSize, rounded up, the legend being legendHeight high.
function NodeLegend.widthBeside(mapSize, legendHeight)
    if view().simpleLegends then return simpleWidthFor(legendHeight) end
    return NodeLegend.clampedWidth(mapSize * NodeLegend.TO_MAP, NodeLegend.MINIMUM_WIDTH)
end

-- Builds the legend's headings, rows and NAVIGATE button in content.
function NodeLegend.build(map, content)
    map.legendHeadings, map.legendRows = {}, {}
    for listIndex, list in ipairs(MapView.LEGEND_LISTS) do
        map.legendHeadings[#map.legendHeadings + 1] = {
            text = MapWidgets.addText(content, MapWidgets.TEXT_FONT, MapWidgets.HEADING_COLOUR, ui.AlignMode.CENTRE,
                TITLES[listIndex]),
            rowCount = #list,
        }
        for _, feature in ipairs(list) do
            local row = { feature = feature, nameText = feature.name:upper() }
            local function cannotRoute() return not row.canRoute end
            -- A click draws the route and another drops it.
            row.cell = MapWidgets.addCell(content, function() MapView.toggleRoute(feature.key) end, cannotRoute)
            -- over the cell, under the row's picture and name
            if feature.kind == "node" then
                row.claimedBackground = MapWidgets.addGameSprite(content, WINDOW_BACKGROUND_SPRITE)
                row.claimedBackground.isTiling = true
            end
            row.icon = MapWidgets.addIcon(content, feature.key)
            -- centred between the icon and the skill symbol
            row.name = MapWidgets.addText(content, MapWidgets.TEXT_FONT, MapWidgets.TEXT_COLOUR, ui.AlignMode.CENTRE,
                row.nameText)
            -- the game's skill icons; the SKILL_<skill> sprites are the daily tasks' set, not these
            if feature.skill ~= nil then
                row.skill = MapWidgets.addGameSprite(content, id.Sprite["HITMARK_ICON_SKILL_" .. feature.skill:upper()])
            end
            -- covers the row of a node that is absent but still unclaimed today
            row.missing = MapWidgets.create(ui.Rectangle, content)
            row.missing.fill = true
            row.missing.rgba = MISSING_COLOUR
            row.outlineColour = ForestFeatures.colourOf(feature)
            row.outline = MapWidgets.addOutline(content, row.outlineColour)
            row.hover = MapWidgets.addHover(content, row.cell, cannotRoute)
            map.legendRows[#map.legendRows + 1] = row
        end
    end
    -- The plan needs the player in the forest, so the button does nothing outside it.
    map.mapRouteButton = MapWidgets.addButton(content, "NAVIGATE", function()
        if Forest.isInside then RouteChoice.togglePlan("navigate") end
    end)
end

-- Shows each row's counts: dimmed when none is in the forest, covered red when an absent node is still unclaimed,
-- and the hint to walk nearer for a task's NPC not yet seen.
function NodeLegend.showCounts(map)
    local shows = view()
    local isMapped = Forest.bounds ~= nil
    -- A node who is claimed today, and hidden by the setting, counts as absent.
    local unusedOf = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == "node" and (shows.usedNodes or not entry.isUsed) then
            unusedOf[entry.feature.key] = (unusedOf[entry.feature.key] or 0) + 1
        end
    end
    for _, row in ipairs(map.legendRows) do
        local feature = row.feature
        local foundCount = Forest.countOf[feature.key] or 0
        -- canRoute also needs the player inside and no sharing mode, so no outline shows where a click does nothing.
        row.canRoute = foundCount > 0 and MapView.canChooseRoute()
        local count = feature.kind == "node" and (unusedOf[feature.key] or 0) or foundCount
        if feature.kind == "task" and shows.forestNotes and not Forest.isTaskActive(feature) then count = 0 end
        local isDimmed = isMapped and count == 0
        local isAbsentNode = shows.outlineAbsent and isMapped and feature.kind == "node" and foundCount == 0
        row.isNeeded = isAbsentNode and not Forest.isNodeClaimed(feature.key)
        row.isClaimedAbsent = isAbsentNode and Forest.isNodeClaimed(feature.key)
        -- An NPC never seen is far off, so the row says to walk nearer. The hint is not dimmed.
        local isUnseen = shows.forestNotes and isMapped and feature.npcs ~= nil and foundCount == 0
            and Forest.isTaskActive(feature)
        if row.isDimmed ~= isDimmed then
            row.isDimmed = isDimmed
            MapWidgets.setDimmed(isDimmed, row.icon, row.skill)
        end
        MapWidgets.showLabel(row.name, row, isUnseen, isUnseen and KEY_UNSEEN_NAME or row.nameText,
            isDimmed and not isUnseen)
    end
end

-- Outlines the row whose route is drawn, covers the rows of absent nodes, and shows NAVIGATE pressed or not.
function NodeLegend.showStates(map)
    for _, row in ipairs(map.legendRows) do
        setHidden(row.outline, not row.isShown or row.feature.key ~= RouteChoice.keyChosen())
        setHidden(row.missing, not row.isShown or not row.isNeeded)
        if row.claimedBackground ~= nil then -- (nodes only)
            setHidden(row.claimedBackground, not row.isShown or not row.isClaimedAbsent)
        end
    end
    MapWidgets.showButton(map.mapRouteButton, RouteChoice.isPlanChosen("navigate"))
end

-- Gives each row's outline its feature's colour, after a colour setting changes.
function NodeLegend.showColours(map)
    for _, row in ipairs(map.legendRows) do
        local colour = ForestFeatures.colourOf(row.feature)
        if row.outlineColour ~= colour then
            row.outlineColour = colour
            row.outline.rgba = colour
        end
    end
end

-- Lays the legend out in box ({ left, top, width, height }), keeping the dividers' heights in box.lines.
function NodeLegend.layout(map, box)
    local shows, showsLegend = view(), map.legendShown
    local left, legendWidth = box.left, box.width
    -- NAVIGATE and the covers are as wide as the dividers, inside the legend's border, or the legend's whole width
    -- when simplified.
    local lineInset = shows.simpleLegends and 1 or MapWidgets.LEGEND_LINE_INSET
    box.lines = {}
    local rowsHeight = box.height - (shows.mapRoute and NodeLegend.BUTTON_HEIGHT or 0)
    local simple = shows.simpleLegends
    local showsTexts = showsLegend and not simple
    local headingHeight, headingFontEntry = NodeLegend.heading(legendWidth)
    local legendRows = MapView.legendRowsShown()
    local rowsShown, headingsShown = legendRows.rows, legendRows.headings
    local rowHeight = rowsShown > 0 and (rowsHeight - headingHeight * headingsShown) / rowsShown or 0
    -- Kept so the legend's own window can keep its rows as tall when rows come or go.
    if rowsShown > 0 then map.nodeRowHeight = rowHeight end
    map.nodeRowCount = rowsShown
    local iconWidth = simple and legendWidth - 12 or math.min(70, rowHeight * 1.5, legendWidth * 0.26)
    local skillWidth = math.min(44, rowHeight * 1.2, legendWidth * 0.16)
    local nameWidth = legendWidth - iconWidth - skillWidth - 24
    -- Names use the largest font the widest name fits, no taller than its share of a row.
    local nameFontEntry = MapWidgets.fittingFont(NAME_FONTS, NAMES, math.max(1, nameWidth), rowHeight * NAME_TO_ROW)
    -- Fonts are written only when they change, as this runs on every step of a resize.
    local headingFontChanged, nameFontChanged = map.headingFont ~= headingFontEntry, map.nameFont ~= nameFontEntry
    map.headingFont, map.nameFont = headingFontEntry, nameFontEntry
    local rowTop = box.top
    local nextRow = 1
    for headingIndex, heading in ipairs(map.legendHeadings) do
        local headingShown = headingIndex <= headingsShown
        if headingFontChanged then heading.text.font = headingFontEntry.id end
        setHidden(heading.text, not showsTexts or not headingShown)
        setBox(heading.text, left, rowTop, legendWidth, headingHeight)
        if headingShown then rowTop = rowTop + headingHeight end
        for index = nextRow, nextRow + heading.rowCount - 1 do
            local row = map.legendRows[index]
            -- The outline and red cover are shown or hidden by showStates, which follows.
            local rowShown = MapView.legendRowShown(row.feature)
            row.isShown = showsLegend and rowShown
            setAllHidden(not row.isShown, row.cell, row.icon)
            setAllHidden(not showsTexts or not rowShown, row.name, row.skill)
            if rowShown then box.lines[#box.lines + 1] = math.floor(rowTop) end
            setBox(row.cell, left + 1, rowTop, legendWidth - 2, rowHeight)
            setBoxes(row.outline, row.hover, left + 2, rowTop + 1, legendWidth - 4, rowHeight - 2)
            if not row.hover.hidden then row.hover.hidden = true end
            if simple then
                MapWidgets.setIconIn(row.icon, row.feature.key, left + SIMPLE_ICON_INSET, rowTop + SIMPLE_ICON_INSET,
                    legendWidth - SIMPLE_ICON_INSET * 2, rowHeight - SIMPLE_ICON_INSET * 2, LARGEST_SIMPLE_ICON_SCALE)
            else
                MapWidgets.setIconIn(row.icon, row.feature.key, left + 6, rowTop + 3, iconWidth, rowHeight - 6,
                    LARGEST_ICON_SCALE)
            end
            if nameFontChanged then row.name.font = nameFontEntry.id end
            setBox(row.missing, left + lineInset, rowTop, legendWidth - lineInset * 2, rowHeight)
            if row.claimedBackground ~= nil then
                setBox(row.claimedBackground, left + lineInset, rowTop, legendWidth - lineInset * 2, rowHeight)
            end
            setBox(row.name, left + iconWidth + 12, rowTop, nameWidth, rowHeight)
            if row.skill ~= nil then
                -- The game's icon is square, as large as the column allows.
                local size = math.min(skillWidth, rowHeight - 6)
                setBox(row.skill, left + legendWidth - 6 - (skillWidth + size) / 2,
                    rowTop + (rowHeight - size) / 2, size, size)
            end
            if rowShown then rowTop = rowTop + rowHeight end
        end
        nextRow = nextRow + heading.rowCount
        -- NAVIGATE goes under the node rows, before the tasks.
        if headingIndex == 1 then
            local button = map.mapRouteButton
            MapWidgets.showButtonParts(button, showsLegend and shows.mapRoute, simple)
            MapWidgets.setButtonBox(button, left + lineInset, rowTop, legendWidth - lineInset * 2,
                NodeLegend.BUTTON_HEIGHT - 1)
            if shows.mapRoute then rowTop = rowTop + NodeLegend.BUTTON_HEIGHT end
        end
        if headingIndex < headingsShown then box.lines[#box.lines + 1] = math.floor(rowTop) end
    end
    map.nodeBox = box
end

-- Draws the legend's border and the dividers between its rows and between its two lists.
function NodeLegend.drawOverlay(canvas, box)
    canvas:AddOutline(box.left, box.top, box.width, box.height, 1, MapWidgets.FRAME_LINE_COLOUR)
    for _, lineY in ipairs(box.lines) do
        canvas:AddLine(box.left + MapWidgets.LEGEND_LINE_INSET, lineY,
            box.left + box.width - MapWidgets.LEGEND_LINE_INSET, lineY, 1, MapWidgets.FRAME_LINE_COLOUR)
    end
end

return NodeLegend
