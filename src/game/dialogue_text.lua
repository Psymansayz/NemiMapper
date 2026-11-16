-- The text showing in the NPC dialogue box and the info box, where the follow messages and refusals appear: the young
-- goebie's line in the NPC dialogue box (CHAT_V2_LEFT), the lightning's notice in the info box.

local GameIds = require("src/game/game_ids")

local DialogueText = {}

local dialogueBoxID = GameIds.resolve("Interface", "CHAT_V2_LEFT")
-- The dialogue box's labels: the speaker's name and the line.
local dialogueLabelIDs = {}
for _, name in ipairs({ "CHAT_V2_LEFT__TITLE_TEXT", "CHAT_V2_LEFT__CHAT_TEXT" }) do
    dialogueLabelIDs[#dialogueLabelIDs + 1] = GameIds.resolve("Component", name)
end
local infoLayerID = GameIds.resolve("Component", "TOPLEVEL_V2__INFOBOX_TOP_LAYER")

local texts -- the list DialogueText.open is filling

local function noteLabel(component)
    if component.type == ui.ComponentType.LABEL and component.visibleGlobal then
        local content = component.content
        if content ~= nil and content ~= "" then texts[#texts + 1] = content end
    end
end

-- Notes a dynamic child's text, if it is a label showing.
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
        for _, labelID in ipairs(dialogueLabelIDs) do
            local component = ui.Interfaces:GetComponent(labelID)
            if component ~= nil then noteLabel(component) end
        end
    end
    local found = texts
    texts = nil
    return found
end

return DialogueText
