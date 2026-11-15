-- The box round a node's, key's, door's or the Pahtli plant's model, from the saved boxes (src/data/model_bounds.lua),
-- for the world's highlights. The game's model bounds are not read: a far model is not loaded, and every copy of a
-- location has the same box, turned with it.

local Data = require("src/data/model_bounds")
local GameIds = require("src/game/game_ids")

local ModelBounds = {}

local HALF_TILE = 256 -- fine units

-- location id -> its box, unturned; the data's table is emptied once converted, as require keeps it for good
local boxOf = {}
for name, box in pairs(Data) do
    local locID = GameIds.resolve("Loc", name)
    if locID ~= nil then boxOf[locID] = box end
end
for name in pairs(Data) do Data[name] = nil end

-- Returns the box round the model of location locID turned rotation quarter turns, as the highlight takes it:
-- { x, X, z, Z, height } in fine units from the centre of its south-west tile, or nil for a location with no saved
-- box. width and length are its size in tiles as turned.
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
