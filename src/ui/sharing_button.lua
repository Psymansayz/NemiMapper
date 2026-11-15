-- The button on the map window's title bar that turns map sharing mode on and off, drawn with the game's chat
-- filter icon and dim while the mode is off. PrettyUI's title drag strip would take its clicks inside the window, so
-- the button sits beside the window in the plugin layer, and PrettyUI keeps it over the title bar as an overlay
-- (placed again after a drag, shown and hidden with the window).

local GameIds = require("src/game/game_ids")
local Settings = require("src/data/settings")

local SharingButton = {}
SharingButton.__index = SharingButton

local SPRITE = GameIds.resolve("Sprite", "RS3_ICON_LOCAL_CHAT_FILTER")
local SIZE = 20 -- PrettyUI's close button's size
local LEFT, TOP = 8, 6 -- from the window's corner, like the close button's
local OFF_ALPHA = 0.45
local RAISE_SUBSCRIPTION = "nemi_mapper_sharing_raise"

local raised = nil -- the button to raise on the next frame

local function raise()
    Event.Draw.Unsubscribe(RAISE_SUBSCRIPTION)
    if raised ~= nil then raised.sprite:MoveToFront() end
    raised = nil
end

-- Adds the button beside a PrettyUI window, or returns nil if the game lacks the icon.
-- isShown says whether the window is shown, and onToggle is called on a click.
function SharingButton.add(window, pluginLayer, isShown, onToggle)
    if SPRITE == nil then return nil end
    local sprite = ui.Sprite.new(pluginLayer)
    sprite.spriteID = SPRITE
    -- A plugin's component takes no clicks until enabled, as well as not clickthrough.
    sprite.clickthrough = false
    sprite.enabled = true
    sprite:SetSize(SIZE, SIZE)
    sprite:Subscribe(ui.Hook.ONCLICK, function()
        onToggle()
        return true
    end)
    local button = setmetatable({ sprite = sprite, window = window }, SharingButton)
    button:show()
    -- PrettyUI places its overlays on every resize step and show, so the position is written only when it moves.
    local placedX, placedY = nil, nil
    local function place()
        local x, y = math.floor(window.root.x) + LEFT, math.floor(window.root.y) + TOP
        if x == placedX and y == placedY then return end
        placedX, placedY = x, y
        sprite:SetPos(x, y)
    end
    window:_RegisterOverlay(sprite, isShown, place)
    place()
    -- A title click raises the drag strip over the overlay.
    -- PrettyUI's click handler turns the resize handle off first, so a one-frame raise of the button is hooked on that.
    if window.resize ~= nil then
        local setEnabled = window.resize.SetEnabled
        window.resize.SetEnabled = function(resize, enabled)
            setEnabled(resize, enabled)
            if not enabled then
                raised = button
                Event.Draw.Subscribe(RAISE_SUBSCRIPTION, raise)
            end
        end
    end
    return button
end

-- Shows the button bright while map sharing mode is on, and dim while off.
function SharingButton:show()
    local alpha = Settings.mapSharingMode and 1 or OFF_ALPHA
    if self.alpha ~= alpha then
        self.alpha = alpha
        self.sprite.alpha = alpha
    end
end

-- Hides the button with the window, which PrettyUI shows again with it.
function SharingButton:hide()
    self.sprite.hidden = true
end

function SharingButton:destroy()
    if raised == self then raise() end
    self.window:_UnregisterOverlay(self.sprite)
    self.sprite:Destroy()
end

return SharingButton
