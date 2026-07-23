local toolbar = plugin:CreateToolbar("VFXPlayer")
local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")
game:GetService("StarterPlayer")

local playSelectionButton = toolbar:CreateButton("Play VFX", "Play the selected VFX", "rbxassetid://14978048121")
local stopAllButton = toolbar:CreateButton("Stop All", "Stop All Playing VFX", "rbxassetid://14978048121")
local setupButton = toolbar:CreateButton("Setup VFX", "Add Base Attributes and Tags to selected VFX Object", "rbxassetid://14978048121")

local Sequence = require(script.Parent:WaitForChild("Sequence"))

local activeSequences = {}

local pluginTime = 0

local function PlaySequence(s)
    print("Playing Sequence "..s.Name)
    local newSeq = Sequence:new()
    newSeq.model = s
    newSeq.startTime = pluginTime
    newSeq.duration = s:GetAttribute("Duration")
    newSeq.looping = s:GetAttribute("Looping")

    newSeq:Init()

    table.insert(activeSequences, newSeq)
end


local function onPlaySelectionButtonClicked()
    activeSequences = {}

    --find all VFXSequence tagged objects in the selection
    for _, obj in pairs(Selection:Get()) do
        if CollectionService:HasTag(obj, "VFXSequence") then
            PlaySequence(obj)
        end
    end
end

playSelectionButton.Click:Connect(onPlaySelectionButtonClicked)


local function onStopAllButtonClicked()
    for _,s in activeSequences do
        s:Init()
    end
    activeSequences = {}
end
stopAllButton.Click:Connect(onStopAllButtonClicked)


local function onSetupButtonClicked()
    for _, obj in pairs(Selection:Get()) do
        print(obj.Name)
    end
end
setupButton.Click:Connect(onSetupButtonClicked)


task.spawn(function()
    while true do
        local deltaTime = task.wait()
        pluginTime = pluginTime + deltaTime

        local timeStamp = pluginTime
        local i = 1
        while i <= #activeSequences do
            local s = activeSequences[i]
            local elapsedTime = timeStamp - s.startTime
            --print(elapsedTime)

            if elapsedTime > s.duration then
                if s.looping then
                    --print("reseting loop")
                    s.startTime = pluginTime
                    s:Init()
                    i += 1
                else
                    --print("killing effect")
                    table.remove(activeSequences, i)
                end
            else
                s:Update(elapsedTime)
                i += 1
            end
        end
    end
end)