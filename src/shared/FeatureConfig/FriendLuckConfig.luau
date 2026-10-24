-- Friend luck: while at least one Roblox friend is in the same server, walk-ins of
-- MinRarityOrder and above get SpawnWeightMultiplier (through Hooks "SpawnWeight").
-- The server writes the friend count to the player's FriendLuck attribute; the client box
-- on the right reads it and opens the Roblox invite prompt.

return {
	MinRarityOrder = 2, -- RarityConfig order: Rare and above
	SpawnWeightMultiplier = 2,
	PromptText = "Invite Friends for 2x LUCK!",
	ActiveText = "2x LUCK ACTIVE!",
	InviteMessage = "Come wash animals with me!",
}
