-- Puts a black-stroked rainbow VIP title in front of chat messages for anyone
-- the server marked with the Vip attribute. It is not drawn over the avatar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local Social = {}

function Social.init(_initial: any)
	local title = UIStyle.vipChatTitle(MonetizationConfig.VIP.TagText)
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
		props.PrefixText = `{title} {message.PrefixText}`
		return props
	end
end

return Social
