-- The forest's walkable tiles: each zone's walkable tiles from its template, turned the way the game turned the
-- zone. The game does not say how it turned a zone, so the zones' standing heights are compared against the
-- template's to determine how it was rotated.

local ZoneWalkability = require("src/data/zone_walkability")
local TemplateStanding = require("src/data/template_standing")

local ForestGrid = {}

local ZONE_SIZE = 8 -- tiles
local ZONE_TILES = ZONE_SIZE * ZONE_SIZE


local Grid = {}
Grid.__index = Grid

-- The data leaves out a zone with no standing heights (such as the entrance).
function ForestGrid.hasStanding(sourceKey)
    return TemplateStanding[sourceKey] ~= nil
end

-- Where each of a zone's tiles goes when the zone is turned: turnedIndex[quarterTurns][index] is the index of the
-- tile at index (tile x, z at z * 8 + x + 1) once turned clockwise quarterTurns times, (x, z) -> (z, 7 - x) each.
local turnedIndex = {}
for quarterTurns = 0, 3 do
    local indexes = {}
    for z = 0, ZONE_SIZE - 1 do
        for x = 0, ZONE_SIZE - 1 do
            local turnedX, turnedZ = x, z
            for _ = 1, quarterTurns do turnedX, turnedZ = turnedZ, ZONE_SIZE - 1 - turnedX end
            indexes[z * ZONE_SIZE + x + 1] = turnedZ * ZONE_SIZE + turnedX + 1
        end
    end
    turnedIndex[quarterTurns] = indexes
end

-- Returns values, a zone's tile walkablility data turned clockwise quarterTurns times.
local function turnedTiles(values, quarterTurns)
    local turnedValues = {}
    for index, turned in ipairs(turnedIndex[quarterTurns]) do turnedValues[turned] = values[index] end
    return turnedValues
end

-- Returns the number of turns needed for a zone in the current forest to match it's template's orientation.
-- The forest replaces a few tiles (nodes, barriers) and a zone read from afar lacks small plants, so it
-- may not be a perfect match to the template.
local function turnsByStanding(sourceKey, standing)
    if standing == nil then return nil end
    local template = TemplateStanding[sourceKey]
    local bestTurns, bestAlike = {}, -1
    for quarterTurns = 0, 3 do
        local alike = 0
        for index, turned in ipairs(turnedIndex[quarterTurns]) do
            if template[index] == standing[turned] then alike = alike + 1 end
        end
        if alike > bestAlike then
            bestTurns, bestAlike = { quarterTurns }, alike
        elseif alike == bestAlike then
            bestTurns[#bestTurns + 1] = quarterTurns
        end
    end
    return bestTurns
end

-- parses the template's walkability data.
local function groundTiles(sourceKey)
    local rows, tiles = ZoneWalkability[sourceKey], {}
    for z = 0, ZONE_SIZE - 1 do
        local row = rows and rows[ZONE_SIZE - z]
        for x = 0, ZONE_SIZE - 1 do
            tiles[z * ZONE_SIZE + x + 1] = row ~= nil and row:byte(x + 1) == 46 -- "."
        end
    end
    return tiles
end

-- Cache of each template zone in every orientation.
local groundTurnsCache = {}
local function groundTurns(sourceKey)
    local template = groundTurnsCache[sourceKey]
    if template ~= nil then return template end
    local tiles = groundTiles(sourceKey)
    template = { ground = {}, groundKey = {}, turnMatters = false }
    for quarterTurns = 0, 3 do
        local turned = turnedTiles(tiles, quarterTurns)
        local ground = {}
        for tileIndex = 1, ZONE_TILES do
            if turned[tileIndex] then
                ground[#ground + 1], ground[#ground + 2] = (tileIndex - 1) % ZONE_SIZE, (tileIndex - 1) // ZONE_SIZE
            end
            if turned[tileIndex] ~= tiles[tileIndex] then template.turnMatters = true end
        end
        template.ground[quarterTurns], template.groundKey[quarterTurns] = ground, table.concat(ground, ",")
    end
    groundTurnsCache[sourceKey] = template
    return template
end

-- Returns whether the turns give a zone the same walkable tiles.
-- used for tie breaks when detecting rotation.
local function sameGround(template, turns)
    for _, quarterTurns in ipairs(turns) do
        if template.groundKey[quarterTurns] ~= template.groundKey[turns[1]] then return false end
    end
    return true
end

-- Returns the current forest's walkable tiles.
-- grid.settled indicates whether all zones have had their correct rotations identified.
function ForestGrid.build(zones, bounds, standingByZone, previous)
    local turnsOf, settled, tied = {}, true, {}
    for index, zone in ipairs(zones) do
        local zoneKey = zone.x .. "," .. zone.z
        local template = groundTurns(zone.templateKey)
        local turns = turnsByStanding(zone.templateKey, standingByZone[zoneKey])
        if template.turnMatters and (turns == nil or not sameGround(template, turns)) then
            settled = false
            if turns ~= nil then tied[zoneKey] = true end
        end
        turnsOf[index] = turns and turns[1] or 0
    end
    if previous ~= nil and previous.settled == settled then
        local same = true
        for index, turns in ipairs(turnsOf) do same = same and previous.turns[index] == turns end
        if same then
            previous.tiedZones = tied
            return previous -- return early if no zone has new information.
        end
    end
    local grid = setmetatable({
        minX = bounds.minX, minZ = bounds.minZ, width = bounds.width, length = bounds.length,
        walkable = {}, -- tile index -> true
        turns = turnsOf, -- zone index -> quarter turns
        settled = settled,
        tiedZones = tied,
    }, Grid)
    for index, zone in ipairs(zones) do
        local ground = groundTurns(zone.templateKey).ground[turnsOf[index]]
        for position = 1, #ground, 2 do
            grid.walkable[grid:index(zone.x + ground[position], zone.z + ground[position + 1])] = true
        end
    end
    return grid
end

-- Returns a tile's index in the grid.
function Grid:index(x, z)
    if x < self.minX or z < self.minZ or x >= self.minX + self.width or z >= self.minZ + self.length then return nil end
    return (z - self.minZ) * self.width + (x - self.minX) + 1
end

-- Returns the tile of an index.
function Grid:tile(index)
    local offset = index - 1
    return self.minX + offset % self.width, self.minZ + offset // self.width
end

-- Drops the template zones' turned tiles on leaving a forest.
-- The next grid makes them again from the data, which is why the walkability rows are kept.
function ForestGrid.forgetTemplates()
    groundTurnsCache = {}
end

return ForestGrid
