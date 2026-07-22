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
}

local Utility = require(script.Parent:WaitForChild("Utility"))

function ParticleDriver:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--restore the emitter to its starting state and suppress emission during the delay window
function ParticleDriver:HoldAtStart()
    self.emitter.Rate = 0
    self.emitter.Brightness = self.baseBrightness
    self.emitter.LightEmission = self.baseLightEmission
    self.emitter.LightInfluence = self.baseLightInfluence
    self.emitter.Size = self.baseSize
    self.emitter.Color = self.baseColor
    self.emitter.Transparency = self.baseTransparency
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
function ParticleDriver:ApplyCurves(curves, t, suppressEmission)
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

    if curves.transparencyScaleOverDuration ~= nil then
        local transScale = Utility.EvalNumberSequence(curves.transparencyScaleOverDuration, t)
        self.emitter.Transparency = Utility.ScaleNumberSequence(self.baseTransparency, transScale)
    else
        self.emitter.Transparency = self.baseTransparency
    end

    if curves.tintOverDuration ~= nil then
        local tint = Utility.EvalColorSequence(curves.tintOverDuration, t)
        self.emitter.Color = Utility.TintColorSequence(self.baseColor, tint)
    else
        self.emitter.Color = self.baseColor
    end
end

function ParticleDriver:Update(elapsedTime)
    if self.timeline == nil or #self.timeline == 0 then
        self:HoldAtStart()
        return
    end

    local curves, t, active, frozen, entry = Utility.ResolveTimeline(self.timeline, elapsedTime)
    if not active or curves == nil then
        self:HoldAtStart()
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

    self:ApplyCurves(curves, t, frozen)
end

return ParticleDriver
