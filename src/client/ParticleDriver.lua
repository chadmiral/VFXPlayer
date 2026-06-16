ParticleDriver = {
    name = "ParticleDriver",
    _type = "ParticleDriver",
    emitter = nil,
    baseRate = 0,
    emissionScaleOverDuration = nil
}

local Utility = require(script.Parent:WaitForChild("Utility"))

function ParticleDriver:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function ParticleDriver:Update(t)
    --print("Updating ParticleSystem "..self.emitter.Name)
    if self.emissionScaleOverDuration ~= nil then
        --print(self.emissionScaleOverDuration)
        local rateScale = Utility.EvalNumberSequence(self.emissionScaleOverDuration, t)
        self.emitter.Rate = self.baseRate * rateScale
        --print(t.." "..self.emitter.Rate)
    end
end

return ParticleDriver