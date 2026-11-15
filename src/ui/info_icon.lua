-- A setting's info icon on its checkbox's line, showing its text as a tooltip.
-- Used on the plugin's pages and the settings window.

local InfoIcon = {}

local SIZE = 21 -- the game's info icon at its native size, which fits a checkbox row (22)
InfoIcon.SIZE = SIZE

local function doNothing() end

function InfoIcon.add(view, text)
    view:AddSpriteButton("INFO", doNothing, {
        inline = true, size = SIZE, tooltip = { text = text, maxWidth = 320 },
    })
end

return InfoIcon
