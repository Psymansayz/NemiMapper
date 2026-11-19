-- The text showing in the NPC dialogue box and the info box, where the follow messages and refusals appear: the young
-- goebie's line in the NPC dialogue box (CHAT_V2_LEFT), the lightning's notice in the info box.

local GameIds = require("src/game/game_ids")

local DialogueText = {}

-- The dialogue box's labels: the speaker's name and the line. They read as nil while the box is closed.
local dialogueLabelIDs = {}
for _, name in ipairs({ "CHAT_V2_LEFT__TITLE_TEXT", "CHAT_V2_LEFT__CHAT_TEXT" }) do
    dialogueLabelIDs[#dialogueLabelIDs + 1] = GameIds.resolve("Component", name)
end
local infoLayerID = GameIds.resolve("Component", "TOPLEVEL_V2__INFOBOX_TOP_LAYER")

local texts -- the list DialogueText.open is filling

-- Notes a component's text, if it is a label showing. Returns false, so a search through the info box goes on.
local function noteLabel(component)
    if component.type == ui.ComponentType.LABEL and component.visibleGlobal then
        local content = component.content
        if content ~= nil and content ~= "" then texts[#texts + 1] = content end
    end
    return false
end

-- Returns the texts showing now in the info box and the dialogue box, if open, as a list.
function DialogueText.open()
    texts = {}
    local infoLayer = infoLayerID ~= nil and ui.Interfaces:GetComponent(infoLayerID) or nil
    if infoLayer ~= nil then infoLayer:IterateDynamicComponents(noteLabel) end
    for _, labelID in ipairs(dialogueLabelIDs) do
        local component = ui.Interfaces:GetComponent(labelID)
        if component ~= nil then noteLabel(component) end
    end
    local found = texts
    texts = nil
    return found
end

return DialogueText
