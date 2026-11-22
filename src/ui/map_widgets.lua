-- The map window's building blocks, shared by the map, its legends and their windows: texts, sprites, cells,
-- outlines and buttons in the frame's colours and fonts.

local IconSizes = require("src/data/icon_sizes")
local ComponentWrites = require("src/ui/component_writes")
local StatusText = require("src/ui/status_text")

local MapWidgets = {}

local setBox, setHidden = ComponentWrites.setBox, ComponentWrites.setHidden

MapWidgets.EDGE = 8 -- border around and between the frame's parts
MapWidgets.DEFAULT_MAP_SIZE, MapWidgets.MINIMUM_MAP_SIZE = 520, 260
MapWidgets.TEXT_HEIGHT = 20
MapWidgets.LEGEND_LINE_INSET = 6 -- inset of the legend's dividers, NAVIGATE and the red covers
MapWidgets.FRAME_COLOUR = 0x09161FFF
MapWidgets.FRAME_LINE_COLOUR = 0x2B3C48FF
MapWidgets.TEXT_COLOUR = 0xFFFFFFFF
MapWidgets.HEADING_COLOUR = 0xE9B93EFF
MapWidgets.TEXT_FONT = id.Font.MUSEO_SANS_13PT_BOLD
MapWidgets.SMALL_FONT = id.Font.MUSEO_SANS_11PT_REGULAR
MapWidgets.KEY_UNSEEN_TEXT = "Walk to find" -- a key's NPC only reaches the client near the player
-- Simplified legends show the game's paths icon on NAVIGATE and SOLVE instead of their words.
local PATHS_ICON_SPRITE = id.Sprite.RS3_ICON_MENU_PATHS_0
local BUTTON_COLOUR = 0x1B4A6BFF -- in the frame's blues
local BUTTON_DOWN_COLOUR = 0x2F7FB3FF
local BUTTON_OVER_COLOUR = 0x245E88FF
local HINT_COLOUR = StatusText.GOLD -- "Walk to find"
local HOVER_COLOUR = 0xFFFFFFFF -- outline of a clickable row or pair under the mouse
local DIMMED_ALPHA = 0.3 -- legend entries absent from the forest, and finished puzzles

-- Returns a picture by its file name, without the extension.
function MapWidgets.picture(name)
    return Plugin.resources[name]
end

function MapWidgets.create(componentType, parent)
    local component = componentType.new(parent)
    component.clickthrough = true
    return component
end

function MapWidgets.addText(parent, font, colour, alignHorizontal, content)
    local text = MapWidgets.create(ui.Text, parent)
    text.font = font
    text.rgba = colour
    text.isShadowed = true
    text.maxLines = 1
    text.alignHorizontal = alignHorizontal
    text.alignVertical = ui.AlignMode.CENTRE
    text.content = content or ""
    return text
end

-- Adds the game sprite spriteID to parent.
function MapWidgets.addGameSprite(parent, spriteID)
    local sprite = MapWidgets.create(ui.Sprite, parent)
    sprite.spriteID = spriteID
    return sprite
end

function MapWidgets.addIcon(parent, key)
    local icon = MapWidgets.create(ui.Sprite, parent)
    icon.sprite = MapWidgets.picture(key)
    return icon
end

-- Places a feature's icon (key) as large as fits the box, at most largestScale times its size, centred in it.
function MapWidgets.setIconIn(icon, key, left, top, width, height, largestScale)
    local size = IconSizes[key]
    local scale = math.min(width / size.width, height / size.height, largestScale)
    local iconWidth, iconHeight = size.width * scale, size.height * scale
    setBox(icon, left + (width - iconWidth) / 2, top + (height - iconHeight) / 2, iconWidth, iconHeight)
end

local textWidths = {} -- texts -> font id -> the widest of them, measured once
local function widestText(texts, fontID)
    local widths = textWidths[texts]
    if widths == nil then
        widths = {}
        textWidths[texts] = widths
    end
    if widths[fontID] == nil then
        local font, widest = config.Font.FromID(fontID), 0
        for _, text in ipairs(texts) do widest = math.max(widest, font:GetStringWidth(text)) end
        widths[fontID] = widest
    end
    return widths[fontID]
end

-- Returns the largest of fonts ({ id, size }, largest first), no larger than largestSize, that every one of texts
-- fits in width with, or the smallest.
function MapWidgets.fittingFont(fonts, texts, width, largestSize)
    for _, font in ipairs(fonts) do
        if (largestSize == nil or font.size <= largestSize) and widestText(texts, font.id) <= width then
            return font
        end
    end
    return fonts[#fonts]
end

function MapWidgets.setDimmed(isDimmed, ...)
    local alpha = isDimmed and DIMMED_ALPHA or 1
    for index = 1, select("#", ...) do
        local component = select(index, ...)
        if component ~= nil then component.alpha = alpha end
    end
end

-- Shows a legend row's or puzzle's label, writing its text and colour only when they change.
-- Writing the colour also writes its alpha, so the dimming is written again after it.
function MapWidgets.showLabel(label, holder, isHint, text, isDimmed)
    holder.labelStatus = holder.labelStatus or StatusText.new(label)
    local colour = isHint and HINT_COLOUR or MapWidgets.TEXT_COLOUR
    local colourChanged = holder.labelStatus.colour ~= colour
    StatusText.set(holder.labelStatus, text, colour)
    if colourChanged or holder.labelDimmed ~= isDimmed then
        holder.labelDimmed = isDimmed
        MapWidgets.setDimmed(isDimmed, label)
    end
end

-- Adds a legend entry's cell, its click target: a filled rectangle under the entry's icons, which pass clicks
-- through. A click calls onClick, unless cannotClick says a click there does nothing.
function MapWidgets.addCell(content, onClick, cannotClick)
    local cell = MapWidgets.create(ui.Rectangle, content)
    cell.fill = true
    cell.rgba = MapWidgets.FRAME_COLOUR
    cell.clickthrough = false
    cell:Subscribe(ui.Hook.ONCLICK, function()
        if not cannotClick() then onClick() end
        return true
    end)
    return cell
end

function MapWidgets.addOutline(content, colour)
    local outline = MapWidgets.create(ui.Rectangle, content)
    outline.fill = false
    outline.outlineThickness = 2
    outline.rgba = colour
    return outline
end

-- Adds a white outline over a cell under the mouse, unless cannotClick says a click there does nothing.
function MapWidgets.addHover(content, cell, cannotClick)
    local hover = MapWidgets.addOutline(content, HOVER_COLOUR)
    hover.hidden = true
    cell:Subscribe(ui.Hook.ONMOUSEOVER, function()
        hover.hidden = cannotClick()
        return true
    end)
    cell:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        hover.hidden = true
        return true
    end)
    return hover
end

-- Writes a button's colours only when they change.
function MapWidgets.showButton(button, isDown)
    local colour = isDown and BUTTON_DOWN_COLOUR or BUTTON_COLOUR
    if button.colour ~= colour then
        button.colour = colour
        button.cell.rgba = colour
    end
    if button.isDown ~= isDown then
        button.isDown = isDown
        button.text.rgba = isDown and MapWidgets.HEADING_COLOUR or MapWidgets.TEXT_COLOUR
    end
end

-- Adds a button in the frame's blues, brighter under the mouse and while pressed.
function MapWidgets.addButton(content, label, onClick)
    local button = { cell = MapWidgets.create(ui.Rectangle, content) }
    button.cell.fill = true
    button.cell.rgba = BUTTON_COLOUR
    button.cell.clickthrough = false
    button.cell:Subscribe(ui.Hook.ONCLICK, function() onClick() return true end)
    button.cell:Subscribe(ui.Hook.ONMOUSEOVER, function()
        if not button.isDown then
            button.colour = BUTTON_OVER_COLOUR
            button.cell.rgba = BUTTON_OVER_COLOUR
        end
        return true
    end)
    button.cell:Subscribe(ui.Hook.ONMOUSELEAVE, function() MapWidgets.showButton(button, button.isDown) return true end)
    button.text = MapWidgets.addText(content, MapWidgets.TEXT_FONT, MapWidgets.TEXT_COLOUR, ui.AlignMode.CENTRE, label)
    button.icon = MapWidgets.addGameSprite(content, PATHS_ICON_SPRITE)
    return button
end

function MapWidgets.setButtonBox(button, left, top, width, height)
    setBox(button.cell, left, top, width, height)
    setBox(button.text, left, top, width, height)
    local size = math.max(1, math.min(width, height) - 8)
    setBox(button.icon, left + (width - size) / 2, top + (height - size) / 2, size, size)
end

-- Shows a button, or hides it, with its words, or the paths icon in place of them when simple.
function MapWidgets.showButtonParts(button, isShown, simple)
    setHidden(button.cell, not isShown)
    setHidden(button.text, not isShown or simple)
    setHidden(button.icon, not isShown or not simple)
end

return MapWidgets
