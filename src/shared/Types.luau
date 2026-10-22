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
	Reward: number?,
	Progress: number?,
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
	Bay: BaySnapshot?,
}

return {}
