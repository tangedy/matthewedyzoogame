-- Puts black-stroked rainbow titles in front of chat messages: VIP for anyone the server
-- marked with the Vip attribute, PRO WASHER for the ProWasher attribute (daily check-in),
-- and the owners' StaffTitle (server/Features/Staff, which also draws theirs over the avatar).
-- VIP and PRO WASHER are not drawn over the avatar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local Social = {}

function Social.init(_initial: any)
	local title = UIStyle.vipChatTitle(MonetizationConfig.VIP.TagText)
	local proTitle = UIStyle.vipChatTitle("PRO WASHER") -- daily check-in, day 6
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
		local source = message.TextSource
		if not source then
			return nil
		end
		local speaker = Players:GetPlayerByUserId(source.UserId)
		if not speaker then
			return nil
		end
		local prefix = ""
		local staffTitle = speaker:GetAttribute("StaffTitle")
		if typeof(staffTitle) == "string" then
			prefix ..= `{UIStyle.vipChatTitle(staffTitle)} `
		end
		if speaker:GetAttribute("Vip") == true then
			prefix ..= `{title} `
		end
		if speaker:GetAttribute("ProWasher") == true then
			prefix ..= `{proTitle} `
		end
		if prefix == "" then
			return nil
		end
		local props = Instance.new("TextChatMessageProperties")
		props.PrefixText = `{prefix}{message.PrefixText}`
		return props
	end
end

return Social
