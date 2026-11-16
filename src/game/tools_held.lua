-- Which puzzle tools the player has. An item tool counts in the backpack or worn (a burning log goes straight
-- to an empty hand). An NPC tool  counts once the info box or a dialogue says it is following the player. 

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
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

local heldBefore = {} -- source key -> true: tools held when last asked
local usedAt = {} -- source key -> the server tick its tool was used on its barrier

-- Returns the barrier of sourceKey's puzzle if it still stands near playerTile.
local function barrierNear(sourceKey, playerTile)
    local barrier = barrierOfSourceKey[sourceKey]
    if Forest.doorsGone[barrier.key] then return nil end
    for _, entry in ipairs(Forest.found) do
        if entry.feature == barrier and math.abs(entry.x - playerTile.x - 0.5) - entry.width / 2 <= USED_BY
            and math.abs(entry.z - playerTile.z - 0.5) - entry.length / 2 <= USED_BY then
            return entry
        end
    end
    return nil
end

-- Adds to held the tools just used on a barrier that has not opened yet.
local function keepToolsBeingUsed(held, playerTile)
    for sourceKey in pairs(heldBefore) do
        if not held[sourceKey] and barrierNear(sourceKey, playerTile) then usedAt[sourceKey] = Forest.ticks end
    end
    local heldNow = {}
    for sourceKey in pairs(held) do heldNow[sourceKey] = true end
    heldBefore = heldNow
    for sourceKey, tick in pairs(usedAt) do
        local barrier = barrierOfSourceKey[sourceKey]
        if Forest.doorsGone[barrier.key] or Forest.ticks - tick > OPENING_TICKS then
            usedAt[sourceKey] = nil
        else
            held[sourceKey] = true
        end
    end
end

-- Returns the source keys of the puzzles whose tool the player has (source key -> true); playerTile: { x, z }.
function ToolsHeld.sourceKeys(playerTile)
    local itemsHeld, held = Forest.itemsHeld(), {}
    for sourceKey, itemID in pairs(itemOfSourceKey) do
        if itemsHeld[itemID] then held[sourceKey] = true end
    end
    for sourceKey in pairs(Forest.following) do held[sourceKey] = true end
    keepToolsBeingUsed(held, playerTile)
    return held
end

-- Forgets the tools held and used, on leaving the forest.
function ToolsHeld.forget()
    heldBefore, usedAt = {}, {}
end

return ToolsHeld
