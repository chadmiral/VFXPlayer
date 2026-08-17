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

--advance every playing sequence; looping sequences restart, one-shots are
--retired and any instance spawned by PlayVFX is destroyed with them
local function stepSequences()
	pruneActiveSequences()

	local timeStamp = time()
	local i = 1
	while i <= #activeSequences do
		local s = activeSequences[i]
		local elapsedTime = timeStamp - s.startTime

		if elapsedTime > s.duration then
			if s.looping then
				s.startTime = timeStamp
				s:Init()
				i += 1
			else
				table.remove(activeSequences, i)
				if s.destroyModelOnComplete and s.model ~= nil then
					s.model:Destroy()
				end
			end
		else
			s:Update(elapsedTime)
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
	newSeq.startTime = time()
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

--spawn a copy of a VFX template at `cframe` and play it, returning the spawned
--instance. A one-shot template's copy is destroyed once playback completes; a
--template with Looping set plays continuously, so destroy the returned instance
--when you want it to stop.
function VFXPlayerClient.PlayVFXFromTemplate(template: Model, cframe: CFrame)
	local instance = template:Clone()
	-- position before parenting so the copy never renders at the template's spot
	instance:PivotTo(cframe)
	instance.Parent = Workspace

	local looping = instance:GetAttribute("Looping") == true
	startSequence(instance, not looping)

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
