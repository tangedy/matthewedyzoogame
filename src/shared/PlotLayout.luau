-- Shared footprint for the eight farms. Slots 1-4 are east of the road and grow +X.
-- Slots 5-8 are west and grow -X. Depth is studs away from the road edge; lateral is
-- studs to the plot's right when the plot faces the road.

local GameConfig = require(script.Parent.GameConfig)

export type PlotFrame = {
	Index: number,
	Side: number, -- 1 east, -1 west
	Anchor: Vector3, -- road-edge centre of this plot
	Back: Vector3, -- away from the road, the direction the farm grows
	Right: Vector3, -- plot-local right while facing the road
	Look: Vector3, -- toward the road
}

local PlotLayout = {}

function PlotLayout.sideOf(index: number): number
	return if index <= 4 then 1 else -1
end

function PlotLayout.zOf(index: number): number
	local along = (index - 1) % 4 -- 0..3 along one side
	return (along - 1.5) * GameConfig.BaySpacing
end

function PlotLayout.frame(index: number): PlotFrame
	local side = PlotLayout.sideOf(index)
	local back = Vector3.new(side, 0, 0)
	local look = -back
	return {
		Index = index,
		Side = side,
		Anchor = Vector3.new(side * GameConfig.RoadWidth / 2, 0, PlotLayout.zOf(index)),
		Back = back,
		Right = look:Cross(Vector3.yAxis),
		Look = look,
	}
end

function PlotLayout.point(plot: PlotFrame, depth: number, lateral: number, y: number): Vector3
	return plot.Anchor + plot.Back * depth + plot.Right * lateral + Vector3.new(0, y, 0)
end

-- Facing into the farm. Animals walk this way, from the road toward the wash.
function PlotLayout.inbound(plot: PlotFrame, depth: number, lateral: number, y: number): CFrame
	local pos = PlotLayout.point(plot, depth, lateral, y)
	return CFrame.lookAt(pos, pos + plot.Back)
end

-- Facing the road.
function PlotLayout.outbound(plot: PlotFrame, depth: number, lateral: number, y: number): CFrame
	local pos = PlotLayout.point(plot, depth, lateral, y)
	return CFrame.lookAt(pos, pos + plot.Look)
end

-- True when a point sits in a plot's reserved rectangle, including the barn it may grow into.
function PlotLayout.contains(x: number, z: number, margin: number): boolean
	local halfW = GameConfig.PlotWidth / 2 + margin
	for i = 1, GameConfig.BayCount do
		local side = PlotLayout.sideOf(i)
		local edge = side * GameConfig.RoadWidth / 2
		local far = edge + side * GameConfig.PlotDepth
		local minX = math.min(edge, far) - margin
		local maxX = math.max(edge, far) + margin
		if x >= minX and x <= maxX and math.abs(z - PlotLayout.zOf(i)) <= halfW then
			return true
		end
	end
	return false
end

return PlotLayout
