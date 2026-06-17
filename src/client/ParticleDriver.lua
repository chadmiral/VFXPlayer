ParticleDriver = {
    name = "ParticleDriver",
    _type = "ParticleDriver",
    emitter = nil,
    baseRate = nil,
    emissionScaleOverDuration = nil,
    baseColor = nil,
    tintOverDuration = nil
}

local Utility = require(script.Parent:WaitForChild("Utility"))

function ParticleDriver:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function ParticleDriver:Update(t)
    if self.emissionScaleOverDuration ~= nil then
        local rateScale = Utility.EvalNumberSequence(self.emissionScaleOverDuration, t)
        self.emitter.Rate = self.baseRate * rateScale
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

return ParticleDriver