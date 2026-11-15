-- The text showing in the NPC dialogue box and the info box, where the follow messages appear: the lost goebie's
-- line in the NPC dialogue box (CHAT_V2_LEFT), the lightning's notice in the info box. No event fires when either
-- shows, so callers poll this on server ticks. The dialogue box keeps its text in labels among its first
-- components. The info box's notices are dynamic label children of TOPLEVEL_V2__INFOBOX_TOP_LAYER; the INFO_BOX
-- interface itself holds no text. Hidden labels are skipped, as a box can keep its last text when hidden.

local GameIds = require("src/game/game_ids")

local DialogueText = {}

local LAST_STATIC_READ = 40

local dialogueBoxID = GameIds.resolve("Interface", "CHAT_V2_LEFT")
local infoLayerID = GameIds.resolve("Component", "TOPLEVEL_V2__INFOBOX_TOP_LAYER")

local texts -- the list DialogueText.open is filling

local function noteLabel(component)
    if component.type == ui.ComponentType.LABEL and component.visibleGlobal then
        local content = component.content
        if content ~= nil and content ~= "" then texts[#texts + 1] = content end
    end
end

-- Notes a dynamic child's text, if it is a label showing.
-- The callback is made once rather than on every read.
local function noteDynamicLabel(child)
    noteLabel(child)
    return false
end

-- Returns the texts showing now in the info box and the dialogue box, if open, as a list.
function DialogueText.open()
    texts = {}
    local infoLayer = infoLayerID ~= nil and ui.Interfaces:GetComponent(infoLayerID) or nil
    if infoLayer ~= nil then infoLayer:IterateDynamicComponents(noteDynamicLabel) end
    if dialogueBoxID ~= nil and ui.Interfaces:GetInterface(dialogueBoxID) ~= nil then
        for staticID = 0, LAST_STATIC_READ do
            local component = ui.Interfaces:GetComponent(dialogueBoxID, staticID)
            if component ~= nil then noteLabel(component) end
        end
    end
    local found = texts
    texts = nil
    return found
end

return DialogueText
