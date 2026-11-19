-- Dev-only probe: logs what the game holds in a Nemi Forest, to check the plugin's assumptions against.
-- Every line starts "[nemi_mapper] ". ForestProbe.logForest() prints:
--   WORLD|     region or not, map squares loaded, player tile, and the plugin's forest state
--   BACKPACK|  slot, id, config name
--   WORN|      the worn inventory's id (id.Inv.WORN), then slot, id, config name
--   TURNS|     quarter turns given to each zone by its standing heights, one row per line, south first
--   ZONELOC|   every forest location by zone: the zone's south-west tile and source, then the location's id,
--              config, tile within the zone (x east, z north), size, shape and rotation. Compared with the
--              template's, these show how each zone was turned.
--   HEIGHT|    per forest zone: south-west tile, source, ground height at each tile centre (south row first,
--              west to east), then what stands on each tile (HeightOffsetType.LOCATION minus ground), which
--              shows how the zone was turned. Ground heights differ from the template's (flat on level 0).
--   STANDING|  zones with nothing read standing on them yet (not loaded: too far away)
--   WALK|      tiles the player walked, so known to be walkable (every 24 tiles, and at the dump)
--   LOCTYPE|   each named location kind loaded: id, config, parent id and config, name, count, size, tiles,
--              how many are flagged hidden, and how many LocList.ByConfigID returns
--   LOCUNNAMED| unnamed location kinds as id:count
--   NPCTYPE|   each NPC kind in view: id, config, name, Attack op index (-1 if none), whether a familiar,
--              one entity's uid, count, tiles
--   FOUND|     what the plugin found: key, tile
-- ForestProbe.logTemplateSquare() logs the template's map square (stand in 65,10: "!tele 0,65,10"):
--   TEMPLATELOC| zone south-west tile, location id, config, tile within the zone, size, shape, rotation
--   TEMPLATEHEIGHT| the HEIGHT data for the template square; the source of src/data/template_standing.lua
--              and zone_walkability.lua (tools/make_template_standing.py)
-- Logged as they happen: EVENT| for region and world events; CHANGE| for each change to what the plugin found,
-- with ticks since the region was created (ForestProbe.logChange); and WALK| (ForestProbe.noteStep).
-- Each forest is also saved to the PersistentDB for the route tests (saveForest), logging SAVED| each time.
-- ForestProbe.logInterfaceComponents() logs what the open interfaces hold that the map could use:
--   UICOMPONENT| each static component whose name (id.Component) contains MINIMAP, COMPASS or WORLD, with its
--                sprite if it has one
--   UILABEL|     each text naming a world ("World 22"), and each bare number in interfaces whose names contain
--                FRIEND, WORLD, LOBBY or ESCAPE (one may be the player's world)
--   COMPASS|     the compass components (ring, face, needle): type, sprite, size, visibility. The map's compass
--                uses the COMPASS sprite, so these show what the game has if it draws nothing.

local Forest = require("src/game/forest")
local GameIds = require("src/game/game_ids")

local ForestProbe = {}

local LOG_PREFIX = "[nemi_mapper] "
local SUBSCRIPTION = "nemi_mapper_probe"
local TILES_LISTED = 10 -- per location or NPC kind
local UNNAMED_PER_LINE = 30
local INTERFACES_TRIED = 3000
local STATIC_IDS_TRIED = 3000 -- per interface, at most
local UNUSED_IDS_ENDING = 60 -- consecutive missing static ids that end an interface's scan
local COMPONENT_LINES = 300 -- most lines the scan prints

local regionCreatedAt = 0 -- Forest.ticks when the last region was created

local function log(tag, text)
    print(LOG_PREFIX .. tag .. "|" .. text)
end

-- Returns getValue() as text, or "?" if it fails.
-- The probe asks for fields and names that may not exist, hence pcall.
local function read(getValue)
    local succeeded, value = pcall(getValue)
    return succeeded and tostring(value) or "?"
end

local function tile(coord)
    if coord == nil then return "?" end -- an NPC entity can be given before it has a tile
    return coord.x .. "," .. coord.z
end

local function logWorld()
    local squares, bounds = World.GetMapSquareBounds(), Forest.bounds
    log("WORLD", "region=" .. tostring(World.IsRegion())
        .. "|squares=" .. read(function()
            return squares.x .. "," .. squares.y .. " " .. squares.width .. "x" .. squares.height
        end)
        .. "|player=" .. read(function()
            local coord = Player.GetEntity().coordGrid
            return coord.level .. "," .. tile(coord)
        end)
        .. "|inside=" .. tostring(Forest.isInside) .. "|searching=" .. tostring(Forest.isSearching)
        .. "|bounds=" .. (bounds and (bounds.minX .. "," .. bounds.minZ .. " " .. bounds.width .. "x" .. bounds.length)
            or "none")
        .. "|zones=" .. #Forest.zones)
end

-- Reads the worn inventory by its id, as src/game/forest.lua does.
local function logInventories()
    -- An empty slot holds an object with id -1.
    for slotIndex, slot in ipairs(Inventory.Find(config.Inv.INV.id):GetSlots()) do
        if slot.obj ~= nil and slot.obj.id >= 0 then
            log("BACKPACK", slotIndex .. "|" .. slot.obj.id .. "|" .. read(function() return slot.obj.configName end))
        end
    end
    local wornID = id.Inv.WORN
    log("WORN", "id.Inv.WORN=" .. tostring(wornID))
    if wornID < 0 then return end
    for slotIndex, slot in ipairs(Inventory.Find(wornID):GetSlots()) do
        if slot.obj ~= nil and slot.obj.id >= 0 then
            log("WORN", slotIndex .. "|" .. slot.obj.id .. "|" .. read(function() return slot.obj.configName end))
        end
    end
end

local function logTurns()
    local grid = Forest.grid
    if grid == nil then return end
    local rows = {}
    for index, zone in ipairs(Forest.zones) do
        rows[zone.z] = rows[zone.z] or {}
        rows[zone.z][zone.x] = grid.turns[index]
    end
    local rowKeys = {}
    for z in pairs(rows) do rowKeys[#rowKeys + 1] = z end
    table.sort(rowKeys)
    for _, z in ipairs(rowKeys) do
        local columnKeys, turns = {}, {}
        for x in pairs(rows[z]) do columnKeys[#columnKeys + 1] = x end
        table.sort(columnKeys)
        for _, x in ipairs(columnKeys) do turns[#turns + 1] = tostring(rows[z][x]) end
        log("TURNS", z .. "|" .. table.concat(turns, " "))
    end
end

local function logLocations()
    local kinds = {} -- "id/parent id" -> { id, count, tiles, name, text }
    for _, location in ipairs(LocList.All()) do
        local kindKey = location.configID .. "/" .. location.parentConfigID
        local kind = kinds[kindKey]
        if kind == nil then
            kind = {
                id = location.configID, count = 0, hidden = 0, tiles = {}, name = location.displayName or "",
                text = location.configID .. "|" .. read(function() return location.config.configName end)
                    .. "|" .. location.parentConfigID
                    .. "|" .. read(function() return location.parentConfig.configName end)
                    .. "|" .. tostring(location.displayName)
                    .. "|var=" .. read(function() return location.parentConfig.multiVar.configName end)
                    .. "|" .. location.width .. "x" .. location.length .. " shape=" .. tostring(location.shapeType)
                    .. " rotation=" .. tostring(location.rotationType),
            }
            kinds[kindKey] = kind
        end
        kind.count = kind.count + 1
        if location.isHidden then kind.hidden = kind.hidden + 1 end
        if #kind.tiles < TILES_LISTED then kind.tiles[#kind.tiles + 1] = tile(location.coordGrid) end
    end
    local named, unnamed = {}, {}
    for _, kind in pairs(kinds) do
        if kind.name ~= "" then named[#named + 1] = kind else unnamed[#unnamed + 1] = kind end
    end
    table.sort(named, function(first, second) return first.id < second.id end)
    table.sort(unnamed, function(first, second) return first.id < second.id end)
    for _, kind in ipairs(named) do
        log("LOCTYPE", kind.text .. "|count=" .. kind.count .. " hidden=" .. kind.hidden
            .. " byConfig=" .. read(function() return #LocList.ByConfigID(kind.id) end)
            .. "|" .. table.concat(kind.tiles, " "))
    end
    for first = 1, #unnamed, UNNAMED_PER_LINE do
        local line = {}
        for index = first, math.min(first + UNNAMED_PER_LINE - 1, #unnamed) do
            line[#line + 1] = unnamed[index].id .. ":" .. unnamed[index].count
        end
        log("LOCUNNAMED", table.concat(line, " "))
    end
end

local function logNpcs()
    local kinds = {}
    for _, npcEntity in ipairs(NPCList.All()) do
        local kind = kinds[npcEntity.configID]
        if kind == nil then
            kind = {
                id = npcEntity.configID, count = 0, tiles = {},
                text = npcEntity.configID .. "|" .. read(function() return npcEntity.config.configName end)
                    .. "|" .. tostring(npcEntity.displayName) .. "|attack="
                    .. read(function() return npcEntity.config.attackOpIndex end) .. " familiar="
                    .. read(function() return npcEntity.config.isFamiliar end) .. " uid=" .. tostring(npcEntity.uid),
            }
            kinds[npcEntity.configID] = kind
        end
        kind.count = kind.count + 1
        if #kind.tiles < TILES_LISTED then kind.tiles[#kind.tiles + 1] = tile(npcEntity.coordGrid) end
    end
    local ordered = {}
    for _, kind in pairs(kinds) do ordered[#ordered + 1] = kind end
    table.sort(ordered, function(first, second) return first.id < second.id end)
    for _, kind in ipairs(ordered) do
        log("NPCTYPE", kind.text .. "|count=" .. kind.count .. "|" .. table.concat(kind.tiles, " "))
    end
end

-- Scans the open interfaces' static components by name, and their texts (dynamic children included) for a world.
function ForestProbe.logInterfaceComponents()
    log("UISCAN", "begin")
    for _, name in ipairs({ "TOPLEVEL_V2_MINIMAP__COMPASS_CONTAINER", "TOPLEVEL_V2_COMPASS__COM_1",
        "TOPLEVEL_V2_COMPASS__COMPASS" }) do
        log("COMPASS", name .. "|" .. read(function()
            local component = ui.Interfaces:GetComponent(id.Component[name])
            return "type=" .. tostring(component.type) .. " sprite=" .. tostring(component.spriteID) .. " "
                .. component.width .. "x" .. component.height .. " visible=" .. tostring(component.visibleGlobal)
                .. " alpha=" .. tostring(component.alpha) .. " rotation=" .. tostring(component.rotationDegrees)
        end))
    end
    local linesLeft = COMPONENT_LINES
    local function logComponent(component, name, isStatic)
        if linesLeft <= 0 then return end
        local isLabel = component.type == ui.ComponentType.LABEL
        local content = isLabel and read(function() return component.content end) or ""
        local isNamed = isStatic and (name:find("MINIMAP") or name:find("COMPASS") or name:find("WORLD"))
        local mayHoldWorld = name:find("FRIEND") or name:find("WORLD") or name:find("LOBBY") or name:find("ESCAPE")
        local showsWorld = content:find("[Ww]orld%s*%d") or content:find("RuneScape%s*%d")
            or (mayHoldWorld and content:find("^%s*%d%d?%d?%d?%s*$"))
        if not isNamed and not showsWorld then return end
        linesLeft = linesLeft - 1
        if component.type == ui.ComponentType.SPRITE then
            content = "sprite=" .. read(function() return component.spriteID end) .. " "
                .. read(function() return id.Sprite.FromID(component.spriteID) end)
        end
        log(showsWorld and "UILABEL" or "UICOMPONENT", name .. "|interface=" .. component.interfaceID
            .. "|static=" .. component.staticID .. "|dynamic=" .. component.categoryID .. "." .. component.dynamicID
            .. "|type=" .. tostring(component.type) .. "|" .. component.width .. "x" .. component.height
            .. " at " .. component.x .. "," .. component.y .. "|visible=" .. tostring(component.visibleGlobal)
            .. "|" .. content:sub(1, 80))
    end
    local interfacesOpen = 0
    for interfaceID = 0, INTERFACES_TRIED do
        if ui.Interfaces:GetInterface(interfaceID) ~= nil then
            interfacesOpen = interfacesOpen + 1
            local unusedInARow = 0
            for staticID = 0, STATIC_IDS_TRIED do
                local component = ui.Interfaces:GetComponent(interfaceID, staticID)
                if component == nil then
                    unusedInARow = unusedInARow + 1
                    if unusedInARow >= UNUSED_IDS_ENDING then break end
                else
                    unusedInARow = 0
                    local name = read(function() return id.Component.FromID((interfaceID << 16) | staticID) end)
                    logComponent(component, name, true)
                    -- Only layout components have this method.
                    pcall(function()
                        component:IterateDynamicComponents(function(child)
                            logComponent(child, name .. " (dynamic)", false)
                            return false
                        end)
                    end)
                end
            end
        end
    end
    log("UISCAN", "end|interfaces open=" .. interfacesOpen .. "|lines left=" .. linesLeft)
end

-- Logs every location in the map square (squareX, squareZ), by zone.
-- zoneSource(zoneX, zoneZ) gives a zone's source; nil omits it.
local function logLocationsByZone(tag, squareX, squareZ, zoneSource)
    local lines = {}
    for _, location in ipairs(LocList.All()) do
        local coord = location.coordGrid
        if coord.x // 64 == squareX and coord.z // 64 == squareZ then
            local zoneX, zoneZ = coord.x // 8 * 8, coord.z // 8 * 8
            local source = zoneSource and zoneSource(zoneX, zoneZ) or ""
            lines[#lines + 1] = zoneX .. "," .. zoneZ .. "|" .. source .. "|" .. location.configID .. "|"
                .. read(function() return location.config.configName end) .. "|" .. (coord.x - zoneX) .. ","
                .. (coord.z - zoneZ) .. "|" .. location.width .. "x" .. location.length .. "|"
                .. tostring(location.shapeType) .. "|" .. tostring(location.rotationType)
        end
    end
    table.sort(lines)
    for _, line in ipairs(lines) do log(tag, line) end
    log(tag, "end|" .. #lines .. " locations in map square " .. squareX .. "," .. squareZ)
end

-- Logs the heights of the zone at (zoneX, zoneZ) on one line: the ground at each tile centre, then
-- what standing locations add.
-- A tile is 512 fine units.
-- The docs place the offset enum under World, but it is the global HeightOffsetType.
local function logHeights(tag, level, zoneX, zoneZ, source)
    local grounds, standing = {}, {}
    for z = zoneZ, zoneZ + 7 do
        for x = zoneX, zoneX + 7 do
            local fineX, fineZ = x * 512 + 256, z * 512 + 256
            local ground = World.GetGroundHeight(level, fineX, fineZ, HeightOffsetType.NONE)
            local withLocation = World.GetGroundHeight(level, fineX, fineZ, HeightOffsetType.LOCATION)
            grounds[#grounds + 1] = ground
            standing[#standing + 1] = withLocation - ground
        end
    end
    log(tag, zoneX .. "," .. zoneZ .. "|" .. source .. "|" .. table.concat(grounds, " ") .. "|"
        .. table.concat(standing, " "))
end

-- Logs the map square the player stands in (65,10 for the forest template).
function ForestProbe.logTemplateSquare()
    local coord = Player.GetEntity().coordGrid
    log("TEMPLATELOC", "begin|player=" .. coord.level .. "," .. tile(coord))
    logLocationsByZone("TEMPLATELOC", coord.x // 64, coord.z // 64)
    local squareX, squareZ = coord.x // 64 * 64, coord.z // 64 * 64
    local succeeded, problem = pcall(function()
        for zoneZ = squareZ, squareZ + 56, 8 do
            for zoneX = squareX, squareX + 56, 8 do logHeights("TEMPLATEHEIGHT", coord.level, zoneX, zoneZ, "") end
        end
    end)
    log("TEMPLATEHEIGHT", succeeded and "end" or ("failed|" .. tostring(problem)))
end

-- Tiles walked since the last WALK line: known walkable, to check the grid against.
local walked, lastWalkedTile = {}, nil
local WALKED_PER_LINE = 24

local function flushWalked()
    if #walked == 0 then return end
    log("WALK", table.concat(walked, " "))
    walked = {}
end

local saveForest

-- Called from Forest.onMoved while in the forest.
-- Zones' standing heights are read as the player walks, so the forest is saved again when more are known.
function ForestProbe.noteStep()
    saveForest()
    local tileText = tile(Forest.playerTile)
    if tileText == lastWalkedTile then return end
    lastWalkedTile = tileText
    walked[#walked + 1] = tileText
    if #walked >= WALKED_PER_LINE then flushWalked() end
end

function ForestProbe.logForest()
    log("PROBE", "begin")
    logWorld()
    logInventories()
    for _, entry in ipairs(Forest.found) do
        log("FOUND", entry.feature.key .. "|" .. entry.x .. "," .. entry.z)
    end
    logTurns()
    logLocations()
    if Forest.bounds ~= nil then
        local sourceOf = {}
        for _, zone in ipairs(Forest.zones) do
            sourceOf[zone.x .. "," .. zone.z] = zone.sourceX .. "." .. zone.sourceZ
        end
        local squaresLogged = {}
        for _, zone in ipairs(Forest.zones) do
            local squareKey = (zone.x // 64) .. "," .. (zone.z // 64)
            if not squaresLogged[squareKey] then
                squaresLogged[squareKey] = true
                logLocationsByZone("ZONELOC", zone.x // 64, zone.z // 64, function(zoneX, zoneZ)
                    return sourceOf[zoneX .. "," .. zoneZ] or "-"
                end)
            end
        end
        local level = Player.GetEntity().coordGrid.level
        local succeeded, problem = pcall(function()
            for _, zone in ipairs(Forest.zones) do
                logHeights("HEIGHT", level, zone.x, zone.z, zone.sourceX .. "." .. zone.sourceZ)
            end
        end)
        log("HEIGHT", succeeded and "end" or ("failed|" .. tostring(problem)))
        local unread = {}
        for _, zone in ipairs(Forest.zones) do
            local zoneKey = zone.x .. "," .. zone.z
            if Forest.standingByZone[zoneKey] == nil then unread[#unread + 1] = zoneKey end
        end
        log("STANDING", "zones not read yet: " .. #unread .. "|" .. table.concat(unread, " "))
    end
    flushWalked()
    logNpcs()
    log("PROBE", "end")
end

-- Saves the forest for the route tests as the PersistentDB string "forest|<layout hash>", which
-- tools/export_forests.py copies to tools/forests/.
-- It is in the pasted log's line format, newest first: HEIGHT|end, each zone's standing heights as the plugin read
-- them (0 for none), what was found, and the entry tile as WORLD's player.
-- It is saved again under the same key whenever more is known, so the last save holds the most.
local saved = { zones = nil, key = nil, known = nil }
function saveForest() -- declared above ForestProbe.noteStep
    if Forest.bounds == nil or Forest.entryTile == nil then return end
    local standingCount = 0
    for _, zone in ipairs(Forest.zones) do
        if Forest.standingByZone[zone.x .. "," .. zone.z] ~= nil then standingCount = standingCount + 1 end
    end
    local known = #Forest.found .. "|" .. standingCount
    if saved.zones == Forest.zones and saved.known == known then return end
    if saved.zones ~= Forest.zones then
        -- Instances reuse the same tiles, so a forest is told apart by its layout.
        local hash = 0
        for _, zone in ipairs(Forest.zones) do
            for character in (zone.sourceX .. "." .. zone.sourceZ .. ";"):gmatch(".") do
                hash = (hash * 31 + character:byte()) % 4294967296
            end
        end
        saved.zones, saved.key = Forest.zones, string.format("forest|%08x", hash)
    end
    saved.known = known
    local lines = { LOG_PREFIX .. "HEIGHT|end" }
    for _, zone in ipairs(Forest.zones) do
        local standing = Forest.standingByZone[zone.x .. "," .. zone.z]
        lines[#lines + 1] = LOG_PREFIX .. "HEIGHT|" .. zone.x .. "," .. zone.z .. "|" .. zone.sourceX .. "."
            .. zone.sourceZ .. "|0|" .. (standing and table.concat(standing, " ") or "0")
    end
    for _, entry in ipairs(Forest.found) do
        lines[#lines + 1] = LOG_PREFIX .. "FOUND|" .. entry.feature.key .. "|" .. entry.x .. "," .. entry.z
    end
    lines[#lines + 1] = LOG_PREFIX .. "WORLD|player=0," .. Forest.entryTile.x .. "," .. Forest.entryTile.z
        .. "|zones=" .. #Forest.zones .. "|standing=" .. standingCount .. "|found=" .. #Forest.found
    PersistentDB:SetString(saved.key, table.concat(lines, "\n"))
    log("SAVED", saved.key .. "|standing=" .. standingCount .. "|found=" .. #Forest.found)
end

-- Called when what the plugin found changes or its search ends.
function ForestProbe.logChange()
    local kinds, total = Forest.nodeCounts()
    log("CHANGE", "tick=" .. (Forest.ticks - regionCreatedAt) .. "|found=" .. #Forest.found .. "|nodes=" .. kinds
        .. "/" .. total .. "|searching=" .. tostring(Forest.isSearching)
        .. "|missed=" .. #Forest.nodesMissedByRotation())
    saveForest()
end

function ForestProbe.start()
    Event.RegionCreated.Subscribe(SUBSCRIPTION, function(event)
        regionCreatedAt = Forest.ticks
        log("EVENT", "RegionCreated|squares=" .. event.mapSquareMinX .. "," .. event.mapSquareMinZ .. ".."
            .. event.mapSquareMaxX .. "," .. event.mapSquareMaxZ .. "|corner=" .. tile(event.regionGridCorner)
            .. "|size=" .. event.regionGridWidth .. "x" .. event.regionGridLength)
    end)
    Event.WorldCreated.Subscribe(SUBSCRIPTION, function(event)
        log("EVENT", "WorldCreated|squares=" .. event.mapSquareMinX .. "," .. event.mapSquareMinZ .. ".."
            .. event.mapSquareMaxX .. "," .. event.mapSquareMaxZ)
    end)
end

function ForestProbe.stop()
    Event.RegionCreated.Unsubscribe(SUBSCRIPTION)
    Event.WorldCreated.Unsubscribe(SUBSCRIPTION)
end

return ForestProbe
