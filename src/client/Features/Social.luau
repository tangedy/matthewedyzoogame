-- Puts a gold VIP title in front of chat messages for anyone who has spent Robux.
-- The server sets the Vip attribute; the overhead tag is built there too.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Social = {}

function Social.init(_initial: any)
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
		local source = message.TextSource
		if not source then
			return nil
		end
		local speaker = Players:GetPlayerByUserId(source.UserId)
		if not speaker or speaker:GetAttribute("Vip") ~= true then
			return nil
		end
		local props = Instance.new("TextChatMessageProperties")
		props.PrefixText = `<font color="#FFD24A">[VIP]</font> {message.PrefixText}`
		return props
	end
end

return Social
