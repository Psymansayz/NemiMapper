-- Which puzzle tools the player has. An item tool counts in the backpack or worn (a burning log goes straight
-- to an empty hand). An NPC tool counts once the info box or a dialogue says it is following the player.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local Sets = require("src/game/sets")
local GameIds = require("src/game/game_ids")

local ToolsHeld = {}

-- A tool lost next to its barrier was used on it. The barrier takes a moment to open, so the tool still counts
-- until then; otherwise the routes would briefly turn away from the barrier.
local USED_BY = 2 -- tiles from the barrier's edge
local OPENING_TICKS = 8 -- about five seconds

local itemOfSourceKey, barrierOfSourceKey = {}, {}
for _, toolPair in ipairs(ForestFeatures.tools) do
    local sourceKey = toolPair.source.key
    barrierOfSourceKey[sourceKey] = toolPair.barrier
    if toolPair.toolItem ~= nil then itemOfSourceKey[sourceKey] = GameIds.resolve("Obj", toolPair.toolItem) end
end

local carriedBefore = {} -- source key -> true: tools carried at the last refresh
local usedAt = {} -- source key -> the server tick its tool was used on its barrier

-- Returns the barrier of sourceKey's puzzle if it still stands near the player.
local function barrierNear(sourceKey)
    local barrier, playerTile = barrierOfSourceKey[sourceKey], Forest.playerTile
    if Forest.doorsGone[barrier.key] then return nil end
    for _, entry in ipairs(Forest.found) do
        if entry.feature == barrier and math.abs(entry.x - playerTile.x - 0.5) - entry.width / 2 <= USED_BY
            and math.abs(entry.z - playerTile.z - 0.5) - entry.length / 2 <= USED_BY then
            return entry
        end
    end
    return nil
end

-- Returns the tools in the backpack, worn or following, by source key.
local function toolsCarried()
    local itemsHeld, held = Forest.itemsHeld(), {}
    for sourceKey, itemID in pairs(itemOfSourceKey) do
        if itemsHeld[itemID] then held[sourceKey] = true end
    end
    for sourceKey in pairs(Forest.following) do held[sourceKey] = true end
    return held
end

-- The source keys of the puzzles whose tool the player has (source key -> true), counting a tool still opening its
-- barrier, as at the last refresh.
ToolsHeld.held = {}

-- Works out the tools held again, on each step, inventory change and forest change, noting the tools just lost
-- beside their barriers. Returns whether they changed.
function ToolsHeld.refresh()
    local carried, held = toolsCarried(), {}
    for sourceKey in pairs(carriedBefore) do
        if not carried[sourceKey] and barrierNear(sourceKey) then usedAt[sourceKey] = Forest.ticks end
    end
    carriedBefore = carried
    for sourceKey in pairs(carried) do held[sourceKey] = true end
    for sourceKey, tick in pairs(usedAt) do
        local barrier = barrierOfSourceKey[sourceKey]
        if not Forest.doorsGone[barrier.key] and Forest.ticks - tick <= OPENING_TICKS then held[sourceKey] = true end
    end
    if Sets.same(held, ToolsHeld.held) then return false end
    ToolsHeld.held = held
    return true
end

-- Forgets the tools held and used, on leaving the forest.
function ToolsHeld.forget()
    carriedBefore, usedAt, ToolsHeld.held = {}, {}, {}
end

return ToolsHeld
