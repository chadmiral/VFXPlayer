print("VFXPlayer")

local Sequence = require(script.Parent:WaitForChild("Sequence"))

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local activeSequences = {}

local function PlaySequence(s)
    print("Playing Sequence "..s.Name)
    local newSeq = Sequence:new()
    newSeq.model = s
    newSeq.startTime = time()
    newSeq.duration = s:GetAttribute("Duration")
    newSeq.looping = s:GetAttribute("Looping")

    newSeq:Init()

    table.insert(activeSequences, newSeq)
end

local function Init()
    local allSeqs = CollectionService:GetTagged("VFXSequence")
    for _,s in allSeqs do
        if s:GetAttribute("PlayOnStart") == true then
            PlaySequence(s)
        end
    end
end

local function OnHeartbeat(dt)
    local timeStamp = time()
    local i = 1
    while i <= #activeSequences do
        local s = activeSequences[i]
        local elapsedTime = timeStamp - s.startTime

        --print("ElapsedTime: "..elapsedTime)
        if elapsedTime > s.duration then
            --print("Sequence "..s.model.Name.." has elapsed!")
            if s.looping then
                s.startTime = time()
                s:Init()
                i += 1
            else
                table.remove(activeSequences, i)
            end
        else
            s:Update(elapsedTime)
            i += 1
        end
    end
end

RunService.Heartbeat:Connect(OnHeartbeat)
wait(1)
Init()