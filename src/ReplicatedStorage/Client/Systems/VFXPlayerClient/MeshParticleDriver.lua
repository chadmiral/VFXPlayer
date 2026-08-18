local MeshParticleDriver = {
	name = "MeshParticleDriver",
	_type = "MeshParticleDriver",

	-- ordered stage timeline (stand -> hold -> decay); see Utility.BuildTimeline
	timeline = nil,

	emitter = nil, -- the Attachment tagged "MeshEmitter"
	template = nil, -- the BasePart/MeshPart cloned for each particle
	baseSize = nil, -- Vector3, the template's Size (uniform scale base)

	lifetimeMin = 1,
	lifetimeMax = 1,

	colorOverLifetime = nil, -- ColorSequence
	sizeOverLifetime = nil, -- NumberSequence (uniform scale multiplier)
	transparencyOverLifetime = nil, -- NumberSequence

	rotationMin = nil, -- Vector3 of Euler angles in degrees
	rotationMax = nil, -- Vector3 of Euler angles in degrees

	-- Vector3 in studs per second, in world space, given to each particle as it
	-- spawns. It is a launch and not a path: the particle is let go at this speed
	-- and carries on from there, either by physics or by hand; see SpawnParticle.
	initialVelocity = nil,

	anchored = false,
	collide = false,

	emissionRate = 0, -- particles per second
	burstCount = nil, -- one-shot particles emitted once when the first stage begins

	burstFired = false,
	-- tracks the stage entry whose burst was last emitted, so each stage fires
	-- its burst exactly once (even while the Hold stage loops)
	lastBurstEntry = nil,
	spawnAccumulator = 0,
	lastElapsed = 0,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Utility = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Utility)

-- Particles are simulated by a single, module-wide Heartbeat loop rather than
-- per-driver. This lets particles keep animating and get destroyed on schedule
-- even after their sequence has ended or looped, with no per-driver connections
-- to leak. The loop disconnects itself whenever no particles remain.
local activeParticles = {}
local heartbeatConnection = nil
local particleContainer = nil

local function getParticleContainer()
	if particleContainer ~= nil and particleContainer.Parent ~= nil then
		return particleContainer
	end
	particleContainer = Instance.new("Folder")
	particleContainer.Name = "VFXMeshParticles"
	particleContainer.Parent = Workspace
	return particleContainer
end

--advance, animate, and cull every live particle; runs once per frame
local function stepParticles(dt)
	-- the pull physics would be applying, for the particles the driver is moving
	-- in its place
	local gravityStep = Vector3.new(0, -Workspace.Gravity * dt, 0)

	local i = 1
	while i <= #activeParticles do
		local p = activeParticles[i]
		p.elapsed += dt
		local t = p.elapsed / p.lifetime

		if t >= 1 or p.part.Parent == nil then
			p.part:Destroy()
			-- swap-remove to keep culling O(1) per particle
			local last = #activeParticles
			activeParticles[i] = activeParticles[last]
			activeParticles[last] = nil
		else
			-- carried by hand only when physics is not carrying it; see SpawnParticle
			if p.velocity ~= nil then
				if p.falls then
					p.velocity += gravityStep
				end
				p.part.CFrame += p.velocity * dt
			end

			if p.colorOverLifetime ~= nil then
				p.part.Color = Utility.EvalColorSequence(p.colorOverLifetime, t)
			end
			if p.sizeOverLifetime ~= nil then
				p.part.Size = p.baseSize * Utility.EvalNumberSequence(p.sizeOverLifetime, t)
			end
			if p.transparencyOverLifetime ~= nil then
				p.part.Transparency = Utility.EvalNumberSequence(p.transparencyOverLifetime, t)
			end
			i += 1
		end
	end

	if #activeParticles == 0 and heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function ensureSimulationRunning()
	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepParticles)
	end
end

function MeshParticleDriver:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end

--reset per-cycle emission state at the start of a sequence or loop
function MeshParticleDriver:BeginCycle()
	self.burstFired = false
	self.lastBurstEntry = nil
	self.spawnAccumulator = 0
	self.lastElapsed = 0
end

--randomly sample a point inside `part`, in the part's own space, spread evenly
--through its volume rather than gathered anywhere within it
--
--Each of the shapes Roblox draws is sampled directly, so no point is ever picked
--and thrown away for having landed outside the solid, and none of them crowds a
--centre or a pole the way the obvious form of each does. Anything with no
--interior the engine will describe -- a MeshPart, a union, a truss -- is filled
--as the box its Size spans, which is the volume Studio itself draws around it.
local function samplePointInPart(part)
	local half = part.Size / 2

	-- Part carries its shape in a property, while the two wedges are classes of
	-- their own; everything else falls through to the box below.
	local shape = nil
	if part:IsA("Part") then
		shape = part.Shape
	elseif part:IsA("WedgePart") then
		shape = Enum.PartType.Wedge
	elseif part:IsA("CornerWedgePart") then
		shape = Enum.PartType.CornerWedge
	end

	if shape == Enum.PartType.Ball then
		-- A Ball is a true sphere however unevenly it is sized, taking its diameter
		-- from its narrowest axis: the roundest volume that fits in the box.
		local radius = math.min(half.X, half.Y, half.Z)
		-- An even scatter over a sphere comes from a uniform height rather than a
		-- uniform angle, which would gather at the poles. Scaling by a cube root
		-- then spreads it through the interior, where a uniform radius would gather
		-- at the centre: nearly all of a sphere's room is in its outer shells.
		local height = 2 * math.random() - 1
		local ring = math.sqrt(1 - height * height)
		local angle = 2 * math.pi * math.random()
		local radiusAt = radius * math.random() ^ (1 / 3)
		return Vector3.new(radiusAt * ring * math.cos(angle), radiusAt * ring * math.sin(angle), radiusAt * height)
	end

	if shape == Enum.PartType.Cylinder then
		-- A Cylinder lies along its X axis, and like a Ball keeps a circular section
		-- however its other two axes are sized, taking its radius from the smaller.
		local radius = math.min(half.Y, half.Z)
		-- The square root spreads the points evenly across the disc; a uniform
		-- radius would gather at the axis, since a ring's room grows as it widens.
		local radiusAt = radius * math.sqrt(math.random())
		local angle = 2 * math.pi * math.random()
		return Vector3.new((2 * math.random() - 1) * half.X, radiusAt * math.cos(angle), radiusAt * math.sin(angle))
	end

	if shape == Enum.PartType.Wedge then
		-- A Wedge stands full height across its +Z face and tapers away to the
		-- bottom edge of -Z, so its section is the triangle where y/half.Y is at or
		-- below z/half.Z, drawn out evenly along X.
		--
		-- Two uniform numbers scatter evenly over the square that triangle is half
		-- of; folding the far half back onto the near one keeps the scatter even
		-- while landing every point inside the wedge.
		local u, v = math.random(), math.random()
		if u + v > 1 then
			u, v = 1 - u, 1 - v
		end
		return Vector3.new((2 * math.random() - 1) * half.X, (2 * v - 1) * half.Y, (2 * (u + v) - 1) * half.Z)
	end

	if shape == Enum.PartType.CornerWedge then
		-- A CornerWedge is a pyramid: the whole of its -Y face for a base, rising to
		-- a point above the one corner where +X meets -Z. Its section is that base
		-- shrunk towards the corner as it climbs, and because it closes to nothing
		-- rather than merely narrowing, the height is drawn from a cube root --
		-- there is seven times as much room in the lower half as in the upper.
		local climb = 1 - math.random() ^ (1 / 3)
		local section = 1 - climb
		return Vector3.new(
			half.X - 2 * half.X * section * math.random(),
			(2 * climb - 1) * half.Y,
			-half.Z + 2 * half.Z * section * math.random()
		)
	end

	return Vector3.new(
		(2 * math.random() - 1) * half.X,
		(2 * math.random() - 1) * half.Y,
		(2 * math.random() - 1) * half.Z
	)
end

--randomly sample an initial rotation between the min/max Euler angles (degrees)
local function sampleRotation(rotationMin, rotationMax)
	if rotationMin == nil and rotationMax == nil then
		return CFrame.identity
	end
	rotationMin = rotationMin or Vector3.zero
	rotationMax = rotationMax or Vector3.zero
	local x = rotationMin.X + (rotationMax.X - rotationMin.X) * math.random()
	local y = rotationMin.Y + (rotationMax.Y - rotationMin.Y) * math.random()
	local z = rotationMin.Z + (rotationMax.Z - rotationMin.Z) * math.random()
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

function MeshParticleDriver:SpawnParticle()
	local template = self.template
	if template == nil then
		return
	end

	local part = template:Clone()
	part.Anchored = self.anchored
	part.CanCollide = self.collide
	-- particles never participate in touch/spatial queries, for efficiency
	part.CanTouch = false
	part.CanQuery = false

	local lifetime = self.lifetimeMin
	if self.lifetimeMax > self.lifetimeMin then
		lifetime = self.lifetimeMin + (self.lifetimeMax - self.lifetimeMin) * math.random()
	end
	if lifetime <= 0 then
		lifetime = 0.0001
	end

	-- The part an emitter hangs off is its emission volume, so particles come from
	-- everywhere inside it rather than all from the one point. Terrain is the one
	-- part that is not a volume anyone means: its Size is the whole world's.
	-- An emitter parented to anything else has only its own position to emit from.
	local host = self.emitter.Parent
	local origin
	if host ~= nil and host:IsA("BasePart") and not host:IsA("Terrain") then
		origin = host.CFrame * samplePointInPart(host)
	else
		origin = self.emitter.WorldPosition
	end

	-- Only the position is taken from the volume. A particle's own rotation is
	-- sampled apart from it, so turning the emitter's part moves where particles
	-- appear without turning the particles themselves.
	part.CFrame = CFrame.new(origin) * sampleRotation(self.rotationMin, self.rotationMax)

	-- apply the t = 0 state before parenting to avoid a one-frame pop
	if self.sizeOverLifetime ~= nil then
		part.Size = self.baseSize * Utility.EvalNumberSequence(self.sizeOverLifetime, 0)
	end
	if self.colorOverLifetime ~= nil then
		part.Color = Utility.EvalColorSequence(self.colorOverLifetime, 0)
	end
	if self.transparencyOverLifetime ~= nil then
		part.Transparency = Utility.EvalNumberSequence(self.transparencyOverLifetime, 0)
	end

	part.Parent = getParticleContainer()

	-- Physics moves a particle only when the simulation is running and the particle
	-- is not anchored. Neither holds in the editor, which plays effects with the
	-- simulation stopped, and the second never holds for an anchored particle
	-- anywhere. So whenever physics is not going to carry the velocity, the driver
	-- carries it instead, and an authored velocity means the same thing wherever the
	-- effect is played.
	local velocity = nil
	local falls = false

	if RunService:IsRunning() and not part.Anchored then
		-- Set after parenting rather than alongside the state above: velocity
		-- belongs to the assembly a part is part of, and a part outside the world is
		-- not in one yet.
		if self.initialVelocity ~= nil then
			part.AssemblyLinearVelocity = self.initialVelocity
		end
	elseif not part.Anchored then
		-- Standing in for physics rather than doing something else: this particle
		-- would be falling if the simulation were running, so it falls here too and
		-- the editor shows what the game will.
		velocity = self.initialVelocity or Vector3.zero
		falls = true
	elseif self.initialVelocity ~= nil then
		-- An anchored particle is never touched by physics, so its velocity is a
		-- steady drift at the speed it was given, the same in the editor as in the
		-- game: the way to author motion that does not fall.
		velocity = self.initialVelocity
	end

	table.insert(activeParticles, {
		part = part,
		elapsed = 0,
		lifetime = lifetime,
		velocity = velocity,
		falls = falls,
		baseSize = self.baseSize,
		colorOverLifetime = self.colorOverLifetime,
		sizeOverLifetime = self.sizeOverLifetime,
		transparencyOverLifetime = self.transparencyOverLifetime,
	})

	ensureSimulationRunning()
end

--spawn `count` particles at once, independent of EmissionRate, so a pure-burst
--emitter works with EmissionRate = 0
function MeshParticleDriver:SpawnBurst(count)
	if count == nil or self.template == nil then
		return
	end
	for _ = 1, count do
		self:SpawnParticle()
	end
end

function MeshParticleDriver:Update(elapsedTime)
	local dt = elapsedTime - self.lastElapsed
	self.lastElapsed = elapsedTime

	if self.timeline == nil or #self.timeline == 0 then
		return
	end

	local _, _, active, frozen, entry = Utility.ResolveTimeline(self.timeline, elapsedTime)

	-- still inside the leading delay: the emitter has not started yet
	if not active then
		return
	end

	-- the emitter-level BurstCount fires once, as the first stage begins
	if not self.burstFired then
		self.burstFired = true
		self:SpawnBurst(self.burstCount)
	end

	-- each stage's own BurstCount fires once as that stage begins; the looping
	-- Hold stage does NOT re-fire on subsequent loop iterations
	if not frozen and entry ~= nil and entry ~= self.lastBurstEntry then
		self.lastBurstEntry = entry
		self:SpawnBurst(entry.burstCount)
	end

	-- in a gap between stages, or past the final stage: already-spawned
	-- particles live out their lifetimes, but no new ones are emitted
	if frozen then
		return
	end

	-- ignore non-positive steps (loops/resets) and clamp large steps so a lag
	-- spike or tab-out cannot spawn a flood of particles in a single frame
	if dt <= 0 then
		return
	end
	if dt > 0.1 then
		dt = 0.1
	end

	if self.emissionRate <= 0 or self.template == nil then
		return
	end

	self.spawnAccumulator += dt * self.emissionRate
	while self.spawnAccumulator >= 1 do
		self:SpawnParticle()
		self.spawnAccumulator -= 1
	end
end

return MeshParticleDriver
