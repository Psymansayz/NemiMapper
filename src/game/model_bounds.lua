-- The box round a node's, key's, door's, the Pahtli plant's or a highlighted NPC's model, from the saved boxes
-- (src/data/model_bounds.lua), for the world's highlights.

local Data = require("src/data/model_bounds")
local ForestFeatures = require("src/data/forest_features")

local ModelBounds = {}

local HALF_TILE = 256 -- fine units

-- feature -> its box, unturned; the data's table is emptied once converted, as require keeps it for good.
-- Every location of a feature takes the box of its base location; an NPC's is from the middle of its tile.
local boxOf = {}
local function listBoxes(feature)
    boxOf[feature] = Data[feature.addedAs or ""] or Data[(feature.locations or feature.npcs)[1]]
end
for _, node in ipairs(ForestFeatures.nodes) do listBoxes(node) end
for _, task in ipairs(ForestFeatures.trinksTasks) do listBoxes(task) end
for _, toolPair in ipairs(ForestFeatures.tools) do
    listBoxes(toolPair.source)
    listBoxes(toolPair.barrier)
end
for name in pairs(Data) do Data[name] = nil end

-- Returns the box round the model of a location of feature turned rotation quarter turns, as the highlight takes it:
-- { x, X, z, Z, height } in fine units from the centre of its south-west tile. width and length are its size in tiles
-- as turned; an NPC is unturned and 1 by 1.
function ModelBounds.of(feature, rotation, width, length)
    local box = boxOf[feature]
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
