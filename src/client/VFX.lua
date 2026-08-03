VFXClient = {}

local Sequence = require(script.Parent:WaitForChild("Sequence"))

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Playing sequences are advanced by a single shared Heartbeat loop that only
-- runs while something is playing.
local activeSequences = {}
local heartbeatConnection = nil

--advance every playing sequence; looping sequences restart, one-shots are
--retired and any instance spawned by PlayVFX is destroyed with them
local function stepSequences()
    local timeStamp = time()
    local i = 1
    while i <= #activeSequences do
        local s = activeSequences[i]
        local elapsedTime = timeStamp - s.startTime

        if elapsedTime > s.duration then
            if s.looping then
                s.startTime = timeStamp
                s:Init()
                i += 1
            else
                table.remove(activeSequences, i)
                if s.destroyModelOnComplete and s.model ~= nil then
                    s.model:Destroy()
                end
            end
        else
            s:Update(elapsedTime)
            i += 1
        end
    end

    if #activeSequences == 0 and heartbeatConnection ~= nil then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
end

local function ensurePlaybackRunning()
    if heartbeatConnection == nil then
        heartbeatConnection = RunService.Heartbeat:Connect(stepSequences)
    end
end

local function startSequence(model, destroyModelOnComplete)
    local newSeq = Sequence:new()
    newSeq.model = model
    newSeq.startTime = time()
    newSeq.duration = model:GetAttribute("Duration")
    newSeq.looping = model:GetAttribute("Looping")
    --playback bookkeeping: only instances spawned by PlayVFX are ours to destroy
    newSeq.destroyModelOnComplete = destroyModelOnComplete

    newSeq:Init()

    table.insert(activeSequences, newSeq)
    ensurePlaybackRunning()

    return newSeq
end

--play a VFXSequence model that is already placed in the world. The model is
--left in place when playback completes.
function VFXClient.PlaySequence(model)
    return startSequence(model, false)
end

--spawn a copy of a VFX template at `cframe` and play it, returning the spawned
--instance. A one-shot template's copy is destroyed once playback completes; a
--template with Looping set plays continuously, so destroy the returned instance
--when you want it to stop.
function VFXClient.PlayVFX(template: Model, cframe: CFrame)
    local instance = template:Clone()
    -- position before parenting so the copy never renders at the template's spot
    instance:PivotTo(cframe)
    instance.Parent = Workspace

    local looping = instance:GetAttribute("Looping") == true
    startSequence(instance, not looping)

    return instance
end

return VFXClient
