LightDriver = {
    name = "LightDriver",
    _type = "LightDriver",
    light = nil,

    isSpotLight = false,

    -- ordered stage timeline (stand -> hold -> decay); see Utility.BuildTimeline
    timeline = nil,

    baseBrightness = nil,
    baseRange = nil,
    baseAngle = nil,
    baseColor = nil,
}

local Utility = require(script.Parent:WaitForChild("Utility"))

function LightDriver:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--restore the light to its starting state and switch it off during the delay window
function LightDriver:HoldAtStart()
    self.light.Brightness = 0
    self.light.Color = self.baseColor
    self.light.Range = self.baseRange
    if self.isSpotLight then
        self.light.Angle = self.baseAngle
    end
end

--reset per-cycle state at the start of a sequence or loop
function LightDriver:BeginCycle()
    self:HoldAtStart()
end

--apply a single stage's curve set at normalized time t; properties whose curve
--is absent for this stage fall back to the light's base value
function LightDriver:ApplyCurves(curves, t)
    if curves.brightnessScaleOverDuration ~= nil then
        local brightnessScale = Utility.EvalNumberSequence(curves.brightnessScaleOverDuration, t)
        self.light.Brightness = self.baseBrightness * brightnessScale
    else
        self.light.Brightness = self.baseBrightness
    end

    if curves.rangeScaleOverDuration ~= nil then
        local rangeScale = Utility.EvalNumberSequence(curves.rangeScaleOverDuration, t)
        self.light.Range = self.baseRange * rangeScale
    else
        self.light.Range = self.baseRange
    end

    if self.isSpotLight then
        if curves.angleScaleOverDuration ~= nil then
            local angleScale = Utility.EvalNumberSequence(curves.angleScaleOverDuration, t)
            self.light.Angle = self.baseAngle * angleScale
        else
            self.light.Angle = self.baseAngle
        end
    end

    if curves.tintOverDuration ~= nil then
        local tint = Utility.EvalColorSequence(curves.tintOverDuration, t)
        self.light.Color = Color3.new(self.baseColor.R * tint.R, self.baseColor.G * tint.G, self.baseColor.B * tint.B)
    else
        self.light.Color = self.baseColor
    end
end

function LightDriver:Update(elapsedTime)
    if self.timeline == nil or #self.timeline == 0 then
        self:HoldAtStart()
        return
    end

    local curves, t, active = Utility.ResolveTimeline(self.timeline, elapsedTime)
    if not active or curves == nil then
        self:HoldAtStart()
        return
    end

    self:ApplyCurves(curves, t)
end

return LightDriver
