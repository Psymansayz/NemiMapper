-- The scout window: how many of the nine node kinds the forest has, then each kind in rotation order, dimmed when
-- absent (in red if still unclaimed today), with its count and whether it is known only from the rotation; then how
-- many monsters are still to spawn.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local GameIds = require("src/game/game_ids")
local Settings = require("src/data/settings")
local WindowPlace = require("src/ui/window_place")
local FullForestAlert = require("src/ui/full_forest_alert")
local StatusText = require("src/ui/status_text")

local ScoutWindow = {}

local WIDTH, HEIGHT = 300, 480 -- HEIGHT only places it, as it is then fitted to its content
local MINIMUM_HEIGHT = 140 -- the minimum width comes from widthNeeded
local TEXT_FONT = id.Font.MUSEO_SANS_15PT_REGULAR -- PrettyUI's text font
local PADDING = 14 -- PrettyUI's padding on each side of the content
local WINDOW_EDGE_WIDTH = 16 -- a PrettyUI window is this much wider than its content
-- The unblock button's row: PrettyUI's button height plus the gap below it.
-- The window grows by this while the button is shown, so the other rows keep their room.
local BUTTON_ROW = 30 + 8
local UNBLOCK_SUBSCRIPTION = "nemi_mapper_scout_unblock"
-- Marks a node known only from the rotation. It is kept short, as it sets the minimum width.
local UNSEEN_SUFFIX = " (unseen)"
local TITLE_AND_BORDER = 40 -- a PrettyUI window's title bar (32) and bottom border (8)
local COMPLETE_COLOUR = 0x7DDC5AFF
local INCOMPLETE_COLOUR = 0xF2C66DFF
local NODE_COLOUR = 0xFFFFFFFF
local ABSENT_COLOUR = 0xFFFFFF4D -- dimmed like the map's legend (0.3)
local MISSING_COLOUR = 0xE0433A99 -- the map's red for an absent node still unclaimed today, dimmed
local COUNT_FONT = GameIds.resolve("Font", "MUSEO_SANS_27PT_BOLD") or id.Font.MUSEO_SANS_13PT_BOLD
-- A text has only one font, so "monsters left" is two texts on one line: a larger bold number, right-aligned in the
-- width of the highest possible count, then the words.
local MONSTER_NUMBER_FONT = GameIds.resolve("Font", "MUSEO_SANS_19PT_BOLD") or id.Font.MUSEO_SANS_13PT_BOLD
local MONSTER_WORDS = "monsters left"
local MONSTER_GAP = 5 -- pixels between the number and its words
local COUNT_HEIGHT = 32 -- about the font's height, leaving no room under it
local NODE_ROW_HEIGHT = 22

-- The open window's components, its texts as StatusText lines, or nil.
local parts = nil

-- Returns whether the scout window is open.
local function isOpen()
    if parts ~= nil and ui.Interfaces:GetInterface(parts.window.interfaceID) == nil then parts = nil end
    return parts ~= nil
end

-- Returns the width of the highest possible monster count, in its font.
local function monsterNumberWidth()
    return config.Font.FromID(MONSTER_NUMBER_FONT):GetStringWidth(tostring(ForestFeatures.monstersAtMost)) + 4
end

-- Shows how many monsters are still to spawn.
local function showMonsters()
    local monstersLeft = math.max(0, ForestFeatures.monstersAtMost - Forest.monstersSpawned)
    StatusText.set(parts.monstersNumber, tostring(monstersLeft),
        monstersLeft == 0 and COMPLETE_COLOUR or INCOMPLETE_COLOUR)
    StatusText.set(parts.monstersText, monstersLeft == 1 and "monster left" or MONSTER_WORDS)
end

local function showCounts()
    local setText = StatusText.set
    if Forest.bounds == nil then
        setText(parts.countText, "")
        setText(parts.stateText, "Enter the Nemi Forest")
        for index, node in ipairs(ForestFeatures.nodesInRotation) do
            setText(parts.nodeRows[index], node.name, NODE_COLOUR)
        end
        setText(parts.monstersNumber, "")
        setText(parts.monstersText, "")
        setText(parts.keysText, "")
        return
    end
    -- Once the search settles, the rotation reveals nodes missed between those found.
    -- They are in the forest but unseen, and their kinds count toward the total.
    local kinds, _, missed, missedKinds = Forest.scoutCounts()
    local missedOf = {}
    for _, feature in ipairs(missed) do missedOf[feature.key] = (missedOf[feature.key] or 0) + 1 end
    -- The count goes green on a 9/9 forest, or, with the alert set to every node still needed, once the search has
    -- settled with all of them in the forest, by the alert's own test.
    local complete = kinds >= #ForestFeatures.nodes
        or Settings.alertOnNeededNodes and not Forest.isSearching
        and FullForestAlert.forestIsComplete(kinds, missedKinds)
    setText(parts.countText, kinds .. (kinds == 1 and " Node" or " Nodes"),
        complete and COMPLETE_COLOUR or INCOMPLETE_COLOUR)
    -- Locations arrive over the forest's first server ticks, so the count can rise until the search settles.
    setText(parts.stateText, Forest.isSearching and "Still looking..." or "", NODE_COLOUR)
    for index, node in ipairs(ForestFeatures.nodesInRotation) do
        local found, unseen = Forest.countOf[node.key] or 0, missedOf[node.key] or 0
        local count = found + unseen
        local colour = NODE_COLOUR
        if count == 0 then colour = Forest.isNodeClaimed(node.key) and ABSENT_COLOUR or MISSING_COLOUR end
        -- A second node of a kind gives no extra XP.
        setText(parts.nodeRows[index],
            node.name .. (count > 1 and (" x" .. count) or "") .. (unseen > 0 and UNSEEN_SUFFIX or ""), colour)
    end
    showMonsters()
    -- An NPC key only reaches the client near the player, so a distant one stays unseen until the player walks nearer.
    local unseen = {}
    for _, toolPair in ipairs(Forest.keysUnseen()) do unseen[#unseen + 1] = toolPair.source.name end
    for _, task in ipairs(Forest.tasksUnseen()) do unseen[#unseen + 1] = task.name end
    setText(parts.keysText, #unseen > 0 and ("Walk nearer: " .. table.concat(unseen, ", ")) or "")
end

-- Saves the window's place and size, less the unblock button's row, which comes and goes.
local function release()
    WindowPlace.remember(parts.window.root, "scout", parts.unblockButton ~= nil and BUTTON_ROW or 0)
    Event.Draw.Unsubscribe(UNBLOCK_SUBSCRIPTION)
    parts = nil
end

local function widthNeeded(PrettyUI, numberWidth, wordsWidth, isBlocking)
    local textFont, countFont = config.Font.FromID(TEXT_FONT), config.Font.FromID(COUNT_FONT)
    local widest = math.max(countFont:GetStringWidth("9 Nodes"), numberWidth + MONSTER_GAP + wordsWidth,
        PrettyUI.SimpleButton.getSize("Open the map"),
        isBlocking and PrettyUI.SimpleButton.getSize("Unblock the game") or 0)
    for _, node in ipairs(ForestFeatures.nodesInRotation) do
        widest = math.max(widest, textFont:GetStringWidth(node.name .. " x2"),
            textFont:GetStringWidth(node.name .. UNSEEN_SUFFIX))
    end
    return widest + PADDING * 2 + WINDOW_EDGE_WIDTH
end

-- Opening it again brings it to the front. onUnblock ends the full-forest alert.
-- isBlocking shows the unblock button at the top.
local openWith -- the last open's arguments, to rebuild the window with the unblock button
function ScoutWindow.open(PrettyUI, pluginLayer, onOpenMap, onUnblock, isBlocking)
    openWith = { PrettyUI, pluginLayer, onOpenMap, onUnblock }
    if isOpen() then return parts.window:Show() end
    local numberWidth = monsterNumberWidth()
    local wordsWidth = config.Font.FromID(TEXT_FONT):GetStringWidth(MONSTER_WORDS) + 4
    local minimumWidth = widthNeeded(PrettyUI, numberWidth, wordsWidth, isBlocking)
    local width = math.min(math.max(minimumWidth, Settings.scoutWidth or WIDTH), pluginLayer.width)
    local height = math.min(Settings.scoutHeight or HEIGHT, pluginLayer.height)
    local x, y = WindowPlace.position(pluginLayer, width, height, Settings.scoutX, Settings.scoutY)
    local window = PrettyUI.Window.new(pluginLayer, {
        title = "Nemi scout", x = x, y = y, width = width, height = height, destroyOnClose = true,
        resizable = true, minWidth = minimumWidth, minHeight = MINIMUM_HEIGHT,
        onClose = release, -- closing with the X destroys the window itself
    })
    parts = { window = window, minimumWidthUnblocked = widthNeeded(PrettyUI, numberWidth, wordsWidth, false) }
    local line = StatusText.new
    parts.countText = line(window:AddTitle({ text = "", font = COUNT_FONT, height = COUNT_HEIGHT, marginBottom = 0 }))
    -- PrettyUI lays controls out in the order they are added, so the button can only be at the top if added here.
    -- The window is rebuilt to add it, and the button destroyed to remove it.
    if isBlocking then parts.unblockButton = window:AddSimpleButton("Unblock the game", onUnblock) end
    parts.stateText = line(window:AddText({ text = "", height = 18 }))
    parts.nodeRows = {}
    for index in ipairs(ForestFeatures.nodesInRotation) do
        parts.nodeRows[index] = line(window:AddText({ text = "", height = NODE_ROW_HEIGHT, maxLines = 1 }))
    end
    parts.monstersNumber = line(window:AddText({ text = "", font = MONSTER_NUMBER_FONT, width = numberWidth,
        height = 24, maxLines = 1, alignHorizontal = ui.AlignMode.RIGHT }))
    parts.monstersText = line(window:AddText({ text = "", inline = true, columnGap = MONSTER_GAP, height = 24,
        width = wordsWidth, maxLines = 1 }))
    -- A text keeps the height it was made with, so this one is sized for the longest list of unseen keys.
    parts.keysText = line(window:AddText({ text = "", height = 42 }))
    window:AddSimpleButton("Open the map", onOpenMap)
    -- Fitted to its content it needs no scrollbar. Once the player resizes it, that size is kept.
    if Settings.scoutHeight == nil then
        window:SetSize(width, window.contentHeight + TITLE_AND_BORDER)
    elseif isBlocking then
        window:SetSize(width, height + BUTTON_ROW)
    end
    showCounts()
end

-- Called when what was found changes or the search ends.
function ScoutWindow.showForest()
    if isOpen() then showCounts() end
end

-- Called when a monster spawns, which changes nothing else shown.
function ScoutWindow.showMonsters()
    if isOpen() and Forest.bounds ~= nil then showMonsters() end
end

-- Called when a setting the window shows changes.
function ScoutWindow.showSettings()
    if isOpen() then showCounts() end
end

-- Destroys the unblock button a frame after its click hid it, as destroying a component in its
-- The controls below move up and the window shrinks by its row.
local function removeUnblockButton()
    Event.Draw.Unsubscribe(UNBLOCK_SUBSCRIPTION)
    if not isOpen() or parts.unblockButton == nil then return end
    parts.unblockButton:Destroy()
    parts.unblockButton = nil
    -- PrettyUI's resize handle keeps its own copy of the limits.
    local window, minimumWidth = parts.window, parts.minimumWidthUnblocked
    window.minWidth = minimumWidth
    if window.resize ~= nil then window.resize.minWidth = minimumWidth end
    local root = parts.window.root
    parts.window:SetSize(root.width, root.height - BUTTON_ROW)
end

-- Shows the unblock button with isBlocking, or removes it without.
-- Adding it rebuilds the window in place; removing it hides it now and destroys it next frame.
function ScoutWindow.showBlocking(isBlocking)
    if not isOpen() then return end
    if isBlocking and parts.unblockButton == nil then
        ScoutWindow.close()
        openWith[5] = true
        ScoutWindow.open(table.unpack(openWith, 1, 5))
    elseif not isBlocking and parts.unblockButton ~= nil then
        parts.unblockButton.root.hidden = true
        Event.Draw.Subscribe(UNBLOCK_SUBSCRIPTION, removeUnblockButton)
    end
end

ScoutWindow.isOpen = isOpen

function ScoutWindow.close()
    if not isOpen() then return end
    local window = parts.window
    release()
    window:Destroy()
end

return ScoutWindow
