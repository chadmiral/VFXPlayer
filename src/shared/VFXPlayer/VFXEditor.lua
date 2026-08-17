--Studio-only inspector window for the VFX in a place. A band of playback
--controls across the top, and under it three panes, left to right: every
--instance tagged "VFXSequence", the emitters inside the selected sequence, and
--the native properties plus attributes of the selected emitter.
local VFXEditor = {}

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Selection = game:GetService("Selection")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local Studio = settings().Studio

local Fields = require(script.Parent:WaitForChild("VFXEditorFields"))
local SequenceEditor = require(script.Parent:WaitForChild("VFXSequenceEditor"))

--the runtime's own timeline builder, so the bar the editor draws is sequenced by
--the same code that plays it
local Utility = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Utility)

local VFX_SEQUENCE_TAG = "VFXSequence"
local MESH_EMITTER_TAG = "MeshEmitter"

local HEADER_HEIGHT = 26
local ROW_HEIGHT = 22
local TEXT_SIZE = 14
local PADDING = 8
--the playback band above the panes, and the size of a button in it
local TOOLBAR_HEIGHT = 32
--the buttons are square and carry nothing but their icon, with what each one does
--in a tooltip rather than on its face
local BUTTON_SIZE = 22
local ICON_SIZE = 16
--how long the mouse has to rest on a button before its tooltip appears, so that
--sweeping across the toolbar does not flash every one of them in turn
local TOOLTIP_DELAY = 0.4
local TOOLTIP_PADDING = 6
--The stage timeline below the buttons: one row per emitter, stacked on a shared
--time axis. The band grows with the emitter count up to MAX_ROWS and then
--scrolls, so a sequence with three emitters does not reserve room for thirty.
local TIMELINE_ROW_HEIGHT = 20
local TIMELINE_TRACK_HEIGHT = 14
local TIMELINE_NAME_WIDTH = 118
local TIMELINE_AXIS_HEIGHT = 16
local TIMELINE_MAX_ROWS = 10
local TIMELINE_SCROLLBAR = 6
--the room the three panes are always left with, which is what decides how many
--rows the band may take for itself
local TIMELINE_MIN_PANES = 140
--Where a row's bar starts and stops, which the lines drawn across every row
--share. The rows always reserve the scroll bar so this column is the same width
--whether the bar is showing or not, and the lines cannot drift out of step.
local TIMELINE_TRACK_LEFT = PADDING + TIMELINE_NAME_WIDTH
local TIMELINE_TRACK_RIGHT = PADDING + TIMELINE_SCROLLBAR
--How near a stage border counts as being on it, and the white line drawn over the
--border while the mouse is that near or is dragging it.
local BORDER_GRAB = 5
local BORDER_HIGHLIGHT_WIDTH = 3
--How soon after a click on an emitter's name a second one counts as a double
--click, which is what opens that name for editing.
local DOUBLE_CLICK_TIME = 0.4
--What a dragged length snaps to, so that a drag lands on a round number rather
--than on whatever pixel the mouse happened to be over.
local DRAG_SNAP = 0.1
--The shortest a stage can be dragged, which is one snap step: the step below it is
--nothing at all, and a stage of no length disappears from the timeline along with
--the border that would drag it back. Zeroing a stage out is what the parameters
--pane is for.
local MIN_DRAG_DURATION = DRAG_SNAP

--the icons these two buttons carried when they lived on the Studio ribbon
local PLAY_ICON = "rbxassetid://8215093320"
local STOP_ICON = "rbxassetid://579151508"

--Studio's own ribbon artwork for adding and deleting: a plus and a waste basket.
--It ships one copy of each per theme, so the name of the theme goes in the %s.
local ADD_ICON = "rbxasset://studio_svg_textures/Shared/Ribbon/%s/Standard/RibbonAddNoBorderSmall.png"
local DELETE_ICON = "rbxasset://studio_svg_textures/Shared/Ribbon/%s/Standard/RibbonDeleteSmall.png"

--What Add Emitter offers: what the menu calls each one, the class it creates, and
--for the mesh emitter the tag the runtime knows it by, since that is an ordinary
--Attachment until it is tagged.
--`attachTo` is what the class needs above it to render at all: an emitter or a
--light will hang off either a part or an attachment and prefers an attachment,
--while an attachment itself can only go on a part.
local NEW_EMITTER_KINDS = {
	{ text = "Particle Emitter", className = "ParticleEmitter", attachTo = "Attachment" },
	{ text = "Mesh Emitter", className = "Attachment", tag = MESH_EMITTER_TAG, attachTo = "BasePart" },
	{ text = "Light", className = "PointLight", attachTo = "Attachment" },
}

--A fill per stage, and red for the delays between them. Fixed rather than drawn
--from the theme, since the point is to tell the four apart at a glance.
local STAGE_COLORS = {
	stand = Color3.fromRGB(74, 134, 204),
	hold = Color3.fromRGB(78, 158, 96),
	decay = Color3.fromRGB(198, 142, 60),
}
local DELAY_COLOR = Color3.fromRGB(188, 66, 66)

--the three animation stages, in playback order
local STAGES = { "Stand", "Hold", "Decay" }

--Snap a dragged length, then clear the floating point drift that multiplying the
--step count back out leaves behind, so that the number the parameters pane goes
--on to show is exactly the one an author would have typed themselves.
local function snapSeconds(value: number): number
	local snapped = math.floor(value / DRAG_SNAP + 0.5) * DRAG_SNAP
	return math.floor(snapped * 1000 + 0.5) / 1000
end

--The length given to an effect that names none, so that one loaded in the editor
--always has something to divide into stages and something to play for.
local DEFAULT_SEQUENCE_DURATION = 1

--Stage timings for one instance in playback order, shaped for
--Utility.BuildTimeline. `sequenceDuration` is what a Stand stage spans when it
--names no duration of its own.
--
--These attribute names mirror the runtime's own reader in Sequence.lua, and are
--read here rather than borrowed from it on purpose: this window is a plugin
--while that module belongs to the place, and Studio keeps the result of a module
--it has already required for the rest of the session. A function newly added
--over there is therefore absent from the copy a running session hands back,
--however many times the plugin itself reloads.
local function readStageTimings(inst: Instance, sequenceDuration: number)
	local stages = {}

	for _, stage in STAGES do
		local duration = inst:GetAttribute(stage .. "Duration")
		if duration == nil and stage == "Stand" then
			duration = sequenceDuration
		end

		table.insert(stages, {
			name = string.lower(stage),
			delay = inst:GetAttribute(stage .. "Delay") or 0,
			duration = duration or 0,
			loopCount = if stage == "Hold" then (inst:GetAttribute("HoldLoopCount") or 1) else 1,
		})
	end

	return stages
end
--how much of a parameter row the name takes, leaving the rest to the editor
local NAME_COLUMN = 0.45
--the small square buttons that live inside a row: the "+" on a stage's heading and
--the "-" on each of its parameters
local ROW_BUTTON_SIZE = ROW_HEIGHT - 6

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

--Somewhere inside `sequence` that a new emitter of `kind` can live. A sequence's
--root is a Model, and none of the three classes renders parented straight to one,
--so an emitter has to join whatever the effect already hangs its others off. The
--first suitable host in the hierarchy is taken; an attachment is preferred over a
--part where either would do, since that is where the emitters in these effects
--already sit. Returns nil for an effect with nothing suitable in it at all.
local function findEmitterHost(sequence: Instance, kind): Instance?
	local part = nil

	for _, d in sequence:GetDescendants() do
		--an attachment that is itself a mesh emitter is skipped: it is one of the
		--things being animated rather than somewhere to put another
		if kind.attachTo == "Attachment" and d:IsA("Attachment") and not isMeshEmitter(d) then
			return d
		elseif d:IsA("BasePart") then
			if kind.attachTo ~= "Attachment" then
				return d
			end
			part = part or d
		end
	end

	return part
end

--The host convention these effects already follow, for the one case where there
--is nothing to reuse: an anchored, invisible, collisionless part at the effect's
--own position, with an attachment inside it.
local function makeEmitterHost(sequence: Instance, kind): Instance
	local part = Instance.new("Part")
	part.Name = "EmitterPart"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	--so that a new emitter starts where the effect is rather than at the origin
	if sequence:IsA("PVInstance") then
		part.CFrame = sequence:GetPivot()
	end

	part.Parent = sequence

	if kind.attachTo ~= "Attachment" then
		return part
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "EmitterAttachment"
	attachment.Parent = part
	return attachment
end

--A "Base<Property>" attribute holds the authored value the runtime animates the
--matching native property away from and back to, so to an author the two are
--one parameter and the attribute is the half worth editing. Returns the
--property such an attribute stands in for, or nil if the name is not one.
local function baseAttributeTarget(attributeName: string): string?
	return string.match(attributeName, "^Base(.+)$")
end

--The sections the parameter pane is divided into, in the order it shows them: what
--the timeline is made of, then the emitter's own parameters split by whether they
--vary across a particle's life, then one section per stage for what that stage
--animates. The last three are built from STAGES so that they cannot fall out of
--step with it, and so that a section's index says which stage it is for.
local SECTION_TIMELINE = 1
local SECTION_PARTICLE_AGE = 2
local SECTION_BASE = 3
local SECTION_STAGE_FIRST = SECTION_BASE + 1

local SECTION_TITLES = {
	"Timeline",
	"Animated Over Particle Age",
	"Base Parameters",
}

--A wash of colour behind each section, so that what kind of parameter a row is can
--be read without looking back up to the heading it sits under. These are hues to
--blend into the theme's own background rather than colours in their own right, so
--that the pane stays as readable in a light theme as in a dark one.
--The first three keep well clear of the blue, green and orange the stages have
--taken; a teal for the second read too close to Stand's blue to be worth having.
local SECTION_HUES = {
	Color3.fromRGB(146, 108, 204),
	Color3.fromRGB(190, 96, 150),
	Color3.fromRGB(148, 148, 158),
}

--Each stage's section is named and coloured exactly as its block in the timeline
--is, which is the whole reason for splitting them apart: the band above says when
--Hold plays, and the green section below says what it does while it is playing.
for _, stage in STAGES do
	table.insert(SECTION_TITLES, stage)
	table.insert(SECTION_HUES, STAGE_COLORS[string.lower(stage)])
end

local SECTION_COUNT = #SECTION_TITLES

--How far towards its hue a section's rows are taken, and its heading, which goes
--much further: the heading band is where the colour is meant to be read, and it
--carries the theme's full-strength text so it can afford one. The rows only have
--to look washed, and a wash costs contrast whichever way it goes, since it
--lightens a dark theme's background and darkens a light one's. At this weight the
--wash is still some ten values away from the plain background -- plainly visible
--across a row's width -- while costing a tenth of the contrast the row's name had.
local SECTION_TINT = 0.07
local SECTION_HEADING_TINT = 0.32

--Of a stage's attributes, the ones that decide where the stage sits on the
--timeline rather than what it does while it is there. `LoopCount` belongs to Hold
--alone, but naming it per stage is not worth the exception.
local TIMELINE_STAGE_PARTS = {
	Delay = true,
	Duration = true,
	LoopCount = true,
}

--The sequence root's own timings, which are not named after any stage: how long
--the whole effect runs for and whether it starts again afterwards.
local TIMELINE_ATTRIBUTES = {
	Duration = true,
	Looping = true,
}

--What can be authored per stage, listed by the kind of emitter whose driver reads
--it: each entry is the part of the attribute name that follows the stage. These
--are the names the drivers actually look up, so a light is not offered the size
--curve it would ignore, and a mesh emitter -- whose driver reads a burst and no
--curves at all -- is offered only the burst. Kept in alphabetical order, which is
--the order the rows they become are sorted into, so that what a stage's menu
--offers and what its section shows read the same way down the list.
local STAGE_ATTRIBUTE_PARTS = {
	ParticleEmitter = {
		"BrightnessScaleOverDuration",
		"BurstCount",
		"EmissionScaleOverDuration",
		"LightEmissionScaleOverDuration",
		"LightInfluenceScaleOverDuration",
		"SizeScaleOverDuration",
		"TintOverDuration",
		"TransparencyScaleOverDuration",
	},
	PointLight = {
		"BrightnessScaleOverDuration",
		"RangeScaleOverDuration",
		"TintOverDuration",
	},
	SpotLight = {
		"AngleScaleOverDuration",
		"BrightnessScaleOverDuration",
		"RangeScaleOverDuration",
		"TintOverDuration",
	},
	[MESH_EMITTER_TAG] = {
		"BurstCount",
	},
}

--What a newly added stage attribute starts at: whatever leaves playback exactly as
--it was, so that adding one gives something to edit rather than an immediate change
--to the effect. A scale curve of 1 multiplies a base value by itself, a white tint
--multiplies a colour by itself, and a burst of none emits nothing.
local function defaultStageValue(part: string): any
	if part == "BurstCount" then
		return 0
	end
	if string.find(part, "Tint", 1, true) ~= nil then
		return ColorSequence.new(Color3.new(1, 1, 1))
	end
	return NumberSequence.new(1)
end

--Which stage an attribute belongs to and what it says about that stage:
--"HoldDelay" is the Hold stage's "Delay". Returns nil for a name that names no
--stage, which is every parameter that is not authored per stage.
local function stageAttribute(attributeName: string): (number?, string?)
	for index, stage in STAGES do
		if string.sub(attributeName, 1, #stage) == stage then
			return index, string.sub(attributeName, #stage + 1)
		end
	end
	return nil, nil
end

--Which of the pane's sections a parameter belongs in. The per-stage attributes
--are told apart by their names, since names are how the runtime reads them, and
--everything else by whether its value is a curve: a ParticleEmitter's
--sequence-typed properties are exactly the ones evaluated across a particle's
--life, which is why the test is the value's type rather than a list of names to
--keep up to date.
local function sectionFor(name: string, value: any): number
	local stage, part = stageAttribute(name)
	if stage ~= nil then
		if part ~= nil and TIMELINE_STAGE_PARTS[part] then
			return SECTION_TIMELINE
		end
		--everything else a stage names belongs to that stage's own section
		return SECTION_STAGE_FIRST + stage - 1
	end

	if TIMELINE_ATTRIBUTES[name] then
		return SECTION_TIMELINE
	end

	--a mesh emitter animates over particle age through attributes that say as much
	--in their names, since an Attachment has no curve properties of its own
	if string.find(name, "OverParticleLifetime", 1, true) ~= nil then
		return SECTION_PARTICLE_AGE
	end

	local kind = typeof(value)
	if kind == "NumberSequence" or kind == "ColorSequence" then
		return SECTION_PARTICLE_AGE
	end

	return SECTION_BASE
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

--Author every stage timing the emitters of `sequence` are missing, so an effect
--loaded in the editor carries a full set to read and edit rather than leaving the
--runtime to fall back on values that are nowhere written down. A missing duration
--takes an even third of the sequence's own, and a missing delay is zero, so the
--three stages run back to back and fill the sequence exactly.
--
--Nothing is recorded when nothing is missing, so clicking through sequences does
--not litter the undo history with empty waypoints.
local function ensureStageAttributes(sequence: Instance)
	local writes = {}

	local function want(inst: Instance, name: string, value: any)
		if inst:GetAttribute(name) == nil then
			table.insert(writes, { instance = inst, name = name, value = value })
		end
	end

	--The effect's own length, which everything below is derived from. An absent
	--one is a fault rather than a choice: the runtime compares elapsed time
	--against it directly, so a sequence without one cannot play at all.
	local duration = sequence:GetAttribute("Duration")
	if duration == nil then
		duration = DEFAULT_SEQUENCE_DURATION
		want(sequence, "Duration", duration)
	end

	want(sequence, "Looping", false)

	--A length that is present but unusable is left exactly as authored rather than
	--overwritten, which leaves nothing to divide into stages.
	if typeof(duration) == "number" and duration > 0 then
		local share = duration / #STAGES

		for _, emitter in collectEmitters(sequence) do
			for _, stage in STAGES do
				want(emitter, stage .. "Delay", 0)
				want(emitter, stage .. "Duration", share)
			end

			--not a timing, but how many times the hold window repeats; writing the
			--value it already falls back to changes nothing beyond making it editable
			want(emitter, "HoldLoopCount", 1)
		end
	end

	if #writes == 0 then
		return
	end

	recorded("Add missing VFX attributes to " .. sequence.Name, function()
		for _, write in writes do
			write.instance:SetAttribute(write.name, write.value)
		end
	end)
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

--Which copy of a two-tone Studio icon to use. The wrong one is artwork very
--nearly the colour of the button behind it, so it is picked by how dark the theme
--actually is rather than by what it happens to be called.
local function iconVariant(theme): string
	local fill = theme.buttonBackground
	local luminance = fill.R * 0.299 + fill.G * 0.587 + fill.B * 0.114
	return if luminance < 0.5 then "Dark" else "Light"
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
		--enough that the playback and timeline bands still leave the panes usable
		320 -- minimum height
	)

	local widget = plugin:CreateDockWidgetPluginGui("VFXEditor", widgetInfo)
	widget.Name = "VFXEditor"
	widget.Title = "VFX Editor"
	widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local theme = currentTheme()

	local selectedSequence: Instance? = nil
	local selectedEmitter: Instance? = nil

	--Picking an emitter redraws the panes and the timeline, all of which are built
	--below, but the toolbar and the timeline rows above both need to ask for it, so
	--it is named here and defined down there. The same goes for the picker list,
	--which the parameter rows and the Add Emitter button both raise.
	local selectEmitter
	local openDropdown

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
	--the timeline band sits between this and the buttons, and it is the one that
	--knows how tall it needs to be, so it places this line and the panes below it
	toolbarDivider.Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT - 1)
	toolbarDivider.Size = UDim2.new(1, 0, 0, 1)
	toolbarDivider.BorderSizePixel = 0
	toolbarDivider.BackgroundColor3 = theme.border
	toolbarDivider.Parent = root

	--Roblox gives a plugin window no tooltips of its own, so the toolbar draws its
	--own: one label floated over the window, since only one button can be under the
	--mouse at a time. It hangs below the toolbar, so it is a child of the root and
	--not of the band -- and the root deliberately carries no layout that would
	--otherwise arrange it into a column of its own.
	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "Tooltip"
	tooltip.BackgroundColor3 = theme.inputBackground
	tooltip.BorderColor3 = theme.border
	tooltip.Font = Enum.Font.SourceSans
	tooltip.TextSize = TEXT_SIZE
	tooltip.TextColor3 = theme.text
	tooltip.ZIndex = 20
	tooltip.Visible = false
	tooltip.Text = ""
	tooltip.Parent = root

	--Bumped on every show and hide, so that a tooltip still waiting out its delay
	--knows the mouse has moved on and drops itself instead of appearing.
	local tooltipToken = 0

	local function hideTooltip()
		tooltipToken += 1
		tooltip.Visible = false
	end

	local function showTooltip(anchor: GuiObject, text: string)
		tooltipToken += 1
		local token = tooltipToken

		task.delay(TOOLTIP_DELAY, function()
			if token ~= tooltipToken or not widget.Enabled then
				return
			end

			--Measured rather than grown into place, so it can be centred under the
			--button it belongs to and kept inside the window in one go.
			local text_size = TextService:GetTextSize(text, TEXT_SIZE, Enum.Font.SourceSans, Vector2.new(1000, 100))
			local width = text_size.X + TOOLTIP_PADDING * 2
			local origin = anchor.AbsolutePosition - root.AbsolutePosition
			local x = origin.X + anchor.AbsoluteSize.X / 2 - width / 2
			local room = math.max(PADDING, root.AbsoluteSize.X - width - PADDING)

			tooltip.Text = text
			tooltip.Size = UDim2.fromOffset(width, ROW_HEIGHT)
			tooltip.Position =
				UDim2.fromOffset(math.floor(math.clamp(x, PADDING, room)), origin.Y + anchor.AbsoluteSize.Y + 3)
			tooltip.Visible = true
		end)
	end

	--A square button holding nothing but its icon. What it does is named in the
	--tooltip, which is the only place it is written now.
	local function makeToolbarButton(text: string, order: number, icon: string)
		local button = Instance.new("TextButton")
		button.Name = (text:gsub("%s", ""))
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE)
		button.BackgroundColor3 = theme.buttonBackground
		button.BorderColor3 = theme.buttonBorder
		button.Text = ""
		button.Parent = toolbar

		local image = Instance.new("ImageLabel")
		image.Name = "Icon"
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
		image.BackgroundTransparency = 1
		image.Image = icon
		--the ribbon icons are square artwork, so they are fitted rather than
		--stretched to whatever the button leaves them
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = button

		button.MouseEnter:Connect(function()
			showTooltip(button, text)
		end)
		button.MouseLeave:Connect(hideTooltip)
		--a tooltip left hanging over the menu a button just opened
		button.Activated:Connect(hideTooltip)

		return button, image
	end

	local playButton, playIcon = makeToolbarButton("Play VFX", 1, PLAY_ICON)
	local stopButton = makeToolbarButton("Stop All", 2, STOP_ICON)

	local variant = iconVariant(theme)
	local addButton, addIcon = makeToolbarButton("Add Emitter", 3, string.format(ADD_ICON, variant))
	local deleteButton, deleteIcon = makeToolbarButton("Delete Emitter", 4, string.format(DELETE_ICON, variant))

	--Play acts on the pane's selection rather than the hierarchy's, which is not
	--something a button can show on its own, so the target is named beside it.
	local playTarget = Instance.new("TextLabel")
	playTarget.Name = "PlayTarget"
	playTarget.LayoutOrder = 5
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

	--A fresh emitter of the chosen kind, carrying nothing but its class defaults and
	--joining whatever the effect already hangs its emitters off. The host, the
	--emitter and its stage timings are all authored in one recording, so adding one
	--is a single thing to undo rather than three: a recording started inside another
	--simply joins it.
	local function addEmitter(kind)
		local sequence = selectedSequence
		if sequence == nil or sequence.Parent == nil then
			return
		end

		local added = nil
		local ok = recorded(string.format("Add %s to %s", kind.text, sequence.Name), function()
			local host = findEmitterHost(sequence, kind) or makeEmitterHost(sequence, kind)

			added = Instance.new(kind.className)
			--tagged before it is parented, so that it already counts as an emitter by
			--the time anything watching the sequence hears about it
			if kind.tag ~= nil then
				CollectionService:AddTag(added, kind.tag)
			end
			added.Parent = host
			ensureStageAttributes(sequence)
		end)

		if ok and added ~= nil then
			selectEmitter(added)
		end
	end

	--Which kind to add is asked rather than assumed, since the runtime animates
	--three different sorts of emitter and they are not interchangeable.
	addButton.Activated:Connect(function()
		local items = {}
		for _, kind in NEW_EMITTER_KINDS do
			table.insert(items, {
				text = kind.text,
				activate = function()
					addEmitter(kind)
				end,
			})
		end

		openDropdown(addButton, items)
	end)

	--Parented away rather than destroyed: a destroyed instance is locked, and an
	--undo cannot bring it back.
	deleteButton.Activated:Connect(function()
		local emitter = selectedEmitter
		if emitter == nil or emitter.Parent == nil then
			return
		end

		local ok = recorded("Delete " .. emitter.Name, function()
			emitter.Parent = nil
		end)

		if ok then
			selectEmitter(nil)
		end
	end)

	--A button that cannot act says so: its icon fades and it stops lighting up
	--under the mouse.
	local function setButtonEnabled(button: TextButton, icon: ImageLabel, enabled: boolean)
		button.Active = enabled
		button.AutoButtonColor = enabled
		icon.ImageTransparency = if enabled then 0 else 0.6
	end

	local function updateToolbar()
		local sequence = selectedSequence
		local haveSequence = sequence ~= nil and sequence.Parent ~= nil

		setButtonEnabled(playButton, playIcon, sequence ~= nil)
		setButtonEnabled(addButton, addIcon, haveSequence)
		setButtonEnabled(deleteButton, deleteIcon, selectedEmitter ~= nil)

		playTarget.Text = if sequence ~= nil then sequence.Name else "Select a sequence to play."
	end

	--The panes are laid out inside their own frame rather than directly in the
	--root, because a UIListLayout arranges every child it can see: an overlay
	--dropped into the root would be given a column of its own and push the panes
	--out of the window. The root is left as plain space for things that sit on
	--top of the layout instead of in it.
	local paneHolder = Instance.new("Frame")
	paneHolder.Name = "Panes"
	paneHolder.BackgroundTransparency = 1
	paneHolder.BorderSizePixel = 0
	paneHolder.Parent = root

	local paneLayout = Instance.new("UIListLayout")
	paneLayout.FillDirection = Enum.FillDirection.Horizontal
	paneLayout.SortOrder = Enum.SortOrder.LayoutOrder
	paneLayout.Parent = paneHolder

	--The stage timeline. One row per emitter in the selected sequence, each
	--showing stand, hold and decay laid end to end with their delays between
	--them. Every row shares one time axis, so the rows can be read against each
	--other and a single line marks where playback has reached across all of them.
	local timelineBand = Instance.new("Frame")
	timelineBand.Name = "Timeline"
	timelineBand.Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT)
	timelineBand.BorderSizePixel = 0
	timelineBand.BackgroundColor3 = theme.header
	timelineBand.Parent = root

	local rows = Instance.new("ScrollingFrame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromOffset(0, 2)
	rows.BackgroundTransparency = 1
	rows.BorderSizePixel = 0
	rows.ScrollBarThickness = TIMELINE_SCROLLBAR
	rows.ScrollingDirection = Enum.ScrollingDirection.Y
	--always inset, so a row's bar is the same width whether the bar is showing or
	--not and the lines drawn over the rows stay aligned with it
	rows.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	rows.CanvasSize = UDim2.new()
	rows.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rows.Parent = timelineBand

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = rows

	--The two vertical lines are drawn across the rows rather than inside them, so
	--each is one continuous line down the whole stack. They live beside the
	--scrolling rows and share the bars' column, which is why that column reserves
	--the scroll bar whether or not it is showing.
	local overlay = Instance.new("Frame")
	overlay.Name = "Lines"
	overlay.Position = UDim2.fromOffset(TIMELINE_TRACK_LEFT, 2)
	overlay.Size = UDim2.new(1, -(TIMELINE_TRACK_LEFT + TIMELINE_TRACK_RIGHT), 1, -(2 + TIMELINE_AXIS_HEIGHT))
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ClipsDescendants = true
	overlay.ZIndex = 4
	overlay.Parent = timelineBand

	--Where the sequence itself ends, which is not always where the stages do: a
	--stage can be authored to run past the sequence's Duration, and playback stops
	--at the Duration regardless. Only shown when the two differ.
	local durationMark = Instance.new("Frame")
	durationMark.Name = "DurationMark"
	durationMark.Size = UDim2.new(0, 1, 1, 0)
	durationMark.BorderSizePixel = 0
	durationMark.BackgroundColor3 = theme.text
	durationMark.BackgroundTransparency = 0.45
	durationMark.Visible = false
	durationMark.Parent = overlay

	--The only thing playback touches.
	local playhead = Instance.new("Frame")
	playhead.Name = "Playhead"
	playhead.Size = UDim2.new(0, 2, 1, 0)
	playhead.BorderSizePixel = 0
	playhead.BackgroundColor3 = theme.text
	playhead.ZIndex = 2
	playhead.Visible = false
	playhead.Parent = overlay

	--stands in for the rows when there is nothing to lay out
	local timelineHint = Instance.new("TextLabel")
	timelineHint.Name = "Hint"
	timelineHint.Position = UDim2.fromOffset(PADDING, 2)
	timelineHint.Size = UDim2.new(1, -PADDING * 2, 0, TIMELINE_ROW_HEIGHT)
	timelineHint.BackgroundTransparency = 1
	timelineHint.Font = Enum.Font.SourceSans
	timelineHint.TextSize = TEXT_SIZE
	timelineHint.TextXAlignment = Enum.TextXAlignment.Left
	timelineHint.TextTruncate = Enum.TextTruncate.AtEnd
	timelineHint.TextColor3 = theme.dimText
	timelineHint.Text = ""
	timelineHint.Parent = timelineBand

	--The shared axis, labelled once under the stack rather than per row.
	local function makeTimeLabel(alignment: Enum.TextXAlignment): TextLabel
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0, 1)
		label.Position = UDim2.fromScale(0, 1)
		label.Size = UDim2.new(0.5, -PADDING, 0, TIMELINE_AXIS_HEIGHT)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.SourceSans
		label.TextSize = 12
		label.TextXAlignment = alignment
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.TextColor3 = theme.dimText
		label.Text = ""
		label.Parent = timelineBand
		return label
	end

	local startLabel = makeTimeLabel(Enum.TextXAlignment.Left)
	startLabel.Name = "StartTime"
	startLabel.Position = UDim2.new(0, TIMELINE_TRACK_LEFT, 1, 0)

	local endLabel = makeTimeLabel(Enum.TextXAlignment.Right)
	endLabel.Name = "EndTime"
	endLabel.AnchorPoint = Vector2.new(1, 1)
	endLabel.Position = UDim2.new(1, -TIMELINE_TRACK_RIGHT, 1, 0)

	--how many seconds a row spans, and so what a playhead position means
	local timelineSpan = 0

	--what the last refresh laid out, so a resize can re-fit the band without
	--having to rebuild the rows in it
	local timelineRowCount = 1

	--The band is only as tall as it needs to be, and everything below it follows.
	--It shows as many rows as will fit before it starts scrolling, since rows are
	--there to be read against each other, but never so many that the panes below
	--are squeezed out of the window.
	local function setTimelineHeight(rowCount: number)
		timelineRowCount = rowCount

		local spare = root.AbsoluteSize.Y - TOOLBAR_HEIGHT - TIMELINE_AXIS_HEIGHT - TIMELINE_MIN_PANES
		local allowed = math.clamp(spare // TIMELINE_ROW_HEIGHT, 1, TIMELINE_MAX_ROWS)
		local visibleRows = math.clamp(rowCount, 1, allowed)
		local height = 2 + visibleRows * TIMELINE_ROW_HEIGHT + TIMELINE_AXIS_HEIGHT

		timelineBand.Size = UDim2.new(1, 0, 0, height)
		rows.Size = UDim2.new(1, 0, 0, visibleRows * TIMELINE_ROW_HEIGHT)

		local top = TOOLBAR_HEIGHT + height
		toolbarDivider.Position = UDim2.fromOffset(0, top - 1)
		paneHolder.Position = UDim2.fromOffset(0, top)
		paneHolder.Size = UDim2.new(1, 0, 1, -top)
	end

	local function showTimelineHint(text: string)
		rows.Visible = false
		overlay.Visible = false
		startLabel.Visible = false
		endLabel.Visible = false
		timelineHint.Visible = true
		timelineHint.Text = text
		setTimelineHeight(1)
	end

	--The stage border being dragged, if any: which attribute the block's length is
	--written to, where that block starts, and the bar it is being dragged along.
	local dragBoundary = nil

	local function showBorderHighlight(highlight: Frame, alpha: number)
		highlight.Position = UDim2.fromScale(math.clamp(alpha, 0, 1), 0)
		highlight.Visible = true
	end

	--The attribute is written when the button comes up rather than on every mouse
	--move: writing it rebuilds the rows, which would destroy the very handle being
	--dragged, and one drag should read back as one undo entry rather than hundreds.
	local function endBoundaryDrag()
		local drag = dragBoundary
		if drag == nil then
			return
		end

		dragBoundary = nil
		drag.highlight.Visible = false

		if drag.emitter.Parent == nil then
			return
		end

		--a press that never moved is a click on the row like any other
		if drag.value == nil then
			selectEmitter(drag.emitter)
			return
		end

		local attribute = drag.blocks[drag.index].attribute
		recorded("Set " .. attribute, function()
			drag.emitter:SetAttribute(attribute, drag.value)
		end)
	end

	local function endBoundaryDragOnRelease(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			endBoundaryDrag()
		end
	end

	--Where a block and its border sit on the axis. Used to lay a row out to begin
	--with and to move it while one of its borders is being dragged.
	local function layoutBlock(block, from: number, to: number, span: number)
		block.frame.Position = UDim2.fromScale(from / span, 0)
		block.frame.Size = UDim2.fromScale((to - from) / span, 1)
		block.handle.Position = UDim2.fromScale(to / span, 0)
	end

	local function moveBoundaryDrag(input: InputObject)
		local drag = dragBoundary
		if drag == nil or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		local width = drag.track.AbsoluteSize.X
		if width <= 0 then
			return
		end

		local block = drag.blocks[drag.index]

		--The block now runs from where it starts to wherever the mouse is, and its
		--attribute is that length shared between however many times it loops. The
		--floor is applied after the snap rather than before it, so that the nearest
		--step to a very short drag cannot fall through it.
		local at = (input.Position.X - drag.track.AbsolutePosition.X) / width * drag.span
		local value = math.max(snapSeconds((at - block.from) / block.loops), block.minimum)

		drag.value = value

		--The row is laid out again as it will be once the value is written, so the
		--rectangles follow the border rather than waiting for the button to come up.
		--Nothing before the border moves, and because the stages run in series the
		--blocks after it shift by whatever it gained or lost, keeping their own
		--lengths. The axis is deliberately left as it is: rescaling it under the
		--mouse would move the border away from the cursor dragging it, so a block
		--taken past the end simply runs off the edge until the drag is over.
		local shift = value * block.loops - (block.to - block.from)

		for index, other in drag.blocks do
			local from = other.from
			local to = other.to

			if index == drag.index then
				to += shift
			elseif index > drag.index then
				from += shift
				to += shift
			end

			layoutBlock(other, from, to, drag.span)
		end

		--the line sits where the border will land rather than under the mouse, so the
		--snap is something the drag shows rather than something it does afterwards
		showBorderHighlight(drag.highlight, (block.from + value * block.loops) / drag.span)
	end

	local function addTimelineBlock(track: Frame, text: string, fill: Color3, from: number, to: number, span: number)
		local block = Instance.new("TextLabel")
		block.Name = if text == "" then "Delay" else text
		block.Position = UDim2.fromScale(from / span, 0)
		block.Size = UDim2.fromScale((to - from) / span, 1)
		block.BackgroundColor3 = fill
		block.BorderSizePixel = 0
		block.Font = Enum.Font.SourceSans
		block.TextSize = 12
		--the fills are deep enough to read white off in either Studio theme
		block.TextColor3 = Color3.new(1, 1, 1)
		block.TextTruncate = Enum.TextTruncate.AtEnd
		block.Text = text
		block.Parent = track
		return block
	end

	--The right-hand border of a block, there to be grabbed: dragging it changes the
	--length of the block to its left, which for a stage window is that stage's
	--duration and for the gap before a stage is that stage's delay. The stages run
	--back to back, so everything to the right of the border shifts along with it.
	--
	--The handle draws nothing of its own -- it only shows the row's white line --
	--so the blocks are still drawn exactly as they were.
	local function addBoundaryHandle(
		track: Frame,
		highlight: Frame,
		emitter: Instance,
		blocks,
		index: number,
		span: number
	)
		local block = blocks[index]
		local alpha = block.to / span

		local handle = Instance.new("TextButton")
		handle.Name = block.attribute .. "Border"
		handle.AnchorPoint = Vector2.new(0.5, 0)
		handle.Position = UDim2.fromScale(alpha, 0)
		--wide enough to be worth aiming at: BORDER_GRAB either side of the border
		handle.Size = UDim2.new(0, BORDER_GRAB * 2 + 1, 1, 0)
		handle.BackgroundTransparency = 1
		handle.AutoButtonColor = false
		handle.Text = ""
		handle.ZIndex = 2
		handle.Parent = track

		handle.MouseEnter:Connect(function()
			if dragBoundary == nil then
				showBorderHighlight(highlight, alpha)
			end
		end)

		handle.MouseLeave:Connect(function()
			if dragBoundary == nil then
				highlight.Visible = false
			end
		end)

		handle.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			--the whole row is carried, since dragging one border moves every block
			--after it as well
			dragBoundary = {
				emitter = emitter,
				blocks = blocks,
				index = index,
				track = track,
				span = span,
				highlight = highlight,
				--nothing is written unless the mouse actually moves
				value = nil,
			}
			showBorderHighlight(highlight, alpha)
		end)

		--the mouse leaves the handle almost at once when dragged, so the row and the
		--window carry the drag on from here
		handle.InputChanged:Connect(moveBoundaryDrag)
		handle.InputEnded:Connect(endBoundaryDragOnRelease)

		return handle
	end

	--One emitter's row: its name, then its stages on the shared axis. Clicking it
	--picks that emitter, the same as picking it in the middle pane, so the rows
	--can be used to navigate rather than only to read.
	--Which name was clicked and when. Picking a row rebuilds every row, so the first
	--click of a double click destroys the very label the second one lands on, and
	--none of this can be remembered on the row itself.
	local lastNameClick: Instance? = nil
	local lastNameClickAt = 0

	--The name becomes a field over the top of itself: same place, same text, all of
	--it selected so that typing replaces the old name outright. Committing when the
	--field loses focus is how the parameter fields behave too, so a name is written
	--by pressing Return or by clicking away from it, while Escape puts the old one
	--back. A blank name is no name at all, so it counts as leaving it alone.
	local function beginRename(emitter: Instance, label: TextLabel)
		local holder = label.Parent
		if holder == nil or emitter.Parent == nil then
			return
		end

		local box = Instance.new("TextBox")
		box.Name = "Rename"
		box.Position = label.Position
		box.Size = label.Size
		box.BackgroundColor3 = theme.inputBackground
		box.BorderColor3 = theme.inputBorder
		box.Font = Enum.Font.SourceSans
		box.TextSize = TEXT_SIZE
		box.TextColor3 = theme.text
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.ClearTextOnFocus = false
		box.Text = emitter.Name
		box.ZIndex = 2
		box.Parent = holder

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 2)
		padding.PaddingRight = UDim.new(0, 2)
		padding.Parent = box

		label.Visible = false

		--a rebuild under a half-typed name would throw it away, which is the same
		--reason the parameter fields hold redraws off while they are being typed into
		fieldFocused = true

		box.FocusLost:Connect(function(_, cause)
			fieldFocused = false

			local wanted = Fields.Trim(box.Text)
			local cancelled = cause ~= nil and cause.KeyCode == Enum.KeyCode.Escape

			if not cancelled and wanted ~= "" and wanted ~= emitter.Name and emitter.Parent ~= nil then
				recorded(string.format("Rename %s to %s", emitter.Name, wanted), function()
					emitter.Name = wanted
				end)
			end

			box:Destroy()

			--The rows may have been rebuilt while the name was being typed, in which
			--case this label is gone and the one that replaced it is already showing
			--whatever the name now is.
			if label.Parent ~= nil then
				label.Text = emitter.Name
				label.Visible = true
			end
		end)

		box:CaptureFocus()
		box.CursorPosition = #box.Text + 1
		box.SelectionStart = 1
	end

	local function addTimelineRow(order: number, emitter: Instance, entries, span: number, selected: boolean)
		local row = Instance.new("TextButton")
		row.Name = "Row"
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, TIMELINE_ROW_HEIGHT)
		row.BorderSizePixel = 0
		row.AutoButtonColor = false
		--the row the panes are showing is picked out, so the two halves of the
		--window read as being about the same thing
		row.BackgroundColor3 = if selected then theme.rowSelected else theme.background
		row.BackgroundTransparency = if selected then 0 else 1
		row.Text = ""
		row.Parent = rows

		if not selected then
			row.MouseEnter:Connect(function()
				row.BackgroundTransparency = 0
				row.BackgroundColor3 = theme.rowHover
			end)
			row.MouseLeave:Connect(function()
				row.BackgroundTransparency = 1
			end)
		end

		--Whether the press about to activate the row landed on the name rather than on
		--the bar. It is read off the press because a label takes no clicks of its own,
		--and putting a button over the name instead would take the hover and the
		--border drags off the row along with them.
		local pressedName = false

		row.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				pressedName = input.Position.X - row.AbsolutePosition.X < TIMELINE_TRACK_LEFT
			end
		end)

		--a border being dragged is almost always dragged across the row rather than
		--across the handle it started on, and the row takes the mouse before the
		--window behind it does
		row.InputChanged:Connect(moveBoundaryDrag)
		row.InputEnded:Connect(endBoundaryDragOnRelease)

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.Position = UDim2.fromOffset(PADDING, 0)
		nameLabel.Size = UDim2.fromOffset(TIMELINE_NAME_WIDTH - PADDING, TIMELINE_ROW_HEIGHT)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = if selected then Enum.Font.SourceSansBold else Enum.Font.SourceSans
		nameLabel.TextSize = TEXT_SIZE
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.TextColor3 = if selected then theme.selectedText else theme.subText
		nameLabel.Text = emitter.Name
		nameLabel.Parent = row

		row.Activated:Connect(function()
			local now = os.clock()
			local again = pressedName and lastNameClick == emitter and now - lastNameClickAt <= DOUBLE_CLICK_TIME

			--the first click has already picked the row, so a second one on the same
			--name has nothing left to do but open it
			if again then
				lastNameClick = nil
				beginRename(emitter, nameLabel)
				return
			end

			lastNameClick = if pressedName then emitter else nil
			lastNameClickAt = now
			selectEmitter(emitter)
		end)

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Position = UDim2.fromOffset(TIMELINE_TRACK_LEFT, (TIMELINE_ROW_HEIGHT - TIMELINE_TRACK_HEIGHT) // 2)
		track.Size = UDim2.new(1, -(TIMELINE_TRACK_LEFT + TIMELINE_TRACK_RIGHT), 0, TIMELINE_TRACK_HEIGHT)
		track.BackgroundColor3 = theme.inputBackground
		track.BorderColor3 = theme.border
		track.ClipsDescendants = true
		track.Parent = row

		--Every block is described before any is drawn, since each one's border has to
		--know which attribute its length belongs to and where the block begins.
		local blocks = {}
		local cursor = 0

		for _, entry in entries do
			local stage = entry.name:sub(1, 1):upper() .. entry.name:sub(2)

			--BuildTimeline drops the delays, keeping only the windows a stage is
			--actually playing, so each gap it left behind is that stage's delay
			if entry.start > cursor then
				table.insert(blocks, {
					text = "",
					fill = DELAY_COLOR,
					from = cursor,
					to = entry.start,
					attribute = stage .. "Delay",
					--no delay at all is a legitimate result; the block just goes away
					minimum = 0,
					loops = 1,
				})
			end

			table.insert(blocks, {
				text = if entry.loopCount > 1 then string.format("%s x%d", stage, entry.loopCount) else stage,
				fill = STAGE_COLORS[entry.name] or theme.buttonBackground,
				from = entry.start,
				to = entry.finish,
				attribute = stage .. "Duration",
				minimum = MIN_DRAG_DURATION,
				--a looping stage draws its window once per pass, so the attribute is a
				--fraction of the length on screen
				loops = entry.loopCount,
			})

			cursor = entry.finish
		end

		--the frames are kept on the descriptors so that a drag can move them without
		--rebuilding the row, which would destroy the handle being dragged
		for _, block in blocks do
			block.frame = addTimelineBlock(track, block.text, block.fill, block.from, block.to, span)
		end

		--One line shared by the row's borders, since only ever one of them is under
		--the mouse. Above the blocks, so the border reads as a line over them.
		local highlight = Instance.new("Frame")
		highlight.Name = "BorderHighlight"
		highlight.AnchorPoint = Vector2.new(0.5, 0)
		highlight.Size = UDim2.new(0, BORDER_HIGHLIGHT_WIDTH, 1, 0)
		highlight.BorderSizePixel = 0
		highlight.BackgroundColor3 = Color3.new(1, 1, 1)
		highlight.ZIndex = 3
		highlight.Visible = false
		highlight.Parent = track

		for index, block in blocks do
			block.handle = addBoundaryHandle(track, highlight, emitter, blocks, index, span)
		end
	end

	local function refreshTimeline()
		for _, child in rows:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		timelineSpan = 0
		playhead.Visible = false
		durationMark.Visible = false

		local sequence = selectedSequence
		if sequence == nil then
			showTimelineHint("Select a sequence to see its emitters' stages.")
			return
		end

		local emitters = collectEmitters(sequence)
		if #emitters == 0 then
			showTimelineHint("This sequence has no emitters.")
			return
		end

		--One pass to resolve every emitter's stages, so they can all be laid out
		--against the longest of them.
		local duration = sequence:GetAttribute("Duration") or 0
		local span = duration
		local resolved = {}

		for _, emitter in emitters do
			local entries = Utility.BuildTimeline(readStageTimings(emitter, duration))
			table.insert(resolved, { emitter = emitter, entries = entries })
			if #entries > 0 then
				--The sequence's length is what bounds playback, but a stage running
				--past the end is still drawn rather than quietly clipped away.
				span = math.max(span, entries[#entries].finish)
			end
		end

		rows.Visible = true
		overlay.Visible = true
		startLabel.Visible = true
		endLabel.Visible = true
		timelineHint.Visible = false

		--The rows are drawn even when there is no axis to lay them out against,
		--because they are also the only list of the sequence's emitters: an effect
		--with no duration authored anywhere would otherwise show nothing that could
		--be picked, and so could not be given one.
		local hasAxis = span > 0
		timelineSpan = if hasAxis then span else 0

		if not hasAxis then
			startLabel.Text = "No stage on any emitter has a duration."
			endLabel.Text = ""
		elseif span > duration + 1e-6 then
			--An axis longer than the sequence means stages that never get to finish,
			--so both numbers are named and the mark shows which is which.
			startLabel.Text = "0s"
			endLabel.Text = string.format("%.2fs  (sequence ends %.2fs)", span, duration)
			durationMark.Visible = duration > 0
			durationMark.Position = UDim2.fromScale(duration / span, 0)
		else
			startLabel.Text = "0s"
			endLabel.Text = string.format("%.2fs", span)
		end

		for index, item in resolved do
			--with no axis every row is empty, so the span is then only a divisor
			addTimelineRow(index, item.emitter, item.entries, math.max(span, 1), item.emitter == selectedEmitter)
		end

		setTimelineHeight(#resolved)
	end

	--Called every frame while an effect plays, so it moves the line and does
	--nothing else; the rows behind it are rebuilt only when a timing changes.
	local function setPlayhead(elapsed: number?)
		if elapsed == nil or timelineSpan <= 0 or not rows.Visible then
			playhead.Visible = false
			return
		end

		local alpha = math.clamp(elapsed / timelineSpan, 0, 1)
		playhead.Visible = true
		--centred on the instant rather than starting at it, so the line still
		--reads when playback is at either end of the axis
		playhead.Position = UDim2.new(alpha, -1, 0, 0)
	end

	--one third of the window each, laid out left to right
	local function buildPane(titleText: string, order: number, width: number)
		local pane = Instance.new("Frame")
		pane.Name = titleText:gsub("%s", "")
		pane.LayoutOrder = order
		pane.Size = UDim2.fromScale(width, 1)
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

		--right-hand divider, so the panes read as separate columns
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

	--There is no emitter column: the timeline's rows are the list of emitters, and
	--picking one there is what the middle pane used to be for. The sequence list
	--holds nothing but names, so the parameters take the rest of the width.
	local sequencePane = buildPane("VFX Sequences", 1, 1 / 3)
	local parameterPane = buildPane("Parameters", 2, 2 / 3)
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

	function openDropdown(anchor: GuiObject, items)
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

	--A button small enough to sit inside a row: the "+" that adds one of a stage's
	--attributes and the "-" that takes one away. Quiet until the mouse is on it, so
	--that a column of them does not compete with the values beside them.
	local function makeRowButton(text: string, color: Color3): TextButton
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(ROW_BUTTON_SIZE, ROW_BUTTON_SIZE)
		button.BackgroundColor3 = theme.rowHover
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Font = Enum.Font.SourceSansBold
		button.TextSize = TEXT_SIZE + 2
		button.TextColor3 = color
		button.Text = text

		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.TextColor3 = theme.text
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 1
			button.TextColor3 = color
		end)

		return button
	end

	--A "name    editor" parameter line. A value with no control of its own is
	--shown as wrapped text, so the row grows downward with its editor; the name
	--keeps a fixed height so the row's height depends only on the editor.
	--
	--`entry` describes the row:
	--  label     what to call it, which for a Base attribute or one of a stage's own
	--            is shorter than the attribute's real name
	--  value     what to show, and what kind of editor to show it with
	--  commit    what to do with an edited value; without one the row is read-only
	--  kind      names the editor outright for a value whose own type cannot
	--  fullName  the attribute's real name, when the label is a shortened one: the
	--            label is what fits in a column, but a window opened from the row has
	--            to say which attribute of which emitter it is editing
	--  remove    what to do when the row's "-" is clicked; without one there is none
	local function addParameterRow(order: number, entry)
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
		nameLabel.Text = entry.label
		nameLabel.Parent = row

		--A row that can be removed gives up the right-hand end of its editor to the
		--button, so that the two never overlap; every other row keeps the full width
		--it had.
		local buttonRoom = if entry.remove ~= nil then ROW_BUTTON_SIZE + 4 else 0

		local editor = Instance.new("Frame")
		editor.Name = "Editor"
		editor.AnchorPoint = Vector2.new(1, 0)
		editor.Position = UDim2.new(1, -buttonRoom, 0, 0)
		editor.Size = UDim2.new(1 - NAME_COLUMN, -buttonRoom, 0, ROW_HEIGHT)
		editor.AutomaticSize = Enum.AutomaticSize.Y
		editor.BackgroundTransparency = 1
		editor.Parent = row

		--what the sequence editor puts in its titlebar, fixed now rather than at
		--click time so a window opened from this row keeps naming this row
		local emitter = selectedEmitter
		local qualified = entry.fullName or entry.label
		local title = if emitter ~= nil then emitter.Name .. "." .. qualified else qualified

		fillEditor(editor, entry.value, entry.commit, entry.kind, title)

		if entry.remove ~= nil then
			--Level with the first line rather than centred, since a row grows downward
			--when its editor does and the button belongs to the row's own line.
			local button = makeRowButton("-", theme.subText)
			button.Name = "Remove"
			button.AnchorPoint = Vector2.new(1, 0)
			button.Position = UDim2.new(1, 0, 0, (ROW_HEIGHT - ROW_BUTTON_SIZE) // 2)
			button.Parent = row

			button.Activated:Connect(entry.remove)
		end

		return row
	end

	--The pane's rows sit flush against one another, so colouring each one reads as a
	--single band down the whole section rather than as stripes. That is why the
	--colour goes on the rows themselves rather than on a frame behind them, which
	--the pane's single list layout leaves no room for anyway: a frame among the rows
	--would be given a row's worth of space of its own.
	local function tintRow(row: GuiObject, hue: Color3, weight: number)
		row.BackgroundColor3 = theme.background:Lerp(hue, weight)
		row.BackgroundTransparency = 0
		--a border comes with the background it was hidden behind
		row.BorderSizePixel = 0
	end

	local refreshSequences, refreshParameters, watchSelection

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

	--Coalesced for the same reason as the parameter pane: a bulk edit reports each
	--attribute separately, and every one of them would otherwise rebuild every row.
	local timelineQueued = false

	local function requestTimelineRefresh()
		if timelineQueued then
			return
		end

		timelineQueued = true
		task.defer(function()
			timelineQueued = false
			if widget.Enabled then
				refreshTimeline()
			end
		end)
	end

	--Not one emitter's values but which emitters there are: a rebuild of the
	--middle pane and of the rows, and a rewiring of the watchers so that an
	--emitter just added is followed like the rest.
	local emitterSetQueued = false

	local function requestEmitterSetRefresh()
		if emitterSetQueued then
			return
		end

		emitterSetQueued = true
		task.defer(function()
			emitterSetQueued = false
			if not widget.Enabled then
				return
			end

			--an emitter that has been deleted cannot stay selected
			if selectedEmitter ~= nil and selectedEmitter.Parent == nil then
				selectedEmitter = nil
				refreshParameters()
			end

			--an emitter just added to a loaded effect needs its timings filling in
			--the same as one that was already there when the effect was loaded
			local sequence = selectedSequence
			if sequence ~= nil and sequence.Parent ~= nil then
				ensureStageAttributes(sequence)
			end

			watchSelection()
			refreshTimeline()
		end)
	end

	--Whether an instance coming or going could change the emitter list. Attachments
	--count whether or not they are tagged yet, since a MeshEmitter is usually
	--parented first and tagged after, and an extra rebuild costs nothing.
	local function affectsEmitterSet(inst: Instance): boolean
		return inst:IsA("ParticleEmitter") or inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("Attachment")
	end

	--Keep the parameter pane and the timeline live while a selection stands. The
	--drivers rewrite properties every heartbeat but never touch attributes, and
	--every stage timing is an attribute, so the timeline rebuilds only on a real
	--authoring change rather than on every frame of playback.
	function watchSelection()
		disconnectEmitterConnections()

		local sequence = selectedSequence
		if sequence == nil then
			return
		end

		--the sequence's Duration sets how long the shared axis spans, and with no
		--emitter picked the pane is showing that Duration
		table.insert(emitterConnections, sequence.AttributeChanged:Connect(requestTimelineRefresh))
		table.insert(emitterConnections, sequence.AttributeChanged:Connect(requestParameterRefresh))

		local function onDescendant(inst: Instance)
			if affectsEmitterSet(inst) then
				requestEmitterSetRefresh()
			end
		end

		table.insert(emitterConnections, sequence.DescendantAdded:Connect(onDescendant))
		table.insert(emitterConnections, sequence.DescendantRemoving:Connect(onDescendant))

		--every emitter has a row now, so every emitter's timings matter and not
		--just those of the one the panes are showing
		for _, emitter in collectEmitters(sequence) do
			table.insert(emitterConnections, emitter.AttributeChanged:Connect(requestTimelineRefresh))
		end

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
	--its real name; the undo entry reads back as the author saw it. Takes any
	--instance, since the pane edits the sequence's own attributes as well as an
	--emitter's.
	local function commitAttribute(inst: Instance, attributeName: string, label: string, value: any)
		if inst.Parent == nil then
			return
		end

		recorded("Set " .. label, function()
			inst:SetAttribute(attributeName, value)
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

	local function addStageAttribute(emitter: Instance, name: string, part: string)
		if emitter.Parent == nil then
			return
		end

		recorded("Add " .. name, function()
			emitter:SetAttribute(name, defaultStageValue(part))
		end)

		requestParameterRefresh()
	end

	--Taking a stage attribute away leaves the driver to fall back to whatever it does
	--when the attribute was never there, which is what the attribute's own neutral
	--value was standing in for anyway.
	local function removeStageAttribute(emitter: Instance, name: string)
		if emitter.Parent == nil then
			return
		end

		recorded("Remove " .. name, function()
			emitter:SetAttribute(name, nil)
		end)

		requestParameterRefresh()
	end

	--What `stage` can animate on this emitter and does not yet. The stage is left off
	--the entries, since the heading the menu drops from names it: under Hold, a
	--"SizeScaleOverDuration" can only be HoldSizeScaleOverDuration.
	local function stageAttributeMenu(emitter: Instance, stage: string)
		local kind = emitterKind(emitter)
		local parts = STAGE_ATTRIBUTE_PARTS[kind]

		if parts == nil then
			return { { text = "Nothing is animated per stage on a " .. kind .. "." } }
		end

		local items = {}

		for _, part in parts do
			if emitter:GetAttribute(stage .. part) == nil then
				table.insert(items, {
					text = part,
					activate = function()
						addStageAttribute(emitter, stage .. part, part)
					end,
				})
			end
		end

		if #items == 0 then
			table.insert(items, { text = string.format("%s animates everything it can already.", stage) })
		end

		return items
	end

	--A "+" at the right-hand end of a stage's heading. Its menu hangs off the
	--heading rather than off the button, so that it comes out as wide as the pane: a
	--menu the width of its anchor is what the other pickers want, but these names are
	--long enough that one the width of a 16-pixel button would truncate every single
	--one.
	local function addStageAttributeButton(heading: TextLabel, emitter: Instance, stage: string)
		local button = makeRowButton("+", theme.text)
		button.Name = "Add"
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.fromScale(1, 0.5)
		button.Parent = heading

		button.Activated:Connect(function()
			openDropdown(heading, stageAttributeMenu(emitter, stage))
		end)
	end

	function refreshParameters()
		closeDropdown()
		clearPane(parameterPane)

		local order = 0
		local function nextOrder()
			order += 1
			return order
		end

		local emitter = selectedEmitter
		local sequence = selectedSequence

		if emitter == nil or emitter.Parent == nil then
			if sequence == nil or sequence.Parent == nil then
				parameterPane.title.Text = "Parameters"
				addLabelRow(parameterPane, nextOrder(), "Select a VFX sequence.", theme.dimText, false)
				return
			end

			--With no emitter picked the pane shows the effect's own settings. That is
			--where Duration lives, the length every stage timing is derived from, and
			--so the one value that has to stay reachable however the timeline reads.
			parameterPane.title.Text = string.format("Parameters - %s (Sequence)", sequence.Name)

			local sequenceAttributes = sequence:GetAttributes()
			local sequenceNames = {}
			for attributeName in sequenceAttributes do
				table.insert(sequenceNames, attributeName)
			end
			table.sort(sequenceNames)

			addLabelRow(
				parameterPane,
				nextOrder(),
				string.format("Attributes (%d)", #sequenceNames),
				theme.subText,
				true
			)

			if #sequenceNames == 0 then
				addLabelRow(parameterPane, nextOrder(), "No attributes.", theme.dimText, false)
			end

			for _, attributeName in sequenceNames do
				addParameterRow(nextOrder(), {
					label = attributeName,
					value = sequenceAttributes[attributeName],
					commit = function(edited)
						commitAttribute(sequence, attributeName, attributeName, edited)
					end,
				})
			end

			--emitters are picked in the timeline now that there is no column of them
			addLabelRow(
				parameterPane,
				nextOrder(),
				"Pick an emitter in the timeline to edit its own parameters.",
				theme.dimText,
				false
			)
			return
		end

		--the class is named here because the column that used to name it is gone,
		--and a MeshEmitter is worth telling apart from a ParticleEmitter
		parameterPane.title.Text = string.format("Parameters - %s (%s)", emitter.Name, emitterKind(emitter))

		local attributes = emitter:GetAttributes()
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
		end

		--Where a native property sits in its own class's list, so that a Base
		--attribute files under the property it stands in for rather than off on its
		--own, and so the familiar order of a class's properties survives being split
		--across two sections.
		local propertyNames = NATIVE_PROPERTIES[emitter.ClassName]
		local nativeRank = {}
		if propertyNames ~= nil then
			for index, propertyName in propertyNames do
				nativeRank[propertyName] = index
			end
		end

		--Every row is described before any is drawn, so that each can be filed under
		--the section it belongs to whether it came from a property or an attribute.
		local sections = {}
		for index = 1, SECTION_COUNT do
			sections[index] = {}
		end
		--sorts after anything a class names itself, which is where an attribute that
		--stands in for no property belongs
		local UNRANKED = math.huge

		local function fileRow(
			name: string,
			label: string,
			value: any,
			kind: string?,
			onCommit: (any) -> (),
			onRemove: (() -> ())?
		)
			local section = sectionFor(name, value)
			local stage, part = stageAttribute(name)
			local rank, within

			if stage ~= nil then
				--the stages read in playback order rather than alphabetically, so that
				--Decay does not come before Hold
				rank, within = stage, part or ""
			else
				rank, within = nativeRank[label] or UNRANKED, label
			end

			--A stage's own section names the stage, so its rows need not: under Hold, a
			--"BrightnessScaleOverDuration" can only be HoldBrightnessScaleOverDuration.
			--The timings are the exception and keep their full names, since all three
			--stages' delays and durations share the one Timeline section and would
			--otherwise come out as three rows called Delay and three called Duration.
			local isStage = section >= SECTION_STAGE_FIRST

			local shown = label
			if isStage and part ~= nil and part ~= "" then
				shown = part
			end

			table.insert(sections[section], {
				label = shown,
				fullName = name,
				value = value,
				kind = kind,
				rank = rank,
				within = within,
				commit = onCommit,
				--Only a stage's own attributes are offered a "-". A timing is what the
				--timeline is drawn from and would be authored straight back the next
				--time the effect is loaded, and a native property is not an attribute
				--to be taken away at all.
				remove = if isStage then onRemove else nil,
			})
		end

		if propertyNames ~= nil then
			for _, propertyName in propertyNames do
				local value, ok = readProperty(emitter, propertyName)
				if ok and not shadowed[propertyName] then
					fileRow(propertyName, propertyName, value, nil, function(edited)
						commitProperty(emitter, propertyName, edited)
					end)
				end
			end
		end

		--the mesh template is wired up through an ObjectValue child rather than a
		--property, so surface it alongside the real properties
		if isMeshEmitter(emitter) then
			local objectValue = emitter:FindFirstChildOfClass("ObjectValue")
			local template = if objectValue ~= nil then objectValue.Value else nil
			fileRow("MeshTemplate", "MeshTemplate", template, "instance", function(edited)
				commitMeshTemplate(emitter, edited)
			end)
		end

		for attributeName, value in attributes do
			local label = displayNames[attributeName]
			fileRow(attributeName, label, value, nil, function(edited)
				commitAttribute(emitter, attributeName, label, edited)
			end, function()
				removeStageAttribute(emitter, attributeName)
			end)
		end

		--An empty section is still named, since where a parameter would appear is
		--worth knowing before there is one there: an emitter with nothing in its
		--last section is one with no stage curves authored yet.
		for index, entries in sections do
			table.sort(entries, function(a, b)
				if a.rank ~= b.rank then
					return a.rank < b.rank
				end
				return a.within < b.within
			end)

			local hue = SECTION_HUES[index]

			--full-strength text rather than the dimmed grey a heading would carry on
			--the plain background: a tint costs contrast whichever way it goes, since
			--it lightens a dark theme's background and darkens a light one's
			local heading = addLabelRow(
				parameterPane,
				nextOrder(),
				string.format("%s (%d)", SECTION_TITLES[index], #entries),
				theme.text,
				true
			)
			tintRow(heading, hue, SECTION_HEADING_TINT)

			--the stage sections are the ones whose rows are authored rather than
			--inherent in the class, and so the ones worth hanging a button off
			if index >= SECTION_STAGE_FIRST then
				addStageAttributeButton(heading, emitter, STAGES[index - SECTION_STAGE_FIRST + 1])
			end

			if #entries == 0 then
				tintRow(addLabelRow(parameterPane, nextOrder(), "None.", theme.dimText, false), hue, SECTION_TINT)
			end

			for _, entry in entries do
				tintRow(addParameterRow(nextOrder(), entry), hue, SECTION_TINT)
			end
		end
	end

	--The timeline is redrawn as well as the parameters, since it is the rows that
	--show which emitter is picked, and the toolbar because Delete Emitter acts on
	--whatever that is.
	function selectEmitter(emitter: Instance?)
		selectedEmitter = emitter
		watchSelection()
		refreshParameters()
		refreshTimeline()
		updateToolbar()
	end

	local function selectSequence(sequence: Instance?)
		selectedSequence = sequence
		selectedEmitter = nil

		--Loading an effect is what fills in the timings it is missing, and it
		--happens before the panes and the timeline are drawn so that what they show
		--is what is now authored on the emitters.
		if sequence ~= nil then
			ensureStageAttributes(sequence)
		end

		watchSelection()
		refreshSequences()
		refreshParameters()
		refreshTimeline()
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
				watchSelection()
			end
		end

		if selectedEmitter ~= nil and selectedEmitter.Parent == nil then
			selectedEmitter = nil
			watchSelection()
		end

		refreshSequences()
		refreshParameters()
		refreshTimeline()
	end

	local function applyTheme()
		theme = currentTheme()

		root.BackgroundColor3 = theme.background
		toolbar.BackgroundColor3 = theme.header
		toolbarDivider.BackgroundColor3 = theme.border
		playTarget.TextColor3 = theme.dimText

		tooltip.BackgroundColor3 = theme.inputBackground
		tooltip.BorderColor3 = theme.border
		tooltip.TextColor3 = theme.text

		--the rows themselves carry their colours from creation, and refreshAll
		--below redraws them
		timelineBand.BackgroundColor3 = theme.header
		playhead.BackgroundColor3 = theme.text
		durationMark.BackgroundColor3 = theme.text
		timelineHint.TextColor3 = theme.dimText
		startLabel.TextColor3 = theme.dimText
		endLabel.TextColor3 = theme.dimText

		--Studio ships these two icons once per theme rather than tinting one, so they
		--are re-pointed and not just recoloured.
		local themeVariant = iconVariant(theme)
		addIcon.Image = string.format(ADD_ICON, themeVariant)
		deleteIcon.Image = string.format(DELETE_ICON, themeVariant)

		for _, button in { playButton, stopButton, addButton, deleteButton } do
			button.BackgroundColor3 = theme.buttonBackground
			button.BorderColor3 = theme.buttonBorder
		end

		for _, pane in { sequencePane, parameterPane } do
			pane.pane.BackgroundColor3 = theme.background
			pane.header.BackgroundColor3 = theme.header
			pane.title.TextColor3 = theme.text
			pane.divider.BackgroundColor3 = theme.border
		end

		--rows carry theme colours baked in at creation, so redraw them
		refreshAll()
	end

	table.insert(connections, Studio.ThemeChanged:Connect(applyTheme))
	--a taller window can afford more timeline rows before scrolling, and a shorter
	--one has to give the room back to the panes
	table.insert(
		connections,
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			setTimelineHeight(timelineRowCount)
		end)
	)
	--A stage border keeps following the mouse anywhere in the window, and the drag
	--ends wherever the button comes up. That last one is watched globally as well
	--because a release outside the window is one the rows never hear about, and a
	--drag left open would commit itself on some unrelated later click.
	table.insert(connections, root.InputChanged:Connect(moveBoundaryDrag))
	table.insert(connections, root.InputEnded:Connect(endBoundaryDragOnRelease))
	table.insert(connections, UserInputService.InputEnded:Connect(endBoundaryDragOnRelease))
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
	--A MeshEmitter is an Attachment that has been tagged, so tagging one that is
	--already in the selected sequence makes it an emitter without anything being
	--parented. The sequence's own descendant signals cannot see that.
	for _, signal in
		{
			CollectionService:GetInstanceAddedSignal(MESH_EMITTER_TAG),
			CollectionService:GetInstanceRemovedSignal(MESH_EMITTER_TAG),
		}
	do
		table.insert(
			connections,
			signal:Connect(function(inst)
				local sequence = selectedSequence
				if sequence ~= nil and inst:IsDescendantOf(sequence) then
					requestEmitterSetRefresh()
				end
			end)
		)
	end
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

	--Where playback has reached, pushed in by whatever is running the effect:
	--the sequence being played and its elapsed time, or nil once nothing is.
	--Only the sequence the window is showing moves the line.
	function controller:SetPlayhead(sequence: Instance?, elapsed: number?)
		if sequence ~= nil and sequence == selectedSequence then
			setPlayhead(elapsed)
		else
			setPlayhead(nil)
		end
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
