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

	Colour sequences get a picker as well, for the same reason: Studio's colour
	dialog has no plugin API either. It is the usual saturation/value square
	beside a hue bar, and it edits whichever keypoint is selected.

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
local CURSOR_SIZE = 9

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

local function isColorKind(): boolean
	return state.kind == "colorSequence"
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

	if value ~= nil then
		for _, keypoint in value.Keypoints do
			if kind == "colorSequence" then
				table.insert(keypoints, { time = keypoint.Time, color = keypoint.Value })
			else
				table.insert(keypoints, { time = keypoint.Time, value = keypoint.Value })
			end
		end
	end

	if #keypoints < MIN_KEYPOINTS then
		keypoints = if kind == "colorSequence"
			then { { time = 0, color = Color3.new(1, 1, 1) }, { time = 1, color = Color3.new(1, 1, 1) } }
			else { { time = 0, value = 1 }, { time = 1, value = 0 } }
	end

	return keypoints
end

local function normalize()
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
			table.insert(points, NumberSequenceKeypoint.new(time, keypoint.value))
		end
	end

	return if isColorKind() then ColorSequence.new(points) else NumberSequence.new(points)
end

-- The plot's vertical range. VFX curves are routinely well above 1 -- a Size
-- sequence is in studs -- so the plot grows to whatever the tallest keypoint
-- needs rather than clipping it off the top. Dragging is bounded by the same
-- ceiling, so raising a curve past its current peak is done by typing the value.
local function valueCeiling(): number
	if isColorKind() then
		return 1
	end

	local ceiling = 1
	for _, keypoint in state.keypoints do
		ceiling = math.max(ceiling, keypoint.value)
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
		else { time = time, value = value }

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

local function makeCursor(parent: Frame): Frame
	local cursor = Instance.new("Frame")
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Size = UDim2.fromOffset(CURSOR_SIZE, CURSOR_SIZE)
	cursor.BackgroundTransparency = 1
	cursor.BorderSizePixel = 1
	cursor.BorderColor3 = Color3.new(1, 1, 1)
	cursor.ZIndex = 3
	cursor.Parent = parent

	-- A white ring disappears against white and a black one against black, so
	-- the cursor wears both, the dark one outside the light one.
	local outline = Instance.new("Frame")
	outline.AnchorPoint = Vector2.new(0.5, 0.5)
	outline.Position = UDim2.fromScale(0.5, 0.5)
	outline.Size = UDim2.new(1, 2, 1, 2)
	outline.BackgroundTransparency = 1
	outline.BorderSizePixel = 1
	outline.BorderColor3 = Color3.new(0, 0, 0)
	outline.ZIndex = 3
	outline.Parent = cursor

	return cursor
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

	ui.planeCursor = makeCursor(plane)

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

	ui.hueCursor = makeCursor(hue)
	ui.hueCursor.Size = UDim2.new(1, 4, 0, CURSOR_SIZE)

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
		if dragIndex == nil and pickerDrag == nil then
			return
		end

		dragIndex = nil
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

		if dragIndex == nil then
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

	-- The colour editor is a gradient with its keypoints on a strip below it,
	-- the number editor a plot with the keypoints on it. Both drag the same way,
	-- so only the surface differs.
	local surface = Instance.new("Frame")
	surface.Position = UDim2.fromOffset(PADDING, SURFACE_TOP)
	surface.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
	surface.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
	surface.Parent = root
	ui.surface = surface

	if isColorKind() then
		surface.Size = UDim2.new(1, -PADDING * 2, 0, GRADIENT_HEIGHT)
		-- A UIGradient multiplies the frame's own colour rather than replacing
		-- it, so anything it is laid over has to be white or the whole ramp
		-- comes out dimmed by whatever the theme painted underneath.
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
	else
		surface.Size = UDim2.new(1, -PADDING * 2, 1, -(SURFACE_TOP + bottomStack))
		ui.markers = surface
	end

	-- The curve is redrawn from scratch every render; the keypoint buttons are
	-- not, so they live alongside it rather than among it.
	local curve = Instance.new("Frame")
	curve.Size = UDim2.fromScale(1, 1)
	curve.BackgroundTransparency = 1
	curve.ZIndex = 1
	curve.Parent = ui.markers
	ui.curve = curve
	ui.markerButtons = {}

	if isColorKind() then
		buildPicker(root, SURFACE_TOP + GRADIENT_HEIGHT + STRIP_HEIGHT + PADDING, bottomStack)
	end

	local fields = Instance.new("Frame")
	fields.Position = UDim2.new(0, PADDING, 1, -(PADDING + HINT_HEIGHT + 4 + ROW_HEIGHT))
	fields.Size = UDim2.new(1, -PADDING * 2, 0, ROW_HEIGHT)
	fields.BackgroundTransparency = 1
	fields.Parent = root

	local timeLabel = makeLabel("Time", true)
	timeLabel.Position = UDim2.fromOffset(0, 0)
	timeLabel.Size = UDim2.fromOffset(34, ROW_HEIGHT)
	timeLabel.Parent = fields

	ui.timeBox = makeTextBox(56, 36)
	ui.timeBox.Parent = fields

	local valueLabel = makeLabel(if isColorKind() then "Color" else "Value", true)
	valueLabel.Position = UDim2.fromOffset(102, 0)
	valueLabel.Size = UDim2.fromOffset(40, ROW_HEIGHT)
	valueLabel.Parent = fields

	ui.valueBox = makeTextBox(if isColorKind() then 76 else 56, 144)
	ui.valueBox.Parent = fields

	if isColorKind() then
		local swatch = Instance.new("Frame")
		swatch.Position = UDim2.fromOffset(226, 2)
		swatch.Size = UDim2.fromOffset(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
		swatch.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		swatch.Parent = fields
		ui.swatch = swatch
	end

	ui.removeButton = makeButton("Remove", 66)
	ui.removeButton.AnchorPoint = Vector2.new(1, 0)
	ui.removeButton.Position = UDim2.new(1, 0, 0, 2)
	ui.removeButton.Parent = fields

	local hint = makeLabel(
		if isColorKind()
			then "Click the gradient to add a keypoint, right-click one to remove it."
			else "Click to add a keypoint. Right-click one to remove it.",
		true
	)
	hint.Position = UDim2.new(0, PADDING, 1, -(PADDING + HINT_HEIGHT))
	hint.Size = UDim2.new(1, -PADDING * 2, 0, HINT_HEIGHT)
	hint.Parent = root

	ui.timeBox.FocusLost:Connect(function()
		local time = tonumber(ui.timeBox.Text)
		if time ~= nil then
			dragTo(state.selected, math.clamp(time, 0, 1), nil)
			commit()
		else
			render()
		end
	end)

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

	ui.removeButton.Activated:Connect(function()
		removeKeypoint(state.selected)
	end)

	-- Clicking anywhere on the surface that is not a keypoint adds one. Keypoints
	-- are buttons and take the click first, setting dragIndex on the way, which
	-- is what keeps a grab from also inserting a point underneath itself.
	surface.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or dragIndex ~= nil then
			return
		end

		local position = surfaceLocalPosition(input)
		local size = surface.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			return
		end

		addKeypoint(position.X / size.X, (1 - position.Y / size.Y) * valueCeiling())
	end)

	-- Tracked on the root rather than the surface so a drag that wanders off the
	-- plot keeps working until the mouse comes back or is released. Keypoint
	-- buttons sink input, so they carry the same two handlers (see createMarker)
	-- and the drag survives passing over them.
	root.InputChanged:Connect(ui.onDragMove)
	root.InputEnded:Connect(ui.onDragEnd)

	surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if state ~= nil then
			render()
		end
	end)
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
	marker.ZIndex = 2

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

local function renderMarkers()
	local keypoints = state.keypoints
	local markers = ui.markerButtons
	local size = ui.surface.AbsoluteSize
	local ceiling = valueCeiling()

	for _, segment in ui.curve:GetChildren() do
		segment:Destroy()
	end

	-- Segments are drawn as thin rotated frames between consecutive keypoints,
	-- which needs pixel positions; the render re-runs when the surface resizes.
	if not isColorKind() and size.X > 0 and size.Y > 0 then
		for index = 1, #keypoints - 1 do
			local left, right = keypoints[index], keypoints[index + 1]
			local x1, y1 = left.time * size.X, (1 - left.value / ceiling) * size.Y
			local x2, y2 = right.time * size.X, (1 - right.value / ceiling) * size.Y
			local dx, dy = x2 - x1, y2 - y1

			local segment = Instance.new("Frame")
			segment.AnchorPoint = Vector2.new(0.5, 0.5)
			segment.Position = UDim2.fromOffset((x1 + x2) * 0.5, (y1 + y2) * 0.5)
			segment.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 2)
			segment.Rotation = math.deg(math.atan2(dy, dx))
			segment.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DialogMainButton)
			segment.BorderSizePixel = 0
			segment.Parent = ui.curve
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

		ui.gradient.Color = buildValue()
		ui.swatch.BackgroundColor3 = keypoint.color
		ui.valueBox.Text = "#" .. toHex(keypoint.color)

		ui.plane.BackgroundColor3 = Color3.fromHSV(state.hue, 1, 1)
		ui.planeCursor.Position = UDim2.fromScale(state.sat, 1 - state.val)
		ui.hueCursor.Position = UDim2.fromScale(0.5, state.hue)
	else
		ui.valueBox.Text = string.format("%g", keypoint.value)
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
	Opens the editor on one parameter. `kind` is "numberSequence" or
	"colorSequence". `commit` is called with a rebuilt sequence after every
	completed edit; the caller owns how that reaches the instance, so undo
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
