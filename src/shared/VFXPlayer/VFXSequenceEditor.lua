--[[
	VFXSequenceEditor

	A popout editor for the NumberSequence and ColorSequence parameters, opened
	from the VFX Editor's parameter pane. It is a floating dock widget rather
	than an overlay inside the window that opened it, so it can be moved aside
	and resized while you work.

	Studio's own sequence editor cannot be opened by a plugin -- there is no API
	for it -- so this is a rebuild of the parts that matter: drag a keypoint to
	move it, click the surface to add one, right-click a keypoint to remove it,
	and type exact values into the fields underneath.

	A number keypoint also carries an envelope, the distance either way its value
	is allowed to land at runtime, which the engine picks within per particle. It
	is drawn as the two edges of a band around the curve and dragged by the
	handles above and below the selected keypoint.

	Colour sequences get a picker as well, for the same reason: Studio's colour
	dialog has no plugin API either. It is the usual saturation/value square
	beside a hue bar, and it edits whichever keypoint is selected.

	That picker is also what a plain Color3 parameter opens, as the "color" kind:
	the same window with the gradient, the keypoints and their times taken away,
	leaving the square, the hue bar and the hex field to edit the one colour.

	Edits are written straight back through the commit function the caller
	passes in, one write per completed change, so each drag or typed value is a
	single undo step.

	Adapted from the editor of the same name in the ScatterGraph plugin.
]]

local UserInputService = game:GetService("UserInputService")

local VFXSequenceEditor = {}

local PADDING = 8
local ROW_HEIGHT = 22
local TITLE_HEIGHT = 18
local HINT_HEIGHT = 16
local SURFACE_TOP = 30
local MARKER_SIZE = 10
local GRADIENT_HEIGHT = 44
local STRIP_HEIGHT = 20
local HUE_WIDTH = 18
--the gap between a field's label and the field, and between one field and the
--next label along
local LABEL_GAP = 2
local FIELD_GAP = 6
--The bar dragged to widen a keypoint's envelope. It runs vertically, from clear
--of the keypoint out to the edge of the band, which is the direction it is
--dragged in and gives a whole line's worth of it to aim at.
local ENVELOPE_HANDLE_WIDTH = 5
local ENVELOPE_HANDLE_MIN_LENGTH = 12
--How far a handle stays off the keypoint it belongs to. The two are the only
--things on the plot that are dragged, and they are dragged to different ends, so
--the gap is what keeps a press for one from ever landing on the other.
local ENVELOPE_HANDLE_CLEARANCE = MARKER_SIZE // 2 + 4
--how far the envelope's own lines are taken back from the curve's, so that the
--curve stays the thing being read
local ENVELOPE_FADE = 0.55
--the width of the Remove button at the right-hand end of the same row, which
--everything laid out from the left has to stop short of
local REMOVE_WIDTH = 66
--the colour the cursor shows in its middle, and the two rings around it that
--keep it visible against a colour of its own kind
local CURSOR_SIZE = 9
local RING_WIDTH = 1

-- Roblox rejects sequences outside these bounds, so the editor never lets the
-- keypoints leave them: at least two keypoints, at most twenty, strictly
-- increasing times pinned to 0 and 1 at the ends.
local MIN_KEYPOINTS = 2
local MAX_KEYPOINTS = 20
local MIN_GAP = 0.005

local widget = nil
local ui = nil
local state = nil
local dragIndex = nil
-- Which keypoint's envelope the mouse is widening, if any. Mutually exclusive
-- with dragIndex for the same reason: a press starts one drag, and the handle
-- is a separate thing to grab from the keypoint it belongs to.
local envelopeIndex = nil
-- Which part of the colour picker the mouse is holding, if any: "plane" or
-- "hue". Mutually exclusive with dragIndex, since a press starts one or the
-- other.
local pickerDrag = nil
-- A press that selects a keypoint without moving it is not an edit, and should
-- not leave an entry on the undo stack.
local dragMoved = false
-- The session-long connections made the first time the widget is built, kept so
-- the plugin can let go of them when it unloads.
local connections = {}

local function color(guideColor: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(guideColor, modifier)
end

--Whether the value is made of colours, and so wants the picker, the hex field
--and the swatch.
local function isColorKind(): boolean
	return state.kind == "colorSequence" or state.kind == "color"
end

--Whether the value is a run of keypoints rather than a single colour. Only a
--sequence has a surface to drag them on, times to give them, and a keypoint to
--take away; a lone colour is held as one keypoint purely so that the picker,
--which edits the selected one, needs no second path through.
local function isSequenceKind(): boolean
	return state.kind ~= "color"
end

local function toHex(value: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.round(value.R * 255),
		math.round(value.G * 255),
		math.round(value.B * 255)
	)
end

local function fromHex(text: string): Color3?
	local digits = text:gsub("#", ""):gsub("%s", "")
	if #digits ~= 6 then
		return nil
	end

	local number = tonumber(digits, 16)
	if number == nil then
		return nil
	end

	return Color3.fromRGB(bit32.extract(number, 16, 8), bit32.extract(number, 8, 8), bit32.extract(number, 0, 8))
end

-- Keypoints are held as plain tables while being edited, since the Roblox
-- sequence types are immutable and validate on construction -- which is exactly
-- what a half-finished drag would fail.
local function readKeypoints(kind: string, value: any)
	local keypoints = {}

	if kind == "color" then
		return { { time = 0, color = if typeof(value) == "Color3" then value else Color3.new(1, 1, 1) } }
	end

	if value ~= nil then
		for _, keypoint in value.Keypoints do
			if kind == "colorSequence" then
				table.insert(keypoints, { time = keypoint.Time, color = keypoint.Value })
			else
				--the envelope comes along whether or not it is being edited, so that
				--a curve authored with one does not lose it to an unrelated edit
				table.insert(keypoints, { time = keypoint.Time, value = keypoint.Value, envelope = keypoint.Envelope })
			end
		end
	end

	if #keypoints < MIN_KEYPOINTS then
		keypoints = if kind == "colorSequence"
			then { { time = 0, color = Color3.new(1, 1, 1) }, { time = 1, color = Color3.new(1, 1, 1) } }
			else { { time = 0, value = 1, envelope = 0 }, { time = 1, value = 0, envelope = 0 } }
	end

	return keypoints
end

local function normalize()
	--one colour has no order to put itself in, and pinning its time would only
	--be pinning a time nothing reads
	if not isSequenceKind() then
		return
	end

	local keypoints = state.keypoints

	table.sort(keypoints, function(a, b)
		return a.time < b.time
	end)

	keypoints[1].time = 0
	keypoints[#keypoints].time = 1

	for index = 2, #keypoints - 1 do
		local previous = keypoints[index - 1].time
		if keypoints[index].time <= previous then
			keypoints[index].time = math.min(1 - MIN_GAP, previous + MIN_GAP)
		end
	end
end

-- Times are pinned and forced apart as the points are built rather than trusted
-- from the working copy: the colour preview rebuilds the sequence on every
-- mouse move, and a constructor that throws mid-drag would take the editor with
-- it.
local function buildValue(): any
	if not isSequenceKind() then
		return state.keypoints[1].color
	end

	local points = {}
	local last = #state.keypoints
	local time = 0

	for index, keypoint in state.keypoints do
		if index == last then
			time = 1
		elseif index > 1 then
			time = math.max(time + MIN_GAP, math.min(keypoint.time, 1 - MIN_GAP))
		end

		if isColorKind() then
			table.insert(points, ColorSequenceKeypoint.new(time, keypoint.color))
		else
			table.insert(points, NumberSequenceKeypoint.new(time, keypoint.value, keypoint.envelope or 0))
		end
	end

	return if isColorKind() then ColorSequence.new(points) else NumberSequence.new(points)
end

-- The plot's vertical range. VFX curves are routinely well above 1 -- a Size
-- sequence is in studs -- so the plot grows to whatever the tallest keypoint
-- needs rather than clipping it off the top. Dragging is bounded by the same
-- ceiling, so raising a curve past its current peak is done by typing the value.
--
-- An envelope is measured from the top of the band it puts around a value, not
-- from the value, or a curve at the ceiling would have its envelope drawn off
-- the top of the plot.
local function valueCeiling(): number
	if isColorKind() then
		return 1
	end

	local ceiling = 1
	for _, keypoint in state.keypoints do
		ceiling = math.max(ceiling, keypoint.value + (keypoint.envelope or 0))
	end
	return ceiling
end

local function sampleColor(time: number): Color3
	local keypoints = state.keypoints

	for index = 1, #keypoints - 1 do
		local left, right = keypoints[index], keypoints[index + 1]
		if time >= left.time and time <= right.time then
			local span = right.time - left.time
			local alpha = if span > 0 then (time - left.time) / span else 0
			return left.color:Lerp(right.color, alpha)
		end
	end

	return keypoints[#keypoints].color
end

-- The envelope the curve already has at `time`, for a keypoint being inserted
-- into a band: without this the band would pinch to nothing wherever a keypoint
-- was added, which is never what adding one was meant to do.
local function sampleEnvelope(time: number): number
	local keypoints = state.keypoints

	for index = 1, #keypoints - 1 do
		local left, right = keypoints[index], keypoints[index + 1]
		if time >= left.time and time <= right.time then
			local span = right.time - left.time
			local alpha = if span > 0 then (time - left.time) / span else 0
			local from, to = left.envelope or 0, right.envelope or 0
			return from + (to - from) * alpha
		end
	end

	return keypoints[#keypoints].envelope or 0
end

-- The picker works in HSV while the keypoint holds RGB, and the two do not
-- round trip: black and white have no hue to convert back to, so a value dragged
-- to zero would throw away the hue on the way down and come back up grey. The
-- HSV the user is dragging is therefore kept as it was entered, and only read
-- back from the keypoint when the colour changed from somewhere else -- another
-- keypoint selected, a hex typed in.
local function syncPicker()
	local target = state.keypoints[state.selected].color
	local current = Color3.fromHSV(state.hue, state.sat, state.val)

	local matches = math.abs(current.R - target.R) < 1 / 512
		and math.abs(current.G - target.G) < 1 / 512
		and math.abs(current.B - target.B) < 1 / 512

	if not matches then
		state.hue, state.sat, state.val = target:ToHSV()
	end
end

local render

local function commit()
	normalize()
	state.commit(buildValue())
	render()
end

local function selectKeypoint(index: number)
	state.selected = math.clamp(index, 1, #state.keypoints)
	render()
end

local function addKeypoint(time: number, value: number)
	if #state.keypoints >= MAX_KEYPOINTS then
		return
	end

	time = math.clamp(time, MIN_GAP, 1 - MIN_GAP)

	local keypoint = if isColorKind()
		then { time = time, color = sampleColor(time) }
		else { time = time, value = value, envelope = sampleEnvelope(time) }

	table.insert(state.keypoints, keypoint)
	table.sort(state.keypoints, function(a, b)
		return a.time < b.time
	end)

	for index, candidate in state.keypoints do
		if candidate == keypoint then
			state.selected = index
		end
	end

	commit()
end

local function removeKeypoint(index: number)
	-- The ends anchor the sequence to 0 and 1; removing them has no meaning.
	if #state.keypoints <= MIN_KEYPOINTS or index == 1 or index == #state.keypoints then
		return
	end

	table.remove(state.keypoints, index)
	state.selected = math.clamp(state.selected, 1, #state.keypoints)
	commit()
end

-- Dragging is clamped between the neighbouring keypoints so the times stay
-- ordered, and the first and last keep their pinned times whatever the mouse
-- does horizontally.
local function dragTo(index: number, time: number, value: number?)
	local keypoints = state.keypoints
	local keypoint = keypoints[index]

	if index > 1 and index < #keypoints then
		local lower = keypoints[index - 1].time + MIN_GAP
		local upper = keypoints[index + 1].time - MIN_GAP
		keypoint.time = math.clamp(time, math.min(lower, upper), math.max(lower, upper))
	end

	if value ~= nil then
		keypoint.value = math.clamp(value, 0, valueCeiling())
	end

	render()
end

-- How far either way a keypoint's value is allowed to land at runtime. Set by
-- dragging the line above or below the keypoint to wherever the band should
-- reach, so what the mouse is holding is the edge of the band and what is stored
-- is its distance from the value.
local function dragEnvelopeTo(index: number, value: number)
	local keypoint = state.keypoints[index]
	keypoint.envelope = math.abs(value - keypoint.value)
	render()
end

local function makeLabel(text: string, dimmed: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.SourceSans
	label.TextSize = 14
	label.TextColor3 =
		color(if dimmed then Enum.StudioStyleGuideColor.DimmedText else Enum.StudioStyleGuideColor.MainText)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = text
	return label
end

local function makeTextBox(width: number, x: number): TextBox
	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(width, ROW_HEIGHT - 4)
	box.Position = UDim2.fromOffset(x, 2)
	box.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
	box.BorderColor3 = color(Enum.StudioStyleGuideColor.InputFieldBorder)
	box.Font = Enum.Font.SourceSans
	box.TextSize = 14
	box.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
	box.ClearTextOnFocus = false
	box.Text = ""
	return box
end

local function makeButton(text: string, width: number): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(width, ROW_HEIGHT - 4)
	button.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.SourceSans
	button.TextSize = 14
	button.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText)
	button.Text = text
	return button
end

-- The square that marks the colour in hand, and the square inside it that
-- carries that colour. It follows the mouse through the drag, since every move
-- writes the colour and renders again.
--
-- Built from filled squares nested inside one another rather than from one
-- square wearing a border, because a border is drawn at its own frame's
-- background transparency: a frame with nothing but a border on a transparent
-- background draws nothing whatsoever.
--
-- A white ring disappears against white and a black one against black, so the
-- cursor wears both, the dark one outside the light one. That is what keeps it
-- findable in the corners of the square, where the colour beneath it is one or
-- the other.
local function makeCursor(parent: Frame): (Frame, Frame)
	local cursor = Instance.new("Frame")
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Size = UDim2.fromOffset(CURSOR_SIZE + RING_WIDTH * 4, CURSOR_SIZE + RING_WIDTH * 4)
	cursor.BackgroundColor3 = Color3.new(0, 0, 0)
	cursor.BorderSizePixel = 0
	cursor.ZIndex = 3
	cursor.Parent = parent

	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.new(1, -RING_WIDTH * 2, 1, -RING_WIDTH * 2)
	ring.BackgroundColor3 = Color3.new(1, 1, 1)
	ring.BorderSizePixel = 0
	ring.Parent = cursor

	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0.5, 0.5)
	fill.Position = UDim2.fromScale(0.5, 0.5)
	fill.Size = UDim2.new(1, -RING_WIDTH * 2, 1, -RING_WIDTH * 2)
	fill.BorderSizePixel = 0
	fill.Parent = ring

	return cursor, fill
end

-- The saturation/value square is a hue-coloured panel under two gradients: white
-- fading out to the right, black fading in towards the bottom. Stacking them is
-- how a two-dimensional ramp is had from one-dimensional UIGradients.
local function buildPicker(container: Frame, top: number, bottom: number)
	local plane = Instance.new("Frame")
	plane.Position = UDim2.fromOffset(PADDING, top)
	plane.Size = UDim2.new(1, -(PADDING * 3 + HUE_WIDTH), 1, -(top + bottom))
	plane.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
	plane.Parent = container
	ui.plane = plane

	local saturation = Instance.new("Frame")
	saturation.Size = UDim2.fromScale(1, 1)
	saturation.BackgroundColor3 = Color3.new(1, 1, 1)
	saturation.BorderSizePixel = 0
	saturation.ZIndex = 1
	saturation.Parent = plane

	local saturationRamp = Instance.new("UIGradient")
	saturationRamp.Transparency = NumberSequence.new(0, 1)
	saturationRamp.Parent = saturation

	local brightness = Instance.new("Frame")
	brightness.Size = UDim2.fromScale(1, 1)
	brightness.BackgroundColor3 = Color3.new(0, 0, 0)
	brightness.BorderSizePixel = 0
	brightness.ZIndex = 2
	brightness.Parent = plane

	local brightnessRamp = Instance.new("UIGradient")
	brightnessRamp.Rotation = 90
	brightnessRamp.Transparency = NumberSequence.new(1, 0)
	brightnessRamp.Parent = brightness

	ui.planeCursor, ui.planeCursorFill = makeCursor(plane)

	local hue = Instance.new("Frame")
	hue.Position = UDim2.new(1, -(PADDING + HUE_WIDTH), 0, top)
	hue.Size = UDim2.new(0, HUE_WIDTH, 1, -(top + bottom))
	-- White for the same reason as the gradient above: the ramp is a multiplier,
	-- and a Frame's default grey would take a third off every hue.
	hue.BackgroundColor3 = Color3.new(1, 1, 1)
	hue.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
	hue.Parent = container
	ui.hue = hue

	local hueStops = {}
	for step = 0, 6 do
		local point = step / 6
		table.insert(hueStops, ColorSequenceKeypoint.new(point, Color3.fromHSV(point, 1, 1)))
	end

	local hueRamp = Instance.new("UIGradient")
	hueRamp.Rotation = 90
	hueRamp.Color = ColorSequence.new(hueStops)
	hueRamp.Parent = hue

	-- The hue cursor spans the bar it sits on, overhanging a little at both ends
	-- so that the ring reads as a band across it rather than a square on it.
	ui.hueCursor, ui.hueCursorFill = makeCursor(hue)
	ui.hueCursor.Size = UDim2.new(1, RING_WIDTH * 4, 0, CURSOR_SIZE + RING_WIDTH * 4)

	plane.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		pickerDrag = "plane"
		ui.applyPicker(input)
	end)

	hue.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		pickerDrag = "hue"
		ui.applyPicker(input)
	end)
end

local function surfaceLocalPosition(input: InputObject): Vector2
	local surface = ui.surface
	return Vector2.new(input.Position.X, input.Position.Y) - surface.AbsolutePosition
end

local function build()
	if ui ~= nil and ui.root ~= nil then
		ui.root:Destroy()
	end
	ui = {}

	function ui.endDrag()
		if dragIndex == nil and envelopeIndex == nil and pickerDrag == nil then
			return
		end

		dragIndex = nil
		envelopeIndex = nil
		pickerDrag = nil

		if dragMoved then
			commit()
		else
			render()
		end
	end

	-- Applies wherever in the picker the mouse currently is. A press counts as a
	-- change, so a single click on the square is an edit in its own right rather
	-- than something that only takes effect once dragged.
	function ui.applyPicker(input: InputObject)
		local point = Vector2.new(input.Position.X, input.Position.Y)

		if pickerDrag == "plane" then
			local size = ui.plane.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end

			local position = point - ui.plane.AbsolutePosition
			state.sat = math.clamp(position.X / size.X, 0, 1)
			state.val = math.clamp(1 - position.Y / size.Y, 0, 1)
		else
			local size = ui.hue.AbsoluteSize
			if size.Y <= 0 then
				return
			end

			state.hue = math.clamp((point.Y - ui.hue.AbsolutePosition.Y) / size.Y, 0, 1)
		end

		state.keypoints[state.selected].color = Color3.fromHSV(state.hue, state.sat, state.val)
		dragMoved = true
		render()
	end

	function ui.onDragMove(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		if pickerDrag ~= nil then
			ui.applyPicker(input)
			return
		end

		if dragIndex == nil and envelopeIndex == nil then
			return
		end

		local size = ui.surface.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			return
		end

		local position = surfaceLocalPosition(input)
		local time = math.clamp(position.X / size.X, 0, 1)
		local value = if isColorKind() then nil else math.clamp(1 - position.Y / size.Y, 0, 1) * valueCeiling()

		dragMoved = true

		--an envelope is dragged up and down only: it belongs to a keypoint that
		--stays where it is
		if envelopeIndex ~= nil then
			dragEnvelopeTo(envelopeIndex, value or 0)
			return
		end

		dragTo(dragIndex, time, value)
	end

	function ui.onDragEnd(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			ui.endDrag()
		end
	end

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	root.BorderSizePixel = 0
	root.Active = true
	root.Parent = widget
	ui.root = root

	local title = makeLabel(state.title, false)
	title.Font = Enum.Font.SourceSansBold
	title.Position = UDim2.fromOffset(PADDING, PADDING)
	title.Size = UDim2.new(1, -PADDING * 2, 0, TITLE_HEIGHT)
	title.Parent = root

	local bottomStack = PADDING + HINT_HEIGHT + 4 + ROW_HEIGHT + PADDING

	-- Where the picker starts. A lone colour has no keypoints to lay along
	-- anything, so nothing stands between the title and the square.
	local pickerTop = SURFACE_TOP

	if isSequenceKind() then
		-- The colour editor is a gradient with its keypoints on a strip below
		-- it, the number editor a plot with the keypoints on it. Both drag the
		-- same way, so only the surface differs.
		local surface = Instance.new("Frame")
		surface.Position = UDim2.fromOffset(PADDING, SURFACE_TOP)
		surface.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		surface.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		surface.Parent = root
		ui.surface = surface

		if isColorKind() then
			surface.Size = UDim2.new(1, -PADDING * 2, 0, GRADIENT_HEIGHT)
			-- A UIGradient multiplies the frame's own colour rather than
			-- replacing it, so anything it is laid over has to be white or the
			-- whole ramp comes out dimmed by whatever the theme painted
			-- underneath.
			surface.BackgroundColor3 = Color3.new(1, 1, 1)

			local gradient = Instance.new("UIGradient")
			gradient.Parent = surface
			ui.gradient = gradient

			local strip = Instance.new("Frame")
			strip.Position = UDim2.fromOffset(PADDING, SURFACE_TOP + GRADIENT_HEIGHT)
			strip.Size = UDim2.new(1, -PADDING * 2, 0, STRIP_HEIGHT)
			strip.BackgroundTransparency = 1
			strip.Parent = root
			ui.markers = strip

			pickerTop = SURFACE_TOP + GRADIENT_HEIGHT + STRIP_HEIGHT + PADDING
		else
			surface.Size = UDim2.new(1, -PADDING * 2, 1, -(SURFACE_TOP + bottomStack))
			ui.markers = surface
		end

		-- The curve is redrawn from scratch every render; the keypoint buttons
		-- are not, so they live alongside it rather than among it.
		local curve = Instance.new("Frame")
		curve.Size = UDim2.fromScale(1, 1)
		curve.BackgroundTransparency = 1
		curve.ZIndex = 1
		curve.Parent = ui.markers
		ui.curve = curve
		ui.markerButtons = {}
		--kept by which side of the value they sit on rather than in a list, since
		--there is one above and one below and they are reused like the markers
		ui.envelopeHandles = {}
	end

	if isColorKind() then
		buildPicker(root, pickerTop, bottomStack)
	end

	local fields = Instance.new("Frame")
	fields.Position = UDim2.new(0, PADDING, 1, -(PADDING + HINT_HEIGHT + 4 + ROW_HEIGHT))
	fields.Size = UDim2.new(1, -PADDING * 2, 0, ROW_HEIGHT)
	fields.BackgroundTransparency = 1
	fields.Parent = root

	-- The row is filled left to right rather than at written-out offsets, because
	-- what goes in it varies: a number's keypoint has a time, a value and an
	-- envelope, a colour's has a time and a colour, and a lone colour has only the
	-- colour. Each piece takes the width it needs from where the last one ended.
	local fieldLeft = 0

	local function placeLabel(text: string, width: number)
		local label = makeLabel(text, true)
		label.Position = UDim2.fromOffset(fieldLeft, 0)
		label.Size = UDim2.fromOffset(width, ROW_HEIGHT)
		label.Parent = fields
		fieldLeft += width + LABEL_GAP
	end

	local function placeBox(width: number): TextBox
		local box = makeTextBox(width, fieldLeft)
		box.Parent = fields
		fieldLeft += width + FIELD_GAP
		return box
	end

	if isSequenceKind() then
		placeLabel("Time", 30)
		ui.timeBox = placeBox(48)
	end

	placeLabel(if isColorKind() then "Color" else "Value", 34)
	ui.valueBox = placeBox(if isColorKind() then 72 else 48)

	if isColorKind() then
		local swatch = Instance.new("Frame")
		swatch.Position = UDim2.fromOffset(fieldLeft, 2)
		swatch.Size = UDim2.fromOffset(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
		swatch.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		swatch.Parent = fields
		ui.swatch = swatch
		fieldLeft += ROW_HEIGHT - 4 + FIELD_GAP
	else
		--How far either way the value may land, which is the one thing here that
		--is a property of the curve rather than of the keypoint's place on it.
		placeLabel("Env", 26)
		ui.envelopeBox = placeBox(48)
	end

	if isSequenceKind() then
		ui.removeButton = makeButton("Remove", REMOVE_WIDTH)
		ui.removeButton.AnchorPoint = Vector2.new(1, 0)
		ui.removeButton.Position = UDim2.new(1, 0, 0, 2)
		ui.removeButton.Parent = fields
	end

	local hintText = "Click to add a keypoint, right-click one to remove it. Drag a handle to vary its value."
	if not isSequenceKind() then
		hintText = "Drag the square and the hue bar, or type a hex colour."
	elseif isColorKind() then
		hintText = "Click the gradient to add a keypoint, right-click one to remove it."
	end

	local hint = makeLabel(hintText, true)
	hint.Position = UDim2.new(0, PADDING, 1, -(PADDING + HINT_HEIGHT))
	hint.Size = UDim2.new(1, -PADDING * 2, 0, HINT_HEIGHT)
	hint.Parent = root

	if isSequenceKind() then
		ui.timeBox.FocusLost:Connect(function()
			local time = tonumber(ui.timeBox.Text)
			if time ~= nil then
				dragTo(state.selected, math.clamp(time, 0, 1), nil)
				commit()
			else
				render()
			end
		end)

		ui.removeButton.Activated:Connect(function()
			removeKeypoint(state.selected)
		end)
	end

	if ui.envelopeBox ~= nil then
		ui.envelopeBox.FocusLost:Connect(function()
			local parsed = tonumber(ui.envelopeBox.Text)
			if parsed ~= nil then
				--an envelope is a distance either way, so it has no sign; typing a
				--bigger one than the plot shows grows the plot rather than being
				--refused, the same as typing a value does
				state.keypoints[state.selected].envelope = math.max(parsed, 0)
				commit()
				return
			end

			render()
		end)
	end

	ui.valueBox.FocusLost:Connect(function()
		local keypoint = state.keypoints[state.selected]

		if isColorKind() then
			local parsed = fromHex(ui.valueBox.Text)
			if parsed ~= nil then
				keypoint.color = parsed
				commit()
				return
			end
		else
			local parsed = tonumber(ui.valueBox.Text)
			if parsed ~= nil then
				keypoint.value = math.max(parsed, 0)
				commit()
				return
			end
		end

		render()
	end)

	if isSequenceKind() then
		-- Clicking anywhere on the surface that is not a keypoint adds one.
		-- Keypoints are buttons and take the click first, setting dragIndex on
		-- the way, which is what keeps a grab from also inserting a point
		-- underneath itself.
		ui.surface.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 or dragIndex ~= nil then
				return
			end

			local position = surfaceLocalPosition(input)
			local size = ui.surface.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end

			addKeypoint(position.X / size.X, (1 - position.Y / size.Y) * valueCeiling())
		end)

		-- The curve between the keypoints is drawn in pixels, so it has to be
		-- drawn again whenever the surface it spans changes size.
		ui.surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if state ~= nil then
				render()
			end
		end)
	end

	-- Tracked on the root rather than the surface so a drag that wanders off the
	-- plot keeps working until the mouse comes back or is released. Keypoint
	-- buttons sink input, so they carry the same two handlers (see createMarker)
	-- and the drag survives passing over them.
	root.InputChanged:Connect(ui.onDragMove)
	root.InputEnded:Connect(ui.onDragEnd)
end

-- A marker always stands for the keypoint at its own index. Keypoints never
-- reorder while one is being dragged -- the drag is clamped between its
-- neighbours -- so that binding holds for as long as the button lives.
local function createMarker(index: number): TextButton
	local marker = Instance.new("TextButton")
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Size = UDim2.fromOffset(MARKER_SIZE, MARKER_SIZE)
	marker.Text = ""
	marker.AutoButtonColor = false
	--above the envelope handles, so that the keypoint takes the press if the two
	--are ever drawn over one another
	marker.ZIndex = 3

	marker.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragIndex = index
			dragMoved = false
			selectKeypoint(index)
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			removeKeypoint(index)
		end
	end)

	marker.InputChanged:Connect(function(input)
		ui.onDragMove(input)
	end)

	marker.InputEnded:Connect(function(input)
		ui.onDragEnd(input)
	end)

	marker.Parent = ui.markers
	return marker
end

-- A handle stands for one edge of one keypoint's envelope: `side` is 1 for the
-- one above the value and -1 for the one below. Dragging either sets the same
-- envelope, since the band is symmetrical.
--
-- Anchored at whichever end of itself is nearest the keypoint, so that it is
-- placed by the gap it keeps from the keypoint and grows away from it as the
-- envelope widens.
local function createEnvelopeHandle(side: number): TextButton
	local handle = Instance.new("TextButton")
	handle.Name = if side > 0 then "EnvelopeTop" else "EnvelopeBottom"
	handle.AnchorPoint = Vector2.new(0.5, if side > 0 then 1 else 0)
	handle.Text = ""
	handle.AutoButtonColor = false
	handle.BorderSizePixel = 0
	handle.ZIndex = 2
	handle.Visible = false

	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			envelopeIndex = state.selected
			dragMoved = false
		end
	end)

	handle.InputChanged:Connect(function(input)
		ui.onDragMove(input)
	end)

	handle.InputEnded:Connect(function(input)
		ui.onDragEnd(input)
	end)

	handle.Parent = ui.markers
	return handle
end

local function renderMarkers()
	local keypoints = state.keypoints
	local markers = ui.markerButtons
	local size = ui.surface.AbsoluteSize
	local ceiling = valueCeiling()

	for _, segment in ui.curve:GetChildren() do
		segment:Destroy()
	end

	-- A line between two points on the plot, drawn as a thin rotated frame, which
	-- is why this needs pixel positions and why the render re-runs when the
	-- surface resizes.
	local function drawLine(x1: number, y1: number, x2: number, y2: number, thickness: number, faded: number)
		local dx, dy = x2 - x1, y2 - y1

		local segment = Instance.new("Frame")
		segment.AnchorPoint = Vector2.new(0.5, 0.5)
		segment.Position = UDim2.fromOffset((x1 + x2) * 0.5, (y1 + y2) * 0.5)
		segment.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), thickness)
		segment.Rotation = math.deg(math.atan2(dy, dx))
		segment.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DialogMainButton)
		segment.BackgroundTransparency = faded
		segment.BorderSizePixel = 0
		segment.Parent = ui.curve
	end

	if not isColorKind() and size.X > 0 and size.Y > 0 then
		local function plotY(value: number): number
			return (1 - value / ceiling) * size.Y
		end

		for index = 1, #keypoints - 1 do
			local left, right = keypoints[index], keypoints[index + 1]
			local x1, x2 = left.time * size.X, right.time * size.X
			local leftEnvelope, rightEnvelope = left.envelope or 0, right.envelope or 0

			-- The envelope is the range a value may actually land in, so it is
			-- drawn as the two edges of a band around the curve. Studio shades the
			-- band in; a UI frame cannot be a trapezoid, so the edges carry it
			-- here, dimmed so they read as the bounds rather than as more curves.
			if leftEnvelope > 0 or rightEnvelope > 0 then
				for _, side in { 1, -1 } do
					drawLine(
						x1,
						plotY(left.value + side * leftEnvelope),
						x2,
						plotY(right.value + side * rightEnvelope),
						1,
						ENVELOPE_FADE
					)
				end
			end

			drawLine(x1, plotY(left.value), x2, plotY(right.value), 2, 0)
		end

		-- Whichever keypoint is selected gets the handles, so that a curve with an
		-- envelope on every keypoint is not buried under forty of them.
		local selected = keypoints[state.selected]
		local envelope = selected.envelope or 0
		local originX, originY = selected.time * size.X, plotY(selected.value)

		for _, side in { 1, -1 } do
			local handle = ui.envelopeHandles[side]
			if handle == nil then
				handle = createEnvelopeHandle(side)
				ui.envelopeHandles[side] = handle
			end

			--Where the handle starts, which is clear of the keypoint whatever the
			--envelope is doing: that gap is the whole reason a press can only ever
			--mean one of the two.
			local near = originY - side * ENVELOPE_HANDLE_CLEARANCE
			--how much of the plot is left between there and the edge it grows
			--towards, so a whisker is never drawn outside the plot
			local room = if side > 0 then near else size.Y - near

			--The rest of the way to the edge of the band, once the gap has been
			--taken off, and never so short that there is nothing to aim at. A
			--keypoint hard against the top or bottom of the plot has no room for
			--the handle on that side, which is also the side its envelope has
			--nowhere to reach into; the other one sets the same envelope.
			local reach = math.abs(plotY(selected.value + side * envelope) - originY)
			local length = math.clamp(
				math.max(reach - ENVELOPE_HANDLE_CLEARANCE, ENVELOPE_HANDLE_MIN_LENGTH),
				0,
				math.max(room, 0)
			)

			handle.Visible = length > 0
			handle.Size = UDim2.fromOffset(ENVELOPE_HANDLE_WIDTH, length)
			handle.Position = UDim2.fromOffset(originX, near)
			handle.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DialogMainButton)
			handle.BackgroundTransparency = if envelope > 0 then 0 else ENVELOPE_FADE
		end
	end

	-- Reused rather than rebuilt: destroying the button under the cursor part
	-- way through a drag takes its input connections with it, and the release
	-- that should end the drag is then never delivered anywhere.
	while #markers > #keypoints do
		markers[#markers]:Destroy()
		markers[#markers] = nil
	end

	for index, keypoint in keypoints do
		local marker = markers[index]
		if marker == nil then
			marker = createMarker(index)
			markers[index] = marker
		end

		if isColorKind() then
			marker.Position = UDim2.fromScale(keypoint.time, 0.5)
			marker.BackgroundColor3 = keypoint.color
		else
			marker.Position = UDim2.fromScale(keypoint.time, 1 - keypoint.value / ceiling)
			marker.BackgroundColor3 = color(
				Enum.StudioStyleGuideColor.DialogMainButton,
				if index == state.selected then Enum.StudioStyleGuideModifier.Selected else nil
			)
		end

		local isSelected = index == state.selected
		marker.BorderSizePixel = if isSelected then 2 else 1
		marker.BorderColor3 =
			color(if isSelected then Enum.StudioStyleGuideColor.BrightText else Enum.StudioStyleGuideColor.Border)
	end
end

render = function()
	if state == nil or ui == nil then
		return
	end

	state.selected = math.clamp(state.selected, 1, #state.keypoints)
	local keypoint = state.keypoints[state.selected]

	if isColorKind() then
		syncPicker()

		if isSequenceKind() then
			ui.gradient.Color = buildValue()
		end

		ui.swatch.BackgroundColor3 = keypoint.color
		ui.valueBox.Text = "#" .. toHex(keypoint.color)

		local pureHue = Color3.fromHSV(state.hue, 1, 1)

		ui.plane.BackgroundColor3 = pureHue
		ui.planeCursor.Position = UDim2.fromScale(state.sat, 1 - state.val)
		--the colour in hand, so the cursor reads as the swatch it is standing on
		ui.planeCursorFill.BackgroundColor3 = keypoint.color

		ui.hueCursor.Position = UDim2.fromScale(0.5, state.hue)
		--the hue alone, which is what this bar picks rather than the whole colour
		ui.hueCursorFill.BackgroundColor3 = pureHue
	else
		ui.valueBox.Text = string.format("%g", keypoint.value)
		ui.envelopeBox.Text = string.format("%g", keypoint.envelope or 0)
	end

	--the rest of the window is the keypoints and what can be done to them, none
	--of which a lone colour has
	if not isSequenceKind() then
		return
	end

	ui.timeBox.Text = string.format("%g", keypoint.time)

	-- The end keypoints hold the sequence's 0 and 1, so their times are not
	-- editable and they cannot be removed.
	local isEnd = state.selected == 1 or state.selected == #state.keypoints
	ui.timeBox.TextEditable = not isEnd
	ui.timeBox.TextColor3 =
		color(if isEnd then Enum.StudioStyleGuideColor.DimmedText else Enum.StudioStyleGuideColor.MainText)

	local removable = not isEnd and #state.keypoints > MIN_KEYPOINTS
	ui.removeButton.Active = removable
	ui.removeButton.AutoButtonColor = removable
	ui.removeButton.TextColor3 =
		color(Enum.StudioStyleGuideColor.ButtonText, if removable then nil else Enum.StudioStyleGuideModifier.Disabled)

	renderMarkers()
end

--[[
	Opens the editor on one parameter. `kind` is "numberSequence",
	"colorSequence" or "color", the last being a single Color3 rather than a
	sequence. `commit` is called with a rebuilt value of that same type after
	every completed edit; the caller owns how that reaches the instance, so undo
	history stays in one place.
]]
function VFXSequenceEditor.Open(pluginRef: Plugin, title: string, kind: string, value: any, onCommit: (any) -> ())
	if widget == nil then
		-- Tall enough that the colour picker gets a usable square underneath the
		-- gradient; the number plot simply grows into the same room.
		local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 480, 400, 340, 300)
		widget = pluginRef:CreateDockWidgetPluginGui("VFXSequenceEditor", info)
		widget.Name = "VFXSequenceEditor"
		widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		table.insert(
			connections,
			settings().Studio.ThemeChanged:Connect(function()
				if state ~= nil and widget.Enabled then
					build()
					render()
				end
			end)
		)

		-- Backstops for a release the widget's own handlers never see, because it
		-- happened outside the window or over something that swallowed it. Both
		-- are event driven: if Studio routes neither to a floating widget they
		-- simply never fire, where a check of the live button state would end
		-- every drag on the first movement instead.
		table.insert(
			connections,
			UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 and ui ~= nil and state ~= nil then
					ui.endDrag()
				end
			end)
		)

		table.insert(
			connections,
			widget.WindowFocusReleased:Connect(function()
				if ui ~= nil and state ~= nil then
					ui.endDrag()
				end
			end)
		)
	end

	widget.Title = title
	dragIndex = nil
	pickerDrag = nil
	state = {
		title = title,
		kind = kind,
		keypoints = readKeypoints(kind, value),
		selected = 1,
		commit = onCommit,
		-- White, until the first render reads the selected keypoint's colour.
		hue = 0,
		sat = 0,
		val = 1,
	}

	build()
	render()
	widget.Enabled = true
end

--Let go of the widget and its session-long connections, for when the plugin
--unloads.
function VFXSequenceEditor.Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	state = nil
	ui = nil
	dragIndex = nil
	pickerDrag = nil

	if widget ~= nil then
		widget:Destroy()
		widget = nil
	end
end

return VFXSequenceEditor
