ParticleDriver = {
    name = "ParticleDriver",
    _type = "ParticleDriver",
    emitter = nil,
    duration = nil,
    delay = nil,

    burstCount = nil,
    burstFired = false,

    baseRate = nil,
    emissionScaleOverDuration = nil,

    baseTransparency = nil,
    transparencyScaleOverDuration = nil,
    
    baseColor = nil,
    tintOverDuration = nil,
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
    self.emitter.Color = self.baseColor
    self.emitter.Transparency = self.baseTransparency
end

--reset per-cycle state at the start of a sequence or loop
function ParticleDriver:BeginCycle()
    self.burstFired = false
    self:HoldAtStart()
end

function ParticleDriver:ApplyCurves(t)
    if self.emissionScaleOverDuration ~= nil then
        local rateScale = Utility.EvalNumberSequence(self.emissionScaleOverDuration, t)
        self.emitter.Rate = self.baseRate * rateScale
    else
        self.emitter.Rate = self.baseRate
    end

    if self.transparencyScaleOverDuration ~= nil then
        local transScale = Utility.EvalNumberSequence(self.transparencyScaleOverDuration, t)

        local newKeypoints = {}
        for i = 1, #self.baseTransparency.Keypoints do
            local kpTrans = self.baseTransparency.Keypoints[i].Value
            table.insert(newKeypoints, NumberSequenceKeypoint.new(self.baseTransparency.Keypoints[i].Time, kpTrans * transScale))
        end
        self.emitter.Transparency = NumberSequence.new(newKeypoints)
    end

    if self.tintOverDuration ~= nil then
        local tint = Utility.EvalColorSequence(self.tintOverDuration, t)

        local newKeypoints = {}
        for i = 1, #self.baseColor.Keypoints do
            local kpColor = self.baseColor.Keypoints[i].Value
            table.insert(newKeypoints, ColorSequenceKeypoint.new(self.baseColor.Keypoints[i].Time, Color3.new(kpColor.R * tint.R, kpColor.G * tint.G, kpColor.B * tint.B)))
        end
        self.emitter.Color = ColorSequence.new(newKeypoints)
    end
end

function ParticleDriver:Update(elapsedTime)
    local delay = self.delay or 0
    if elapsedTime < delay then
        self:HoldAtStart()
        return
    end

    if not self.burstFired and self.burstCount ~= nil then
        self.emitter:Emit(self.burstCount)
        self.burstFired = true
    end

    local duration = self.duration
    if duration == nil or duration <= 0 then
        return
    end

    local localElapsed = elapsedTime - delay
    local t = math.clamp(localElapsed / duration, 0, 1)
    self:ApplyCurves(t)
end

return ParticleDriver