-- Owner titles and flight. The experience belongs to the FAIRE GAME group (game.CreatorId),
-- so anyone at MinRank or above in that group is staff: rank 255 is the group Owner and 254
-- is Admin, the two owners. UserIds adds people by id whatever their rank (and is what works
-- if the game is ever moved off the group).
--
-- Staff get a rainbow title over the avatar, in chat and in the player list, and can fly
-- (double-tap Space or F on keyboard, the Fly button on a phone, Y on a gamepad).

return {
	MinRank = 254,
	UserIds = {
		171080174, -- ninjacookie35YT, group owner
		1804601081, -- TheIcyChipmunk
	} :: { number },

	Role = "Owner", -- the StaffRole attribute; the client checks it before letting anyone fly
	Title = "OWNER",
	TagMaxDistance = 150, -- studs; the title over the head fades past this

	Fly = {
		Speed = 60, -- studs per second
		FastSpeed = 140, -- holding Shift
		DoubleTapSeconds = 0.3, -- most time between the two Space taps that toggle flight
		Responsiveness = 40, -- how quickly the velocity catches up (LinearVelocity is instant otherwise)
	},
}
