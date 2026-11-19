-- Dev-only: the development servers' cheats, for testing the plugin. They run as console commands
-- (ExecuteConsoleCommand), which work only on the development servers. Each command is logged as CHEAT|.

local ForestFeatures = require("src/data/forest_features")
local GameIds = require("src/game/game_ids")

local DevCheats = {}

local LOG_PREFIX = "[nemi_mapper] "
-- The VarBits of Trinks' task on RAID1_REPEATABLE_CONTENT: the task, and the parts of it done so far.
local CURRENT_TASK = "RAID1_GOEBIE_CURRENT_QUEST"
local TASK_PARTS = {
    "RAID1_GOEBIE_CURRENT_QUEST_PROGRESS", "RAID1_GOEBIE_NPC_SUBTASK", "RAID1_GOEBIE_LOC_SUBTASK",
    "RAID1_GOEBIE_OBJ_SUBTASK",
}
local MET_TRINKS = "RAID1_GOEBIE_GIVER_MET_STATE"

-- Sets a variable with the !setvar cheat and logs the command.
-- The cheats' own examples write variable names in lower case.
local function setVariable(name, value)
    local command = "!setvar " .. name:lower() .. " " .. value
    print(LOG_PREFIX .. "CHEAT|" .. command)
    ExecuteConsoleCommand(command)
end

-- Takes back every node's claim for today.
function DevCheats.clearClaims()
    for _, node in ipairs(ForestFeatures.nodes) do setVariable(node.claimed, 0) end
end

-- The tasks the plugin maps take turns, starting with the first listed.
local nextTaskIndex = 1

-- Ends the current Trinks' task and clears its parts done (the Traitor killed, a step of its progress), or with none,
-- starts the next of the forest's tasks (the Pahtli plant's, then the Traitor's).
function DevCheats.toggleTask()
    local current = GameIds.playerVariable(CURRENT_TASK)
    if current ~= nil and current.value ~= 0 then
        setVariable(CURRENT_TASK, 0)
        for _, name in ipairs(TASK_PARTS) do setVariable(name, 0) end
        return
    end
    local tasks = ForestFeatures.trinksTasks
    local task = tasks[nextTaskIndex]
    nextTaskIndex = nextTaskIndex % #tasks + 1
    local struct = config.Struct[task.questStruct]
    local quest = struct and config.Enum.RAID1_GOEBIE_IDS_TO_STRUCTS:GetInputValues(struct)[1]
    if quest == nil then return print(LOG_PREFIX .. "CHEAT|no task value known for " .. task.key) end
    setVariable(MET_TRINKS, 1)
    setVariable(CURRENT_TASK, quest)
end

return DevCheats
