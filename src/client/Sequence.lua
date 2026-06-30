Sequence = { name = "Sequence", _type = "Sequence", model = nil, startTime = -1, duration = -1, looping = false, particleDrivers = {}, lightDrivers = {} }

local Utility = require(script.Parent:WaitForChild("Utility"))
local ParticleDriver = require(script.Parent:WaitForChild("ParticleDriver"))
local LightDriver = require(script.Parent:WaitForChild("LightDriver"))

function Sequence:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

local function initParticleEmitter(seq, e)
    local pd = ParticleDriver:new()
    pd.emitter = e

    pd.duration = e:GetAttribute("Duration")
    if pd.duration == nil then
        pd.duration = seq.duration
    end
    pd.delay = e:GetAttribute("Delay")
    if pd.delay == nil then
        pd.delay = 0
    end
    pd.burstCount = e:GetAttribute("BurstCount")

    pd.baseRate = e.Rate
    pd.emissionScaleOverDuration = e:GetAttribute("EmissionScaleOverDuration")

    pd.baseBrightness = e.Brightness
    pd.brightnessScaleOverDuration = e:GetAttribute("BrightnessScaleOverDuration")

    pd.baseLightEmission = e.LightEmission
    pd.lightEmissionScaleOverDuration = e:GetAttribute("LightEmissionScaleOverDuration")

    pd.baseLightInfluence = e.LightInfluence
    pd.lightInfluenceScaleOverDuration = e:GetAttribute("LightInfluenceScaleOverDuration")

    pd.baseSize = e.Size
    pd.sizeScaleOverDuration = e:GetAttribute("SizeScaleOverDuration")

    pd.baseColor = e.Color
    pd.tintOverDuration = e:GetAttribute("TintOverDuration")

    pd.baseTransparency = e.Transparency
    pd.transparencyScaleOverDuration = e:GetAttribute("TransparencyScaleOverDuration")

    pd:BeginCycle()

    return pd
end

local function initLight(seq, l)
    local ld = LightDriver:new()
    ld.light = l
    ld.isSpotLight = l:IsA("SpotLight")

    ld.duration = l:GetAttribute("Duration")
    if ld.duration == nil then
        ld.duration = seq.duration
    end
    ld.delay = l:GetAttribute("Delay")
    if ld.delay == nil then
        ld.delay = 0
    end

    ld.baseBrightness = l.Brightness
    ld.brightnessScaleOverDuration = l:GetAttribute("BrightnessScaleOverDuration")

    ld.baseRange = l.Range
    ld.rangeScaleOverDuration = l:GetAttribute("RangeScaleOverDuration")

    if ld.isSpotLight then
        ld.baseAngle = l.Angle
        ld.angleScaleOverDuration = l:GetAttribute("AngleScaleOverDuration")
    end

    ld.baseColor = l.Color
    ld.tintOverDuration = l:GetAttribute("TintOverDuration")

    ld:BeginCycle()

    return ld
end

--reset all playing emitters to their starting states
local function resetParticleDrivers(seq)
    for _,pd in seq.particleDrivers do
        pd.emitter.Rate = pd.baseRate
        pd.emitter.Brightness = pd.baseBrightness
        pd.emitter.LightEmission = pd.baseLightEmission
        pd.emitter.LightInfluence = pd.baseLightInfluence
        pd.emitter.Size = pd.baseSize
        pd.emitter.Color = pd.baseColor
        pd.emitter.Transparency = pd.baseTransparency
    end
end

--reset all playing lights to their starting states
local function resetLightDrivers(seq)
    for _,ld in seq.lightDrivers do
        ld.light.Brightness = ld.baseBrightness
        ld.light.Color = ld.baseColor
        ld.light.Range = ld.baseRange
        if ld.isSpotLight then
            ld.light.Angle = ld.baseAngle
        end
    end
end

function Sequence:Init()
    resetParticleDrivers(self)
    resetLightDrivers(self)
    self.particleDrivers = {}
    self.lightDrivers = {}

    local descendants = self.model:GetDescendants()
    for _,d in descendants do
        if d:IsA("ParticleEmitter") then
            local pd = initParticleEmitter(self, d)
            table.insert(self.particleDrivers, pd)
        elseif d:IsA("PointLight") or d:IsA("SpotLight") then
            local ld = initLight(self, d)
            table.insert(self.lightDrivers, ld)
        end
    end
end

function Sequence:Update(elapsedTime)
    for _,pd in self.particleDrivers do
        pd:Update(elapsedTime)
    end

    for _,ld in self.lightDrivers do
        ld:Update(elapsedTime)
    end
end

return Sequence