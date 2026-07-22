ParticleDriver = {
    name = "ParticleDriver",
    _type = "ParticleDriver",
    emitter = nil,

    -- ordered stage timeline (stand -> hold -> decay); see Utility.BuildTimeline
    timeline = nil,

    -- tracks the stage entry whose burst was last emitted, so each stage fires
    -- its burst exactly once (even while the Hold stage loops)
    lastBurstEntry = nil,

    baseRate = nil,
    baseBrightness = nil,
    baseLightEmission = nil,
    baseLightInfluence = nil,
    baseSize = nil,
    baseTransparency = nil,
    baseColor = nil,

    -- distance-based fade bounds in studs, derived from the FadeDistance
    -- NumberRange attribute (Min -> fadeStart, Max -> fadeEnd)
    fadeStart = nil,
    fadeEnd = nil,
    -- authored Enabled state, restored when the emitter is within FadeEnd
    baseEnabled = true,
}

local Utility = require(script.Parent:WaitForChild("Utility"))

local Workspace = game:GetService("Workspace")

function ParticleDriver:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--world position of the emitter, derived from its parent (BasePart or Attachment)
local function getEmitterWorldPosition(emitter)
    local parent = emitter.Parent
    if parent == nil then
        return nil
    end
    if parent:IsA("Attachment") then
        return parent.WorldPosition
    elseif parent:IsA("BasePart") then
        return parent.Position
    end
    return nil
end

--compute the distance-based fade for this frame.
--returns `alpha, distance`:
--  * alpha    -> transparency fade in [0, 1] (0 = fully visible, 1 = faded out)
--  * distance -> camera-to-emitter distance in studs, or nil when the fade is
--                inactive (parameters unset, or no camera / position available)
function ParticleDriver:ComputeFade()
    if self.fadeStart == nil or self.fadeEnd == nil then
        return 0, nil
    end

    local camera = Workspace.CurrentCamera
    local position = getEmitterWorldPosition(self.emitter)
    if camera == nil or position == nil then
        return 0, nil
    end

    local distance = (camera.CFrame.Position - position).Magnitude

    local alpha
    if self.fadeEnd <= self.fadeStart then
        -- degenerate range: treat as a hard cutoff at fadeEnd
        alpha = distance >= self.fadeEnd and 1 or 0
    else
        alpha = math.clamp((distance - self.fadeStart) / (self.fadeEnd - self.fadeStart), 0, 1)
    end

    return alpha, distance
end

--restore the emitter to its starting state and suppress emission during the delay window
function ParticleDriver:HoldAtStart(fadeAlpha)
    self.emitter.Rate = 0
    self.emitter.Brightness = self.baseBrightness
    self.emitter.LightEmission = self.baseLightEmission
    self.emitter.LightInfluence = self.baseLightInfluence
    self.emitter.Size = self.baseSize
    self.emitter.Color = self.baseColor
    self.emitter.Transparency = Utility.FadeNumberSequence(self.baseTransparency, fadeAlpha or 0)
end

--reset per-cycle state at the start of a sequence or loop
function ParticleDriver:BeginCycle()
    self.lastBurstEntry = nil
    self:HoldAtStart()
end

--apply a single stage's curve set at normalized time t; properties whose curve
--is absent for this stage fall back to the emitter's base value.
--when `suppressEmission` is true (a stage has elapsed and we are holding), the
--emission Rate is forced to 0 so no new particles spawn, while every other
--property stays frozen at its held value and already-spawned particles live on.
--`fadeAlpha` (0-1) is the distance-based transparency fade layered on top of the
--stage's transparency.
function ParticleDriver:ApplyCurves(curves, t, suppressEmission, fadeAlpha)
    if suppressEmission then
        self.emitter.Rate = 0
    elseif curves.emissionScaleOverDuration ~= nil then
        local rateScale = Utility.EvalNumberSequence(curves.emissionScaleOverDuration, t)
        self.emitter.Rate = self.baseRate * rateScale
    else
        self.emitter.Rate = self.baseRate
    end

    if curves.brightnessScaleOverDuration ~= nil then
        local brightnessScale = Utility.EvalNumberSequence(curves.brightnessScaleOverDuration, t)
        self.emitter.Brightness = self.baseBrightness * brightnessScale
    else
        self.emitter.Brightness = self.baseBrightness
    end

    if curves.lightEmissionScaleOverDuration ~= nil then
        local lightEmissionScale = Utility.EvalNumberSequence(curves.lightEmissionScaleOverDuration, t)
        self.emitter.LightEmission = self.baseLightEmission * lightEmissionScale
    else
        self.emitter.LightEmission = self.baseLightEmission
    end

    if curves.lightInfluenceScaleOverDuration ~= nil then
        local lightInfluenceScale = Utility.EvalNumberSequence(curves.lightInfluenceScaleOverDuration, t)
        self.emitter.LightInfluence = self.baseLightInfluence * lightInfluenceScale
    else
        self.emitter.LightInfluence = self.baseLightInfluence
    end

    if curves.sizeScaleOverDuration ~= nil then
        local sizeScale = Utility.EvalNumberSequence(curves.sizeScaleOverDuration, t)
        self.emitter.Size = Utility.ScaleNumberSequence(self.baseSize, sizeScale)
    else
        self.emitter.Size = self.baseSize
    end

    local stageTransparency
    if curves.transparencyScaleOverDuration ~= nil then
        local transScale = Utility.EvalNumberSequence(curves.transparencyScaleOverDuration, t)
        stageTransparency = Utility.ScaleNumberSequence(self.baseTransparency, transScale)
    else
        stageTransparency = self.baseTransparency
    end
    self.emitter.Transparency = Utility.FadeNumberSequence(stageTransparency, fadeAlpha or 0)

    if curves.tintOverDuration ~= nil then
        local tint = Utility.EvalColorSequence(curves.tintOverDuration, t)
        self.emitter.Color = Utility.TintColorSequence(self.baseColor, tint)
    else
        self.emitter.Color = self.baseColor
    end
end

function ParticleDriver:Update(elapsedTime)
    local fadeAlpha, distance = self:ComputeFade()

    -- distance culling: turn emission off past FadeEnd, back on within FadeEnd
    if distance ~= nil then
        self.emitter.Enabled = self.baseEnabled and distance <= self.fadeEnd
    end

    if self.timeline == nil or #self.timeline == 0 then
        self:HoldAtStart(fadeAlpha)
        return
    end

    local curves, t, active, frozen, entry = Utility.ResolveTimeline(self.timeline, elapsedTime)
    if not active or curves == nil then
        self:HoldAtStart(fadeAlpha)
        return
    end

    -- fire the current stage's burst once, when the stage first begins; the
    -- looping Hold stage does NOT re-fire on subsequent loop iterations
    if not frozen and entry ~= nil and entry ~= self.lastBurstEntry then
        if entry.burstCount ~= nil then
            self.emitter:Emit(entry.burstCount)
        end
        self.lastBurstEntry = entry
    end

    self:ApplyCurves(curves, t, frozen, fadeAlpha)
end

return ParticleDriver
