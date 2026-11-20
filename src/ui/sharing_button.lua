-- The button on the map window's title bar that turns map sharing mode on and off.

local Settings = require("src/data/settings")

local SharingButton = {}
SharingButton.__index = SharingButton

local SPRITE = id.Sprite.RS3_ICON_LOCAL_CHAT_FILTER
local SIZE = 20 -- PrettyUI's close button's size
local LEFT, TOP = 8, 6 -- from the window's corner, like the close button's
local OFF_ALPHA = 0.45

-- The title bar's drag layer is a sibling over the window, so a button inside the window would be covered by it.
-- The button goes inside the drag layer instead, which hides and raises it with the window's title bar.
function SharingButton.add(PrettyUI, window, onToggle)
    local titleDrag = window.titleDrag
    local sprite = PrettyUI.NewComponent(ui.Sprite, titleDrag)
    sprite.spriteID = SPRITE
    sprite.clickthrough = false
    sprite.enabled = true
    sprite:SetSize(SIZE, SIZE)
    sprite:Subscribe(ui.Hook.ONCLICK, function()
        onToggle()
        return true
    end)
    local button = setmetatable({ sprite = sprite }, SharingButton)
    button:show()
    -- A title drag stretches the drag layer over the screen, so the button is kept at the window's corner by its
    -- offset from the layer, written only when it changes.
    local placedX, placedY = nil, nil
    local function place()
        local x = math.floor(window.root.x - titleDrag.x) + LEFT
        local y = math.floor(window.root.y - titleDrag.y) + TOP
        if x == placedX and y == placedY then return end
        placedX, placedY = x, y
        sprite:SetPos(x, y)
    end
    place()
    -- PrettyUI remembers the window's place on each step of a drag, and syncs its overlays once the drag layer is
    -- back over the title bar.
    local bounds = window.dragBounds
    local rememberPosition = bounds.RememberPosition
    bounds.RememberPosition = function(self)
        rememberPosition(self)
        place()
    end
    local syncOverlays = window._SyncOverlays
    window._SyncOverlays = function(self, hidden)
        syncOverlays(self, hidden)
        place()
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

return SharingButton
