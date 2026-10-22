-- Shared type definitions.

export type BayState = "Empty" | "Arriving" | "Washing" | "Completing" | "Departing"

export type DirtPatchState = {
	Id: string,
	RemainingDirt: number,
	InitialDirt: number,
	Weight: number,
}

-- Payload of BayStateChanged (server -> owner)
export type BaySnapshot = {
	BayName: string,
	State: BayState,
	JobId: string?,
	AnimalName: string?,
	Rarity: string?,
	Mutation: string?,
	Reward: number?,
	Progress: number?,
}

export type ZooSummary = {
	ZooSize: number,
	MaxPens: number,
	Count: number,
	NextExpansionPrice: number?,
	CacheCount: number,
	CacheSlots: number,
	IncomePerSecond: number,
}

-- The animal riding above the player's head while they carry it to a pen.
export type CarryInfo = {
	Label: string,
	Rarity: string,
	Mutation: string,
	IncomePerSecond: number,
	SellValue: number,
}

-- Loaded: progress saves. Failed/Locked: playing on a temporary profile that is never saved.
export type DataStatus = "Loaded" | "Failed" | "Locked"

-- Payload of InitialState / RequestInitialState
export type InitialState = {
	DataStatus: DataStatus,
	Coins: number,
	ToolTier: number,
	ToolName: string,
	TutorialCompleted: boolean,
	GuideStep: string?, -- Wash, Pickup, Place, Collect, Upgrade, Repeat, Done
	Bay: BaySnapshot?,
	Zoo: ZooSummary?,
	Index: { [string]: boolean }?,
}

return {}
