MeshParticleDriver = {
    name = "MeshParticleDriver",
    _type = "MeshParticleDriver",

    emitter = nil,          -- the Attachment tagged "MeshEmitter"
    template = nil,         -- the BasePart/MeshPart cloned for each particle
    baseSize = nil,         -- Vector3, the template's Size (uniform scale base)

    lifetimeMin = 1,
    lifetimeMax = 1,

    colorOverLifetime = nil,        -- ColorSequence
    sizeOverLifetime = nil,         -- NumberSequence (uniform scale multiplier)
    transparencyOverLifetime = nil, -- NumberSequence

    rotationMin = nil,      -- Vector3 of Euler angles in degrees
    rotationMax = nil,      -- Vector3 of Euler angles in degrees

    anchored = false,
    collide = false,

    emissionRate = 0,       -- particles per second
    burstCount = nil,       -- one-shot particles emitted once when the cycle begins

    burstFired = false,
    spawnAccumulator = 0,
    lastElapsed = 0,
}

local Utility = require(script.Parent:WaitForChild("Utility"))

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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
    self.spawnAccumulator = 0
    self.lastElapsed = 0
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

    -- spawn at the emitter's current world position with a sampled rotation
    part.CFrame = CFrame.new(self.emitter.WorldPosition) * sampleRotation(self.rotationMin, self.rotationMax)

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

    table.insert(activeParticles, {
        part = part,
        elapsed = 0,
        lifetime = lifetime,
        baseSize = self.baseSize,
        colorOverLifetime = self.colorOverLifetime,
        sizeOverLifetime = self.sizeOverLifetime,
        transparencyOverLifetime = self.transparencyOverLifetime,
    })

    ensureSimulationRunning()
end

function MeshParticleDriver:Update(elapsedTime)
    -- one-shot burst, emitted once when the cycle begins (independent of
    -- EmissionRate, so a pure-burst emitter works with EmissionRate = 0)
    if not self.burstFired then
        self.burstFired = true
        if self.burstCount ~= nil and self.template ~= nil then
            for _ = 1, self.burstCount do
                self:SpawnParticle()
            end
        end
    end

    local dt = elapsedTime - self.lastElapsed
    self.lastElapsed = elapsedTime

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
