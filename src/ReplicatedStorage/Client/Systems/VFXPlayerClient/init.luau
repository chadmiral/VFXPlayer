local VFXPlayerClient = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Sequence = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Sequence)

-- Playing sequences are advanced by a single shared Heartbeat loop that only
-- runs while something is playing.
local activeSequences = {}
local heartbeatConnection = nil

local function pruneActiveSequences()
	for i = #activeSequences, 1, -1 do
		if activeSequences[i] == nil then
			table.remove(activeSequences, i)
		end
	end
end

--Advance every playing sequence; looping sequences restart, one-shots are
--retired and any instance spawned by PlayVFX is destroyed with them.
--
--Progress is added up frame by frame rather than read off the game clock, which
--stands still while a place is only being edited. Reading a clock there would leave
--every sequence sitting at nought for ever: frozen on its first frame, never
--reaching its end, and so never cleaned up.
local function stepSequences(deltaTime: number)
	pruneActiveSequences()

	local i = 1
	while i <= #activeSequences do
		local s = activeSequences[i]
		s.elapsed += deltaTime

		if s.elapsed > s.duration then
			if s.looping then
				s.elapsed = 0
				s:Init()
				i += 1
			else
				table.remove(activeSequences, i)
				if s.destroyModelOnComplete and s.model ~= nil then
					s.model:Destroy()
				end
			end
		else
			s:Update(s.elapsed)
			i += 1
		end
	end

	if #activeSequences == 0 and heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function ensurePlaybackRunning()
	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepSequences)
	end
end

local function startSequence(model, destroyModelOnComplete)
	local newSeq = Sequence:new()
	newSeq.model = model
	newSeq.elapsed = 0
	newSeq.duration = model:GetAttribute("Duration")
	newSeq.looping = model:GetAttribute("Looping")
	--playback bookkeeping: only instances spawned by PlayVFX are ours to destroy
	newSeq.destroyModelOnComplete = destroyModelOnComplete

	newSeq:Init()

	table.insert(activeSequences, newSeq)
	ensurePlaybackRunning()

	return newSeq
end

--play a VFXSequence model that is already placed in the world. The model is
--left in place when playback completes.
function VFXPlayerClient.PlaySequence(model)
	return startSequence(model, false)
end

--put a copy of `template` into the world at `cframe`, ready to be played
local function spawnCopy(template: Model, cframe: CFrame)
	local instance = template:Clone()
	-- position before parenting so the copy never renders at the template's spot
	instance:PivotTo(cframe)
	--A copy exists only while it is playing, so it is nothing the place should ever
	--hold: unarchivable keeps whichever copies happen to be in flight when a place
	--is saved from being written into the file, which in the editor is the
	--difference between an effect and a mess left behind in the Explorer.
	instance.Archivable = false
	instance.Parent = Workspace
	return instance
end

--spawn a copy of a VFX template at `cframe` and play it, returning the spawned
--instance. A one-shot template's copy is destroyed once playback completes; a
--template with Looping set plays continuously, so destroy the returned instance
--when you want it to stop.
function VFXPlayerClient.PlayVFXFromTemplate(template: Model, cframe: CFrame)
	local instance = spawnCopy(template, cframe)

	local looping = instance:GetAttribute("Looping") == true
	startSequence(instance, not looping)

	return instance
end

--Spawn a copy of a VFX template at `cframe` and play it through once, whatever the
--template does when it is played in its own right, destroying the copy at the end.
--
--For an effect nobody is left holding: an impact happens once, and a copy set
--looping would have nothing to stop it and no one to notice it was still there, so
--one would be left behind at every strike.
function VFXPlayerClient.PlayVFXOnce(template: Model, cframe: CFrame)
	local instance = spawnCopy(template, cframe)
	--the copy really is a one-shot, and says so, so that anything reading it later
	--sees what it is being played as
	instance:SetAttribute("Looping", false)
	startSequence(instance, true)

	return instance
end

--assumed to be already placed in the world / workspace (environment vfx)
function VFXPlayerClient.PlayVFX(instance: Model)
	local looping = instance:GetAttribute("Looping") == true
	startSequence(instance, not looping)
end

--[[
local function onVFXSequenceLoaded(s)
    print("onVFXSequenceLoaded")
    if s and s:IsDescendantOf(workspace) and s:GetAttribute("PlayOnStart") == true then
        print("Playing Sequence "..s.Name)
        VFXPlayerClient.PlayVFX(s)
    end
end
--]]

function VFXPlayerClient.start()
	--print("Initializing VFXPlayer...")

	--[[
    --play all hand-placed environment VFX (which should be tagged as PlayOnStart / Looping)
    local allSeqs = CollectionService:GetTagged("VFXSequence")
    for _,s in allSeqs do
        task.spawn(onVFXSequenceLoaded, s)
    end--]]

	--CollectionService:GetInstanceAddedSignal("VFXSequence"):Connect(onVFXSequenceLoaded)
end

return VFXPlayerClient
