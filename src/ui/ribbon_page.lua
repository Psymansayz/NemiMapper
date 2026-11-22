-- The plugin's ribbon page in the hub: buttons opening the windows, and the day's status (the nodes claimed and
-- Trinks' tasks), kept up as the server sends their variables.

local Forest = require("src/game/forest")
local ForestFeatures = require("src/data/forest_features")
local StatusText = require("src/ui/status_text")

local RibbonPage = {}

local SUBSCRIPTION = "nemi_mapper_daily"
local COLUMN_GAP = 8 -- PrettyUI's gap before an inline text
local DAILY_COMPLETE_COLOUR, DAILY_INCOMPLETE_COLOUR = StatusText.GREEN, StatusText.GOLD
local UNCLAIMED_COLOUR = StatusText.RED | 0xFF
local DAILY_LINE_HEIGHT = 22
-- The hub's page is narrow, so the page keeps PrettyUI's padding small and indents nothing.
local PAGE_LAYOUT = { paddingLeft = 4, paddingRight = 4, startY = 6 }
local PAGE_TEXT_FONT = id.Font.MUSEO_SANS_15PT_REGULAR -- PrettyUI's text font

local pageView = nil
local pageStatus = nil -- the page's status lines while the page exists, by name (a node's is its key)

-- Returns the width of a node name's column: the widest name, measured, plus a gap.
local function nodeColumnWidth()
    local font, widest = config.Font.FromID(PAGE_TEXT_FONT), 0
    for _, node in ipairs(ForestFeatures.nodesInRotation) do
        widest = math.max(widest, font:GetStringWidth(node.name))
    end
    return widest + 8
end

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

local function onInventoryUpdated(event)
    if event.inv.id == config.Inv.INV.id then showDailyStatus() end
end
local function followBackpack()
    if Forest.taskCountsItems() then
        Event.InventoryUpdated.Subscribe(SUBSCRIPTION, onInventoryUpdated)
    else
        Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
    end
end
local function onDailyVariable(event)
    local claimsBase, questBase, tasksDoneBase = Forest.dailyVariableIDs()
    local sent = event.var.id
    if sent == questBase then followBackpack() end
    if sent == claimsBase or sent == questBase or sent == tasksDoneBase then showDailyStatus() end
end

-- Destroys the page, and stops following the day's status.
function RibbonPage.close()
    Event.VarTransmit.Unsubscribe(SUBSCRIPTION)
    Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
    if pageView ~= nil then pcall(function() pageView:Destroy() end) end
    pageView, pageStatus = nil, nil
end

-- Builds the page on the hub's layer, replacing the last one built. actions: openMap, openScout and openSettings.
function RibbonPage.build(pluginLayer, actions)
    RibbonPage.close()
    pageView = prettyui.SimpleView.new(pluginLayer, {
        categoryID = "auto", width = pluginLayer.width, height = pluginLayer.height, scrollable = true,
        layout = PAGE_LAYOUT,
    })
    pageView:AddTitle("Nemi Mapper")
    pageView:AddText("A window open before you enter the forest stays open after you leave it.")
    pageView:AddSimpleButton("Open the map", actions.openMap)
    pageView:AddSimpleButton("Open the scout window", actions.openScout)
    pageView:AddSimpleButton("Open the settings", actions.openSettings)
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
    Event.VarTransmit.Subscribe(SUBSCRIPTION, onDailyVariable)
    followBackpack()
end

return RibbonPage
