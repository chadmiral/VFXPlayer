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

--the three animation stages, in playback order
local STAGES = { "Stand", "Hold", "Decay" }

--read the timing (delay/duration/loop) attributes for a single stage on an instance
local function readStageTiming(inst, stage, standDurationFallback)
    local duration = inst:GetAttribute(stage.."Duration")
    if duration == nil and stage == "Stand" then
        -- the stand stage spans the whole sequence by default
        duration = standDurationFallback
    end

    local loopCount = 1
    if stage == "Hold" then
        loopCount = inst:GetAttribute("HoldLoopCount") or 1
    end

    return {
        delay = inst:GetAttribute(stage.."Delay") or 0,
        duration = duration or 0,
        loopCount = loopCount,
    }
end

--read the curve attributes for a particle emitter stage (e.g. "StandSizeScaleOverDuration")
local function readParticleStageCurves(e, stage)
    return {
        emissionScaleOverDuration = e:GetAttribute(stage.."EmissionScaleOverDuration"),
        brightnessScaleOverDuration = e:GetAttribute(stage.."BrightnessScaleOverDuration"),
        lightEmissionScaleOverDuration = e:GetAttribute(stage.."LightEmissionScaleOverDuration"),
        lightInfluenceScaleOverDuration = e:GetAttribute(stage.."LightInfluenceScaleOverDuration"),
        sizeScaleOverDuration = e:GetAttribute(stage.."SizeScaleOverDuration"),
        transparencyScaleOverDuration = e:GetAttribute(stage.."TransparencyScaleOverDuration"),
        tintOverDuration = e:GetAttribute(stage.."TintOverDuration"),
    }
end

--read the curve attributes for a light stage
local function readLightStageCurves(l, stage)
    return {
        brightnessScaleOverDuration = l:GetAttribute(stage.."BrightnessScaleOverDuration"),
        rangeScaleOverDuration = l:GetAttribute(stage.."RangeScaleOverDuration"),
        angleScaleOverDuration = l:GetAttribute(stage.."AngleScaleOverDuration"),
        tintOverDuration = l:GetAttribute(stage.."TintOverDuration"),
    }
end

--assemble the ordered stage definitions consumed by Utility.BuildTimeline
local function buildStages(inst, standDurationFallback, readCurves)
    local stages = {}
    for _, stage in STAGES do
        local timing = readStageTiming(inst, stage, standDurationFallback)
        table.insert(stages, {
            name = string.lower(stage),
            delay = timing.delay,
            duration = timing.duration,
            loopCount = timing.loopCount,
            burstCount = inst:GetAttribute(stage.."BurstCount"),
            curves = readCurves(inst, stage),
        })
    end
    return stages
end

local function initParticleEmitter(seq, e)
    local pd = ParticleDriver:new()
    pd.emitter = e

    pd.baseRate = e.Rate
    pd.baseBrightness = e.Brightness
    pd.baseLightEmission = e.LightEmission
    pd.baseLightInfluence = e.LightInfluence
    pd.baseSize = e.Size
    pd.baseColor = e.Color
    pd.baseTransparency = e.Transparency

    local stages = buildStages(e, seq.duration, readParticleStageCurves)
    pd.timeline = Utility.BuildTimeline(stages)

    pd:BeginCycle()

    return pd
end

local function initLight(seq, l)
    local ld = LightDriver:new()
    ld.light = l
    ld.isSpotLight = l:IsA("SpotLight")

    ld.baseBrightness = l.Brightness
    ld.baseRange = l.Range
    if ld.isSpotLight then
        ld.baseAngle = l.Angle
    end
    ld.baseColor = l.Color

    local stages = buildStages(l, seq.duration, readLightStageCurves)
    ld.timeline = Utility.BuildTimeline(stages)

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