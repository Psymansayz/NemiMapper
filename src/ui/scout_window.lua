-- The scout window: how many of the nine node kinds the forest has, then each kind in rotation order, dimmed when
-- absent (in red if still unclaimed today), with its count and whether it is known only from the rotation; then how
-- many monsters are still to spawn.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local Settings = require("src/data/settings")
local WindowPlace = require("src/ui/window_place")
local FullForestAlert = require("src/ui/full_forest_alert")
local StatusText = require("src/ui/status_text")

local ScoutWindow = {}

local WIDTH, HEIGHT = 300, 480 -- HEIGHT only places it, as it is then fitted to its content
local MINIMUM_HEIGHT = 140 -- the minimum width comes from widthNeeded
local TEXT_FONT = id.Font.MUSEO_SANS_15PT_REGULAR -- PrettyUI's text font
local PADDING = 14 -- PrettyUI's padding on each side of the content
-- The unblock button's row
local BUTTON_ROW = 30 + 8
local UNBLOCK_SUBSCRIPTION = "nemi_mapper_scout_unblock"
-- Marks a node known only from the rotation. It is kept short, as it sets the minimum width.
local UNSEEN_SUFFIX = " (unseen)"
local COMPLETE_COLOUR = StatusText.GREEN
local INCOMPLETE_COLOUR = StatusText.GOLD
local NODE_COLOUR = 0xFFFFFFFF
local ABSENT_COLOUR = 0xFFFFFF4D -- dimmed like the map's legend (0.3)
local MISSING_COLOUR = StatusText.RED | 0x99 -- dimmed
local COUNT_FONT = id.Font.MUSEO_SANS_27PT_BOLD
local MONSTER_NUMBER_FONT = id.Font.MUSEO_SANS_19PT_BOLD
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
    local kinds, missed, missedKinds = Forest.scoutCounts()
    local missedOf = {}
    for _, feature in ipairs(missed) do missedOf[feature.key] = (missedOf[feature.key] or 0) + 1 end
    -- The count goes green when the alert's test passes.
    local complete = Forest.isFull(kinds, missedKinds, Settings.alertOnNeededNodes)
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
    if Forest.isTraitorUnseen() then unseen[#unseen + 1] = ForestFeatures.byKey.traitor.name end
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
    return widest + PADDING * 2 + WindowPlace.EDGE_WIDTH
end

-- Opens the scout window, or brings it to the front if open.
function ScoutWindow.open(PrettyUI, pluginLayer, onOpenMap)
    if isOpen() then return parts.window:Show() end
    local isBlocking = FullForestAlert.isBlocking()
    -- the highest possible monster count in its font, and the words after it
    local numberWidth = config.Font.FromID(MONSTER_NUMBER_FONT):GetStringWidth(tostring(ForestFeatures.monstersAtMost))
        + 4
    local wordsWidth = config.Font.FromID(TEXT_FONT):GetStringWidth(MONSTER_WORDS) + 4
    local minimumWidth = widthNeeded(PrettyUI, numberWidth, wordsWidth, isBlocking)
    local x, y, width, height = WindowPlace.restore(pluginLayer, "scout", WIDTH, HEIGHT, minimumWidth)
    local window = PrettyUI.Window.new(pluginLayer, {
        categoryID = "auto", title = "Nemi scout", x = x, y = y, width = width, height = height, destroyOnClose = true,
        resizable = true, minWidth = minimumWidth, minHeight = MINIMUM_HEIGHT,
        onClose = release, -- closing with the X destroys the window itself
    })
    parts = { window = window }
    if isBlocking then parts.minimumWidthUnblocked = widthNeeded(PrettyUI, numberWidth, wordsWidth, false) end
    local line = StatusText.new
    parts.countText = line(window:AddTitle({ text = "", font = COUNT_FONT, height = COUNT_HEIGHT, marginBottom = 0 }))
    -- PrettyUI lays controls out in the order they are added, so the button can only be at the top if added here.
    -- The window is rebuilt to add it, and the button destroyed to remove it.
    if isBlocking then parts.unblockButton = window:AddSimpleButton("Unblock the game", FullForestAlert.stop) end
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
        window:SetSize(width, window.contentHeight + WindowPlace.EDGE_HEIGHT)
    elseif isBlocking then
        window:SetSize(width, height + BUTTON_ROW)
    end
    showCounts()
end

-- Called when what was found changes, the search ends or a setting the window shows changes.
function ScoutWindow.showForest()
    if isOpen() then showCounts() end
end
ScoutWindow.showSettings = ScoutWindow.showForest

-- Called when a monster spawns, which changes nothing else shown.
function ScoutWindow.showMonsters()
    if isOpen() then showMonsters() end
end

local function removeUnblockButton()
    Event.Draw.Unsubscribe(UNBLOCK_SUBSCRIPTION)
    if not isOpen() or parts.unblockButton == nil then return end
    parts.unblockButton:Destroy()
    parts.unblockButton = nil
    local window = parts.window
    WindowPlace.setMinimumSize(window, parts.minimumWidthUnblocked, window.minHeight)
    window:SetSize(window.root.width, window.root.height - BUTTON_ROW)
end

-- Removes the unblock button: hides it now and destroys it next frame.
function ScoutWindow.dropUnblockButton()
    if not isOpen() or parts.unblockButton == nil then return end
    parts.unblockButton.root.hidden = true
    Event.Draw.Subscribe(UNBLOCK_SUBSCRIPTION, removeUnblockButton)
end

ScoutWindow.isOpen = isOpen

function ScoutWindow.close()
    if not isOpen() then return end
    local window = parts.window
    release()
    window:Destroy()
end

return ScoutWindow
