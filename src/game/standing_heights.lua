-- The height of the tree or plant on each tile of a zone, 0 where nothing stands. The client does not list
-- the trees as locations (static scenery is merged for drawing), but the ground height with
-- HeightOffsetType.LOCATION includes them. Far from the player the client drops small scenery and swaps tree
-- models, so a distant read is partial: enough to tell how the zone was turned, but not which tiles are
-- walkable. Those come from the template's data.

local StandingHeights = {}

local ZONE_SIZE = 8
local FINE_UNITS_PER_TILE = 512
local TILE_MIDDLE = FINE_UNITS_PER_TILE // 2

-- Returns the 64 heights of the zone whose south-west tile is (zoneX, zoneZ), south row first, each row west to east,
-- or nil when nothing stands anywhere: the zone is not loaded yet, or is open ground.
function StandingHeights.read(level, zoneX, zoneZ)
    local standing, anyStanding = {}, false
    for z = zoneZ, zoneZ + ZONE_SIZE - 1 do
        for x = zoneX, zoneX + ZONE_SIZE - 1 do
            local fineX, fineZ = x * FINE_UNITS_PER_TILE + TILE_MIDDLE, z * FINE_UNITS_PER_TILE + TILE_MIDDLE
            local ground = World.GetGroundHeight(level, fineX, fineZ, HeightOffsetType.NONE)
            local withLocation = World.GetGroundHeight(level, fineX, fineZ, HeightOffsetType.LOCATION)
            local height = withLocation - ground
            standing[#standing + 1] = height
            anyStanding = anyStanding or height > 0
        end
    end
    return anyStanding and standing or nil
end

return StandingHeights
