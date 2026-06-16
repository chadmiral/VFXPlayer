Sequence = { name = "Sequence", _type = "Sequence", model = nil, startTime = -1, duration = -1, looping = false }

local Utility = require(script.Parent:WaitForChild("Utility"))

function Sequence:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Sequence:Update(elapsedTime)
    local t = elapsedTime / self.duration
    print("Updating sequence "..self.model.Name.." elapsedTime: "..elapsedTime.." t: "..t)
end

return Sequence