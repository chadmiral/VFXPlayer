--Studio-only inspector window for the VFX in a place. A band of playback
--controls across the top, and under it three panes, left to right: every
--instance tagged "VFXSequence", the emitters inside the selected sequence, and
--the native properties plus attributes of the selected emitter.
local VFXEditor = {}

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")
local Studio = settings().Studio

local Fields = require(script.Parent:WaitForChild("VFXEditorFields"))
local SequenceEditor = require(script.Parent:WaitForChild("VFXSequenceEditor"))

local VFX_SEQUENCE_TAG = "VFXSequence"
local MESH_EMITTER_TAG = "MeshEmitter"

local HEADER_HEIGHT = 26
local ROW_HEIGHT = 22
local TEXT_SIZE = 14
local PADDING = 8
--the playback band above the panes, and the size of a button in it
local TOOLBAR_HEIGHT = 32
local BUTTON_WIDTH = 96
local ICON_SIZE = 16

--the icons these two buttons carried when they lived on the Studio ribbon
local PLAY_ICON = "rbxassetid://8215093320"
local STOP_ICON = "rbxassetid://579151508"
--how much of a parameter row the name takes, leaving the rest to the editor
local NAME_COLUMN = 0.45

--Roblox exposes no property reflection to plugins, so the native properties
--worth showing for each driven class are enumerated here, in display order.
--Names that do not resolve on a given instance are skipped at read time.
local NATIVE_PROPERTIES = {
	ParticleEmitter = {
		"Enabled",
		"Rate",
		"Lifetime",
		"Speed",
		"SpreadAngle",
		"EmissionDirection",
		"Shape",
		"ShapeStyle",
		"ShapeInOut",
		"ShapePartial",
		"Size",
		"Squash",
		"Transparency",
		"Color",
		"Texture",
		"Brightness",
		"LightEmission",
		"LightInfluence",
		"Orientation",
		"Rotation",
		"RotSpeed",
		"ZOffset",
		"Acceleration",
		"Drag",
		"VelocityInheritance",
		"LockedToPart",
		"TimeScale",
	},
	PointLight = { "Enabled", "Brightness", "Color", "Range", "Shadows" },
	SpotLight = { "Enabled", "Brightness", "Color", "Range", "Angle", "Face", "Shadows" },
	Attachment = { "Visible", "Position", "Orientation", "WorldPosition" },
}

local function isMeshEmitter(inst)
	return inst:IsA("Attachment") and CollectionService:HasTag(inst, MESH_EMITTER_TAG)
end

--the label shown for an emitter's type; tagged attachments read as MeshEmitter
--rather than the less informative "Attachment"
local function emitterKind(inst)
	if isMeshEmitter(inst) then
		return MESH_EMITTER_TAG
	end
	return inst.ClassName
end

--every element of a sequence that the runtime animates, matching the classes
--Sequence:Init picks up
local function collectEmitters(sequence)
	local emitters = {}
	for _, d in sequence:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("PointLight") or d:IsA("SpotLight") or isMeshEmitter(d) then
			table.insert(emitters, d)
		end
	end
	return emitters
end

--A "Base<Property>" attribute holds the authored value the runtime animates the
--matching native property away from and back to, so to an author the two are
--one parameter and the attribute is the half worth editing. Returns the
--property such an attribute stands in for, or nil if the name is not one.
local function baseAttributeTarget(attributeName: string): string?
	return string.match(attributeName, "^Base(.+)$")
end

--read a property defensively: the enumerated lists above may name properties
--that do not exist on a given instance or are not readable by plugins
local function readProperty(inst: Instance, propertyName: string)
	local ok, value = pcall(function()
		return (inst :: any)[propertyName]
	end)
	if not ok then
		return nil, false
	end
	return value, true
end

--Studio's undo stack only records what happens between these calls, so every
--edit the pane makes has to run inside one. A write that throws -- a property
--that turns out not to be settable, a value the engine rejects -- cancels the
--recording rather than leaving half an edit on the stack.
local function recorded(name: string, edit: () -> ()): boolean
	local recording = ChangeHistoryService:TryBeginRecording(name)
	local ok, err = pcall(edit)

	if recording ~= nil then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not ok then
		warn("VFXEditor: " .. name .. " failed -- " .. tostring(err))
	end

	return ok
end

local function currentTheme()
	local theme = Studio.Theme
	return {
		background = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground),
		header = theme:GetColor(Enum.StudioStyleGuideColor.Titlebar),
		border = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		text = theme:GetColor(Enum.StudioStyleGuideColor.MainText),
		dimText = theme:GetColor(Enum.StudioStyleGuideColor.DimmedText),
		subText = theme:GetColor(Enum.StudioStyleGuideColor.SubText),
		rowHover = theme:GetColor(Enum.StudioStyleGuideColor.Item, Enum.StudioStyleGuideModifier.Hover),
		rowSelected = theme:GetColor(Enum.StudioStyleGuideColor.Item, Enum.StudioStyleGuideModifier.Selected),
		selectedText = theme:GetColor(Enum.StudioStyleGuideColor.MainText, Enum.StudioStyleGuideModifier.Selected),
		inputBackground = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground),
		inputBorder = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBorder),
		buttonBackground = theme:GetColor(Enum.StudioStyleGuideColor.Button),
		buttonBorder = theme:GetColor(Enum.StudioStyleGuideColor.ButtonBorder),
		buttonText = theme:GetColor(Enum.StudioStyleGuideColor.ButtonText),
	}
end

--Build the editor window and wire it to `plugin`. Returns a controller with
--Toggle/IsOpen/SetOpen/Destroy plus an OpenChanged signal-ish callback hook so
--the caller can keep its toolbar button's active state in sync.
function VFXEditor.Create(plugin: Plugin)
	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false, -- start closed
		false, -- do not override the user's restored state
		900, -- default width
		480, -- default height
		520, -- minimum width
		260 -- minimum height
	)

	local widget = plugin:CreateDockWidgetPluginGui("VFXEditor", widgetInfo)
	widget.Name = "VFXEditor"
	widget.Title = "VFX Editor"
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local theme = currentTheme()

	local selectedSequence: Instance? = nil
	local selectedEmitter: Instance? = nil

	--the open picker list, if any, and whether a field is mid-edit
	local dropdown: GuiObject? = nil
	local fieldFocused = false

	--connections that track the currently inspected emitter, replaced whenever
	--the selection changes
	local emitterConnections = {}
	local connections = {}

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	root.BackgroundColor3 = theme.background
	root.Parent = widget

	--The playback band. It holds nothing but its buttons, because the layout
	--below arranges every child it can see -- the separating line underneath is
	--therefore a child of the root, not of the band it draws the edge of.
	local toolbar = Instance.new("Frame")
	toolbar.Name = "Playback"
	toolbar.Size = UDim2.new(1, 0, 0, TOOLBAR_HEIGHT)
	toolbar.BorderSizePixel = 0
	toolbar.BackgroundColor3 = theme.header
	--the target name grows with the text, so a long one is cut at the window
	--edge rather than drawn past it
	toolbar.ClipsDescendants = true
	toolbar.Parent = root

	local toolbarLayout = Instance.new("UIListLayout")
	toolbarLayout.FillDirection = Enum.FillDirection.Horizontal
	toolbarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toolbarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	toolbarLayout.Padding = UDim.new(0, 6)
	toolbarLayout.Parent = toolbar

	local toolbarPadding = Instance.new("UIPadding")
	toolbarPadding.PaddingLeft = UDim.new(0, PADDING)
	toolbarPadding.PaddingRight = UDim.new(0, PADDING)
	toolbarPadding.Parent = toolbar

	local toolbarDivider = Instance.new("Frame")
	toolbarDivider.Name = "PlaybackDivider"
	toolbarDivider.Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT - 1)
	toolbarDivider.Size = UDim2.new(1, 0, 0, 1)
	toolbarDivider.BorderSizePixel = 0
	toolbarDivider.BackgroundColor3 = theme.border
	toolbarDivider.Parent = root

	--Icon beside label, both centred, the way the same two commands read on the
	--ribbon. The button's own Text is left empty so the pair can be centred
	--together: a button's text always centres on the whole button, which with an
	--icon in the way would sit off to one side of it.
	local function makeToolbarButton(text: string, order: number, icon: string)
		local button = Instance.new("TextButton")
		button.Name = (text:gsub("%s", ""))
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(BUTTON_WIDTH, ROW_HEIGHT)
		button.BackgroundColor3 = theme.buttonBackground
		button.BorderColor3 = theme.buttonBorder
		button.Text = ""
		button.Parent = toolbar

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.Parent = button

		local image = Instance.new("ImageLabel")
		image.Name = "Icon"
		image.LayoutOrder = 1
		image.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
		image.BackgroundTransparency = 1
		image.Image = icon
		--the ribbon icons are square artwork, so they are fitted rather than
		--stretched to whatever the button leaves them
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = button

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.LayoutOrder = 2
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, ROW_HEIGHT)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.SourceSans
		label.TextSize = TEXT_SIZE
		label.TextColor3 = theme.buttonText
		label.Text = text
		label.Parent = button

		return button, image, label
	end

	local playButton, playIcon, playLabel = makeToolbarButton("Play VFX", 1, PLAY_ICON)
	local stopButton, _, stopLabel = makeToolbarButton("Stop All", 2, STOP_ICON)

	--Play acts on the pane's selection rather than the hierarchy's, which is not
	--something a button can show on its own, so the target is named beside it.
	local playTarget = Instance.new("TextLabel")
	playTarget.Name = "PlayTarget"
	playTarget.LayoutOrder = 3
	playTarget.AutomaticSize = Enum.AutomaticSize.X
	playTarget.Size = UDim2.fromOffset(0, ROW_HEIGHT)
	playTarget.BackgroundTransparency = 1
	playTarget.Font = Enum.Font.SourceSans
	playTarget.TextSize = TEXT_SIZE
	playTarget.TextXAlignment = Enum.TextXAlignment.Left
	playTarget.TextColor3 = theme.dimText
	playTarget.Text = ""
	playTarget.Parent = toolbar

	--The window owns the buttons but not the playback engine, so what they
	--actually do is supplied by the caller.
	local playCallbacks = {}
	local stopCallbacks = {}

	playButton.Activated:Connect(function()
		local sequence = selectedSequence
		if sequence == nil then
			return
		end

		for _, callback in playCallbacks do
			callback(sequence)
		end
	end)

	stopButton.Activated:Connect(function()
		for _, callback in stopCallbacks do
			callback()
		end
	end)

	local function updateToolbar()
		local sequence = selectedSequence
		local playable = sequence ~= nil

		playButton.Active = playable
		playButton.AutoButtonColor = playable
		playLabel.TextColor3 = if playable then theme.buttonText else theme.dimText
		playIcon.ImageTransparency = if playable then 0 else 0.6
		playTarget.Text = if sequence ~= nil then sequence.Name else "Select a sequence to play."
	end

	--The panes are laid out inside their own frame rather than directly in the
	--root, because a UIListLayout arranges every child it can see: an overlay
	--dropped into the root would be given a column of its own and push the panes
	--out of the window. The root is left as plain space for things that sit on
	--top of the layout instead of in it.
	local paneHolder = Instance.new("Frame")
	paneHolder.Name = "Panes"
	paneHolder.Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT)
	paneHolder.Size = UDim2.new(1, 0, 1, -TOOLBAR_HEIGHT)
	paneHolder.BackgroundTransparency = 1
	paneHolder.BorderSizePixel = 0
	paneHolder.Parent = root

	local paneLayout = Instance.new("UIListLayout")
	paneLayout.FillDirection = Enum.FillDirection.Horizontal
	paneLayout.SortOrder = Enum.SortOrder.LayoutOrder
	paneLayout.Parent = paneHolder

	--one third of the window each, laid out left to right
	local function buildPane(titleText: string, order: number)
		local pane = Instance.new("Frame")
		pane.Name = titleText:gsub("%s", "")
		pane.LayoutOrder = order
		pane.Size = UDim2.fromScale(1 / 3, 1)
		pane.BorderSizePixel = 0
		pane.BackgroundColor3 = theme.background
		pane.Parent = paneHolder

		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
		header.BorderSizePixel = 0
		header.BackgroundColor3 = theme.header
		header.Parent = pane

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(1, -PADDING * 2, 1, 0)
		title.Position = UDim2.fromOffset(PADDING, 0)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.SourceSansBold
		title.TextSize = TEXT_SIZE
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = theme.text
		title.Text = titleText
		title.Parent = header

		local content = Instance.new("ScrollingFrame")
		content.Name = "Content"
		content.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
		content.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
		content.BackgroundTransparency = 1
		content.BorderSizePixel = 0
		content.ScrollBarThickness = 8
		content.ScrollingDirection = Enum.ScrollingDirection.Y
		content.CanvasSize = UDim2.new()
		content.AutomaticCanvasSize = Enum.AutomaticSize.Y
		content.Parent = pane

		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = content

		--right-hand divider, so the three panes read as separate columns
		local divider = Instance.new("Frame")
		divider.Name = "Divider"
		divider.AnchorPoint = Vector2.new(1, 0)
		divider.Position = UDim2.fromScale(1, 0)
		divider.Size = UDim2.new(0, 1, 1, 0)
		divider.BorderSizePixel = 0
		divider.BackgroundColor3 = theme.border
		divider.Parent = pane

		return {
			pane = pane,
			header = header,
			title = title,
			content = content,
			divider = divider,
		}
	end

	local sequencePane = buildPane("VFX Sequences", 1)
	local emitterPane = buildPane("Emitters", 2)
	local parameterPane = buildPane("Parameters", 3)
	--nothing sits to the right of the last pane
	parameterPane.divider.Visible = false

	local function clearPane(pane)
		for _, child in pane.content:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	--a non-interactive line of text, used for empty states and section titles
	local function addLabelRow(pane, order: number, text: string, color: Color3, bold: boolean)
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		label.BackgroundTransparency = 1
		label.Font = bold and Enum.Font.SourceSansBold or Enum.Font.SourceSans
		label.TextSize = TEXT_SIZE
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.TextColor3 = color
		label.Text = text
		label.Parent = pane.content

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.Parent = label

		return label
	end

	--a selectable list entry: primary name on the left, dimmed detail on the right
	local function addSelectableRow(pane, order: number, primary: string, secondary: string, selected: boolean, onClick)
		local button = Instance.new("TextButton")
		button.Name = "Row"
		button.LayoutOrder = order
		button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.BackgroundColor3 = selected and theme.rowSelected or theme.background
		button.BackgroundTransparency = selected and 0 or 1
		button.Text = ""
		button.Parent = pane.content

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.Parent = button

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.Size = UDim2.fromScale(0.65, 1)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.SourceSans
		nameLabel.TextSize = TEXT_SIZE
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.TextColor3 = selected and theme.selectedText or theme.text
		nameLabel.Text = primary
		nameLabel.Parent = button

		local detailLabel = Instance.new("TextLabel")
		detailLabel.Name = "Detail"
		detailLabel.AnchorPoint = Vector2.new(1, 0)
		detailLabel.Position = UDim2.fromScale(1, 0)
		detailLabel.Size = UDim2.fromScale(0.35, 1)
		detailLabel.BackgroundTransparency = 1
		detailLabel.Font = Enum.Font.SourceSans
		detailLabel.TextSize = TEXT_SIZE
		detailLabel.TextXAlignment = Enum.TextXAlignment.Right
		detailLabel.TextTruncate = Enum.TextTruncate.AtEnd
		detailLabel.TextColor3 = theme.dimText
		detailLabel.Text = secondary
		detailLabel.Parent = button

		if not selected then
			button.MouseEnter:Connect(function()
				button.BackgroundTransparency = 0
				button.BackgroundColor3 = theme.rowHover
			end)
			button.MouseLeave:Connect(function()
				button.BackgroundTransparency = 1
			end)
		end

		button.Activated:Connect(onClick)

		return button
	end

	--A list floated over the window, on a backdrop that dismisses it when
	--clicked. Roblox provides no dropdown, so enum and instance pickers draw
	--their own.
	local function closeDropdown()
		if dropdown ~= nil then
			dropdown:Destroy()
			dropdown = nil
		end
	end

	local function openDropdown(anchor: GuiObject, items)
		closeDropdown()

		local backdrop = Instance.new("TextButton")
		backdrop.Name = "DropdownBackdrop"
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundTransparency = 1
		backdrop.Text = ""
		backdrop.ZIndex = 10
		backdrop.AutoButtonColor = false
		backdrop.Parent = root
		dropdown = backdrop

		backdrop.Activated:Connect(closeDropdown)

		local windowSize = root.AbsoluteSize
		local height = math.min(#items * ROW_HEIGHT, windowSize.Y)
		local offset = anchor.AbsolutePosition - root.AbsolutePosition
		local below = offset.Y + anchor.AbsoluteSize.Y

		--flips above the anchor when there is no room beneath it, which near the
		--bottom of a short window there often is not
		local y = if below + height <= windowSize.Y then below else math.max(0, offset.Y - height)
		local width = math.clamp(anchor.AbsoluteSize.X, math.min(140, windowSize.X), windowSize.X)
		local x = math.clamp(offset.X, 0, math.max(0, windowSize.X - width))

		local list = Instance.new("ScrollingFrame")
		list.Name = "Dropdown"
		list.Position = UDim2.fromOffset(x, y)
		list.Size = UDim2.fromOffset(width, height)
		list.BackgroundColor3 = theme.background
		list.BorderColor3 = theme.border
		list.ScrollBarThickness = 6
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ZIndex = 11
		list.Parent = backdrop

		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list

		for index, item in items do
			local option = Instance.new("TextButton")
			option.LayoutOrder = index
			option.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			option.BackgroundColor3 = theme.rowHover
			option.BackgroundTransparency = 1
			option.BorderSizePixel = 0
			option.AutoButtonColor = false
			option.Font = Enum.Font.SourceSans
			option.TextSize = TEXT_SIZE
			option.TextXAlignment = Enum.TextXAlignment.Left
			option.TextTruncate = Enum.TextTruncate.AtEnd
			option.TextColor3 = if item.activate ~= nil then theme.text else theme.dimText
			option.Text = item.text
			option.ZIndex = 11
			option.Parent = list

			local optionPadding = Instance.new("UIPadding")
			optionPadding.PaddingLeft = UDim.new(0, PADDING)
			optionPadding.PaddingRight = UDim.new(0, PADDING)
			optionPadding.Parent = option

			if item.activate ~= nil then
				option.MouseEnter:Connect(function()
					option.BackgroundTransparency = 0
				end)
				option.MouseLeave:Connect(function()
					option.BackgroundTransparency = 1
				end)
				option.Activated:Connect(function()
					closeDropdown()
					item.activate()
				end)
			end
		end
	end

	local function makeInput(): TextBox
		local box = Instance.new("TextBox")
		box.Position = UDim2.fromOffset(0, 2)
		box.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
		box.BackgroundColor3 = theme.inputBackground
		box.BorderColor3 = theme.inputBorder
		box.Font = Enum.Font.SourceSans
		box.TextSize = TEXT_SIZE
		box.TextColor3 = theme.text
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.ClearTextOnFocus = false
		box.Text = ""

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 4)
		padding.PaddingRight = UDim.new(0, 4)
		padding.Parent = box

		--a pane that rebuilt itself under a half-typed field would throw the edit
		--away, and the drivers rewrite emitter properties every frame while a
		--sequence plays, so redraws are held off until the field is done with
		box.Focused:Connect(function()
			fieldFocused = true
		end)
		box.FocusLost:Connect(function()
			fieldFocused = false
		end)

		return box
	end

	local function makeValueButton(text: string, asField: boolean?): TextButton
		local button = Instance.new("TextButton")
		button.Position = UDim2.fromOffset(0, 2)
		button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
		button.BackgroundColor3 = if asField then theme.inputBackground else theme.buttonBackground
		button.BorderColor3 = if asField then theme.inputBorder else theme.buttonBorder
		button.Font = Enum.Font.SourceSans
		button.TextSize = TEXT_SIZE
		button.TextColor3 = if asField then theme.text else theme.buttonText
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.TextTruncate = Enum.TextTruncate.AtEnd
		button.Text = text

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 4)
		padding.PaddingRight = UDim.new(0, 4)
		padding.Parent = button

		return button
	end

	--A value typed as text. Committing happens when the field loses focus, and
	--text that cannot be read back as the value's own type puts the old text
	--back rather than writing anything. Text that has not been touched commits
	--nothing at all, so merely clicking through a field cannot round it off.
	local function fillTextEditor(container: Frame, value: any, commit: (any) -> ())
		local box = makeInput()

		local original = Fields.ToText(value)
		box.Text = original
		box.Parent = container

		box.FocusLost:Connect(function()
			if box.Text == original then
				return
			end

			local parsed, ok = Fields.Parse(box.Text, value)
			if not ok then
				box.Text = original
				return
			end

			commit(parsed)
		end)
	end

	--A curve is not something to type, so the row shows its keypoints and opens
	--the sequence editor on click. That window writes back through the same
	--commit as any other field, so a dragged keypoint is one undo step like
	--everything else.
	local function fillSequenceEditor(container: Frame, value: any, commit: (any) -> (), title: string)
		local button = makeValueButton(Fields.ToText(value), true)
		button.Parent = container

		local kind = if typeof(value) == "ColorSequence" then "colorSequence" else "numberSequence"

		button.Activated:Connect(function()
			SequenceEditor.Open(plugin, title, kind, value, commit)
		end)
	end

	local function fillBooleanEditor(container: Frame, value: boolean, commit: (any) -> ())
		local button = makeValueButton(tostring(value))
		button.Parent = container

		button.Activated:Connect(function()
			commit(not value)
		end)
	end

	local function fillEnumEditor(container: Frame, value: EnumItem, commit: (any) -> ())
		local button = makeValueButton(value.Name)
		button.Parent = container

		button.Activated:Connect(function()
			local items = {}
			for _, option in value.EnumType:GetEnumItems() do
				table.insert(items, {
					text = option.Name,
					activate = function()
						commit(option)
					end,
				})
			end
			openDropdown(button, items)
		end)
	end

	--Several numbers making up one value, typed a component at a time. `build`
	--puts an edited set back together into the value's own type.
	--
	--A commit reads every box rather than the value the row was drawn from:
	--redraws are held off while a field has focus, so tabbing from one
	--component straight into the next leaves the row showing an edit the
	--underlying value has not caught up with, and building from the older
	--reading would quietly put the first component back.
	local function fillComponentEditor(container: Frame, components, values, build, commit: (any) -> ())
		local count = #components
		local boxes = {}
		local originals = {}

		local function gather(): { number }?
			local parts = {}
			for index = 1, count do
				local number = Fields.ParseNumber(boxes[index].Text)
				if number == nil then
					return nil
				end
				parts[index] = number
			end
			return parts
		end

		for index = 1, count do
			local box = makeInput()
			box.Size = UDim2.new(1 / count, -3, 0, ROW_HEIGHT - 4)
			box.Position = UDim2.new((index - 1) / count, if index == 1 then 0 else 2, 0, 2)
			box.PlaceholderText = components[index]
			box.PlaceholderColor3 = theme.dimText

			originals[index] = Fields.FormatNumber(values[index])
			box.Text = originals[index]
			box.Parent = container
			boxes[index] = box

			box.FocusLost:Connect(function()
				if box.Text == originals[index] then
					return
				end

				local parts = gather()
				if parts == nil then
					box.Text = originals[index]
					return
				end

				commit(build(parts))
			end)
		end
	end

	--An instance cannot be typed, so it is set from the Studio selection, the
	--same gesture the Properties pane uses for an ObjectValue.
	local function fillInstanceEditor(container: Frame, value: Instance?, commit: (any) -> ())
		local button = makeValueButton(if value ~= nil then Fields.ToText(value) else "(not set)", true)
		button.Parent = container

		button.Activated:Connect(function()
			local items = {}

			if value ~= nil then
				table.insert(items, { text = value:GetFullName() })
			end

			local selected = Selection:Get()
			if #selected == 1 then
				table.insert(items, {
					text = "Set to " .. selected[1].Name,
					activate = function()
						commit(selected[1])
					end,
				})
			else
				table.insert(items, { text = "Select one instance in Studio to set" })
			end

			openDropdown(button, items)
		end)
	end

	local function fillReadOnly(container: Frame, value: any)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.SourceSans
		label.TextSize = TEXT_SIZE
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextWrapped = true
		label.TextColor3 = theme.dimText
		label.Text = Fields.ToText(value)
		label.Parent = container
	end

	--Pick the control that suits the value's type. `kind` names the control
	--outright for a row whose type cannot carry it -- an unset instance
	--reference is just nil, and nothing about nil says "pick an instance".
	--Anything left without a control is shown dimmed and left alone.
	local function fillEditor(container: Frame, value: any, commit: ((any) -> ())?, kind: string?, title: string?)
		if commit == nil then
			fillReadOnly(container, value)
			return
		end

		if kind == "instance" then
			fillInstanceEditor(container, value, commit)
			return
		end

		local valueType = typeof(value)

		if valueType == "NumberSequence" or valueType == "ColorSequence" then
			fillSequenceEditor(container, value, commit, title or "Sequence")
		elseif Fields.IsTextEditable(value) then
			fillTextEditor(container, value, commit)
		elseif valueType == "boolean" then
			fillBooleanEditor(container, value, commit)
		elseif valueType == "EnumItem" then
			fillEnumEditor(container, value, commit)
		elseif valueType == "NumberRange" then
			--NumberRange rejects a Min above its Max, so a range typed in either
			--order is taken as the two ends of the same range
			fillComponentEditor(container, { "Min", "Max" }, { value.Min, value.Max }, function(parts)
				return NumberRange.new(math.min(parts[1], parts[2]), math.max(parts[1], parts[2]))
			end, commit)
		elseif valueType == "Vector2" then
			fillComponentEditor(container, { "X", "Y" }, { value.X, value.Y }, function(parts)
				return Vector2.new(parts[1], parts[2])
			end, commit)
		elseif valueType == "Vector3" then
			fillComponentEditor(container, { "X", "Y", "Z" }, { value.X, value.Y, value.Z }, function(parts)
				return Vector3.new(parts[1], parts[2], parts[3])
			end, commit)
		else
			fillReadOnly(container, value)
		end
	end

	--A "name    editor" parameter line. A value with no control of its own is
	--shown as wrapped text, so the row grows downward with its editor; the name
	--keeps a fixed height so the row's height depends only on the editor.
	local function addParameterRow(order: number, name: string, value: any, commit: ((any) -> ())?, kind: string?)
		local row = Instance.new("Frame")
		row.Name = "Parameter"
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundTransparency = 1
		row.Parent = parameterPane.content

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, PADDING)
		padding.PaddingRight = UDim.new(0, PADDING)
		padding.PaddingBottom = UDim.new(0, 2)
		padding.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.Size = UDim2.new(NAME_COLUMN, -4, 0, ROW_HEIGHT)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.SourceSans
		nameLabel.TextSize = TEXT_SIZE
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextYAlignment = Enum.TextYAlignment.Top
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.TextColor3 = theme.subText
		nameLabel.Text = name
		nameLabel.Parent = row

		local editor = Instance.new("Frame")
		editor.Name = "Editor"
		editor.AnchorPoint = Vector2.new(1, 0)
		editor.Position = UDim2.fromScale(1, 0)
		editor.Size = UDim2.new(1 - NAME_COLUMN, 0, 0, ROW_HEIGHT)
		editor.AutomaticSize = Enum.AutomaticSize.Y
		editor.BackgroundTransparency = 1
		editor.Parent = row

		--what the sequence editor puts in its titlebar, fixed now rather than at
		--click time so a window opened from this row keeps naming this row
		local emitter = selectedEmitter
		local title = if emitter ~= nil then emitter.Name .. "." .. name else name

		fillEditor(editor, value, commit, kind, title)

		return row
	end

	local refreshSequences, refreshEmitters, refreshParameters

	local function disconnectEmitterConnections()
		for _, connection in emitterConnections do
			connection:Disconnect()
		end
		table.clear(emitterConnections)
	end

	--A redraw asked for by something that changed, rather than by the author.
	--Coalesced to one per frame, because playback rewrites every emitter
	--property on every heartbeat and each write reports itself separately, and
	--held off entirely while a field has focus so a half-typed edit survives.
	local refreshQueued = false

	local function requestParameterRefresh()
		if refreshQueued then
			return
		end

		refreshQueued = true
		task.defer(function()
			refreshQueued = false
			if not fieldFocused and widget.Enabled then
				refreshParameters()
			end
		end)
	end

	--keep the parameter pane live while an emitter is selected
	local function watchSelectedEmitter()
		disconnectEmitterConnections()

		local emitter = selectedEmitter
		if emitter == nil then
			return
		end

		table.insert(emitterConnections, emitter.AttributeChanged:Connect(requestParameterRefresh))
		table.insert(emitterConnections, emitter.Changed:Connect(requestParameterRefresh))
	end

	--Every write the pane makes goes through here, so each edit is one entry on
	--Studio's undo stack and reads back as "Set <name>" in the history.
	local function commitProperty(emitter: Instance, propertyName: string, value: any)
		if emitter.Parent == nil then
			return
		end

		recorded("Set " .. propertyName, function()
			(emitter :: any)[propertyName] = value
		end)

		requestParameterRefresh()
	end

	--`label` is what the pane called the row, which for a Base attribute is not
	--its real name; the undo entry reads back as the author saw it.
	local function commitAttribute(emitter: Instance, attributeName: string, label: string, value: any)
		if emitter.Parent == nil then
			return
		end

		recorded("Set " .. label, function()
			emitter:SetAttribute(attributeName, value)
		end)

		requestParameterRefresh()
	end

	--the mesh template is a child ObjectValue rather than a property, and is
	--created on demand so an emitter that never had one can still be pointed at
	--a mesh
	local function commitMeshTemplate(emitter: Instance, value: Instance?)
		if emitter.Parent == nil then
			return
		end

		recorded("Set MeshTemplate", function()
			local objectValue = emitter:FindFirstChildOfClass("ObjectValue")
			if objectValue == nil then
				objectValue = Instance.new("ObjectValue")
				objectValue.Name = "MeshTemplate"
				objectValue.Parent = emitter
			end
			objectValue.Value = value
		end)

		requestParameterRefresh()
	end

	function refreshParameters()
		closeDropdown()
		clearPane(parameterPane)

		local emitter = selectedEmitter
		if emitter == nil or emitter.Parent == nil then
			parameterPane.title.Text = "Parameters"
			addLabelRow(parameterPane, 1, "Select an emitter.", theme.dimText, false)
			return
		end

		parameterPane.title.Text = string.format("Parameters - %s", emitter.Name)

		local order = 0
		local function nextOrder()
			order += 1
			return order
		end

		local attributes = emitter:GetAttributes()
		local attributeNames = {}
		--what each attribute is called in the pane, and which native properties
		--a Base attribute is standing in for
		local displayNames = {}
		local shadowed = {}

		for attributeName in attributes do
			local shadows = baseAttributeTarget(attributeName)
			displayNames[attributeName] = shadows or attributeName
			if shadows ~= nil then
				shadowed[shadows] = true
			end
			table.insert(attributeNames, attributeName)
		end

		--sorted by what the pane calls them, so a Base attribute files under the
		--name the author reads rather than under B
		table.sort(attributeNames, function(a, b)
			return displayNames[a] < displayNames[b]
		end)

		addLabelRow(parameterPane, nextOrder(), "Properties", theme.subText, true)

		local propertyNames = NATIVE_PROPERTIES[emitter.ClassName]
		local shownProperties = 0
		if propertyNames ~= nil then
			for _, propertyName in propertyNames do
				local value, ok = readProperty(emitter, propertyName)
				if ok and not shadowed[propertyName] then
					addParameterRow(nextOrder(), propertyName, value, function(edited)
						commitProperty(emitter, propertyName, edited)
					end)
					shownProperties += 1
				end
			end
		end

		--the mesh template is wired up through an ObjectValue child rather than a
		--property, so surface it alongside the real properties
		if isMeshEmitter(emitter) then
			local objectValue = emitter:FindFirstChildOfClass("ObjectValue")
			local template = if objectValue ~= nil then objectValue.Value else nil
			addParameterRow(nextOrder(), "MeshTemplate", template, function(edited)
				commitMeshTemplate(emitter, edited)
			end, "instance")
			shownProperties += 1
		end

		if shownProperties == 0 then
			addLabelRow(parameterPane, nextOrder(), "No properties listed for this class.", theme.dimText, false)
		end

		addLabelRow(parameterPane, nextOrder(), string.format("Attributes (%d)", #attributeNames), theme.subText, true)

		if #attributeNames == 0 then
			addLabelRow(parameterPane, nextOrder(), "No attributes.", theme.dimText, false)
		else
			for _, attributeName in attributeNames do
				local label = displayNames[attributeName]
				addParameterRow(nextOrder(), label, attributes[attributeName], function(edited)
					commitAttribute(emitter, attributeName, label, edited)
				end)
			end
		end
	end

	local function selectEmitter(emitter: Instance?)
		selectedEmitter = emitter
		watchSelectedEmitter()
		refreshEmitters()
		refreshParameters()
	end

	function refreshEmitters()
		clearPane(emitterPane)

		local sequence = selectedSequence
		if sequence == nil or sequence.Parent == nil then
			emitterPane.title.Text = "Emitters"
			addLabelRow(emitterPane, 1, "Select a VFX sequence.", theme.dimText, false)
			return
		end

		local emitters = collectEmitters(sequence)
		emitterPane.title.Text = string.format("Emitters (%d)", #emitters)

		if #emitters == 0 then
			addLabelRow(emitterPane, 1, "This sequence has no emitters.", theme.dimText, false)
			return
		end

		for index, emitter in emitters do
			addSelectableRow(
				emitterPane,
				index,
				emitter.Name,
				emitterKind(emitter),
				emitter == selectedEmitter,
				function()
					selectEmitter(emitter)
				end
			)
		end
	end

	local function selectSequence(sequence: Instance?)
		selectedSequence = sequence
		selectedEmitter = nil
		watchSelectedEmitter()
		refreshSequences()
		refreshEmitters()
		refreshParameters()
	end

	function refreshSequences()
		clearPane(sequencePane)
		updateToolbar()

		local sequences = CollectionService:GetTagged(VFX_SEQUENCE_TAG)
		table.sort(sequences, function(a, b)
			return a.Name < b.Name
		end)

		sequencePane.title.Text = string.format("VFX Sequences (%d)", #sequences)

		if #sequences == 0 then
			addLabelRow(sequencePane, 1, "Nothing tagged 'VFXSequence'.", theme.dimText, false)
			return
		end

		for index, sequence in sequences do
			local parentName = sequence.Parent ~= nil and sequence.Parent.Name or ""
			addSelectableRow(sequencePane, index, sequence.Name, parentName, sequence == selectedSequence, function()
				selectSequence(sequence)
			end)
		end
	end

	--drop a selection whose instance was deleted or untagged, then redraw
	local function refreshAll()
		if selectedSequence ~= nil then
			local stillTagged = selectedSequence.Parent ~= nil
				and CollectionService:HasTag(selectedSequence, VFX_SEQUENCE_TAG)
			if not stillTagged then
				selectedSequence = nil
				selectedEmitter = nil
				watchSelectedEmitter()
			end
		end

		if selectedEmitter ~= nil and selectedEmitter.Parent == nil then
			selectedEmitter = nil
			watchSelectedEmitter()
		end

		refreshSequences()
		refreshEmitters()
		refreshParameters()
	end

	local function applyTheme()
		theme = currentTheme()

		root.BackgroundColor3 = theme.background
		toolbar.BackgroundColor3 = theme.header
		toolbarDivider.BackgroundColor3 = theme.border
		playTarget.TextColor3 = theme.dimText
		stopLabel.TextColor3 = theme.buttonText

		for _, button in { playButton, stopButton } do
			button.BackgroundColor3 = theme.buttonBackground
			button.BorderColor3 = theme.buttonBorder
		end

		for _, pane in { sequencePane, emitterPane, parameterPane } do
			pane.pane.BackgroundColor3 = theme.background
			pane.header.BackgroundColor3 = theme.header
			pane.title.TextColor3 = theme.text
			pane.divider.BackgroundColor3 = theme.border
		end

		--rows carry theme colours baked in at creation, so redraw them
		refreshAll()
	end

	table.insert(connections, Studio.ThemeChanged:Connect(applyTheme))
	table.insert(
		connections,
		CollectionService:GetInstanceAddedSignal(VFX_SEQUENCE_TAG):Connect(function()
			if widget.Enabled then
				refreshAll()
			end
		end)
	)
	table.insert(
		connections,
		CollectionService:GetInstanceRemovedSignal(VFX_SEQUENCE_TAG):Connect(function()
			if widget.Enabled then
				refreshAll()
			end
		end)
	)
	table.insert(
		connections,
		widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			if widget.Enabled then
				refreshAll()
			end
		end)
	)

	refreshAll()

	local controller = {}

	function controller:IsOpen(): boolean
		return widget.Enabled
	end

	function controller:SetOpen(open: boolean)
		widget.Enabled = open
	end

	function controller:Toggle()
		widget.Enabled = not widget.Enabled
	end

	--The playback buttons live in the window but the engine that drives a
	--sequence does not, so the caller says what they do. Play is handed the
	--sequence picked in the left pane, and is inert until one is picked.
	function controller:OnPlay(callback)
		table.insert(playCallbacks, callback)
	end

	function controller:OnStop(callback)
		table.insert(stopCallbacks, callback)
	end

	--fires whenever the window is opened or closed, including via its own close
	--button, so a toolbar button can mirror the state
	function controller:OnOpenChanged(callback)
		table.insert(
			connections,
			widget:GetPropertyChangedSignal("Enabled"):Connect(function()
				callback(widget.Enabled)
			end)
		)
	end

	function controller:Destroy()
		closeDropdown()
		SequenceEditor.Destroy()
		disconnectEmitterConnections()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		widget:Destroy()
	end

	return controller
end

return VFXEditor
