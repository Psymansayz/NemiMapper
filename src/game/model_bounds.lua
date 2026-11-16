-- The box round a node's, key's, door's or the Pahtli plant's model, from the saved boxes (src/data/model_bounds.lua),
-- for the world's highlights.

local Data = require("src/data/model_bounds")
local ForestFeatures = require("src/data/forest_features")
local GameIds = require("src/game/game_ids")

local ModelBounds = {}

local HALF_TILE = 256 -- fine units

-- location id -> its box, unturned; the data's table is emptied once converted, as require keeps it for good.
-- Every location name of a feature takes the box of its base location..
local boxOf = {}
local function listBoxes(feature)
    local box = Data[feature.addedAs or ""] or Data[(feature.locations or {})[1] or ""]
    if box == nil then return end
    local names = {}
    for _, name in ipairs(feature.locations or {}) do names[#names + 1] = name end
    names[#names + 1] = feature.addedAs
    for _, name in ipairs(names) do
        local locID = GameIds.resolve("Loc", name)
        if locID ~= nil then boxOf[locID] = box end
    end
end
for _, node in ipairs(ForestFeatures.nodes) do listBoxes(node) end
for _, task in ipairs(ForestFeatures.trinksTasks) do listBoxes(task) end
for _, toolPair in ipairs(ForestFeatures.tools) do
    listBoxes(toolPair.source)
    listBoxes(toolPair.barrier)
end
for name in pairs(Data) do Data[name] = nil end

-- Returns the box round the model of location locID turned rotation quarter turns, as the highlight takes it:
-- { x, X, z, Z, height } in fine units from the centre of its south-west tile. width and length are its size in tiles
-- as turned.
function ModelBounds.of(locID, rotation, width, length)
    local box = boxOf[locID]
    if box == nil then return nil end
    local west, east, south, north = box[1], box[2], box[3], box[4]
    -- a quarter turn takes the box's south side to its west, as the game turns a location's model
    for _ = 1, rotation % 4 do
        west, east, south, north = south, north, -east, -west
    end
    -- the box is from the middle of the tiles it stands on, the highlight's from its south-west tile's centre
    local middleX, middleZ = (width - 1) * HALF_TILE, (length - 1) * HALF_TILE
    return { x = west + middleX, X = east + middleX, z = south + middleZ, Z = north + middleZ, height = box[5] }
end

return ModelBounds
