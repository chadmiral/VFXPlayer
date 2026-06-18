LightDriver = {
    name = "LightDriver",
    _type = "LightDriver",
    light = nil,
    duration = nil,
    delay = nil,

    isSpotLight = false,

    baseBrightness = nil,
    brightnessScaleOverDuration = nil,

    baseRange = nil,
    rangeScaleOverDuration = nil,

    baseAngle = nil,
    angleScaleOverDuration = nil,

    baseColor = nil,
    tintOverDuration = nil,
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

function LightDriver:ApplyCurves(t)
    if self.brightnessScaleOverDuration ~= nil then
        local brightnessScale = Utility.EvalNumberSequence(self.brightnessScaleOverDuration, t)
        self.light.Brightness = self.baseBrightness * brightnessScale
    else
        self.light.Brightness = self.baseBrightness
    end

    if self.rangeScaleOverDuration ~= nil then
        local rangeScale = Utility.EvalNumberSequence(self.rangeScaleOverDuration, t)
        self.light.Range = self.baseRange * rangeScale
    end

    if self.isSpotLight and self.angleScaleOverDuration ~= nil then
        local angleScale = Utility.EvalNumberSequence(self.angleScaleOverDuration, t)
        self.light.Angle = self.baseAngle * angleScale
    end

    if self.tintOverDuration ~= nil then
        local tint = Utility.EvalColorSequence(self.tintOverDuration, t)
        self.light.Color = Color3.new(self.baseColor.R * tint.R, self.baseColor.G * tint.G, self.baseColor.B * tint.B)
    end
end

function LightDriver:Update(elapsedTime)
    local delay = self.delay or 0
    if elapsedTime < delay then
        self:HoldAtStart()
        return
    end

    local duration = self.duration
    if duration == nil or duration <= 0 then
        return
    end

    local localElapsed = elapsedTime - delay
    local t = math.clamp(localElapsed / duration, 0, 1)
    self:ApplyCurves(t)
end

return LightDriver
