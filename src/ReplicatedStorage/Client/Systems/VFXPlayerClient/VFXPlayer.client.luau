print("VFXPlayer v0.0.1")

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VFXPlayerClient = require(ReplicatedStorage.Client.Systems.VFXPlayerClient)

local function Init()
    local allSeqs = CollectionService:GetTagged("VFXSequence")
    for _,s in allSeqs do
        if s:GetAttribute("PlayOnStart") == true then
            print("Playing Sequence "..s.Name)
            VFXPlayerClient.PlayVFX(s)
        end
    end
end

task.wait(1) --prevents bug when waiting for content 
Init()
