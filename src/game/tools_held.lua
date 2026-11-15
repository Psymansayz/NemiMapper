-- Which puzzle tools the player has. An item tool counts in the backpack or worn (a burning log goes straight
-- to an empty hand). An NPC tool (the lightning, the lost goebie) counts once the info box or a dialogue says it
-- follows, or, for one that follows whoever talks to it, once its name heads a dialogue line beside the player
-- (Forest.following).
-- For an NPC with no known message, being next to the player counts instead, though that also counts walking past one.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local GameIds = require("src/game/game_ids")

local ToolsHeld = {}

local FOLLOWING_DISTANCE = 4 -- tiles
-- A tool lost next to its barrier was used on it. The barrier takes a moment to open, so the tool still counts
-- until then; otherwise the routes would briefly turn away from the barrier.
local USED_BY = 2 -- tiles from the barrier's edge
local OPENING_TICKS = 8 -- about five seconds

local itemOfSourceKey, npcOfSourceKey, barrierOfSourceKey = {}, {}, {}
local hasFollowMessage = {} -- source key -> true for an NPC tool that says when it follows
for _, toolPair in ipairs(ForestFeatures.tools) do
    local sourceKey = toolPair.source.key
    barrierOfSourceKey[sourceKey] = toolPair.barrier
    if toolPair.toolItem ~= nil then itemOfSourceKey[sourceKey] = GameIds.resolve("Obj", toolPair.toolItem) end
    if toolPair.source.npcs ~= nil then
        for _, name in ipairs(toolPair.source.npcs) do npcOfSourceKey[sourceKey] = GameIds.resolve("NPC", name) end
    end
    if toolPair.followMessages ~= nil then hasFollowMessage[sourceKey] = true end
end

-- Returns the barrier of sourceKey's puzzle if it still stands near playerTile, or nil.
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
    for sourceKey in pairs(Forest.keysHeldBefore) do
        if not held[sourceKey] and barrierNear(sourceKey, playerTile) then
            Forest.keysUsedAt[sourceKey] = Forest.ticks
        end
    end
    local heldNow = {}
    for sourceKey in pairs(held) do heldNow[sourceKey] = true end
    Forest.keysHeldBefore = heldNow
    for sourceKey, usedAt in pairs(Forest.keysUsedAt) do
        local barrier = barrierOfSourceKey[sourceKey]
        if Forest.doorsGone[barrier.key] or Forest.ticks - usedAt > OPENING_TICKS then
            Forest.keysUsedAt[sourceKey] = nil
        else
            held[sourceKey] = true
        end
    end
end

-- The source keys of the puzzles whose tool the player has; playerTile: { x, z }. The map and the world's boxes
-- both ask on each step and inventory change, so the answer is kept while the tick, the tile, the items held and
-- the followers are the same.
local kept = {}
function ToolsHeld.sourceKeys(playerTile)
    local itemsHeld = Forest.itemsHeld()
    if kept.held ~= nil and kept.tick == Forest.ticks and kept.tile == playerTile and kept.items == itemsHeld
        and kept.following == Forest.followingVersion then
        return kept.held
    end
    local held = {}
    for sourceKey, itemID in pairs(itemOfSourceKey) do
        if itemsHeld[itemID] then held[sourceKey] = true end
    end
    for sourceKey, npcID in pairs(npcOfSourceKey) do
        if Forest.following[sourceKey] then
            held[sourceKey] = true
        elseif not hasFollowMessage[sourceKey] then
            for _, npcEntity in ipairs(NPCList.ByConfigID(npcID)) do
                local coord = npcEntity.coordGrid
                if math.abs(coord.x - playerTile.x) <= FOLLOWING_DISTANCE
                    and math.abs(coord.z - playerTile.z) <= FOLLOWING_DISTANCE then
                    held[sourceKey] = true
                end
            end
        end
    end
    keepToolsBeingUsed(held, playerTile)
    kept.held, kept.tick, kept.tile, kept.items = held, Forest.ticks, playerTile, itemsHeld
    kept.following = Forest.followingVersion
    return held
end

-- Drops the kept answer on leaving the forest.
function ToolsHeld.forget()
    kept = {}
end

return ToolsHeld
