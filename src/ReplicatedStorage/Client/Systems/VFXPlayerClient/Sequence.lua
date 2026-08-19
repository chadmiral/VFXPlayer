local Sequence = {
	name = "Sequence",
	_type = "Sequence",
	model = nil,
	--Two ways of saying how far along a sequence is, for the two loops that drive
	--one. A loop with a clock of its own notes the reading it started at; one
	--without adds up the time between frames instead, which is the only way that
	--works in the editor, where the game clock stands still.
	startTime = -1,
	elapsed = 0,
	duration = -1,
	looping = false,
	particleDrivers = {},
	lightDrivers = {},
	meshDrivers = {},
}

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LightDriver = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.LightDriver)
local MeshParticleDriver = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.MeshParticleDriver)
local ParticleDriver = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.ParticleDriver)
local Utility = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Utility)

local MESH_EMITTER_TAG = "MeshEmitter"

--The mesh a particle is made of and the effect it plays where it strikes something
--are each held by an ObjectValue child of the emitter, an attribute being unable to
--hold a reference to an instance. They are told apart by name.
local MESH_TEMPLATE_NAME = "MeshTemplate"
local COLLISION_SEQUENCE_NAME = "CollisionSequence"

local function namedObjectValue(inst, name: string)
	local found = inst:FindFirstChild(name)
	if found ~= nil and found:IsA("ObjectValue") then
		return found
	end
	return nil
end

--The mesh template, which an emitter authored before there was a second of these
--may hold under any name at all: back then there was nothing to tell it apart
--from, so anything that is not the impact effect still counts as one.
local function meshTemplateValue(inst)
	local named = namedObjectValue(inst, MESH_TEMPLATE_NAME)
	if named ~= nil then
		return named
	end

	for _, child in inst:GetChildren() do
		if child:IsA("ObjectValue") and child.Name ~= COLLISION_SEQUENCE_NAME then
			return child
		end
	end

	return nil
end

function Sequence:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end

--the three animation stages, in playback order
local STAGES = { "Stand", "Hold", "Decay" }

--read the timing (delay/duration/loop) attributes for a single stage on an instance
local function readStageTiming(inst, stage: string, standDurationFallback)
	local duration = inst:GetAttribute(stage .. "Duration")
	if duration == nil and stage == "Stand" then
		-- the stand stage spans the whole sequence by default
		duration = standDurationFallback
	end

	local loopCount = 1
	if stage == "Hold" then
		loopCount = inst:GetAttribute("HoldLoopCount") or 1
	end

	return {
		delay = inst:GetAttribute(stage .. "Delay") or 0,
		duration = duration or 0,
		loopCount = loopCount,
	}
end

--read the curve attributes for a particle emitter stage (e.g. "StandSizeScaleOverDuration")
local function readParticleStageCurves(e, stage: string)
	return {
		emissionScaleOverDuration = e:GetAttribute(stage .. "EmissionScaleOverDuration"),
		brightnessScaleOverDuration = e:GetAttribute(stage .. "BrightnessScaleOverDuration"),
		lightEmissionScaleOverDuration = e:GetAttribute(stage .. "LightEmissionScaleOverDuration"),
		lightInfluenceScaleOverDuration = e:GetAttribute(stage .. "LightInfluenceScaleOverDuration"),
		sizeScaleOverDuration = e:GetAttribute(stage .. "SizeScaleOverDuration"),
		transparencyScaleOverDuration = e:GetAttribute(stage .. "TransparencyScaleOverDuration"),
		tintOverDuration = e:GetAttribute(stage .. "TintOverDuration"),
	}
end

--read the curve attributes for a light stage
local function readLightStageCurves(l, stage: string)
	return {
		brightnessScaleOverDuration = l:GetAttribute(stage .. "BrightnessScaleOverDuration"),
		rangeScaleOverDuration = l:GetAttribute(stage .. "RangeScaleOverDuration"),
		angleScaleOverDuration = l:GetAttribute(stage .. "AngleScaleOverDuration"),
		tintOverDuration = l:GetAttribute(stage .. "TintOverDuration"),
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
			burstCount = inst:GetAttribute(stage .. "BurstCount"),
			curves = readCurves(inst, stage),
		})
	end
	return stages
end

--resolve a base animation value: prefer a `Base<Property>` attribute override on
--the instance, otherwise fall back to the instance's native property value.
--the attribute is what makes a base survive being played: a driver animates by
--writing the native property, so on a loop restart that property holds wherever
--the last frame left it rather than what the author asked for.
local function baseValue(inst, property, nativeValue)
	local override = inst:GetAttribute("Base" .. property)
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

	ld.baseBrightness = baseValue(l, "Brightness", l.Brightness)
	ld.baseRange = baseValue(l, "Range", l.Range)
	if ld.isSpotLight then
		ld.baseAngle = baseValue(l, "Angle", l.Angle)
	end
	ld.baseColor = baseValue(l, "Color", l.Color)

	local stages = buildStages(l, seq.duration, readLightStageCurves)
	ld.timeline = Utility.BuildTimeline(stages)

	ld:BeginCycle()

	return ld
end

--The effect played where a particle strikes, if it can be played at all: it is
--copied and pivoted into place, so it has to be a Model, and it is run against a
--length of its own, so it has to carry a Duration. Anything else is refused here,
--with a word about why, rather than left to fail the moment something is struck.
local function collisionSequenceTemplate(a)
	local held = namedObjectValue(a, COLLISION_SEQUENCE_NAME)
	local template = if held ~= nil then held.Value else nil
	if template == nil then
		return nil
	end

	if not template:IsA("Model") or typeof(template:GetAttribute("Duration")) ~= "number" then
		warn(
			"MeshEmitter '"
				.. a:GetFullName()
				.. "' has a CollisionSequence that is not a VFX sequence model with a Duration; "
				.. "nothing will play where its particles strike"
		)
		return nil
	end

	--An effect that is out of the world, or that has had its insides taken out from
	--under it, is what content streaming leaves behind: the client is far enough
	--away that it no longer holds the effect, and a reference to it keeps an empty
	--shell alive rather than going nil. Copies of that shell play perfectly and show
	--nothing at all, which is worth a word here, since nowhere further down is there
	--anything to notice.
	if not template:IsDescendantOf(game) or #template:GetDescendants() == 0 then
		warn(
			"MeshEmitter '"
				.. a:GetFullName()
				.. "' has a CollisionSequence '"
				.. template.Name
				.. "' that this client does not hold, most likely streamed out: an effect played from a "
				.. "template wants to live in ReplicatedStorage, or to be a model whose "
				.. "ModelStreamingMode is Persistent"
		)
		return nil
	end

	return template
end

--The mesh a particle is a copy of, if it can be copied at all. Every particle is
--sized, coloured and moved as a single part, so the template has to be one; a Model
--or a Folder pointed at here would otherwise throw on the first property read and
--take the whole effect's Init down with it, leaving none of its emitters playing.
local function meshTemplate(a)
	local held = meshTemplateValue(a)
	local template = if held ~= nil then held.Value else nil
	if template == nil then
		warn(
			"MeshEmitter '"
				.. a:GetFullName()
				.. "' has no ObjectValue pointing to a mesh template; no particles will spawn"
		)
		return nil
	end

	if not template:IsA("BasePart") then
		warn(
			"MeshEmitter '"
				.. a:GetFullName()
				.. "' has a MeshTemplate that is a "
				.. template.ClassName
				.. " rather than a single part; no particles will spawn"
		)
		return nil
	end

	return template
end

local function initMeshEmitter(seq, a)
	local md = MeshParticleDriver:new()
	md.emitter = a

	md.template = meshTemplate(a)
	if md.template ~= nil then
		md.baseSize = md.template.Size

		-- scalar folded into the base size; because base size is only applied
		-- alongside SizeOverParticleLifetime, this multiplies against that curve
		local sizeMultiplier = a:GetAttribute("SizeMultiplier")
		if sizeMultiplier ~= nil then
			md.baseSize = md.baseSize * sizeMultiplier
		end
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

	md.initialVelocity = a:GetAttribute("InitialVelocity")

	md.anchored = a:GetAttribute("Anchored") == true
	md.collide = a:GetAttribute("Collide") == true

	-- read whether or not Collide is set, so that turning Collide on is all it
	-- takes to start playing the effect the author has already pointed at
	md.collisionGroup = a:GetAttribute("CollisionGroup")
	md.collisionSequence = collisionSequenceTemplate(a)

	md.emissionRate = a:GetAttribute("EmissionRate") or 0
	md.burstCount = a:GetAttribute("BurstCount")

	local stages = buildStages(a, seq.duration, readLightStageCurves)
	md.timeline = Utility.BuildTimeline(stages)

	md:BeginCycle()

	return md
end

--reset all playing emitters to their starting states
local function resetParticleDrivers(seq)
	for _, pd in seq.particleDrivers do
		pd.emitter.Rate = pd.baseRate
		pd.emitter.Brightness = pd.baseBrightness
		pd.emitter.LightEmission = pd.baseLightEmission
		pd.emitter.LightInfluence = pd.baseLightInfluence
		pd.emitter.Size = pd.baseSize
		pd.emitter.Color = pd.baseColor
		pd.emitter.Transparency = pd.baseTransparency

		--Enabled is the author's own switch rather than something the sequence
		--animates, so the only thing to undo here is a distance cull of this
		--driver's own making. Writing back a value captured when the sequence
		--started would overwrite an author who reached for that switch since.
		if pd.culled then
			pd.culled = false
			pd.emitter.Enabled = true
		end
	end
end

--reset all playing lights to their starting states
local function resetLightDrivers(seq)
	for _, ld in seq.lightDrivers do
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
	for _, d in descendants do
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
	for _, pd in self.particleDrivers do
		pd:Update(elapsedTime)
	end

	for _, ld in self.lightDrivers do
		ld:Update(elapsedTime)
	end

	for _, md in self.meshDrivers do
		md:Update(elapsedTime)
	end
end

return Sequence
