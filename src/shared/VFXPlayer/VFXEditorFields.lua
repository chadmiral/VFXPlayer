--Turning a parameter value into text and back again, for the VFX Editor's
--parameter fields. Kept free of UI so the round trip -- value to text, text to
--value -- can be reasoned about, and exercised, on its own.
--
--Only the types that are edited as text make the trip both ways. Vectors and
--ranges are typed a component at a time, enums are picked from a list, booleans
--are toggled, and sequences are dragged in the sequence editor; those are
--formatted here for display but never read back from a string.
local VFXEditorFields = {}

local function trim(text: string): string
	return (string.match(text, "^%s*(.-)%s*$"))
end
VFXEditorFields.Trim = trim

--%g rather than a fixed precision: enough significant digits that a value
--survives being shown and typed back unchanged, without a tail of zeros on the
--round numbers most parameters actually hold.
local function formatNumber(n: number): string
	return string.format("%g", n)
end
VFXEditorFields.FormatNumber = formatNumber

local function formatColor3(c: Color3): string
	return string.format("%d, %d, %d", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end
VFXEditorFields.FormatColor3 = formatColor3

--The readable spelling of a value. Sequences read as their keypoints,
--`time:value` separated by spaces, which is what a parameter row shows on the
--button that opens the sequence editor.
function VFXEditorFields.ToText(value: any): string
	local valueType = typeof(value)

	if valueType == "nil" then
		return ""
	elseif valueType == "number" then
		return formatNumber(value)
	elseif valueType == "string" then
		return value
	elseif valueType == "boolean" then
		return tostring(value)
	elseif valueType == "EnumItem" then
		return value.Name
	elseif valueType == "Instance" then
		return string.format("%s (%s)", value.Name, value.ClassName)
	elseif valueType == "Color3" then
		return formatColor3(value)
	elseif valueType == "Vector2" then
		return string.format("%s, %s", formatNumber(value.X), formatNumber(value.Y))
	elseif valueType == "Vector3" then
		return string.format("%s, %s, %s", formatNumber(value.X), formatNumber(value.Y), formatNumber(value.Z))
	elseif valueType == "CFrame" then
		local p = value.Position
		return string.format("%s, %s, %s", formatNumber(p.X), formatNumber(p.Y), formatNumber(p.Z))
	elseif valueType == "NumberRange" then
		return string.format("%s .. %s", formatNumber(value.Min), formatNumber(value.Max))
	elseif valueType == "UDim" then
		return string.format("%s, %s", formatNumber(value.Scale), formatNumber(value.Offset))
	elseif valueType == "UDim2" then
		return string.format(
			"{%s, %s}, {%s, %s}",
			formatNumber(value.X.Scale),
			formatNumber(value.X.Offset),
			formatNumber(value.Y.Scale),
			formatNumber(value.Y.Offset)
		)
	elseif valueType == "NumberSequence" then
		local parts = {}
		for _, keypoint in value.Keypoints do
			table.insert(parts, string.format("%s:%s", formatNumber(keypoint.Time), formatNumber(keypoint.Value)))
		end
		return table.concat(parts, "  ")
	elseif valueType == "ColorSequence" then
		local parts = {}
		for _, keypoint in value.Keypoints do
			table.insert(parts, string.format("%s:(%s)", formatNumber(keypoint.Time), formatColor3(keypoint.Value)))
		end
		return table.concat(parts, "  ")
	end

	return tostring(value)
end

--A signed decimal, in plain or exponent form. Used to pick the numbers out of a
--sequence without also matching the punctuation between them.
local NUMBER_PATTERN = "[%-%+]?[%d%.]+[eE]?[%-%+%d]*"

function VFXEditorFields.ParseNumber(text: string): number?
	return tonumber(trim(text))
end

--Either "#RRGGBB" or the "r, g, b" spelling the pane shows, in 0-255.
function VFXEditorFields.ParseColor3(text: string): Color3?
	local body = trim(text)

	local hex = string.match(body, "^#?(%x%x%x%x%x%x)$")
	if hex ~= nil then
		local number = tonumber(hex, 16) :: number
		return Color3.fromRGB(bit32.extract(number, 16, 8), bit32.extract(number, 8, 8), bit32.extract(number, 0, 8))
	end

	local r, g, b = string.match(
		body,
		"^(" .. NUMBER_PATTERN .. ")%s*,%s*(" .. NUMBER_PATTERN .. ")%s*,%s*(" .. NUMBER_PATTERN .. ")$"
	)
	if r == nil then
		return nil
	end

	local red, green, blue = tonumber(r), tonumber(g), tonumber(b)
	if red == nil or green == nil or blue == nil then
		return nil
	end

	return Color3.fromRGB(math.clamp(red, 0, 255), math.clamp(green, 0, 255), math.clamp(blue, 0, 255))
end

--Read `text` back as the same type as `template`. Returns the value and whether
--the text could be understood; a false result leaves the caller to put the old
--text back.
function VFXEditorFields.Parse(text: string, template: any): (any, boolean)
	local templateType = typeof(template)
	local body = trim(text)

	if templateType == "string" then
		return text, true
	elseif templateType == "number" then
		local number = tonumber(body)
		return number, number ~= nil
	elseif templateType == "boolean" then
		local lowered = string.lower(body)
		if lowered == "true" then
			return true, true
		elseif lowered == "false" then
			return false, true
		end
		return nil, false
	elseif templateType == "Color3" then
		local color = VFXEditorFields.ParseColor3(body)
		return color, color ~= nil
	end

	return nil, false
end

--Whether a value of this type can be typed into a text field at all. Vectors,
--ranges, enums, booleans and instances get their own controls, and the two
--sequence types open the sequence editor.
function VFXEditorFields.IsTextEditable(value: any): boolean
	local valueType = typeof(value)
	return valueType == "string" or valueType == "number" or valueType == "Color3"
end

return VFXEditorFields
