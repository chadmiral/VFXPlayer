local toolbar = plugin:CreateToolbar("VFXPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
game:GetService("StarterPlayer")

--Play and Stop are buttons in the VFX Editor window rather than on the ribbon,
--so that playback follows the sequence picked in the window's left pane. The
--ribbon is left with the one button that opens that window.
local editorButton = toolbar:CreateButton("VFX Editor", "Inspect the VFX Sequences in this place", "rbxasset://studio_svg_textures/Shared/InsertableObjects/Dark/Standard/ParticleEmitter.png")

local Sequence = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Sequence)
local VFXEditor = require(script.Parent:WaitForChild("VFXEditor"))

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

--play one sequence, replacing whatever was playing before
local function onPlayRequested(sequence)
    activeSequences = {}

    ensureBaseAttributes(sequence)
    PlaySequence(sequence)
end

local function onStopRequested()
    for _,s in activeSequences do
        s:Init()
    end
    activeSequences = {}
end


local editor = VFXEditor.Create(plugin)
editorButton.ClickableWhenViewportHidden = true
editorButton:SetActive(editor:IsOpen())

editorButton.Click:Connect(function()
    editor:Toggle()
end)

editor:OnPlay(onPlayRequested)
editor:OnStop(onStopRequested)

--the window can also be closed by its own titlebar, so mirror its state rather
--than toggling the button directly
editor:OnOpenChanged(function(open)
    editorButton:SetActive(open)
end)

plugin.Unloading:Connect(function()
    editor:Destroy()
end)


task.spawn(function()
    while true do
        local deltaTime = task.wait()
        pluginTime = pluginTime + deltaTime

        --the effect whose progress the editor's timeline cursor follows
        local playingModel = nil
        local playingElapsed = nil

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
                if playingModel == nil then
                    playingModel = s.model
                    playingElapsed = elapsedTime
                end
                i += 1
            end
        end

        editor:SetPlayhead(playingModel, playingElapsed)
    end
end)