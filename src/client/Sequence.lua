Sequence = { name = "Sequence", _type = "Sequence", model = nil, startTime = -1, duration = -1, looping = false, particleDrivers = {} }

local Utility = require(script.Parent:WaitForChild("Utility"))
local ParticleDriver = require(script.Parent:WaitForChild("ParticleDriver"))

function Sequence:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

local function initParticleEmitter(e)
    local burstCount = e:GetAttribute("BurstCount")
    if burstCount ~= nil then 
        e:Emit(burstCount)
    end

    local pd = ParticleDriver:new()
    pd.emitter = e

    pd.baseRate = e.Rate
    pd.emissionScaleOverDuration = e:GetAttribute("EmissionScaleOverDuration")

    pd.baseColor = e.Color
    pd.tintOverDuration = e:GetAttribute("TintOverDuration")

    pd.baseTransparency = e.Transparency
    pd.transparencyScaleOverDuration = e:GetAttribute("TransparencyScaleOverDuration")

    return pd
end

--reset all playing emitters to their starting states
function Sequence:resetParticleDrivers()
    for _,pd in self.particleDrivers do
        pd.emitter.Rate = pd.baseRate
        pd.emitter.Color = pd.baseColor
        pd.emitter.Transparency = pd.baseTransparency
    end
end

function Sequence:Init()
    self:resetParticleDrivers()

    local descendants = self.model:GetDescendants()
    for _,d in descendants do
        if d:IsA("ParticleEmitter") then
            local pd = initParticleEmitter(d)
            table.insert(self.particleDrivers, pd)
        end
    end
end

function Sequence:Update(elapsedTime)
    local t = elapsedTime / self.duration
    --print("Updating sequence "..self.model.Name.." elapsedTime: "..elapsedTime.." t: "..t)

    for _,pd in self.particleDrivers do
        pd:Update(t)
    end
end

return Sequence