Utility = {}

function Utility.EvalNumberSequence(sequence: NumberSequence, time: number)
    -- If time is 0 or 1, return the first or last value respectively
    if time == 0 then
        return sequence.Keypoints[1].Value
    elseif time == 1 then
        return sequence.Keypoints[#sequence.Keypoints].Value
    end

    -- Otherwise, step through each sequential pair of keypoints
    for i = 1, #sequence.Keypoints - 1 do
        local currKeypoint = sequence.Keypoints[i]
        local nextKeypoint = sequence.Keypoints[i + 1]
        if time >= currKeypoint.Time and time < nextKeypoint.Time then
            -- Calculate how far alpha lies between the points
            local alpha = (time - currKeypoint.Time) / (nextKeypoint.Time - currKeypoint.Time)
            -- Return the value between the points using alpha
            return currKeypoint.Value + (nextKeypoint.Value - currKeypoint.Value) * alpha
        end
    end
end

function Utility.EvalColorSequence(sequence: ColorSequence, time: number)
    -- If time is 0 or 1, return the first or last value respectively
    if time == 0 then
        return sequence.Keypoints[1].Value
    elseif time == 1 then
        return sequence.Keypoints[#sequence.Keypoints].Value
    end

    -- Otherwise, step through each sequential pair of keypoints
    for i = 1, #sequence.Keypoints - 1 do
        local thisKeypoint = sequence.Keypoints[i]
        local nextKeypoint = sequence.Keypoints[i + 1]
        if time >= thisKeypoint.Time and time < nextKeypoint.Time then
            -- Calculate how far alpha lies between the points
            local alpha = (time - thisKeypoint.Time) / (nextKeypoint.Time - thisKeypoint.Time)
            -- Evaluate the real value between the points using alpha
            return Color3.new(
                (nextKeypoint.Value.R - thisKeypoint.Value.R) * alpha + thisKeypoint.Value.R,
                (nextKeypoint.Value.G - thisKeypoint.Value.G) * alpha + thisKeypoint.Value.G,
                (nextKeypoint.Value.B - thisKeypoint.Value.B) * alpha + thisKeypoint.Value.B
            )
        end
    end
end

-- Scale every keypoint value of a NumberSequence by a scalar.
function Utility.ScaleNumberSequence(sequence: NumberSequence, scale: number)
    local newKeypoints = {}
    for i = 1, #sequence.Keypoints do
        local kp = sequence.Keypoints[i]
        table.insert(newKeypoints, NumberSequenceKeypoint.new(kp.Time, kp.Value * scale))
    end
    return NumberSequence.new(newKeypoints)
end

-- Multiply every keypoint of a ColorSequence by a tint color (per RGB channel).
function Utility.TintColorSequence(sequence: ColorSequence, tint: Color3)
    local newKeypoints = {}
    for i = 1, #sequence.Keypoints do
        local kp = sequence.Keypoints[i]
        local c = kp.Value
        table.insert(newKeypoints, ColorSequenceKeypoint.new(kp.Time, Color3.new(c.R * tint.R, c.G * tint.G, c.B * tint.B)))
    end
    return ColorSequence.new(newKeypoints)
end

-- Build a sequential stage timeline from an ordered list of stage definitions.
--
-- Each stage definition is a table: { name, delay, duration, loopCount, curves,
-- burstCount }. `curves` and `burstCount` are opaque to this helper and are
-- copied onto the resulting entry for the caller to interpret.
-- Stages play back-to-back in the given order. A stage's `delay` inserts a gap
-- before it begins, measured from the end of the previous stage (or from the
-- sequence start for the first stage). A stage with `duration <= 0` is skipped
-- entirely (its delay is ignored). `loopCount` repeats the stage window that
-- many times (defaults to 1).
--
-- Returns an ordered array of active-stage entries, each with absolute `start`
-- and `finish` times plus the single-iteration `duration` and `loopCount`.
function Utility.BuildTimeline(stages)
    local timeline = {}
    local cursor = 0
    for _, stage in stages do
        local duration = stage.duration or 0
        if duration > 0 then
            local loopCount = stage.loopCount or 1
            if loopCount < 1 then
                loopCount = 1
            end
            local start = cursor + (stage.delay or 0)
            local finish = start + duration * loopCount
            table.insert(timeline, {
                name = stage.name,
                curves = stage.curves,
                burstCount = stage.burstCount,
                start = start,
                duration = duration,
                loopCount = loopCount,
                finish = finish,
            })
            cursor = finish
        end
    end
    return timeline
end

-- Resolve which stage is active at `elapsedTime` on a timeline from BuildTimeline.
--
-- Returns `curves, t, active, frozen, entry, iteration`:
--   * active == false  -> before the first stage begins; caller should hold at
--                         its starting (off) state. `curves`/`t` are undefined.
--   * active == true, frozen == false -> `curves` is the currently-playing stage
--                         curve set to apply at normalized time `t` (0 -> 1).
--                         `entry` is the stage's timeline entry and `iteration`
--                         is its zero-based loop iteration (always 0 for stages
--                         that do not loop).
--   * active == true, frozen == true  -> a stage has elapsed and the effect is
--                         being held: `curves` is the previous/last stage frozen
--                         at t = 1 (during gaps between stages, and after the
--                         final stage). Callers may treat this differently from
--                         a live stage (e.g. stop spawning new particles).
--                         `entry`/`iteration` are nil while frozen.
function Utility.ResolveTimeline(timeline, elapsedTime)
    if #timeline == 0 then
        return nil, 0, false, false, nil, nil
    end

    if elapsedTime < timeline[1].start then
        return nil, 0, false, false, nil, nil
    end

    for i = 1, #timeline do
        local entry = timeline[i]
        if elapsedTime < entry.finish then
            if elapsedTime < entry.start then
                -- Gap before this stage: freeze the previous stage at its end.
                return timeline[i - 1].curves, 1, true, true, nil, nil
            end
            local localElapsed = elapsedTime - entry.start
            local iteration = math.floor(localElapsed / entry.duration)
            local t = (localElapsed % entry.duration) / entry.duration
            return entry.curves, t, true, false, entry, iteration
        end
    end

    -- Past the final stage: freeze it at its end.
    local last = timeline[#timeline]
    return last.curves, 1, true, true, nil, nil
end

return Utility