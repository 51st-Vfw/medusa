require("_header")
require("services.Services")

--[[
            ███████╗██████╗  █████╗ ████████╗██╗ █████╗ ██╗          ██████╗ ██╗   ██╗███████╗██████╗ ██╗   ██╗
            ██╔════╝██╔══██╗██╔══██╗╚══██╔══╝██║██╔══██╗██║         ██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝
            ███████╗██████╔╝███████║   ██║   ██║███████║██║         ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝
            ╚════██║██╔═══╝ ██╔══██║   ██║   ██║██╔══██║██║         ██║   ██║██║   ██║██╔══╝  ██╔══██╗  ╚██╔╝
            ███████║██║     ██║  ██║   ██║   ██║██║  ██║███████╗    ╚██████╔╝╚██████╔╝███████╗██║  ██║   ██║
            ╚══════╝╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝╚═╝  ╚═╝╚══════╝     ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝

    What this service does
    - Provides radius search helpers that query the GeoGrid for nearby batteries, sensors, or tracks.
    - Returns filtered result lists from the underlying stores based on spatial proximity.

    How others use it
    - TargetAssigner finds candidate batteries within range of a track using batteriesInRadius.
    - PointDefenseService and HarmDetectionService use radius queries to find nearby assets.
--]]

Medusa.Services.SpatialQuery = {}

Medusa.Services.SpatialQuery._buffer = {}
local _spatialQueryBuffer = Medusa.Services.SpatialQuery._buffer

local floor, ceil = math.floor, math.ceil
local FILTER_BATTERY = { "Battery" }

--- Batteries within radiusM (2D) of pos. The result list is reused by the next call. It walks the harness GeoGrid's
--- cells straight into that list, with the same cell and exact-distance tests as GeoGrid:queryRadius, so a query
--- allocates nothing: it runs for every HARM, assignment and point-defense check, often over most of a network.
function Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, pos, radiusM)
	local out = _spatialQueryBuffer
	for i = #out, 1, -1 do
		out[i] = nil
	end
	if type(pos) ~= "table" or type(radiusM) ~= "number" or radiusM < 0 then
		return out
	end
	local grid, idx, cellSize = geoGrid.grid, geoGrid.idx, geoGrid.cell
	if not (grid and idx and cellSize) then
		-- another grid implementation: its own query
		local ids = geoGrid:queryRadius(pos, radiusM, FILTER_BATTERY).BatteryIds
		if ids then
			for id in pairs(ids) do
				local battery = batteryStore:get(id)
				if battery then
					out[#out + 1] = battery
				end
			end
		end
		return out
	end
	if geoGrid.types and not geoGrid.types.Battery then
		return out
	end
	local px, pz = pos.x or 0, pos.z or 0
	local ccx, ccz = floor(px / cellSize), floor(pz / cellSize)
	local cr = ceil(radiusM / cellSize)
	local r2 = radiusM * radiusM
	local n = 0
	for cx = ccx - cr, ccx + cr do
		local col = grid[cx]
		if col then
			for cz = ccz - cr, ccz + cr do
				local cell = col[cz]
				local bucket = cell and cell.BatteryIds
				if bucket then
					for id in pairs(bucket) do
						local loc = idx[id]
						local lp = loc and loc.p
						if lp then
							local dx, dz = lp.x - px, lp.z - pz
							if dx * dx + dz * dz <= r2 then
								local battery = batteryStore:get(id)
								if battery then
									n = n + 1
									out[n] = battery
								end
							end
						end
					end
				end
			end
		end
	end
	return out
end

--- Test whether a position is inside any of the given border zone polygons.
--- Uses the harness PointInPolygon2D ray-casting algorithm (odd crossings = inside).
--- Returns true on first match.
--- @param borderPolygons table[] List of polygon tables, each a list of ground Vec3 points
--- @param pos table Vec3 position
--- @return boolean inside True if pos is inside any border polygon
function Medusa.Services.SpatialQuery.pointInBorderZones(borderPolygons, pos)
	for i = 1, #borderPolygons do
		if PointInPolygon2D(pos, borderPolygons[i]) then
			return true
		end
	end
	return false
end
