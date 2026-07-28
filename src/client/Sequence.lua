Sequence = { name = "Sequence", _type = "Sequence", model = nil, startTime = -1, duration = -1, looping = false, particleDrivers = {}, lightDrivers = {}, meshDrivers = {} }

local Utility = require(script.Parent:WaitForChild("Utility"))
local ParticleDriver = require(script.Parent:WaitForChild("ParticleDriver"))
local LightDriver = require(script.Parent:WaitForChild("LightDriver"))
local MeshParticleDriver = require(script.Parent:WaitForChild("MeshParticleDriver"))

local CollectionService = game:GetService("CollectionService")

local MESH_EMITTER_TAG = "MeshEmitter"


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

--resolve a base animation value: prefer a `Base<Property>` attribute override on
--the instance, otherwise fall back to the instance's native property value
local function baseValue(inst, property, nativeValue)
    local override = inst:GetAttribute("Base"..property)
    if override ~= nil then
        return override
    end
    return nativeValue
end

local function initParticleEmitter(seq, e)
    local pd = ParticleDriver:new()
    pd.emitter = e

    pd.baseRate = baseValue(e, "Rate", e.Rate)
    pd.baseBrightness = baseValue(e, "Brightness", e.Brightness)
    pd.baseLightEmission = baseValue(e, "LightEmission", e.LightEmission)
    pd.baseLightInfluence = baseValue(e, "LightInfluence", e.LightInfluence)
    pd.baseSize = baseValue(e, "Size", e.Size)
    pd.baseColor = baseValue(e, "Color", e.Color)
    pd.baseTransparency = baseValue(e, "Transparency", e.Transparency)
    pd.baseEnabled = e.Enabled

    -- scalar multiplier applied to the base size sequence before stage size curves
    local baseSizeMultiplier = e:GetAttribute("BaseSizeMultiplier")
    if baseSizeMultiplier ~= nil then
        pd.baseSize = Utility.ScaleNumberSequence(pd.baseSize, baseSizeMultiplier)
    end

    local fadeDistance = e:GetAttribute("FadeDistance")
    if fadeDistance ~= nil then
        pd.fadeStart = fadeDistance.Min
        pd.fadeEnd = fadeDistance.Max
    end

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

local function initMeshEmitter(seq, a)
    local md = MeshParticleDriver:new()
    md.emitter = a

    -- the mesh template is referenced by an ObjectValue child of the attachment
    local objectValue = a:FindFirstChildOfClass("ObjectValue")
    if objectValue ~= nil then
        md.template = objectValue.Value
    end
    if md.template ~= nil then
        md.baseSize = md.template.Size

        -- scalar folded into the base size; because base size is only applied
        -- alongside SizeOverParticleLifetime, this multiplies against that curve
        local sizeMultiplier = a:GetAttribute("SizeMultiplier")
        if sizeMultiplier ~= nil then
            md.baseSize = md.baseSize * sizeMultiplier
        end
    else
        warn("MeshEmitter '"..a:GetFullName().."' has no ObjectValue pointing to a mesh template; no particles will spawn")
    end

    local lifetime = a:GetAttribute("ParticleLifetime")
    if lifetime ~= nil then
        md.lifetimeMin = lifetime.Min
        md.lifetimeMax = lifetime.Max
    end

    md.colorOverLifetime = a:GetAttribute("ColorOverParticleLifetime")
    md.sizeOverLifetime = a:GetAttribute("SizeOverParticleLifetime")
    md.transparencyOverLifetime = a:GetAttribute("TransparencyOverParticleLifetime")

    md.rotationMin = a:GetAttribute("RotationMin")
    md.rotationMax = a:GetAttribute("RotationMax")

    md.anchored = a:GetAttribute("Anchored") == true
    md.collide = a:GetAttribute("Collide") == true

    md.emissionRate = a:GetAttribute("EmissionRate") or 0
    md.burstCount = a:GetAttribute("BurstCount")

    md:BeginCycle()

    return md
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
        pd.emitter.Enabled = pd.baseEnabled
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
    -- previously spawned mesh particles keep animating via the shared
    -- simulation loop; dropping the old drivers just stops further emission
    self.meshDrivers = {}

    local descendants = self.model:GetDescendants()
    for _,d in descendants do
        if d:IsA("ParticleEmitter") then
            local pd = initParticleEmitter(self, d)
            table.insert(self.particleDrivers, pd)
        elseif d:IsA("PointLight") or d:IsA("SpotLight") then
            local ld = initLight(self, d)
            table.insert(self.lightDrivers, ld)
        elseif d:IsA("Attachment") and CollectionService:HasTag(d, MESH_EMITTER_TAG) then
            local md = initMeshEmitter(self, d)
            table.insert(self.meshDrivers, md)
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

    for _,md in self.meshDrivers do
        md:Update(elapsedTime)
    end
end

return Sequence