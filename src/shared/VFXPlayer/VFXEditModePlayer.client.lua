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


--native ParticleEmitter properties copied verbatim into their Base attribute
--(Size is handled separately below, since it is normalized)
local PARTICLE_BASE_PROPERTIES = {
    "Rate",
    "Brightness",
    "LightEmission",
    "LightInfluence",
    "Transparency",
    "Color",
}

--split a NumberSequence into a [0,1] normalized sequence plus the peak value it
--was divided by, such that normalized * peak reproduces the original
local function normalizeNumberSequence(sequence)
    local peak = 0
    for _, kp in sequence.Keypoints do
        if kp.Value > peak then
            peak = kp.Value
        end
    end

    --an all-zero (or degenerate) sequence is already normalized
    if peak <= 0 then
        return sequence, 1
    end

    local keypoints = {}
    for _, kp in sequence.Keypoints do
        table.insert(keypoints, NumberSequenceKeypoint.new(kp.Time, kp.Value / peak, kp.Envelope / peak))
    end
    return NumberSequence.new(keypoints), peak
end

--author any missing Base attributes on the emitters of a sequence, seeding each
--one with the emitter's current native property value
local function ensureBaseAttributes(model)
    for _, d in model:GetDescendants() do
        if d:IsA("ParticleEmitter") then
            for _, property in PARTICLE_BASE_PROPERTIES do
                local attribute = "Base"..property
                if d:GetAttribute(attribute) == nil then
                    d:SetAttribute(attribute, d[property])
                end
            end

            --BaseSize is stored normalized to [0,1] with the peak factored out
            --into BaseSizeMultiplier, so BaseSize * BaseSizeMultiplier == Size
            if d:GetAttribute("BaseSize") == nil then
                local normalized, peak = normalizeNumberSequence(d.Size)
                d:SetAttribute("BaseSize", normalized)
                d:SetAttribute("BaseSizeMultiplier", peak)
            end
        end
    end
end

local function onPlaySelectionButtonClicked()
    activeSequences = {}

    --find all VFXSequence tagged objects in the selection
    for _, obj in pairs(Selection:Get()) do
        if CollectionService:HasTag(obj, "VFXSequence") then
            ensureBaseAttributes(obj)
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