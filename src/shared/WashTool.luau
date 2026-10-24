-- Finds the cleaning tool a character is holding. Players hold a real Tool (it sits in the
-- backpack hotbar and is always equipped); the cutscene avatar holds a welded part named
-- "Hose". Either way the returned part carries the "Nozzle" attachment the spray starts from.

local WashTool = {}

WashTool.ATTRIBUTE = "WashTool"

function WashTool.find(character: Instance?): BasePart?
	if not character then
		return nil
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute(WashTool.ATTRIBUTE) == true then
			local handle = child:FindFirstChild("Handle")
			return if handle and handle:IsA("BasePart") then handle else nil
		end
	end
	local welded = character:FindFirstChild("Hose")
	return if welded and welded:IsA("BasePart") then welded else nil
end

return WashTool
